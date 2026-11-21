package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
)

// resolveCodexSession finds the JSONL transcript for a Codex session ID.
// Codex home is $CODEX_HOME or ~/.codex; transcripts live under
// sessions/ and archived_sessions/ as <timestamp>-<uuid>.jsonl. Returns ""
// (no error) when nothing matches. Positive results are cached per
// codex-home + id.
var (
	codexIDRe    = regexp.MustCompile(`^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$`)
	codexSession = sync.Map{} // key: codexHome + "\x00" + id -> path
)

func codexHome() string {
	if v := strings.TrimSpace(os.Getenv("CODEX_HOME")); v != "" {
		if v == "~" {
			if home, err := os.UserHomeDir(); err == nil {
				return home
			}
			return v
		}
		if strings.HasPrefix(v, "~/") {
			if home, err := os.UserHomeDir(); err == nil {
				return filepath.Join(home, v[2:])
			}
		}
		return v
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	return filepath.Join(home, ".codex")
}

func resolveCodexSession(id, cwd string) (string, error) {
	if !codexIDRe.MatchString(strings.ToLower(strings.TrimSpace(id))) {
		return "", fmt.Errorf("invalid codex session id %q", id)
	}
	home := codexHome()
	if home == "" {
		return "", nil
	}
	cacheKey := home + "\x00" + id
	if v, ok := codexSession.Load(cacheKey); ok {
		return v.(string), nil
	}
	var found string
	for _, dir := range []string{"sessions", "archived_sessions"} {
		root := filepath.Join(home, dir)
		filepath.WalkDir(root, func(path string, d os.DirEntry, err error) error {
			if err != nil || found != "" {
				return nil
			}
			if d.IsDir() || !strings.HasSuffix(path, ".jsonl") {
				return nil
			}
			base := filepath.Base(path)
			if strings.HasSuffix(base, "-"+id+".jsonl") || strings.HasSuffix(base, "-"+strings.ToLower(id)+".jsonl") {
				found = path
			}
			return nil
		})
	}
	if found != "" {
		codexSession.Store(cacheKey, found)
	}
	return found, nil
}

// codexText normalizes a Codex content value: a plain string, or an array of
// {type:text,text} / {type:content} blocks, into newline-joined text.
func codexText(raw any) string {
	switch v := raw.(type) {
	case string:
		return v
	case []any:
		var parts []string
		for _, item := range v {
			if s, ok := item.(string); ok {
				parts = append(parts, s)
				continue
			}
			if m, ok := item.(map[string]any); ok {
				if s, ok := m["text"].(string); ok && s != "" {
					parts = append(parts, s)
					continue
				}
				if s, ok := m["content"].(string); ok && s != "" {
					parts = append(parts, s)
					continue
				}
			}
			if t := textFromContent(item); t != "" {
				parts = append(parts, t)
			}
		}
		return strings.Join(parts, "\n")
	default:
		return textFromContent(raw)
	}
}

// codexToolOutput extracts tool output text, falling back to pretty JSON.
func codexToolOutput(payload map[string]any) string {
	if s, ok := payload["output"].(string); ok && s != "" {
		return s
	}
	if t := codexText(payload["output"]); t != "" {
		return t
	}
	if t := codexText(payload["content"]); t != "" {
		return t
	}
	for _, key := range []string{"output", "content"} {
		if v, ok := payload[key]; ok && v != nil {
			if b, err := json.MarshalIndent(v, "", "  "); err == nil {
				return string(b)
			}
		}
	}
	return ""
}

func codexToolCallID(payload map[string]any, lineNo int) string {
	for _, key := range []string{"call_id", "id"} {
		if s, _ := payload[key].(string); s != "" {
			return s
		}
	}
	return fmt.Sprintf("codex-%d", lineNo)
}

// codexPending is an event_msg message deferred until file end: Codex logs
// both event_msg user/agent messages and response_item messages for the same
// turn, so we only emit the event copy if no response_item message with the
// same role exists anywhere in the file (matching roamgate's pre-scan rule).
type codexPending struct {
	entry TranscriptEntry
	added bool // set once a response_item message of the same role appears
}

// codexParser is stateful per transcript file. newCodexParser must be called
// once per file; the parent wires parseTranscript to create one, call parse
// per record, then flush after the last line. flush emits deferred
// event_msg messages whose role never appeared as a response_item message.
type codexParser struct {
	hasResponseUser      bool
	hasResponseAssistant bool
	pending              []*codexPending
}

func newCodexParser() *codexParser { return &codexParser{} }

// parse handles one decoded JSONL record. Signature matches the other
// per-agent parsers so the parent can dispatch uniformly.
func (p *codexParser) parse(out *transcriptFile, rec map[string]any, lineNo int) {
	typ, _ := rec["type"].(string)
	switch typ {
	case "session_meta":
		payload, _ := rec["payload"].(map[string]any)
		if id, ok := payload["id"].(string); ok && id != "" {
			out.sessionID = id
		} else if id, ok := rec["id"].(string); ok {
			out.sessionID = id
		}
		return
	case "event_msg":
		payload, _ := rec["payload"].(map[string]any)
		if payload == nil {
			return
		}
		ptyp, _ := payload["type"].(string)
		switch ptyp {
		case "user_message", "agent_message":
			text := strings.TrimSpace(codexText(payload["message"]))
			if text == "" {
				return
			}
			role := "user"
			if ptyp == "agent_message" {
				role = "assistant"
			}
			// pre-scan already knows a response_item message of this role
			// exists; the event copy would duplicate it
			if (role == "user" && p.hasResponseUser) || (role == "assistant" && p.hasResponseAssistant) {
				return
			}
			p.pending = append(p.pending, &codexPending{entry: TranscriptEntry{
				Role: role, Kind: "message", Text: text,
				SentAt: recordTime(rec, payload),
			}})
		case "token_count":
			// usage telemetry, not transcript content
		}
		return
	case "response_item":
		// handled below
	default:
		return
	}

	payload, _ := rec["payload"].(map[string]any)
	if payload == nil {
		return
	}
	ptype, _ := payload["type"].(string)
	sentAt := recordTime(rec, payload)

	switch {
	case ptype == "message":
		role, _ := payload["role"].(string)
		text := strings.TrimSpace(codexText(payload["content"]))
		if text == "" {
			return
		}
		outRole := "system"
		switch role {
		case "user":
			outRole = "user"
			p.hasResponseUser = true
			for _, pend := range p.pending {
				if pend.entry.Role == "user" {
					pend.added = true
				}
			}
		case "assistant":
			outRole = "assistant"
			p.hasResponseAssistant = true
			for _, pend := range p.pending {
				if pend.entry.Role == "assistant" {
					pend.added = true
				}
			}
		}
		addEntry(out, TranscriptEntry{
			ID: codexToolCallID(payload, lineNo), Role: outRole, Kind: "message",
			Text: text, SentAt: sentAt,
		})
	case ptype == "reasoning":
		text := strings.TrimSpace(codexText(payload["summary"]))
		if text == "" {
			text = "Reasoning"
		}
		addEntry(out, TranscriptEntry{
			ID: codexToolCallID(payload, lineNo), Role: "assistant", Kind: "reasoning",
			Text: text, SentAt: sentAt,
		})
		out.trajectory = append(out.trajectory, map[string]any{
			"reasoning_content": text,
			"message":           "",
			"sent_at":           sentAt,
		})
	case strings.Contains(ptype, "output") || strings.Contains(ptype, "result"):
		// checked before the call case: function_call_output etc. are results
		text := codexToolOutput(payload)
		isErr := false
		if s, _ := payload["status"].(string); s == "failed" || s == "error" {
			isErr = true
		}
		if b, ok := payload["is_error"].(bool); ok {
			isErr = isErr || b
		}
		addEntry(out, TranscriptEntry{
			ID: codexToolCallID(payload, lineNo), Role: "tool", Kind: "tool_result",
			Text: text, IsError: isErr, SentAt: sentAt,
		})
	case strings.Contains(ptype, "tool_call") || strings.Contains(ptype, "function_call"):
		name := firstNonEmpty(
			stringField(payload, "name"),
			stringField(payload, "call_name"),
			stringField(payload, "function_name"),
			ptype,
		)
		var text string
		if args, ok := payload["arguments"].(string); ok {
			text = args
		} else if args := payload["arguments"]; args != nil {
			b, _ := json.Marshal(args)
			text = string(b)
		} else if input, ok := payload["input"].(string); ok {
			text = input
		} else if input := payload["input"]; input != nil {
			b, _ := json.Marshal(input)
			text = string(b)
		}
		addEntry(out, TranscriptEntry{
			ID: codexToolCallID(payload, lineNo), Role: "assistant", Kind: "tool_call",
			Text: text, ToolName: name, SentAt: sentAt,
		})
	case strings.Contains(ptype, "tool"):
		text := codexToolOutput(payload)
		isErr := false
		if s, _ := payload["status"].(string); s == "failed" || s == "error" {
			isErr = true
		}
		if b, ok := payload["is_error"].(bool); ok {
			isErr = isErr || b
		}
		addEntry(out, TranscriptEntry{
			ID: codexToolCallID(payload, lineNo), Role: "tool", Kind: "tool_result",
			Text: text, IsError: isErr, SentAt: sentAt,
		})
	}
}

// flush emits deferred event_msg messages that were never superseded by a
// response_item message of the same role. Call once after the last record.
func (p *codexParser) flush(out *transcriptFile) {
	for _, pend := range p.pending {
		if !pend.added {
			e := pend.entry
			addEntry(out, e)
		}
	}
	p.pending = nil
}

// parseCodexRecord is the stateless entry point for callers that process one
// record at a time. It cannot dedup event_msg against response_item messages
// later in the file; prefer newCodexParser().parse + flush per file.
func parseCodexRecord(out *transcriptFile, rec map[string]any, lineNo int) {
	p := newCodexParser()
	p.parse(out, rec, lineNo)
	p.flush(out)
}

func stringField(m map[string]any, key string) string {

	s, _ := m[key].(string)
	return s
}

// codexScanRec is the minimal record shape needed for the dedup pre-scan.
type codexScanRec struct {
	Type    string `json:"type"`
	Payload struct {
		Type string `json:"type"`
		Role string `json:"role"`
	} `json:"payload"`
}

// parseCodexTranscript is the file-level entry point wired into
// parseTranscript. Pass 1 pre-scans for response_item messages so
// event_msg user/agent copies are only emitted when no response_item
// message with the same role exists anywhere in the file (roamgate's
// dedup rule); pass 2 runs the stateful parser over every line.
func parseCodexTranscript(f *os.File, out *transcriptFile) (*transcriptFile, error) {
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 256*1024), 32*1024*1024)
	var hasUser, hasAssistant bool
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" {
			continue
		}
		var rec codexScanRec
		if json.Unmarshal([]byte(line), &rec) != nil {
			continue
		}
		if rec.Type != "response_item" || rec.Payload.Type != "message" {
			continue
		}
		switch rec.Payload.Role {
		case "user":
			hasUser = true
		case "assistant":
			hasAssistant = true
		}
	}
	if _, err := f.Seek(0, 0); err != nil {
		return nil, err
	}
	p := newCodexParser()
	p.hasResponseUser = hasUser
	p.hasResponseAssistant = hasAssistant
	sc = bufio.NewScanner(f)
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
		p.parse(out, rec, lineNo)
	}
	if err := sc.Err(); err != nil {
		return nil, err
	}
	p.flush(out)
	if len(out.entries) > 1500 {
		out.entries = out.entries[len(out.entries)-1500:]
	}
	return out, nil
}
