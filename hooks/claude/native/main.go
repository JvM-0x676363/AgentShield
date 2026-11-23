package main

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"regexp"
	"unicode/utf8"
)

const maxBytes = 1024 * 1024

var patterns = []struct {
	name string
	re   *regexp.Regexp
}{
	{"private_key", regexp.MustCompile(`-----BEGIN (?:[A-Z0-9]+ )*PRIVATE KEY-----`)},
	{"aws_access_key_id", regexp.MustCompile(`\b(?:AKIA|ASIA)[A-Z0-9]{16}\b`)},
	{"github_token", regexp.MustCompile(`\bgh[pousr]_[A-Za-z0-9]{36,}\b`)},
	{"github_fine_grained_token", regexp.MustCompile(`\bgithub_pat_[A-Za-z0-9_]{40,}\b`)},
	{"gitlab_token", regexp.MustCompile(`\bglpat-[A-Za-z0-9_-]{20,}`)},
	{"slack_token", regexp.MustCompile(`\bxox[baprs]-[A-Za-z0-9-]{20,}`)},
}

func evaluate(raw []byte) string {
	if len(raw) > maxBytes {
		return "input_limit"
	}
	if !utf8.Valid(raw) {
		return "evaluation_failed"
	}
	var event map[string]any
	if json.Unmarshal(raw, &event) != nil || event == nil {
		return "invalid_event"
	}
	if event["hook_event_name"] != "PreToolUse" {
		return "invalid_event"
	}
	input, ok := event["tool_input"].(map[string]any)
	if !ok {
		return "invalid_input"
	}
	var values []any
	switch event["tool_name"] {
	case "Write":
		values = []any{input["content"]}
	case "Edit":
		values = []any{input["new_string"]}
	case "NotebookEdit":
		if input["edit_mode"] == "delete" {
			values = []any{""}
		} else {
			values = []any{input["new_source"]}
		}
	case "MultiEdit":
		edits, ok := input["edits"].([]any)
		if !ok || len(edits) == 0 {
			return "invalid_edits"
		}
		for _, item := range edits {
			edit, ok := item.(map[string]any)
			if !ok {
				return "invalid_content"
			}
			values = append(values, edit["new_string"])
		}
	default:
		return "unsupported_tool"
	}
	for _, value := range values {
		text, ok := value.(string)
		if !ok {
			return "invalid_content"
		}
		for _, pattern := range patterns {
			if pattern.re.MatchString(text) {
				return "secret_pattern_" + pattern.name
			}
		}
	}
	return ""
}

func run(input io.Reader, output io.Writer) error {
	raw, err := io.ReadAll(io.LimitReader(input, maxBytes+1))
	code := "input_read_failed"
	if err == nil {
		code = evaluate(raw)
	}
	result := map[string]any{}
	if code != "" {
		result["hookSpecificOutput"] = map[string]string{
			"hookEventName":            "PreToolUse",
			"permissionDecision":       "deny",
			"permissionDecisionReason": "AgentShield: " + code + ". Write blocked; no submitted content is included in this diagnostic.",
		}
	}
	return json.NewEncoder(output).Encode(result)
}

func main() {
	if err := run(os.Stdin, os.Stdout); err != nil {
		fmt.Fprintln(os.Stderr, "AgentShield: output_failed")
		os.Exit(1)
	}
}
