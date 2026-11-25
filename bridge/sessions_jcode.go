package main

import (
	"bufio"
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

func parseJcodeTranscript(f *os.File, out *transcriptFile) (*transcriptFile, error) {
	var doc struct {
		ID       string `json:"id"`
		Messages []struct {
			ID        string `json:"id"`
			Role      string `json:"role"`
			Timestamp string `json:"timestamp"`
			Content   []struct {
				Type    string          `json:"type"`
				Text    string          `json:"text"`
				Name    string          `json:"name"`
				ID      string          `json:"id"`
				Input   json.RawMessage `json:"input"`
				IsError bool            `json:"is_error"`
			} `json:"content"`
		} `json:"messages"`
	}
	if err := json.NewDecoder(bufio.NewReader(f)).Decode(&doc); err != nil {
		return nil, err
	}
	out.sessionID = doc.ID
	if out.full == nil {
		out.full = make(map[string]string)
	}
	for _, m := range doc.Messages {
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
				if text == "" || strings.HasPrefix(text, "<system-reminder") {
					continue
				}
				kind := "message"
				role := m.Role
				if role == "system" {
					continue
				}
				addEntry(out, TranscriptEntry{
					ID: id, Role: role, Kind: kind, Text: text, SentAt: sentAt,
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
				text := b.Text
				if content, ok := parseStringOrBlocks(b.Input); ok {
					text = content
				}
				addEntry(out, TranscriptEntry{
					ID: id, Role: "tool", Kind: "tool_result", Text: text,
					IsError: b.IsError, SentAt: sentAt,
				})
			}
		}
	}
	return out, nil
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
