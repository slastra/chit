package migrations

import (
	"github.com/pocketbase/pocketbase/core"
	m "github.com/pocketbase/pocketbase/migrations"
	"github.com/pocketbase/pocketbase/tools/types"
)

// Accounts are invite-only, so everyone with one belongs to the household.
// Let any signed-in user list the others to pick who to share a note with.
// Emails still show only on accounts with emailVisibility set.
const directoryRule = `@request.auth.id != ""`

func init() {
	m.Register(func(app core.App) error {
		return setUsersReadRule(app, directoryRule)
	}, func(app core.App) error {
		return setUsersReadRule(app, "id = @request.auth.id")
	})
}

func setUsersReadRule(app core.App, rule string) error {
	users, err := app.FindCollectionByNameOrId("users")
	if err != nil {
		return err
	}
	users.ListRule = types.Pointer(rule)
	users.ViewRule = types.Pointer(rule)
	return app.Save(users)
}
