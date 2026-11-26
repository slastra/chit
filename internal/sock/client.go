package sock

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"sync/atomic"
	"time"

	"github.com/slastra/chit/internal/protocol"
)

// DefaultPath is $CHIT_SOCKET, else $XDG_RUNTIME_DIR/chit.sock.
func DefaultPath() string {
	if p := os.Getenv("CHIT_SOCKET"); p != "" {
		return p
	}
	dir := os.Getenv("XDG_RUNTIME_DIR")
	if dir == "" {
		dir = os.TempDir()
	}
	return filepath.Join(dir, "chit.sock")
}

// Client talks to a running chitd.
type Client struct {
	Path string
	seq  atomic.Int64
}

func New(path string) *Client { return &Client{Path: path} }

// Up reports whether chitd answers on the socket.
func (c *Client) Up(ctx context.Context) bool {
	ctx, cancel := context.WithTimeout(ctx, 500*time.Millisecond)
	defer cancel()
	_, err := c.Call(ctx, Request{Op: "status"})
	return err == nil
}

// Call sends one request and waits for its reply.
func (c *Client) Call(ctx context.Context, req Request) (*Reply, error) {
	var d net.Dialer
	nc, err := d.DialContext(ctx, "unix", c.Path)
	if err != nil {
		return nil, err
	}
	defer nc.Close()
	if dl, ok := ctx.Deadline(); ok {
		_ = nc.SetDeadline(dl)
	} else {
		_ = nc.SetDeadline(time.Now().Add(30 * time.Second))
	}
	req.Req = strconv.FormatInt(c.seq.Add(1), 10)
	b, _ := json.Marshal(req)
	if _, err := nc.Write(append(b, '\n')); err != nil {
		return nil, err
	}
	sc := bufio.NewScanner(nc)
	sc.Buffer(make([]byte, 64*1024), 64*1024*1024)
	for sc.Scan() {
		var r Reply
		if json.Unmarshal(sc.Bytes(), &r) == nil && r.Req == req.Req {
			if !r.OK {
				return &r, errors.New(r.Error)
			}
			return &r, nil
		}
	}
	if err := sc.Err(); err != nil {
		return nil, err
	}
	return nil, errors.New("chitd closed the connection")
}

func (c *Client) Status(ctx context.Context) (*Status, error) {
	r, err := c.Call(ctx, Request{Op: "status"})
	if err != nil {
		return nil, err
	}
	return r.Status, nil
}

func (c *Client) Snapshot(ctx context.Context) (*protocol.Snapshot, error) {
	r, err := c.Call(ctx, Request{Op: "snapshot"})
	if err != nil {
		return nil, err
	}
	return r.Snapshot, nil
}

// Ops applies ops locally in chitd, which queues them for the server. The
// response's Seq is always 0: the server has not seen them yet.
func (c *Client) Ops(ctx context.Context, ops []protocol.Op) (*protocol.OpsResponse, error) {
	r, err := c.Call(ctx, Request{Op: "ops", Ops: ops})
	if err != nil {
		return nil, err
	}
	return &protocol.OpsResponse{Results: r.Results}, nil
}

func (c *Client) People(ctx context.Context) ([]protocol.Person, error) {
	r, err := c.Call(ctx, Request{Op: "people"})
	if err != nil {
		return nil, err
	}
	return r.People, nil
}

// Stream follows changes as chitd applies them, starting now (since is
// ignored: chitd's replica is already current). It returns when ctx ends or
// chitd goes away.
func (c *Client) Stream(ctx context.Context, since int64, fn func(protocol.Change) error) error {
	var d net.Dialer
	nc, err := d.DialContext(ctx, "unix", c.Path)
	if err != nil {
		return err
	}
	defer nc.Close()
	go func() { <-ctx.Done(); nc.Close() }()
	b, _ := json.Marshal(Request{Op: "subscribe", Changes: true, Req: "sub"})
	if _, err := nc.Write(append(b, '\n')); err != nil {
		return err
	}
	sc := bufio.NewScanner(nc)
	sc.Buffer(make([]byte, 64*1024), 64*1024*1024)
	for sc.Scan() {
		var ev struct {
			Event  string          `json:"event"`
			Change protocol.Change `json:"change"`
		}
		if json.Unmarshal(sc.Bytes(), &ev) != nil || ev.Event != "change" {
			continue
		}
		if err := fn(ev.Change); err != nil {
			return err
		}
	}
	if ctx.Err() != nil {
		return nil
	}
	return fmt.Errorf("chitd went away")
}
