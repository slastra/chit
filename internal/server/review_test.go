package server

import (
	"errors"
	"testing"

	"github.com/slastra/chit/internal/protocol"
)

// A batch that names a note's items or state before the note itself still
// creates the note first.
func TestBatchCreatesNotesBeforeWhatHangsOnThem(t *testing.T) {
	e := newEnv(t)
	shaun := e.device(e.user("shaun"), "desk")
	note, item := newID(), newID()
	shaun.mustApply(
		op(protocol.Items, item, "note", note, shaun.clock.Now()),
		op(protocol.Items, item, "text", "milk", shaun.clock.Now()),
		op(protocol.NoteState, note, "pinned", true, shaun.clock.Now()),
		op(protocol.Notes, note, "kind", "list", shaun.clock.Now()),
	)
	snap := shaun.snapshot()
	if len(snap.Notes) != 1 || len(snap.Items) != 1 || len(snap.State) != 1 || !snap.State[0].Pinned {
		t.Fatalf("snapshot after an out-of-order batch: %+v", snap)
	}
}

// A date field takes RFC 3339 (or "" to clear), and refuses anything else
// rather than storing it as cleared.
func TestDatesMustBeDates(t *testing.T) {
	e := newEnv(t)
	shaun := e.device(e.user("shaun"), "desk")
	note, _ := shaun.newList("Dentist")
	r := shaun.send(
		op(protocol.NoteState, note, "reminder", "tomorrow-ish", shaun.clock.Now()),
		op(protocol.Notes, note, "trashed", "2026-13-45", shaun.clock.Now()),
	)
	for i, res := range r.Results {
		if res.Applied || res.Error == "" {
			t.Errorf("op %d = %+v, want an error", i, res)
		}
	}
	shaun.mustApply(
		op(protocol.NoteState, note, "reminder", "2026-12-01T09:00:00Z", shaun.clock.Now()),
		op(protocol.NoteState, note, "reminder", "2026-12-01T09:00:00.000Z", shaun.clock.Now()),
		op(protocol.NoteState, note, "reminder", "", shaun.clock.Now()),
	)
}

// A deleted note takes no new files and no new members.
func TestDeletedNoteTakesNoFilesOrMembers(t *testing.T) {
	e := newEnv(t)
	shaun := e.device(e.user("shaun"), "desk")
	angelica := e.user("angelica")
	note, _ := shaun.newList("Old")
	shaun.mustApply(op(protocol.Notes, note, "deleted", true, shaun.clock.Now()))
	if _, err := shaun.attach(note, newID(), "x.png", pngBytes); !errors.Is(err, errNotFound) {
		t.Errorf("attach to a deleted note: %v, want not found", err)
	}
	if _, err := share(e.app, shaun.user, shaun.id, note, angelica.Id, "editor"); !errors.Is(err, errNotFound) {
		t.Errorf("share a deleted note: %v, want not found", err)
	}
}
