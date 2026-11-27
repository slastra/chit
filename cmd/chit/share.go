package main

// Sharing a note with people and taking it back.

import (
	"fmt"

	"github.com/spf13/cobra"

	"github.com/slastra/chit/internal/notes"
)

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
			n, err := notes.FindNote(snap, args[0])
			if err != nil {
				return err
			}
			people, err := s.b.People(ctx)
			if err != nil {
				return err
			}
			p, err := notes.FindPerson(people, args[1])
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
				fmt.Printf("Shared %s with %s (%s).\n", notes.Title(n), notes.DisplayName(p), role)
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
			n, err := notes.FindNote(snap, args[0])
			if err != nil {
				return err
			}
			people, err := s.b.People(ctx)
			if err != nil {
				return err
			}
			p, err := notes.FindPerson(people, args[1])
			if err != nil {
				return err
			}
			_, err = s.c.Unshare(ctx, n.ID, p.ID)
			return err
		},
	}
}
