package main

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"

	"github.com/spf13/cobra"

	"github.com/slastra/chit/internal/config"
	"github.com/slastra/chit/internal/notes"
	"github.com/slastra/chit/internal/protocol"
)

// maxUpload matches the server's attachment limit.
const maxUpload = protocol.MaxAttachmentSize

func humanSize(n int64) string {
	switch {
	case n >= 1<<20:
		return fmt.Sprintf("%.1f MB", float64(n)/(1<<20))
	case n >= 1<<10:
		return fmt.Sprintf("%.0f KB", float64(n)/(1<<10))
	}
	return fmt.Sprintf("%d B", n)
}

func attachCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "attach <note> <file>...",
		Short: "Attach files to a note (250 MB each)",
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
			// Check every file before uploading any.
			for _, p := range args[1:] {
				st, err := os.Stat(p)
				if err != nil {
					return err
				}
				if st.IsDir() {
					return fmt.Errorf("%s is a directory", p)
				}
				if st.Size() > maxUpload {
					return fmt.Errorf("%s is over the 250 MB limit (%d bytes)", p, st.Size())
				}
			}
			var done []protocol.Attachment
			for _, p := range args[1:] {
				resp, err := s.c.Upload(ctx, n.ID, config.NewID(), p)
				if err != nil {
					return fmt.Errorf("%s: %w", p, err)
				}
				done = append(done, resp.Attachment)
				if !jsonOut {
					fmt.Printf("Attached %s (%s) to %s.\n", resp.Attachment.Name, humanSize(resp.Attachment.Size), notes.Title(n))
				}
			}
			if jsonOut {
				return printJSON(done)
			}
			return nil
		},
	}
}

func getCmd() *cobra.Command {
	var out, thumb string
	cmd := &cobra.Command{
		Use:   "get <note> <attachment>",
		Short: "Download an attachment",
		Long: "Download an attachment into the current directory under its own name,\n" +
			"or to -o PATH (- for stdout). --thumb 320x320 or 1080x0 fetches an image preview.",
		Args: cobra.ExactArgs(2),
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
			a, err := notes.FindAttachment(snap, n.ID, args[1])
			if err != nil {
				return err
			}
			if thumb != "" && thumb != "320x320" && thumb != "1080x0" {
				return errors.New("--thumb is 320x320 or 1080x0")
			}
			if out == "-" {
				return s.c.Download(ctx, a, thumb, os.Stdout)
			}
			if out == "" {
				out = filepath.Base(a.Name)
			}
			if _, err := os.Stat(out); err == nil {
				return fmt.Errorf("%s already exists; pick another name with -o", out)
			}
			tmp := out + ".part"
			f, err := os.Create(tmp)
			if err != nil {
				return err
			}
			err = s.c.Download(ctx, a, thumb, f)
			if cerr := f.Close(); err == nil {
				err = cerr
			}
			if err != nil {
				os.Remove(tmp)
				return err
			}
			if err := os.Rename(tmp, out); err != nil {
				return err
			}
			if !jsonOut {
				fmt.Printf("Saved %s.\n", out)
			}
			return nil
		},
	}
	cmd.Flags().StringVarP(&out, "output", "o", "", "where to save it (- for stdout)")
	cmd.Flags().StringVar(&thumb, "thumb", "", "image preview size: 320x320 or 1080x0")
	return cmd
}

func detachCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "detach <note> <attachment>",
		Short: "Remove an attachment from a note",
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
			a, err := notes.FindAttachment(snap, n.ID, args[1])
			if err != nil {
				return err
			}
			if err := s.send(ctx, s.op(protocol.Attachments, a.ID, "deleted", true)); err != nil {
				return err
			}
			if !jsonOut {
				fmt.Printf("Removed %s from %s.\n", a.Name, notes.Title(n))
			}
			return nil
		},
	}
}
