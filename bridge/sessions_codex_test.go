package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func codexRec(t *testing.T, v map[string]any) map[string]any {
	t.Helper()
	return v
}

func TestParseCodexRecord(t *testing.T) {
	out := &transcriptFile{full: make(map[string]string)}
	p := newCodexParser()
	feed := func(v map[string]any) {
		b, _ := json.Marshal(v)
		var rec map[string]any
		if err := json.Unmarshal(b, &rec); err != nil {
			t.Fatalf("bad record: %v", err)
		}
		p.parse(out, rec, len(out.entries)+1)
	}

	feed(map[string]any{"type": "session_meta", "payload": map[string]any{"id": "sess-1"}})
	if out.sessionID != "sess-1" {
		t.Fatalf("sessionID = %q", out.sessionID)
	}

	// event_msg user + agent messages (no response_item messages -> kept)
	feed(map[string]any{"type": "event_msg", "payload": map[string]any{
		"type": "user_message", "message": "hello codex",
	}})
	feed(map[string]any{"type": "event_msg", "payload": map[string]any{
		"type": "agent_message", "message": "hi there",
	}})
	feed(map[string]any{"type": "event_msg", "payload": map[string]any{
		"type": "token_count", "info": map[string]any{},
	}})

	// response_item message user -> suppresses pending user event
	feed(map[string]any{"type": "response_item", "payload": map[string]any{
		"type": "message", "role": "user",
		"content": []any{map[string]any{"type": "input_text", "text": "real user msg"}},
	}})
	// response_item message assistant
	feed(map[string]any{"type": "response_item", "payload": map[string]any{
		"type": "message", "role": "assistant",
		"content": []any{
			map[string]any{"type": "text", "text": "part one"},
			map[string]any{"type": "text", "text": "part two"},
		},
	}})
	// reasoning
	feed(map[string]any{"type": "response_item", "payload": map[string]any{
		"type": "reasoning", "summary": []any{map[string]any{"type": "text", "text": "thinking hard"}},
	}})
	// function_call
	feed(map[string]any{"type": "response_item", "payload": map[string]any{
		"type": "function_call", "name": "shell", "call_id": "call-1",
		"arguments": `{"cmd":"ls"}`,
	}})
	// local_shell_call style output
	feed(map[string]any{"type": "response_item", "payload": map[string]any{
		"type": "function_call_output", "call_id": "call-1", "output": "file.txt\n",
	}})
	// failed tool result
	feed(map[string]any{"type": "response_item", "payload": map[string]any{
		"type": "custom_tool_call_output", "call_id": "call-2",
		"output": []any{map[string]any{"type": "text", "text": "boom"}},
		"status": "failed",
	}})

	p.flush(out)

	var kinds []string
	roles := map[string]int{}
	texts := map[string]string{}
	for _, e := range out.entries {
		kinds = append(kinds, e["kind"].(string))
		roles[e["role"].(string)]++
		texts[e["kind"].(string)+"/"+e["role"].(string)] = e["text"].(string)
	}

	// expected: user msg (response_item), assistant msg, reasoning,
	// tool_call, tool_result x2; event user suppressed (response user exists),
	// event agent suppressed (response assistant exists)
	if len(out.entries) != 6 {
		t.Fatalf("entries = %d, want 6: %v", len(out.entries), kinds)
	}
	if out.entries[0]["kind"] != "message" || out.entries[0]["role"] != "user" ||
		out.entries[0]["text"] != "real user msg" {
		t.Fatalf("entry0 = %v", out.entries[0])
	}
	if out.entries[1]["kind"] != "message" || out.entries[1]["role"] != "assistant" ||
		out.entries[1]["text"] != "part one\npart two" {
		t.Fatalf("entry1 = %v", out.entries[1])
	}
	if out.entries[2]["kind"] != "reasoning" || out.entries[2]["text"] != "thinking hard" {
		t.Fatalf("entry2 = %v", out.entries[2])
	}
	if len(out.trajectory) != 1 || out.trajectory[0]["reasoning_content"] != "thinking hard" {
		t.Fatalf("trajectory = %v", out.trajectory)
	}
	tc := out.entries[3]
	if tc["kind"] != "tool_call" || tc["role"] != "assistant" ||
		tc["tool_name"] != "shell" || tc["text"] != `{"cmd":"ls"}` {
		t.Fatalf("tool_call = %v", tc)
	}
	tr := out.entries[4]
	if tr["kind"] != "tool_result" || tr["role"] != "tool" || tr["text"] != "file.txt\n" {
		t.Fatalf("tool_result = %v", tr)
	}
	trErr := out.entries[5]
	if trErr["kind"] != "tool_result" || trErr["is_error"] != true || trErr["text"] != "boom" {
		t.Fatalf("tool_result err = %v", trErr)
	}
}

func TestParseCodexRecordEventOnly(t *testing.T) {
	out := &transcriptFile{full: make(map[string]string)}
	p := newCodexParser()
	rec := map[string]any{"type": "event_msg", "payload": map[string]any{
		"type": "user_message", "message": "only event",
	}}
	p.parse(out, rec, 1)
	p.flush(out)
	if len(out.entries) != 1 || out.entries[0]["text"] != "only event" || out.entries[0]["role"] != "user" {
		t.Fatalf("entries = %v", out.entries)
	}
}

func TestResolveCodexSession(t *testing.T) {
	home := t.TempDir()
	id := "01234567-89ab-cdef-0123-456789abcdef"
	// invalid id
	if p, err := resolveCodexSession("not-a-uuid", ""); err == nil || p != "" {
		t.Fatalf("invalid id: %q %v", p, err)
	}
	// id containing path separator rejected by shape anyway
	if p, err := resolveCodexSession("../"+id, ""); err == nil || p != "" {
		t.Fatalf("path id: %q %v", p, err)
	}
	// not found
	if p, err := resolveCodexSession(id, ""); err != nil || p != "" {
		t.Fatalf("not found: %q %v", p, err)
	}
	// create nested file under sessions/
	dir := filepath.Join(home, "sessions", "2026", "11", "21")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	want := filepath.Join(dir, "rollout-2026-11-21T00-00-00-"+id+".jsonl")
	if err := os.WriteFile(want, []byte("{}\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	t.Setenv("CODEX_HOME", home)
	// clear cache for this home+id (not cached since earlier lookups missed)
	got, err := resolveCodexSession(id, "")
	if err != nil || got != want {
		t.Fatalf("resolve = %q, %v; want %q", got, err, want)
	}
	// archived_sessions fallback
	id2 := "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
	adir := filepath.Join(home, "archived_sessions")
	if err := os.MkdirAll(adir, 0o755); err != nil {
		t.Fatal(err)
	}
	awant := filepath.Join(adir, "x-"+id2+".jsonl")
	if err := os.WriteFile(awant, []byte("{}\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if got, err := resolveCodexSession(id2, ""); err != nil || got != awant {
		t.Fatalf("archived resolve = %q, %v; want %q", got, err, awant)
	}
}

func TestParseCodexTranscriptTwoPass(t *testing.T) {
	// event_msg user appears BEFORE the response_item user message;
	// only the pre-scan can suppress the duplicate.
	lines := []string{
		`{"type":"event_msg","payload":{"type":"user_message","message":"dup user"}}`,
		`{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"real user"}]}}`,
		`{"type":"event_msg","payload":{"type":"agent_message","message":"only agent"}}`,
	}
	dir := t.TempDir()
	path := filepath.Join(dir, "rollout-x-01234567-89ab-cdef-0123-456789abcdef.jsonl")
	if err := os.WriteFile(path, []byte(strings.Join(lines, "\n")+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	f, err := os.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	out := &transcriptFile{full: make(map[string]string)}
	got, err := parseCodexTranscript(f, out)
	if err != nil {
		t.Fatal(err)
	}
	if len(got.entries) != 2 {
		t.Fatalf("entries = %v", got.entries)
	}
	if got.entries[0]["text"] != "real user" || got.entries[0]["role"] != "user" {
		t.Fatalf("entry0 = %v", got.entries[0])
	}
	if got.entries[1]["text"] != "only agent" || got.entries[1]["role"] != "assistant" {
		t.Fatalf("entry1 = %v", got.entries[1])
	}
}
