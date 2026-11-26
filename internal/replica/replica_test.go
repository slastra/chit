package replica

import (
	"encoding/json"
	"path/filepath"
	"testing"

	"github.com/slastra/chit/internal/hlc"
	"github.com/slastra/chit/internal/protocol"
)

func open(t *testing.T, path string) *Replica {
	t.Helper()
	r, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { r.Close() })
	return r
}

func op(collection, id, field string, v any, h string) protocol.Op {
	b, _ := json.Marshal(v)
	return protocol.Op{Collection: collection, ID: id, Field: field, Value: b, HLC: h}
}

func raw(v any) json.RawMessage { b, _ := json.Marshal(v); return b }

const me = "useruseruser001"

func seed(t *testing.T, r *Replica) {
	t.Helper()
	err := r.ReplaceAll(&protocol.Snapshot{
		Seq: 10,
		Notes: []protocol.Note{{ID: "note00000000001", Owner: me, Kind: "list", Title: "Groceries",
			Clocks: protocol.Clocks{"title": "1795651200000-0000-srv"}}},
		Items: []protocol.Item{{ID: "item00000000001", Note: "note00000000001", Text: "milk", Order: "1",
			Clocks: protocol.Clocks{"text": "1795651200000-0000-srv"}}},
	})
	if err != nil {
		t.Fatal(err)
	}
}

func TestLocalEditsQueueAndSurviveRestart(t *testing.T) {
	path := filepath.Join(t.TempDir(), "replica.db")
	r := open(t, path)
	seed(t, r)
	c := hlc.New("desk")
	c.Observe("1795651200000-0000-srv")
	res, err := r.ApplyLocal([]protocol.Op{
		op(protocol.Items, "item00000000001", "checked", true, c.Now()),
		op(protocol.Items, "item00000000002", "note", "note00000000001", c.Now()),
		op(protocol.Items, "item00000000002", "text", "eggs", c.Now()),
	}, me)
	if err != nil {
		t.Fatal(err)
	}
	for i, x := range res {
		if !x.Applied {
			t.Fatalf("op %d = %+v", i, x)
		}
	}
	r.Close()

	r2 := open(t, path)
	if n, _ := r2.PendingCount(); n != 3 {
		t.Fatalf("pending after restart = %d, want 3", n)
	}
	s, err := r2.Snapshot()
	if err != nil {
		t.Fatal(err)
	}
	if len(s.Items) != 2 || !s.Items[0].Checked || s.Items[1].Text != "eggs" {
		t.Fatalf("items = %+v", s.Items)
	}
}

func TestFeedMergesPerField(t *testing.T) {
	r := open(t, filepath.Join(t.TempDir(), "r.db"))
	seed(t, r)
	newer, older := "1795651300000-0000-pix", "1795651100000-0000-pix"
	err := r.ApplyChanges([]protocol.Change{
		{Seq: 11, Kind: protocol.KindSet, Collection: protocol.Items, Record: "item00000000001", Field: "text", Value: raw("oat milk"), HLC: newer},
		{Seq: 12, Kind: protocol.KindSet, Collection: protocol.Notes, Record: "note00000000001", Field: "title", Value: raw("stale"), HLC: older},
	}, 12)
	if err != nil {
		t.Fatal(err)
	}
	s, _ := r.Snapshot()
	if s.Items[0].Text != "oat milk" || s.Notes[0].Title != "Groceries" || s.Seq != 12 {
		t.Fatalf("snapshot = %+v", s)
	}
}

func TestRecordMergeKeepsNewerLocalField(t *testing.T) {
	r := open(t, filepath.Join(t.TempDir(), "r.db"))
	seed(t, r)
	local := "1795651400000-0000-desk"
	if _, err := r.ApplyLocal([]protocol.Op{op(protocol.Notes, "note00000000001", "title", "Weekly groceries", local)}, me); err != nil {
		t.Fatal(err)
	}
	// A whole-record copy arrives (e.g. a share snapshot) with an older title
	// but a newer color.
	in := protocol.Note{ID: "note00000000001", Owner: me, Kind: "list", Title: "Groceries", Color: "green",
		Clocks: protocol.Clocks{"title": "1795651200000-0000-srv", "color": "1795651500000-0000-srv"}}
	if err := r.ApplyChanges([]protocol.Change{{Seq: 11, Kind: protocol.KindRecord, Collection: protocol.Notes, Record: in.ID, Value: raw(in)}}, 11); err != nil {
		t.Fatal(err)
	}
	s, _ := r.Snapshot()
	if s.Notes[0].Title != "Weekly groceries" || s.Notes[0].Color != "green" {
		t.Fatalf("note = %+v", s.Notes[0])
	}
}

func TestRevokeDropsTheNoteAndChildren(t *testing.T) {
	r := open(t, filepath.Join(t.TempDir(), "r.db"))
	seed(t, r)
	st := protocol.State{Note: "note00000000001", Pinned: true, Labels: []string{}, Clocks: protocol.Clocks{"pinned": "1795651200000-0000-srv"}}
	if err := r.ApplyChanges([]protocol.Change{
		{Seq: 11, Kind: protocol.KindRecord, Collection: protocol.NoteState, Record: st.Note, Value: raw(st)},
		{Seq: 12, Kind: protocol.KindRevoke, Collection: protocol.Notes, Record: "note00000000001"},
	}, 12); err != nil {
		t.Fatal(err)
	}
	s, _ := r.Snapshot()
	if len(s.Notes)+len(s.Items)+len(s.State) != 0 {
		t.Fatalf("after revoke: %+v", s)
	}
}

func TestDeletedNoteHidesItsItems(t *testing.T) {
	r := open(t, filepath.Join(t.TempDir(), "r.db"))
	seed(t, r)
	if err := r.ApplyChanges([]protocol.Change{
		{Seq: 11, Kind: protocol.KindSet, Collection: protocol.Notes, Record: "note00000000001", Field: "deleted", Value: raw(true), HLC: "1795651300000-0000-srv"},
	}, 11); err != nil {
		t.Fatal(err)
	}
	s, _ := r.Snapshot()
	if len(s.Notes) != 0 || len(s.Items) != 0 {
		t.Fatalf("deleted note still visible: %+v", s)
	}
}

func TestResyncKeepsOfflineEdits(t *testing.T) {
	r := open(t, filepath.Join(t.TempDir(), "r.db"))
	if err := r.SetMeta(MetaUser, me); err != nil {
		t.Fatal(err)
	}
	seed(t, r)
	c := hlc.New("desk")
	c.Observe("1795651200000-0000-srv")
	newNote := "note00000000009"
	if _, err := r.ApplyLocal([]protocol.Op{
		op(protocol.Notes, newNote, "kind", "text", c.Now()),
		op(protocol.Notes, newNote, "title", "Written offline", c.Now()),
		op(protocol.Items, "item00000000001", "checked", true, c.Now()),
	}, me); err != nil {
		t.Fatal(err)
	}
	// The server snapshot knows nothing of those edits yet.
	seed(t, r)
	s, _ := r.Snapshot()
	var found bool
	for _, n := range s.Notes {
		if n.ID == newNote && n.Title == "Written offline" && n.Owner == me {
			found = true
		}
	}
	if !found || !s.Items[0].Checked {
		t.Fatalf("offline edits lost in resync: %+v", s)
	}
	if n, _ := r.PendingCount(); n != 3 {
		t.Fatalf("pending = %d, want 3", n)
	}
}

func TestStaleLocalOpIsNotQueued(t *testing.T) {
	r := open(t, filepath.Join(t.TempDir(), "r.db"))
	seed(t, r)
	res, err := r.ApplyLocal([]protocol.Op{op(protocol.Notes, "note00000000001", "title", "old", "1795651100000-0000-desk")}, me)
	if err != nil {
		t.Fatal(err)
	}
	if !res[0].Stale {
		t.Fatalf("result = %+v, want stale", res[0])
	}
	if n, _ := r.PendingCount(); n != 0 {
		t.Fatalf("stale op queued")
	}
}

func TestAck(t *testing.T) {
	r := open(t, filepath.Join(t.TempDir(), "r.db"))
	seed(t, r)
	c := hlc.New("desk")
	c.Observe("1795651200000-0000-srv")
	r.ApplyLocal([]protocol.Op{op(protocol.Items, "item00000000001", "checked", true, c.Now())}, me)
	p, _ := r.Pending(0)
	if len(p) != 1 {
		t.Fatalf("pending = %+v", p)
	}
	if err := r.Ack(p[0].Seq); err != nil {
		t.Fatal(err)
	}
	if n, _ := r.PendingCount(); n != 0 {
		t.Fatal("ack left the op queued")
	}
}
