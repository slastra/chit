// Package migrations defines chit's collections. Registered migrations run
// automatically when the server starts.
package migrations

import (
	"github.com/pocketbase/pocketbase/core"
	m "github.com/pocketbase/pocketbase/migrations"
	"github.com/pocketbase/pocketbase/tools/types"
)

// Access rules. Every write to these collections goes through chit's sync
// routes, which save as the server, so create/update/delete stay nil
// (superusers only). The read rules decide who sees what in the admin API,
// in file downloads, and in the sync feed's visibility checks.
const (
	// A note is visible to its owner and to anyone listed in note_members.
	noteRule = "owner = @request.auth.id || note_members_via_note.user ?= @request.auth.id"
	// Items and member rows are visible to whoever can see their note.
	viaNoteRule = "note.owner = @request.auth.id || note.note_members_via_note.user ?= @request.auth.id"
	// Labels and per-note state belong to one user.
	ownRule = "user = @request.auth.id"
)

func init() {
	m.Register(up, down)
}

func up(app core.App) error {
	users, err := app.FindCollectionByNameOrId("users")
	if err != nil {
		return err
	}
	// Invite-only: accounts are created by a superuser in the admin UI.
	users.CreateRule = nil
	users.DeleteRule = nil
	if err := app.Save(users); err != nil {
		return err
	}

	notes := core.NewBaseCollection("notes")
	notes.Fields.Add(
		&core.RelationField{Name: "owner", CollectionId: users.Id, MaxSelect: 1, Required: true, CascadeDelete: true},
		&core.SelectField{Name: "kind", Values: []string{"text", "list"}, MaxSelect: 1, Required: true},
		&core.TextField{Name: "title", Max: 1000},
		&core.TextField{Name: "body", Max: 200000},
		&core.SelectField{Name: "color", MaxSelect: 1, Values: []string{
			"red", "orange", "yellow", "green", "teal", "blue", "purple", "pink", "brown", "gray",
		}},
		&core.DateField{Name: "trashed"},
		&core.BoolField{Name: "deleted"},
		clocksField(),
	)
	addTimestamps(notes)
	notes.AddIndex("idx_notes_owner", false, "owner", "")
	if err := app.Save(notes); err != nil {
		return err
	}

	members := core.NewBaseCollection("note_members")
	members.Fields.Add(
		&core.RelationField{Name: "note", CollectionId: notes.Id, MaxSelect: 1, Required: true, CascadeDelete: true},
		&core.RelationField{Name: "user", CollectionId: users.Id, MaxSelect: 1, Required: true, CascadeDelete: true},
		&core.SelectField{Name: "role", Values: []string{"editor", "viewer"}, MaxSelect: 1, Required: true},
	)
	addTimestamps(members)
	members.AddIndex("idx_note_members_note_user", true, "note, user", "")
	members.AddIndex("idx_note_members_user", false, "user", "")
	members.ListRule = types.Pointer(viaNoteRule)
	members.ViewRule = types.Pointer(viaNoteRule)
	if err := app.Save(members); err != nil {
		return err
	}

	// The notes rule names note_members, so it can only be set once that exists.
	notes.ListRule = types.Pointer(noteRule)
	notes.ViewRule = types.Pointer(noteRule)
	if err := app.Save(notes); err != nil {
		return err
	}

	items := core.NewBaseCollection("items")
	items.Fields.Add(
		&core.RelationField{Name: "note", CollectionId: notes.Id, MaxSelect: 1, Required: true, CascadeDelete: true},
		&core.TextField{Name: "text", Max: 10000},
		&core.BoolField{Name: "checked"},
		// Fractional index: items sort by this string, and moving one item
		// rewrites only its own key.
		&core.TextField{Name: "order", Max: 200},
		&core.NumberField{Name: "indent", OnlyInt: true, Min: types.Pointer(0.0), Max: types.Pointer(1.0)},
		&core.BoolField{Name: "deleted"},
		clocksField(),
	)
	addTimestamps(items)
	items.AddIndex("idx_items_note", false, "note", "")
	items.ListRule = types.Pointer(viaNoteRule)
	items.ViewRule = types.Pointer(viaNoteRule)
	if err := app.Save(items); err != nil {
		return err
	}

	labels := core.NewBaseCollection("labels")
	labels.Fields.Add(
		&core.RelationField{Name: "user", CollectionId: users.Id, MaxSelect: 1, Required: true, CascadeDelete: true},
		&core.TextField{Name: "name", Max: 100, Required: true},
		&core.BoolField{Name: "deleted"},
		clocksField(),
	)
	addTimestamps(labels)
	labels.AddIndex("idx_labels_user", false, "user", "")
	labels.ListRule = types.Pointer(ownRule)
	labels.ViewRule = types.Pointer(ownRule)
	if err := app.Save(labels); err != nil {
		return err
	}

	// Per-user view of a note: what Keep keeps private even on a shared note.
	state := core.NewBaseCollection("note_state")
	state.Fields.Add(
		&core.RelationField{Name: "note", CollectionId: notes.Id, MaxSelect: 1, Required: true, CascadeDelete: true},
		&core.RelationField{Name: "user", CollectionId: users.Id, MaxSelect: 1, Required: true, CascadeDelete: true},
		&core.BoolField{Name: "pinned"},
		&core.BoolField{Name: "archived"},
		&core.RelationField{Name: "labels", CollectionId: labels.Id, MaxSelect: 1000},
		&core.DateField{Name: "reminder"},
		&core.BoolField{Name: "reminder_done"},
		clocksField(),
	)
	addTimestamps(state)
	state.AddIndex("idx_note_state_note_user", true, "note, user", "")
	state.AddIndex("idx_note_state_user", false, "user", "")
	state.ListRule = types.Pointer(ownRule)
	state.ViewRule = types.Pointer(ownRule)
	return app.Save(state)
}

func down(app core.App) error {
	for _, name := range []string{"note_state", "labels", "items", "note_members", "notes"} {
		c, err := app.FindCollectionByNameOrId(name)
		if err != nil {
			return err
		}
		if name == "note_members" {
			// notes' rules reference note_members; clear them before deleting it.
			n, err := app.FindCollectionByNameOrId("notes")
			if err != nil {
				return err
			}
			n.ListRule, n.ViewRule = nil, nil
			if err := app.Save(n); err != nil {
				return err
			}
		}
		if err := app.Delete(c); err != nil {
			return err
		}
	}

	users, err := app.FindCollectionByNameOrId("users")
	if err != nil {
		return err
	}
	users.CreateRule = types.Pointer("")
	users.DeleteRule = types.Pointer("id = @request.auth.id")
	return app.Save(users)
}

// clocksField holds the per-field hybrid logical clocks that last-write-wins
// compares, keyed by field name. See docs/design.md.
func clocksField() *core.JSONField {
	return &core.JSONField{Name: "clocks", Hidden: true}
}

func addTimestamps(c *core.Collection) {
	c.Fields.Add(
		&core.AutodateField{Name: "created", OnCreate: true},
		&core.AutodateField{Name: "updated", OnCreate: true, OnUpdate: true},
	)
}
