package main

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

func timeNowPlus(seconds int) time.Time { return time.Now().Add(time.Duration(seconds) * time.Second) }

func TestParseJcodeTranscript(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "session.json")
	data := `{"id":"s1","messages":[
      {"id":"m1","role":"user","timestamp":"2026-01-01T00:00:00Z","content":[{"type":"text","text":"hello"}]},
      {"id":"m2","role":"assistant","timestamp":"2026-01-01T00:00:01Z","content":[{"type":"text","text":"hi"},{"type":"tool_use","id":"c1","name":"bash","input":{"command":"pwd"}}]},
      {"id":"m3","role":"user","timestamp":"2026-01-01T00:00:02Z","content":[{"type":"text","text":"tool output"},{"type":"tool_result","content":[{"type":"text","text":"/tmp"}]}]}
    ]}`
	if err := os.WriteFile(path, []byte(data), 0o600); err != nil {
		t.Fatal(err)
	}
	f, err := os.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	out, err := parseJcodeTranscript(f, &transcriptFile{})
	if err != nil {
		t.Fatal(err)
	}
	if out.sessionID != "s1" || len(out.entries) != 5 {
		t.Fatalf("session=%q entries=%d: %v", out.sessionID, len(out.entries), out.entries)
	}
	want := []string{"message", "message", "tool_call", "message", "tool_result"}
	for i, e := range out.entries {
		if e["kind"] != want[i] {
			t.Errorf("entry %d kind=%v want %s", i, e["kind"], want[i])
		}
	}
	if out.entries[2]["tool_name"] != "bash" {
		t.Errorf("tool_call missing name: %v", out.entries[2])
	}
}

func TestRecentJcodeSessionPrefersMatchingCwd(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("HOME", dir)
	root := filepath.Join(dir, ".jcode", "sessions")
	if err := os.MkdirAll(root, 0o700); err != nil {
		t.Fatal(err)
	}
	os.WriteFile(filepath.Join(root, "new_other.json"),
		[]byte(`{"id":"other","working_dir":"/other","messages":[]}`), 0o600)
	os.Chtimes(filepath.Join(root, "new_other.json"), timeNowPlus(2), timeNowPlus(2))
	os.WriteFile(filepath.Join(root, "old_match.json"),
		[]byte(`{"id":"match","working_dir":"/work/proj","messages":[]}`), 0o600)
	if got := recentJcodeSession("/work/proj/sub"); filepath.Base(got) != "old_match.json" {
		t.Fatalf("got %q", got)
	}
}
