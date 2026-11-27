// Package merge joins two edits of the same text made from a common
// starting point (a three-way merge), word by word, so neither is lost.
//
// The Flutter app has the same algorithm (app/lib/core/merge.dart) and the
// two share testdata/cases.json: a live merge on a device and the server's
// merge must agree. Keep them in step.
package merge

import "regexp"

// tokens splits text into words and the runs of whitespace between them,
// so joining the tokens gives the text back. Whitespace is its own token:
// "milk" at the end of a line and "milk" before a space are the same word.
var token = regexp.MustCompile(`\s+|\S+`)

func tokens(s string) []string { return token.FindAllString(s, -1) }

// maxCells bounds the comparison table: past it, a changed middle is not
// compared token by token, and the two edits of it are kept side by side.
const maxCells = 2_000_000

// match pairs the tokens of x with equal tokens of y, in order, as many as
// possible (a longest common subsequence): m[i] is the index in y that x[i]
// matches, or -1. Deterministic: the same in Dart, tie for tie.
func match(x, y []string) []int {
	m := make([]int, len(x))
	for i := range m {
		m[i] = -1
	}
	// the common start and end, which is most of a typical edit
	p := 0
	for p < len(x) && p < len(y) && x[p] == y[p] {
		m[p] = p
		p++
	}
	sx, sy := len(x), len(y)
	for sx > p && sy > p && x[sx-1] == y[sy-1] {
		sx--
		sy--
		m[sx] = sy
	}
	n, k := sx-p, sy-p
	if n == 0 || k == 0 || n*k > maxCells {
		return m
	}
	// lengths of the longest common subsequence of every pair of suffixes
	w := k + 1
	dp := make([]int32, (n+1)*w)
	for i := n - 1; i >= 0; i-- {
		for j := k - 1; j >= 0; j-- {
			if x[p+i] == y[p+j] {
				dp[i*w+j] = dp[(i+1)*w+j+1] + 1
			} else if a, b := dp[(i+1)*w+j], dp[i*w+j+1]; a >= b {
				dp[i*w+j] = a
			} else {
				dp[i*w+j] = b
			}
		}
	}
	for i, j := 0, 0; i < n && j < k; {
		switch {
		case x[p+i] == y[p+j]:
			m[p+i] = p + j
			i++
			j++
		case dp[(i+1)*w+j] >= dp[i*w+j+1]:
			i++
		default:
			j++
		}
	}
	return m
}

func join(ts []string) string {
	n := 0
	for _, t := range ts {
		n += len(t)
	}
	b := make([]byte, 0, n)
	for _, t := range ts {
		b = append(b, t...)
	}
	return string(b)
}

func same(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

// Merge joins current (what is there now) and mine (an edit made from
// base). A stretch only one side changed takes that side's change; where
// both changed the same stretch differently, both are kept, current's
// first, so nothing either wrote is lost.
func Merge(base, current, mine string) string {
	if current == mine || base == mine {
		return current
	}
	if base == current {
		return mine
	}
	b, c, m := tokens(base), tokens(current), tokens(mine)
	toC, toM := match(b, c), match(b, m)
	var out []string
	i, ci, mi := 0, 0, 0
	for {
		// the next base token both sides kept: a point the three agree on
		j := i
		for j < len(b) && (toC[j] < ci || toM[j] < mi) {
			j++
		}
		cj, mj := len(c), len(m)
		if j < len(b) {
			cj, mj = toC[j], toM[j]
		}
		bs, cs, ms := b[i:j], c[ci:cj], m[mi:mj]
		switch {
		case same(cs, bs):
			out = append(out, ms...)
		case same(ms, bs), same(cs, ms):
			out = append(out, cs...)
		default:
			// both changed this stretch: keep both
			out = append(out, cs...)
			if len(cs) > 0 && len(ms) > 0 && !endsInSpace(cs[len(cs)-1]) && !startsWithSpace(ms[0]) {
				out = append(out, " ")
			}
			out = append(out, ms...)
		}
		if j >= len(b) {
			break
		}
		out = append(out, b[j])
		i, ci, mi = j+1, cj+1, mj+1
	}
	return join(out)
}

func endsInSpace(t string) bool {
	if t == "" {
		return false
	}
	switch t[len(t)-1] {
	case ' ', '\n', '\t', '\r':
		return true
	}
	return false
}

func startsWithSpace(t string) bool {
	if t == "" {
		return false
	}
	switch t[0] {
	case ' ', '\n', '\t', '\r':
		return true
	}
	return false
}
