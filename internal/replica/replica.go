// Package replica is chitd's local copy of everything the user can see, plus
// the outbox of edits not yet accepted by the server. It merges with the same
// per-field last-write-wins rule as the server, so the two cannot disagree.
//
// Records are stored as their wire JSON (internal/protocol types) and merged
// generically, field by field, using each record's clocks map.
package replica

import (
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"sync"
	"time"

	_ "modernc.org/sqlite"

	"github.com/slastra/chit/internal/protocol"
)

type Replica struct {
	mu sync.Mutex
	db *sql.DB
	// Now stamps local "updated" times; tests replace it.
	Now func() time.Time
}

const schema = `
CREATE TABLE IF NOT EXISTS records (
	collection TEXT NOT NULL,
	id         TEXT NOT NULL,
	note       TEXT NOT NULL DEFAULT '',
	data       TEXT NOT NULL,
	PRIMARY KEY (collection, id)
);
CREATE INDEX IF NOT EXISTS idx_records_note ON records (note);
CREATE TABLE IF NOT EXISTS outbox (
	seq     INTEGER PRIMARY KEY AUTOINCREMENT,
	op      TEXT NOT NULL,
	created TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS uploads (
	id      TEXT PRIMARY KEY,
	note    TEXT NOT NULL,
	path    TEXT NOT NULL,
	record  TEXT NOT NULL,
	created TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS meta (
	key   TEXT PRIMARY KEY,
	value TEXT NOT NULL
);`

// Open opens (creating if needed) the replica at path.
func Open(path string) (*Replica, error) {
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return nil, err
	}
	db, err := sql.Open("sqlite", "file:"+path+"?_pragma=journal_mode(WAL)&_pragma=busy_timeout(5000)&_pragma=foreign_keys(1)")
	if err != nil {
		return nil, err
	}
	db.SetMaxOpenConns(1) // one writer; the mutex serializes everything anyway
	if _, err := db.Exec(schema); err != nil {
		db.Close()
		return nil, err
	}
	return &Replica{db: db, Now: time.Now}, nil
}

func (r *Replica) Close() error { return r.db.Close() }

// Meta keys.
const (
	MetaCursor = "cursor"
	MetaDevice = "device"
	MetaUser   = "user"
	MetaServer = "server"
)

func (r *Replica) Meta(key string) (string, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	var v string
	err := r.db.QueryRow("SELECT value FROM meta WHERE key = ?", key).Scan(&v)
	if errors.Is(err, sql.ErrNoRows) {
		return "", nil
	}
	return v, err
}

func (r *Replica) SetMeta(key, value string) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	return setMeta(r.db, key, value)
}

type execer interface {
	Exec(query string, args ...any) (sql.Result, error)
}

func setMeta(db execer, key, value string) error {
	_, err := db.Exec("INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT (key) DO UPDATE SET value = excluded.value", key, value)
	return err
}

// Cursor is the feed position the replica has applied up to.
func (r *Replica) Cursor() (int64, error) {
	v, err := r.Meta(MetaCursor)
	if err != nil || v == "" {
		return 0, err
	}
	return strconv.ParseInt(v, 10, 64)
}

// Wipe forgets every record, the outbox and the cursor (for a server or user
// change). The device id survives.
func (r *Replica) Wipe() error {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.tx(func(tx *sql.Tx) error {
		for _, q := range []string{"DELETE FROM records", "DELETE FROM outbox", "DELETE FROM uploads", "DELETE FROM meta WHERE key IN ('cursor', 'user', 'server')"} {
			if _, err := tx.Exec(q); err != nil {
				return err
			}
		}
		return nil
	})
}

func (r *Replica) tx(fn func(*sql.Tx) error) error {
	tx, err := r.db.Begin()
	if err != nil {
		return err
	}
	if err := fn(tx); err != nil {
		tx.Rollback()
		return err
	}
	return tx.Commit()
}

// record is one stored record as a field map.
type record map[string]json.RawMessage

func (rec record) clocks() protocol.Clocks {
	c := protocol.Clocks{}
	if raw, ok := rec["clocks"]; ok {
		_ = json.Unmarshal(raw, &c)
	}
	if c == nil {
		c = protocol.Clocks{}
	}
	return c
}

func (rec record) setClocks(c protocol.Clocks) {
	b, _ := json.Marshal(c)
	rec["clocks"] = b
}

func (rec record) str(field string) string {
	var s string
	_ = json.Unmarshal(rec[field], &s)
	return s
}

// key is how a record is addressed: note_state rows by their note's id.
func keyOf(collection string, rec record) string {
	if collection == protocol.NoteState {
		return rec.str("note")
	}
	return rec.str("id")
}

// noteOf is the note a record belongs to (a note belongs to itself).
func noteOf(collection string, rec record) string {
	if collection == protocol.Notes {
		return rec.str("id")
	}
	return rec.str("note")
}

func load(q interface {
	QueryRow(string, ...any) *sql.Row
}, collection, id string) (record, error) {
	var data string
	err := q.QueryRow("SELECT data FROM records WHERE collection = ? AND id = ?", collection, id).Scan(&data)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	rec := record{}
	if err := json.Unmarshal([]byte(data), &rec); err != nil {
		return nil, err
	}
	return rec, nil
}

func store(tx execer, collection string, rec record) error {
	b, err := json.Marshal(rec)
	if err != nil {
		return err
	}
	_, err = tx.Exec(`INSERT INTO records (collection, id, note, data) VALUES (?, ?, ?, ?)
		ON CONFLICT (collection, id) DO UPDATE SET note = excluded.note, data = excluded.data`,
		collection, keyOf(collection, rec), noteOf(collection, rec), string(b))
	return err
}

func toRecord(v any) (record, error) {
	b, err := json.Marshal(v)
	if err != nil {
		return nil, err
	}
	rec := record{}
	return rec, json.Unmarshal(b, &rec)
}

// pbTime formats a time the way PocketBase does, so locally stamped and
// server-stamped times sort together.
func pbTime(t time.Time) string { return t.UTC().Format("2006-01-02 15:04:05.000Z") }

// touch bumps the parent note's updated time, so recently edited notes sort
// first even for edits the feed reports field by field.
func (r *Replica) touch(tx *sql.Tx, noteID string) error {
	if noteID == "" {
		return nil
	}
	n, err := load(tx, protocol.Notes, noteID)
	if err != nil || n == nil {
		return err
	}
	n["updated"], _ = json.Marshal(pbTime(r.Now()))
	return store(tx, protocol.Notes, n)
}

// ReplaceAll swaps the whole replica for a server snapshot and moves the
// cursor to it. Pending outbox ops stay queued and are re-applied on top, so
// edits made offline survive a resync.
func (r *Replica) ReplaceAll(s *protocol.Snapshot) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.tx(func(tx *sql.Tx) error {
		if _, err := tx.Exec("DELETE FROM records"); err != nil {
			return err
		}
		add := func(collection string, v any) error {
			rec, err := toRecord(v)
			if err != nil {
				return err
			}
			return store(tx, collection, rec)
		}
		for _, n := range s.Notes {
			if err := add(protocol.Notes, n); err != nil {
				return err
			}
		}
		for _, v := range s.Items {
			if err := add(protocol.Items, v); err != nil {
				return err
			}
		}
		for _, v := range s.Members {
			if err := add(protocol.Members, v); err != nil {
				return err
			}
		}
		for _, v := range s.State {
			if err := add(protocol.NoteState, v); err != nil {
				return err
			}
		}
		for _, v := range s.Labels {
			if err := add(protocol.Labels, v); err != nil {
				return err
			}
		}
		for _, v := range s.Attachments {
			if err := add(protocol.Attachments, v); err != nil {
				return err
			}
		}
		pending, err := pendingOps(tx, 0)
		if err != nil {
			return err
		}
		var me string
		_ = tx.QueryRow("SELECT value FROM meta WHERE key = 'user'").Scan(&me)
		for _, q := range pending {
			if _, err := r.applyOp(tx, q.Op, me); err != nil {
				return err
			}
		}
		// Files still waiting to upload are not on the server yet either.
		rows, err := tx.Query("SELECT record FROM uploads")
		if err != nil {
			return err
		}
		var waiting []string
		for rows.Next() {
			var rec string
			if err := rows.Scan(&rec); err != nil {
				rows.Close()
				return err
			}
			waiting = append(waiting, rec)
		}
		rows.Close()
		for _, raw := range waiting {
			rec := record{}
			if err := json.Unmarshal([]byte(raw), &rec); err != nil {
				return err
			}
			if err := store(tx, protocol.Attachments, rec); err != nil {
				return err
			}
		}
		return setMeta(tx, MetaCursor, strconv.FormatInt(s.Seq, 10))
	})
}

// Upload is a file waiting to go to the server.
type Upload struct {
	ID, Note, Path string
}

// QueueUpload records a file to upload as attachment a (its ID chosen
// here), and shows it in the replica as pending right away.
func (r *Replica) QueueUpload(a protocol.Attachment, path string) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	a.Pending, a.Local = true, path
	if a.Created == "" {
		a.Created = pbTime(r.Now())
	}
	rec, err := toRecord(a)
	if err != nil {
		return err
	}
	return r.tx(func(tx *sql.Tx) error {
		if err := store(tx, protocol.Attachments, rec); err != nil {
			return err
		}
		b, _ := json.Marshal(rec)
		if _, err := tx.Exec("INSERT INTO uploads (id, note, path, record, created) VALUES (?, ?, ?, ?, ?)",
			a.ID, a.Note, path, string(b), a.Created); err != nil {
			return err
		}
		return r.touch(tx, a.Note)
	})
}

// PendingUploads lists queued files, oldest first.
func (r *Replica) PendingUploads() ([]Upload, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	rows, err := r.db.Query("SELECT id, note, path FROM uploads ORDER BY created, id")
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Upload
	for rows.Next() {
		var u Upload
		if err := rows.Scan(&u.ID, &u.Note, &u.Path); err != nil {
			return nil, err
		}
		out = append(out, u)
	}
	return out, rows.Err()
}

// FinishUpload ends a queued upload: with the server's record it replaces
// the pending one; with nil (the server refused it) the attachment goes.
func (r *Replica) FinishUpload(id string, server *protocol.Attachment) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.tx(func(tx *sql.Tx) error {
		if _, err := tx.Exec("DELETE FROM uploads WHERE id = ?", id); err != nil {
			return err
		}
		if server == nil {
			_, err := tx.Exec("DELETE FROM records WHERE collection = ? AND id = ?", protocol.Attachments, id)
			return err
		}
		rec, err := toRecord(*server)
		if err != nil {
			return err
		}
		return store(tx, protocol.Attachments, rec)
	})
}

// ApplyChanges merges feed changes and records the new cursor, atomically.
func (r *Replica) ApplyChanges(changes []protocol.Change, cursor int64) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.tx(func(tx *sql.Tx) error {
		for _, c := range changes {
			if err := r.applyChange(tx, c); err != nil {
				return fmt.Errorf("change %d: %w", c.Seq, err)
			}
		}
		return setMeta(tx, MetaCursor, strconv.FormatInt(cursor, 10))
	})
}

func (r *Replica) applyChange(tx *sql.Tx, c protocol.Change) error {
	switch c.Kind {
	case protocol.KindRevoke:
		_, err := tx.Exec("DELETE FROM records WHERE note = ?", c.Record)
		return err
	case protocol.KindRemove:
		_, err := tx.Exec("DELETE FROM records WHERE collection = ? AND id = ?", c.Collection, c.Record)
		return err
	case protocol.KindRecord:
		in := record{}
		if err := json.Unmarshal(c.Value, &in); err != nil {
			return err
		}
		cur, err := load(tx, c.Collection, keyOf(c.Collection, in))
		if err != nil {
			return err
		}
		merged := mergeRecord(cur, in)
		if err := store(tx, c.Collection, merged); err != nil {
			return err
		}
		if c.Collection != protocol.Notes {
			return r.touch(tx, noteOf(c.Collection, merged))
		}
		return nil
	case protocol.KindSet:
		cur, err := load(tx, c.Collection, c.Record)
		if err != nil || cur == nil {
			// A set for a record we never saw: the snapshot or record change
			// carrying it will arrive (or a resync will).
			return err
		}
		if setField(cur, c.Field, c.Value, c.HLC) {
			if err := store(tx, c.Collection, cur); err != nil {
				return err
			}
			return r.touch(tx, noteOf(c.Collection, cur))
		}
	}
	return nil
}

// mergeRecord folds an incoming whole record into the local one. Fields with
// clocks keep whichever write is newer; fields without (id, owner, file,
// created) come from the server.
func mergeRecord(cur, in record) record {
	if cur == nil {
		return in
	}
	curC, inC := cur.clocks(), in.clocks()
	for k, v := range in {
		if k == "clocks" {
			continue
		}
		if h, ok := inC[k]; ok {
			if h > curC[k] {
				cur[k] = v
				curC[k] = h
			}
			continue
		}
		if _, clocked := curC[k]; !clocked {
			cur[k] = v
		}
	}
	cur.setClocks(curC)
	return cur
}

// setField applies one write if its clock is newer than the field's.
func setField(rec record, field string, value json.RawMessage, h string) bool {
	c := rec.clocks()
	if h <= c[field] {
		return false
	}
	rec[field] = value
	c[field] = h
	rec.setClocks(c)
	return true
}

// Queued is an outbox entry.
type Queued struct {
	Seq int64
	Op  protocol.Op
}

// ApplyLocal applies this device's ops to the replica and queues them for
// the server. me is the signed-in user (owner of new notes). An op that is
// already stale locally is reported and not queued: the server would refuse
// it too.
func (r *Replica) ApplyLocal(ops []protocol.Op, me string) ([]protocol.OpResult, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	results := make([]protocol.OpResult, len(ops))
	err := r.tx(func(tx *sql.Tx) error {
		for i, op := range ops {
			res, err := r.applyOp(tx, op, me)
			if err != nil {
				return err
			}
			results[i] = res
			if !res.Applied {
				continue
			}
			b, _ := json.Marshal(op)
			if _, err := tx.Exec("INSERT INTO outbox (op, created) VALUES (?, ?)", string(b), pbTime(r.Now())); err != nil {
				return err
			}
		}
		return nil
	})
	return results, err
}

func (r *Replica) applyOp(tx *sql.Tx, op protocol.Op, me string) (protocol.OpResult, error) {
	cur, err := load(tx, op.Collection, op.ID)
	if err != nil {
		return protocol.OpResult{}, err
	}
	if cur == nil {
		cur, err = blank(op, me, pbTime(r.Now()))
		if err != nil {
			return protocol.OpResult{Error: err.Error()}, nil
		}
	}
	if !setField(cur, op.Field, op.Value, op.HLC) {
		return protocol.OpResult{Stale: true}, nil
	}
	if err := store(tx, op.Collection, cur); err != nil {
		return protocol.OpResult{}, err
	}
	if err := r.touch(tx, noteOf(op.Collection, cur)); err != nil {
		return protocol.OpResult{}, err
	}
	return protocol.OpResult{Applied: true}, nil
}

// blank is the starting point for a record created locally.
func blank(op protocol.Op, me, now string) (record, error) {
	var v any
	switch op.Collection {
	case protocol.Notes:
		v = protocol.Note{ID: op.ID, Owner: me, Kind: "text", Created: now, Updated: now}
	case protocol.Items:
		v = protocol.Item{ID: op.ID}
	case protocol.Labels:
		v = protocol.Label{ID: op.ID}
	case protocol.NoteState:
		v = protocol.State{Note: op.ID, Labels: []string{}}
	default:
		return nil, fmt.Errorf("cannot create %s locally", op.Collection)
	}
	return toRecord(v)
}

func pendingOps(q interface {
	Query(string, ...any) (*sql.Rows, error)
}, limit int) ([]Queued, error) {
	query := "SELECT seq, op FROM outbox ORDER BY seq"
	if limit > 0 {
		query += " LIMIT " + strconv.Itoa(limit)
	}
	rows, err := q.Query(query)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Queued
	for rows.Next() {
		var q Queued
		var raw string
		if err := rows.Scan(&q.Seq, &raw); err != nil {
			return nil, err
		}
		if err := json.Unmarshal([]byte(raw), &q.Op); err != nil {
			return nil, err
		}
		out = append(out, q)
	}
	return out, rows.Err()
}

// Pending returns up to limit queued ops, oldest first (0 = all).
func (r *Replica) Pending(limit int) ([]Queued, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	return pendingOps(r.db, limit)
}

// PendingCount is the outbox length.
func (r *Replica) PendingCount() (int, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	var n int
	err := r.db.QueryRow("SELECT COUNT(*) FROM outbox").Scan(&n)
	return n, err
}

// Ack removes sent ops from the outbox.
func (r *Replica) Ack(seqs ...int64) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.tx(func(tx *sql.Tx) error {
		for _, s := range seqs {
			if _, err := tx.Exec("DELETE FROM outbox WHERE seq = ?", s); err != nil {
				return err
			}
		}
		return nil
	})
}

// Record returns one stored record decoded into dst (a protocol type), and
// whether it exists.
func (r *Replica) Record(collection, id string, dst any) (bool, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	rec, err := load(r.db, collection, id)
	if err != nil || rec == nil {
		return false, err
	}
	b, _ := json.Marshal(rec)
	return true, json.Unmarshal(b, dst)
}

// Snapshot renders the replica in the server's snapshot shape, leaving out
// deleted records and everything under a deleted note.
func (r *Replica) Snapshot() (*protocol.Snapshot, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	s := &protocol.Snapshot{
		Notes: []protocol.Note{}, Items: []protocol.Item{}, Members: []protocol.Member{},
		State: []protocol.State{}, Labels: []protocol.Label{}, Attachments: []protocol.Attachment{},
	}
	var cursor string
	_ = r.db.QueryRow("SELECT value FROM meta WHERE key = 'cursor'").Scan(&cursor)
	s.Seq, _ = strconv.ParseInt(cursor, 10, 64)

	rows, err := r.db.Query("SELECT collection, data FROM records ORDER BY collection, id")
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	type raw struct {
		collection string
		data       []byte
	}
	var all []raw
	for rows.Next() {
		var x raw
		var d string
		if err := rows.Scan(&x.collection, &d); err != nil {
			return nil, err
		}
		x.data = []byte(d)
		all = append(all, x)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}

	live := map[string]bool{}
	for _, x := range all {
		if x.collection != protocol.Notes {
			continue
		}
		var n protocol.Note
		if err := json.Unmarshal(x.data, &n); err != nil {
			return nil, err
		}
		if !n.Deleted {
			live[n.ID] = true
			s.Notes = append(s.Notes, n)
		}
	}
	for _, x := range all {
		var err error
		switch x.collection {
		case protocol.Items:
			var v protocol.Item
			if err = json.Unmarshal(x.data, &v); err == nil && !v.Deleted && live[v.Note] {
				s.Items = append(s.Items, v)
			}
		case protocol.Members:
			var v protocol.Member
			if err = json.Unmarshal(x.data, &v); err == nil && live[v.Note] {
				s.Members = append(s.Members, v)
			}
		case protocol.NoteState:
			var v protocol.State
			if err = json.Unmarshal(x.data, &v); err == nil && live[v.Note] {
				if v.Labels == nil {
					v.Labels = []string{}
				}
				s.State = append(s.State, v)
			}
		case protocol.Labels:
			var v protocol.Label
			if err = json.Unmarshal(x.data, &v); err == nil && !v.Deleted {
				s.Labels = append(s.Labels, v)
			}
		case protocol.Attachments:
			var v protocol.Attachment
			if err = json.Unmarshal(x.data, &v); err == nil && !v.Deleted && live[v.Note] {
				s.Attachments = append(s.Attachments, v)
			}
		}
		if err != nil {
			return nil, err
		}
	}
	return s, nil
}
