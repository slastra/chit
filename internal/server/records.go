package server

import (
	"encoding/json"

	"github.com/pocketbase/dbx"
	"github.com/pocketbase/pocketbase/core"

	"github.com/slastra/chit/internal/protocol"
)

func clocksOf(r *core.Record) protocol.Clocks {
	c := protocol.Clocks{}
	if raw, ok := r.Get("clocks").(interface{ String() string }); ok {
		_ = json.Unmarshal([]byte(raw.String()), &c)
	}
	if c == nil { // a new record's clocks are JSON null
		c = protocol.Clocks{}
	}
	return c
}

func dateOf(r *core.Record, field string) string {
	d := r.GetDateTime(field)
	if d.IsZero() {
		return ""
	}
	return d.String()
}

func noteOf(r *core.Record) protocol.Note {
	return protocol.Note{
		ID:      r.Id,
		Owner:   r.GetString("owner"),
		Kind:    r.GetString("kind"),
		Title:   r.GetString("title"),
		Body:    r.GetString("body"),
		Color:   r.GetString("color"),
		Trashed: dateOf(r, "trashed"),
		Deleted: r.GetBool("deleted"),
		Clocks:  clocksOf(r),
		Created: dateOf(r, "created"),
		Updated: dateOf(r, "updated"),
	}
}

func itemOf(r *core.Record) protocol.Item {
	return protocol.Item{
		ID:      r.Id,
		Note:    r.GetString("note"),
		Text:    r.GetString("text"),
		Checked: r.GetBool("checked"),
		Order:   r.GetString("order"),
		Indent:  r.GetInt("indent"),
		Deleted: r.GetBool("deleted"),
		Clocks:  clocksOf(r),
	}
}

func memberOf(r *core.Record) protocol.Member {
	return protocol.Member{
		ID:   r.Id,
		Note: r.GetString("note"),
		User: r.GetString("user"),
		Role: r.GetString("role"),
	}
}

func stateOf(r *core.Record) protocol.State {
	labels := r.GetStringSlice("labels")
	if labels == nil {
		labels = []string{}
	}
	return protocol.State{
		Note:         r.GetString("note"),
		Pinned:       r.GetBool("pinned"),
		Archived:     r.GetBool("archived"),
		Labels:       labels,
		Reminder:     dateOf(r, "reminder"),
		ReminderDone: r.GetBool("reminder_done"),
		Order:        r.GetString("order"),
		Clocks:       clocksOf(r),
	}
}

func labelOf(r *core.Record) protocol.Label {
	return protocol.Label{
		ID:      r.Id,
		Name:    r.GetString("name"),
		Deleted: r.GetBool("deleted"),
		Clocks:  clocksOf(r),
	}
}

func attachmentOf(r *core.Record) protocol.Attachment {
	return protocol.Attachment{
		ID:      r.Id,
		Note:    r.GetString("note"),
		File:    r.GetString("file"),
		Name:    r.GetString("name"),
		Size:    r.GetInt64("size"),
		Type:    r.GetString("type"),
		Deleted: r.GetBool("deleted"),
		Clocks:  clocksOf(r),
		Created: dateOf(r, "created"),
	}
}

// wireRecord renders a record the way the feed and the snapshot send it.
func wireRecord(r *core.Record) json.RawMessage {
	var v any
	switch r.Collection().Name {
	case protocol.Notes:
		v = noteOf(r)
	case protocol.Items:
		v = itemOf(r)
	case protocol.Members:
		v = memberOf(r)
	case protocol.NoteState:
		v = stateOf(r)
	case protocol.Labels:
		v = labelOf(r)
	case protocol.Attachments:
		v = attachmentOf(r)
	}
	b, _ := json.Marshal(v)
	return b
}

// visibleNotes is the SQL condition for notes the user may read.
const visibleNotes = `SELECT id FROM notes WHERE owner = {:me}
	UNION SELECT note FROM note_members WHERE user = {:me}`

// access is what a user may do with one note.
type access int

const (
	noAccess access = iota
	canRead
	canEdit
	isOwner
)

func noteAccess(app core.App, userID, noteID string) (access, *core.Record, error) {
	note, err := app.FindRecordById(protocol.Notes, noteID)
	if err != nil {
		return noAccess, nil, nil
	}
	if note.GetString("owner") == userID {
		return isOwner, note, nil
	}
	m, err := app.FindFirstRecordByFilter(protocol.Members, "note = {:n} && user = {:u}", dbx.Params{"n": noteID, "u": userID})
	if err != nil {
		return noAccess, note, nil
	}
	if m.GetString("role") == "editor" {
		return canEdit, note, nil
	}
	return canRead, note, nil
}

// snapshot collects everything userID can see.
func snapshot(app core.App, userID string) (*protocol.Snapshot, error) {
	s := &protocol.Snapshot{
		Notes: []protocol.Note{}, Items: []protocol.Item{}, Members: []protocol.Member{},
		State: []protocol.State{}, Labels: []protocol.Label{}, Attachments: []protocol.Attachment{},
	}
	p := dbx.Params{"me": userID}
	err := app.RunInTransaction(func(tx core.App) error {
		var err error
		if s.Seq, err = head(tx); err != nil {
			return err
		}
		var notes, items, members, states, labels, files []*core.Record
		if err := tx.RecordQuery(protocol.Notes).
			AndWhere(dbx.NewExp("[[deleted]] = FALSE AND [[id]] IN ("+visibleNotes+")", p)).
			OrderBy("created ASC").All(&notes); err != nil {
			return err
		}
		if err := tx.RecordQuery(protocol.Items).
			AndWhere(dbx.NewExp("[[deleted]] = FALSE AND [[note]] IN (SELECT id FROM notes WHERE deleted = FALSE AND id IN ("+visibleNotes+"))", p)).
			OrderBy("note ASC", "order ASC").All(&items); err != nil {
			return err
		}
		if err := tx.RecordQuery(protocol.Members).
			AndWhere(dbx.NewExp("[[note]] IN ("+visibleNotes+")", p)).All(&members); err != nil {
			return err
		}
		if err := tx.RecordQuery(protocol.NoteState).
			AndWhere(dbx.NewExp("[[user]] = {:me} AND [[note]] IN ("+visibleNotes+")", p)).All(&states); err != nil {
			return err
		}
		if err := tx.RecordQuery(protocol.Labels).
			AndWhere(dbx.NewExp("[[user]] = {:me} AND [[deleted]] = FALSE", p)).
			OrderBy("name ASC").All(&labels); err != nil {
			return err
		}
		if err := tx.RecordQuery(protocol.Attachments).
			AndWhere(dbx.NewExp("[[deleted]] = FALSE AND [[note]] IN (SELECT id FROM notes WHERE deleted = FALSE AND id IN ("+visibleNotes+"))", p)).
			OrderBy("created ASC").All(&files); err != nil {
			return err
		}
		for _, r := range files {
			s.Attachments = append(s.Attachments, attachmentOf(r))
		}
		for _, r := range notes {
			s.Notes = append(s.Notes, noteOf(r))
		}
		for _, r := range items {
			s.Items = append(s.Items, itemOf(r))
		}
		for _, r := range members {
			s.Members = append(s.Members, memberOf(r))
		}
		for _, r := range states {
			s.State = append(s.State, stateOf(r))
		}
		for _, r := range labels {
			s.Labels = append(s.Labels, labelOf(r))
		}
		return nil
	})
	return s, err
}
