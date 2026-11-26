package main

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"
)

type Transcripts struct {
	mu    sync.Mutex
	files map[string]*transcriptFile
}

type transcriptFile struct {
	modTime    time.Time
	size       int64
	entries    []map[string]any
	full       map[string]string
	trajectory []map[string]any
	sessionID  string
}

type TranscriptEntry struct {
	ID       string
	Role     string
	Kind     string
	Text     string
	ToolName string
	IsError  bool
	SentAt   string
}

func NewTranscripts() *Transcripts {
	return &Transcripts{files: make(map[string]*transcriptFile)}
}

func (t *Transcripts) sessionPath(ctx context.Context, s *Server, p map[string]any) (string, string, error) {
	snap, err := s.snapshot(ctx)
	if err != nil {
		return "", "", err
	}
	pane := snap.PaneByTerminal(asString(p, "terminal_id"))
	if pane == nil {
		pane = snap.Pane(asString(p, "pane_id"))
	}
	if pane == nil {
		return "", "", errors.New("pane not found")
	}
	agent := snap.AgentForPane(pane.PaneID)
	if agent == nil {
		return "", "", errors.New("this pane has no agent session")
	}
	name := normalizeAgentName(firstNonEmpty(agent.AgentSession.Agent, agent.Agent))
	ref := agent.AgentSession
	// kind="path": the hook reported a filesystem path directly
	if ref.Kind == "path" && ref.Value != "" {
		if _, err := os.Stat(ref.Value); err == nil {
			return ref.Value, name, nil
		}
	}
	// kind="id" (or legacy reports): resolve the session id to a file
	if ref.Value != "" {
		cwd := firstNonEmpty(agent.ForegroundCwd, agent.Cwd)
		if path := resolveSessionFile(name, ref.Value, cwd); path != "" {
			return path, name, nil
		}
	}
	// jcode's herdr hook reports no session ref, so derive it from the cwd
	if name == "jcode" {
		cwd := firstNonEmpty(agent.ForegroundCwd, agent.Cwd)
		if id := firstNonEmpty(ref.Value, jcodePaneSessionID(ctx, s, pane.PaneID)); id != "" {
			if path := jcodeSessionPath(id); path != "" {
				return path, name, nil
			}
		}
		if path := recentJcodeSession(cwd); path != "" {
			return path, name, nil
		}
		return "", name, errors.New("no jcode session found for this workspace")
	}
	// fallback: treat the value as a path (older herdr without kind)
	path := ref.Value
	if path == "" {
		return "", name, errors.New("the agent has no session file yet")
	}
	if _, err := os.Stat(path); err != nil {
		return "", name, fmt.Errorf("session file is unavailable: %w", err)
	}
	return path, name, nil
}

func (t *Transcripts) load(ctx context.Context, s *Server, p map[string]any) (*transcriptFile, error) {
	path, agent, err := t.sessionPath(ctx, s, p)
	if err != nil {
		return nil, err
	}
	st, err := os.Stat(path)
	if err != nil {
		return nil, err
	}
	// the jcode checkpoint lags its journal, so both decide freshness
	size, modTime := st.Size(), st.ModTime()
	if journal := jcodeJournalPath(path); journal != "" {
		if jst, jerr := os.Stat(journal); jerr == nil {
			size += jst.Size()
			if jst.ModTime().After(modTime) {
				modTime = jst.ModTime()
			}
		}
	}
	t.mu.Lock()
	cached := t.files[path]
	t.mu.Unlock()
	if cached != nil && cached.size == size && cached.modTime.Equal(modTime) {
		return cached, nil
	}
	parsed, err := parseTranscript(path, agent)
	if err != nil {
		return nil, err
	}
	parsed.size = size
	parsed.modTime = modTime
	t.mu.Lock()
	t.files[path] = parsed
	t.mu.Unlock()
	return parsed, nil
}

func (t *Transcripts) Get(ctx context.Context, s *Server, p map[string]any) (any, error) {
	f, err := t.load(ctx, s, p)
	if err != nil {
		return map[string]any{"entries": []any{}, "agent": "", "note": err.Error()}, nil
	}
	version := asInt(p, "history_version", 2)
	// reasoning rides agent_session.get's trajectory, not the transcript
	entries := make([]map[string]any, 0, len(f.entries))
	for _, e := range f.entries {
		if e["kind"] == "reasoning" {
			continue
		}
		if version < 2 && e["kind"] != "message" {
			continue
		}
		entries = append(entries, e)
	}
	return map[string]any{"entries": entries, "history_version": version}, nil
}

func (t *Transcripts) Entry(ctx context.Context, s *Server, p map[string]any) (any, error) {
	f, err := t.load(ctx, s, p)
	if err != nil {
		return nil, err
	}
	id := asString(p, "entry_id")
	text, ok := f.full[id]
	if !ok {
		return nil, errors.New("history entry is no longer available")
	}
	return map[string]any{"text": text}, nil
}

func (t *Transcripts) Session(ctx context.Context, s *Server, p map[string]any) (any, error) {
	f, err := t.load(ctx, s, p)
	if err != nil {
		return map[string]any{"trajectory": map[string]any{"steps": []any{}}}, nil
	}
	steps := f.trajectory
	if !asBool(p, "include_trajectory") {
		steps = nil
	}
	return map[string]any{
		"trajectory": map[string]any{"steps": steps},
		"session_id": f.sessionID,
	}, nil
}

func parseTranscript(path, agent string) (*transcriptFile, error) {
	name := normalizeAgentName(agent)
	if name == "jcode" {
		return parseJcodeTranscript(path, &transcriptFile{full: make(map[string]string)})
	}
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	out := &transcriptFile{full: make(map[string]string)}
	if name == "codex" {
		// codex needs a pre-scan for event_msg/response_item dedup;
		// handled by a dedicated two-pass parser
		return parseCodexTranscript(f, out)
	}
	parse := recordParserFor(name)
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 256*1024), 32*1024*1024)
	lineNo := 0
	for sc.Scan() {
		lineNo++
		line := strings.TrimSpace(sc.Text())
		if line == "" {
			continue
		}
		var rec map[string]any
		if json.Unmarshal([]byte(line), &rec) != nil {
			continue
		}
		parse(out, rec, lineNo)
	}
	if err := sc.Err(); err != nil {
		return nil, err
	}
	if len(out.entries) > 1500 {
		out.entries = out.entries[len(out.entries)-1500:]
	}
	return out, nil
}

// recordParserFor returns the per-record parser for a canonical agent name.
// Unknown agents fall back to a heuristic: records with a "message" key look
// like claude, everything else like omp/pi.
func recordParserFor(name string) func(out *transcriptFile, rec map[string]any, lineNo int) {
	switch name {
	case "omp", "pi":
		return parseOMPRecord
	case "claude":
		return parseClaudeRecord
	case "grok":
		return parseGrokRecord
	case "kimi":
		return parseKimiRecord
	default:
		return func(out *transcriptFile, rec map[string]any, lineNo int) {
			if _, ok := rec["message"]; ok {
				parseClaudeRecord(out, rec, lineNo)
			} else {
				parseOMPRecord(out, rec, lineNo)
			}
		}
	}
}

func textFromContent(raw any) string {
	list, _ := raw.([]any)
	var parts []string
	for _, block := range list {
		b, _ := block.(map[string]any)
		if b == nil {
			continue
		}
		switch b["type"] {
		case "text":
			if s, ok := b["text"].(string); ok {
				parts = append(parts, s)
			}
		case "output_text", "input_text":
			if s, ok := b["text"].(string); ok {
				parts = append(parts, s)
			}
		}
	}
	return strings.Join(parts, "\n")
}

func recordTime(rec map[string]any, msg map[string]any) string {
	for _, source := range []map[string]any{msg, rec} {
		for _, key := range []string{"sent_at", "timestamp", "time"} {
			switch v := source[key].(type) {
			case string:
				if v != "" {
					if t, err := time.Parse(time.RFC3339Nano, v); err == nil {
						return t.UTC().Format(time.RFC3339)
					}
					if n, err := strconv.ParseInt(v, 10, 64); err == nil {
						return milliTime(n)
					}
					return v
				}
			case float64:
				return milliTime(int64(v))
			case json.Number:
				n, _ := v.Int64()
				return milliTime(n)
			}
		}
	}
	return time.Now().UTC().Format(time.RFC3339)
}

func milliTime(n int64) string {
	if n > 1e12 {
		return time.UnixMilli(n).UTC().Format(time.RFC3339)
	}
	return time.Unix(n, 0).UTC().Format(time.RFC3339)
}

func addEntry(out *transcriptFile, e TranscriptEntry) {
	if e.ID == "" {
		e.ID = fmt.Sprintf("%s-%d", e.Kind, len(out.entries))
	}
	if e.SentAt == "" {
		e.SentAt = time.Now().UTC().Format(time.RFC3339)
	}
	full := e.Text
	limit := 12000
	switch e.Kind {
	case "tool_result":
		limit = 4000
	case "tool_call":
		limit = 8000
	case "reasoning":
		limit = 12000
	}
	display := full
	if len(display) > limit {
		display = display[:limit]
	}
	out.full[e.ID] = full
	entry := map[string]any{
		"id":         e.ID,
		"role":       e.Role,
		"kind":       e.Kind,
		"text":       display,
		"text_bytes": len(full),
		"sent_at":    e.SentAt,
	}
	if e.ToolName != "" {
		entry["tool_name"] = e.ToolName
	}
	if e.IsError {
		entry["is_error"] = true
	}
	out.entries = append(out.entries, entry)
}

func parseOMPRecord(out *transcriptFile, rec map[string]any, lineNo int) {
	typ, _ := rec["type"].(string)
	if typ == "session" {
		if id, ok := rec["id"].(string); ok {
			out.sessionID = id
		}
		return
	}
	if typ != "message" {
		return
	}
	msg, _ := rec["message"].(map[string]any)
	if msg == nil {
		return
	}
	role, _ := msg["role"].(string)
	msgID, _ := msg["id"].(string)
	if msgID == "" {
		msgID = fmt.Sprintf("line-%d", lineNo)
	}
	sentAt := recordTime(rec, msg)
	content, _ := msg["content"].([]any)
	if role == "toolResult" || role == "tool_result" {
		text := textFromContent(content)
		toolName, _ := msg["toolName"].(string)
		if toolName == "" {
			toolName, _ = msg["tool_name"].(string)
		}
		isErr, _ := msg["isError"].(bool)
		addEntry(out, TranscriptEntry{
			ID: msgID, Role: "tool", Kind: "tool_result", Text: text,
			ToolName: toolName, IsError: isErr, SentAt: sentAt,
		})
		return
	}
	for i, raw := range content {
		block, _ := raw.(map[string]any)
		if block == nil {
			continue
		}
		btype, _ := block["type"].(string)
		switch btype {
		case "text":
			text, _ := block["text"].(string)
			if strings.TrimSpace(text) == "" {
				continue
			}
			addEntry(out, TranscriptEntry{
				ID: fmt.Sprintf("%s:%d", msgID, i), Role: role, Kind: "message",
				Text: text, SentAt: sentAt,
			})
		case "thinking":
			text, _ := block["thinking"].(string)
			if strings.TrimSpace(text) == "" {
				continue
			}
			addEntry(out, TranscriptEntry{
				ID: fmt.Sprintf("%s:%d", msgID, i), Role: role, Kind: "reasoning",
				Text: text, SentAt: sentAt,
			})
			out.trajectory = append(out.trajectory, map[string]any{
				"reasoning_content": text,
				"message":           "",
				"sent_at":           sentAt,
			})
		case "toolCall", "tool_use":
			name, _ := block["name"].(string)
			args := block["arguments"]
			if args == nil {
				args = block["input"]
			}
			var text string
			switch v := args.(type) {
			case string:
				text = v
			default:
				b, _ := json.Marshal(v)
				text = string(b)
			}
			id, _ := block["id"].(string)
			if id == "" {
				id = fmt.Sprintf("%s:%d", msgID, i)
			}
			addEntry(out, TranscriptEntry{
				ID: id, Role: "assistant", Kind: "tool_call", Text: text,
				ToolName: name, SentAt: sentAt,
			})
			if len(out.trajectory) > 0 {
				last := out.trajectory[len(out.trajectory)-1]
				if last["message"] == "" {
					last["message"] = fmt.Sprintf("Calling %s", name)
				}
			}
		}
	}
}

func parseClaudeRecord(out *transcriptFile, rec map[string]any, lineNo int) {
	// capture the claude session id for agent_session.get (present on every record)
	if out.sessionID == "" {
		if sid, ok := rec["sessionId"].(string); ok && sid != "" {
			out.sessionID = sid
		}
	}
	typ, _ := rec["type"].(string)
	if typ != "user" && typ != "assistant" {
		return
	}
	msg, _ := rec["message"].(map[string]any)
	if msg == nil {
		msg = rec
	}
	role, _ := msg["role"].(string)
	if role == "" {
		role = typ
	}
	id, _ := rec["uuid"].(string)
	if id == "" {
		id = fmt.Sprintf("claude-%d", lineNo)
	}
	sentAt := recordTime(rec, msg)
	content, _ := msg["content"].([]any)
	for i, raw := range content {
		block, _ := raw.(map[string]any)
		if block == nil {
			continue
		}
		btype, _ := block["type"].(string)
		switch btype {
		case "text":
			text, _ := block["text"].(string)
			if strings.TrimSpace(text) != "" {
				addEntry(out, TranscriptEntry{
					ID: fmt.Sprintf("%s:%d", id, i), Role: role, Kind: "message",
					Text: text, SentAt: sentAt,
				})
			}
		case "thinking":
			text, _ := block["thinking"].(string)
			if strings.TrimSpace(text) == "" {
				continue
			}
			addEntry(out, TranscriptEntry{
				ID: fmt.Sprintf("%s:%d", id, i), Role: role, Kind: "reasoning",
				Text: text, SentAt: sentAt,
			})
			out.trajectory = append(out.trajectory, map[string]any{
				"reasoning_content": text, "message": "", "sent_at": sentAt,
			})
		case "tool_use":
			name, _ := block["name"].(string)
			b, _ := json.Marshal(block["input"])
			callID, _ := block["id"].(string)
			if callID == "" {
				callID = fmt.Sprintf("%s:%d", id, i)
			}
			addEntry(out, TranscriptEntry{
				ID: callID, Role: "assistant", Kind: "tool_call", Text: string(b),
				ToolName: name, SentAt: sentAt,
			})
		case "tool_result":
			text := textFromContent(block["content"])
			isErr, _ := block["is_error"].(bool)
			toolID, _ := block["tool_use_id"].(string)
			addEntry(out, TranscriptEntry{
				ID:   fmt.Sprintf("%s:r%d", firstNonEmpty(toolID, id), i),
				Role: "tool", Kind: "tool_result", Text: text, IsError: isErr,
				SentAt: sentAt,
			})
		}
	}
}

func firstNonEmpty(values ...string) string {
	for _, v := range values {
		if v != "" {
			return v
		}
	}
	return ""
}
