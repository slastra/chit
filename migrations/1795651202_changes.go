package migrations

import (
	"github.com/pocketbase/pocketbase/core"
	m "github.com/pocketbase/pocketbase/migrations"
)

// chit_changes is the sync log. It is a plain table, not a collection: only
// chit's routes read and write it, and seq must be a real autoincrement.
//
// scope decides who sees a row: "note" rows go to everyone who can see note,
// "user" rows only to user.
func init() {
	m.Register(func(app core.App) error {
		_, err := app.DB().NewQuery(`
			CREATE TABLE chit_changes (
				seq        INTEGER PRIMARY KEY AUTOINCREMENT,
				scope      TEXT NOT NULL,
				user       TEXT NOT NULL DEFAULT '',
				note       TEXT NOT NULL DEFAULT '',
				kind       TEXT NOT NULL,
				collection TEXT NOT NULL,
				record     TEXT NOT NULL,
				field      TEXT NOT NULL DEFAULT '',
				value      TEXT NOT NULL DEFAULT '',
				hlc        TEXT NOT NULL DEFAULT '',
				by         TEXT NOT NULL DEFAULT '',
				device     TEXT NOT NULL DEFAULT '',
				created    TEXT NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%fZ'))
			);
			CREATE INDEX idx_chit_changes_user ON chit_changes (scope, user, seq);
			CREATE INDEX idx_chit_changes_note ON chit_changes (scope, note, seq);
		`).Execute()
		return err
	}, func(app core.App) error {
		_, err := app.DB().NewQuery(`DROP TABLE IF EXISTS chit_changes`).Execute()
		return err
	})
}
