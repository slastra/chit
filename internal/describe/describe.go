// Package describe turns change-feed entries into short sentences, for
// chit watch and chitd's activity toasts.
package describe

import (
	"encoding/json"
	"fmt"

	"github.com/slastra/chit/internal/notes"
	"github.com/slastra/chit/internal/protocol"
)

type item struct{ note, text string }

// Describer turns feed changes into sentences, tracking titles and item
// text so later changes can name what they touch. Feed it every change in
// order, even ones whose sentence is not shown.
type Describer struct {
	me     string
	names  map[string]string
	titles map[string]string
	items  map[string]item
	shares map[string]protocol.Member // by membership id, as last announced
	files  map[string]protocol.Attachment
}

// New starts a Describer from a snapshot. names maps user id to display
// name; me is the reader, who is called "You".
func New(snap *protocol.Snapshot, names map[string]string, me string) *Describer {
	w := &Describer{me: me, names: names, titles: map[string]string{}, items: map[string]item{}, shares: map[string]protocol.Member{}, files: map[string]protocol.Attachment{}}
	for _, n := range snap.Notes {
		w.titles[n.ID] = notes.Title(n)
	}
	for _, a := range snap.Attachments {
		w.files[a.ID] = a
	}
	for _, m := range snap.Members {
		w.shares[m.ID] = m
	}
	for _, it := range snap.Items {
		w.items[it.ID] = item{note: it.Note, text: it.Text}
	}
	return w
}

func (w *Describer) who(id string) string {
	if id == w.me {
		return "You"
	}
	if n, ok := w.names[id]; ok {
		return n
	}
	return "Someone"
}

func (w *Describer) title(noteID string) string {
	if t, ok := w.titles[noteID]; ok {
		return t
	}
	return "a note"
}

// NoteOf reports which note a change belongs to, as far as the Describer
// knows, for grouping sentences per note.
func (w *Describer) NoteOf(c protocol.Change) string {
	switch c.Collection {
	case protocol.Notes, protocol.NoteState:
		return c.Record
	case protocol.Items:
		if c.Kind == protocol.KindRecord {
			var it protocol.Item
			_ = json.Unmarshal(c.Value, &it)
			return it.Note
		}
		return w.items[c.Record].note
	case protocol.Attachments:
		if c.Kind == protocol.KindRecord {
			var a protocol.Attachment
			_ = json.Unmarshal(c.Value, &a)
			return a.Note
		}
		return w.files[c.Record].Note
	case protocol.Members:
		if m, ok := w.shares[c.Record]; ok {
			return m.Note
		}
		var m protocol.Member
		_ = json.Unmarshal(c.Value, &m)
		return m.Note
	}
	return ""
}

// Title is the note's current title as the Describer knows it.
func (w *Describer) Title(noteID string) string { return w.title(noteID) }

// Who names a user: "You" for the reader.
func (w *Describer) Who(id string) string { return w.who(id) }

// Describe returns the sentence for a change, or "" for changes not worth
// a line (reorders of already-known records and the like).
func (w *Describer) Describe(c protocol.Change) string {
	who := w.who(c.By)
	str := func() string {
		var s string
		_ = json.Unmarshal(c.Value, &s)
		return s
	}
	truthy := string(c.Value) == "true"

	switch c.Kind {
	case protocol.KindRevoke:
		t := w.title(c.Record)
		delete(w.titles, c.Record)
		return fmt.Sprintf("You no longer have access to %s", t)
	case protocol.KindRemove:
		m, ok := w.shares[c.Record]
		delete(w.shares, c.Record)
		if !ok {
			return fmt.Sprintf("%s removed someone from a shared note", who)
		}
		if m.User == c.By {
			return fmt.Sprintf("%s left %s", who, w.title(m.Note))
		}
		return fmt.Sprintf("%s stopped sharing %s with %s", who, w.title(m.Note), w.who(m.User))
	case protocol.KindRecord:
		switch c.Collection {
		case protocol.Notes:
			var n protocol.Note
			_ = json.Unmarshal(c.Value, &n)
			_, known := w.titles[n.ID]
			w.titles[n.ID] = notes.Title(n)
			if known {
				return ""
			}
			kind := "note"
			if n.Kind == "list" {
				kind = "list"
			}
			return fmt.Sprintf("%s: new %s %q", who, kind, notes.Title(n))
		case protocol.Items:
			var it protocol.Item
			_ = json.Unmarshal(c.Value, &it)
			_, known := w.items[it.ID]
			w.items[it.ID] = item{note: it.Note, text: it.Text}
			if known {
				return ""
			}
			return fmt.Sprintf("%s added %q to %s", who, it.Text, w.title(it.Note))
		case protocol.Attachments:
			var a protocol.Attachment
			_ = json.Unmarshal(c.Value, &a)
			_, known := w.files[a.ID]
			w.files[a.ID] = a
			if known {
				return ""
			}
			return fmt.Sprintf("%s attached %s to %s", who, a.Name, w.title(a.Note))
		case protocol.NoteState:
			// The first per-user change on a note creates its state record.
			var st protocol.State
			_ = json.Unmarshal(c.Value, &st)
			switch {
			case st.Pinned:
				return fmt.Sprintf("%s pinned %s", who, w.title(st.Note))
			case st.Archived:
				return fmt.Sprintf("%s archived %s", who, w.title(st.Note))
			case st.Reminder != "":
				return fmt.Sprintf("%s set a reminder on %s", who, w.title(st.Note))
			}
			return ""
		case protocol.Members:
			var m protocol.Member
			_ = json.Unmarshal(c.Value, &m)
			if prev, ok := w.shares[m.ID]; ok && prev.Role == m.Role {
				return "" // a new member's copy of a share already announced
			}
			w.shares[m.ID] = m
			return fmt.Sprintf("%s shared %s with %s (%s)", who, w.title(m.Note), w.who(m.User), m.Role)
		}
	case protocol.KindSet:
		switch c.Collection {
		case protocol.Notes:
			t := w.title(c.Record)
			switch c.Field {
			case "title":
				w.titles[c.Record] = str()
				return fmt.Sprintf("%s renamed %s to %q", who, t, str())
			case "body":
				return fmt.Sprintf("%s edited %s", who, t)
			case "color":
				return fmt.Sprintf("%s colored %s %s", who, t, str())
			case "trashed":
				if str() == "" {
					return fmt.Sprintf("%s restored %s", who, t)
				}
				return fmt.Sprintf("%s moved %s to the trash", who, t)
			case "deleted":
				return fmt.Sprintf("%s deleted %s", who, t)
			}
		case protocol.Items:
			it := w.items[c.Record]
			t := w.title(it.note)
			switch c.Field {
			case "checked":
				if truthy {
					return fmt.Sprintf("%s checked %q in %s", who, it.text, t)
				}
				return fmt.Sprintf("%s unchecked %q in %s", who, it.text, t)
			case "text":
				old := it.text
				it.text = str()
				w.items[c.Record] = it
				return fmt.Sprintf("%s changed %q to %q in %s", who, old, it.text, t)
			case "deleted":
				if truthy {
					return fmt.Sprintf("%s removed %q from %s", who, it.text, t)
				}
			case "order", "indent":
				return fmt.Sprintf("%s rearranged %s", who, t)
			}
		case protocol.Attachments:
			if c.Field == "deleted" && truthy {
				a := w.files[c.Record]
				return fmt.Sprintf("%s removed %s from %s", who, a.Name, w.title(a.Note))
			}
		case protocol.NoteState:
			t := w.title(c.Record)
			switch c.Field {
			case "pinned", "archived":
				verb := map[string][2]string{"pinned": {"unpinned", "pinned"}, "archived": {"unarchived", "archived"}}[c.Field]
				if truthy {
					return fmt.Sprintf("%s %s %s", who, verb[1], t)
				}
				return fmt.Sprintf("%s %s %s", who, verb[0], t)
			case "reminder":
				return fmt.Sprintf("%s set a reminder on %s", who, t)
			}
		}
	}
	return ""
}
