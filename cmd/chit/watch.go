package main

import (
	"encoding/json"
	"fmt"
	"os"
	"time"

	"github.com/spf13/cobra"

	"github.com/slastra/chit/internal/describe"
	"github.com/slastra/chit/internal/notes"
	"github.com/slastra/chit/internal/protocol"
)

func watchCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "watch",
		Short: "Print changes as they happen (Ctrl-C to stop)",
		Long: "Follow the live change feed. Each line says who changed what. With\n" +
			"--json, each change is printed as one JSON object per line.",
		Args: cobra.NoArgs,
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
			people, err := s.b.People(ctx)
			if err != nil {
				return err
			}
			w := describe.New(snap, notes.Names(people), s.cfg.User.ID)
			if !jsonOut {
				fmt.Fprintln(os.Stderr, "Watching for changes. Ctrl-C to stop.")
			}
			enc := json.NewEncoder(os.Stdout)
			// Without chitd: no device id, so a terminal watcher shows this
			// machine's own edits too. chitd reports its local edits itself.
			var stream backend = s.b
			if !s.chitd {
				direct := *s.c
				direct.Device = ""
				stream = &direct
			}
			return stream.Stream(ctx, snap.Seq, func(c protocol.Change) error {
				line := w.Describe(c) // always, to keep names current
				if jsonOut {
					return enc.Encode(c)
				}
				if line != "" {
					fmt.Printf("%s  %s\n", time.Now().Format("15:04:05"), line)
				}
				return nil
			})
		},
	}
}
