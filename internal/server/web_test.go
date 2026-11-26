package server

import (
	"net/http"
	"os"
	"path/filepath"
	"testing"

	"github.com/pocketbase/pocketbase/core"
	"github.com/pocketbase/pocketbase/tests"
)

func TestServesTheWebAppBesideTheAPI(t *testing.T) {
	web := t.TempDir()
	if err := os.WriteFile(filepath.Join(web, "index.html"), []byte("<!doctype html><title>chit</title>"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(web, "main.dart.js"), []byte("main()"), 0o644); err != nil {
		t.Fatal(err)
	}
	factory := func(t testing.TB) *tests.TestApp {
		app, err := tests.NewTestAppWithConfig(core.BaseAppConfig{DataDir: t.TempDir()})
		if err != nil {
			t.Fatal(err)
		}
		Register(app)
		ServeWeb(app, web)
		return app
	}
	for _, s := range []tests.ApiScenario{
		{Name: "the app at the root", Method: http.MethodGet, URL: "/", ExpectedStatus: 200,
			ExpectedContent: []string{"<title>chit</title>"}, TestAppFactory: factory},
		{Name: "an app route falls back to the app", Method: http.MethodGet, URL: "/note/abc", ExpectedStatus: 200,
			ExpectedContent: []string{"<title>chit</title>"}, TestAppFactory: factory},
		{Name: "its files", Method: http.MethodGet, URL: "/main.dart.js", ExpectedStatus: 200,
			ExpectedContent: []string{"main()"}, TestAppFactory: factory},
		{Name: "the API is untouched", Method: http.MethodGet, URL: "/api/health", ExpectedStatus: 200,
			ExpectedContent: []string{`"code":200`}, TestAppFactory: factory},
		{Name: "chit's routes still want a user", Method: http.MethodGet, URL: "/api/chit/snapshot", ExpectedStatus: 401,
			ExpectedContent: []string{`"status":401`}, TestAppFactory: factory},
	} {
		s.Test(t)
	}
}

func TestNoWebBuildNoRoute(t *testing.T) {
	(&tests.ApiScenario{
		Name: "no build", Method: http.MethodGet, URL: "/", ExpectedStatus: 404,
		ExpectedContent: []string{`"status":404`},
		TestAppFactory: func(t testing.TB) *tests.TestApp {
			app, err := tests.NewTestAppWithConfig(core.BaseAppConfig{DataDir: t.TempDir()})
			if err != nil {
				t.Fatal(err)
			}
			ServeWeb(app, t.TempDir())
			return app
		},
	}).Test(t)
}
