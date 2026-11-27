package server

import "testing"

func TestRefineType(t *testing.T) {
	for _, c := range []struct{ sniffed, name, want string }{
		// AAC in MP4 sniffs as video; the name says it is sound
		{"video/mp4", "Voice memo, Nov 26 14.29.m4a", "audio/mp4"},
		{"video/mp4", "MEMO.M4A", "audio/mp4"},
		{"video/webm", "memo.weba", "audio/webm"},
		{"application/ogg", "memo.opus", "audio/ogg"},
		{"video/mp4", "clip.mp4", "video/mp4"},
		{"image/png", "odd.m4a", "image/png"},
		{"application/octet-stream", "notes.pdf", "application/pdf"},
		{"application/octet-stream", "mystery", "application/octet-stream"},
	} {
		if got := refineType(c.sniffed, c.name); got != c.want {
			t.Errorf("refineType(%q, %q) = %q, want %q", c.sniffed, c.name, got, c.want)
		}
	}
}
