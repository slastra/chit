package main

import (
	"encoding/json"
	"fmt"
	"os"
	"time"

	"github.com/spf13/cobra"

	"github.com/slastra/chit/internal/protocol"
)

func watchCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "watch",
		Short: "Print changes as they happen (Ctrl-C to stop)",
		Long: "Follow the live change feed. Each line says who changed what. With\n" +
			"--json, each change is printed as one JSON object per line.",
		Args: cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			ctx := cmd.Context()
			s, err := open(ctx)
			if err != nil {
				return err
			}
			snap, err := s.snapshot(ctx)
			if err != nil {
				return err
			}
			people, err := s.c.People(ctx)
			if err != nil {
				return err
			}
			w := newWatcher(snap, nameMap(people), s.cfg.User.ID)
			if !jsonOut {
				fmt.Fprintln(os.Stderr, "Watching for changes. Ctrl-C to stop.")
			}
			enc := json.NewEncoder(os.Stdout)
			// No device id: a terminal watcher shows this machine's own edits too.
			stream := *s.c
			stream.Device = ""
			return stream.Stream(ctx, snap.Seq, func(c protocol.Change) error {
				line := w.describe(c) // always, to keep names current
				if jsonOut {
					return enc.Encode(c)
				}
				if line != "" {
					fmt.Printf("%s  %s\n", time.Now().Format("15:04:05"), line)
				}
				return nil
			})
		},
	}
}

type watchedItem struct{ note, text string }

// watcher turns feed changes into sentences, tracking titles and item text
// so later changes can name what they touch.
type watcher struct {
	me     string
	names  map[string]string
	titles map[string]string
	items  map[string]watchedItem
	shares map[string]protocol.Member // by membership id, as last announced
}

func newWatcher(snap *protocol.Snapshot, names map[string]string, me string) *watcher {
	w := &watcher{me: me, names: names, titles: map[string]string{}, items: map[string]watchedItem{}, shares: map[string]protocol.Member{}}
	for _, n := range snap.Notes {
		w.titles[n.ID] = noteTitle(n)
	}
	for _, m := range snap.Members {
		w.shares[m.ID] = m
	}
	for _, it := range snap.Items {
		w.items[it.ID] = watchedItem{note: it.Note, text: it.Text}
	}
	return w
}

func (w *watcher) who(id string) string {
	if id == w.me {
		return "You"
	}
	if n, ok := w.names[id]; ok {
		return n
	}
	return "Someone"
}

func (w *watcher) title(noteID string) string {
	if t, ok := w.titles[noteID]; ok {
		return t
	}
	return "a note"
}

func (w *watcher) describe(c protocol.Change) string {
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
			w.titles[n.ID] = noteTitle(n)
			if known {
				return ""
			}
			return fmt.Sprintf("%s: new %s %q", who, n.Kind, noteTitle(n))
		case protocol.Items:
			var it protocol.Item
			_ = json.Unmarshal(c.Value, &it)
			_, known := w.items[it.ID]
			w.items[it.ID] = watchedItem{note: it.Note, text: it.Text}
			if known {
				return ""
			}
			return fmt.Sprintf("%s added %q to %s", who, it.Text, w.title(it.Note))
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
