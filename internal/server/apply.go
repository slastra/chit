package server

import (
	"encoding/json"
	"errors"
	"fmt"
	"regexp"
	"sort"
	"time"

	"github.com/pocketbase/dbx"
	"github.com/pocketbase/pocketbase/core"
	"github.com/pocketbase/pocketbase/tools/types"

	"github.com/slastra/chit/internal/hlc"
	"github.com/slastra/chit/internal/merge"
	"github.com/slastra/chit/internal/order"
	"github.com/slastra/chit/internal/protocol"
)

// maxSkew is how far past the server's clock an op's HLC may be. Further
// than this and one device's bad clock would win every merge for hours.
const maxSkew = 10 * time.Minute

var recordID = regexp.MustCompile(`^[a-z0-9]{15}$`)

type kind int

const (
	kText kind = iota
	kBool
	kInt
	kDate // RFC 3339 or PocketBase datetime string, "" to clear
	kStrings
)

type field struct {
	kind      kind
	ownerOnly bool // notes: only the owner may set it
	create    bool // set only when the record is created
	merge     bool // free text: concurrent edits merge (Op.Base) instead of the later winning
}

var specs = map[string]map[string]field{
	protocol.Notes: {
		"kind":    {kind: kText},
		"title":   {kind: kText, merge: true},
		"body":    {kind: kText, merge: true},
		"color":   {kind: kText},
		"trashed": {kind: kDate, ownerOnly: true},
		"deleted": {kind: kBool, ownerOnly: true},
	},
	protocol.Items: {
		"note":    {kind: kText, create: true},
		"text":    {kind: kText, merge: true},
		"checked": {kind: kBool},
		"order":   {kind: kText},
		"indent":  {kind: kInt},
		"deleted": {kind: kBool},
	},
	protocol.Attachments: {
		"deleted": {kind: kBool},
	},
	protocol.Labels: {
		"name":    {kind: kText},
		"deleted": {kind: kBool},
	},
	protocol.NoteState: {
		"pinned":        {kind: kBool},
		"archived":      {kind: kBool},
		"labels":        {kind: kStrings},
		"reminder":      {kind: kDate},
		"reminder_done": {kind: kBool},
		"order":         {kind: kText},
	},
}

func decode(k kind, raw json.RawMessage) (any, error) {
	switch k {
	case kText:
		var s string
		err := json.Unmarshal(raw, &s)
		return s, err
	case kDate:
		// "" clears it; anything else must be a date, or PocketBase would
		// quietly store a cleared one in its place
		var s string
		if err := json.Unmarshal(raw, &s); err != nil {
			return nil, err
		}
		if s != "" && !validDate(s) {
			return nil, fmt.Errorf("%q is not a date (RFC 3339, in UTC)", s)
		}
		return s, nil
	case kBool:
		var b bool
		err := json.Unmarshal(raw, &b)
		return b, err
	case kInt:
		var n int
		err := json.Unmarshal(raw, &n)
		return n, err
	case kStrings:
		var ss []string
		err := json.Unmarshal(raw, &ss)
		if ss == nil {
			ss = []string{}
		}
		return ss, err
	}
	return nil, errors.New("unknown field kind")
}

// validDate reports whether s is a date the clients write: RFC 3339 (the
// apps and the CLI) or PocketBase's own layout.
func validDate(s string) bool {
	for _, layout := range []string{time.RFC3339Nano, types.DefaultDateLayout} {
		if _, err := time.Parse(layout, s); err == nil {
			return true
		}
	}
	return false
}

// group is the ops for one record, kept in request order.
type group struct {
	collection, id string
	idx            []int
}

func groupOps(ops []protocol.Op) []*group {
	var order []*group
	byKey := map[string]*group{}
	for i, op := range ops {
		key := op.Collection + "/" + op.ID
		g := byKey[key]
		if g == nil {
			g = &group{collection: op.Collection, id: op.ID}
			byKey[key] = g
			order = append(order, g)
		}
		g.idx = append(g.idx, i)
	}
	// Records others hang on go first: a new note before its items, state
	// and files, a new label before the state that uses it, whatever order
	// the batch came in. Otherwise request order, record by record.
	first := func(g *group) bool { return g.collection == protocol.Notes || g.collection == protocol.Labels }
	sort.SliceStable(order, func(i, j int) bool { return first(order[i]) && !first(order[j]) })
	return order
}

// applyOps applies a batch for user me in one transaction and returns a result
// per op plus the newest seq. Bad ops are rejected one record at a time, so a
// single bad op never blocks a client's queue.
func applyOps(app core.App, me *core.Record, device string, ops []protocol.Op, now time.Time) (*protocol.OpsResponse, error) {
	resp := &protocol.OpsResponse{Results: make([]protocol.OpResult, len(ops))}
	err := app.RunInTransaction(func(tx core.App) error {
		for _, g := range groupOps(ops) {
			if err := applyGroup(tx, me, device, ops, g, now, resp.Results); err != nil {
				return err
			}
		}
		var err error
		resp.Seq, err = head(tx)
		return err
	})
	return resp, err
}

func reject(results []protocol.OpResult, idx []int, msg string) {
	for _, i := range idx {
		results[i] = protocol.OpResult{Error: msg}
	}
}

// applyGroup returns an error only for storage failures; anything the client
// got wrong lands in results.
func applyGroup(tx core.App, me *core.Record, device string, ops []protocol.Op, g *group, now time.Time, results []protocol.OpResult) error {
	spec, ok := specs[g.collection]
	if !ok {
		reject(results, g.idx, fmt.Sprintf("collection %q is not writable", g.collection))
		return nil
	}
	if !recordID.MatchString(g.id) {
		reject(results, g.idx, "id must be 15 characters of a-z and 0-9")
		return nil
	}

	// Check every op before touching the record.
	values := map[int]any{}
	var live []int
	for _, i := range g.idx {
		op := ops[i]
		f, ok := spec[op.Field]
		switch {
		case !ok:
			results[i].Error = fmt.Sprintf("field %q is not writable", op.Field)
		case !hlc.Valid(op.HLC):
			results[i].Error = "bad hlc"
		default:
			t, _ := hlc.Time(op.HLC)
			if t.After(now.Add(maxSkew)) {
				results[i].Error = "hlc is too far in the future; check this device's clock"
				break
			}
			v, err := decode(f.kind, op.Value)
			if err != nil {
				results[i].Error = fmt.Sprintf("bad value for %s: %v", op.Field, err)
				break
			}
			values[i] = v
			live = append(live, i)
		}
	}
	if len(live) == 0 {
		return nil
	}

	rec, created, note, noteID, msg, err := loadTarget(tx, me, g, ops, live, values)
	if err != nil {
		return err
	}
	if msg != "" {
		reject(results, live, msg)
		return nil
	}

	acc := noAccess
	if note != nil {
		if acc, _, err = noteAccess(tx, me.Id, note.Id); err != nil {
			return err
		}
	}

	clocks := clocksOf(rec)
	var won []int
	// edits merged with one made meanwhile, and the clock each result takes
	merged := map[int]string{}
	for _, i := range live {
		op := ops[i]
		f := spec[op.Field]
		// Free text edited from an older value than the one there now:
		// someone else wrote it meanwhile. Join the two edits (whichever
		// clock is later), so neither is lost, and stamp the result past
		// both. A resend of an edit already in (its clock is the field's)
		// is stale as ever.
		if f.merge && !created && op.Base != "" && op.Base != clocks[op.Field] && op.HLC != clocks[op.Field] {
			base, ok, err := baseValue(tx, noteID, g.collection, g.id, op.Field, op.Base)
			if err != nil {
				return err
			}
			if ok {
				values[i] = merge.Merge(base, rec.GetString(op.Field), values[i].(string))
				serverClock.Observe(op.HLC)
				serverClock.Observe(clocks[op.Field])
				merged[i] = serverClock.Now()
				rec.Set(op.Field, values[i])
				clocks[op.Field] = merged[i]
				won = append(won, i)
				continue
			}
		}
		// stale first: a client resending a batch whose answer it lost (or
		// two of its isolates both flushing) gets "stale", which it acks,
		// rather than a create-only or owner-only error that makes it
		// reload everything
		if op.HLC <= clocks[op.Field] {
			results[i].Stale = true
			continue
		}
		if f.create && !created {
			results[i].Error = fmt.Sprintf("%s cannot change after the record exists", op.Field)
			continue
		}
		if f.ownerOnly && !created && acc != isOwner {
			results[i].Error = fmt.Sprintf("only the owner can set %s", op.Field)
			continue
		}
		// order keys: valid fractional keys, or "" (no place yet, on a
		// board); short enough to stay a key, not a payload
		if op.Field == "order" {
			if k, _ := values[i].(string); len(k) > 64 || (k != "" && !order.Valid(k)) ||
				(k == "" && g.collection == protocol.Items) {
				results[i].Error = "order must be a valid order key"
				continue
			}
		}
		if g.collection == protocol.NoteState && op.Field == "labels" {
			if msg, err := checkLabels(tx, me.Id, values[i].([]string)); err != nil {
				return err
			} else if msg != "" {
				results[i].Error = msg
				continue
			}
		}
		rec.Set(op.Field, values[i])
		clocks[op.Field] = op.HLC
		won = append(won, i)
	}
	if len(won) == 0 {
		return nil
	}
	rec.Set("clocks", clocks)
	if err := tx.Save(rec); err != nil {
		reject(results, won, err.Error())
		return nil
	}

	scope, reader := "note", ""
	if g.collection == protocol.Labels || g.collection == protocol.NoteState {
		scope, reader = "user", me.Id
	}
	if created {
		if _, err := appendChange(tx, entry{
			scope: scope, user: reader, note: noteID, kind: protocol.KindRecord,
			collection: g.collection, record: g.id, value: wireRecord(rec),
			hlc: ops[won[len(won)-1]].HLC, by: me.Id, device: device,
		}); err != nil {
			return err
		}
	} else {
		for _, i := range won {
			op := ops[i]
			v, _ := json.Marshal(rec.Get(op.Field))
			h, dev := op.HLC, device
			if stamp, ok := merged[i]; ok {
				// a merge is news to the sender too: it holds only its half
				h, dev = stamp, ""
			}
			if _, err := appendChange(tx, entry{
				scope: scope, user: reader, note: noteID, kind: protocol.KindSet,
				collection: g.collection, record: g.id, field: op.Field, value: v,
				hlc: h, by: me.Id, device: dev,
			}); err != nil {
				return err
			}
		}
	}
	for _, i := range won {
		results[i].Applied = true
		_, results[i].Merged = merged[i]
	}
	return nil
}

// loadTarget finds or creates the record a group writes to and checks that me
// may write it. A non-empty msg rejects the group.
func loadTarget(tx core.App, me *core.Record, g *group, ops []protocol.Op, live []int, values map[int]any) (
	rec *core.Record, created bool, note *core.Record, noteID, msg string, err error,
) {
	col, err := tx.FindCollectionByNameOrId(g.collection)
	if err != nil {
		return nil, false, nil, "", "", err
	}
	editable := func(id string) (*core.Record, string, error) {
		acc, n, err := noteAccess(tx, me.Id, id)
		if err != nil {
			return nil, "", err
		}
		if acc < canEdit {
			return nil, "you cannot edit this note", nil
		}
		return n, "", nil
	}

	switch g.collection {
	case protocol.Notes:
		rec, err = tx.FindRecordById(col, g.id)
		if err != nil {
			rec, created = core.NewRecord(col), true
			rec.Id = g.id
			rec.Set("owner", me.Id)
			return rec, true, rec, g.id, "", nil
		}
		n, msg, err := editable(g.id)
		return rec, false, n, g.id, msg, err

	case protocol.Items:
		rec, err = tx.FindRecordById(col, g.id)
		if err != nil {
			parent := ""
			for _, i := range live {
				if ops[i].Field == "note" {
					parent, _ = values[i].(string)
				}
			}
			if parent == "" {
				return nil, false, nil, "", "a new item needs its note", nil
			}
			n, msg, err := editable(parent)
			if msg != "" || err != nil {
				return nil, false, nil, "", msg, err
			}
			rec = core.NewRecord(col)
			rec.Id = g.id
			return rec, true, n, parent, "", nil
		}
		n, msg, err := editable(rec.GetString("note"))
		return rec, false, n, rec.GetString("note"), msg, err

	case protocol.Attachments:
		rec, err = tx.FindRecordById(col, g.id)
		if err != nil {
			return nil, false, nil, "", "unknown attachment; upload files with POST /api/chit/notes/{id}/attachments", nil
		}
		n, msg, err := editable(rec.GetString("note"))
		return rec, false, n, rec.GetString("note"), msg, err

	case protocol.Labels:
		rec, err = tx.FindRecordById(col, g.id)
		if err != nil {
			rec = core.NewRecord(col)
			rec.Id = g.id
			rec.Set("user", me.Id)
			return rec, true, nil, "", "", nil
		}
		if rec.GetString("user") != me.Id {
			return nil, false, nil, "", "not your label", nil
		}
		return rec, false, nil, "", "", nil

	case protocol.NoteState:
		acc, n, err := noteAccess(tx, me.Id, g.id)
		if err != nil {
			return nil, false, nil, "", "", err
		}
		if acc == noAccess {
			return nil, false, nil, "", "you cannot see this note", nil
		}
		rec, err = tx.FindFirstRecordByFilter(col, "note = {:n} && user = {:u}", dbx.Params{"n": g.id, "u": me.Id})
		if err != nil {
			rec = core.NewRecord(col)
			rec.Set("note", g.id)
			rec.Set("user", me.Id)
			return rec, true, n, g.id, "", nil
		}
		return rec, false, n, g.id, "", nil
	}
	return nil, false, nil, "", "collection is not writable", nil
}

// checkLabels makes sure every label id belongs to the user.
func checkLabels(tx core.App, userID string, ids []string) (string, error) {
	for _, id := range ids {
		l, err := tx.FindRecordById(protocol.Labels, id)
		if err != nil || l.GetString("user") != userID {
			return fmt.Sprintf("label %q is not yours", id), nil
		}
	}
	return "", nil
}

// serverClock stamps the result of a merge: past both edits it joins.
var serverClock = hlc.New("srv")

// baseValue finds the value field held when its clock was base: from the
// edit that wrote it, or from the whole record when it was created (or
// copied into a new member's feed). Not found (the log was compacted, or a
// bad base): the edit falls back to the later one winning.
func baseValue(tx core.App, noteID, collection, record, field, base string) (string, bool, error) {
	var rows []struct {
		Kind  string `db:"kind"`
		Field string `db:"field"`
		Value string `db:"value"`
		HLC   string `db:"hlc"`
	}
	err := tx.DB().NewQuery(`
		SELECT kind, field, value, hlc FROM chit_changes
		WHERE scope = 'note' AND note = {:note} AND collection = {:collection} AND record = {:record}
		  AND ((kind = 'set' AND field = {:field} AND hlc = {:base}) OR kind = 'record')
		ORDER BY seq DESC
	`).Bind(dbx.Params{"note": noteID, "collection": collection, "record": record, "field": field, "base": base}).All(&rows)
	if err != nil {
		return "", false, err
	}
	for _, r := range rows {
		switch r.Kind {
		case protocol.KindSet:
			var s string
			if json.Unmarshal([]byte(r.Value), &s) == nil {
				return s, true, nil
			}
		case protocol.KindRecord:
			var rec map[string]any
			if json.Unmarshal([]byte(r.Value), &rec) != nil {
				continue
			}
			clocks, _ := rec["clocks"].(map[string]any)
			if c, _ := clocks[field].(string); c == base {
				s, _ := rec[field].(string)
				return s, true, nil
			}
		}
	}
	return "", false, nil
}
