package main

import (
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func grokEntryKinds(t *testing.T, out *transcriptFile) []string {
	t.Helper()
	var kinds []string
	for _, e := range out.entries {
		kinds = append(kinds, e["kind"].(string)+":"+e["role"].(string))
	}
	return kinds
}

func TestParseGrokRecord(t *testing.T) {
	out := &transcriptFile{full: map[string]string{}}
	lineNo := 0
	next := func(rec map[string]any) {
		lineNo++
		parseGrokRecord(out, rec, lineNo)
	}

	// User query wrapped in env-snapshot tags → only the query survives.
	next(map[string]any{
		"type":      "user",
		"id":        "u1",
		"content":   "<user_info>cwd=/x</user_info>\n<user_query>Ship it</user_query>\n<git_status>dirty</git_status>",
		"timestamp": "2026-11-21T10:00:00Z",
	})
	// Synthetic injected user record → skipped entirely.
	next(map[string]any{
		"type":             "user",
		"synthetic_reason": "system_reminder",
		"content":          "ignore me",
	})
	// Reasoning with summary parts → reasoning entry + trajectory step.
	next(map[string]any{
		"type":    "reasoning",
		"id":      "r1",
		"summary": []any{map[string]any{"type": "summary_text", "text": "Inspect repo"}},
	})
	// Assistant text + tool call.
	next(map[string]any{
		"type":    "assistant",
		"id":      "a1",
		"content": "Let me check.",
		"tool_calls": []any{
			map[string]any{"id": "call_1", "name": "read_file", "arguments": `{"path":"x.go"}`},
		},
	})
	// Tool result.
	next(map[string]any{
		"type":         "tool_result",
		"tool_call_id": "call_1",
		"content":      "package main",
	})
	// Error tool result.
	next(map[string]any{
		"type":         "tool_result",
		"tool_call_id": "call_2",
		"is_error":     true,
		"content":      "boom",
	})
	// System record.
	next(map[string]any{
		"type":    "system",
		"content": "session started",
	})
	// Unknown type → skipped.
	next(map[string]any{"type": "metadata", "content": "x"})

	kinds := grokEntryKinds(t, out)
	want := []string{
		"message:user",
		"reasoning:assistant",
		"message:assistant",
		"tool_call:assistant",
		"tool_result:tool",
		"tool_result:tool",
		"message:system",
	}
	if strings.Join(kinds, ",") != strings.Join(want, ",") {
		t.Fatalf("kinds = %v, want %v", kinds, want)
	}

	if got := out.entries[0]["text"]; got != "Ship it" {
		t.Fatalf("user text = %q, want %q", got, "Ship it")
	}
	if out.entries[0]["sent_at"] != "2026-11-21T10:00:00Z" {
		t.Fatalf("sent_at = %v", out.entries[0]["sent_at"])
	}
	if got := out.entries[3]["tool_name"]; got != "read_file" {
		t.Fatalf("tool_name = %v", got)
	}
	if out.entries[4]["is_error"] != nil {
		t.Fatalf("expected no is_error on success result, got %v", out.entries[4]["is_error"])
	}
	if out.entries[5]["is_error"] != true {
		t.Fatalf("expected is_error on failed result")
	}
	if len(out.trajectory) != 1 {
		t.Fatalf("trajectory len = %d, want 1", len(out.trajectory))
	}
	if out.trajectory[0]["reasoning_content"] != "Inspect repo" {
		t.Fatalf("trajectory reasoning = %v", out.trajectory[0]["reasoning_content"])
	}
}

func TestParseGrokRecordContentArray(t *testing.T) {
	out := &transcriptFile{full: map[string]string{}}
	parseGrokRecord(out, map[string]any{
		"type": "assistant",
		"content": []any{
			map[string]any{"type": "text", "text": "part one"},
			map[string]any{"type": "text", "text": "part two"},
		},
	}, 1)
	if len(out.entries) != 1 {
		t.Fatalf("entries = %d, want 1", len(out.entries))
	}
	if !strings.Contains(out.entries[0]["text"].(string), "part one") ||
		!strings.Contains(out.entries[0]["text"].(string), "part two") {
		t.Fatalf("text = %q", out.entries[0]["text"])
	}
}

func makeGrokSession(t *testing.T, root, cwdEnc, id string) string {
	t.Helper()
	dir := filepath.Join(root, cwdEnc, id)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	for _, f := range []string{"chat_history.jsonl", "summary.json"} {
		if err := os.WriteFile(filepath.Join(dir, f), []byte("{}\n"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	return filepath.Join(dir, "chat_history.jsonl")
}

func TestResolveGrokSession(t *testing.T) {
	home := t.TempDir()
	t.Setenv("GROK_HOME", home)
	root := filepath.Join(home, "sessions")
	cwd := t.TempDir()
	abs, err := filepath.Abs(cwd)
	if err != nil {
		t.Fatal(err)
	}
	want := makeGrokSession(t, root, url.PathEscape(abs), "sess-1")

	// Direct cwd hit.
	got, err := resolveGrokSession("sess-1", cwd)
	if err != nil || got != want {
		t.Fatalf("resolve = %q, %v; want %q", got, err, want)
	}
	// Cache hit returns same path.
	got2, _ := resolveGrokSession("sess-1", cwd)
	if got2 != want {
		t.Fatalf("cached resolve = %q", got2)
	}
	// Empty cwd falls back to scanning all cwd dirs.
	got3, err := resolveGrokSession("sess-1", "")
	if err != nil || got3 != want {
		t.Fatalf("fallback resolve = %q, %v; want %q", got3, err, want)
	}
	// Missing id → "", nil.
	got4, err := resolveGrokSession("nope", cwd)
	if err != nil || got4 != "" {
		t.Fatalf("missing resolve = %q, %v", got4, err)
	}
	// Invalid ids rejected.
	for _, bad := range []string{"", ".", "..", "a/b", `a\b`, "a\x00b"} {
		if p, _ := resolveGrokSession(bad, cwd); p != "" {
			t.Fatalf("invalid id %q resolved to %q", bad, p)
		}
	}
}
