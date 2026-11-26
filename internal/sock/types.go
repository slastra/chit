// Package sock is chitd's socket protocol: the request and reply types, the
// pushed events, and a client. It has no storage dependencies, so the CLI
// stays small.
package sock

import (
	"github.com/slastra/chit/internal/capture"
	"github.com/slastra/chit/internal/protocol"
)

// Status is what the daemon reports about itself.
type Status struct {
	Online   bool            `json:"online"`
	SignedIn bool            `json:"signed_in"`
	Pending  int             `json:"pending"`
	Server   string          `json:"server"`
	User     protocol.Person `json:"user"`
	Error    string          `json:"error,omitempty"`
}

// Request is one line from a client. Op names the call; Req is echoed in the
// reply so a client can match it.
type Request struct {
	Op      string        `json:"op"`
	Req     string        `json:"req,omitempty"`
	Ops     []protocol.Op `json:"ops,omitempty"`
	Text    string        `json:"text,omitempty"`
	Note    string        `json:"note,omitempty"`
	Item    string        `json:"item,omitempty"`
	On      bool          `json:"on,omitempty"`
	Seconds int           `json:"seconds,omitempty"`
	Changes bool          `json:"changes,omitempty"` // subscribe: also stream changes
	Fresh   bool          `json:"fresh,omitempty"`   // people: skip the cache
	// compose, compose-preview: the composer's draft
	Draft *capture.Draft `json:"draft,omitempty"`
	// files: paths to check before attaching
	Paths []string `json:"paths,omitempty"`
}

// Reply answers one Request.
type Reply struct {
	Req      string              `json:"req,omitempty"`
	OK       bool                `json:"ok"`
	Error    string              `json:"error,omitempty"`
	Status   *Status             `json:"status,omitempty"`
	Snapshot *protocol.Snapshot  `json:"snapshot,omitempty"`
	Results  []protocol.OpResult `json:"results,omitempty"`
	People   []protocol.Person   `json:"people,omitempty"`
	Plan     *capture.Plan       `json:"plan,omitempty"`
	Files    []capture.File      `json:"files,omitempty"`
}

// ChangeEvent carries one change to subscribers that asked for them.
type ChangeEvent struct {
	Event  string          `json:"event"` // "change"
	Change protocol.Change `json:"change"`
}

// StateEvent is what lastshell renders: the daemon's status plus notes
// trimmed for QML, pinned first, then most recently updated.
type StateEvent struct {
	Event string `json:"event"` // "state"
	Status
	Notes []ShellNote `json:"notes"`
}

type ShellNote struct {
	ID          string      `json:"id"`
	Title       string      `json:"title"`
	Kind        string      `json:"kind"`
	Color       string      `json:"color"`
	Body        string      `json:"body"`
	Pinned      bool        `json:"pinned"`
	Archived    bool        `json:"archived"`
	Shared      bool        `json:"shared"`
	Open        int         `json:"open"`
	Done        int         `json:"done"`
	Items       []ShellItem `json:"items"`
	Attachments int         `json:"attachments"`
	Reminder    string      `json:"reminder"`
	Updated     string      `json:"updated"`
}

type ShellItem struct {
	ID      string `json:"id"`
	Text    string `json:"text"`
	Checked bool   `json:"checked"`
	Indent  int    `json:"indent"`
}
