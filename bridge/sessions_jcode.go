package main

import (
	"bufio"
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

// jcode session files are whole JSON objects, not JSONL: {"id":...,"messages":[...]}.
// herdr reports jcode agents with no agent_session hook, so the newest session
// touched in the agent's cwd is the best available guess.
func jcodeSessionsRoots() []string {
	home, err := os.UserHomeDir()
	if err != nil {
		return nil
	}
	return []string{filepath.Join(home, ".jcode", "sessions")}
}

// jcodeCwdKey matches a session's working_dir to the pane's current cwd so
// two open jcode agents in different repos do not share a transcript.
func jcodeCwdKey(session map[string]any) string {
	v := session["working_dir"]
	if s, ok := v.(string); ok {
		return filepath.Clean(strings.TrimSpace(s))
	}
	if meta, ok := session["meta"].(map[string]any); ok {
		if s, ok := meta["working_dir"].(string); ok {
			return filepath.Clean(strings.TrimSpace(s))
		}
	}
	return ""
}

// recentJcodeSession picks the newest session file whose recorded cwd matches
// the pane. Sessions without a cwd are only used when nothing matches.
func recentJcodeSession(cwd string) string {
	roots := jcodeSessionsRoots()
	clean := filepath.Clean(strings.TrimSpace(cwd))
	var fallback string
	var fallbackMod time.Time
	var best string
	var bestMod time.Time
	for _, root := range roots {
		entries, err := os.ReadDir(root)
		if err != nil {
			continue
		}
		for _, e := range entries {
			if e.IsDir() || !strings.HasSuffix(e.Name(), ".json") || strings.HasSuffix(e.Name(), ".bak") {
				continue
			}
			path := filepath.Join(root, e.Name())
			st, err := e.Info()
			if err != nil {
				continue
			}
			if fallback == "" || st.ModTime().After(fallbackMod) {
				fallback, fallbackMod = path, st.ModTime()
			}
			if clean == "" {
				continue
			}
			data, err := os.ReadFile(path)
			if err != nil {
				continue
			}
			var doc map[string]any
			if json.Unmarshal(data, &doc) != nil {
				continue
			}
			key := jcodeCwdKey(doc)
			if key == "" || key != clean && !strings.HasPrefix(clean, key+string(filepath.Separator)) {
				continue
			}
			if best == "" || st.ModTime().After(bestMod) {
				best, bestMod = path, st.ModTime()
			}
		}
	}
	if best != "" {
		return best
	}
	// a wrong repo is worse than no transcript when several agents are open
	return ""
}

// jcodeSessionPath returns the checkpoint file for a known session id. The id
// is the whole file name, so an exact lookup cannot pick a neighbour.
func jcodeSessionPath(id string) string {
	if !validSessionID(id) {
		return ""
	}
	for _, root := range jcodeSessionsRoots() {
		path := filepath.Join(root, id+".json")
		if _, err := os.Stat(path); err == nil {
			return path
		}
	}
	return ""
}

// jcodeJournalPath is the append-only log jcode writes between checkpoints.
// The checkpoint lags by turns, the journal does not.
func jcodeJournalPath(path string) string {
	if !strings.HasSuffix(path, ".json") {
		return ""
	}
	return strings.TrimSuffix(path, ".json") + ".journal.jsonl"
}

// jcodePaneSessionID reads the session running in a pane from herdr's process
// table. jcode records the live id per client pid, and reattaches carry it in
// --resume, so the id is exact even when several sessions share one cwd.
func jcodePaneSessionID(ctx context.Context, s *Server, paneID string) string {
	if paneID == "" || s == nil || s.herdr == nil {
		return ""
	}
	raw, err := s.herdr.Call(ctx, "pane.process_info", map[string]any{"pane_id": paneID})
	if err != nil {
		return ""
	}
	var res struct {
		ProcessInfo struct {
			ForegroundProcesses []struct {
				PID  int      `json:"pid"`
				Name string   `json:"name"`
				Argv []string `json:"argv"`
			} `json:"foreground_processes"`
		} `json:"process_info"`
	}
	if json.Unmarshal(raw, &res) != nil {
		return ""
	}
	for _, p := range res.ProcessInfo.ForegroundProcesses {
		if !strings.Contains(strings.ToLower(p.Name), "jcode") {
			continue
		}
		if id := jcodeClientSessionID(p.PID); id != "" {
			return id
		}
		if id := jcodeArgvSessionID(p.Argv); id != "" {
			return id
		}
	}
	return ""
}

func jcodeClientSessionID(pid int) string {
	if pid <= 0 {
		return ""
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	data, err := os.ReadFile(filepath.Join(home, ".jcode", "client_sessions", strconv.Itoa(pid)))
	if err != nil {
		return ""
	}
	id := strings.TrimSpace(string(data))
	if !validSessionID(id) {
		return ""
	}
	return id
}

func jcodeArgvSessionID(argv []string) string {
	for i, arg := range argv {
		switch arg {
		case "--resume", "-r", "--session":
			if i+1 < len(argv) && validSessionID(argv[i+1]) {
				return argv[i+1]
			}
		}
	}
	return ""
}

type jcodeBlock struct {
	Type    string          `json:"type"`
	Text    string          `json:"text"`
	Name    string          `json:"name"`
	Input   json.RawMessage `json:"input"`
	Content json.RawMessage `json:"content"`
	IsError bool            `json:"is_error"`
}

type jcodeMessage struct {
	ID        string       `json:"id"`
	Role      string       `json:"role"`
	Timestamp string       `json:"timestamp"`
	Content   []jcodeBlock `json:"content"`
}

func parseJcodeTime(value string) time.Time {
	if value == "" {
		return time.Time{}
	}
	if t, err := time.Parse(time.RFC3339Nano, value); err == nil {
		return t
	}
	return time.Time{}
}

// parseJcodeTranscript merges the checkpoint with the journal deltas, which is
// what makes the chat live: the checkpoint is only rewritten every few turns.
func parseJcodeTranscript(path string, out *transcriptFile) (*transcriptFile, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	var doc struct {
		ID       string         `json:"id"`
		Messages []jcodeMessage `json:"messages"`
	}
	if err := json.NewDecoder(bufio.NewReader(f)).Decode(&doc); err != nil {
		return nil, err
	}
	out.sessionID = doc.ID
	if out.full == nil {
		out.full = make(map[string]string)
	}
	seen := make(map[string]bool, len(doc.Messages))
	var lastSent time.Time
	for _, m := range doc.Messages {
		if m.ID != "" {
			seen[m.ID] = true
		}
		if ts := parseJcodeTime(m.Timestamp); ts.After(lastSent) {
			lastSent = ts
		}
		addJcodeMessage(out, m)
	}
	appendJcodeJournal(out, jcodeJournalPath(path), seen, lastSent)
	return out, nil
}

func appendJcodeJournal(out *transcriptFile, path string, seen map[string]bool, after time.Time) {
	if path == "" {
		return
	}
	f, err := os.Open(path)
	if err != nil {
		return
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 256*1024), 32*1024*1024)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" {
			continue
		}
		var rec struct {
			AppendMessages []jcodeMessage `json:"append_messages"`
		}
		if json.Unmarshal([]byte(line), &rec) != nil {
			continue
		}
		for _, m := range rec.AppendMessages {
			if m.ID != "" && seen[m.ID] {
				continue
			}
			// a compaction rewrites the checkpoint; journal rows older than its
			// tail are already folded in and must not resurface
			if ts := parseJcodeTime(m.Timestamp); !ts.IsZero() && !after.IsZero() && !ts.After(after) {
				continue
			}
			if m.ID != "" {
				seen[m.ID] = true
			}
			addJcodeMessage(out, m)
		}
	}
}

func addJcodeMessage(out *transcriptFile, m jcodeMessage) {
	for i, b := range m.Content {
		base := m.ID
		if base == "" {
			base = "line"
		}
		id := base + ":" + strconv.Itoa(i)
		sentAt := m.Timestamp
		if sentAt == "" {
			sentAt = time.Now().UTC().Format(time.RFC3339)
		}
		switch b.Type {
		case "text":
			text := strings.TrimSpace(b.Text)
			if text == "" || strings.HasPrefix(text, "<system-reminder") || m.Role == "system" {
				continue
			}
			addEntry(out, TranscriptEntry{
				ID: id, Role: m.Role, Kind: "message", Text: text, SentAt: sentAt,
			})
		case "reasoning":
			if strings.TrimSpace(b.Text) == "" {
				continue
			}
			addEntry(out, TranscriptEntry{
				ID: id, Role: m.Role, Kind: "reasoning", Text: b.Text, SentAt: sentAt,
			})
			out.trajectory = append(out.trajectory, map[string]any{
				"reasoning_content": b.Text,
				"message":           "",
				"sent_at":           sentAt,
			})
		case "tool_use":
			addEntry(out, TranscriptEntry{
				ID: id, Role: "assistant", Kind: "tool_call",
				Text: string(b.Input), ToolName: b.Name, SentAt: sentAt,
			})
		case "tool_result":
			// jcode keeps the payload in content (a string), not in input
			text, ok := parseStringOrBlocks(b.Content)
			if !ok {
				text = b.Text
			}
			addEntry(out, TranscriptEntry{
				ID: id, Role: "tool", Kind: "tool_result", Text: text,
				IsError: b.IsError, SentAt: sentAt,
			})
		}
	}
}

func parseStringOrBlocks(raw json.RawMessage) (string, bool) {
	if len(raw) == 0 || string(raw) == "null" {
		return "", false
	}
	var s string
	if json.Unmarshal(raw, &s) == nil {
		return s, true
	}
	var blocks []struct {
		Type string `json:"type"`
		Text string `json:"text"`
	}
	if json.Unmarshal(raw, &blocks) == nil {
		var parts []string
		for _, b := range blocks {
			if b.Text != "" {
				parts = append(parts, b.Text)
			}
		}
		return strings.Join(parts, "\n"), len(parts) > 0
	}
	return string(raw), true
}
