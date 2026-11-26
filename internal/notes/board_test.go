package notes

import (
	"sort"
	"strings"
	"testing"

	"github.com/slastra/chit/internal/protocol"
)

// The same cases as app/test/board_order_test.dart: the two must agree.
func TestBoardOrder(t *testing.T) {
	ns := []protocol.Note{
		{ID: "a", Created: "2026-11-01"},
		{ID: "b", Created: "2026-11-02"},
		{ID: "c", Created: "2026-11-03"},
		{ID: "d", Created: "2026-11-04"},
		{ID: "e", Created: "2026-11-05"},
		{ID: "f", Created: "2026-11-05"},
	}
	st := map[string]protocol.State{
		"a": {Order: "V"},
		"b": {Order: "1"},
		"c": {Order: "bad0"}, // invalid: no place
		"d": {Pinned: true, Order: "k"},
		"e": {},
		"f": {},
	}
	sort.SliceStable(ns, func(i, j int) bool { return BoardBefore(ns[i], ns[j], st[ns[i].ID], st[ns[j].ID]) })
	var got []string
	for _, n := range ns {
		got = append(got, n.ID)
	}
	if want := "d f e c b a"; strings.Join(got, " ") != want {
		t.Fatalf("board order = %v, want %v", got, want)
	}
}
