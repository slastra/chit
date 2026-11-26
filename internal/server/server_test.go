package server

import (
	"crypto/rand"
	"encoding/json"
	"fmt"
	"testing"
	"time"

	"github.com/pocketbase/pocketbase/core"
	"github.com/pocketbase/pocketbase/tests"

	"github.com/slastra/chit/internal/hlc"
	"github.com/slastra/chit/internal/protocol"
	_ "github.com/slastra/chit/migrations"
)

type env struct {
	t   *testing.T
	app *tests.TestApp
}

func newEnv(t *testing.T) *env {
	t.Helper()
	app, err := tests.NewTestAppWithConfig(core.BaseAppConfig{DataDir: t.TempDir()})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(app.Cleanup)
	return &env{t: t, app: app}
}

// device is one client: a user plus a clock.
type device struct {
	env   *env
	user  *core.Record
	id    string
	clock *hlc.Clock
}

func (e *env) user(name string) *core.Record {
	e.t.Helper()
	c, _ := e.app.FindCollectionByNameOrId("users")
	r := core.NewRecord(c)
	r.Set("email", name+"@example.com")
	r.Set("name", name)
	r.SetPassword("correct horse battery")
	if err := e.app.Save(r); err != nil {
		e.t.Fatal(err)
	}
	return r
}

func (e *env) device(user *core.Record, id string) *device {
	return &device{env: e, user: user, id: id, clock: hlc.New(id)}
}

func newID() string {
	const alphabet = "abcdefghijklmnopqrstuvwxyz0123456789"
	b := make([]byte, 15)
	rand.Read(b)
	for i := range b {
		b[i] = alphabet[int(b[i])%len(alphabet)]
	}
	return string(b)
}

func op(collection, id, field string, value any, h string) protocol.Op {
	v, _ := json.Marshal(value)
	return protocol.Op{Collection: collection, ID: id, Field: field, Value: v, HLC: h}
}

func (d *device) send(ops ...protocol.Op) *protocol.OpsResponse {
	d.env.t.Helper()
	resp, err := applyOps(d.env.app, d.user, d.id, ops, time.Now())
	if err != nil {
		d.env.t.Fatal(err)
	}
	return resp
}

func (d *device) mustApply(ops ...protocol.Op) {
	d.env.t.Helper()
	for i, r := range d.send(ops...).Results {
		if !r.Applied {
			d.env.t.Fatalf("op %d (%s.%s) not applied: %+v", i, ops[i].Collection, ops[i].Field, r)
		}
	}
}

func (d *device) newList(title string, items ...string) (noteID string, itemIDs []string) {
	noteID = newID()
	ops := []protocol.Op{
		op(protocol.Notes, noteID, "kind", "list", d.clock.Now()),
		op(protocol.Notes, noteID, "title", title, d.clock.Now()),
	}
	key := "V"
	for _, text := range items {
		id := newID()
		itemIDs = append(itemIDs, id)
		ops = append(ops,
			op(protocol.Items, id, "note", noteID, d.clock.Now()),
			op(protocol.Items, id, "text", text, d.clock.Now()),
			op(protocol.Items, id, "order", key, d.clock.Now()),
		)
		key += "V"
	}
	d.mustApply(ops...)
	return noteID, itemIDs
}

func (d *device) changes(since int64) *protocol.ChangesResponse {
	d.env.t.Helper()
	resp, err := changesFor(d.env.app, d.user.Id, d.id, since)
	if err != nil {
		d.env.t.Fatal(err)
	}
	return resp
}

func (d *device) snapshot() *protocol.Snapshot {
	d.env.t.Helper()
	s, err := snapshot(d.env.app, d.user.Id)
	if err != nil {
		d.env.t.Fatal(err)
	}
	return s
}

func TestCreateListAndReadItBack(t *testing.T) {
	e := newEnv(t)
	shaun := e.device(e.user("shaun"), "desk")
	note, _ := shaun.newList("Groceries", "milk", "eggs")

	s := shaun.snapshot()
	if len(s.Notes) != 1 || s.Notes[0].ID != note || s.Notes[0].Title != "Groceries" || s.Notes[0].Owner != shaun.user.Id {
		t.Fatalf("notes = %+v", s.Notes)
	}
	if len(s.Items) != 2 || s.Items[0].Text != "milk" || s.Items[1].Text != "eggs" {
		t.Fatalf("items = %+v", s.Items)
	}
	if s.Notes[0].Clocks["title"] == "" {
		t.Fatal("note clocks missing from snapshot")
	}
}

func TestOwnDeviceGetsNoEcho(t *testing.T) {
	e := newEnv(t)
	u := e.user("shaun")
	desk, phone := e.device(u, "desk"), e.device(u, "phone")
	desk.newList("Groceries", "milk")

	if n := len(desk.changes(0).Changes); n != 0 {
		t.Fatalf("desk got %d of its own changes back", n)
	}
	got := phone.changes(0)
	if len(got.Changes) != 2 { // note record + item record
		t.Fatalf("phone got %d changes, want 2: %+v", len(got.Changes), got.Changes)
	}
	if got.Changes[0].Kind != protocol.KindRecord || got.Changes[0].Collection != protocol.Notes {
		t.Fatalf("first change = %+v", got.Changes[0])
	}
}

func TestStrangerCannotSeeOrEdit(t *testing.T) {
	e := newEnv(t)
	shaun := e.device(e.user("shaun"), "desk")
	eve := e.device(e.user("eve"), "evil")
	note, items := shaun.newList("Groceries", "milk")

	if got := eve.changes(0); len(got.Changes) != 0 {
		t.Fatalf("stranger sees %d changes", len(got.Changes))
	}
	if s := eve.snapshot(); len(s.Notes) != 0 || len(s.Items) != 0 {
		t.Fatalf("stranger snapshot = %+v", s)
	}
	r := eve.send(
		op(protocol.Items, items[0], "checked", true, eve.clock.Now()),
		op(protocol.Notes, note, "title", "pwned", eve.clock.Now()),
		op(protocol.Items, newID(), "note", note, eve.clock.Now()),
		op(protocol.NoteState, note, "pinned", true, eve.clock.Now()),
	)
	for i, res := range r.Results {
		if res.Applied || res.Error == "" {
			t.Errorf("stranger op %d = %+v, want rejected", i, res)
		}
	}
}

func TestShareGivesSnapshotThenLiveEdits(t *testing.T) {
	e := newEnv(t)
	shaun := e.device(e.user("shaun"), "desk")
	angelica := e.device(e.user("angelica"), "pixel")
	note, items := shaun.newList("Groceries", "milk", "eggs")

	// Angelica's cursor is already past the note's creation.
	cursor := angelica.changes(0).Seq
	if _, err := share(e.app, shaun.user, shaun.id, note, angelica.user.Id, "editor"); err != nil {
		t.Fatal(err)
	}
	got := angelica.changes(cursor)
	seen := map[string]int{}
	for _, c := range got.Changes {
		seen[c.Collection]++
	}
	if seen[protocol.Notes] != 1 || seen[protocol.Items] != 2 || seen[protocol.Members] < 1 {
		t.Fatalf("after share, angelica got %v", seen)
	}
	cursor = got.Seq

	// She checks off milk; Shaun's desk sees exactly that.
	angelica.mustApply(op(protocol.Items, items[0], "checked", true, angelica.clock.Now()))
	sc := shaun.changes(cursor)
	if len(sc.Changes) != 1 || sc.Changes[0].Field != "checked" || string(sc.Changes[0].Value) != "true" || sc.Changes[0].By != angelica.user.Id {
		t.Fatalf("shaun saw %+v", sc.Changes)
	}
}

func TestLastWriteWinsPerField(t *testing.T) {
	e := newEnv(t)
	shaun := e.device(e.user("shaun"), "desk")
	_, items := shaun.newList("Groceries", "milk")

	older := shaun.clock.Now()
	newer := shaun.clock.Now()
	shaun.mustApply(op(protocol.Items, items[0], "text", "oat milk", newer))
	r := shaun.send(op(protocol.Items, items[0], "text", "whole milk", older))
	if r.Results[0].Applied || !r.Results[0].Stale {
		t.Fatalf("older write result = %+v, want stale", r.Results[0])
	}
	// A different field with an older clock still applies: clocks are per field.
	shaun.mustApply(op(protocol.Items, items[0], "checked", true, older))

	it := shaun.snapshot().Items[0]
	if it.Text != "oat milk" || !it.Checked {
		t.Fatalf("item = %+v", it)
	}
}

func TestRolesLimitWrites(t *testing.T) {
	e := newEnv(t)
	shaun := e.device(e.user("shaun"), "desk")
	angelo := e.device(e.user("angelo"), "phone")
	angelica := e.device(e.user("angelica"), "pixel")
	note, items := shaun.newList("Chores", "dishes")
	if _, err := share(e.app, shaun.user, shaun.id, note, angelo.user.Id, "viewer"); err != nil {
		t.Fatal(err)
	}
	if _, err := share(e.app, shaun.user, shaun.id, note, angelica.user.Id, "editor"); err != nil {
		t.Fatal(err)
	}

	if r := angelo.send(op(protocol.Items, items[0], "checked", true, angelo.clock.Now())); r.Results[0].Applied {
		t.Fatal("viewer checked an item")
	}
	if r := angelica.send(op(protocol.Notes, note, "deleted", true, angelica.clock.Now())); r.Results[0].Applied {
		t.Fatal("editor deleted the owner's note")
	}
	// A viewer still keeps their own per-user state.
	angelo.mustApply(op(protocol.NoteState, note, "pinned", true, angelo.clock.Now()))
	if _, err := share(e.app, angelica.user, angelica.id, note, angelo.user.Id, "editor"); err == nil {
		t.Fatal("a non-owner changed someone's role")
	}
}

func TestPerUserStateStaysPrivate(t *testing.T) {
	e := newEnv(t)
	shaun := e.device(e.user("shaun"), "desk")
	angelica := e.device(e.user("angelica"), "pixel")
	note, _ := shaun.newList("Groceries")
	if _, err := share(e.app, shaun.user, shaun.id, note, angelica.user.Id, "editor"); err != nil {
		t.Fatal(err)
	}
	cursor := shaun.changes(0).Seq

	angelica.mustApply(op(protocol.NoteState, note, "pinned", true, angelica.clock.Now()))
	if got := shaun.changes(cursor); len(got.Changes) != 0 {
		t.Fatalf("shaun saw angelica's pin: %+v", got.Changes)
	}
	if s := shaun.snapshot(); len(s.State) != 0 {
		t.Fatalf("shaun's snapshot has state %+v", s.State)
	}
	s := angelica.snapshot()
	if len(s.State) != 1 || !s.State[0].Pinned || s.State[0].Note != note {
		t.Fatalf("angelica state = %+v", s.State)
	}

	// A second write updates the same row instead of making another.
	angelica.mustApply(op(protocol.NoteState, note, "archived", true, angelica.clock.Now()))
	if s := angelica.snapshot(); len(s.State) != 1 || !s.State[0].Archived || !s.State[0].Pinned {
		t.Fatalf("angelica state after archive = %+v", s.State)
	}
}

func TestUnshareRevokes(t *testing.T) {
	e := newEnv(t)
	shaun := e.device(e.user("shaun"), "desk")
	angelica := e.device(e.user("angelica"), "pixel")
	note, items := shaun.newList("Gift ideas", "scarf")
	if _, err := share(e.app, shaun.user, shaun.id, note, angelica.user.Id, "editor"); err != nil {
		t.Fatal(err)
	}
	cursor := angelica.changes(0).Seq

	if _, err := unshare(e.app, shaun.user, shaun.id, note, angelica.user.Id); err != nil {
		t.Fatal(err)
	}
	got := angelica.changes(cursor)
	if len(got.Changes) != 1 || got.Changes[0].Kind != protocol.KindRevoke || got.Changes[0].Record != note {
		t.Fatalf("after unshare angelica got %+v", got.Changes)
	}
	cursor = got.Seq

	shaun.mustApply(op(protocol.Items, items[0], "text", "red scarf", shaun.clock.Now()))
	if got := angelica.changes(cursor); len(got.Changes) != 0 {
		t.Fatalf("revoked member still sees edits: %+v", got.Changes)
	}
}

func TestMemberCanLeave(t *testing.T) {
	e := newEnv(t)
	shaun := e.device(e.user("shaun"), "desk")
	angelo := e.device(e.user("angelo"), "phone")
	note, _ := shaun.newList("Chores")
	if _, err := share(e.app, shaun.user, shaun.id, note, angelo.user.Id, "editor"); err != nil {
		t.Fatal(err)
	}
	if _, err := unshare(e.app, angelo.user, angelo.id, note, angelo.user.Id); err != nil {
		t.Fatalf("member could not leave: %v", err)
	}
	if s := angelo.snapshot(); len(s.Notes) != 0 {
		t.Fatal("note still visible after leaving")
	}
}

func TestBadOpsAreRejectedOneByOne(t *testing.T) {
	e := newEnv(t)
	shaun := e.device(e.user("shaun"), "desk")
	note, _ := shaun.newList("Groceries")
	future := time.Now().Add(time.Hour).UnixMilli()

	r := shaun.send(
		op(protocol.Notes, note, "title", 42, shaun.clock.Now()),                 // wrong type
		op(protocol.Notes, note, "owner", "someone", shaun.clock.Now()),          // not writable
		op(protocol.Notes, note, "title", "ok", "garbage"),                       // bad clock
		op(protocol.Notes, note, "title", "late", hlcAt(future)),                 // clock too far ahead
		op(protocol.Items, newID(), "text", "orphan", shaun.clock.Now()),         // new item, no note
		op("users", shaun.user.Id, "name", "x", shaun.clock.Now()),               // not a chit collection
		op(protocol.Notes, note, "title", "Weekly groceries", shaun.clock.Now()), // fine
	)
	for i, res := range r.Results[:6] {
		if res.Applied || res.Error == "" {
			t.Errorf("op %d = %+v, want an error", i, res)
		}
	}
	if !r.Results[6].Applied {
		t.Fatalf("good op after bad ones = %+v", r.Results[6])
	}
}

func hlcAt(ms int64) string { return fmt.Sprintf("%013d-0000-x", ms) }

func TestLabelsMustBeYours(t *testing.T) {
	e := newEnv(t)
	shaun := e.device(e.user("shaun"), "desk")
	angelica := e.device(e.user("angelica"), "pixel")
	note, _ := shaun.newList("Groceries")
	if _, err := share(e.app, shaun.user, shaun.id, note, angelica.user.Id, "editor"); err != nil {
		t.Fatal(err)
	}
	label := newID()
	shaun.mustApply(op(protocol.Labels, label, "name", "home", shaun.clock.Now()))
	shaun.mustApply(op(protocol.NoteState, note, "labels", []string{label}, shaun.clock.Now()))

	r := angelica.send(op(protocol.NoteState, note, "labels", []string{label}, angelica.clock.Now()))
	if r.Results[0].Applied {
		t.Fatal("angelica attached shaun's label")
	}
}

func TestStreamCursorSkipsInvisibleRows(t *testing.T) {
	e := newEnv(t)
	shaun := e.device(e.user("shaun"), "desk")
	eve := e.device(e.user("eve"), "evil")
	shaun.newList("Groceries", "milk")
	got := eve.changes(0)
	if len(got.Changes) != 0 || got.Seq == 0 {
		t.Fatalf("eve = %+v, want no changes and the cursor moved to the head", got)
	}
}

func TestReplayedBatchIsStaleNotAnError(t *testing.T) {
	e := newEnv(t)
	shaun := e.device(e.user("shaun"), "desk")
	note := newID()
	item := newID()
	batch := []protocol.Op{
		op(protocol.Notes, note, "kind", "list", shaun.clock.Now()),
		op(protocol.Items, item, "note", note, shaun.clock.Now()),
		op(protocol.Items, item, "text", "milk", shaun.clock.Now()),
	}
	shaun.mustApply(batch...)
	// the same batch again, as after a lost response
	for i, r := range shaun.send(batch...).Results {
		if r.Applied || !r.Stale || r.Error != "" {
			t.Errorf("replayed op %d = %+v, want stale", i, r)
		}
	}
}
