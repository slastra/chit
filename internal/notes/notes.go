// Package notes holds lookups over a snapshot shared by the CLI and chitd:
// fuzzy matching by name, titles, and per-note slices.
package notes

import (
	"fmt"
	"strings"

	"github.com/slastra/chit/internal/order"
	"github.com/slastra/chit/internal/protocol"
)

// Match picks one candidate for query: an exact id, then a case-insensitive
// exact name, then a prefix, then a substring. More than one hit at the
// first tier that has any is an error that lists them.
func Match[T any](what, query string, all []T, id func(T) string, name func(T) string) (T, error) {
	var zero T
	q := strings.ToLower(strings.TrimSpace(query))
	for _, c := range all {
		if id(c) == query {
			return c, nil
		}
	}
	tiers := []func(string) bool{
		func(n string) bool { return n == q },
		func(n string) bool { return strings.HasPrefix(n, q) },
		func(n string) bool { return strings.Contains(n, q) },
	}
	for _, hit := range tiers {
		var found []T
		for _, c := range all {
			if hit(strings.ToLower(name(c))) {
				found = append(found, c)
			}
		}
		switch len(found) {
		case 0:
			continue
		case 1:
			return found[0], nil
		default:
			var b strings.Builder
			fmt.Fprintf(&b, "%q matches %d %ss, use more of the name or the id:", query, len(found), what)
			for _, c := range found {
				fmt.Fprintf(&b, "\n  %s  %s", id(c), name(c))
			}
			return zero, fmt.Errorf("%s", b.String())
		}
	}
	return zero, fmt.Errorf("no %s matches %q", what, query)
}

func Title(n protocol.Note) string {
	if n.Title != "" {
		return n.Title
	}
	body := strings.TrimSpace(n.Body)
	if i := strings.IndexByte(body, '\n'); i >= 0 {
		body = body[:i]
	}
	if len(body) > 40 {
		body = body[:40] + "…"
	}
	if body == "" {
		return "(untitled)"
	}
	return body
}

// FindNote resolves a note, preferring ones not in the trash.
func FindNote(s *protocol.Snapshot, query string) (protocol.Note, error) {
	var live, trashed []protocol.Note
	for _, n := range s.Notes {
		if n.Trashed == "" {
			live = append(live, n)
		} else {
			trashed = append(trashed, n)
		}
	}
	n, err := Match("note", query, live, func(n protocol.Note) string { return n.ID }, Title)
	if err == nil || len(trashed) == 0 || !strings.HasPrefix(err.Error(), "no note") {
		return n, err
	}
	return Match("note", query, trashed, func(n protocol.Note) string { return n.ID }, Title)
}

func ItemsOf(s *protocol.Snapshot, noteID string) []protocol.Item {
	var out []protocol.Item
	for _, it := range s.Items {
		if it.Note == noteID && !it.Deleted {
			out = append(out, it)
		}
	}
	return out
}

func FindItem(s *protocol.Snapshot, noteID, query string) (protocol.Item, error) {
	return Match("item", query, ItemsOf(s, noteID), func(i protocol.Item) string { return i.ID }, func(i protocol.Item) string { return i.Text })
}

func FindPerson(people []protocol.Person, query string) (protocol.Person, error) {
	p, err := Match("person", query, people, func(p protocol.Person) string { return p.ID }, func(p protocol.Person) string { return p.Name })
	if err == nil {
		return p, nil
	}
	if byEmail, err2 := Match("person", query, people, func(p protocol.Person) string { return p.ID }, func(p protocol.Person) string { return p.Email }); err2 == nil {
		return byEmail, nil
	}
	return p, err
}

func StateOf(s *protocol.Snapshot, noteID string) protocol.State {
	for _, st := range s.State {
		if st.Note == noteID {
			return st
		}
	}
	return protocol.State{Note: noteID}
}

func AttachmentsOf(s *protocol.Snapshot, noteID string) []protocol.Attachment {
	var out []protocol.Attachment
	for _, a := range s.Attachments {
		if a.Note == noteID && !a.Deleted {
			out = append(out, a)
		}
	}
	return out
}

func FindAttachment(s *protocol.Snapshot, noteID, query string) (protocol.Attachment, error) {
	return Match("attachment", query, AttachmentsOf(s, noteID),
		func(a protocol.Attachment) string { return a.ID },
		func(a protocol.Attachment) string { return a.Name })
}

func MembersOf(s *protocol.Snapshot, noteID string) []protocol.Member {
	var out []protocol.Member
	for _, m := range s.Members {
		if m.Note == noteID {
			out = append(out, m)
		}
	}
	return out
}

func DisplayName(p protocol.Person) string {
	if p.Name != "" {
		return p.Name
	}
	return p.Email
}

// Names maps user id to display name.
func Names(people []protocol.Person) map[string]string {
	m := map[string]string{}
	for _, p := range people {
		m[p.ID] = DisplayName(p)
	}
	return m
}

// BoardBefore reports whether note a comes before note b on a person's
// board (sa and sb are their states): pinned notes first; within a
// section, notes with no place yet (no valid order key) on top, newest
// first, then the placed ones by key. The app sorts the same way
// (app/lib/core/board_order.dart).
func BoardBefore(a, b protocol.Note, sa, sb protocol.State) bool {
	if sa.Pinned != sb.Pinned {
		return sa.Pinned
	}
	ka, kb := boardKey(sa), boardKey(sb)
	if (ka == "") != (kb == "") {
		return ka == ""
	}
	if ka != kb {
		return ka < kb
	}
	if a.Created != b.Created {
		return a.Created > b.Created
	}
	return a.ID > b.ID
}

func boardKey(st protocol.State) string {
	if order.Valid(st.Order) {
		return st.Order
	}
	return ""
}
