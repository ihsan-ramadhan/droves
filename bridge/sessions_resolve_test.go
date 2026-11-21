package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestNormalizeAgentName(t *testing.T) {
	cases := map[string]string{
		"omp":             "omp",
		"oh-my-pi":        "omp",
		"pi":              "pi",
		"pi-coding-agent": "pi",
		"claude":          "claude",
		"claude-code":     "claude",
		"codex":           "codex",
		"grok":            "grok",
		"grok-build":      "grok",
		"kimi":            "kimi",
		"kimi-code":       "kimi",
		"antigravity-cli": "agy",
		"gemini":          "gemini",
		"":                "",
		"  Claude-Code  ": "claude",
	}
	for in, want := range cases {
		if got := normalizeAgentName(in); got != want {
			t.Errorf("normalizeAgentName(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestResolveClaudeSession(t *testing.T) {
	tmp := t.TempDir()
	t.Setenv("CLAUDE_CONFIG_DIR", tmp)
	slug := filepath.Join(tmp, "projects", "-home-user-proj")
	if err := os.MkdirAll(slug, 0o755); err != nil {
		t.Fatal(err)
	}
	id := "123e4567-e89b-42d3-a456-426614174000"
	want := filepath.Join(slug, id+".jsonl")
	if err := os.WriteFile(want, []byte("{}\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	// a decoy with a different id must not match
	if err := os.WriteFile(filepath.Join(slug, "999.jsonl"), []byte("{}\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if got := resolveClaudeSession(id); got != want {
		t.Fatalf("resolveClaudeSession = %q, want %q", got, want)
	}
	if got := resolveClaudeSession("missing-id"); got != "" {
		t.Fatalf("resolveClaudeSession(missing) = %q, want empty", got)
	}
	if got := resolveClaudeSession("../escape"); got != "" {
		t.Fatalf("resolveClaudeSession(escape) = %q, want empty", got)
	}
}

func TestResolvePiSession(t *testing.T) {
	tmp := t.TempDir()
	t.Setenv("PI_CODING_AGENT_DIR", tmp)
	root := filepath.Join(tmp, "sessions", "--home-user-proj--")
	if err := os.MkdirAll(root, 0o755); err != nil {
		t.Fatal(err)
	}
	id := "abc123"
	want := filepath.Join(root, "2026-11-21T00-00-00-000Z_"+id+".jsonl")
	if err := os.WriteFile(want, []byte("{}\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if got := resolvePiSession(id); got != want {
		t.Fatalf("resolvePiSession = %q, want %q", got, want)
	}
	// exact-name file also matches
	id2 := "def456"
	want2 := filepath.Join(root, id2+".jsonl")
	if err := os.WriteFile(want2, []byte("{}\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if got := resolvePiSession(id2); got != want2 {
		t.Fatalf("resolvePiSession exact = %q, want %q", got, want2)
	}
}

func TestResolveSessionFileRejectsBadIDs(t *testing.T) {
	for _, id := range []string{"", ".", "..", "a/b", `a\b`, "a\x00b"} {
		if got := resolveSessionFile("claude", id, ""); got != "" {
			t.Errorf("resolveSessionFile(%q) = %q, want empty", id, got)
		}
	}
}
