package server

import (
	"testing"

	"github.com/slastra/chit/internal/protocol"
)

func TestBoardOrderIsPerUserAndValidated(t *testing.T) {
	e := newEnv(t)
	shaun := e.device(e.user("shaun"), "desk")
	angelica := e.device(e.user("angelica"), "pixel")
	note, items := shaun.newList("Groceries", "milk")
	if _, err := share(e.app, shaun.user, shaun.id, note, angelica.user.Id, "editor"); err != nil {
		t.Fatal(err)
	}

	shaun.mustApply(op(protocol.NoteState, note, "order", "V", shaun.clock.Now()))
	angelica.mustApply(op(protocol.NoteState, note, "order", "1", angelica.clock.Now()))
	if s := shaun.snapshot(); len(s.State) != 1 || s.State[0].Order != "V" {
		t.Fatalf("shaun's order = %+v", s.State)
	}
	if s := angelica.snapshot(); len(s.State) != 1 || s.State[0].Order != "1" {
		t.Fatalf("angelica's order = %+v", s.State)
	}

	// "" clears a place on the board (back on top)
	shaun.mustApply(op(protocol.NoteState, note, "order", "", shaun.clock.Now()))
	if s := shaun.snapshot(); s.State[0].Order != "" {
		t.Fatalf("cleared order = %q", s.State[0].Order)
	}

	bad := []string{"a0", "a b", "ä", string(make([]byte, 65))}
	for _, k := range bad {
		r := shaun.send(op(protocol.NoteState, note, "order", k, shaun.clock.Now())).Results[0]
		if r.Applied || r.Error == "" {
			t.Errorf("order %q accepted: %+v", k, r)
		}
	}
	// an item needs a real key: it has no "no place" state
	if r := shaun.send(op(protocol.Items, items[0], "order", "", shaun.clock.Now())).Results[0]; r.Applied {
		t.Errorf("empty item order accepted: %+v", r)
	}
}
