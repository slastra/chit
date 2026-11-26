package hlc

import (
	"testing"
	"time"
)

func fixed(ms int64) func() time.Time {
	return func() time.Time { return time.UnixMilli(ms) }
}

func TestNowIncreasesWithinOneMillisecond(t *testing.T) {
	c := New("dev1")
	c.now = fixed(1795651200000)
	prev := ""
	for i := 0; i < 1000; i++ {
		h := c.Now()
		if !Valid(h) {
			t.Fatalf("invalid hlc %q", h)
		}
		if h <= prev {
			t.Fatalf("%q not after %q", h, prev)
		}
		prev = h
	}
}

func TestNowSurvivesClockGoingBackwards(t *testing.T) {
	c := New("dev1")
	c.now = fixed(1795651200500)
	a := c.Now()
	c.now = fixed(1795651200000)
	if b := c.Now(); b <= a {
		t.Fatalf("%q not after %q after the wall clock stepped back", b, a)
	}
}

func TestObserveOrdersAfterRemote(t *testing.T) {
	c := New("slow")
	c.now = fixed(1795651200000)
	remote := "1795651299999-0007-fast"
	c.Observe(remote)
	if h := c.Now(); h <= remote {
		t.Fatalf("%q not after observed %q", h, remote)
	}
}

func TestCounterOverflowCarries(t *testing.T) {
	c := New("d")
	c.now = fixed(1795651200000)
	prev := c.Now()
	for i := 0; i < 0x10005; i++ {
		h := c.Now()
		if h <= prev {
			t.Fatalf("%q not after %q at step %d", h, prev, i)
		}
		prev = h
	}
}

func TestParseRejectsMalformed(t *testing.T) {
	for _, s := range []string{"", "1795651200000-0000-", "179565120000-0000-d", "1795651200000-00000-d", "1795651200000-0000-D"} {
		if Valid(s) {
			t.Errorf("Valid(%q) = true", s)
		}
	}
}
