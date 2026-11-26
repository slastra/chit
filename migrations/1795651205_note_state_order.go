package migrations

import (
	"github.com/pocketbase/pocketbase/core"
	m "github.com/pocketbase/pocketbase/migrations"
)

// note_state.order: where each person put a note on their own board, a
// fractional key like an item's order. Empty until they move it.
func init() {
	m.Register(func(app core.App) error {
		c, err := app.FindCollectionByNameOrId("note_state")
		if err != nil {
			return err
		}
		c.Fields.Add(&core.TextField{Name: "order", Max: 64})
		return app.Save(c)
	}, func(app core.App) error {
		c, err := app.FindCollectionByNameOrId("note_state")
		if err != nil {
			return err
		}
		c.Fields.RemoveByName("order")
		return app.Save(c)
	})
}
