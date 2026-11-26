package order

import (
	"math/rand/v2"
	"slices"
	"testing"
)

func TestAppendStaysOrderedAndShort(t *testing.T) {
	k := ""
	for i := 0; i < 1000; i++ {
		next := After(k)
		if !Valid(next) || next <= k {
			t.Fatalf("After(%q) = %q", k, next)
		}
		k = next
	}
	if len(k) > 20 {
		t.Fatalf("1000 appends grew the key to %d chars (%q)", len(k), k)
	}
}

func TestPrependStaysOrdered(t *testing.T) {
	k := After("")
	for i := 0; i < 200; i++ {
		prev := Before(k)
		if !Valid(prev) || prev >= k {
			t.Fatalf("Before(%q) = %q", k, prev)
		}
		k = prev
	}
}

func TestRandomInsertsKeepOrder(t *testing.T) {
	r := rand.New(rand.NewPCG(1, 2))
	keys := []string{After("")}
	for i := 0; i < 2000; i++ {
		at := r.IntN(len(keys) + 1)
		a, b := "", ""
		if at > 0 {
			a = keys[at-1]
		}
		if at < len(keys) {
			b = keys[at]
		}
		k := Between(a, b)
		if !Valid(k) || (a != "" && k <= a) || (b != "" && k >= b) {
			t.Fatalf("Between(%q, %q) = %q", a, b, k)
		}
		keys = slices.Insert(keys, at, k)
	}
	if !slices.IsSorted(keys) {
		t.Fatal("keys out of order")
	}
}

func TestBetweenAdjacentDigits(t *testing.T) {
	for _, c := range [][2]string{{"1", "2"}, {"a", "b"}, {"az", "b"}, {"", "1"}, {"y", "z"}, {"zz", ""}} {
		k := Between(c[0], c[1])
		if !Valid(k) || (c[0] != "" && k <= c[0]) || (c[1] != "" && k >= c[1]) {
			t.Errorf("Between(%q, %q) = %q", c[0], c[1], k)
		}
	}
}
