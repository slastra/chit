// Package protocol holds the wire types shared by chit-server, chitd and the
// CLI. docs/design.md describes the same contract in prose; the Android app
// mirrors these shapes.
package protocol

import "encoding/json"

// Collections that clients write through ops.
const (
	Notes     = "notes"
	Items     = "items"
	Labels    = "labels"
	NoteState = "note_state"
	Members   = "note_members"
)

// Op sets one field of one record. For note_state, ID is the note's id: each
// user has exactly one state row per note, and the server finds it.
type Op struct {
	Collection string          `json:"collection"`
	ID         string          `json:"id"`
	Field      string          `json:"field"`
	Value      json.RawMessage `json:"value"`
	HLC        string          `json:"hlc"`
}

type OpsRequest struct {
	Device string `json:"device"`
	Ops    []Op   `json:"ops"`
}

// OpResult reports one op, in request order. Stale means a newer write already
// holds the field; the client keeps the value it gets from the feed.
type OpResult struct {
	Applied bool   `json:"applied"`
	Stale   bool   `json:"stale,omitempty"`
	Error   string `json:"error,omitempty"`
}

type OpsResponse struct {
	Seq     int64      `json:"seq"`
	Results []OpResult `json:"results"`
}

// Change kinds in the feed.
const (
	// KindSet: one field changed. Field, Value and HLC are set.
	KindSet = "set"
	// KindRecord: a whole record, sent on create and when a note is shared
	// with someone. Value is the record (Note, Item, Member, State or Label).
	KindRecord = "record"
	// KindRemove: the record is gone (a membership that ended).
	KindRemove = "remove"
	// KindRevoke: the reader lost access to note Record; drop it locally.
	KindRevoke = "revoke"
)

type Change struct {
	Seq        int64           `json:"seq"`
	Kind       string          `json:"kind"`
	Collection string          `json:"collection"`
	Record     string          `json:"record"`
	Field      string          `json:"field,omitempty"`
	Value      json.RawMessage `json:"value,omitempty"`
	HLC        string          `json:"hlc,omitempty"`
	By         string          `json:"by,omitempty"`
}

type ChangesResponse struct {
	Changes []Change `json:"changes"`
	// Seq is the cursor for the next request.
	Seq int64 `json:"seq"`
	// More is true when the page was full; ask again from Seq.
	More bool `json:"more"`
}

// Clocks maps field name to the HLC of that field's last write.
type Clocks map[string]string

type Note struct {
	ID      string `json:"id"`
	Owner   string `json:"owner"`
	Kind    string `json:"kind"`
	Title   string `json:"title"`
	Body    string `json:"body"`
	Color   string `json:"color"`
	Trashed string `json:"trashed"`
	Deleted bool   `json:"deleted"`
	Clocks  Clocks `json:"clocks"`
	Created string `json:"created"`
	Updated string `json:"updated"`
}

type Item struct {
	ID      string `json:"id"`
	Note    string `json:"note"`
	Text    string `json:"text"`
	Checked bool   `json:"checked"`
	Order   string `json:"order"`
	Indent  int    `json:"indent"`
	Deleted bool   `json:"deleted"`
	Clocks  Clocks `json:"clocks"`
}

type Member struct {
	ID   string `json:"id"`
	Note string `json:"note"`
	User string `json:"user"`
	Role string `json:"role"`
}

type State struct {
	Note         string   `json:"note"`
	Pinned       bool     `json:"pinned"`
	Archived     bool     `json:"archived"`
	Labels       []string `json:"labels"`
	Reminder     string   `json:"reminder"`
	ReminderDone bool     `json:"reminder_done"`
	Clocks       Clocks   `json:"clocks"`
}

type Label struct {
	ID      string `json:"id"`
	Name    string `json:"name"`
	Deleted bool   `json:"deleted"`
	Clocks  Clocks `json:"clocks"`
}

// Snapshot is everything the caller can see, as of Seq. Deleted records are
// left out. A client that gets a reset event replaces its replica with this.
type Snapshot struct {
	Seq     int64    `json:"seq"`
	Notes   []Note   `json:"notes"`
	Items   []Item   `json:"items"`
	Members []Member `json:"members"`
	State   []State  `json:"state"`
	Labels  []Label  `json:"labels"`
}

type ShareRequest struct {
	User string `json:"user"`
	Role string `json:"role"`
}

type SeqResponse struct {
	Seq int64 `json:"seq"`
}

// Person is an account on the instance.
type Person struct {
	ID    string `json:"id"`
	Name  string `json:"name"`
	Email string `json:"email"`
}
