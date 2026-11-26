package migrations

import (
	"github.com/pocketbase/pocketbase/core"
	m "github.com/pocketbase/pocketbase/migrations"

	"github.com/slastra/chit/internal/protocol"
)

// Attachments up to protocol.MaxAttachmentSize (250 MB): a few minutes of
// phone video. The upload route carries a body limit to match.
func init() {
	m.Register(func(app core.App) error {
		return setAttachmentLimit(app, protocol.MaxAttachmentSize)
	}, func(app core.App) error {
		return setAttachmentLimit(app, firstAttachmentLimit)
	})
}

func setAttachmentLimit(app core.App, size int64) error {
	c, err := app.FindCollectionByNameOrId("attachments")
	if err != nil {
		return err
	}
	f, ok := c.Fields.GetByName("file").(*core.FileField)
	if !ok {
		return nil
	}
	f.MaxSize = size
	return app.Save(c)
}
