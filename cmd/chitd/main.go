// Command chitd is the chit desktop daemon: a local replica that syncs with
// the server, works offline, serves lastshell and the CLI over a unix
// socket, and shows reminder and activity toasts.
package main

import (
	"context"
	"fmt"
	"log"
	"os"
	"os/signal"
	"path/filepath"
	"runtime/debug"
	"syscall"

	"github.com/slastra/chit/internal/config"
	"github.com/slastra/chit/internal/daemon"
	"github.com/slastra/chit/internal/replica"
	"github.com/slastra/chit/internal/sock"
)

func usage() {
	fmt.Fprintln(os.Stderr, `usage: chitd serve | version

serve    run the daemon (socket: $CHIT_SOCKET or $XDG_RUNTIME_DIR/chit.sock,
         replica: $XDG_DATA_HOME/chit/replica.db)
version  print the version

Sign in first with: chit login <server-url>`)
	os.Exit(2)
}

func main() {
	if len(os.Args) != 2 {
		usage()
	}
	switch os.Args[1] {
	case "version":
		fmt.Println(version())
	case "serve":
		if err := serve(); err != nil {
			log.Fatal(err)
		}
	default:
		usage()
	}
}

func dataDir() string {
	if d := os.Getenv("XDG_DATA_HOME"); d != "" {
		return filepath.Join(d, "chit")
	}
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".local", "share", "chit")
}

func serve() error {
	log.SetFlags(0) // journald stamps lines
	rep, err := replica.Open(filepath.Join(dataDir(), "replica.db"))
	if err != nil {
		return err
	}
	defer rep.Close()
	var notifier daemon.Notifier = daemon.NotifySend{}
	if os.Getenv("CHITD_NO_TOASTS") != "" {
		notifier = nil
	}
	d, err := daemon.New(daemon.Options{
		Replica:    rep,
		Socket:     sock.DefaultPath(),
		UploadDir:  filepath.Join(dataDir(), "uploads"),
		LoadConfig: config.Load,
		Notifier:   notifier,
		Logf:       log.Printf,
	})
	if err != nil {
		return err
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	log.Printf("%s listening on %s", version(), sock.DefaultPath())
	return d.Run(ctx)
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
	return "chitd " + v
}
