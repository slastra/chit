package server

import (
	"encoding/json"
	"testing"

	"github.com/slastra/chit/internal/protocol"
)

func based(o protocol.Op, base string) protocol.Op {
	o.Base = base
	return o
}

func bodyOf(t *testing.T, d *device, note string) (string, string) {
	t.Helper()
	for _, n := range d.snapshot().Notes {
		if n.ID == note {
			return n.Body, n.Clocks["body"]
		}
	}
	t.Fatalf("no note %s", note)
	return "", ""
}

// Two people edit a note's text from the same version: both edits stay,
// and the one who wrote first hears the joined text on the feed too.
func TestConcurrentTextEditsMerge(t *testing.T) {
	e := newEnv(t)
	shaun := e.device(e.user("shaun"), "desk")
	angelica := e.device(e.user("angelica"), "pixel")
	note := newID()
	shaun.mustApply(
		op(protocol.Notes, note, "kind", "text", shaun.clock.Now()),
		op(protocol.Notes, note, "body", "Pick up brushes on Saturday.", shaun.clock.Now()),
	)
	if _, err := share(e.app, shaun.user, shaun.id, note, angelica.user.Id, "editor"); err != nil {
		t.Fatal(err)
	}
	_, base := bodyOf(t, shaun, note)
	cursor := shaun.changes(0).Seq

	// Angelica adds to the middle; Shaun, not having seen it, to the end.
	angelica.mustApply(based(op(protocol.Notes, note, "body", "Pick up brushes and a drop cloth on Saturday.", angelica.clock.Now()), base))
	r := shaun.send(based(op(protocol.Notes, note, "body", "Pick up brushes on Saturday morning.", shaun.clock.Now()), base))
	if !r.Results[0].Applied || !r.Results[0].Merged {
		t.Fatalf("second edit = %+v, want applied and merged", r.Results[0])
	}
	want := "Pick up brushes and a drop cloth on Saturday morning."
	if got, _ := bodyOf(t, shaun, note); got != want {
		t.Fatalf("body = %q, want %q", got, want)
	}
	// Shaun's own device hears the joined text (it holds only its half).
	var heard string
	for _, c := range shaun.changes(cursor).Changes {
		if c.Field == "body" {
			_ = json.Unmarshal(c.Value, &heard)
		}
	}
	if heard != want {
		t.Fatalf("shaun's feed carried %q, want %q", heard, want)
	}
}

// An edit whose clock is behind the field's (a device whose clock is slow)
// still merges rather than being dropped as stale.
func TestSlowClockEditStillMerges(t *testing.T) {
	e := newEnv(t)
	shaun := e.device(e.user("shaun"), "desk")
	note := newID()
	early := shaun.clock.Now()
	shaun.mustApply(
		op(protocol.Notes, note, "kind", "text", shaun.clock.Now()),
		op(protocol.Notes, note, "body", "milk eggs", shaun.clock.Now()),
	)
	_, base := bodyOf(t, shaun, note)
	shaun.mustApply(based(op(protocol.Notes, note, "body", "milk eggs bread", shaun.clock.Now()), base))
	r := shaun.send(based(op(protocol.Notes, note, "body", "oat milk eggs", early), base))
	if !r.Results[0].Merged {
		t.Fatalf("slow edit = %+v, want merged", r.Results[0])
	}
	if got, _ := bodyOf(t, shaun, note); got != "oat milk eggs bread" {
		t.Fatalf("body = %q", got)
	}
}

// Without a base (an old client, the CLI) the later edit wins, as before.
func TestNoBaseIsLastWriterWins(t *testing.T) {
	e := newEnv(t)
	shaun := e.device(e.user("shaun"), "desk")
	note := newID()
	shaun.mustApply(
		op(protocol.Notes, note, "kind", "text", shaun.clock.Now()),
		op(protocol.Notes, note, "body", "one", shaun.clock.Now()),
	)
	shaun.mustApply(op(protocol.Notes, note, "body", "two", shaun.clock.Now()))
	if got, _ := bodyOf(t, shaun, note); got != "two" {
		t.Fatalf("body = %q", got)
	}
}
