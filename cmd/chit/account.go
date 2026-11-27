package main

// Signing in and out, and the people on the server.

import (
	"bufio"
	"errors"
	"fmt"
	"os"
	"strings"
	"text/tabwriter"

	"github.com/spf13/cobra"
	"golang.org/x/term"

	"github.com/slastra/chit/internal/client"
	"github.com/slastra/chit/internal/config"
	"github.com/slastra/chit/internal/notes"
)

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
			cfg, err := config.Load()
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
			if err := cfg.Save(); err != nil {
				return err
			}
			fmt.Printf("Signed in to %s as %s.\n", cfg.Server, notes.DisplayName(a.User))
			return nil
		},
	}
	cmd.Flags().StringVar(&email, "email", "", "account email")
	return cmd
}

func logoutCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "logout",
		Short: "Forget the saved session",
		Args:  cobra.NoArgs,
		RunE: func(*cobra.Command, []string) error {
			cfg, err := config.Load()
			if err != nil {
				return err
			}
			cfg.Token = ""
			return cfg.Save()
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
			people, err := s.b.People(cmd.Context())
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
