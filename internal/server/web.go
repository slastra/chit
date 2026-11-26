package server

import (
	"os"
	"path/filepath"

	"github.com/pocketbase/pocketbase/apis"
	"github.com/pocketbase/pocketbase/core"
)

// ServeWeb serves the web app's build from dir at the server's root, when
// there is one (the Docker image puts it at /srv/web). The API and the
// admin UI keep their own, more specific routes; any other path gets
// index.html, so the app's own links load it.
func ServeWeb(app core.App, dir string) {
	if st, err := os.Stat(filepath.Join(dir, "index.html")); err != nil || st.IsDir() {
		return
	}
	static := apis.Static(os.DirFS(dir), true)
	app.OnServe().BindFunc(func(se *core.ServeEvent) error {
		se.Router.GET("/{path...}", func(e *core.RequestEvent) error {
			// what names the current build is fetched fresh, so a deploy
			// shows on the next load; the rest is content-hashed or small
			switch e.Request.PathValue("path") {
			case "", "index.html", "flutter_bootstrap.js", "flutter_service_worker.js", "version.json", "manifest.json":
				e.Response.Header().Set("Cache-Control", "no-cache")
			}
			return static(e)
		})
		return se.Next()
	})
}
