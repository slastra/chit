package daemon

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/slastra/chit/internal/capture"
	"github.com/slastra/chit/internal/config"
	"github.com/slastra/chit/internal/notes"
	"github.com/slastra/chit/internal/protocol"
	"github.com/slastra/chit/internal/replica"
	"github.com/slastra/chit/internal/sock"
)

type fakeNotifier struct {
	mu     sync.Mutex
	shown  []Toast
	acts   []func(string)
	closed []uint32
}

func (f *fakeNotifier) Show(_ context.Context, t Toast, on func(string)) (uint32, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.shown = append(f.shown, t)
	f.acts = append(f.acts, on)
	return uint32(len(f.shown)), nil
}

func (f *fakeNotifier) Close(id uint32) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.closed = append(f.closed, id)
	return nil
}

const (
	me       = "shaun0000000001"
	angelica = "angelica0000001"
	listID   = "groceries000001"
	itemID   = "milk00000000001"
)

func raw(v any) json.RawMessage { b, _ := json.Marshal(v); return b }

func newDaemon(t *testing.T, n Notifier) *Daemon {
	t.Helper()
	rep, err := replica.Open(filepath.Join(t.TempDir(), "replica.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { rep.Close() })
	if err := rep.SetMeta(replica.MetaUser, me); err != nil {
		t.Fatal(err)
	}
	err = rep.ReplaceAll(&protocol.Snapshot{
		Seq: 5,
		Notes: []protocol.Note{{ID: listID, Owner: me, Kind: "list", Title: "Groceries",
			Clocks: protocol.Clocks{"title": "1795651200000-0000-srv"}}},
		Items: []protocol.Item{{ID: itemID, Note: listID, Text: "milk", Order: "1",
			Clocks: protocol.Clocks{"text": "1795651200000-0000-srv"}}},
		Members: []protocol.Member{{ID: "member000000001", Note: listID, User: angelica, Role: "editor"}},
	})
	if err != nil {
		t.Fatal(err)
	}
	cfg := &config.Config{Server: "http://127.0.0.1:1", User: protocol.Person{ID: me, Name: "Shaun"}}
	d, err := New(Options{
		Replica: rep, Socket: filepath.Join(t.TempDir(), "chit.sock"), Notifier: n,
		LoadConfig: func() (*config.Config, error) { return cfg, nil },
		Logf:       t.Logf,
	})
	if err != nil {
		t.Fatal(err)
	}
	d.cfg = cfg
	d.notes.names[angelica] = "Angelica"
	return d
}

func TestActivityToastsGroupPerPersonAndNote(t *testing.T) {
	f := &fakeNotifier{}
	d := newDaemon(t, f)
	d.notes.window = time.Hour // only flushAll shows them
	set := func(by, field string, v any) protocol.Change {
		return protocol.Change{Kind: protocol.KindSet, Collection: protocol.Items, Record: itemID, Field: field, Value: raw(v), HLC: "1795651300000-0000-pix", By: by}
	}
	d.notes.saw(set(angelica, "checked", true), false)
	d.notes.saw(protocol.Change{Kind: protocol.KindRecord, Collection: protocol.Items, Record: "eggs00000000001",
		Value: raw(protocol.Item{ID: "eggs00000000001", Note: listID, Text: "eggs"}), By: angelica}, false)
	d.notes.saw(set(me, "checked", false), false)      // mine from another device: no toast
	d.notes.saw(set(angelica, "checked", false), true) // local: no toast
	d.notes.flushAll()

	if len(f.shown) != 1 {
		t.Fatalf("toasts = %+v, want 1", f.shown)
	}
	got := f.shown[0]
	if got.Summary != "Groceries" || !strings.Contains(got.Body, `Angelica checked "milk"`) || !strings.Contains(got.Body, `Angelica added "eggs"`) {
		t.Fatalf("toast = %+v", got)
	}
}

func TestActivityToastsCanBeTurnedOff(t *testing.T) {
	f := &fakeNotifier{}
	d := newDaemon(t, f)
	off := false
	d.cfg.ActivityToasts = &off
	d.notes.saw(protocol.Change{Kind: protocol.KindSet, Collection: protocol.Items, Record: itemID, Field: "checked", Value: raw(true), HLC: "1795651300000-0000-pix", By: angelica}, false)
	d.notes.flushAll()
	if len(f.shown) != 0 {
		t.Fatalf("toast shown with activity_toasts off: %+v", f.shown)
	}
}

func TestQuietHoldsActivity(t *testing.T) {
	f := &fakeNotifier{}
	d := newDaemon(t, f)
	d.notes.quiet(time.Hour)
	d.notes.saw(protocol.Change{Kind: protocol.KindSet, Collection: protocol.Items, Record: itemID, Field: "checked", Value: raw(true), HLC: "1795651300000-0000-pix", By: angelica}, false)
	d.notes.flushAll()
	if len(f.shown) != 0 {
		t.Fatal("toast shown during quiet")
	}
}

func setReminder(t *testing.T, d *Daemon, at time.Time) {
	t.Helper()
	if _, err := d.ApplyLocal([]protocol.Op{d.op(protocol.NoteState, listID, "reminder", at.UTC().Format(time.RFC3339))}); err != nil {
		t.Fatal(err)
	}
}

func TestReminderFiresOnceAndDoneSyncs(t *testing.T) {
	f := &fakeNotifier{}
	d := newDaemon(t, f)
	setReminder(t, d, time.Now().Add(-time.Minute))

	d.notes.checkReminders()
	d.notes.checkReminders() // a second pass (or a restart) must not refire
	if len(f.shown) != 1 {
		t.Fatalf("reminder toasts = %d, want 1", len(f.shown))
	}
	if !f.shown[0].Critical || len(f.shown[0].Actions) != 2 || !strings.Contains(f.shown[0].Body, "Groceries") {
		t.Fatalf("toast = %+v", f.shown[0])
	}

	f.acts[0]("done")
	var st protocol.State
	if ok, _ := d.rep.Record(protocol.NoteState, listID, &st); !ok || !st.ReminderDone {
		t.Fatalf("state after Done = %+v", st)
	}
	queued, _ := d.rep.Pending(0)
	if len(queued) != 2 || queued[1].Op.Field != "reminder_done" {
		t.Fatalf("outbox = %+v", queued)
	}
}

func TestReminderSnooze(t *testing.T) {
	f := &fakeNotifier{}
	d := newDaemon(t, f)
	setReminder(t, d, time.Now().Add(-time.Minute))
	d.notes.checkReminders()
	f.acts[0]("snooze")
	next := d.notes.checkReminders()
	if until := time.Until(next); until < 9*time.Minute || until > 11*time.Minute {
		t.Fatalf("snoozed reminder due in %v, want about 10m", until)
	}
}

func TestOldReminderIsSkipped(t *testing.T) {
	f := &fakeNotifier{}
	d := newDaemon(t, f)
	setReminder(t, d, time.Now().Add(-13*time.Hour))
	d.notes.checkReminders()
	if len(f.shown) != 0 {
		t.Fatal("a reminder 13 hours late fired")
	}
}

func TestReminderDoneElsewhereClosesToast(t *testing.T) {
	f := &fakeNotifier{}
	d := newDaemon(t, f)
	setReminder(t, d, time.Now().Add(-time.Minute))
	d.notes.checkReminders()
	// The phone marks it done; the change arrives through the feed.
	if err := d.rep.ApplyChanges([]protocol.Change{{Seq: 6, Kind: protocol.KindSet, Collection: protocol.NoteState,
		Record: listID, Field: "reminder_done", Value: raw(true), HLC: d.clock.Now(), By: me}}, 6); err != nil {
		t.Fatal(err)
	}
	d.notes.checkReminders()
	if len(f.closed) != 1 || f.closed[0] != 1 {
		t.Fatalf("closed = %v, want the reminder toast", f.closed)
	}
}

func TestSocketCaptureAndState(t *testing.T) {
	d := newDaemon(t, nil)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan struct{})
	go func() { d.Run(ctx); close(done) }()
	c := sock.New(d.opts.Socket)
	deadline := time.Now().Add(3 * time.Second)
	for !c.Up(ctx) {
		if time.Now().After(deadline) {
			t.Fatal("socket never came up")
		}
		time.Sleep(20 * time.Millisecond)
	}

	r, err := c.Call(ctx, sock.Request{Op: "preview", Text: "groc: eggs, coffee"})
	if err != nil || r.Plan == nil || r.Plan.Summary != `Add "eggs", "coffee" to Groceries` {
		t.Fatalf("preview = %+v, %v", r, err)
	}
	if _, err := c.Call(ctx, sock.Request{Op: "capture", Text: "groc: eggs, coffee"}); err != nil {
		t.Fatal(err)
	}
	if _, err := c.Call(ctx, sock.Request{Op: "check", Item: itemID, On: true}); err != nil {
		t.Fatal(err)
	}
	s, err := c.Snapshot(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if len(s.Items) != 3 {
		t.Fatalf("items after capture = %+v", s.Items)
	}
	ev := d.stateEvent()
	if len(ev.Notes) != 1 || ev.Notes[0].Open != 2 || ev.Notes[0].Done != 1 || !ev.Notes[0].Shared {
		t.Fatalf("state = %+v", ev.Notes)
	}
	if n, _ := d.rep.PendingCount(); n != 7 { // 3 per new item + the check
		t.Fatalf("pending = %d, want 7", n)
	}
	cancel()
	<-done
}

func TestComposeQueuesFilesAfterTheNote(t *testing.T) {
	d := newDaemon(t, nil)
	d.opts.UploadDir = filepath.Join(t.TempDir(), "uploads")
	src := filepath.Join(t.TempDir(), "receipt.png")
	if err := os.WriteFile(src, []byte("\x89PNG\r\n\x1a\nfake"), 0o600); err != nil {
		t.Fatal(err)
	}
	s, _ := d.rep.Snapshot()
	plan, err := capture.Compose(capture.Draft{Title: "Plumber", Body: "kitchen sink", Files: []string{src}}, s)
	if err != nil {
		t.Fatal(err)
	}
	if err := d.compose(&plan, s); err != nil {
		t.Fatal(err)
	}
	// The original can go; chitd kept a copy.
	os.Remove(src)

	ups, _ := d.rep.PendingUploads()
	if len(ups) != 1 || ups[0].Note != plan.NoteID {
		t.Fatalf("uploads = %+v (note %s)", ups, plan.NoteID)
	}
	if b, err := os.ReadFile(ups[0].Path); err != nil || string(b) != "\x89PNG\r\n\x1a\nfake" {
		t.Fatalf("queued copy = %q, %v", b, err)
	}
	snap, _ := d.rep.Snapshot()
	if len(snap.Attachments) != 1 || !snap.Attachments[0].Pending || snap.Attachments[0].Name != "receipt.png" {
		t.Fatalf("attachments = %+v", snap.Attachments)
	}

	// A resync from a server that has not seen the note keeps both.
	if err := d.rep.ReplaceAll(&protocol.Snapshot{Seq: 9, Notes: s.Notes, Items: s.Items}); err != nil {
		t.Fatal(err)
	}
	snap, _ = d.rep.Snapshot()
	var title string
	for _, n := range snap.Notes {
		if n.ID == plan.NoteID {
			title = n.Title
		}
	}
	if title != "Plumber" || len(snap.Attachments) != 1 {
		t.Fatalf("after resync: note %q, attachments %+v", title, snap.Attachments)
	}

	// The server's record replaces the pending one.
	if err := d.rep.FinishUpload(ups[0].ID, &protocol.Attachment{ID: ups[0].ID, Note: plan.NoteID, File: "receipt_x1.png", Name: "receipt.png"}); err != nil {
		t.Fatal(err)
	}
	snap, _ = d.rep.Snapshot()
	if len(snap.Attachments) != 1 || snap.Attachments[0].Pending || snap.Attachments[0].File != "receipt_x1.png" {
		t.Fatalf("after upload = %+v", snap.Attachments)
	}
	if ups, _ := d.rep.PendingUploads(); len(ups) != 0 {
		t.Fatal("upload still queued")
	}
}

func TestSetIsLimitedToEditableFields(t *testing.T) {
	d := newDaemon(t, nil)
	ok := d.dispatch(context.Background(), nil, sock.Request{Op: "set", Collection: protocol.Notes, ID: listID, Field: "title", Value: raw("Weekly shop")})
	if !ok.OK {
		t.Fatalf("set title: %+v", ok)
	}
	for _, bad := range []sock.Request{
		{Op: "set", Collection: protocol.Notes, ID: listID, Field: "owner", Value: raw(angelica)},
		{Op: "set", Collection: protocol.Members, ID: "member000000001", Field: "role", Value: raw("editor")},
		{Op: "set", Collection: protocol.Notes, ID: listID, Field: "title", Value: json.RawMessage("{not json")},
	} {
		if r := d.dispatch(context.Background(), nil, bad); r.OK {
			t.Errorf("%s.%s accepted", bad.Collection, bad.Field)
		}
	}
	var n protocol.Note
	d.rep.Record(protocol.Notes, listID, &n)
	if n.Title != "Weekly shop" || n.Owner != me {
		t.Fatalf("note = %+v", n)
	}
}

func TestAddItemInsertsAfter(t *testing.T) {
	d := newDaemon(t, nil)
	last, err := d.addItem(listID, "eggs", "")
	if err != nil {
		t.Fatal(err)
	}
	mid, err := d.addItem(listID, "butter", itemID) // between milk and eggs
	if err != nil {
		t.Fatal(err)
	}
	s, _ := d.rep.Snapshot()
	items := notes.ItemsOf(s, listID)
	sort.Slice(items, func(i, j int) bool { return items[i].Order < items[j].Order })
	got := []string{items[0].ID, items[1].ID, items[2].ID}
	if got[0] != itemID || got[1] != mid || got[2] != last {
		t.Fatalf("order = %v", []string{items[0].Text, items[1].Text, items[2].Text})
	}
}

func TestFetchPendingUsesTheQueuedCopy(t *testing.T) {
	d := newDaemon(t, nil)
	d.opts.UploadDir = filepath.Join(t.TempDir(), "uploads")
	src := filepath.Join(t.TempDir(), "a.png")
	os.WriteFile(src, []byte("\x89PNG\r\n\x1a\nx"), 0o600)
	s, _ := d.rep.Snapshot()
	plan, _ := capture.Compose(capture.Draft{Body: "groceries:", Files: []string{src}}, s)
	if err := d.compose(&plan, s); err != nil {
		t.Fatal(err)
	}
	ups, _ := d.rep.PendingUploads()
	path, err := d.fetch(context.Background(), ups[0].ID, "320x320")
	if err != nil || path != ups[0].Path {
		t.Fatalf("fetch = %q, %v; want %q", path, err, ups[0].Path)
	}
	ev := d.stateEvent()
	if len(ev.Notes[0].Files) != 1 || !ev.Notes[0].Files[0].Pending || !ev.Notes[0].Files[0].Image {
		t.Fatalf("state files = %+v", ev.Notes[0].Files)
	}
}
