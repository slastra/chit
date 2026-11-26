// Command chit is the chit command-line client.
package main

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/signal"
	"runtime/debug"
	"sort"
	"strings"
	"syscall"
	"text/tabwriter"
	"time"

	"github.com/spf13/cobra"
	"golang.org/x/term"

	"github.com/slastra/chit/internal/client"
	"github.com/slastra/chit/internal/hlc"
	"github.com/slastra/chit/internal/order"
	"github.com/slastra/chit/internal/protocol"
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
		attachCmd(), getCmd(), detachCmd(),
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
type session struct {
	cfg   *config
	c     *client.Client
	clock *hlc.Clock
}

// open loads the config and refreshes the token when it is close to expiring.
func open(ctx context.Context) (*session, error) {
	cfg, err := loadConfig()
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
			_ = cfg.save()
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
	snap, err := s.c.Snapshot(ctx)
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
	resp, err := s.c.Ops(ctx, ops)
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

func loginCmd() *cobra.Command {
	var email string
	cmd := &cobra.Command{
		Use:   "login [server-url]",
		Short: "Sign in and save the session",
		Long: "Sign in to a chit server. The password is prompted for, or read from\n" +
			"stdin when stdin is not a terminal. The session is saved to\n" +
			"~/.config/chit/config.json (mode 600).",
		Args: cobra.MaximumNArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			cfg, err := loadConfig()
			if err != nil {
				return err
			}
			if len(args) == 1 {
				cfg.Server = strings.TrimRight(args[0], "/")
			}
			if cfg.Server == "" {
				return errors.New("give the server URL the first time: chit login https://chit.example.com")
			}
			in := bufio.NewReader(os.Stdin)
			if email == "" {
				if !stdinIsTerminal() {
					return errors.New("--email is required when stdin is not a terminal")
				}
				fmt.Fprint(os.Stderr, "Email: ")
				line, _ := in.ReadString('\n')
				email = strings.TrimSpace(line)
			}
			var password string
			if stdinIsTerminal() {
				fmt.Fprint(os.Stderr, "Password: ")
				b, err := term.ReadPassword(int(os.Stdin.Fd()))
				fmt.Fprintln(os.Stderr)
				if err != nil {
					return err
				}
				password = string(b)
			} else {
				line, _ := in.ReadString('\n')
				password = strings.TrimRight(line, "\r\n")
			}
			a, err := client.New(cfg.Server, "", cfg.Device).Login(cmd.Context(), email, password)
			if err != nil {
				return err
			}
			cfg.Token, cfg.User = a.Token, a.User
			if err := cfg.save(); err != nil {
				return err
			}
			fmt.Printf("Signed in to %s as %s.\n", cfg.Server, displayName(a.User))
			return nil
		},
	}
	cmd.Flags().StringVar(&email, "email", "", "account email")
	return cmd
}

func displayName(p protocol.Person) string {
	if p.Name != "" {
		return p.Name
	}
	return p.Email
}

func logoutCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "logout",
		Short: "Forget the saved session",
		Args:  cobra.NoArgs,
		RunE: func(*cobra.Command, []string) error {
			cfg, err := loadConfig()
			if err != nil {
				return err
			}
			cfg.Token = ""
			return cfg.save()
		},
	}
}

func peopleCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "people",
		Short: "List the accounts on the server",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			s, err := open(cmd.Context())
			if err != nil {
				return err
			}
			people, err := s.c.People(cmd.Context())
			if err != nil {
				return err
			}
			if jsonOut {
				return printJSON(people)
			}
			w := tabwriter.NewWriter(os.Stdout, 0, 4, 2, ' ', 0)
			for _, p := range people {
				you := ""
				if p.ID == s.cfg.User.ID {
					you = "(you)"
				}
				fmt.Fprintf(w, "%s\t%s\t%s\n", p.Name, p.Email, you)
			}
			return w.Flush()
		},
	}
}

func membersOf(snap *protocol.Snapshot, noteID string) []protocol.Member {
	var out []protocol.Member
	for _, m := range snap.Members {
		if m.Note == noteID {
			out = append(out, m)
		}
	}
	return out
}

func nameMap(people []protocol.Person) map[string]string {
	m := map[string]string{}
	for _, p := range people {
		m[p.ID] = displayName(p)
	}
	return m
}

func lsCmd() *cobra.Command {
	var archived, trashed bool
	cmd := &cobra.Command{
		Use:   "ls",
		Short: "List notes, pinned first",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			ctx := cmd.Context()
			s, err := open(ctx)
			if err != nil {
				return err
			}
			snap, err := s.snapshot(ctx)
			if err != nil {
				return err
			}
			var notes []protocol.Note
			for _, n := range snap.Notes {
				st := stateOf(snap, n.ID)
				if (n.Trashed != "") != trashed || (!trashed && st.Archived != archived) {
					continue
				}
				notes = append(notes, n)
			}
			sort.SliceStable(notes, func(i, j int) bool {
				pi, pj := stateOf(snap, notes[i].ID).Pinned, stateOf(snap, notes[j].ID).Pinned
				if pi != pj {
					return pi
				}
				return notes[i].Updated > notes[j].Updated
			})
			if jsonOut {
				return printJSON(notes)
			}
			if len(notes) == 0 {
				fmt.Fprintln(os.Stderr, "No notes.")
				return nil
			}
			people, err := s.c.People(ctx)
			if err != nil {
				return err
			}
			names := nameMap(people)
			w := tabwriter.NewWriter(os.Stdout, 0, 4, 2, ' ', 0)
			for _, n := range notes {
				pin := " "
				if stateOf(snap, n.ID).Pinned {
					pin = "*"
				}
				detail := ""
				if n.Kind == "list" {
					items := itemsOf(snap, n.ID)
					done := 0
					for _, it := range items {
						if it.Checked {
							done++
						}
					}
					detail = fmt.Sprintf("%d/%d done", done, len(items))
				} else {
					detail = oneLine(n.Body, 40)
				}
				var with []string
				if n.Owner != s.cfg.User.ID {
					with = append(with, names[n.Owner])
				}
				for _, m := range membersOf(snap, n.ID) {
					if m.User != s.cfg.User.ID {
						with = append(with, names[m.User])
					}
				}
				shared := ""
				if len(with) > 0 {
					shared = "with " + strings.Join(with, ", ")
				}
				fmt.Fprintf(w, "%s %s\t%s\t%s\t%s\n", pin, noteTitle(n), n.Kind, detail, shared)
			}
			return w.Flush()
		},
	}
	cmd.Flags().BoolVar(&archived, "archived", false, "list archived notes instead")
	cmd.Flags().BoolVar(&trashed, "trashed", false, "list notes in the trash instead")
	return cmd
}

func oneLine(s string, max int) string {
	s = strings.Join(strings.Fields(s), " ")
	if r := []rune(s); len(r) > max {
		return string(r[:max]) + "…"
	}
	return s
}

func sortedItems(items []protocol.Item) []protocol.Item {
	out := append([]protocol.Item(nil), items...)
	sort.SliceStable(out, func(i, j int) bool { return out[i].Order < out[j].Order })
	return out
}

func showCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "show <note>",
		Short: "Print a note or list",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			ctx := cmd.Context()
			s, err := open(ctx)
			if err != nil {
				return err
			}
			snap, err := s.snapshot(ctx)
			if err != nil {
				return err
			}
			n, err := findNote(snap, args[0])
			if err != nil {
				return err
			}
			items := sortedItems(itemsOf(snap, n.ID))
			if jsonOut {
				return printJSON(struct {
					Note        protocol.Note         `json:"note"`
					Items       []protocol.Item       `json:"items"`
					State       protocol.State        `json:"state"`
					Members     []protocol.Member     `json:"members"`
					Attachments []protocol.Attachment `json:"attachments"`
				}{n, items, stateOf(snap, n.ID), membersOf(snap, n.ID), attachmentsOf(snap, n.ID)})
			}
			fmt.Println(noteTitle(n))
			if n.Kind == "list" {
				// Keep's order: open items, then the checked ones.
				for _, checked := range []bool{false, true} {
					for _, it := range items {
						if it.Checked != checked {
							continue
						}
						box := "[ ]"
						if it.Checked {
							box = "[x]"
						}
						fmt.Printf("%s%s %s\n", strings.Repeat("  ", it.Indent), box, it.Text)
					}
				}
			} else if n.Body != "" {
				fmt.Println()
				fmt.Println(n.Body)
			}
			if files := attachmentsOf(snap, n.ID); len(files) > 0 {
				fmt.Println("\nAttachments:")
				for _, a := range files {
					fmt.Printf("  %s (%s)\n", a.Name, humanSize(a.Size))
				}
			}
			if members := membersOf(snap, n.ID); len(members) > 0 || n.Owner != s.cfg.User.ID {
				people, err := s.c.People(ctx)
				if err != nil {
					return err
				}
				names := nameMap(people)
				parts := []string{names[n.Owner] + " (owner)"}
				for _, m := range members {
					parts = append(parts, fmt.Sprintf("%s (%s)", names[m.User], m.Role))
				}
				fmt.Printf("\nShared: %s\n", strings.Join(parts, ", "))
			}
			return nil
		},
	}
}

func newCmd() *cobra.Command {
	var list bool
	cmd := &cobra.Command{
		Use:   "new <title> [text or items...]",
		Short: "Create a note, or a list with --list",
		Long: "Create a note. For a text note the remaining arguments (or stdin) are\n" +
			"the body. With --list, each remaining argument (or stdin line) is an item.",
		Args: cobra.MinimumNArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			ctx := cmd.Context()
			s, err := open(ctx)
			if err != nil {
				return err
			}
			rest := args[1:]
			if len(rest) == 0 {
				in, err := readStdin()
				if err != nil {
					return err
				}
				if in != "" {
					if list {
						rest = strings.Split(in, "\n")
					} else {
						rest = []string{in}
					}
				}
			}
			id := newID()
			kind := "text"
			if list {
				kind = "list"
			}
			ops := []protocol.Op{
				s.op(protocol.Notes, id, "kind", kind),
				s.op(protocol.Notes, id, "title", args[0]),
			}
			if list {
				ops = append(ops, itemOps(s, id, "", rest)...)
			} else if len(rest) > 0 {
				ops = append(ops, s.op(protocol.Notes, id, "body", strings.Join(rest, " ")))
			}
			if err := s.send(ctx, ops...); err != nil {
				return err
			}
			if jsonOut {
				return printJSON(map[string]string{"id": id})
			}
			fmt.Printf("Created %q.\n", args[0])
			return nil
		},
	}
	cmd.Flags().BoolVarP(&list, "list", "l", false, "make a checklist")
	return cmd
}

// itemOps creates items after the key last, skipping blank lines.
func itemOps(s *session, noteID, last string, texts []string) []protocol.Op {
	var ops []protocol.Op
	for _, t := range texts {
		t = strings.TrimSpace(t)
		if t == "" {
			continue
		}
		last = order.After(last)
		id := newID()
		ops = append(ops,
			s.op(protocol.Items, id, "note", noteID),
			s.op(protocol.Items, id, "text", t),
			s.op(protocol.Items, id, "order", last),
		)
	}
	return ops
}

func addCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "add <list> <item>...",
		Short: "Add items to the end of a list",
		Args:  cobra.MinimumNArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			ctx := cmd.Context()
			s, err := open(ctx)
			if err != nil {
				return err
			}
			texts := args[1:]
			if len(texts) == 0 {
				in, err := readStdin()
				if err != nil {
					return err
				}
				texts = strings.Split(in, "\n")
			}
			snap, err := s.snapshot(ctx)
			if err != nil {
				return err
			}
			n, err := findNote(snap, args[0])
			if err != nil {
				return err
			}
			if n.Kind != "list" {
				return fmt.Errorf("%q is a text note, not a list", noteTitle(n))
			}
			last := ""
			for _, it := range itemsOf(snap, n.ID) {
				if it.Order > last {
					last = it.Order
				}
			}
			ops := itemOps(s, n.ID, last, texts)
			if len(ops) == 0 {
				return errors.New("nothing to add")
			}
			if err := s.send(ctx, ops...); err != nil {
				return err
			}
			if !jsonOut {
				fmt.Printf("Added %d to %s.\n", len(ops)/3, noteTitle(n))
			}
			return nil
		},
	}
}

func checkCmd() *cobra.Command {
	var undo bool
	cmd := &cobra.Command{
		Use:   "check <list> <item>...",
		Short: "Check off items (--undo to uncheck)",
		Args:  cobra.MinimumNArgs(2),
		RunE: func(cmd *cobra.Command, args []string) error {
			ctx := cmd.Context()
			s, err := open(ctx)
			if err != nil {
				return err
			}
			snap, err := s.snapshot(ctx)
			if err != nil {
				return err
			}
			n, err := findNote(snap, args[0])
			if err != nil {
				return err
			}
			var ops []protocol.Op
			var names []string
			for _, q := range args[1:] {
				it, err := findItem(snap, n.ID, q)
				if err != nil {
					return err
				}
				ops = append(ops, s.op(protocol.Items, it.ID, "checked", !undo))
				names = append(names, it.Text)
			}
			if err := s.send(ctx, ops...); err != nil {
				return err
			}
			if !jsonOut {
				verb := "Checked"
				if undo {
					verb = "Unchecked"
				}
				fmt.Printf("%s %s.\n", verb, strings.Join(names, ", "))
			}
			return nil
		},
	}
	cmd.Flags().BoolVar(&undo, "undo", false, "uncheck instead")
	return cmd
}

func rmCmd() *cobra.Command {
	var restore bool
	cmd := &cobra.Command{
		Use:   "rm <note>",
		Short: "Move a note to the trash (--restore to bring it back)",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			ctx := cmd.Context()
			s, err := open(ctx)
			if err != nil {
				return err
			}
			snap, err := s.snapshot(ctx)
			if err != nil {
				return err
			}
			n, err := findNote(snap, args[0])
			if err != nil {
				return err
			}
			when := ""
			if !restore {
				when = time.Now().UTC().Format(time.RFC3339)
			}
			return s.send(ctx, s.op(protocol.Notes, n.ID, "trashed", when))
		},
	}
	cmd.Flags().BoolVar(&restore, "restore", false, "take the note out of the trash")
	return cmd
}

func pinCmd(pin bool) *cobra.Command {
	use, short := "pin <note>", "Pin a note to the top"
	if !pin {
		use, short = "unpin <note>", "Unpin a note"
	}
	return &cobra.Command{
		Use:   use,
		Short: short,
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			ctx := cmd.Context()
			s, err := open(ctx)
			if err != nil {
				return err
			}
			snap, err := s.snapshot(ctx)
			if err != nil {
				return err
			}
			n, err := findNote(snap, args[0])
			if err != nil {
				return err
			}
			return s.send(ctx, s.op(protocol.NoteState, n.ID, "pinned", pin))
		},
	}
}

func shareCmd() *cobra.Command {
	var viewer bool
	cmd := &cobra.Command{
		Use:   "share <note> <person>",
		Short: "Share a note (editor by default, --viewer for read-only)",
		Args:  cobra.ExactArgs(2),
		RunE: func(cmd *cobra.Command, args []string) error {
			ctx := cmd.Context()
			s, err := open(ctx)
			if err != nil {
				return err
			}
			snap, err := s.snapshot(ctx)
			if err != nil {
				return err
			}
			n, err := findNote(snap, args[0])
			if err != nil {
				return err
			}
			people, err := s.c.People(ctx)
			if err != nil {
				return err
			}
			p, err := findPerson(people, args[1])
			if err != nil {
				return err
			}
			role := "editor"
			if viewer {
				role = "viewer"
			}
			if _, err := s.c.Share(ctx, n.ID, p.ID, role); err != nil {
				return err
			}
			if !jsonOut {
				fmt.Printf("Shared %s with %s (%s).\n", noteTitle(n), displayName(p), role)
			}
			return nil
		},
	}
	cmd.Flags().BoolVar(&viewer, "viewer", false, "read-only")
	return cmd
}

func unshareCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "unshare <note> <person>",
		Short: "Stop sharing a note with someone (or yourself, to leave it)",
		Args:  cobra.ExactArgs(2),
		RunE: func(cmd *cobra.Command, args []string) error {
			ctx := cmd.Context()
			s, err := open(ctx)
			if err != nil {
				return err
			}
			snap, err := s.snapshot(ctx)
			if err != nil {
				return err
			}
			n, err := findNote(snap, args[0])
			if err != nil {
				return err
			}
			people, err := s.c.People(ctx)
			if err != nil {
				return err
			}
			p, err := findPerson(people, args[1])
			if err != nil {
				return err
			}
			_, err = s.c.Unshare(ctx, n.ID, p.ID)
			return err
		},
	}
}
