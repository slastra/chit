package main

import (
	"errors"
	"fmt"
	"strconv"
	"strings"
	"time"

	"github.com/spf13/cobra"

	"github.com/slastra/chit/internal/config"
	"github.com/slastra/chit/internal/notes"
	"github.com/slastra/chit/internal/protocol"
	"github.com/slastra/chit/internal/sock"
)

// parseWhen reads a reminder time relative to now, in local time:
// "10m", "2h", "1h30m", "in 20m", "15:30", "tomorrow 9:00", "tomorrow",
// "2026-12-01 09:00", or RFC 3339.
func parseWhen(s string, now time.Time) (time.Time, error) {
	s = strings.TrimSpace(strings.ToLower(s))
	s = strings.TrimPrefix(s, "in ")
	if d, err := time.ParseDuration(s); err == nil && d > 0 {
		return now.Add(d), nil
	}
	if t, err := time.Parse(time.RFC3339, s); err == nil {
		return t, nil
	}
	loc := now.Location()
	if t, err := time.ParseInLocation("2006-01-02 15:04", s, loc); err == nil {
		return t, nil
	}
	day := now
	if rest, ok := strings.CutPrefix(s, "tomorrow"); ok {
		day = now.AddDate(0, 0, 1)
		s = strings.TrimSpace(rest)
		if s == "" {
			s = "9:00"
		}
	}
	for _, layout := range []string{"15:04", "3:04pm", "3pm", "15"} {
		if t, err := time.ParseInLocation(layout, s, loc); err == nil {
			at := time.Date(day.Year(), day.Month(), day.Day(), t.Hour(), t.Minute(), 0, 0, loc)
			if day.Equal(now) && !at.After(now) {
				at = at.AddDate(0, 0, 1) // "15:30" when it is already 16:00 means tomorrow
			}
			return at, nil
		}
	}
	return time.Time{}, fmt.Errorf("cannot read %q as a time; try 10m, 2h, 15:30, \"tomorrow 9:00\" or \"2026-12-01 09:00\"", s)
}

func remindCmd() *cobra.Command {
	var clear bool
	cmd := &cobra.Command{
		Use:   "remind <note> [when]",
		Short: "Set a reminder on a note (--clear to remove it)",
		Long: "Set when chit reminds you about a note: 10m, 2h, 15:30, \"tomorrow 9:00\",\n" +
			"or \"2026-12-01 09:00\". chitd shows the reminder on the desktop; your phone\n" +
			"gets it too. Reminders are yours alone, even on a shared note.",
		Args: cobra.RangeArgs(1, 2),
		RunE: func(cmd *cobra.Command, args []string) error {
			ctx := cmd.Context()
			if !clear && len(args) != 2 {
				return errors.New("say when, e.g. chit remind groceries 17:30")
			}
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
			if clear {
				if err := s.send(ctx, s.op(protocol.NoteState, n.ID, "reminder", "")); err != nil {
					return err
				}
				fmt.Printf("Cleared the reminder on %s.\n", notes.Title(n))
				return nil
			}
			at, err := parseWhen(args[1], time.Now())
			if err != nil {
				return err
			}
			if err := s.send(ctx,
				s.op(protocol.NoteState, n.ID, "reminder", at.UTC().Format(time.RFC3339)),
				s.op(protocol.NoteState, n.ID, "reminder_done", false),
			); err != nil {
				return err
			}
			if !jsonOut {
				fmt.Printf("Reminder on %s for %s.\n", notes.Title(n), at.Format("Mon Jan 2 15:04"))
			}
			return nil
		},
	}
	cmd.Flags().BoolVar(&clear, "clear", false, "remove the reminder")
	return cmd
}

// reminderLine describes a note's pending reminder, or "".
func reminderLine(st protocol.State) string {
	if st.Reminder == "" || st.ReminderDone {
		return ""
	}
	for _, layout := range []string{"2006-01-02 15:04:05.000Z", time.RFC3339} {
		if t, err := time.Parse(layout, st.Reminder); err == nil {
			return "Reminder: " + t.Local().Format("Mon Jan 2 15:04")
		}
	}
	return "Reminder: " + st.Reminder
}

func statusCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "status",
		Short: "Show the session and whether chitd is running",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			cfg, err := config.Load()
			if err != nil {
				return err
			}
			st, derr := sock.New(sock.DefaultPath()).Status(cmd.Context())
			if jsonOut {
				return printJSON(struct {
					Server string       `json:"server"`
					User   string       `json:"user"`
					Chitd  *sock.Status `json:"chitd"`
				}{cfg.Server, cfg.User.Email, st})
			}
			if cfg.Token == "" {
				fmt.Println("Not signed in. Run: chit login <server-url>")
			} else {
				fmt.Printf("Signed in to %s as %s.\n", cfg.Server, notes.DisplayName(cfg.User))
			}
			if derr != nil {
				fmt.Println("chitd: not running (commands go straight to the server).")
				return nil
			}
			state := "online"
			if !st.Online {
				state = "offline"
				if st.Error != "" {
					state += " (" + st.Error + ")"
				}
			}
			fmt.Printf("chitd: %s, %s waiting to send.\n", state, plural(st.Pending, "edit"))
			return nil
		},
	}
}

func plural(n int, word string) string {
	if n == 1 {
		return "1 " + word
	}
	return strconv.Itoa(n) + " " + word + "s"
}
