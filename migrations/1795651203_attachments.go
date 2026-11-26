package migrations

import (
	"github.com/pocketbase/pocketbase/core"
	m "github.com/pocketbase/pocketbase/migrations"
	"github.com/pocketbase/pocketbase/tools/types"
)

// MaxAttachmentSize stays under PocketBase's default 32 MB request body
// limit, so uploads need no route-specific override.
const MaxAttachmentSize = 25 << 20

// attachments are files on a note. The file is protected: downloading it
// takes a short-lived file token, and the view rule (can see the note)
// decides who gets one.
func init() {
	m.Register(func(app core.App) error {
		notes, err := app.FindCollectionByNameOrId("notes")
		if err != nil {
			return err
		}
		c := core.NewBaseCollection("attachments")
		c.Fields.Add(
			&core.RelationField{Name: "note", CollectionId: notes.Id, MaxSelect: 1, Required: true, CascadeDelete: true},
			&core.FileField{
				Name: "file", MaxSelect: 1, MaxSize: MaxAttachmentSize, Required: true, Protected: true,
				Thumbs: []string{"320x320", "1080x0"},
			},
			&core.TextField{Name: "name", Max: 500},
			&core.NumberField{Name: "size", OnlyInt: true},
			&core.TextField{Name: "type", Max: 200},
			&core.BoolField{Name: "deleted"},
			clocksField(),
		)
		addTimestamps(c)
		c.AddIndex("idx_attachments_note", false, "note", "")
		c.ListRule = types.Pointer(viaNoteRule)
		c.ViewRule = types.Pointer(viaNoteRule)
		return app.Save(c)
	}, func(app core.App) error {
		c, err := app.FindCollectionByNameOrId("attachments")
		if err != nil {
			return err
		}
		return app.Delete(c)
	})
}
