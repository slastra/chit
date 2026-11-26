// Package capture turns one typed line into note edits, for lastshell's
// quick-capture box (and later voice): "groceries: milk, eggs" adds to a
// list, anything else becomes a new note.
package capture

import (
	"encoding/json"
	"errors"
	"fmt"
	"strings"

	"github.com/slastra/chit/internal/notes"
	"github.com/slastra/chit/internal/order"
	"github.com/slastra/chit/internal/protocol"
)

// Plan kinds.
const (
	AddItems   = "add-items"
	AppendText = "append-text"
	NewNote    = "new-note"
)

type Plan struct {
	Kind    string   `json:"kind"`
	NoteID  string   `json:"note,omitempty"`
	Target  string   `json:"target,omitempty"` // the target note's title
	Items   []string `json:"items,omitempty"`
	Title   string   `json:"title,omitempty"`
	Text    string   `json:"text,omitempty"`
	Summary string   `json:"summary"`
}

// ErrEmpty means there is nothing to save.
var ErrEmpty = errors.New("nothing to save")

// Parse decides what text does. A "name: rest" line targets an existing note
// only when name is the note's exact title or a prefix of exactly one title
// (two characters at least), so ordinary sentences with a colon in them
// ("re: taxes", "call at 3:30") still become new notes.
func Parse(text string, snap *protocol.Snapshot) (Plan, error) {
	text = strings.TrimSpace(text)
	if text == "" {
		return Plan{}, ErrEmpty
	}
	if i := strings.Index(text, ":"); i > 0 {
		name, rest := strings.TrimSpace(text[:i]), strings.TrimSpace(text[i+1:])
		if rest != "" && !strings.Contains(name, "\n") {
			if n, ok, err := target(snap, name); err != nil {
				return Plan{}, err
			} else if ok {
				return planFor(n, rest), nil
			}
		}
	}
	title, body := "", text
	if i := strings.Index(text, "\n"); i >= 0 {
		title, body = strings.TrimSpace(text[:i]), strings.TrimSpace(text[i+1:])
	}
	p := Plan{Kind: NewNote, Title: title, Text: body, Summary: "New note"}
	if title != "" {
		p.Summary = fmt.Sprintf("New note %q", title)
	}
	return p, nil
}

func planFor(n protocol.Note, rest string) Plan {
	if n.Kind == "list" {
		var items []string
		for _, part := range strings.FieldsFunc(rest, func(r rune) bool { return r == ',' || r == '\n' }) {
			if t := strings.TrimSpace(part); t != "" {
				items = append(items, t)
			}
		}
		quoted := make([]string, len(items))
		for i, it := range items {
			quoted[i] = fmt.Sprintf("%q", it)
		}
		return Plan{Kind: AddItems, NoteID: n.ID, Target: notes.Title(n), Items: items,
			Summary: fmt.Sprintf("Add %s to %s", strings.Join(quoted, ", "), notes.Title(n))}
	}
	return Plan{Kind: AppendText, NoteID: n.ID, Target: notes.Title(n), Text: rest,
		Summary: fmt.Sprintf("Add a line to %s", notes.Title(n))}
}

// target finds the note name points at, among notes not in the trash.
func target(snap *protocol.Snapshot, name string) (protocol.Note, bool, error) {
	q := strings.ToLower(name)
	var exact, prefix []protocol.Note
	for _, n := range snap.Notes {
		if n.Trashed != "" || n.Title == "" {
			continue
		}
		t := strings.ToLower(n.Title)
		switch {
		case t == q:
			exact = append(exact, n)
		case len(q) >= 2 && strings.HasPrefix(t, q):
			prefix = append(prefix, n)
		}
	}
	switch {
	case len(exact) == 1:
		return exact[0], true, nil
	case len(exact) > 1:
		return protocol.Note{}, false, fmt.Errorf("%d notes are called %q", len(exact), name)
	case len(prefix) == 1:
		return prefix[0], true, nil
	case len(prefix) > 1:
		titles := make([]string, len(prefix))
		for i, n := range prefix {
			titles[i] = n.Title
		}
		return protocol.Note{}, false, fmt.Errorf("%q could be %s", name, strings.Join(titles, " or "))
	}
	return protocol.Note{}, false, nil
}

// Ops turns a plan into ops. now issues HLCs and newID record ids.
func (p Plan) Ops(snap *protocol.Snapshot, now func() string, newID func() string) []protocol.Op {
	op := func(collection, id, field string, v any) protocol.Op {
		return protocol.Op{Collection: collection, ID: id, Field: field, Value: jsonOf(v), HLC: now()}
	}
	switch p.Kind {
	case AddItems:
		last := ""
		for _, it := range notes.ItemsOf(snap, p.NoteID) {
			if it.Order > last {
				last = it.Order
			}
		}
		var ops []protocol.Op
		for _, text := range p.Items {
			last = order.After(last)
			id := newID()
			ops = append(ops,
				op(protocol.Items, id, "note", p.NoteID),
				op(protocol.Items, id, "text", text),
				op(protocol.Items, id, "order", last))
		}
		return ops
	case AppendText:
		body := p.Text
		for _, n := range snap.Notes {
			if n.ID == p.NoteID && strings.TrimSpace(n.Body) != "" {
				body = strings.TrimRight(n.Body, "\n") + "\n" + p.Text
			}
		}
		return []protocol.Op{op(protocol.Notes, p.NoteID, "body", body)}
	default:
		id := newID()
		ops := []protocol.Op{op(protocol.Notes, id, "kind", "text")}
		if p.Title != "" {
			ops = append(ops, op(protocol.Notes, id, "title", p.Title))
		}
		if p.Text != "" {
			ops = append(ops, op(protocol.Notes, id, "body", p.Text))
		}
		return ops
	}
}

func jsonOf(v any) json.RawMessage {
	b, _ := json.Marshal(v)
	return b
}
