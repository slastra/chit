package server

import (
	"encoding/json"
	"net/http"
	"sync"
	"time"

	"github.com/pocketbase/pocketbase/apis"
	"github.com/pocketbase/pocketbase/core"
)

// Presence is who has which note open, and who is typing in it: kept in
// memory only, never in the log, and gone when a device stops saying so.
//
// A device with a note open says so every 15 seconds (POST /presence), and
// as it types (editing). It counts as there for presenceFor after its last
// word, and as editing for editingFor after its last keystroke.
const (
	presenceFor = 40 * time.Second
	editingFor  = 8 * time.Second
)

// PresenceEvent is one device's presence on one note, as streams send it.
type PresenceEvent struct {
	Note    string `json:"note"`
	User    string `json:"user"`
	Device  string `json:"device"`
	Editing bool   `json:"editing"`
	Gone    bool   `json:"gone,omitempty"`
}

type presence struct {
	user           string
	here, editing  time.Time // until when
	editingWasSent bool
}

type presenceKey struct{ note, device string }

// presences holds every device's presence and tells the streams of changes.
type presences struct {
	mu   sync.Mutex
	now  func() time.Time
	seen map[presenceKey]*presence
	subs map[chan PresenceEvent]struct{}
}

func newPresences() *presences {
	p := &presences{now: time.Now, seen: map[presenceKey]*presence{}, subs: map[chan PresenceEvent]struct{}{}}
	go func() {
		for range time.Tick(2 * time.Second) {
			p.expire()
		}
	}()
	return p
}

func (p *presences) subscribe() chan PresenceEvent {
	ch := make(chan PresenceEvent, 64)
	p.mu.Lock()
	p.subs[ch] = struct{}{}
	p.mu.Unlock()
	return ch
}

func (p *presences) unsubscribe(ch chan PresenceEvent) {
	p.mu.Lock()
	delete(p.subs, ch)
	p.mu.Unlock()
}

// publish hands ev to every stream; one too far behind to take it misses
// it (the next word from that device sets it right). Called with p.mu held.
func (p *presences) publish(ev PresenceEvent) {
	for ch := range p.subs {
		select {
		case ch <- ev:
		default:
		}
	}
}

// set records what a device said: here (and maybe editing), or gone.
func (p *presences) set(note, user, device string, editing, gone bool) {
	p.mu.Lock()
	defer p.mu.Unlock()
	k := presenceKey{note, device}
	if gone {
		if _, ok := p.seen[k]; ok {
			delete(p.seen, k)
			p.publish(PresenceEvent{Note: note, User: user, Device: device, Gone: true})
		}
		return
	}
	now := p.now()
	cur, ok := p.seen[k]
	if !ok {
		cur = &presence{user: user}
		p.seen[k] = cur
	}
	cur.here = now.Add(presenceFor)
	if editing {
		cur.editing = now.Add(editingFor)
	}
	isEditing := cur.editing.After(now)
	// tell the streams only of what changed: arriving, starting or
	// stopping typing (a plain "still here" changes nothing they show)
	if !ok || isEditing != cur.editingWasSent {
		cur.editingWasSent = isEditing
		p.publish(PresenceEvent{Note: note, User: user, Device: device, Editing: isEditing})
	}
}

// expire drops devices that stopped saying they are there, and marks those
// that stopped typing.
func (p *presences) expire() {
	p.mu.Lock()
	defer p.mu.Unlock()
	now := p.now()
	for k, cur := range p.seen {
		switch {
		case !cur.here.After(now):
			delete(p.seen, k)
			p.publish(PresenceEvent{Note: k.note, User: cur.user, Device: k.device, Gone: true})
		case cur.editingWasSent && !cur.editing.After(now):
			cur.editingWasSent = false
			p.publish(PresenceEvent{Note: k.note, User: cur.user, Device: k.device})
		}
	}
}

// current is every presence now, for a stream that has just opened.
func (p *presences) current() []PresenceEvent {
	p.mu.Lock()
	defer p.mu.Unlock()
	now := p.now()
	out := make([]PresenceEvent, 0, len(p.seen))
	for k, cur := range p.seen {
		out = append(out, PresenceEvent{Note: k.note, User: cur.user, Device: k.device, Editing: cur.editing.After(now)})
	}
	return out
}

// handlePresence takes a device's word that it has a note open (editing,
// if it is typing), or that it has left it (gone).
func handlePresence(e *core.RequestEvent, b *Broker) error {
	var body struct {
		Note    string `json:"note"`
		Editing bool   `json:"editing"`
		Gone    bool   `json:"gone"`
	}
	if err := json.NewDecoder(e.Request.Body).Decode(&body); err != nil || !recordID.MatchString(body.Note) {
		return apis.NewBadRequestError("send {\"note\": id, \"editing\": bool, \"gone\": bool}", nil)
	}
	device := deviceOf(e)
	if device == "" {
		return apis.NewBadRequestError("name this device (X-Chit-Device)", nil)
	}
	acc, note, err := noteAccess(e.App, e.Auth.Id, body.Note)
	if err != nil {
		return err
	}
	if note == nil || acc == noAccess {
		return apis.NewNotFoundError("", nil)
	}
	b.presence.set(body.Note, e.Auth.Id, device, body.Editing && acc >= canEdit, body.Gone)
	return e.NoContent(http.StatusNoContent)
}
