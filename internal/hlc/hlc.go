// Package hlc implements chit's hybrid logical clocks.
//
// A timestamp is "<unix ms, 13 digits>-<counter, 4 hex>-<device id>", so
// plain string comparison orders timestamps. The device id breaks ties
// between devices that write in the same millisecond with the same counter.
package hlc

import (
	"fmt"
	"regexp"
	"strconv"
	"sync"
	"time"
)

var format = regexp.MustCompile(`^(\d{13})-([0-9a-f]{4})-([a-z0-9]{1,16})$`)

// DeviceID reports whether s is usable as a device id.
func DeviceID(s string) bool {
	return regexp.MustCompile(`^[a-z0-9]{1,16}$`).MatchString(s)
}

// Parse splits a timestamp into its parts.
func Parse(s string) (ms int64, counter int, device string, err error) {
	m := format.FindStringSubmatch(s)
	if m == nil {
		return 0, 0, "", fmt.Errorf("bad hlc %q", s)
	}
	ms, _ = strconv.ParseInt(m[1], 10, 64)
	c, _ := strconv.ParseInt(m[2], 16, 32)
	return ms, int(c), m[3], nil
}

// Valid reports whether s is a well-formed timestamp.
func Valid(s string) bool { return format.MatchString(s) }

// Time returns the wall-clock part of a timestamp.
func Time(s string) (time.Time, error) {
	ms, _, _, err := Parse(s)
	if err != nil {
		return time.Time{}, err
	}
	return time.UnixMilli(ms), nil
}

// Clock issues increasing timestamps for one device.
type Clock struct {
	mu      sync.Mutex
	device  string
	ms      int64
	counter int
	now     func() time.Time
}

func New(device string) *Clock {
	return &Clock{device: device, now: time.Now}
}

// Now returns a timestamp greater than every one this clock has issued or
// observed.
func (c *Clock) Now() string {
	c.mu.Lock()
	defer c.mu.Unlock()
	ms := c.now().UnixMilli()
	if ms > c.ms {
		c.ms, c.counter = ms, 0
	} else {
		c.counter++
		if c.counter > 0xffff {
			c.ms, c.counter = c.ms+1, 0
		}
	}
	return fmt.Sprintf("%013d-%04x-%s", c.ms, c.counter, c.device)
}

// Observe moves the clock past a timestamp seen from another device, so the
// next write here sorts after it even if this device's wall clock is behind.
func (c *Clock) Observe(s string) {
	ms, counter, _, err := Parse(s)
	if err != nil {
		return
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if ms > c.ms || (ms == c.ms && counter > c.counter) {
		c.ms, c.counter = ms, counter
	}
}
