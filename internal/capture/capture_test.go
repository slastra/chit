package capture

import (
	"encoding/json"
	"fmt"
	"reflect"
	"strings"
	"testing"

	"github.com/slastra/chit/internal/protocol"
)

var snap = &protocol.Snapshot{
	Notes: []protocol.Note{
		{ID: "groceries000001", Kind: "list", Title: "Groceries"},
		{ID: "wifi00000000001", Kind: "text", Title: "Wifi", Body: "router in the closet"},
		{ID: "gifts0000000001", Kind: "list", Title: "Gift ideas"},
		{ID: "garden000000001", Kind: "list", Title: "Garden"},
		{ID: "old000000000001", Kind: "list", Title: "Old list", Trashed: "2026-11-01 00:00:00.000Z"},
	},
	Items: []protocol.Item{{ID: "item00000000001", Note: "groceries000001", Text: "milk", Order: "5"}},
}

func TestParse(t *testing.T) {
	cases := []struct {
		in      string
		kind    string
		note    string
		items   []string
		title   string
		text    string
		summary string
	}{
		{in: "groceries: milk, eggs", kind: AddItems, note: "groceries000001", items: []string{"milk", "eggs"}, summary: `Add "milk", "eggs" to Groceries`},
		{in: "Groc: coffee", kind: AddItems, note: "groceries000001", items: []string{"coffee"}},
		{in: "gift ideas: scarf", kind: AddItems, note: "gifts0000000001", items: []string{"scarf"}},
		{in: "wifi: guest code 1234", kind: AppendText, note: "wifi00000000001", text: "guest code 1234", summary: "Add a line to Wifi"},
		{in: "call the dentist", kind: NewNote, text: "call the dentist", summary: "New note"},
		{in: "re: taxes are due", kind: NewNote, text: "re: taxes are due"}, // "re" is in "Groceries" but not a prefix
		{in: "meet at 3:30", kind: NewNote, text: "meet at 3:30"},           // no note called "meet at 3"
		{in: "old list: thing", kind: NewNote, text: "old list: thing"},     // trashed notes are not targets
		{in: "groceries:", kind: NewNote, text: "groceries:"},               // nothing after the colon
		{in: "Packing\nsocks and a charger", kind: NewNote, title: "Packing", text: "socks and a charger", summary: `New note "Packing"`},
	}
	for _, c := range cases {
		t.Run(c.in, func(t *testing.T) {
			p, err := Parse(c.in, snap)
			if err != nil {
				t.Fatal(err)
			}
			if p.Kind != c.kind || p.NoteID != c.note || p.Title != c.title || p.Text != c.text || (c.items != nil && !reflect.DeepEqual(p.Items, c.items)) {
				t.Fatalf("plan = %+v", p)
			}
			if c.summary != "" && p.Summary != c.summary {
				t.Fatalf("summary = %q, want %q", p.Summary, c.summary)
			}
		})
	}
}

func TestAmbiguousPrefixIsAnError(t *testing.T) {
	_, err := Parse("g: thing", snap) // one letter: too short to target anything
	if err != nil {
		t.Fatalf("one-letter prefix: %v", err)
	}
	if _, err := Parse("ga: thing", snap); err != nil { // only Garden
		t.Fatal(err)
	}
	if _, err := Parse("gi: x", snap); err != nil { // only Gift ideas
		t.Fatal(err)
	}
	two := &protocol.Snapshot{Notes: append(snap.Notes, protocol.Note{ID: "gro2", Kind: "list", Title: "Grocery run"})}
	if _, err := Parse("groc: milk", two); err == nil || !strings.Contains(err.Error(), "could be") {
		t.Fatalf("ambiguous prefix err = %v", err)
	}
}

func TestEmpty(t *testing.T) {
	if _, err := Parse("   ", snap); err != ErrEmpty {
		t.Fatalf("err = %v", err)
	}
}

func TestOps(t *testing.T) {
	n := 0
	now := func() string { n++; return fmt.Sprintf("1795651200000-%04x-desk", n) }
	ids := 0
	newID := func() string { ids++; return fmt.Sprintf("new%012d", ids) }

	p, _ := Parse("groceries: eggs, coffee", snap)
	ops := p.Ops(snap, now, newID)
	if len(ops) != 6 {
		t.Fatalf("ops = %d", len(ops))
	}
	var orders []string
	for _, o := range ops {
		if o.Field == "order" {
			var k string
			json.Unmarshal(o.Value, &k)
			orders = append(orders, k)
		}
	}
	if len(orders) != 2 || orders[0] <= "5" || orders[1] <= orders[0] {
		t.Fatalf("new items do not sort after the last one: %v", orders)
	}

	p, _ = Parse("wifi: guest code 1234", snap)
	ops = p.Ops(snap, now, newID)
	var body string
	json.Unmarshal(ops[0].Value, &body)
	if body != "router in the closet\nguest code 1234" {
		t.Fatalf("body = %q", body)
	}
}
