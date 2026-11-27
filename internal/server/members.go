package server

import (
	"errors"

	"github.com/pocketbase/dbx"
	"github.com/pocketbase/pocketbase/core"

	"github.com/slastra/chit/internal/protocol"
)

// errNotAllowed and errNotFound map to 403 and 404 in the handlers.
var (
	errNotAllowed = errors.New("not allowed")
	errNotFound   = errors.New("not found")
	errBadRequest = errors.New("bad request")
)

// share adds userID to noteID as role, or changes their role. Only the owner
// may share. A new member gets the note, its items and its members written
// into their own feed, so their next catch-up includes it.
func share(app core.App, me *core.Record, device, noteID, userID, role string) (int64, error) {
	if role != "editor" && role != "viewer" {
		return 0, errBadRequest
	}
	var seq int64
	err := app.RunInTransaction(func(tx core.App) error {
		acc, note, err := noteAccess(tx, me.Id, noteID)
		if err != nil {
			return err
		}
		if note == nil || acc == noAccess || note.GetBool("deleted") {
			return errNotFound
		}
		if acc != isOwner {
			return errNotAllowed
		}
		if userID == me.Id {
			return errBadRequest
		}
		if _, err := tx.FindRecordById("users", userID); err != nil {
			return errNotFound
		}

		col, err := tx.FindCollectionByNameOrId(protocol.Members)
		if err != nil {
			return err
		}
		m, err := tx.FindFirstRecordByFilter(col, "note = {:n} && user = {:u}", dbx.Params{"n": noteID, "u": userID})
		isNew := err != nil
		if isNew {
			m = core.NewRecord(col)
			m.Set("note", noteID)
			m.Set("user", userID)
		} else if m.GetString("role") == role {
			seq, err = head(tx)
			return err
		}
		m.Set("role", role)
		if err := tx.Save(m); err != nil {
			return err
		}

		// A new member gets the note first (its snapshot includes their own
		// membership), then everyone with access hears about the membership.
		if isNew {
			if _, err := snapshotInto(tx, userID, note, me.Id, device); err != nil {
				return err
			}
		}
		seq, err = appendChange(tx, entry{
			scope: "note", note: noteID, kind: protocol.KindRecord, collection: protocol.Members,
			record: m.Id, value: wireRecord(m), by: me.Id, device: device,
		})
		return err
	})
	return seq, err
}

// snapshotInto writes note, its live items, attachments and members into one user's feed.
func snapshotInto(tx core.App, userID string, note *core.Record, by, device string) (int64, error) {
	rows := []*core.Record{note}
	var items, members, files []*core.Record
	if err := tx.RecordQuery(protocol.Items).
		AndWhere(dbx.HashExp{"note": note.Id, "deleted": false}).
		OrderBy("order ASC").All(&items); err != nil {
		return 0, err
	}
	if err := tx.RecordQuery(protocol.Members).
		AndWhere(dbx.HashExp{"note": note.Id}).All(&members); err != nil {
		return 0, err
	}
	if err := tx.RecordQuery(protocol.Attachments).
		AndWhere(dbx.HashExp{"note": note.Id, "deleted": false}).All(&files); err != nil {
		return 0, err
	}
	rows = append(append(append(rows, items...), files...), members...)

	var seq int64
	for _, r := range rows {
		var err error
		if seq, err = appendChange(tx, entry{
			scope: "user", user: userID, note: note.Id, kind: protocol.KindRecord,
			collection: r.Collection().Name, record: r.Id, value: wireRecord(r),
			by: by, device: device,
		}); err != nil {
			return 0, err
		}
	}
	return seq, nil
}

// unshare removes userID from noteID. The owner may remove anyone; a member
// may remove themselves (leaving the note).
func unshare(app core.App, me *core.Record, device, noteID, userID string) (int64, error) {
	var seq int64
	err := app.RunInTransaction(func(tx core.App) error {
		acc, note, err := noteAccess(tx, me.Id, noteID)
		if err != nil {
			return err
		}
		if note == nil || acc == noAccess {
			return errNotFound
		}
		if acc != isOwner && userID != me.Id {
			return errNotAllowed
		}
		m, err := tx.FindFirstRecordByFilter(protocol.Members, "note = {:n} && user = {:u}", dbx.Params{"n": noteID, "u": userID})
		if err != nil {
			return errNotFound
		}
		if err := tx.Delete(m); err != nil {
			return err
		}
		// The removed user's own note_state for it goes too.
		if st, err := tx.FindFirstRecordByFilter(protocol.NoteState, "note = {:n} && user = {:u}", dbx.Params{"n": noteID, "u": userID}); err == nil {
			if err := tx.Delete(st); err != nil {
				return err
			}
		}
		if _, err := appendChange(tx, entry{
			scope: "note", note: noteID, kind: protocol.KindRemove, collection: protocol.Members,
			record: m.Id, by: me.Id, device: device,
		}); err != nil {
			return err
		}
		seq, err = appendChange(tx, entry{
			scope: "user", user: userID, note: noteID, kind: protocol.KindRevoke,
			collection: protocol.Notes, record: noteID, by: me.Id, device: device,
		})
		return err
	})
	return seq, err
}
