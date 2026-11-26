package server

import (
	"fmt"
	"io"
	"net/http"
	"strings"
	"testing"

	"github.com/pocketbase/pocketbase/core"
	"github.com/pocketbase/pocketbase/tests"

	"github.com/slastra/chit/internal/protocol"
)

// zeros reads as an endless run of zero bytes, so a large upload body costs
// no memory.
type zeros struct{}

func (zeros) Read(p []byte) (int, error) {
	clear(p)
	return len(p), nil
}

// multipartOf is a streamed multipart body: an "id" field and a "file" of
// size zero bytes.
func multipartOf(id string, size int64) (io.Reader, string) {
	const boundary = "chit-test-boundary"
	head := fmt.Sprintf("--%[1]s\r\nContent-Disposition: form-data; name=\"id\"\r\n\r\n%[2]s\r\n"+
		"--%[1]s\r\nContent-Disposition: form-data; name=\"file\"; filename=\"clip.bin\"\r\n"+
		"Content-Type: application/octet-stream\r\n\r\n", boundary, id)
	tail := fmt.Sprintf("\r\n--%s--\r\n", boundary)
	body := io.MultiReader(strings.NewReader(head), io.LimitReader(zeros{}, size), strings.NewReader(tail))
	return body, "multipart/form-data; boundary=" + boundary
}

func TestUploadRouteTakesLargeFiles(t *testing.T) {
	e := newEnv(t)
	shaun := e.device(e.user("shaun"), "desk")
	note, _ := shaun.newList("Clips")
	token, err := shaun.user.NewAuthToken()
	if err != nil {
		t.Fatal(err)
	}
	Register(e.app)

	upload := func(name string, size int64, status int, expect []string) {
		body, ctype := multipartOf(newID(), size)
		(&tests.ApiScenario{
			Name:   name,
			Method: http.MethodPost,
			URL:    "/api/chit/notes/" + note + "/attachments",
			Body:   body,
			Headers: map[string]string{
				"Authorization": token,
				"Content-Type":  ctype,
				"X-Chit-Device": "desk",
			},
			ExpectedStatus:        status,
			ExpectedContent:       expect,
			TestAppFactory:        func(testing.TB) *tests.TestApp { return e.app },
			DisableTestAppCleanup: true,
		}).Test(t)
	}

	// past PocketBase's default 32 MB request limit
	upload("40 MB", 40<<20, http.StatusOK, []string{`"size":41943040`})
	// past the attachment limit: the route's own body limit turns it away
	upload("over the limit", protocol.MaxAttachmentSize+2<<20, http.StatusRequestEntityTooLarge, []string{`"status":413`})
}

func TestAttachmentFieldLimit(t *testing.T) {
	e := newEnv(t)
	c, err := e.app.FindCollectionByNameOrId(protocol.Attachments)
	if err != nil {
		t.Fatal(err)
	}
	f, ok := c.Fields.GetByName("file").(*core.FileField)
	if !ok || f.MaxSize != protocol.MaxAttachmentSize {
		t.Fatalf("file field max size = %v, want %d", f, protocol.MaxAttachmentSize)
	}
}
