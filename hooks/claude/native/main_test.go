package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"strings"
	"testing"
)

func event(tool string, input any) []byte {
	raw, _ := json.Marshal(map[string]any{"hook_event_name": "PreToolUse", "tool_name": tool, "tool_input": input})
	return raw
}

func TestPatternsAndNonDisclosure(t *testing.T) {
	for _, marker := range []string{
		"AK" + "IA" + strings.Repeat("Z", 16), "gh" + "p_" + strings.Repeat("z", 36),
		"github_" + "pat_" + strings.Repeat("z", 50), "gl" + "pat-" + strings.Repeat("z", 20),
		"xox" + "b-" + strings.Repeat("z", 24), "-----BEGIN " + "PRIVATE KEY-----",
	} {
		var out bytes.Buffer
		raw := event("Write", map[string]any{"content": marker, "file_path": "synthetic.example"})
		if err := run(bytes.NewReader(raw), &out); err != nil {
			t.Fatal(err)
		}
		if !strings.Contains(out.String(), `"permissionDecision":"deny"`) || strings.Contains(out.String(), marker) || strings.Contains(out.String(), "synthetic.example") {
			t.Fatal("unexpected or leaking decision")
		}
	}
}

func TestTools(t *testing.T) {
	for tool, input := range map[string]any{
		"Write": map[string]any{"content": "safe"}, "Edit": map[string]any{"new_string": "safe"},
		"NotebookEdit": map[string]any{"edit_mode": "delete"},
		"MultiEdit":    map[string]any{"edits": []any{map[string]any{"new_string": "safe"}}},
	} {
		if code := evaluate(event(tool, input)); code != "" {
			t.Fatal(tool, code)
		}
	}
}

func TestInvalidInputs(t *testing.T) {
	for _, raw := range [][]byte{
		[]byte("null"), []byte("[]"), []byte("{}"), {0xff}, []byte("{} {}"),
		event("Bash", map[string]any{}), event("Write", map[string]any{"content": 1}),
		event("MultiEdit", map[string]any{"edits": []any{nil}}),
		event("MultiEdit", map[string]any{"edits": []any{}}),
		bytes.Repeat([]byte("x"), maxBytes+1),
	} {
		if evaluate(raw) == "" {
			t.Fatal("invalid input accepted")
		}
	}
}

type failedIO struct{}

func (failedIO) Read([]byte) (int, error)  { return 0, errors.New("synthetic-read-error") }
func (failedIO) Write([]byte) (int, error) { return 0, errors.New("synthetic-write-error") }

func TestIOFailures(t *testing.T) {
	var out bytes.Buffer
	if err := run(failedIO{}, &out); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(out.String(), "input_read_failed") || strings.Contains(out.String(), "synthetic-read-error") {
		t.Fatal("read failure not safely denied")
	}
	if run(strings.NewReader("{}"), failedIO{}) == nil {
		t.Fatal("output failure hidden")
	}
}

func TestCleanProtocol(t *testing.T) {
	var out bytes.Buffer
	if err := run(bytes.NewReader(event("Write", map[string]any{"content": "process.env.API_TOKEN"})), &out); err != nil {
		t.Fatal(err)
	}
	if out.String() != "{}\n" {
		t.Fatal("clean result must not grant allow")
	}
}
