package capture

import (
	"fmt"
	"mime"
	"net/http"
	"os"
	"path/filepath"
	"strings"

	"github.com/slastra/chit/internal/protocol"
)

// MaxFileSize matches the server's attachment limit.
const MaxFileSize = 25 << 20

// Draft is what the composer holds: an optional title, the body, whether
// the body is a list (one item per line), and files to attach.
type Draft struct {
	Title string   `json:"title"`
	Body  string   `json:"body"`
	List  bool     `json:"list"`
	Files []string `json:"files"` // local paths
}

// File describes one file to attach, checked before anything is saved.
type File struct {
	Path  string `json:"path"`
	Name  string `json:"name"`
	Size  int64  `json:"size"`
	Type  string `json:"type"`
	Image bool   `json:"image"`
	Error string `json:"error,omitempty"`
}

// Inspect checks a path for attaching: a regular file within the size limit.
func Inspect(path string) File {
	f := File{Path: path, Name: filepath.Base(path)}
	st, err := os.Stat(path)
	switch {
	case err != nil:
		f.Error = "can't read it"
		return f
	case !st.Mode().IsRegular():
		f.Error = "not a file"
		return f
	}
	f.Size = st.Size()
	if f.Size > MaxFileSize {
		f.Error = "over the 25 MB limit"
	}
	f.Type = sniff(path)
	f.Image = strings.HasPrefix(f.Type, "image/")
	return f
}

func sniff(path string) string {
	t := "application/octet-stream"
	if fh, err := os.Open(path); err == nil {
		buf := make([]byte, 512)
		n, _ := fh.Read(buf)
		fh.Close()
		t = http.DetectContentType(buf[:n])
	}
	if t == "application/octet-stream" || strings.HasPrefix(t, "text/plain") {
		if byExt := mime.TypeByExtension(strings.ToLower(filepath.Ext(path))); byExt != "" {
			return byExt
		}
	}
	return t
}

// Compose decides what saving a draft does. With no title, a single body
// line keeps the quick grammar: "groceries: milk" adds to that list, and
// "groceries:" with files attached puts the files on Groceries.
func Compose(d Draft, snap *protocol.Snapshot) (Plan, error) {
	title := strings.TrimSpace(d.Title)
	body := strings.TrimRight(d.Body, " \n\t")
	var files []File
	for _, p := range d.Files {
		f := Inspect(p)
		if f.Error != "" {
			return Plan{}, fmt.Errorf("%s: %s", f.Name, f.Error)
		}
		files = append(files, f)
	}
	if title == "" && body == "" && len(files) == 0 {
		return Plan{}, ErrEmpty
	}

	if title == "" && !d.List && !strings.Contains(body, "\n") {
		line := strings.TrimSpace(body)
		if name, ok := strings.CutSuffix(line, ":"); ok && len(files) > 0 {
			n, found, err := target(snap, strings.TrimSpace(name))
			if err != nil {
				return Plan{}, err
			}
			if found {
				p := Plan{Kind: Attach, NoteID: n.ID, Target: n.Title, Files: files}
				p.Summary = fmt.Sprintf("Attach %s to %s", count(len(files), "file"), n.Title)
				return p, nil
			}
		}
		if line != "" {
			p, err := Parse(line, snap)
			if err != nil {
				return Plan{}, err
			}
			if p.Kind != NewNote {
				p.Files = files
				if len(files) > 0 {
					p.Summary += " and attach " + count(len(files), "file")
				}
				return p, nil
			}
		}
	}

	if d.List {
		var items []string
		for _, l := range strings.Split(body, "\n") {
			if t := strings.TrimSpace(l); t != "" {
				items = append(items, t)
			}
		}
		p := Plan{Kind: NewList, Title: title, Items: items, Files: files}
		p.Summary = "New list" + quoted(title) + " with " + count(len(items), "item") + withFiles(len(files))
		return p, nil
	}
	p := Plan{Kind: NewNote, Title: title, Text: strings.TrimSpace(body), Files: files}
	p.Summary = "New note" + quoted(title) + withFiles(len(files))
	if p.Title == "" && p.Text == "" && len(files) > 0 {
		p.Summary = "New note with " + count(len(files), "file")
	}
	return p, nil
}

func quoted(s string) string {
	if s == "" {
		return ""
	}
	return fmt.Sprintf(" %q", s)
}

func count(n int, word string) string {
	if n == 1 {
		return "1 " + word
	}
	return fmt.Sprintf("%d %ss", n, word)
}

func withFiles(n int) string {
	if n == 0 {
		return ""
	}
	return " and " + count(n, "file")
}
