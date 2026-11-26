package server

import (
	"testing"

	"github.com/pocketbase/pocketbase/core"
	"github.com/pocketbase/pocketbase/tools/filesystem"

	"github.com/slastra/chit/internal/protocol"
)

// A 1x1 PNG.
var pngBytes = []byte("\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x00\x01\x00\x00\x00\x01\x08\x06\x00\x00\x00\x1f\x15\xc4\x89\x00\x00\x00\rIDATx\x9cc\xf8\x0f\x00\x00\x01\x01\x00\x05\x18\xd8N\x00\x00\x00\x00IEND\xaeB`\x82")

func (d *device) attach(noteID, id, name string, data []byte) (*protocol.Attachment, error) {
	d.env.t.Helper()
	f, err := filesystem.NewFileFromBytes(data, name)
	if err != nil {
		d.env.t.Fatal(err)
	}
	a, _, err := attach(d.env.app, d.user, d.id, noteID, id, f)
	return a, err
}

func TestAttachAndShare(t *testing.T) {
	e := newEnv(t)
	shaun := e.device(e.user("shaun"), "desk")
	angelica := e.device(e.user("angelica"), "pixel")
	note, _ := shaun.newList("Groceries", "milk")

	a, err := shaun.attach(note, newID(), "receipt.png", pngBytes)
	if err != nil {
		t.Fatal(err)
	}
	if a.Name != "receipt.png" || a.Type != "image/png" || a.Size != int64(len(pngBytes)) || a.File == "" {
		t.Fatalf("attachment = %+v", a)
	}
	if s := shaun.snapshot(); len(s.Attachments) != 1 || s.Attachments[0].ID != a.ID {
		t.Fatalf("owner snapshot attachments = %+v", s.Attachments)
	}

	// Shared later: the new member's feed carries the attachment too.
	cursor := angelica.changes(0).Seq
	if _, err := share(e.app, shaun.user, shaun.id, note, angelica.user.Id, "editor"); err != nil {
		t.Fatal(err)
	}
	found := false
	for _, c := range angelica.changes(cursor).Changes {
		if c.Collection == protocol.Attachments && c.Record == a.ID {
			found = true
		}
	}
	if !found {
		t.Fatal("new member's feed has no attachment record")
	}

	// The protected file follows the note's visibility.
	rec, err := e.app.FindRecordById(protocol.Attachments, a.ID)
	if err != nil {
		t.Fatal(err)
	}
	eve := e.user("eve")
	for _, c := range []struct {
		who  *core.Record
		want bool
	}{{angelica.user, true}, {eve, false}} {
		ok, err := e.app.CanAccessRecord(rec, &core.RequestInfo{Auth: c.who}, rec.Collection().ViewRule)
		if err != nil {
			t.Fatal(err)
		}
		if ok != c.want {
			t.Fatalf("%s can access attachment = %v, want %v", c.who.GetString("name"), ok, c.want)
		}
	}
}

func TestAttachPermissions(t *testing.T) {
	e := newEnv(t)
	shaun := e.device(e.user("shaun"), "desk")
	angelo := e.device(e.user("angelo"), "phone")
	eve := e.device(e.user("eve"), "evil")
	note, _ := shaun.newList("Chores")
	if _, err := share(e.app, shaun.user, shaun.id, note, angelo.user.Id, "viewer"); err != nil {
		t.Fatal(err)
	}
	if _, err := angelo.attach(note, newID(), "x.png", pngBytes); err == nil {
		t.Fatal("viewer uploaded an attachment")
	}
	if _, err := eve.attach(note, newID(), "x.png", pngBytes); err == nil {
		t.Fatal("stranger uploaded an attachment")
	}
	if _, err := shaun.attach(note, "BAD", "x.png", pngBytes); err == nil {
		t.Fatal("accepted a malformed id")
	}
}

func TestAttachRetryIsIdempotent(t *testing.T) {
	e := newEnv(t)
	shaun := e.device(e.user("shaun"), "desk")
	note, _ := shaun.newList("Groceries")
	id := newID()
	first, err := shaun.attach(note, id, "receipt.png", pngBytes)
	if err != nil {
		t.Fatal(err)
	}
	again, err := shaun.attach(note, id, "receipt.png", pngBytes)
	if err != nil {
		t.Fatal(err)
	}
	if again.File != first.File || len(shaun.snapshot().Attachments) != 1 {
		t.Fatalf("retry made a second file: %+v vs %+v", first, again)
	}
}

func TestRemoveAttachmentByOp(t *testing.T) {
	e := newEnv(t)
	shaun := e.device(e.user("shaun"), "desk")
	angelo := e.device(e.user("angelo"), "phone")
	note, _ := shaun.newList("Groceries")
	if _, err := share(e.app, shaun.user, shaun.id, note, angelo.user.Id, "viewer"); err != nil {
		t.Fatal(err)
	}
	a, err := shaun.attach(note, newID(), "receipt.png", pngBytes)
	if err != nil {
		t.Fatal(err)
	}
	if r := angelo.send(op(protocol.Attachments, a.ID, "deleted", true, angelo.clock.Now())); r.Results[0].Applied {
		t.Fatal("viewer removed an attachment")
	}
	if r := shaun.send(op(protocol.Attachments, a.ID, "name", "x", shaun.clock.Now())); r.Results[0].Applied {
		t.Fatal("renamed an attachment through ops")
	}
	shaun.mustApply(op(protocol.Attachments, a.ID, "deleted", true, shaun.clock.Now()))
	if s := shaun.snapshot(); len(s.Attachments) != 0 {
		t.Fatalf("removed attachment still in snapshot: %+v", s.Attachments)
	}
	if r := shaun.send(op(protocol.Attachments, newID(), "deleted", false, shaun.clock.Now())); r.Results[0].Applied {
		t.Fatal("created an attachment through ops")
	}
}
