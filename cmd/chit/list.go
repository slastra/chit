package main

// Listing notes and printing one.

import (
	"fmt"
	"os"
	"sort"
	"strings"
	"text/tabwriter"

	"github.com/spf13/cobra"

	"github.com/slastra/chit/internal/notes"
	"github.com/slastra/chit/internal/protocol"
)

func lsCmd() *cobra.Command {
	var archived, trashed bool
	cmd := &cobra.Command{
		Use:   "ls",
		Short: "List notes in board order (pinned first)",
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
			var shown []protocol.Note
			for _, n := range snap.Notes {
				st := notes.StateOf(snap, n.ID)
				if (n.Trashed != "") != trashed || (!trashed && st.Archived != archived) {
					continue
				}
				shown = append(shown, n)
			}
			// the board's order: pinned first, then where you put them
			sort.SliceStable(shown, func(i, j int) bool {
				return notes.BoardBefore(shown[i], shown[j], notes.StateOf(snap, shown[i].ID), notes.StateOf(snap, shown[j].ID))
			})
			if jsonOut {
				return printJSON(shown)
			}
			if len(shown) == 0 {
				fmt.Fprintln(os.Stderr, "No notes.")
				return nil
			}
			people, err := s.b.People(ctx)
			if err != nil {
				return err
			}
			names := notes.Names(people)
			w := tabwriter.NewWriter(os.Stdout, 0, 4, 2, ' ', 0)
			for _, n := range shown {
				pin := " "
				if notes.StateOf(snap, n.ID).Pinned {
					pin = "*"
				}
				detail := ""
				if n.Kind == "list" {
					items := notes.ItemsOf(snap, n.ID)
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
				for _, m := range notes.MembersOf(snap, n.ID) {
					if m.User != s.cfg.User.ID {
						with = append(with, names[m.User])
					}
				}
				shared := ""
				if len(with) > 0 {
					shared = "with " + strings.Join(with, ", ")
				}
				fmt.Fprintf(w, "%s %s\t%s\t%s\t%s\n", pin, notes.Title(n), n.Kind, detail, shared)
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
			n, err := notes.FindNote(snap, args[0])
			if err != nil {
				return err
			}
			items := sortedItems(notes.ItemsOf(snap, n.ID))
			if jsonOut {
				return printJSON(struct {
					Note        protocol.Note         `json:"note"`
					Items       []protocol.Item       `json:"items"`
					State       protocol.State        `json:"state"`
					Members     []protocol.Member     `json:"members"`
					Attachments []protocol.Attachment `json:"attachments"`
				}{n, items, notes.StateOf(snap, n.ID), notes.MembersOf(snap, n.ID), notes.AttachmentsOf(snap, n.ID)})
			}
			fmt.Println(notes.Title(n))
			if line := reminderLine(notes.StateOf(snap, n.ID)); line != "" {
				fmt.Println(line)
			}
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
			if files := notes.AttachmentsOf(snap, n.ID); len(files) > 0 {
				fmt.Println("\nAttachments:")
				for _, a := range files {
					fmt.Printf("  %s (%s)\n", a.Name, humanSize(a.Size))
				}
			}
			if members := notes.MembersOf(snap, n.ID); len(members) > 0 || n.Owner != s.cfg.User.ID {
				people, err := s.b.People(ctx)
				if err != nil {
					return err
				}
				names := notes.Names(people)
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
