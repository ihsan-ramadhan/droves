package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync"
)

// kimiSessionCache memoizes positive id→path lookups keyed by
// root|id; kimi session files are immutable once written.
var kimiSessionCache sync.Map

// kimiSessionsRoot mirrors roamgate's findKimiSession: transcripts live
// under ~/.kimi-code/sessions/<id>/agents/main/wire.jsonl. Roamgate honors
// no dedicated env override for kimi, only $HOME.
func kimiSessionsRoot() string {
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	return filepath.Join(home, ".kimi-code", "sessions")
}

// resolveKimiSession maps a herdr-reported kimi session id to
// <root>/<id>/agents/main/wire.jsonl. Returns "" (nil error) when the id is
// invalid or no matching file exists. Positive results are cached per
// root + id.
func resolveKimiSession(id, cwd string) (string, error) {
	if !validSessionID(id) {
		return "", nil
	}
	root := kimiSessionsRoot()
	if root == "" {
		return "", nil
	}
	cacheKey := root + "|" + id
	if p, ok := kimiSessionCache.Load(cacheKey); ok {
		return p.(string), nil
	}
	suffix := "/" + id + "/agents/main/wire.jsonl"
	var found string
	files, err := sortedJSONLFiles(root)
	if err != nil {
		return "", err
	}
	for _, path := range files {
		// sortedJSONLFiles returns newest first; first match wins.
		if strings.HasSuffix(strings.ReplaceAll(path, "\\", "/"), suffix) {
			found = path
			break
		}
	}
	if found != "" {
		kimiSessionCache.Store(cacheKey, found)
	}
	return found, nil
}

// kimiTagPatterns mirror cleanMessageText in roamgate's session-utils.ts:
// wrapper tags Claude Code / kimi inject around injected context are not
// part of the user's words.
var kimiTagPatterns = []*regexp.Regexp{
	regexp.MustCompile(`<command-message>[\s\S]*?</command-message>`),
	regexp.MustCompile(`<command-name>[\s\S]*?</command-name>`),
	regexp.MustCompile(`<local-command-stdout>[\s\S]*?</local-command-stdout>`),
	regexp.MustCompile(`<task-notification>[\s\S]*?</task-notification>`),
	regexp.MustCompile(`<system-reminder>[\s\S]*?</system-reminder>`),
}

func kimiCleanText(value string) string {
	text := strings.ReplaceAll(value, "\r\n", "\n")
	for _, re := range kimiTagPatterns {
		text = re.ReplaceAllString(text, "")
	}
	text = strings.TrimSpace(text)
	if text == "[Request interrupted by user]" {
		return ""
	}
	return text
}

// kimiContentText handles message.content as a plain string or an array of
// content blocks (matching roamgate's textFromContent, which accepts both).
func kimiContentText(raw any) string {
	if s, ok := raw.(string); ok {
		return s
	}
	return textFromContent(raw)
}

// kimiToolOutput mirrors roamgate's toolOutputText: string output passes
// through, arrays become newline-joined text, anything else pretty-prints.
func kimiToolOutput(raw any) string {
	if s, ok := raw.(string); ok {
		return s
	}
	if t := textFromContent(raw); t != "" {
		return t
	}
	if raw == nil {
		return ""
	}
	if b, err := json.MarshalIndent(raw, "", "  "); err == nil {
		return string(b)
	}
	return ""
}

// kimiArgsText serializes tool.call args: strings pass through, other
// values marshal to JSON (matching parseOMPRecord/parseClaudeRecord).
func kimiArgsText(raw any) string {
	switch v := raw.(type) {
	case nil:
		return ""
	case string:
		return v
	default:
		b, _ := json.Marshal(v)
		return string(b)
	}
}

// kimiTimestamp resolves the record timestamp: created_at is in
// milliseconds for kimi wire records; fall back to recordTime's keys.
func kimiTimestamp(rec map[string]any) string {
	switch v := rec["created_at"].(type) {
	case float64:
		if v > 0 {
			return milliTime(int64(v))
		}
	case int:
		if v > 0 {
			return milliTime(int64(v))
		}
	case int64:
		if v > 0 {
			return milliTime(v)
		}
	case json.Number:
		if n, err := v.Int64(); err == nil && n > 0 {
			return milliTime(n)
		}
	case string:
		if n, err := strconv.ParseInt(strings.TrimSpace(v), 10, 64); err == nil && n > 0 {
			return milliTime(n)
		}
	}
	return recordTime(rec, nil)
}

// parseKimiRecord handles one kimi wire.jsonl record.
//
// Record types (roamgate projectKimiTrajectory):
//   - metadata: session metadata; captures session id, otherwise skipped
//   - context.append_message: only role=="user" messages are kept; assistant
//     context messages duplicate the authoritative loop events
//   - context.append_loop_event: event.type ∈ content.part (text|think),
//     tool.call, tool.result, step.end
func parseKimiRecord(out *transcriptFile, rec map[string]any, lineNo int) {
	typ, _ := rec["type"].(string)
	sentAt := kimiTimestamp(rec)
	switch typ {
	case "metadata":
		if out.sessionID == "" {
			for _, key := range []string{"id", "session_id", "sessionId", "conversation_id"} {
				if s, ok := rec[key].(string); ok && s != "" {
					out.sessionID = s
					break
				}
			}
		}
		return
	case "context.append_message":
		msg, _ := rec["message"].(map[string]any)
		if msg == nil {
			return
		}
		role, _ := msg["role"].(string)
		if role != "user" {
			return
		}
		text := kimiCleanText(kimiContentText(msg["content"]))
		if text == "" {
			return
		}
		addEntry(out, TranscriptEntry{
			ID: fmt.Sprintf("kimi-%d", lineNo), Role: "user", Kind: "message",
			Text: text, SentAt: sentAt,
		})
		return
	case "context.append_loop_event":
		event, _ := rec["event"].(map[string]any)
		if event == nil {
			return
		}
		eventType, _ := event["type"].(string)
		switch eventType {
		case "content.part":
			part, _ := event["part"].(map[string]any)
			if part == nil {
				return
			}
			partType, _ := part["type"].(string)
			switch partType {
			case "text":
				text := kimiCleanText(stringField(part, "text"))
				if text == "" {
					return
				}
				addEntry(out, TranscriptEntry{
					ID: fmt.Sprintf("kimi-%d", lineNo), Role: "assistant",
					Kind: "message", Text: text, SentAt: sentAt,
				})
			case "think":
				text := kimiCleanText(stringField(part, "think"))
				if text == "" {
					return
				}
				addEntry(out, TranscriptEntry{
					ID: fmt.Sprintf("kimi-%d", lineNo), Role: "assistant",
					Kind: "reasoning", Text: text, SentAt: sentAt,
				})
				out.trajectory = append(out.trajectory, map[string]any{
					"reasoning_content": text,
					"message":           "",
					"sent_at":           sentAt,
				})
			}
		case "tool.call":
			name := firstNonEmpty(stringField(event, "name"), "tool")
			callID := stringField(event, "toolCallId")
			if callID == "" {
				callID = fmt.Sprintf("kimi-%d", lineNo)
			}
			addEntry(out, TranscriptEntry{
				ID: callID, Role: "assistant", Kind: "tool_call",
				Text: kimiArgsText(event["args"]), ToolName: name,
				SentAt: sentAt,
			})
		case "tool.result":
			result, _ := event["result"].(map[string]any)
			if result == nil {
				result = map[string]any{}
			}
			text := kimiToolOutput(result["output"])
			if text == "" {
				text = "Tool result"
			}
			isErr, _ := result["isError"].(bool)
			callID := stringField(event, "toolCallId")
			if callID == "" {
				callID = fmt.Sprintf("kimi-%d", lineNo)
			}
			addEntry(out, TranscriptEntry{
				ID: callID + ":result", Role: "tool", Kind: "tool_result",
				Text: text, IsError: isErr, SentAt: sentAt,
			})
		case "step.end":
			// usage bookkeeping only; nothing to surface
		}
	}
}
