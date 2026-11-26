// Package client talks to chit-server. It has no PocketBase dependency, so
// the CLI and chitd stay small.
package client

import (
	"bufio"
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"mime/multipart"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/slastra/chit/internal/protocol"
)

// ErrUnauthorized means the token is missing, expired or revoked.
var ErrUnauthorized = errors.New("not signed in, or the session expired: run chit login")

type Client struct {
	Server string
	Token  string
	Device string
	HTTP   *http.Client
}

func New(server, token, device string) *Client {
	return &Client{
		Server: strings.TrimRight(server, "/"),
		Token:  token,
		Device: device,
		HTTP:   &http.Client{Timeout: 30 * time.Second},
	}
}

// APIError is an error response from the server.
type APIError struct {
	Status  int
	Message string
}

func (e *APIError) Error() string { return fmt.Sprintf("server: %s (%d)", e.Message, e.Status) }

func (c *Client) do(ctx context.Context, method, path string, body, out any) error {
	var r io.Reader
	if body != nil {
		b, err := json.Marshal(body)
		if err != nil {
			return err
		}
		r = bytes.NewReader(b)
	}
	req, err := http.NewRequestWithContext(ctx, method, c.Server+path, r)
	if err != nil {
		return err
	}
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	if c.Token != "" {
		req.Header.Set("Authorization", c.Token)
	}
	if c.Device != "" {
		req.Header.Set("X-Chit-Device", c.Device)
	}
	resp, err := c.HTTP.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	return decodeResponse(resp, out)
}

// decodeResponse turns an error status into an error, or decodes a JSON body
// into out (when out is not nil).
func decodeResponse(resp *http.Response, out any) error {
	if resp.StatusCode == http.StatusUnauthorized {
		return ErrUnauthorized
	}
	if resp.StatusCode >= 300 {
		var e struct {
			Message string `json:"message"`
		}
		_ = json.NewDecoder(resp.Body).Decode(&e)
		if e.Message == "" {
			e.Message = resp.Status
		}
		return &APIError{Status: resp.StatusCode, Message: e.Message}
	}
	if out == nil {
		return nil
	}
	return json.NewDecoder(resp.Body).Decode(out)
}

// Auth is a signed-in session.
type Auth struct {
	Token string
	User  protocol.Person
}

type authResponse struct {
	Token  string          `json:"token"`
	Record protocol.Person `json:"record"`
}

func (c *Client) Login(ctx context.Context, email, password string) (*Auth, error) {
	var resp authResponse
	err := c.do(ctx, http.MethodPost, "/api/collections/users/auth-with-password",
		map[string]string{"identity": email, "password": password}, &resp)
	if err != nil {
		var ae *APIError
		if errors.As(err, &ae) && ae.Status == http.StatusBadRequest {
			return nil, errors.New("wrong email or password")
		}
		return nil, err
	}
	return &Auth{Token: resp.Token, User: resp.Record}, nil
}

// Refresh trades the current token for a fresh one.
func (c *Client) Refresh(ctx context.Context) (*Auth, error) {
	var resp authResponse
	if err := c.do(ctx, http.MethodPost, "/api/collections/users/auth-refresh", nil, &resp); err != nil {
		return nil, err
	}
	return &Auth{Token: resp.Token, User: resp.Record}, nil
}

// TokenExpiry reads the exp claim of a PocketBase token. It does not verify
// the signature; the server does that.
func TokenExpiry(token string) (time.Time, bool) {
	parts := strings.Split(token, ".")
	if len(parts) != 3 {
		return time.Time{}, false
	}
	b, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return time.Time{}, false
	}
	var claims struct {
		Exp int64 `json:"exp"`
	}
	if json.Unmarshal(b, &claims) != nil || claims.Exp == 0 {
		return time.Time{}, false
	}
	return time.Unix(claims.Exp, 0), true
}

func (c *Client) People(ctx context.Context) ([]protocol.Person, error) {
	var resp struct {
		Items []protocol.Person `json:"items"`
	}
	err := c.do(ctx, http.MethodGet, "/api/collections/users/records?perPage=500&sort=name&fields=id,name,email", nil, &resp)
	return resp.Items, err
}

func (c *Client) Snapshot(ctx context.Context) (*protocol.Snapshot, error) {
	var s protocol.Snapshot
	err := c.do(ctx, http.MethodGet, "/api/chit/snapshot", nil, &s)
	return &s, err
}

func (c *Client) Ops(ctx context.Context, ops []protocol.Op) (*protocol.OpsResponse, error) {
	var resp protocol.OpsResponse
	err := c.do(ctx, http.MethodPost, "/api/chit/ops", protocol.OpsRequest{Device: c.Device, Ops: ops}, &resp)
	return &resp, err
}

func (c *Client) Changes(ctx context.Context, since int64) (*protocol.ChangesResponse, error) {
	var resp protocol.ChangesResponse
	err := c.do(ctx, http.MethodGet, "/api/chit/changes?since="+strconv.FormatInt(since, 10), nil, &resp)
	return &resp, err
}

func (c *Client) Share(ctx context.Context, note, user, role string) (int64, error) {
	var resp protocol.SeqResponse
	err := c.do(ctx, http.MethodPost, "/api/chit/notes/"+url.PathEscape(note)+"/members",
		protocol.ShareRequest{User: user, Role: role}, &resp)
	return resp.Seq, err
}

func (c *Client) Unshare(ctx context.Context, note, user string) (int64, error) {
	var resp protocol.SeqResponse
	err := c.do(ctx, http.MethodDelete, "/api/chit/notes/"+url.PathEscape(note)+"/members/"+url.PathEscape(user), nil, &resp)
	return resp.Seq, err
}

// Upload sends the file at path to noteID as attachment id. The body streams
// from disk, so large files are never held in memory.
func (c *Client) Upload(ctx context.Context, noteID, id, path string) (*protocol.AttachResponse, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()

	pr, pw := io.Pipe()
	mw := multipart.NewWriter(pw)
	go func() {
		err := mw.WriteField("id", id)
		if err == nil {
			var part io.Writer
			if part, err = mw.CreateFormFile("file", filepath.Base(path)); err == nil {
				if _, err = io.Copy(part, f); err == nil {
					err = mw.Close()
				}
			}
		}
		pw.CloseWithError(err)
	}()

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.Server+"/api/chit/notes/"+url.PathEscape(noteID)+"/attachments", pr)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", mw.FormDataContentType())
	req.Header.Set("Authorization", c.Token)
	req.Header.Set("X-Chit-Device", c.Device)
	up := &http.Client{Timeout: 10 * time.Minute}
	resp, err := up.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	var out protocol.AttachResponse
	if err := decodeResponse(resp, &out); err != nil {
		return nil, err
	}
	return &out, nil
}

// Download writes an attachment to w, fetching a short-lived file token first.
// thumb is "" for the original, or one of the sizes in protocol.Attachment.
func (c *Client) Download(ctx context.Context, a protocol.Attachment, thumb string, w io.Writer) error {
	var tok struct {
		Token string `json:"token"`
	}
	if err := c.do(ctx, http.MethodPost, "/api/files/token", nil, &tok); err != nil {
		return err
	}
	q := url.Values{"token": {tok.Token}}
	if thumb != "" {
		q.Set("thumb", thumb)
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, c.Server+a.FilePath()+"?"+q.Encode(), nil)
	if err != nil {
		return err
	}
	resp, err := (&http.Client{Timeout: 10 * time.Minute}).Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return decodeResponse(resp, nil)
	}
	_, err = io.Copy(w, resp.Body)
	return err
}

// Stream follows the live feed from since, calling fn for each change, and
// reconnects with Last-Event-ID until ctx ends. A connection with no bytes
// for staleAfter (two missed pings) counts as dead.
func (c *Client) Stream(ctx context.Context, since int64, fn func(protocol.Change) error) error {
	return c.StreamWith(ctx, since, fn, StreamHooks{})
}

// StreamHooks report stream life to a long-running client (chitd). Each may
// be nil.
type StreamHooks struct {
	OnConnect    func()
	OnDisconnect func(error)
	// OnCursor gets every cursor move, including the payload-free "cursor"
	// events that skip rows the reader cannot see.
	OnCursor func(int64)
}

// StreamWith is Stream with hooks.
func (c *Client) StreamWith(ctx context.Context, since int64, fn func(protocol.Change) error, hooks StreamHooks) error {
	const staleAfter = 2*time.Minute + 10*time.Second
	cursor := since
	backoff := time.Second
	for {
		err := c.streamOnce(ctx, &cursor, staleAfter, fn, hooks)
		if hooks.OnDisconnect != nil && ctx.Err() == nil {
			hooks.OnDisconnect(err)
		}
		if ctx.Err() != nil {
			return nil
		}
		if errors.Is(err, ErrUnauthorized) {
			return err
		}
		var fnErr *callbackError
		if errors.As(err, &fnErr) {
			return fnErr.err
		}
		select {
		case <-ctx.Done():
			return nil
		case <-time.After(backoff):
		}
		if backoff < 30*time.Second {
			backoff *= 2
		}
	}
}

type callbackError struct{ err error }

func (e *callbackError) Error() string { return e.err.Error() }

func (c *Client) streamOnce(ctx context.Context, cursor *int64, staleAfter time.Duration, fn func(protocol.Change) error, hooks StreamHooks) error {
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, c.Server+"/api/chit/stream?since="+strconv.FormatInt(*cursor, 10), nil)
	if err != nil {
		return err
	}
	req.Header.Set("Accept", "text/event-stream")
	req.Header.Set("Authorization", c.Token)
	req.Header.Set("X-Chit-Device", c.Device)
	if *cursor > 0 {
		req.Header.Set("Last-Event-ID", strconv.FormatInt(*cursor, 10))
	}
	resp, err := (&http.Client{}).Do(req) // no overall timeout: the stream is long-lived
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode == http.StatusUnauthorized {
		return ErrUnauthorized
	}
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("stream: %s", resp.Status)
	}
	if hooks.OnConnect != nil {
		hooks.OnConnect()
	}

	// Watchdog: any line (data or ping) proves the connection is alive.
	alive := make(chan struct{}, 1)
	go func() {
		t := time.NewTimer(staleAfter)
		defer t.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-alive:
				t.Reset(staleAfter)
			case <-t.C:
				cancel()
				return
			}
		}
	}()

	sc := bufio.NewScanner(resp.Body)
	sc.Buffer(make([]byte, 64*1024), 4*1024*1024)
	var id, event string
	var data strings.Builder
	for sc.Scan() {
		select {
		case alive <- struct{}{}:
		default:
		}
		line := sc.Text()
		switch {
		case line == "":
			moved := false
			if id != "" {
				if n, err := strconv.ParseInt(id, 10, 64); err == nil && n != *cursor {
					*cursor, moved = n, true
				}
			}
			if event == "change" && data.Len() > 0 {
				var ch protocol.Change
				if err := json.Unmarshal([]byte(data.String()), &ch); err == nil {
					if err := fn(ch); err != nil {
						return &callbackError{err}
					}
				}
			} else if moved && hooks.OnCursor != nil {
				hooks.OnCursor(*cursor)
			}
			id, event = "", ""
			data.Reset()
		case strings.HasPrefix(line, ":"):
		case strings.HasPrefix(line, "id:"):
			id = strings.TrimSpace(line[3:])
		case strings.HasPrefix(line, "event:"):
			event = strings.TrimSpace(line[6:])
		case strings.HasPrefix(line, "data:"):
			data.WriteString(strings.TrimPrefix(line[5:], " "))
		}
	}
	if err := sc.Err(); err != nil {
		return err
	}
	return io.ErrUnexpectedEOF
}
