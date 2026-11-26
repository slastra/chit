package order

import "testing"

// TestKnownCases pins values the Dart port (app/test/core_test.dart) checks too.
func TestKnownCases(t *testing.T) {
	for _, c := range []struct{ got, want string }{
		{After(""), "1"},
		{After("z"), "z1"},
		{Between("", "1"), "0V"},
		{Between("a", "b"), "aV"},
	} {
		if c.got != c.want {
			t.Errorf("got %q, want %q", c.got, c.want)
		}
	}
}
