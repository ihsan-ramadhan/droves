package main

import (
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
)

func kimiEntryKinds(t *testing.T, out *transcriptFile) []string {
	t.Helper()
	var kinds []string
	for _, e := range out.entries {
		kinds = append(kinds, e["kind"].(string)+":"+e["role"].(string))
	}
	return kinds
}

func TestParseKimiRecord(t *testing.T) {
	out := &transcriptFile{full: map[string]string{}}
	lineNo := 0
	next := func(rec map[string]any) {
		lineNo++
		parseKimiRecord(out, rec, lineNo)
	}

	// metadata → session id captured, no entries.
	next(map[string]any{
		"type":       "metadata",
		"id":         "sess-1",
		"created_at": 1763700000000,
		"agent":      "kimi-code",
	})
	// user context message, tags stripped.
	next(map[string]any{
		"type":       "context.append_message",
		"created_at": 1763700001000,
		"message": map[string]any{
			"role":    "user",
			"content": "<system-reminder>secret</system-reminder>\nShip it",
		},
	})
	// assistant context message → skipped (loop events authoritative).
	next(map[string]any{
		"type":       "context.append_message",
		"created_at": 1763700001500,
		"message": map[string]any{
			"role":    "assistant",
			"content": "duplicate response",
		},
	})
	// think part → reasoning entry + trajectory step.
	next(map[string]any{
		"type":       "context.append_loop_event",
		"created_at": 1763700002000,
		"event": map[string]any{
			"type": "content.part",
			"part": map[string]any{"type": "think", "think": "Inspect repo"},
		},
	})
	// text part → assistant message.
	next(map[string]any{
		"type":       "context.append_loop_event",
		"created_at": 1763700002500,
		"event": map[string]any{
			"type": "content.part",
			"part": map[string]any{"type": "text", "text": "Let me check."},
		},
	})
	// tool.call → tool_call entry.
	next(map[string]any{
		"type":       "context.append_loop_event",
		"created_at": 1763700003000,
		"event": map[string]any{
			"type":       "tool.call",
			"toolCallId": "call_1",
			"name":       "read_file",
			"args":       map[string]any{"path": "x.go"},
		},
	})
	// tool.result → tool_result entry.
	next(map[string]any{
		"type":       "context.append_loop_event",
		"created_at": 1763700003500,
		"event": map[string]any{
			"type":       "tool.result",
			"toolCallId": "call_1",
			"result": map[string]any{
				"output": "package main",
			},
		},
	})
	// error tool.result.
	next(map[string]any{
		"type":       "context.append_loop_event",
		"created_at": 1763700004000,
		"event": map[string]any{
			"type":       "tool.result",
			"toolCallId": "call_2",
			"result": map[string]any{
				"output":  "boom",
				"isError": true,
			},
		},
	})
	// step.end → skipped.
	next(map[string]any{
		"type":       "context.append_loop_event",
		"created_at": 1763700004500,
		"event": map[string]any{
			"type":  "step.end",
			"usage": map[string]any{"input": 1},
		},
	})
	// unknown record type → skipped.
	next(map[string]any{"type": "something.else"})

	kinds := kimiEntryKinds(t, out)
	want := []string{
		"message:user",
		"reasoning:assistant",
		"message:assistant",
		"tool_call:assistant",
		"tool_result:tool",
		"tool_result:tool",
	}
	if strings.Join(kinds, ",") != strings.Join(want, ",") {
		t.Fatalf("kinds = %v, want %v", kinds, want)
	}

	if got := out.sessionID; got != "sess-1" {
		t.Fatalf("sessionID = %q, want %q", got, "sess-1")
	}
	if got := out.entries[0]["text"]; got != "Ship it" {
		t.Fatalf("user text = %q, want %q", got, "Ship it")
	}
	if got := out.entries[0]["sent_at"]; got != "2025-11-21T04:40:01Z" {
		t.Fatalf("sent_at = %v, want milliTime of 1763700001000", got)
	}
	if got := out.entries[2]["text"]; got != "Let me check." {
		t.Fatalf("assistant text = %q", got)
	}
	if got := out.entries[3]["tool_name"]; got != "read_file" {
		t.Fatalf("tool_name = %v", got)
	}
	if !strings.Contains(out.entries[3]["text"].(string), `"path":"x.go"`) {
		t.Fatalf("tool_call text = %q", out.entries[3]["text"])
	}
	if got := out.entries[4]["text"]; got != "package main" {
		t.Fatalf("tool_result text = %q", got)
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

func TestParseKimiRecordContentVariants(t *testing.T) {
	out := &transcriptFile{full: map[string]string{}}
	// user message with array content
	parseKimiRecord(out, map[string]any{
		"type": "context.append_message",
		"message": map[string]any{
			"role": "user",
			"content": []any{
				map[string]any{"type": "text", "text": "part one"},
				map[string]any{"type": "text", "text": "part two"},
			},
		},
	}, 1)
	// tool.call with string args and missing toolCallId → lineNo fallback
	parseKimiRecord(out, map[string]any{
		"type": "context.append_loop_event",
		"event": map[string]any{
			"type": "tool.call",
			"name": "shell",
			"args": `{"cmd":"ls"}`,
		},
	}, 7)
	// tool.result with array output and no toolCallId
	parseKimiRecord(out, map[string]any{
		"type": "context.append_loop_event",
		"event": map[string]any{
			"type":   "tool.result",
			"result": map[string]any{"output": []any{map[string]any{"type": "text", "text": "out"}}},
		},
	}, 8)

	if len(out.entries) != 3 {
		t.Fatalf("entries = %d, want 3", len(out.entries))
	}
	text := out.entries[0]["text"].(string)
	if !strings.Contains(text, "part one") || !strings.Contains(text, "part two") {
		t.Fatalf("user text = %q", text)
	}
	if out.entries[1]["id"] != "kimi-7" {
		t.Fatalf("tool_call id = %v, want kimi-7", out.entries[1]["id"])
	}
	if out.entries[1]["text"] != `{"cmd":"ls"}` {
		t.Fatalf("tool_call args text = %q", out.entries[1]["text"])
	}
	if out.entries[2]["text"] != "out" {
		t.Fatalf("tool_result text = %q", out.entries[2]["text"])
	}
}

func TestResolveKimiSession(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	// os.UserHomeDir may cache; clear via env is enough on unix.

	root := filepath.Join(home, ".kimi-code", "sessions")
	id := "sess-abc"
	wireDir := filepath.Join(root, id, "agents", "main")
	if err := os.MkdirAll(wireDir, 0o755); err != nil {
		t.Fatal(err)
	}
	wire := filepath.Join(wireDir, "wire.jsonl")
	if err := os.WriteFile(wire, []byte("{}\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	// A decoy: different id must not match.
	decoyDir := filepath.Join(root, "other-id", "agents", "main")
	if err := os.MkdirAll(decoyDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(decoyDir, "wire.jsonl"), []byte("{}\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	// A file with the right name but wrong depth must not match.
	shallow := filepath.Join(root, id, "wire.jsonl")
	if err := os.WriteFile(shallow, []byte("{}\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	kimiSessionCache = sync.Map{}

	got, err := resolveKimiSession(id, "")
	if err != nil {
		t.Fatal(err)
	}
	if got != wire {
		t.Fatalf("resolveKimiSession = %q, want %q", got, wire)
	}

	// cached second call still resolves
	got2, err := resolveKimiSession(id, "")
	if err != nil || got2 != wire {
		t.Fatalf("cached resolve = %q, %v", got2, err)
	}

	// unknown id → ""
	got, err = resolveKimiSession("missing-id", "")
	if err != nil || got != "" {
		t.Fatalf("missing id = %q, %v; want empty", got, err)
	}

	// invalid ids → "" (path separators rejected)
	for _, bad := range []string{"", "a/b", "..", "a\\b", "."} {
		got, err = resolveKimiSession(bad, "")
		if err != nil || got != "" {
			t.Fatalf("invalid id %q = %q, %v; want empty", bad, got, err)
		}
	}
}
