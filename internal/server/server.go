// Package server adds chit's sync routes to a PocketBase app. The route
// contract is in docs/design.md.
package server

import (
	"errors"
	"net/http"
	"strconv"
	"time"

	"github.com/pocketbase/pocketbase/apis"
	"github.com/pocketbase/pocketbase/core"

	"github.com/slastra/chit/internal/hlc"
	"github.com/slastra/chit/internal/protocol"
)

const maxOps = 1000

// Register mounts the routes under /api/chit, for signed-in users only.
func Register(app core.App) *Broker {
	b := NewBroker()
	app.OnServe().BindFunc(func(se *core.ServeEvent) error {
		g := se.Router.Group("/api/chit")
		g.Bind(apis.RequireAuth("users"))
		g.POST("/ops", func(e *core.RequestEvent) error { return handleOps(e, b) })
		g.GET("/changes", handleChanges)
		g.GET("/snapshot", handleSnapshot)
		g.GET("/stream", func(e *core.RequestEvent) error { return handleStream(e, b) })
		g.POST("/notes/{id}/members", func(e *core.RequestEvent) error { return handleShare(e, b) })
		g.POST("/notes/{id}/attachments", func(e *core.RequestEvent) error { return handleAttach(e, b) })
		g.DELETE("/notes/{id}/members/{user}", func(e *core.RequestEvent) error { return handleUnshare(e, b) })
		return se.Next()
	})
	return b
}

// deviceOf is the caller's device id from ?device= or the X-Chit-Device header.
func deviceOf(e *core.RequestEvent) string {
	d := e.Request.URL.Query().Get("device")
	if d == "" {
		d = e.Request.Header.Get("X-Chit-Device")
	}
	if !hlc.DeviceID(d) {
		return ""
	}
	return d
}

func handleOps(e *core.RequestEvent, b *Broker) error {
	var req protocol.OpsRequest
	if err := e.BindBody(&req); err != nil {
		return apis.NewBadRequestError("bad body", err)
	}
	if !hlc.DeviceID(req.Device) {
		return apis.NewBadRequestError("device must be 1-16 characters of a-z and 0-9", nil)
	}
	if len(req.Ops) > maxOps {
		return apis.NewBadRequestError("too many ops in one batch", nil)
	}
	resp, err := applyOps(e.App, e.Auth, req.Device, req.Ops, time.Now())
	if err != nil {
		return err
	}
	b.Notify()
	return e.JSON(http.StatusOK, resp)
}

func handleChanges(e *core.RequestEvent) error {
	since, _ := strconv.ParseInt(e.Request.URL.Query().Get("since"), 10, 64)
	resp, err := changesFor(e.App, e.Auth.Id, deviceOf(e), since)
	if err != nil {
		return err
	}
	return e.JSON(http.StatusOK, resp)
}

func handleSnapshot(e *core.RequestEvent) error {
	s, err := snapshot(e.App, e.Auth.Id)
	if err != nil {
		return err
	}
	return e.JSON(http.StatusOK, s)
}

func handleShare(e *core.RequestEvent, b *Broker) error {
	var req protocol.ShareRequest
	if err := e.BindBody(&req); err != nil {
		return apis.NewBadRequestError("bad body", err)
	}
	if req.Role == "" {
		req.Role = "editor"
	}
	seq, err := share(e.App, e.Auth, deviceOf(e), e.Request.PathValue("id"), req.User, req.Role)
	if err != nil {
		return mapErr(err)
	}
	b.Notify()
	return e.JSON(http.StatusOK, protocol.SeqResponse{Seq: seq})
}

func handleUnshare(e *core.RequestEvent, b *Broker) error {
	seq, err := unshare(e.App, e.Auth, deviceOf(e), e.Request.PathValue("id"), e.Request.PathValue("user"))
	if err != nil {
		return mapErr(err)
	}
	b.Notify()
	return e.JSON(http.StatusOK, protocol.SeqResponse{Seq: seq})
}

func mapErr(err error) error {
	switch {
	case errors.Is(err, errNotFound):
		return apis.NewNotFoundError("note or user not found", nil)
	case errors.Is(err, errNotAllowed):
		return apis.NewForbiddenError("you do not have permission for that on this note", nil)
	case errors.Is(err, errBadRequest):
		return apis.NewBadRequestError("bad share request", nil)
	}
	return err
}
