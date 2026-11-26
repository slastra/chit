// Command chit-server is the chit sync server: PocketBase for accounts,
// the admin UI, files and backups, plus chit's own sync routes.
package main

import (
	"fmt"
	"log"
	"runtime/debug"

	"github.com/pocketbase/pocketbase"
	"github.com/pocketbase/pocketbase/plugins/migratecmd"
	"github.com/spf13/cobra"

	_ "github.com/slastra/chit/migrations"
)

func main() {
	app := pocketbase.New()

	// Schema lives in Go migrations. Automigrate stays off so edits made in
	// the admin UI never write migration files on the server.
	migratecmd.MustRegister(app, app.RootCmd, migratecmd.Config{Automigrate: false})

	app.RootCmd.AddCommand(&cobra.Command{
		Use:   "version",
		Short: "Print the chit-server version",
		Run:   func(*cobra.Command, []string) { fmt.Println(version()) },
	})

	if err := app.Start(); err != nil {
		log.Fatal(err)
	}
}

// version reads the build info: Go stamps the module version from the VCS
// tag (a pseudo-version past it) and the commit.
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
	return "chit-server " + v
}
