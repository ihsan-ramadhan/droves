package main

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

func timeNowPlus(seconds int) time.Time { return time.Now().Add(time.Duration(seconds) * time.Second) }

func writeJcodeSession(t *testing.T, path, data string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(data), 0o600); err != nil {
		t.Fatal(err)
	}
}

func TestParseJcodeTranscript(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "session.json")
	data := `{"id":"s1","messages":[
      {"id":"m1","role":"user","timestamp":"2026-01-01T00:00:00Z","content":[{"type":"text","text":"hello"}]},
      {"id":"m2","role":"assistant","timestamp":"2026-01-01T00:00:01Z","content":[{"type":"text","text":"hi"},{"type":"tool_use","id":"c1","name":"bash","input":{"command":"pwd"}}]},
      {"id":"m3","role":"user","timestamp":"2026-01-01T00:00:02Z","content":[{"type":"tool_result","content":"/tmp"}]}
    ]}`
	writeJcodeSession(t, path, data)
	out, err := parseJcodeTranscript(path, &transcriptFile{})
	if err != nil {
		t.Fatal(err)
	}
	if out.sessionID != "s1" || len(out.entries) != 4 {
		t.Fatalf("session=%q entries=%d: %v", out.sessionID, len(out.entries), out.entries)
	}
	want := []string{"message", "message", "tool_call", "tool_result"}
	for i, e := range out.entries {
		if e["kind"] != want[i] {
			t.Errorf("entry %d kind=%v want %s", i, e["kind"], want[i])
		}
	}
	if out.entries[2]["tool_name"] != "bash" {
		t.Errorf("tool_call missing name: %v", out.entries[2])
	}
	if got := out.entries[3]["text"]; got != "/tmp" {
		t.Errorf("tool_result text=%v want the content payload", got)
	}
}

// the checkpoint lags; new turns only exist in the journal
func TestParseJcodeTranscriptAppendsJournal(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "session.json")
	writeJcodeSession(t, path, `{"id":"s1","messages":[
      {"id":"m1","role":"user","timestamp":"2026-01-01T00:00:00Z","content":[{"type":"text","text":"first"}]}
    ]}`)
	journal := `{"meta":{"updated_at":"2026-01-01T00:00:05Z"},"append_messages":[{"id":"m1","role":"user","timestamp":"2026-01-01T00:00:00Z","content":[{"type":"text","text":"first"}]},{"id":"m2","role":"assistant","timestamp":"2026-01-01T00:00:05Z","content":[{"type":"text","text":"second"}]}]}
{"meta":{"updated_at":"2026-01-01T00:00:09Z"},"append_messages":[{"id":"m3","role":"user","timestamp":"2026-01-01T00:00:09Z","content":[{"type":"text","text":"third"}]}]}
`
	writeJcodeSession(t, jcodeJournalPath(path), journal)
	out, err := parseJcodeTranscript(path, &transcriptFile{})
	if err != nil {
		t.Fatal(err)
	}
	if len(out.entries) != 3 {
		t.Fatalf("entries=%d: %v", len(out.entries), out.entries)
	}
	for i, want := range []string{"first", "second", "third"} {
		if got := out.entries[i]["text"]; got != want {
			t.Errorf("entry %d text=%v want %s", i, got, want)
		}
	}
}

// after a compaction the checkpoint is the truth; older journal rows must not
// resurface in front of the newer tail
func TestJcodeJournalSkipsFoldedRows(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "session.json")
	writeJcodeSession(t, path, `{"id":"s1","messages":[
      {"id":"kept","role":"user","timestamp":"2026-01-01T01:00:00Z","content":[{"type":"text","text":"kept"}]}
    ]}`)
	journal := `{"append_messages":[{"id":"dropped","role":"user","timestamp":"2026-01-01T00:00:00Z","content":[{"type":"text","text":"dropped"}]},{"id":"fresh","role":"assistant","timestamp":"2026-01-01T01:00:05Z","content":[{"type":"text","text":"fresh"}]}]}
`
	writeJcodeSession(t, jcodeJournalPath(path), journal)
	out, err := parseJcodeTranscript(path, &transcriptFile{})
	if err != nil {
		t.Fatal(err)
	}
	if len(out.entries) != 2 || out.entries[0]["text"] != "kept" || out.entries[1]["text"] != "fresh" {
		t.Fatalf("entries=%v", out.entries)
	}
}

func TestJcodeSessionPathIsExact(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("HOME", dir)
	root := filepath.Join(dir, ".jcode", "sessions")
	if err := os.MkdirAll(root, 0o700); err != nil {
		t.Fatal(err)
	}
	writeJcodeSession(t, filepath.Join(root, "session_a.json"), `{"id":"a","messages":[]}`)
	writeJcodeSession(t, filepath.Join(root, "session_b.json"), `{"id":"b","messages":[]}`)
	if got := jcodeSessionPath("session_b"); filepath.Base(got) != "session_b.json" {
		t.Fatalf("got %q", got)
	}
	if got := jcodeSessionPath("../session_a"); got != "" {
		t.Fatalf("traversal returned %q", got)
	}
}

func TestJcodeArgvSessionID(t *testing.T) {
	if got := jcodeArgvSessionID([]string{"jcode", "--resume", "session_rat_1"}); got != "session_rat_1" {
		t.Fatalf("got %q", got)
	}
	if got := jcodeArgvSessionID([]string{"jcode"}); got != "" {
		t.Fatalf("got %q", got)
	}
}

func TestJcodeClientSessionID(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("HOME", dir)
	clients := filepath.Join(dir, ".jcode", "client_sessions")
	if err := os.MkdirAll(clients, 0o700); err != nil {
		t.Fatal(err)
	}
	writeJcodeSession(t, filepath.Join(clients, "4242"), "session_rat_1795624844220_2cb0eaa0a401f4fa\n")
	if got := jcodeClientSessionID(4242); got != "session_rat_1795624844220_2cb0eaa0a401f4fa" {
		t.Fatalf("got %q", got)
	}
	if got := jcodeClientSessionID(9999); got != "" {
		t.Fatalf("got %q", got)
	}
}

func TestRecentJcodeSessionPrefersMatchingCwd(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("HOME", dir)
	root := filepath.Join(dir, ".jcode", "sessions")
	if err := os.MkdirAll(root, 0o700); err != nil {
		t.Fatal(err)
	}
	writeJcodeSession(t, filepath.Join(root, "new_other.json"),
		`{"id":"other","working_dir":"/other","messages":[]}`)
	os.Chtimes(filepath.Join(root, "new_other.json"), timeNowPlus(2), timeNowPlus(2))
	writeJcodeSession(t, filepath.Join(root, "old_match.json"),
		`{"id":"match","working_dir":"/work/proj","messages":[]}`)
	if got := recentJcodeSession("/work/proj/sub"); filepath.Base(got) != "old_match.json" {
		t.Fatalf("got %q", got)
	}
}
