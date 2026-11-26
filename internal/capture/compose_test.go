package capture

import (
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func tempFile(t *testing.T, name string, data []byte) string {
	t.Helper()
	p := filepath.Join(t.TempDir(), name)
	if err := os.WriteFile(p, data, 0o600); err != nil {
		t.Fatal(err)
	}
	return p
}

var png = []byte("\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x00\x01\x00\x00\x00\x01\x08\x06\x00\x00\x00\x1f\x15\xc4\x89")

func TestCompose(t *testing.T) {
	img := tempFile(t, "receipt.png", png)
	pdf := tempFile(t, "quote.pdf", []byte("%PDF-1.4 hello"))
	cases := []struct {
		name    string
		d       Draft
		kind    string
		summary string
	}{
		{"titled note", Draft{Title: "Plumber", Body: "kitchen sink\nshutoff valve"}, NewNote, `New note "Plumber"`},
		{"body only, two lines, no auto title", Draft{Body: "line one\nline two"}, NewNote, "New note"},
		{"list", Draft{Title: "Packing", Body: "socks\n\nshirts\n", List: true}, NewList, `New list "Packing" with 2 items`},
		{"files only", Draft{Files: []string{img, pdf}}, NewNote, "New note with 2 files"},
		{"note with a file", Draft{Title: "Quote", Files: []string{pdf}}, NewNote, `New note "Quote" and 1 file`},
		{"quick grammar still works", Draft{Body: "groceries: butter"}, AddItems, `Add "butter" to Groceries`},
		{"quick grammar with a file", Draft{Body: "groceries: butter", Files: []string{img}}, AddItems, `Add "butter" to Groceries and attach 1 file`},
		{"attach to a note by name", Draft{Body: "groceries:", Files: []string{img}}, Attach, "Attach 1 file to Groceries"},
		{"a title turns the grammar off", Draft{Title: "Shopping", Body: "groceries: butter"}, NewNote, `New note "Shopping"`},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			p, err := Compose(c.d, snap)
			if err != nil {
				t.Fatal(err)
			}
			if p.Kind != c.kind || p.Summary != c.summary {
				t.Fatalf("plan = %+v", p)
			}
		})
	}
}

func TestComposeListItemsAndFiles(t *testing.T) {
	img := tempFile(t, "a.png", png)
	p, err := Compose(Draft{Title: "Packing", Body: " socks \nshirts", List: true, Files: []string{img}}, snap)
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(p.Items, []string{"socks", "shirts"}) || len(p.Files) != 1 || !p.Files[0].Image || p.Files[0].Type != "image/png" {
		t.Fatalf("plan = %+v", p)
	}
	n := 0
	ops := p.Ops(snap, func() string { n++; return "1795651200000-0000-desk" }, func() string { n++; return "id" + strings.Repeat("0", 12) + string(rune('a'+n%26)) })
	if ops[0].Field != "kind" || string(ops[0].Value) != `"list"` || len(ops) != 2+3*2 {
		t.Fatalf("ops = %+v", ops)
	}
}

func TestComposeRefusesBadFiles(t *testing.T) {
	big := filepath.Join(t.TempDir(), "big.bin")
	f, _ := os.Create(big)
	f.Truncate(MaxFileSize + 1)
	f.Close()
	if _, err := Compose(Draft{Title: "x", Files: []string{big}}, snap); err == nil || !strings.Contains(err.Error(), "25 MB") {
		t.Fatalf("big file err = %v", err)
	}
	if _, err := Compose(Draft{Title: "x", Files: []string{"/nonexistent/file"}}, snap); err == nil {
		t.Fatal("missing file accepted")
	}
	if _, err := Compose(Draft{Title: "x", Files: []string{t.TempDir()}}, snap); err == nil {
		t.Fatal("directory accepted")
	}
	if _, err := Compose(Draft{}, snap); err != ErrEmpty {
		t.Fatalf("empty draft err = %v", err)
	}
}

func TestComposeKeepsAGivenNoteID(t *testing.T) {
	p, _ := Compose(Draft{Title: "x"}, snap)
	p.NoteID = "fixed0000000001"
	ops := p.Ops(snap, func() string { return "1795651200000-0000-desk" }, func() string { return "other0000000001" })
	if ops[0].ID != "fixed0000000001" {
		t.Fatalf("ops = %+v", ops)
	}
}
