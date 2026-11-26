package server

import (
	"database/sql"
	"encoding/json"

	"github.com/pocketbase/dbx"
	"github.com/pocketbase/pocketbase/core"

	"github.com/slastra/chit/internal/protocol"
)

const pageSize = 500

// entry is one row to append to chit_changes.
type entry struct {
	scope      string // "note" or "user"
	user       string // reader, for scope "user"
	note       string // note the row belongs to
	kind       string
	collection string
	record     string
	field      string
	value      json.RawMessage
	hlc        string
	by         string
	device     string
}

func appendChange(tx core.App, e entry) (int64, error) {
	res, err := tx.DB().NewQuery(`
		INSERT INTO chit_changes (scope, user, note, kind, collection, record, field, value, hlc, by, device)
		VALUES ({:scope}, {:user}, {:note}, {:kind}, {:collection}, {:record}, {:field}, {:value}, {:hlc}, {:by}, {:device})
	`).Bind(dbx.Params{
		"scope": e.scope, "user": e.user, "note": e.note, "kind": e.kind,
		"collection": e.collection, "record": e.record, "field": e.field,
		"value": string(e.value), "hlc": e.hlc, "by": e.by, "device": e.device,
	}).Execute()
	if err != nil {
		return 0, err
	}
	return res.LastInsertId()
}

// head is the newest seq in the log, 0 when it is empty.
func head(app core.App) (int64, error) {
	var seq sql.NullInt64
	err := app.DB().NewQuery("SELECT MAX(seq) FROM chit_changes").Row(&seq)
	return seq.Int64, err
}

type changeRow struct {
	Seq        int64  `db:"seq"`
	Kind       string `db:"kind"`
	Collection string `db:"collection"`
	Record     string `db:"record"`
	Field      string `db:"field"`
	Value      string `db:"value"`
	HLC        string `db:"hlc"`
	By         string `db:"by"`
}

// changesFor returns the changes after since that userID may see, leaving
// out the ones device itself sent. Visibility is checked against current
// membership, so a reader who just lost a note stops seeing it at once.
func changesFor(app core.App, userID, device string, since int64) (*protocol.ChangesResponse, error) {
	out := &protocol.ChangesResponse{Changes: []protocol.Change{}, Seq: since}
	err := app.RunInTransaction(func(tx core.App) error {
		top, err := head(tx)
		if err != nil {
			return err
		}
		var rows []changeRow
		err = tx.DB().NewQuery(`
			SELECT seq, kind, collection, record, field, value, hlc, by FROM chit_changes
			WHERE seq > {:since}
			  AND ({:device} = '' OR NOT (device = {:device} AND by = {:me}))
			  AND ((scope = 'user' AND user = {:me})
			    OR (scope = 'note' AND note IN (` + visibleNotes + `)))
			ORDER BY seq LIMIT {:limit}
		`).Bind(dbx.Params{"since": since, "device": device, "me": userID, "limit": pageSize}).All(&rows)
		if err != nil {
			return err
		}
		for _, r := range rows {
			c := protocol.Change{
				Seq: r.Seq, Kind: r.Kind, Collection: r.Collection, Record: r.Record,
				Field: r.Field, HLC: r.HLC, By: r.By,
			}
			if r.Value != "" {
				c.Value = json.RawMessage(r.Value)
			}
			out.Changes = append(out.Changes, c)
		}
		if len(rows) == pageSize {
			out.Seq, out.More = rows[len(rows)-1].Seq, true
		} else if top > since {
			// Nothing else visible up to top, so skip past rows for others.
			out.Seq = top
		}
		return nil
	})
	return out, err
}
