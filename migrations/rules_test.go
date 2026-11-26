package migrations

import (
	"testing"

	"github.com/pocketbase/pocketbase/core"
	"github.com/pocketbase/pocketbase/tests"
)

func newApp(t *testing.T) *tests.TestApp {
	t.Helper()
	app, err := tests.NewTestAppWithConfig(core.BaseAppConfig{DataDir: t.TempDir()})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(app.Cleanup)
	return app
}

func save(t *testing.T, app core.App, collection string, fields map[string]any) *core.Record {
	t.Helper()
	c, err := app.FindCollectionByNameOrId(collection)
	if err != nil {
		t.Fatal(err)
	}
	r := core.NewRecord(c)
	r.Load(fields)
	if c.IsAuth() {
		r.SetPassword("correct horse battery")
	}
	if err := app.Save(r); err != nil {
		t.Fatalf("save %s: %v", collection, err)
	}
	return r
}

// canView reports whether user may view record under its collection's view rule.
func canView(t *testing.T, app core.App, user, record *core.Record) bool {
	t.Helper()
	ok, err := app.CanAccessRecord(record, &core.RequestInfo{Auth: user}, record.Collection().ViewRule)
	if err != nil {
		t.Fatal(err)
	}
	return ok
}

func TestSignupIsInviteOnly(t *testing.T) {
	app := newApp(t)
	users, err := app.FindCollectionByNameOrId("users")
	if err != nil {
		t.Fatal(err)
	}
	if users.CreateRule != nil {
		t.Fatalf("users create rule = %q, want nil (superusers only)", *users.CreateRule)
	}
}

func TestSharingRules(t *testing.T) {
	app := newApp(t)
	owner := save(t, app, "users", map[string]any{"email": "owner@example.com"})
	member := save(t, app, "users", map[string]any{"email": "member@example.com"})
	stranger := save(t, app, "users", map[string]any{"email": "stranger@example.com"})

	note := save(t, app, "notes", map[string]any{"owner": owner.Id, "kind": "list", "title": "Groceries"})
	membership := save(t, app, "note_members", map[string]any{"note": note.Id, "user": member.Id, "role": "editor"})
	item := save(t, app, "items", map[string]any{"note": note.Id, "text": "milk", "order": "a0"})
	ownerState := save(t, app, "note_state", map[string]any{"note": note.Id, "user": owner.Id, "pinned": true})
	label := save(t, app, "labels", map[string]any{"user": owner.Id, "name": "home"})

	cases := []struct {
		name   string
		user   *core.Record
		record *core.Record
		want   bool
	}{
		{"owner sees note", owner, note, true},
		{"member sees note", member, note, true},
		{"stranger cannot see note", stranger, note, false},
		{"member sees item", member, item, true},
		{"stranger cannot see item", stranger, item, false},
		{"member sees membership", member, membership, true},
		{"stranger cannot see membership", stranger, membership, false},
		{"owner sees own state", owner, ownerState, true},
		{"member cannot see owner's state", member, ownerState, false},
		{"owner sees own label", owner, label, true},
		{"member cannot see owner's label", member, label, false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := canView(t, app, tc.user, tc.record); got != tc.want {
				t.Fatalf("canView = %v, want %v", got, tc.want)
			}
		})
	}
}

func TestOneStatePerUserAndNote(t *testing.T) {
	app := newApp(t)
	u := save(t, app, "users", map[string]any{"email": "u@example.com"})
	note := save(t, app, "notes", map[string]any{"owner": u.Id, "kind": "text"})
	save(t, app, "note_state", map[string]any{"note": note.Id, "user": u.Id})

	c, _ := app.FindCollectionByNameOrId("note_state")
	dup := core.NewRecord(c)
	dup.Load(map[string]any{"note": note.Id, "user": u.Id})
	if err := app.Save(dup); err == nil {
		t.Fatal("second note_state for the same note and user saved, want unique violation")
	}
}

func TestDownReverses(t *testing.T) {
	app := newApp(t)
	if err := down(app); err != nil {
		t.Fatal(err)
	}
	if _, err := app.FindCollectionByNameOrId("notes"); err == nil {
		t.Fatal("notes still exists after down")
	}
}
