package daemon

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/slastra/chit/internal/capture"
	"github.com/slastra/chit/internal/config"
	"github.com/slastra/chit/internal/notes"
	"github.com/slastra/chit/internal/protocol"
	"github.com/slastra/chit/internal/sock"
)

func jsonOf(v any) json.RawMessage {
	b, _ := json.Marshal(v)
	return b
}

// listen opens the socket, refusing to steal one a live chitd still holds.
func listen(path string) (net.Listener, error) {
	if c, err := net.DialTimeout("unix", path, time.Second); err == nil {
		c.Close()
		return nil, fmt.Errorf("%s is in use: is chitd already running?", path)
	}
	_ = os.Remove(path)
	ln, err := net.Listen("unix", path)
	if err != nil {
		return nil, err
	}
	if err := os.Chmod(path, 0o600); err != nil {
		ln.Close()
		return nil, err
	}
	return ln, nil
}

// conn is one socket client. Writes come from its own reader and from pushes,
// so they are serialized.
type conn struct {
	nc net.Conn
	mu sync.Mutex
}

func (c *conn) send(v any) {
	b, err := json.Marshal(v)
	if err != nil {
		return
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	_ = c.nc.SetWriteDeadline(time.Now().Add(5 * time.Second))
	_, _ = c.nc.Write(append(b, '\n'))
}

func (d *Daemon) serve(ctx context.Context, ln net.Listener) {
	for {
		nc, err := ln.Accept()
		if err != nil {
			if ctx.Err() != nil || errors.Is(err, net.ErrClosed) {
				return
			}
			d.logf("accept: %v", err)
			continue
		}
		go d.handle(ctx, &conn{nc: nc})
	}
}

func (d *Daemon) handle(ctx context.Context, c *conn) {
	defer c.nc.Close()
	defer d.subs.remove(c)
	sc := bufio.NewScanner(c.nc)
	sc.Buffer(make([]byte, 64*1024), 8*1024*1024)
	for sc.Scan() {
		var req sock.Request
		if err := json.Unmarshal(sc.Bytes(), &req); err != nil {
			c.send(sock.Reply{Error: "bad request: " + err.Error()})
			continue
		}
		reply := d.dispatch(ctx, c, req)
		reply.Req = req.Req
		c.send(reply)
	}
}

func fail(err error) sock.Reply { return sock.Reply{Error: err.Error()} }

func (d *Daemon) dispatch(ctx context.Context, c *conn, req sock.Request) sock.Reply {
	switch req.Op {
	case "status":
		st := d.Status()
		return sock.Reply{OK: true, Status: &st}

	case "snapshot":
		s, err := d.rep.Snapshot()
		if err != nil {
			return fail(err)
		}
		return sock.Reply{OK: true, Snapshot: s}

	case "ops":
		res, err := d.ApplyLocal(req.Ops)
		if err != nil {
			return fail(err)
		}
		return sock.Reply{OK: true, Results: res}

	case "people":
		p, err := d.People(ctx, req.Fresh)
		if err != nil {
			return fail(err)
		}
		return sock.Reply{OK: true, People: p}

	case "preview", "capture":
		s, err := d.rep.Snapshot()
		if err != nil {
			return fail(err)
		}
		plan, err := capture.Parse(req.Text, s)
		if err != nil {
			return fail(err)
		}
		if req.Op == "capture" {
			if _, err := d.ApplyLocal(plan.Ops(s, d.clock.Now, config.NewID)); err != nil {
				return fail(err)
			}
		}
		return sock.Reply{OK: true, Plan: &plan}

	case "files":
		files := make([]capture.File, len(req.Paths))
		for i, p := range req.Paths {
			files[i] = capture.Inspect(p)
		}
		return sock.Reply{OK: true, Files: files}

	case "compose-preview", "compose":
		if req.Draft == nil {
			return fail(fmt.Errorf("no draft"))
		}
		s, err := d.rep.Snapshot()
		if err != nil {
			return fail(err)
		}
		plan, err := capture.Compose(*req.Draft, s)
		if err != nil {
			return fail(err)
		}
		if req.Op == "compose" {
			if err := d.compose(&plan, s); err != nil {
				return fail(err)
			}
		}
		return sock.Reply{OK: true, Plan: &plan}

	case "set":
		if !settable(req.Collection, req.Field) {
			return fail(fmt.Errorf("%s.%s is not editable here", req.Collection, req.Field))
		}
		if !json.Valid(req.Value) {
			return fail(fmt.Errorf("value is not JSON"))
		}
		op := protocol.Op{Collection: req.Collection, ID: req.ID, Field: req.Field, Value: req.Value, HLC: d.clock.Now()}
		res, err := d.ApplyLocal([]protocol.Op{op})
		return opReply(res, err)

	case "add-item":
		id, err := d.addItem(req.Note, req.Text, req.After)
		if err != nil {
			return fail(err)
		}
		return sock.Reply{OK: true, ID: id}

	case "attach":
		var files []capture.File
		for _, p := range req.Paths {
			f := capture.Inspect(p)
			if f.Error != "" {
				return fail(fmt.Errorf("%s: %s", f.Name, f.Error))
			}
			files = append(files, f)
		}
		s, err := d.rep.Snapshot()
		if err != nil {
			return fail(err)
		}
		plan := capture.Plan{Kind: capture.Attach, NoteID: req.Note, Files: files}
		if err := d.compose(&plan, s); err != nil {
			return fail(err)
		}
		return sock.Reply{OK: true, Plan: &plan}

	case "convert":
		if err := d.convert(req.Note, req.Kind); err != nil {
			return fail(err)
		}
		return sock.Reply{OK: true}

	case "fetch":
		path, err := d.fetch(ctx, req.ID, req.Thumb)
		if err != nil {
			return fail(err)
		}
		return sock.Reply{OK: true, Path: path}

	case "check":
		res, err := d.ApplyLocal([]protocol.Op{d.op(protocol.Items, req.Item, "checked", req.On)})
		return opReply(res, err)

	case "pin":
		res, err := d.ApplyLocal([]protocol.Op{d.op(protocol.NoteState, req.Note, "pinned", req.On)})
		return opReply(res, err)

	case "subscribe":
		d.subs.add(c, req.Changes)
		c.send(d.stateEvent())
		return sock.Reply{OK: true}

	case "quiet":
		d.notes.quiet(time.Duration(req.Seconds) * time.Second)
		return sock.Reply{OK: true}
	}
	return fail(fmt.Errorf("unknown op %q", req.Op))
}

func opReply(res []protocol.OpResult, err error) sock.Reply {
	if err != nil {
		return fail(err)
	}
	for _, r := range res {
		if r.Error != "" {
			return sock.Reply{Error: r.Error, Results: res}
		}
	}
	return sock.Reply{OK: true, Results: res}
}

func (d *Daemon) op(collection, id, field string, v any) protocol.Op {
	return protocol.Op{Collection: collection, ID: id, Field: field, Value: jsonOf(v), HLC: d.clock.Now()}
}

// hub fans state and change events out to subscribers.
type hub struct {
	mu   sync.Mutex
	subs map[*conn]bool // value: wants change events
}

func newHub() *hub { return &hub{subs: map[*conn]bool{}} }

func (h *hub) add(c *conn, changes bool) {
	h.mu.Lock()
	h.subs[c] = changes
	h.mu.Unlock()
}

func (h *hub) remove(c *conn) {
	h.mu.Lock()
	delete(h.subs, c)
	h.mu.Unlock()
}

func (h *hub) each(fn func(c *conn, changes bool)) {
	h.mu.Lock()
	subs := make(map[*conn]bool, len(h.subs))
	for c, ch := range h.subs {
		subs[c] = ch
	}
	h.mu.Unlock()
	for c, ch := range subs {
		fn(c, ch)
	}
}

func (h *hub) state(ev sock.StateEvent) { h.each(func(c *conn, _ bool) { c.send(ev) }) }

func (h *hub) change(ch protocol.Change) {
	ev := sock.ChangeEvent{Event: "change", Change: ch}
	h.each(func(c *conn, changes bool) {
		if changes {
			c.send(ev)
		}
	})
}

func (d *Daemon) stateEvent() sock.StateEvent {
	ev := sock.StateEvent{Event: "state", Status: d.Status(), Notes: []sock.ShellNote{}}
	s, err := d.rep.Snapshot()
	if err != nil {
		d.logf("state: %v", err)
		return ev
	}
	for _, n := range s.Notes {
		st := notes.StateOf(s, n.ID)
		sn := sock.ShellNote{
			ID: n.ID, Title: n.Title, Label: notes.Title(n), Kind: n.Kind, Color: n.Color, Body: n.Body,
			Pinned: st.Pinned, Archived: st.Archived, Trashed: n.Trashed != "", Owned: n.Owner == ev.User.ID,
			Shared: len(notes.MembersOf(s, n.ID)) > 0 || n.Owner != ev.User.ID,
			Items:  []sock.ShellItem{}, Files: []sock.ShellFile{}, Updated: n.Updated,
		}
		if !st.ReminderDone {
			sn.Reminder = st.Reminder
		}
		items := notes.ItemsOf(s, n.ID)
		sort.SliceStable(items, func(i, j int) bool { return items[i].Order < items[j].Order })
		for _, it := range items {
			sn.Items = append(sn.Items, sock.ShellItem{ID: it.ID, Text: it.Text, Checked: it.Checked, Indent: it.Indent})
			if it.Checked {
				sn.Done++
			} else {
				sn.Open++
			}
		}
		for _, a := range notes.AttachmentsOf(s, n.ID) {
			sn.Files = append(sn.Files, sock.ShellFile{ID: a.ID, Name: a.Name, Size: a.Size, Type: a.Type,
				Image: strings.HasPrefix(a.Type, "image/"), Pending: a.Pending})
		}
		ev.Notes = append(ev.Notes, sn)
	}
	sort.SliceStable(ev.Notes, func(i, j int) bool {
		if ev.Notes[i].Pinned != ev.Notes[j].Pinned {
			return ev.Notes[i].Pinned
		}
		return ev.Notes[i].Updated > ev.Notes[j].Updated
	})
	return ev
}
