package main

import (
	"fmt"
	"strings"

	"github.com/slastra/chit/internal/protocol"
)

// match picks one candidate for query: an exact id, then a case-insensitive
// exact name, then a prefix, then a substring. More than one hit at the
// first tier that has any is an error that lists them.
func match[T any](what, query string, all []T, id func(T) string, name func(T) string) (T, error) {
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

func noteTitle(n protocol.Note) string {
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

// findNote resolves a note, preferring ones not in the trash.
func findNote(s *protocol.Snapshot, query string) (protocol.Note, error) {
	var live, trashed []protocol.Note
	for _, n := range s.Notes {
		if n.Trashed == "" {
			live = append(live, n)
		} else {
			trashed = append(trashed, n)
		}
	}
	n, err := match("note", query, live, func(n protocol.Note) string { return n.ID }, noteTitle)
	if err == nil || len(trashed) == 0 || !strings.HasPrefix(err.Error(), "no note") {
		return n, err
	}
	return match("note", query, trashed, func(n protocol.Note) string { return n.ID }, noteTitle)
}

func itemsOf(s *protocol.Snapshot, noteID string) []protocol.Item {
	var out []protocol.Item
	for _, it := range s.Items {
		if it.Note == noteID && !it.Deleted {
			out = append(out, it)
		}
	}
	return out
}

func findItem(s *protocol.Snapshot, noteID, query string) (protocol.Item, error) {
	return match("item", query, itemsOf(s, noteID), func(i protocol.Item) string { return i.ID }, func(i protocol.Item) string { return i.Text })
}

func findPerson(people []protocol.Person, query string) (protocol.Person, error) {
	p, err := match("person", query, people, func(p protocol.Person) string { return p.ID }, func(p protocol.Person) string { return p.Name })
	if err == nil {
		return p, nil
	}
	if byEmail, err2 := match("person", query, people, func(p protocol.Person) string { return p.ID }, func(p protocol.Person) string { return p.Email }); err2 == nil {
		return byEmail, nil
	}
	return p, err
}

func stateOf(s *protocol.Snapshot, noteID string) protocol.State {
	for _, st := range s.State {
		if st.Note == noteID {
			return st
		}
	}
	return protocol.State{Note: noteID}
}
