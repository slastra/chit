// Command chit is the chit command-line client.
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/signal"
	"runtime/debug"
	"strings"
	"syscall"
	"time"

	"github.com/spf13/cobra"
	"golang.org/x/term"

	"github.com/slastra/chit/internal/client"
	"github.com/slastra/chit/internal/config"
	"github.com/slastra/chit/internal/hlc"
	"github.com/slastra/chit/internal/protocol"
	"github.com/slastra/chit/internal/sock"
)

var jsonOut bool

func main() {
	root := &cobra.Command{
		Use:           "chit",
		Short:         "Notes and shared checklists from the terminal",
		SilenceUsage:  true,
		SilenceErrors: true,
	}
	root.PersistentFlags().BoolVar(&jsonOut, "json", false, "print JSON")
	root.AddCommand(
		loginCmd(), logoutCmd(), peopleCmd(), lsCmd(), showCmd(), newCmd(), addCmd(),
		checkCmd(), rmCmd(), pinCmd(true), pinCmd(false), shareCmd(), unshareCmd(), watchCmd(),
		attachCmd(), getCmd(), detachCmd(), remindCmd(), statusCmd(),
		&cobra.Command{
			Use:   "version",
			Short: "Print the chit version",
			Run:   func(*cobra.Command, []string) { fmt.Println(version()) },
		},
	)
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	if err := root.ExecuteContext(ctx); err != nil {
		fmt.Fprintln(os.Stderr, "chit:", err)
		os.Exit(1)
	}
}

func version() string {
	v := "(unknown)"
	if bi, ok := debug.ReadBuildInfo(); ok {
		v = bi.Main.Version
		for _, s := range bi.Settings {
			if s.Key == "vcs.revision" && len(s.Value) >= 7 {
				v += " (" + s.Value[:7] + ")"
			}
		}
	}
	return "chit " + v
}

// session is a signed-in client plus the config it came from.
// backend is where reads and edits go: chitd's replica when it is running
// (instant, works offline), else the server. Sharing and files always talk
// to the server directly.
type backend interface {
	Snapshot(ctx context.Context) (*protocol.Snapshot, error)
	Ops(ctx context.Context, ops []protocol.Op) (*protocol.OpsResponse, error)
	People(ctx context.Context) ([]protocol.Person, error)
	Stream(ctx context.Context, since int64, fn func(protocol.Change) error) error
}

type session struct {
	cfg   *config.Config
	c     *client.Client
	b     backend
	chitd bool // b is chitd
	clock *hlc.Clock
}

// open loads the config and refreshes the token when it is close to expiring.
func open(ctx context.Context) (*session, error) {
	cfg, err := config.Load()
	if err != nil {
		return nil, err
	}
	if cfg.Server == "" || cfg.Token == "" {
		return nil, client.ErrUnauthorized
	}
	s := &session{cfg: cfg, c: client.New(cfg.Server, cfg.Token, cfg.Device), clock: hlc.New(cfg.Device)}
	if exp, ok := client.TokenExpiry(cfg.Token); ok && time.Until(exp) < 72*time.Hour {
		if a, err := s.c.Refresh(ctx); err == nil {
			cfg.Token, cfg.User = a.Token, a.User
			s.c.Token = a.Token
			_ = cfg.Save()
		}
	}
	s.b = s.c
	if os.Getenv("CHIT_DIRECT") == "" {
		if d := sock.New(sock.DefaultPath()); d.Up(ctx) {
			s.b, s.chitd = d, true
		}
	}
	return s, nil
}

// observe moves the clock past every clock in the snapshot, so edits made
// here win over what this device has seen even if its wall clock is behind.
func (s *session) observe(snap *protocol.Snapshot) {
	see := func(c protocol.Clocks) {
		for _, h := range c {
			s.clock.Observe(h)
		}
	}
	for _, n := range snap.Notes {
		see(n.Clocks)
	}
	for _, it := range snap.Items {
		see(it.Clocks)
	}
	for _, st := range snap.State {
		see(st.Clocks)
	}
}

func (s *session) snapshot(ctx context.Context) (*protocol.Snapshot, error) {
	snap, err := s.b.Snapshot(ctx)
	if err == nil {
		s.observe(snap)
	}
	return snap, err
}

func (s *session) op(collection, id, field string, value any) protocol.Op {
	v, _ := json.Marshal(value)
	return protocol.Op{Collection: collection, ID: id, Field: field, Value: v, HLC: s.clock.Now()}
}

// send applies ops and turns the first rejected op into an error.
func (s *session) send(ctx context.Context, ops ...protocol.Op) error {
	resp, err := s.b.Ops(ctx, ops)
	if err != nil {
		return err
	}
	for i, r := range resp.Results {
		if r.Error != "" {
			return fmt.Errorf("%s.%s: %s", ops[i].Collection, ops[i].Field, r.Error)
		}
	}
	return nil
}

func printJSON(v any) error {
	enc := json.NewEncoder(os.Stdout)
	enc.SetIndent("", "  ")
	return enc.Encode(v)
}

func stdinIsTerminal() bool { return term.IsTerminal(int(os.Stdin.Fd())) }

// readStdin returns piped input, or "" when stdin is a terminal.
func readStdin() (string, error) {
	if stdinIsTerminal() {
		return "", nil
	}
	b, err := io.ReadAll(os.Stdin)
	return strings.TrimRight(string(b), "\n"), err
}
