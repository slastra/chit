package daemon

import (
	"bufio"
	"context"
	"os/exec"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/slastra/chit/internal/describe"
	"github.com/slastra/chit/internal/notes"
	"github.com/slastra/chit/internal/protocol"
)

// Toast is one desktop notification.
type Toast struct {
	Summary  string
	Body     string
	Icon     string
	Critical bool // sticky in lastshell
	Actions  []Action
}

type Action struct{ Key, Label string }

// Notifier shows toasts. When t has actions, onAction gets the chosen key, or
// "" if the toast closed without one.
type Notifier interface {
	Show(ctx context.Context, t Toast, onAction func(key string)) (uint32, error)
	Close(id uint32) error
}

// NotifySend is the Notifier for the desktop: notify-send to show, gdbus to
// close.
type NotifySend struct{}

func (NotifySend) Show(ctx context.Context, t Toast, onAction func(string)) (uint32, error) {
	args := []string{"--app-name=chit", "--print-id"}
	if t.Icon != "" {
		args = append(args, "--icon="+t.Icon)
	}
	if t.Critical {
		args = append(args, "--urgency=critical")
	}
	for _, a := range t.Actions {
		args = append(args, "--action="+a.Key+"="+a.Label)
	}
	args = append(args, t.Summary, t.Body)
	cmd := exec.CommandContext(ctx, "notify-send", args...)
	out, err := cmd.StdoutPipe()
	if err != nil {
		return 0, err
	}
	if err := cmd.Start(); err != nil {
		return 0, err
	}
	sc := bufio.NewScanner(out)
	var id uint32
	if sc.Scan() {
		n, _ := strconv.ParseUint(strings.TrimSpace(sc.Text()), 10, 32)
		id = uint32(n)
	}
	go func() {
		chosen := ""
		if sc.Scan() {
			chosen = strings.TrimSpace(sc.Text())
		}
		_ = cmd.Wait()
		if onAction != nil {
			onAction(chosen)
		}
	}()
	return id, nil
}

func (NotifySend) Close(id uint32) error {
	return exec.Command("gdbus", "call", "--session", "--dest", "org.freedesktop.Notifications",
		"--object-path", "/org/freedesktop/Notifications",
		"--method", "org.freedesktop.Notifications.CloseNotification", strconv.FormatUint(uint64(id), 10)).Run()
}

// noter raises reminder toasts and grouped activity toasts.
type noter struct {
	d   *Daemon
	n   Notifier
	now func() time.Time
	// window is how long activity on one note gathers before it shows.
	window time.Duration

	mu         sync.Mutex
	quietUntil time.Time
	desc       *describe.Describer
	names      map[string]string
	groups     map[string]*activity
	reminders  map[string]uint32 // note id -> open reminder toast
	rescanCh   chan struct{}
	ctx        context.Context
}

// activity is the pending toast for one person's edits on one note.
type activity struct {
	by, note  string
	sentences []string
	timer     *time.Timer
}

func newNoter(d *Daemon, n Notifier) *noter {
	return &noter{
		d: d, n: n, now: time.Now, window: 20 * time.Second,
		names: map[string]string{}, groups: map[string]*activity{}, reminders: map[string]uint32{},
		rescanCh: make(chan struct{}, 1), ctx: context.Background(),
	}
}

func (n *noter) quiet(d time.Duration) {
	n.mu.Lock()
	n.quietUntil = n.now().Add(d)
	n.mu.Unlock()
}

func (n *noter) rescan() { signal(n.rescanCh) }

// run schedules reminders until ctx ends.
func (n *noter) run(ctx context.Context) {
	n.mu.Lock()
	n.ctx = ctx
	n.mu.Unlock()
	if n.n == nil {
		<-ctx.Done()
		return
	}
	for {
		next := n.checkReminders()
		wait := time.Hour
		if !next.IsZero() {
			wait = max(time.Until(next), 0) + 50*time.Millisecond
		}
		t := time.NewTimer(wait)
		select {
		case <-ctx.Done():
			t.Stop()
			return
		case <-n.rescanCh:
		case <-t.C:
		}
		t.Stop()
	}
}

// parseTime reads a PocketBase datetime or RFC 3339.
func parseTime(s string) (time.Time, bool) {
	for _, layout := range []string{"2006-01-02 15:04:05.000Z", "2006-01-02 15:04:05Z07:00", time.RFC3339Nano, time.RFC3339} {
		if t, err := time.Parse(layout, s); err == nil {
			return t, true
		}
	}
	return time.Time{}, false
}

// missedWindow is how late a reminder may still fire (the desk was off).
const missedWindow = 12 * time.Hour

// checkReminders fires due reminders, closes toasts for reminders handled
// elsewhere, and returns the next one due.
func (n *noter) checkReminders() time.Time {
	s, err := n.d.rep.Snapshot()
	if err != nil {
		return time.Time{}
	}
	now := n.now()
	active := map[string]string{} // note -> reminder still pending
	var next time.Time
	for _, st := range s.State {
		if st.Reminder == "" || st.ReminderDone {
			continue
		}
		var note *protocol.Note
		for i := range s.Notes {
			if s.Notes[i].ID == st.Note {
				note = &s.Notes[i]
			}
		}
		if note == nil || note.Trashed != "" {
			continue
		}
		when, ok := parseTime(st.Reminder)
		if !ok {
			continue
		}
		active[st.Note] = st.Reminder
		key := "fired:" + st.Note
		if fired, _ := n.d.rep.Meta(key); fired == st.Reminder {
			continue
		}
		if when.After(now) {
			if next.IsZero() || when.Before(next) {
				next = when
			}
			continue
		}
		_ = n.d.rep.SetMeta(key, st.Reminder)
		if now.Sub(when) <= missedWindow {
			n.fireReminder(s, *note, st.Reminder)
		}
	}

	n.mu.Lock()
	var stale []uint32
	for note, id := range n.reminders {
		if _, ok := active[note]; !ok {
			stale = append(stale, id)
			delete(n.reminders, note)
		}
	}
	n.mu.Unlock()
	for _, id := range stale {
		_ = n.n.Close(id)
	}
	return next
}

func (n *noter) fireReminder(s *protocol.Snapshot, note protocol.Note, reminder string) {
	body := notes.Title(note)
	var open []string
	for _, it := range notes.ItemsOf(s, note.ID) {
		if !it.Checked {
			open = append(open, it.Text)
		}
	}
	sort.Strings(open)
	if len(open) > 0 {
		if len(open) > 4 {
			open = append(open[:4], "…")
		}
		body += "\n" + strings.Join(open, ", ")
	} else if note.Body != "" {
		body += "\n" + oneLine(note.Body, 120)
	}
	t := Toast{Summary: "Reminder", Body: body, Icon: "appointment-soon", Critical: true,
		Actions: []Action{{"done", "Done"}, {"snooze", "Snooze 10 min"}}}
	n.mu.Lock()
	ctx := n.ctx
	n.mu.Unlock()
	id, err := n.n.Show(ctx, t, func(key string) {
		n.mu.Lock()
		delete(n.reminders, note.ID)
		n.mu.Unlock()
		switch key {
		case "done":
			_, _ = n.d.ApplyLocal([]protocol.Op{n.d.op(protocol.NoteState, note.ID, "reminder_done", true)})
		case "snooze":
			at := n.now().Add(10 * time.Minute).UTC().Format(time.RFC3339)
			_, _ = n.d.ApplyLocal([]protocol.Op{n.d.op(protocol.NoteState, note.ID, "reminder", at)})
		}
	})
	if err != nil {
		n.d.logf("reminder toast: %v", err)
		return
	}
	n.mu.Lock()
	n.reminders[note.ID] = id
	n.mu.Unlock()
}

func oneLine(s string, max int) string {
	s = strings.Join(strings.Fields(s), " ")
	if r := []rune(s); len(r) > max {
		return string(r[:max]) + "…"
	}
	return s
}

// resetDescriber rebuilds sentence state from the replica (after a resync).
func (n *noter) resetDescriber() {
	n.mu.Lock()
	n.desc = nil
	n.mu.Unlock()
}

// saw feeds every change to the describer, and queues other people's edits
// for an activity toast.
func (n *noter) saw(c protocol.Change, local bool) {
	n.mu.Lock()
	if n.desc == nil {
		s, err := n.d.rep.Snapshot()
		if err != nil {
			n.mu.Unlock()
			return
		}
		n.desc = describe.New(s, n.names, n.d.me())
	}
	noteID := n.desc.NoteOf(c)
	sentence := n.desc.Describe(c)
	_, known := n.names[c.By]
	n.mu.Unlock()

	if local || n.n == nil || c.By == "" || c.By == n.d.me() || sentence == "" {
		return
	}
	if cfg := n.d.currentConfig(); cfg != nil && !cfg.Toasts() {
		return
	}
	if !known {
		n.learnNames()
		n.mu.Lock()
		// The sentence was built without the name; build the subject again.
		if name, ok := n.names[c.By]; ok {
			sentence = strings.Replace(sentence, "Someone", name, 1)
		}
		n.mu.Unlock()
	}
	n.queue(c.By, noteID, sentence)
}

func (n *noter) learnNames() {
	n.mu.Lock()
	ctx := n.ctx
	n.mu.Unlock()
	people, err := n.d.People(ctx, true)
	if err != nil {
		return
	}
	n.mu.Lock()
	for _, p := range people {
		n.names[p.ID] = notes.DisplayName(p)
	}
	n.mu.Unlock()
}

func (n *noter) queue(by, note, sentence string) {
	n.mu.Lock()
	defer n.mu.Unlock()
	key := by + "/" + note
	g := n.groups[key]
	if g == nil {
		g = &activity{by: by, note: note}
		n.groups[key] = g
		g.timer = time.AfterFunc(n.window, func() { n.flush(key) })
	}
	g.sentences = append(g.sentences, sentence)
}

// flush shows one group's toast, waiting out a quiet period first.
func (n *noter) flush(key string) {
	n.mu.Lock()
	g := n.groups[key]
	if g == nil {
		n.mu.Unlock()
		return
	}
	if wait := n.quietUntil.Sub(n.now()); wait > 0 {
		g.timer = time.AfterFunc(wait+time.Second, func() { n.flush(key) })
		n.mu.Unlock()
		return
	}
	delete(n.groups, key)
	title := "chit"
	if n.desc != nil && g.note != "" {
		title = n.desc.Title(g.note)
	}
	ctx := n.ctx
	n.mu.Unlock()

	lines := g.sentences
	if len(lines) > 4 {
		more := len(lines) - 3
		lines = append(lines[:3:3], "and "+strconv.Itoa(more)+" more")
	}
	if _, err := n.n.Show(ctx, Toast{Summary: title, Body: strings.Join(lines, "\n"), Icon: "accessories-text-editor"}, nil); err != nil {
		n.d.logf("activity toast: %v", err)
	}
}

// flushAll shows every pending group now (tests, shutdown).
func (n *noter) flushAll() {
	n.mu.Lock()
	keys := make([]string, 0, len(n.groups))
	for k, g := range n.groups {
		g.timer.Stop()
		keys = append(keys, k)
	}
	n.mu.Unlock()
	sort.Strings(keys)
	for _, k := range keys {
		n.flush(k)
	}
}
