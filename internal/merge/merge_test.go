package merge

import (
	"encoding/json"
	"os"
	"strings"
	"testing"
)

type tcase struct {
	Name, Base, Current, Mine, Want string
}

// The cases the Dart port runs too (app/test/merge_test.dart).
func TestSharedCases(t *testing.T) {
	raw, err := os.ReadFile("testdata/cases.json")
	if err != nil {
		t.Fatal(err)
	}
	var cases []tcase
	if err := json.Unmarshal(raw, &cases); err != nil {
		t.Fatal(err)
	}
	for _, c := range cases {
		if got := Merge(c.Base, c.Current, c.Mine); got != c.Want {
			t.Errorf("%s: Merge(%q, %q, %q) = %q, want %q", c.Name, c.Base, c.Current, c.Mine, got, c.Want)
		}
	}
}

// Whatever either side wrote is somewhere in the result.
func TestNothingIsLost(t *testing.T) {
	base := "The quick brown fox jumps over the lazy dog"
	current := "The quick red fox jumps over the sleepy dog"
	mine := "The slow brown fox leaps over the lazy cat"
	got := Merge(base, current, mine)
	for _, w := range []string{"red", "sleepy", "slow", "leaps", "cat"} {
		if !strings.Contains(got, w) {
			t.Errorf("%q lost %q", got, w)
		}
	}
}

// A long text with an edit at each end merges at once (the common middle is
// trimmed, not compared token by token).
func TestLongText(t *testing.T) {
	mid := strings.Repeat("word ", 20000)
	got := Merge("start "+mid+"end", "begin "+mid+"end", "start "+mid+"finish")
	if !strings.HasPrefix(got, "begin ") || !strings.HasSuffix(got, "finish") {
		t.Fatalf("long merge = %q…%q", got[:12], got[len(got)-12:])
	}
}
