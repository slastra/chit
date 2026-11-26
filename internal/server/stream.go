package server

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"strconv"
	"sync"
	"time"

	"github.com/pocketbase/pocketbase/core"
)

// pingEvery keeps proxies and mobile NAT from dropping an idle stream.
var pingEvery = 50 * time.Second

// Broker wakes every open stream after a write. Streams then re-read the
// feed from their own cursor, so visibility rules live in one place
// (changesFor) and a missed wake-up only delays delivery.
type Broker struct {
	mu   sync.Mutex
	subs map[chan struct{}]struct{}
}

func NewBroker() *Broker { return &Broker{subs: map[chan struct{}]struct{}{}} }

func (b *Broker) subscribe() chan struct{} {
	ch := make(chan struct{}, 1)
	b.mu.Lock()
	b.subs[ch] = struct{}{}
	b.mu.Unlock()
	return ch
}

func (b *Broker) unsubscribe(ch chan struct{}) {
	b.mu.Lock()
	delete(b.subs, ch)
	b.mu.Unlock()
}

// Notify wakes all streams. It never blocks: a stream that already has a
// wake-up pending needs no second one.
func (b *Broker) Notify() {
	b.mu.Lock()
	defer b.mu.Unlock()
	for ch := range b.subs {
		select {
		case ch <- struct{}{}:
		default:
		}
	}
}

// handleStream serves the feed as server-sent events. The cursor comes from
// Last-Event-ID (a reconnect) or ?since=.
func handleStream(e *core.RequestEvent, b *Broker) error {
	cursor, _ := strconv.ParseInt(e.Request.Header.Get("Last-Event-ID"), 10, 64)
	if cursor == 0 {
		cursor, _ = strconv.ParseInt(e.Request.URL.Query().Get("since"), 10, 64)
	}
	userID, dev := e.Auth.Id, deviceOf(e)

	// The server's 5-minute WriteTimeout would cut every stream; lift it for
	// this response the way PocketBase's own realtime route does.
	if err := http.NewResponseController(e.Response).SetWriteDeadline(time.Time{}); err != nil && !errors.Is(err, http.ErrNotSupported) {
		return err
	}
	w := e.Response
	h := w.Header()
	h.Set("Content-Type", "text/event-stream")
	h.Set("Cache-Control", "no-cache")
	h.Set("X-Accel-Buffering", "no")
	w.WriteHeader(http.StatusOK)
	fmt.Fprint(w, ": connected\n\n")
	if err := e.Flush(); err != nil {
		return nil
	}

	ch := b.subscribe()
	defer b.unsubscribe(ch)
	ping := time.NewTicker(pingEvery)
	defer ping.Stop()

	send := func() error {
		for {
			resp, err := changesFor(e.App, userID, dev, cursor)
			if err != nil {
				return err
			}
			for _, c := range resp.Changes {
				data, _ := json.Marshal(c)
				if _, err := fmt.Fprintf(w, "id: %d\nevent: change\ndata: %s\n\n", c.Seq, data); err != nil {
					return err
				}
			}
			if resp.Seq != cursor && len(resp.Changes) == 0 {
				// Only other people's rows moved the cursor: tell the client
				// so its Last-Event-ID stays current, without a payload.
				if _, err := fmt.Fprintf(w, "id: %d\nevent: cursor\ndata: {}\n\n", resp.Seq); err != nil {
					return err
				}
			}
			cursor = resp.Seq
			if err := e.Flush(); err != nil {
				return err
			}
			if !resp.More {
				return nil
			}
		}
	}

	if err := send(); err != nil {
		return nil
	}
	ctx := e.Request.Context()
	for {
		select {
		case <-ctx.Done():
			return nil
		case <-ch:
			if err := send(); err != nil {
				return nil
			}
		case <-ping.C:
			if _, err := fmt.Fprint(w, ": ping\n\n"); err != nil {
				return nil
			}
			if e.Flush() != nil {
				return nil
			}
		}
	}
}
