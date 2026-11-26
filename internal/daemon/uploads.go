package daemon

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"

	"github.com/slastra/chit/internal/capture"
	"github.com/slastra/chit/internal/client"
	"github.com/slastra/chit/internal/config"
	"github.com/slastra/chit/internal/protocol"
)

// compose applies a composer draft: the note edits go through the outbox,
// and each file is copied into the upload queue to follow once the note
// exists on the server.
func (d *Daemon) compose(plan *capture.Plan, s *protocol.Snapshot) error {
	if d.me() == "" {
		return client.ErrUnauthorized
	}
	if len(plan.Files) > 0 && d.opts.UploadDir == "" {
		return errors.New("chitd has no upload directory")
	}
	if plan.NoteID == "" && (plan.Kind == capture.NewNote || plan.Kind == capture.NewList) {
		plan.NoteID = config.NewID()
	}
	if ops := plan.Ops(s, d.clock.Now, config.NewID); len(ops) > 0 {
		if _, err := d.ApplyLocal(ops); err != nil {
			return err
		}
	}
	for _, f := range plan.Files {
		id := config.NewID()
		dst := filepath.Join(d.opts.UploadDir, id, f.Name)
		if err := copyFile(f.Path, dst); err != nil {
			return fmt.Errorf("%s: %w", f.Name, err)
		}
		a := protocol.Attachment{ID: id, Note: plan.NoteID, Name: f.Name, Size: f.Size, Type: f.Type}
		if err := d.rep.QueueUpload(a, dst); err != nil {
			return err
		}
		var rec protocol.Attachment
		if ok, _ := d.rep.Record(protocol.Attachments, id, &rec); ok {
			d.changed(protocol.Change{Kind: protocol.KindRecord, Collection: protocol.Attachments,
				Record: id, Value: jsonOf(rec), By: d.me()}, true)
		}
	}
	signal(d.kick)
	return nil
}

func copyFile(src, dst string) error {
	if err := os.MkdirAll(filepath.Dir(dst), 0o700); err != nil {
		return err
	}
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	out, err := os.OpenFile(dst, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o600)
	if err != nil {
		return err
	}
	if _, err := io.Copy(out, in); err != nil {
		out.Close()
		return err
	}
	return out.Close()
}

// flushUploads sends queued files, one at a time, but only once the outbox
// is empty: a file's note must reach the server before the file does.
func (d *Daemon) flushUploads(ctx context.Context, c *client.Client) (int, error) {
	if n, err := d.rep.PendingCount(); err != nil || n > 0 {
		return 0, err
	}
	ups, err := d.rep.PendingUploads()
	if err != nil || len(ups) == 0 {
		return 0, err
	}
	u := ups[0]
	resp, err := c.Upload(ctx, u.Note, u.ID, u.Path)
	if err != nil {
		var ae *client.APIError
		if errors.As(err, &ae) && ae.Status >= 400 && ae.Status < 500 {
			// Refused for good (too big, the note is gone, no permission).
			d.logf("upload of %s refused: %v", filepath.Base(u.Path), err)
			_ = d.rep.FinishUpload(u.ID, nil)
			_ = os.RemoveAll(filepath.Dir(u.Path))
			signal(d.dirty)
			return 1, nil
		}
		return 0, err
	}
	if err := d.rep.FinishUpload(u.ID, &resp.Attachment); err != nil {
		return 0, err
	}
	_ = os.RemoveAll(filepath.Dir(u.Path))
	signal(d.dirty)
	return 1, nil
}
