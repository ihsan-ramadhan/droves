package main

import (
	"encoding/json"
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
)

// grokSessionCache memoizes positive id→path lookups; keys embed
// root|cwd|id so env overrides and cwd variants stay distinct.
var grokSessionCache sync.Map

// grokHome mirrors grok-session.ts: $GROK_HOME wins (with ~ expansion),
// otherwise ~/.grok.
func grokHome() string {
	dir := strings.TrimSpace(os.Getenv("GROK_HOME"))
	if dir == "" {
		home, _ := os.UserHomeDir()
		return filepath.Join(home, ".grok")
	}
	if dir == "~" {
		home, _ := os.UserHomeDir()
		return home
	}
	if strings.HasPrefix(dir, "~/") {
		home, _ := os.UserHomeDir()
		return filepath.Join(home, dir[2:])
	}
	return dir
}

func grokSessionsRoot() string {
	return filepath.Join(grokHome(), "sessions")
}

// resolveGrokSession maps a herdr-reported grok session id to
// <root>/<enc(cwd)>/<id>/chat_history.jsonl. With an empty cwd it falls back
// to scanning every cwd directory for the id. Returns "" (nil error) when the
// session cannot be found. Both chat_history.jsonl and summary.json must
// exist, matching describeSessionDirectory in roamgate.
func resolveGrokSession(id, cwd string) (string, error) {
	if !validSessionID(id) {
		return "", nil
	}
	root := grokSessionsRoot()
	key := "grok|" + root + "|" + cwd + "|" + id
	if p, ok := grokSessionCache.Load(key); ok {
		return p.(string), nil
	}
	candidate := func(dir string) string {
		transcript := filepath.Join(dir, "chat_history.jsonl")
		if st, err := os.Stat(transcript); err != nil || st.IsDir() {
			return ""
		}
		if _, err := os.Stat(filepath.Join(dir, "summary.json")); err != nil {
			return ""
		}
		return transcript
	}
	var found string
	if cwd != "" {
		abs, err := filepath.Abs(cwd)
		if err == nil {
			cwd = abs
		}
		// url.PathEscape approximates JS encodeURIComponent; it differs on
		// '+', '(', ')', '!', "'", '*' and '~', which PathEscape leaves or
		// escapes differently. Grok cwd dirs are percent-encoded, so typical
		// paths match.
		enc := url.PathEscape(cwd)
		found = candidate(filepath.Join(root, enc, id))
	}
	if found == "" {
		entries, err := os.ReadDir(root)
		if err != nil {
			return "", nil
		}
		for _, e := range entries {
			if !e.IsDir() {
				continue
			}
			if p := candidate(filepath.Join(root, e.Name(), id)); p != "" {
				found = p
				break
			}
		}
	}
	if found != "" {
		grokSessionCache.Store(key, found)
	}
	return found, nil
}

var (
	grokQueryRe    = regexp.MustCompile(`(?is)<user_query>\s*(.*?)\s*</user_query>`)
	grokInfoRe     = regexp.MustCompile(`(?is)<user_info>[\s\S]*?</user_info>`)
	grokGitRe      = regexp.MustCompile(`(?is)<git_status>[\s\S]*?</git_status>`)
	grokReminderRe = regexp.MustCompile(`(?is)<system-reminder>[\s\S]*?</system-reminder>`)
	grokCmdRe      = regexp.MustCompile(`(?is)<command-(?:message|name|stdout)>[\s\S]*?</command-(?:message|name|stdout)>`)
	grokTaskRe     = regexp.MustCompile(`(?is)<task-notification>[\s\S]*?</task-notification>`)
)

// grokCleanText ports cleanMessageText: strips injected tags and normalizes
// whitespace that Grok prepends to user turns.
func grokCleanText(s string) string {
	s = grokCmdRe.ReplaceAllString(s, "")
	s = grokTaskRe.ReplaceAllString(s, "")
	s = grokReminderRe.ReplaceAllString(s, "")
	s = strings.ReplaceAll(s, "\r\n", "\n")
	return strings.TrimSpace(s)
}

// grokUserText ports grokUserMessageText: only <user_query> content is real
// history; otherwise strip env-snapshot tags. Returns "" for synthetic
// records (synthetic_reason set).
func grokUserText(rec map[string]any) string {
	if reason, _ := rec["synthetic_reason"].(string); reason != "" {
		return ""
	}
	content := grokContentText(rec["content"])
	matches := grokQueryRe.FindAllStringSubmatch(content, -1)
	if len(matches) > 0 {
		var queries []string
		for _, m := range matches {
			if q := grokCleanText(m[1]); q != "" {
				queries = append(queries, q)
			}
		}
		return strings.Join(queries, "\n\n")
	}
	text := grokInfoRe.ReplaceAllString(content, "")
	text = grokGitRe.ReplaceAllString(text, "")
	text = grokReminderRe.ReplaceAllString(text, "")
	return grokCleanText(text)
}

// grokReasoningText ports grokReasoningText: summary parts first, then content.
// Grok emits summary entries as {type:"summary_text", text:...} blocks, which
// textFromContent does not know, so they are extracted here.
func grokReasoningText(rec map[string]any) string {
	raw, ok := rec["summary"]
	if !ok || raw == nil {
		raw = rec["content"]
	}
	if s, isStr := raw.(string); isStr {
		return grokCleanText(s)
	}
	if parts, isList := raw.([]any); isList {
		var texts []string
		for _, item := range parts {
			m, _ := item.(map[string]any)
			if m == nil {
				continue
			}
			typ, _ := m["type"].(string)
			if typ != "summary_text" && typ != "text" {
				continue
			}
			if s, ok := m["text"].(string); ok && strings.TrimSpace(s) != "" {
				texts = append(texts, s)
			}
		}
		if len(texts) > 0 {
			return grokCleanText(strings.Join(texts, "\n"))
		}
	}
	text := textFromContent(raw)
	if text == "" && raw != nil {
		if b, err := json.Marshal(raw); err == nil {
			text = string(b)
		}
	}
	return grokCleanText(text)
}

// grokContentText handles Grok's content field, which is a bare string or an
// array of typed parts; textFromContent only knows the array form.
func grokContentText(raw any) string {
	if s, ok := raw.(string); ok {
		return s
	}
	return textFromContent(raw)
}

// grokToolOutputText ports toolOutputText: string, text parts, else JSON.
func grokToolOutputText(raw any) string {
	if s, ok := raw.(string); ok {
		return s
	}
	if text := textFromContent(raw); text != "" {
		return text
	}
	if raw == nil {
		return ""
	}
	if b, err := json.Marshal(raw); err == nil {
		return string(b)
	}
	return ""
}

// grokToolResultError ports toolResultExtra's is_error detection.
func grokToolResultError(rec map[string]any) bool {
	if b, _ := rec["is_error"].(bool); b {
		return true
	}
	if b, _ := rec["isError"].(bool); b {
		return true
	}
	switch s, _ := rec["status"].(string); s {
	case "error", "failed":
		return true
	}
	return false
}

// parseGrokRecord normalizes one chat_history.jsonl record. Record types:
// user | system | reasoning | assistant | tool_result. Synthetic user
// records (synthetic_reason) are injected context and are skipped.
func parseGrokRecord(out *transcriptFile, rec map[string]any, lineNo int) {
	typ, _ := rec["type"].(string)
	switch typ {
	case "user":
		text := grokUserText(rec)
		if text == "" {
			return
		}
		id, _ := rec["id"].(string)
		if id == "" {
			id = fmt.Sprintf("grok-%d", lineNo)
		}
		addEntry(out, TranscriptEntry{
			ID: id, Role: "user", Kind: "message", Text: text,
			SentAt: recordTime(rec, nil),
		})
	case "system":
		text := grokCleanText(grokContentText(rec["content"]))
		if text == "" {
			return
		}
		id, _ := rec["id"].(string)
		if id == "" {
			id = fmt.Sprintf("grok-%d", lineNo)
		}
		addEntry(out, TranscriptEntry{
			ID: id, Role: "system", Kind: "message", Text: text,
			SentAt: recordTime(rec, nil),
		})
	case "reasoning":
		text := grokReasoningText(rec)
		if text == "" {
			return
		}
		id, _ := rec["id"].(string)
		if id == "" {
			id = fmt.Sprintf("grok-%d", lineNo)
		}
		sentAt := recordTime(rec, nil)
		addEntry(out, TranscriptEntry{
			ID: id, Role: "assistant", Kind: "reasoning", Text: text,
			SentAt: sentAt,
		})
		out.trajectory = append(out.trajectory, map[string]any{
			"reasoning_content": text,
			"message":           "",
			"sent_at":           sentAt,
		})
	case "assistant":
		id, _ := rec["id"].(string)
		if id == "" {
			id = fmt.Sprintf("grok-%d", lineNo)
		}
		sentAt := recordTime(rec, nil)
		if text := grokCleanText(grokContentText(rec["content"])); text != "" {
			addEntry(out, TranscriptEntry{
				ID: id + ":text", Role: "assistant", Kind: "message",
				Text: text, SentAt: sentAt,
			})
		}
		calls, _ := rec["tool_calls"].([]any)
		for i, raw := range calls {
			call, _ := raw.(map[string]any)
			if call == nil {
				continue
			}
			name, _ := call["name"].(string)
			callID, _ := call["id"].(string)
			if callID == "" {
				callID = fmt.Sprintf("%s:call%d", id, i)
			}
			var text string
			switch v := call["arguments"].(type) {
			case string:
				text = v
			default:
				b, _ := json.Marshal(v)
				text = string(b)
			}
			addEntry(out, TranscriptEntry{
				ID: callID, Role: "assistant", Kind: "tool_call",
				Text: text, ToolName: name, SentAt: sentAt,
			})
		}
	case "tool_result":
		text := grokToolOutputText(rec["content"])
		if text == "" {
			text = grokToolOutputText(rec["output"])
		}
		if text == "" {
			text = "Tool result"
		}
		callID, _ := rec["tool_call_id"].(string)
		if callID == "" {
			callID, _ = rec["tool_use_id"].(string)
		}
		id, _ := rec["id"].(string)
		entryID := callID
		if entryID == "" {
			entryID = firstNonEmpty(id, fmt.Sprintf("grok-%d", lineNo))
		}
		toolName, _ := rec["tool_name"].(string)
		if toolName == "" {
			toolName, _ = rec["name"].(string)
		}
		addEntry(out, TranscriptEntry{
			ID: entryID, Role: "tool", Kind: "tool_result", Text: text,
			ToolName: toolName, IsError: grokToolResultError(rec),
			SentAt: recordTime(rec, nil),
		})
	}
}
