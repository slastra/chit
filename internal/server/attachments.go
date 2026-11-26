package server

import (
	"errors"
	"io"
	"mime"
	"net/http"
	"path/filepath"
	"strings"

	"github.com/pocketbase/pocketbase/apis"
	"github.com/pocketbase/pocketbase/core"
	"github.com/pocketbase/pocketbase/tools/filesystem"

	"github.com/slastra/chit/internal/protocol"
)

// attach stores f on noteID as attachment id (client-generated, so an upload
// retried after a dropped connection lands once). Owner and editors only.
func attach(app core.App, me *core.Record, device, noteID, id string, f *filesystem.File) (*protocol.Attachment, int64, error) {
	if !recordID.MatchString(id) {
		return nil, 0, errBadRequest
	}
	var out protocol.Attachment
	var seq int64
	err := app.RunInTransaction(func(tx core.App) error {
		acc, note, err := noteAccess(tx, me.Id, noteID)
		if err != nil {
			return err
		}
		if note == nil || acc == noAccess {
			return errNotFound
		}
		if acc < canEdit {
			return errNotAllowed
		}
		if existing, err := tx.FindRecordById(protocol.Attachments, id); err == nil {
			if existing.GetString("note") != noteID {
				return errBadRequest
			}
			out = attachmentOf(existing) // a retry of an upload that already landed
			seq, err = head(tx)
			return err
		}

		col, err := tx.FindCollectionByNameOrId(protocol.Attachments)
		if err != nil {
			return err
		}
		rec := core.NewRecord(col)
		rec.Id = id
		rec.Set("note", noteID)
		rec.Set("file", f)
		rec.Set("name", f.OriginalName)
		rec.Set("size", f.Size)
		rec.Set("type", contentType(f))
		if err := tx.Save(rec); err != nil {
			return err
		}
		out = attachmentOf(rec)
		seq, err = appendChange(tx, entry{
			scope: "note", note: noteID, kind: protocol.KindRecord, collection: protocol.Attachments,
			record: id, value: wireRecord(rec), by: me.Id, device: device,
		})
		return err
	})
	return &out, seq, err
}

// contentType sniffs the file, falling back to its extension when the bytes
// alone are ambiguous.
func contentType(f *filesystem.File) string {
	sniffed := "application/octet-stream"
	if r, err := f.Reader.Open(); err == nil {
		buf := make([]byte, 512)
		n, _ := io.ReadFull(r, buf)
		r.Close()
		sniffed = http.DetectContentType(buf[:n])
	}
	if sniffed == "application/octet-stream" || strings.HasPrefix(sniffed, "text/plain") {
		if byExt := mime.TypeByExtension(strings.ToLower(filepath.Ext(f.OriginalName))); byExt != "" {
			return byExt
		}
	}
	return sniffed
}

// handleAttach takes a multipart upload: "file" plus an "id" field.
func handleAttach(e *core.RequestEvent, b *Broker) error {
	files, err := e.FindUploadedFiles("file")
	if err != nil || len(files) != 1 {
		return apis.NewBadRequestError("send exactly one file in the \"file\" field", nil)
	}
	id := e.Request.FormValue("id")
	a, seq, err := attach(e.App, e.Auth, deviceOf(e), e.Request.PathValue("id"), id, files[0])
	if err != nil {
		if errors.Is(err, errBadRequest) {
			return apis.NewBadRequestError("the \"id\" field must be a new 15-character id for this note", nil)
		}
		if errors.Is(err, errNotFound) || errors.Is(err, errNotAllowed) {
			return mapErr(err)
		}
		return apis.NewBadRequestError("upload rejected: "+strings.TrimRight(err.Error(), "."), nil)
	}
	b.Notify()
	return e.JSON(http.StatusOK, protocol.AttachResponse{Seq: seq, Attachment: *a})
}
