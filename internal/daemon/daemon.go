// Package daemon is chitd: it keeps the replica in step with the server,
// drains the outbox, and serves the replica to lastshell and the CLI over a
// unix socket. The socket protocol is newline-delimited JSON, documented in
// docs/chitd.md.
package daemon

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net"
	"os"
	"strings"
	"sync"
	"time"

	"github.com/slastra/chit/internal/client"
	"github.com/slastra/chit/internal/config"
	"github.com/slastra/chit/internal/hlc"
	"github.com/slastra/chit/internal/protocol"
	"github.com/slastra/chit/internal/replica"
	"github.com/slastra/chit/internal/sock"
)

// Options configures a Daemon.
type Options struct {
	Replica *replica.Replica
	Socket  string
	// LoadConfig reads the signed-in session; it is called again whenever
	// the daemon reconnects, so chit login takes effect without a restart.
	LoadConfig func() (*config.Config, error)
	// Notifier shows toasts; nil means none.
	Notifier Notifier
	Logf     func(format string, args ...any)
}

type Daemon struct {
	opts   Options
	rep    *replica.Replica
	logf   func(string, ...any)
	device string
	clock  *hlc.Clock

	mu        sync.Mutex
	cl        *client.Client
	cfg       *config.Config
	online    bool
	signedIn  bool
	lastError string
	people    []protocol.Person
	peopleAt  time.Time

	kick    chan struct{} // wake the outbox flusher
	resync  chan struct{} // reload the snapshot
	dirty   chan struct{} // state changed; push to subscribers
	subs    *hub
	notes   *noter
	started time.Time
}

func New(opts Options) (*Daemon, error) {
	if opts.Logf == nil {
		opts.Logf = log.Printf
	}
	dev, err := opts.Replica.Meta(replica.MetaDevice)
	if err != nil {
		return nil, err
	}
	if dev == "" {
		// chitd's own device id, separate from the CLI's: writes the CLI
		// sends straight to the server must come back to chitd in the feed.
		dev = "d" + config.RandomString(7)
		if err := opts.Replica.SetMeta(replica.MetaDevice, dev); err != nil {
			return nil, err
		}
	}
	d := &Daemon{
		opts: opts, rep: opts.Replica, logf: opts.Logf, device: dev, clock: hlc.New(dev),
		kick: make(chan struct{}, 1), resync: make(chan struct{}, 1), dirty: make(chan struct{}, 1),
		started: time.Now(),
	}
	d.subs = newHub()
	d.notes = newNoter(d, opts.Notifier)
	if s, err := d.rep.Snapshot(); err == nil {
		d.observe(s)
	}
	return d, nil
}

func signal(ch chan struct{}) {
	select {
	case ch <- struct{}{}:
	default:
	}
}

func (d *Daemon) observe(s *protocol.Snapshot) {
	see := func(c protocol.Clocks) {
		for _, h := range c {
			d.clock.Observe(h)
		}
	}
	for _, n := range s.Notes {
		see(n.Clocks)
	}
	for _, it := range s.Items {
		see(it.Clocks)
	}
	for _, st := range s.State {
		see(st.Clocks)
	}
	for _, l := range s.Labels {
		see(l.Clocks)
	}
}

// Status reports connection state and the outbox length.
func (d *Daemon) Status() sock.Status {
	n, _ := d.rep.PendingCount()
	d.mu.Lock()
	defer d.mu.Unlock()
	st := sock.Status{Online: d.online, SignedIn: d.signedIn, Pending: n, Error: d.lastError}
	if d.cfg != nil {
		st.Server, st.User = d.cfg.Server, d.cfg.User
	}
	return st
}

func (d *Daemon) client() *client.Client {
	d.mu.Lock()
	defer d.mu.Unlock()
	return d.cl
}

func (d *Daemon) currentConfig() *config.Config {
	d.mu.Lock()
	defer d.mu.Unlock()
	return d.cfg
}

func (d *Daemon) me() string {
	d.mu.Lock()
	defer d.mu.Unlock()
	if d.cfg == nil {
		return ""
	}
	return d.cfg.User.ID
}

func (d *Daemon) setOnline(on bool, errText string) {
	d.mu.Lock()
	changed := d.online != on || d.lastError != errText
	d.online, d.lastError = on, errText
	d.mu.Unlock()
	if changed {
		signal(d.dirty)
	}
}

// Run serves until ctx ends.
func (d *Daemon) Run(ctx context.Context) error {
	ln, err := listen(d.opts.Socket)
	if err != nil {
		return err
	}
	defer os.Remove(d.opts.Socket)
	defer ln.Close()

	var wg sync.WaitGroup
	for _, f := range []func(context.Context){d.syncLoop, d.flushLoop, d.pushLoop, d.notes.run} {
		wg.Add(1)
		go func() { defer wg.Done(); f(ctx) }()
	}
	go func() { <-ctx.Done(); ln.Close() }()
	d.serve(ctx, ln)
	wg.Wait()
	return nil
}

// signIn loads the config and points the client at it. A different server or
// user than the replica holds wipes the replica first.
func (d *Daemon) signIn(ctx context.Context) (*client.Client, error) {
	cfg, err := d.opts.LoadConfig()
	if err != nil {
		return nil, err
	}
	if cfg.Server == "" || cfg.Token == "" {
		return nil, client.ErrUnauthorized
	}
	c := client.New(cfg.Server, cfg.Token, d.device)
	if exp, ok := client.TokenExpiry(cfg.Token); ok && time.Until(exp) < 72*time.Hour {
		if a, err := c.Refresh(ctx); err == nil {
			cfg.Token, cfg.User = a.Token, a.User
			c.Token = a.Token
			if err := cfg.Save(); err != nil {
				d.logf("saving refreshed token: %v", err)
			}
		} else if errors.Is(err, client.ErrUnauthorized) {
			return nil, err
		}
	}
	server, _ := d.rep.Meta(replica.MetaServer)
	user, _ := d.rep.Meta(replica.MetaUser)
	if server != cfg.Server || user != cfg.User.ID {
		if server != "" || user != "" {
			d.logf("account changed (%s %s -> %s %s): starting a fresh replica", server, user, cfg.Server, cfg.User.ID)
		}
		if err := d.rep.Wipe(); err != nil {
			return nil, err
		}
		if err := d.rep.SetMeta(replica.MetaServer, cfg.Server); err != nil {
			return nil, err
		}
		if err := d.rep.SetMeta(replica.MetaUser, cfg.User.ID); err != nil {
			return nil, err
		}
	}
	d.mu.Lock()
	d.cl, d.cfg, d.signedIn = c, cfg, true
	d.mu.Unlock()
	return c, nil
}

func sleep(ctx context.Context, dur time.Duration) bool {
	t := time.NewTimer(dur)
	defer t.Stop()
	select {
	case <-ctx.Done():
		return false
	case <-t.C:
		return true
	}
}

func (d *Daemon) syncLoop(ctx context.Context) {
	backoff := time.Second
	for ctx.Err() == nil {
		c, err := d.signIn(ctx)
		if err != nil {
			signedOut := errors.Is(err, client.ErrUnauthorized)
			d.mu.Lock()
			d.signedIn = !signedOut && d.signedIn
			d.mu.Unlock()
			msg := err.Error()
			if signedOut {
				msg = "signed out: run chit login"
			}
			d.setOnline(false, msg)
			if !sleep(ctx, 30*time.Second) {
				return
			}
			continue
		}
		cursor, err := d.rep.Cursor()
		if err != nil {
			d.logf("reading cursor: %v", err)
		}
		if cursor == 0 {
			if err := d.loadSnapshot(ctx, c); err != nil {
				d.setOnline(false, offlineReason(err))
				if !sleep(ctx, backoff) {
					return
				}
				backoff = min(backoff*2, 15*time.Second)
				continue
			}
			cursor, _ = d.rep.Cursor()
		}

		streamCtx, cancel := context.WithCancel(ctx)
		go func() {
			// A resync request (a rejected op) reloads the snapshot under
			// the running stream; LWW makes the overlap harmless.
			for {
				select {
				case <-streamCtx.Done():
					return
				case <-d.resync:
					if err := d.loadSnapshot(streamCtx, c); err != nil {
						d.logf("resync: %v", err)
					}
				}
			}
		}()
		err = c.StreamWith(streamCtx, cursor, func(ch protocol.Change) error {
			if err := d.rep.ApplyChanges([]protocol.Change{ch}, ch.Seq); err != nil {
				return err
			}
			if ch.HLC != "" {
				d.clock.Observe(ch.HLC)
			}
			d.changed(ch, false)
			return nil
		}, client.StreamHooks{
			OnConnect: func() {
				backoff = time.Second
				d.setOnline(true, "")
				signal(d.kick)
			},
			OnDisconnect: func(err error) {
				d.setOnline(false, offlineReason(err))
			},
			OnCursor: func(seq int64) {
				_ = d.rep.ApplyChanges(nil, seq)
			},
		})
		cancel()
		if ctx.Err() != nil {
			return
		}
		if errors.Is(err, client.ErrUnauthorized) {
			d.mu.Lock()
			d.signedIn = false
			d.mu.Unlock()
			d.setOnline(false, "signed out: run chit login")
			if !sleep(ctx, 30*time.Second) {
				return
			}
			continue
		}
		if err != nil {
			d.logf("stream: %v", err)
			// A change we could not apply: start over from a snapshot.
			_ = d.rep.ApplyChanges(nil, 0)
		}
		if !sleep(ctx, backoff) {
			return
		}
		backoff = min(backoff*2, 15*time.Second)
	}
}

// offlineReason turns a transport error into a short status line.
func offlineReason(err error) string {
	if err == nil {
		return "disconnected"
	}
	var ne net.Error
	var oe *net.OpError
	switch {
	case errors.As(err, &oe) && oe.Op == "dial":
		return "can't reach the server"
	case errors.As(err, &ne) && ne.Timeout():
		return "the server stopped answering"
	}
	return "disconnected: " + err.Error()
}

func (d *Daemon) loadSnapshot(ctx context.Context, c *client.Client) error {
	s, err := c.Snapshot(ctx)
	if err != nil {
		return err
	}
	if err := d.rep.ReplaceAll(s); err != nil {
		return err
	}
	d.observe(s)
	signal(d.dirty)
	d.notes.resetDescriber()
	d.notes.rescan()
	return nil
}

// flushLoop sends the outbox, oldest first, whenever there is something to
// send and the server answers.
func (d *Daemon) flushLoop(ctx context.Context) {
	backoff := time.Second
	tick := time.NewTicker(30 * time.Second)
	defer tick.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-d.kick:
		case <-tick.C:
		}
		for ctx.Err() == nil {
			sent, err := d.flushOnce(ctx)
			if err != nil {
				d.logf("outbox: %v", err)
				if !sleep(ctx, backoff) {
					return
				}
				backoff = min(backoff*2, 15*time.Second)
				continue
			}
			backoff = time.Second
			if sent == 0 {
				break
			}
		}
	}
}

func (d *Daemon) flushOnce(ctx context.Context) (int, error) {
	c := d.client()
	if c == nil {
		return 0, nil
	}
	queued, err := d.rep.Pending(500)
	if err != nil || len(queued) == 0 {
		return 0, err
	}
	ops := make([]protocol.Op, len(queued))
	seqs := make([]int64, len(queued))
	for i, q := range queued {
		ops[i], seqs[i] = q.Op, q.Seq
	}
	resp, err := c.Ops(ctx, ops)
	if err != nil {
		var ae *client.APIError
		if errors.As(err, &ae) && ae.Status == 400 {
			// The batch as a whole was refused (malformed); drop it rather
			// than retry forever, and resync to undo it locally.
			d.logf("server refused %d queued ops: %v", len(ops), err)
			_ = d.rep.Ack(seqs...)
			signal(d.resync)
			return len(ops), nil
		}
		return 0, err
	}
	var rejected []string
	for i, r := range resp.Results {
		if r.Error != "" {
			rejected = append(rejected, fmt.Sprintf("%s.%s: %s", ops[i].Collection, ops[i].Field, r.Error))
		}
	}
	if err := d.rep.Ack(seqs...); err != nil {
		return 0, err
	}
	if len(rejected) > 0 {
		d.logf("server rejected %d ops: %s", len(rejected), strings.Join(rejected, "; "))
		signal(d.resync)
	}
	signal(d.dirty)
	return len(ops), nil
}

// changed records a change for subscribers and the notifier. local marks
// edits made on this desk.
func (d *Daemon) changed(c protocol.Change, local bool) {
	signal(d.dirty)
	d.subs.change(c)
	d.notes.saw(c, local)
	if c.Collection == protocol.NoteState || c.Collection == protocol.Notes || c.Kind == protocol.KindRevoke {
		d.notes.rescan()
	}
}

// pushLoop sends a fresh state to subscribers at most every 100 ms.
func (d *Daemon) pushLoop(ctx context.Context) {
	for {
		select {
		case <-ctx.Done():
			return
		case <-d.dirty:
		}
		if !sleep(ctx, 100*time.Millisecond) {
			return
		}
		d.subs.state(d.stateEvent())
	}
}

// People lists the accounts on the server, cached for an hour (and served
// stale while offline).
func (d *Daemon) People(ctx context.Context, fresh bool) ([]protocol.Person, error) {
	d.mu.Lock()
	cached, at := d.people, d.peopleAt
	d.mu.Unlock()
	if !fresh && cached != nil && time.Since(at) < time.Hour {
		return cached, nil
	}
	c := d.client()
	if c == nil {
		if cached != nil {
			return cached, nil
		}
		return nil, client.ErrUnauthorized
	}
	p, err := c.People(ctx)
	if err != nil {
		if cached != nil {
			return cached, nil
		}
		return nil, err
	}
	d.mu.Lock()
	d.people, d.peopleAt = p, time.Now()
	d.mu.Unlock()
	return p, nil
}

// ApplyLocal applies this desk's ops, queues them, wakes the flusher and
// tells subscribers. It also synthesizes feed-shaped changes for them, since
// the server never echoes this device's own writes.
func (d *Daemon) ApplyLocal(ops []protocol.Op) ([]protocol.OpResult, error) {
	me := d.me()
	if me == "" {
		return nil, client.ErrUnauthorized
	}
	type key struct{ collection, id string }
	existed := map[key]bool{}
	for _, op := range ops {
		k := key{op.Collection, op.ID}
		if _, seen := existed[k]; !seen {
			var probe map[string]json.RawMessage
			ok, _ := d.rep.Record(op.Collection, op.ID, &probe)
			existed[k] = ok
		}
	}
	results, err := d.rep.ApplyLocal(ops, me)
	if err != nil {
		return nil, err
	}
	for _, op := range ops {
		d.clock.Observe(op.HLC)
	}
	signal(d.kick)

	announced := map[key]bool{}
	for i, op := range ops {
		if !results[i].Applied {
			continue
		}
		k := key{op.Collection, op.ID}
		if existed[k] {
			d.changed(protocol.Change{Kind: protocol.KindSet, Collection: op.Collection, Record: op.ID,
				Field: op.Field, Value: op.Value, HLC: op.HLC, By: me}, true)
			continue
		}
		if announced[k] {
			continue
		}
		announced[k] = true
		rec := map[string]json.RawMessage{}
		if ok, _ := d.rep.Record(op.Collection, op.ID, &rec); ok {
			d.changed(protocol.Change{Kind: protocol.KindRecord, Collection: op.Collection, Record: op.ID,
				Value: jsonOf(rec), HLC: op.HLC, By: me}, true)
		}
	}
	return results, nil
}
