package main

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
)

func TestResolveScoped(t *testing.T) {
	root := t.TempDir()
	other := t.TempDir()
	tc := &scoutToolContext{ctx: context.Background(), cwd: root, roots: []string{root}}

	ok, err := tc.resolveScoped("sub/dir/file.txt")
	if err != nil {
		t.Fatalf("relative path rejected: %v", err)
	}
	if want := filepath.Join(root, "sub/dir/file.txt"); ok != want {
		t.Fatalf("resolveScoped = %q, want %q", ok, want)
	}
	if _, err := tc.resolveScoped(filepath.Join(root, "ok.txt")); err != nil {
		t.Fatalf("absolute inside root rejected: %v", err)
	}
	if _, err := tc.resolveScoped(filepath.Join(other, "evil.txt")); err == nil {
		t.Fatal("path outside roots accepted")
	}
	if _, err := tc.resolveScoped("../escape.txt"); err == nil {
		t.Fatal("traversal accepted")
	}
}

func TestResolveScopedSymlink(t *testing.T) {
	root := t.TempDir()
	outside := t.TempDir()
	tc := &scoutToolContext{ctx: context.Background(), cwd: root, roots: []string{root}}

	if err := os.Symlink(outside, filepath.Join(root, "escape")); err != nil {
		t.Fatal(err)
	}
	if _, err := tc.resolveScoped("escape/file.txt"); err == nil {
		t.Fatal("symlink outside the root accepted")
	}

	real := filepath.Join(root, "real")
	if err := os.Mkdir(real, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(real, filepath.Join(root, "workspace")); err != nil {
		t.Fatal(err)
	}
	got, err := tc.resolveScoped("workspace/file.txt")
	if err != nil {
		t.Fatalf("symlink inside root rejected: %v", err)
	}
	if want := filepath.Join(real, "file.txt"); got != want {
		t.Fatalf("resolveScoped = %q, want %q", got, want)
	}
}

func TestScoutToolsRoundtrip(t *testing.T) {
	root := t.TempDir()
	tc := &scoutToolContext{ctx: context.Background(), cwd: root, roots: []string{root}}

	if out := scoutWriteFile(tc, json.RawMessage(`{"path":"a/b.txt","content":"hello"}`)); !strings.Contains(out, "wrote 5 bytes") {
		t.Fatalf("write_file = %q", out)
	}
	if out := scoutReadFile(tc, json.RawMessage(`{"path":"a/b.txt"}`)); out != "hello" {
		t.Fatalf("read_file = %q", out)
	}
	if out := scoutListDir(tc, json.RawMessage(`{"path":"."}`)); !strings.Contains(out, `"a"`) {
		t.Fatalf("list_dir = %q", out)
	}
	if out := scoutRunCommand(tc, json.RawMessage(`{"command":"echo hi"}`)); !strings.Contains(out, "hi") {
		t.Fatalf("run_command = %q", out)
	}
	// tools refuse paths outside roots
	if out := scoutReadFile(tc, json.RawMessage(`{"path":"/etc/passwd"}`)); !strings.Contains(out, "outside the allowed") {
		t.Fatalf("read_file escape = %q", out)
	}
}

// TestRunOpenAIToolLoop drives runOpenAI against a fake endpoint that asks for
// read_file once, then answers — proving the tool loop wires messages correctly.
func TestRunOpenAIToolLoop(t *testing.T) {
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, "note.txt"), []byte("scout-note"), 0o644); err != nil {
		t.Fatal(err)
	}
	var sawToolResult atomic.Bool
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			Messages []struct {
				Role       string `json:"role"`
				Content    string `json:"content"`
				ToolCallID string `json:"tool_call_id"`
				ToolCalls  []struct {
					ID       string `json:"id"`
					Function struct {
						Name      string `json:"name"`
						Arguments string `json:"arguments"`
					} `json:"function"`
				} `json:"tool_calls"`
			} `json:"messages"`
			Tools []map[string]any `json:"tools"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			t.Errorf("bad request: %v", err)
		}
		if len(req.Tools) == 0 {
			t.Errorf("request missing tools")
		}
		last := req.Messages[len(req.Messages)-1]
		if last.Role == "tool" {
			sawToolResult.Store(true)
			if !strings.Contains(last.Content, "scout-note") {
				t.Errorf("tool result missing file content: %q", last.Content)
			}
			w.Header().Set("Content-Type", "application/json")
			_, _ = w.Write([]byte(`{"choices":[{"message":{"role":"assistant","content":"done: file says scout-note"}}]}`))
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"choices":[{"message":{"role":"assistant","content":"","tool_calls":[{"id":"call_1","type":"function","function":{"name":"read_file","arguments":"{\"path\":\"note.txt\"}"}}]}}]}`))
	}))
	defer srv.Close()

	iv := assistantInvoke{
		ctx:      context.Background(),
		cli:      assistantCLI{name: "openai"},
		endpoint: srv.URL,
		modelID:  "test-model",
		cwd:      root,
	}
	answer, _, err := runOpenAI(iv)
	if err != nil {
		t.Fatalf("runOpenAI: %v", err)
	}
	if !sawToolResult.Load() {
		t.Fatal("endpoint never received a tool result message")
	}
	if answer != "done: file says scout-note" {
		t.Fatalf("answer = %q", answer)
	}
}

func TestScoutWorkspaceToolsCatalog(t *testing.T) {
	tools := scoutOpenAITools()
	if len(tools) != 8 {
		t.Fatalf("tools = %d, want 8", len(tools))
	}
	names := map[string]bool{}
	for _, tool := range tools {
		fn, _ := tool["function"].(map[string]any)
		names[fn["name"].(string)] = true
		params, _ := fn["parameters"].(map[string]any)
		if raw, ok := params["required"]; ok {
			req, valid := raw.([]string)
			if !valid || len(req) == 0 {
				t.Fatalf("tool %q emits invalid required: %v", fn["name"], raw)
			}
		}
	}
	for _, want := range []string{"read_file", "list_dir", "write_file", "run_command",
		"workspace_status", "agent_history", "workspace_diff", "terminal_output"} {
		if !names[want] {
			t.Fatalf("missing tool %q", want)
		}
	}
}

func TestScoutWorkspaceToolsScope(t *testing.T) {
	tc := &scoutToolContext{ctx: context.Background(), cwd: t.TempDir()}
	// no server: workspace tools degrade gracefully
	if out := scoutWorkspaceStatus(tc, json.RawMessage(`{}`)); !strings.Contains(out, "unavailable") {
		t.Fatalf("workspace_status = %q", out)
	}
	if out := scoutAgentHistory(tc, json.RawMessage(`{}`)); !strings.Contains(out, "required") {
		t.Fatalf("agent_history = %q", out)
	}
	if out := scoutTerminalOutput(tc, json.RawMessage(`{}`)); !strings.Contains(out, "required") {
		t.Fatalf("terminal_output = %q", out)
	}
	// scoping helper
	tc.allowed = map[string]bool{"w1": true}
	if !tc.wsAllowed("w1") || tc.wsAllowed("w2") {
		t.Fatal("wsAllowed scoping wrong")
	}
	tc.allowed = nil
	if !tc.wsAllowed("anything") {
		t.Fatal("nil allowed must permit all")
	}
	if fresh := newScoutToolContext(assistantInvoke{}); fresh.wsAllowed("w1") {
		t.Fatal("empty workspace ids must not allow all")
	}
}

func TestCapJSONTrimsLargePatch(t *testing.T) {
	big := strings.Repeat("x", scoutMaxCmdOutput)
	v := map[string]any{"patch": big, "entries": []any{}}
	out := capJSON(v)
	if len(out) > scoutMaxCmdOutput+32 {
		t.Fatalf("capJSON = %d bytes", len(out))
	}
	if !strings.Contains(out, "truncated") {
		t.Fatal("expected truncation marker")
	}
}

func TestScoutCLIErrorText(t *testing.T) {
	// JSONL stdout with a nested provider error -> readable message
	jsonl := []byte("{\"type\":\"session\",\"id\":\"x\"}\n" +
		"{\"type\":\"message\",\"message\":{\"role\":\"assistant\",\"content\":[],\"errorMessage\":\"429 Free usage limit reached\"}}\n")
	if got := scoutCLIErrorText(jsonl); got != "429 Free usage limit reached" {
		t.Fatalf("jsonl error = %q", got)
	}
	// plain text passes through
	if got := scoutCLIErrorText([]byte("boom: something failed")); got != "boom: something failed" {
		t.Fatalf("plain error = %q", got)
	}
	// empty
	if got := scoutCLIErrorText(nil); got != "" {
		t.Fatalf("empty error = %q", got)
	}
}
