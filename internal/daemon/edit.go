package daemon

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/slastra/chit/internal/config"
	"github.com/slastra/chit/internal/notes"
	"github.com/slastra/chit/internal/order"
	"github.com/slastra/chit/internal/protocol"
)

// settable lists what lastshell may change with "set". The server decides
// who may (owner, editor); this only keeps the socket to known fields.
func settable(collection, field string) bool {
	allowed := map[string][]string{
		protocol.Notes:       {"title", "body", "color", "trashed", "deleted"},
		protocol.Items:       {"text", "checked", "deleted", "indent", "order"},
		protocol.NoteState:   {"pinned", "archived", "reminder", "reminder_done", "order"},
		protocol.Attachments: {"deleted"},
	}
	for _, f := range allowed[collection] {
		if f == field {
			return true
		}
	}
	return false
}

// addItem puts a new item on a list, after the item named (or at the end),
// and returns its id so the editor can focus it.
func (d *Daemon) addItem(noteID, text, after string) (string, error) {
	s, err := d.rep.Snapshot()
	if err != nil {
		return "", err
	}
	items := notes.ItemsOf(s, noteID)
	sort.SliceStable(items, func(i, j int) bool { return items[i].Order < items[j].Order })
	prev, next := "", ""
	if len(items) > 0 {
		prev = items[len(items)-1].Order
	}
	if after != "" {
		for i, it := range items {
			if it.ID == after {
				prev = it.Order
				next = ""
				if i+1 < len(items) {
					next = items[i+1].Order
				}
			}
		}
	}
	id := config.NewID()
	_, err = d.ApplyLocal([]protocol.Op{
		d.op(protocol.Items, id, "note", noteID),
		d.op(protocol.Items, id, "text", text),
		d.op(protocol.Items, id, "order", order.Between(prev, next)),
	})
	return id, err
}

// convert turns a text note into a checklist (one item per body line) or a
// checklist into text (one line per item, open ones first).
func (d *Daemon) convert(noteID, kind string) error {
	s, err := d.rep.Snapshot()
	if err != nil {
		return err
	}
	var note *protocol.Note
	for i := range s.Notes {
		if s.Notes[i].ID == noteID {
			note = &s.Notes[i]
		}
	}
	if note == nil {
		return errors.New("no such note")
	}
	if note.Kind == kind {
		return nil
	}
	var ops []protocol.Op
	switch kind {
	case "list":
		last := ""
		for _, line := range strings.Split(note.Body, "\n") {
			if t := strings.TrimSpace(line); t != "" {
				last = order.After(last)
				id := config.NewID()
				ops = append(ops, d.op(protocol.Items, id, "note", noteID), d.op(protocol.Items, id, "text", t),
					d.op(protocol.Items, id, "order", last))
			}
		}
		ops = append(ops, d.op(protocol.Notes, noteID, "body", ""), d.op(protocol.Notes, noteID, "kind", "list"))
	case "text":
		items := notes.ItemsOf(s, noteID)
		sort.SliceStable(items, func(i, j int) bool {
			if items[i].Checked != items[j].Checked {
				return !items[i].Checked
			}
			return items[i].Order < items[j].Order
		})
		var lines []string
		for _, it := range items {
			lines = append(lines, it.Text)
			ops = append(ops, d.op(protocol.Items, it.ID, "deleted", true))
		}
		ops = append(ops, d.op(protocol.Notes, noteID, "body", strings.Join(lines, "\n")), d.op(protocol.Notes, noteID, "kind", "text"))
	default:
		return fmt.Errorf("kind is text or list")
	}
	_, err = d.ApplyLocal(ops)
	return err
}

// fetch returns a local file for an attachment: the queued copy while it
// waits to upload, else a cached download (the thumb size when given).
// Cached files are reused, so the board works offline for what it has seen.
func (d *Daemon) fetch(ctx context.Context, id, thumb string) (string, error) {
	var a protocol.Attachment
	ok, err := d.rep.Record(protocol.Attachments, id, &a)
	if err != nil {
		return "", err
	}
	if !ok {
		return "", errors.New("no such attachment")
	}
	if a.Pending && a.Local != "" {
		return a.Local, nil
	}
	if thumb != "" && thumb != "320x320" && thumb != "1080x0" {
		return "", fmt.Errorf("thumb is 320x320 or 1080x0")
	}
	if d.opts.CacheDir == "" {
		return "", errors.New("chitd has no cache directory")
	}
	kind := "file"
	if thumb != "" {
		kind = thumb
	}
	path := filepath.Join(d.opts.CacheDir, kind, a.ID, filepath.Base(a.Name))
	if _, err := os.Stat(path); err == nil {
		return path, nil
	}
	c := d.client()
	if c == nil {
		return "", errors.New("signed out")
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return "", err
	}
	tmp := path + ".part"
	f, err := os.Create(tmp)
	if err != nil {
		return "", err
	}
	err = c.Download(ctx, a, thumb, f)
	if cerr := f.Close(); err == nil {
		err = cerr
	}
	if err != nil {
		os.Remove(tmp)
		return "", err
	}
	return path, os.Rename(tmp, path)
}
