package server

import (
	"testing"
	"time"
)

func TestPresenceComesGoesAndStopsTyping(t *testing.T) {
	p := &presences{seen: map[presenceKey]*presence{}, subs: map[chan PresenceEvent]struct{}{}}
	now := time.Unix(1_800_000_000, 0)
	p.now = func() time.Time { return now }
	ch := p.subscribe()
	next := func() PresenceEvent {
		t.Helper()
		select {
		case ev := <-ch:
			return ev
		default:
			t.Fatal("no event")
			return PresenceEvent{}
		}
	}
	quiet := func() {
		t.Helper()
		select {
		case ev := <-ch:
			t.Fatalf("unexpected %+v", ev)
		default:
		}
	}

	p.set("note00000000001", "angelica", "pixel", false, false)
	if ev := next(); ev.Editing || ev.Gone || ev.User != "angelica" {
		t.Fatalf("arrive = %+v", ev)
	}
	p.set("note00000000001", "angelica", "pixel", false, false)
	quiet() // still here: nothing new to show

	p.set("note00000000001", "angelica", "pixel", true, false)
	if ev := next(); !ev.Editing {
		t.Fatalf("typing = %+v", ev)
	}
	now = now.Add(editingFor + time.Second)
	p.expire()
	if ev := next(); ev.Editing || ev.Gone {
		t.Fatalf("stopped typing = %+v", ev)
	}
	now = now.Add(presenceFor)
	p.expire()
	if ev := next(); !ev.Gone {
		t.Fatalf("left = %+v", ev)
	}
	if len(p.current()) != 0 {
		t.Fatal("still listed after leaving")
	}
}
