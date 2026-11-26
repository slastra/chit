package main

import (
	"testing"
	"time"
)

func TestParseWhen(t *testing.T) {
	loc := time.FixedZone("CST", -6*3600)
	now := time.Date(2026, 11, 26, 16, 0, 0, 0, loc)
	cases := map[string]time.Time{
		"10m":              now.Add(10 * time.Minute),
		"in 2h":            now.Add(2 * time.Hour),
		"17:30":            time.Date(2026, 11, 26, 17, 30, 0, 0, loc),
		"15:30":            time.Date(2026, 11, 27, 15, 30, 0, 0, loc), // already past today
		"tomorrow 9:00":    time.Date(2026, 11, 27, 9, 0, 0, 0, loc),
		"tomorrow":         time.Date(2026, 11, 27, 9, 0, 0, 0, loc),
		"5pm":              time.Date(2026, 11, 26, 17, 0, 0, 0, loc),
		"2026-12-01 09:00": time.Date(2026, 12, 1, 9, 0, 0, 0, loc),
	}
	for in, want := range cases {
		got, err := parseWhen(in, now)
		if err != nil || !got.Equal(want) {
			t.Errorf("parseWhen(%q) = %v, %v; want %v", in, got, err, want)
		}
	}
	if _, err := parseWhen("next blue moon", now); err == nil {
		t.Error("nonsense parsed")
	}
}
