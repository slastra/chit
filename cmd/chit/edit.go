package main

// Making and changing notes and their items.

import (
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/spf13/cobra"

	"github.com/slastra/chit/internal/config"
	"github.com/slastra/chit/internal/notes"
	"github.com/slastra/chit/internal/order"
	"github.com/slastra/chit/internal/protocol"
)

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
			id := config.NewID()
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
		id := config.NewID()
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
			n, err := notes.FindNote(snap, args[0])
			if err != nil {
				return err
			}
			if n.Kind != "list" {
				return fmt.Errorf("%q is a text note, not a list", notes.Title(n))
			}
			last := ""
			for _, it := range notes.ItemsOf(snap, n.ID) {
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
				fmt.Printf("Added %d to %s.\n", len(ops)/3, notes.Title(n))
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
			n, err := notes.FindNote(snap, args[0])
			if err != nil {
				return err
			}
			var ops []protocol.Op
			var names []string
			for _, q := range args[1:] {
				it, err := notes.FindItem(snap, n.ID, q)
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
			n, err := notes.FindNote(snap, args[0])
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
			n, err := notes.FindNote(snap, args[0])
			if err != nil {
				return err
			}
			// a note changing sections lands on top of its new one
			return s.send(ctx, s.op(protocol.NoteState, n.ID, "pinned", pin), s.op(protocol.NoteState, n.ID, "order", ""))
		},
	}
}
