// Package order generates fractional index keys for checklist items.
//
// Keys are strings over a base-62 alphabet in ASCII order, so byte-wise
// comparison (Go, SQLite, Kotlin) sorts them. A key never ends in '0', which
// keeps a key strictly between any two others always available.
package order

const digits = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"

func digit(c byte) int {
	switch {
	case c >= '0' && c <= '9':
		return int(c - '0')
	case c >= 'A' && c <= 'Z':
		return int(c-'A') + 10
	case c >= 'a' && c <= 'z':
		return int(c-'a') + 36
	}
	return 0
}

// Valid reports whether k is a usable key.
func Valid(k string) bool {
	if k == "" || k[len(k)-1] == '0' {
		return false
	}
	for i := 0; i < len(k); i++ {
		c := k[i]
		if !(c >= '0' && c <= '9' || c >= 'A' && c <= 'Z' || c >= 'a' && c <= 'z') {
			return false
		}
	}
	return true
}

// After returns a key that sorts after a ("" means the list is empty). It
// steps the first digit it can, and when every digit is 'z' it extends the
// key with '1', so appending grows the key one character per 61 appends.
func After(a string) string {
	for i := 0; i < len(a); i++ {
		if d := digit(a[i]); d < len(digits)-1 {
			return a[:i] + string(digits[d+1])
		}
	}
	return a + string(digits[1])
}

// Before returns a key that sorts before b ("" means the list is empty).
func Before(b string) string {
	if b == "" {
		return After("")
	}
	return Between("", b)
}

// Between returns a key strictly between a and b. Either may be "", meaning
// the start or the end of the list. It panics unless a < b.
func Between(a, b string) string {
	if b != "" && a >= b {
		panic("order.Between: a must sort before b")
	}
	if b == "" {
		return After(a)
	}
	return midpoint(a, b)
}

// midpoint returns a key between a and b, where b == "" stands for the end.
func midpoint(a, b string) string {
	if b != "" {
		n := 0
		for n < len(b) {
			ca := byte('0')
			if n < len(a) {
				ca = a[n]
			}
			if ca != b[n] {
				break
			}
			n++
		}
		if n > 0 {
			rest := ""
			if n < len(a) {
				rest = a[n:]
			}
			return b[:n] + midpoint(rest, b[n:])
		}
	}
	da := 0
	if a != "" {
		da = digit(a[0])
	}
	db := len(digits)
	if b != "" {
		db = digit(b[0])
	}
	if db-da > 1 {
		return string(digits[(da+db+1)/2])
	}
	if len(b) > 1 {
		return b[:1]
	}
	rest := ""
	if len(a) > 1 {
		rest = a[1:]
	}
	return string(digits[da]) + midpoint(rest, "")
}
