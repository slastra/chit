package describe

import (
	"encoding/json"
	"os"
	"testing"

	"github.com/slastra/chit/internal/protocol"
)

// The fixture and its sentences are shared with the app's Dart port
// (app/test/describe_test.go reads testdata/sentences.json), so the desk's
// toasts and the phone's notifications say the same thing. Regenerate the
// sentences after changing the describer: CHIT_UPDATE=1 go test.
func TestSentencesMatchTheGolden(t *testing.T) {
	var fx struct {
		Me       string            `json:"me"`
		Names    map[string]string `json:"names"`
		Snapshot protocol.Snapshot `json:"snapshot"`
		Changes  []protocol.Change `json:"changes"`
	}
	raw, err := os.ReadFile("testdata/fixture.json")
	if err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(raw, &fx); err != nil {
		t.Fatal(err)
	}
	w := New(&fx.Snapshot, fx.Names, fx.Me)
	type line struct {
		Note     string `json:"note"`
		Sentence string `json:"sentence"`
	}
	var got []line
	for _, c := range fx.Changes {
		note := w.NoteOf(c)
		got = append(got, line{Note: note, Sentence: w.Describe(c)})
	}
	out, _ := json.MarshalIndent(got, "", "  ")
	if os.Getenv("CHIT_UPDATE") != "" {
		if err := os.WriteFile("testdata/sentences.json", append(out, '\n'), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	want, err := os.ReadFile("testdata/sentences.json")
	if err != nil {
		t.Fatal(err)
	}
	if string(want) != string(append(out, '\n')) {
		t.Fatalf("sentences changed; got\n%s", out)
	}
}
