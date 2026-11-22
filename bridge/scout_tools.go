package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

// Workspace tools for the openai Scout driver. Every file tool is scoped to
// the session's allowed workspace roots; paths escaping them are rejected.

const (
	scoutMaxFileBytes   = 128 * 1024
	scoutMaxDirEntries  = 500
	scoutMaxCmdOutput   = 30 * 1024
	scoutDefaultCmdTime = 120 * time.Second
	scoutMaxCmdTime     = 600 * time.Second
)

type scoutToolContext struct {
	ctx     context.Context
	roots   []string        // absolute, symlink-resolved allowed roots
	cwd     string          // working directory for relative paths and run_command
	srv     *Server         // bridge internals for workspace-read tools
	allowed map[string]bool // workspace ids the session may inspect; nil = all
}

func newScoutToolContext(iv assistantInvoke) *scoutToolContext {
	tc := &scoutToolContext{ctx: iv.ctx, cwd: iv.cwd, srv: iv.srv}
	tc.allowed = make(map[string]bool, len(iv.workspaceIDs))
	for _, id := range iv.workspaceIDs {
		tc.allowed[id] = true
	}
	seen := map[string]bool{}
	for _, root := range append([]string{iv.cwd}, iv.extraDirs...) {
		abs, err := filepath.Abs(root)
		if err != nil {
			continue
		}
		resolved, err := filepath.EvalSymlinks(abs)
		if err == nil {
			abs = resolved
		}
		if !seen[abs] {
			seen[abs] = true
			tc.roots = append(tc.roots, abs)
		}
	}
	return tc
}

// resolveScoped maps a tool-supplied path into an absolute path inside one of
// the allowed roots. Relative paths resolve against the working directory.
func (tc *scoutToolContext) resolveScoped(path string) (string, error) {
	if strings.TrimSpace(path) == "" {
		return "", errors.New("path is required")
	}
	var abs string
	if filepath.IsAbs(path) {
		abs = filepath.Clean(path)
	} else {
		abs = filepath.Join(tc.cwd, path)
	}
	// resolve symlinks on the deepest existing ancestor so writes to new
	// files inside a symlinked root still validate
	orig := abs
	for {
		if _, err := os.Stat(orig); err == nil {
			resolved := orig
			if r, err := filepath.EvalSymlinks(orig); err == nil {
				resolved = r
			}
			candidate := filepath.Join(resolved, strings.TrimPrefix(abs, orig))
			for _, root := range tc.roots {
				if candidate == root || strings.HasPrefix(candidate, root+string(os.PathSeparator)) {
					return candidate, nil
				}
			}
			break
		}
		parent := filepath.Dir(orig)
		if parent == orig {
			break
		}
		orig = parent
	}
	return "", fmt.Errorf("path %q is outside the allowed workspace roots", path)
}

func scoutReadFile(tc *scoutToolContext, args json.RawMessage) string {
	var in struct {
		Path   string `json:"path"`
		Offset int    `json:"offset"` // first line, 1-based
		Limit  int    `json:"limit"`  // max lines
	}
	if err := json.Unmarshal(args, &in); err != nil {
		return "invalid arguments: " + err.Error()
	}
	path, err := tc.resolveScoped(in.Path)
	if err != nil {
		return err.Error()
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return "read failed: " + err.Error()
	}
	truncated := false
	if len(data) > scoutMaxFileBytes {
		data = data[:scoutMaxFileBytes]
		truncated = true
	}
	text := string(data)
	if in.Offset > 0 || in.Limit > 0 {
		lines := strings.Split(text, "\n")
		start := 0
		if in.Offset > 1 {
			start = in.Offset - 1
		}
		if start > len(lines) {
			return fmt.Sprintf("offset %d beyond end of file (%d lines)", in.Offset, len(lines))
		}
		end := len(lines)
		if in.Limit > 0 && start+in.Limit < end {
			end = start + in.Limit
		}
		text = strings.Join(lines[start:end], "\n")
		if end < len(lines) {
			truncated = true
		}
	}
	if truncated {
		text += "\n[truncated]"
	}
	return text
}

func scoutListDir(tc *scoutToolContext, args json.RawMessage) string {
	var in struct {
		Path string `json:"path"`
	}
	if err := json.Unmarshal(args, &in); err != nil {
		return "invalid arguments: " + err.Error()
	}
	path, err := tc.resolveScoped(in.Path)
	if err != nil {
		return err.Error()
	}
	entries, err := os.ReadDir(path)
	if err != nil {
		return "list failed: " + err.Error()
	}
	type row struct {
		Name string `json:"name"`
		Dir  bool   `json:"dir"`
		Size int64  `json:"size,omitempty"`
	}
	rows := make([]row, 0, len(entries))
	for _, e := range entries {
		if len(rows) >= scoutMaxDirEntries {
			break
		}
		info, err := e.Info()
		if err != nil {
			continue
		}
		rows = append(rows, row{Name: e.Name(), Dir: e.IsDir(), Size: info.Size()})
	}
	sort.Slice(rows, func(i, j int) bool {
		if rows[i].Dir != rows[j].Dir {
			return rows[i].Dir
		}
		return rows[i].Name < rows[j].Name
	})
	b, _ := json.MarshalIndent(rows, "", "  ")
	return string(b)
}

func scoutWriteFile(tc *scoutToolContext, args json.RawMessage) string {
	var in struct {
		Path    string `json:"path"`
		Content string `json:"content"`
	}
	if err := json.Unmarshal(args, &in); err != nil {
		return "invalid arguments: " + err.Error()
	}
	path, err := tc.resolveScoped(in.Path)
	if err != nil {
		return err.Error()
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return "mkdir failed: " + err.Error()
	}
	if err := os.WriteFile(path, []byte(in.Content), 0o644); err != nil {
		return "write failed: " + err.Error()
	}
	return fmt.Sprintf("wrote %d bytes to %s", len(in.Content), path)
}

func scoutRunCommand(tc *scoutToolContext, args json.RawMessage) string {
	var in struct {
		Command        string `json:"command"`
		TimeoutSeconds int    `json:"timeout_seconds"`
	}
	if err := json.Unmarshal(args, &in); err != nil {
		return "invalid arguments: " + err.Error()
	}
	if strings.TrimSpace(in.Command) == "" {
		return "command is required"
	}
	timeout := scoutDefaultCmdTime
	if in.TimeoutSeconds > 0 {
		timeout = time.Duration(in.TimeoutSeconds) * time.Second
		if timeout > scoutMaxCmdTime {
			timeout = scoutMaxCmdTime
		}
	}
	ctx, cancel := context.WithTimeout(tc.ctx, timeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, "sh", "-c", in.Command)
	cmd.Dir = tc.cwd
	out, err := cmd.CombinedOutput()
	text := string(out)
	truncated := false
	if len(text) > scoutMaxCmdOutput {
		text = text[:scoutMaxCmdOutput]
		truncated = true
	}
	if ctx.Err() == context.DeadlineExceeded {
		return fmt.Sprintf("command timed out after %s\n%s", timeout, text)
	}
	if err != nil {
		text = fmt.Sprintf("exit error: %v\n%s", err, text)
	}
	if truncated {
		text += "\n[truncated]"
	}
	return text
}

// --- workspace-read tools -------------------------------------------------
// These expose the same read-only views the Droves clients get over RPC, but
// scoped to the Scout session's allowed workspaces.

func (tc *scoutToolContext) wsAllowed(id string) bool {
	return tc.allowed == nil || tc.allowed[id]
}

func (tc *scoutToolContext) snapshot() (*Snapshot, error) {
	if tc.srv == nil {
		return nil, errors.New("workspace tools are unavailable")
	}
	return tc.srv.snapshot(tc.ctx)
}

func capText(s string) string {
	if len(s) > scoutMaxCmdOutput {
		return s[:scoutMaxCmdOutput] + "\n[truncated]"
	}
	return s
}

// capJSON marshals v and keeps the result under scoutMaxCmdOutput, trimming
// large patch/diff text fields first.
func capJSON(v any) string {
	trim := func() {
		if m, ok := v.(map[string]any); ok {
			for _, key := range []string{"patch", "diff", "text"} {
				if s, ok := m[key].(string); ok && len(s) > scoutMaxCmdOutput/2 {
					m[key] = s[:scoutMaxCmdOutput/2] + "\n[truncated]"
				}
			}
		}
	}
	for i := 0; i < 3; i++ {
		out, err := json.Marshal(v)
		if err != nil {
			return "error marshaling result: " + err.Error()
		}
		if len(out) <= scoutMaxCmdOutput {
			return string(out)
		}
		trim()
	}
	out, _ := json.Marshal(v)
	if len(out) > scoutMaxCmdOutput {
		out = out[:scoutMaxCmdOutput]
	}
	return string(out) + "\n[truncated]"
}

// scoutWorkspaceStatus lists allowed workspaces with their panes and agents.
func scoutWorkspaceStatus(tc *scoutToolContext, args json.RawMessage) string {
	snap, err := tc.snapshot()
	if err != nil {
		return "error: " + err.Error()
	}
	var b strings.Builder
	b.WriteString("workspaces:\n")
	for _, w := range snap.Workspaces {
		if !tc.wsAllowed(w.WorkspaceID) {
			continue
		}
		focused := ""
		if w.Focused {
			focused = " focused"
		}
		fmt.Fprintf(&b, "- %s #%d %q status=%s panes=%d cwd=%s%s\n",
			w.WorkspaceID, w.Number, w.Label, w.AgentStatus, w.PaneCount,
			snap.WorkspaceRoot(w.WorkspaceID), focused)
	}
	b.WriteString("agents:\n")
	for _, a := range snap.Agents {
		if !tc.wsAllowed(a.WorkspaceID) {
			continue
		}
		title := a.StrippedTitle
		if title == "" {
			title = a.TerminalTitle
		}
		cwd := a.ForegroundCwd
		if cwd == "" {
			cwd = a.Cwd
		}
		fmt.Fprintf(&b, "- pane=%s ws=%s agent=%s status=%s cwd=%s title=%q\n",
			a.PaneID, a.WorkspaceID, a.Agent, a.AgentStatus, cwd, title)
	}
	return capText(b.String())
}

// paneWorkspace resolves a pane/terminal id to its workspace id.
func paneWorkspace(snap *Snapshot, paneID, terminalID string) (string, bool) {
	pane := snap.Pane(paneID)
	if pane == nil && terminalID != "" {
		pane = snap.PaneByTerminal(terminalID)
	}
	if pane == nil {
		return "", false
	}
	return pane.WorkspaceID, true
}

// scoutAgentHistory reads the transcript of the agent running in a pane.
func scoutAgentHistory(tc *scoutToolContext, args json.RawMessage) string {
	var in struct {
		PaneID     string `json:"pane_id"`
		TerminalID string `json:"terminal_id"`
		Limit      int    `json:"limit"`
	}
	if err := json.Unmarshal(args, &in); err != nil {
		return "invalid arguments: " + err.Error()
	}
	if in.PaneID == "" && in.TerminalID == "" {
		return "pane_id or terminal_id is required (see workspace_status)"
	}
	snap, err := tc.snapshot()
	if err != nil {
		return "error: " + err.Error()
	}
	ws, ok := paneWorkspace(snap, in.PaneID, in.TerminalID)
	if !ok {
		return "pane not found (see workspace_status for pane ids)"
	}
	if !tc.wsAllowed(ws) {
		return "pane is outside the allowed workspaces"
	}
	limit := in.Limit
	if limit <= 0 {
		limit = 50
	}
	if limit > 200 {
		limit = 200
	}
	raw, err := tc.srv.transcripts.Get(tc.ctx, tc.srv, map[string]any{
		"pane_id":         in.PaneID,
		"terminal_id":     in.TerminalID,
		"history_version": 2,
	})
	if err != nil {
		return "error: " + err.Error()
	}
	m, ok := raw.(map[string]any)
	if !ok {
		return capJSON(raw)
	}
	entries, _ := m["entries"].([]map[string]any)
	if len(entries) > limit {
		entries = entries[len(entries)-limit:]
	}
	// trim long texts so the model gets a digest, not a dump
	for _, e := range entries {
		for _, key := range []string{"text", "content"} {
			if s, ok := e[key].(string); ok && len(s) > 4000 {
				e[key] = s[:4000] + "\n[truncated]"
			}
		}
	}
	m["entries"] = entries
	return capJSON(m)
}

// scoutWorkspaceDiff shows git changes for an allowed workspace. Without path
// it returns the diff summary; with path (+ optional kind) a single file diff.
func scoutWorkspaceDiff(tc *scoutToolContext, args json.RawMessage) string {
	var in struct {
		WorkspaceID string `json:"workspace_id"`
		Path        string `json:"path"`
		Kind        string `json:"kind"`
	}
	if err := json.Unmarshal(args, &in); err != nil {
		return "invalid arguments: " + err.Error()
	}
	if tc.srv == nil {
		return "error: workspace tools are unavailable"
	}
	snap, err := tc.snapshot()
	if err != nil {
		return "error: " + err.Error()
	}
	wsID := in.WorkspaceID
	if wsID == "" {
		// default: the workspace whose root contains the session cwd
		for _, w := range snap.Workspaces {
			root := snap.WorkspaceRoot(w.WorkspaceID)
			if root != "" && (tc.cwd == root || strings.HasPrefix(tc.cwd, root+string(os.PathSeparator))) {
				wsID = w.WorkspaceID
				break
			}
		}
	}
	if wsID == "" {
		return "no workspace matches the working directory; pass workspace_id (see workspace_status)"
	}
	if !tc.wsAllowed(wsID) {
		return "workspace is outside the allowed workspaces"
	}
	p := map[string]any{"workspace_id": wsID}
	if in.Path != "" {
		p["path"] = in.Path
		if in.Kind != "" {
			p["kind"] = in.Kind
		}
		raw, err := tc.srv.gitDiffFile(tc.ctx, p)
		if err != nil {
			return "error: " + err.Error()
		}
		return capJSON(raw)
	}
	raw, err := tc.srv.gitDiffSummary(tc.ctx, p)
	if err != nil {
		return "error: " + err.Error()
	}
	return capJSON(raw)
}

// scoutTerminalOutput reads recent terminal output of a pane.
func scoutTerminalOutput(tc *scoutToolContext, args json.RawMessage) string {
	var in struct {
		PaneID     string `json:"pane_id"`
		TerminalID string `json:"terminal_id"`
		Lines      int    `json:"lines"`
	}
	if err := json.Unmarshal(args, &in); err != nil {
		return "invalid arguments: " + err.Error()
	}
	if in.PaneID == "" && in.TerminalID == "" {
		return "pane_id or terminal_id is required (see workspace_status)"
	}
	snap, err := tc.snapshot()
	if err != nil {
		return "error: " + err.Error()
	}
	ws, ok := paneWorkspace(snap, in.PaneID, in.TerminalID)
	if !ok {
		return "pane not found (see workspace_status for pane ids)"
	}
	if !tc.wsAllowed(ws) {
		return "pane is outside the allowed workspaces"
	}
	lines := in.Lines
	if lines <= 0 {
		lines = 120
	}
	if lines > 1000 {
		lines = 1000
	}
	paneID := in.PaneID
	if paneID == "" {
		pane := snap.PaneByTerminal(in.TerminalID)
		if pane == nil {
			return "pane not found"
		}
		paneID = pane.PaneID
	}
	raw, err := tc.srv.herdr.Call(tc.ctx, "pane.read", map[string]any{
		"pane_id":    paneID,
		"source":     "recent_unwrapped",
		"lines":      lines,
		"format":     "text",
		"strip_ansi": true,
	})
	if err != nil {
		return "error: " + err.Error()
	}
	var wrap struct {
		Read *struct {
			Text string `json:"text"`
		} `json:"read"`
		Text string `json:"text"`
	}
	if err := json.Unmarshal(raw, &wrap); err != nil {
		return "error decoding pane output: " + err.Error()
	}
	text := wrap.Text
	if wrap.Read != nil {
		text = wrap.Read.Text
	}
	return capText(text)
}

type scoutToolDef struct {
	name     string
	desc     string
	props    map[string]any
	required []string
	run      func(*scoutToolContext, json.RawMessage) string
}

var scoutToolDefs = []scoutToolDef{
	{
		name: "read_file",
		desc: "Read a file from the workspace. Paths are relative to the working directory or absolute inside the allowed roots. Use offset/limit (1-based lines) for large files.",
		props: map[string]any{
			"path":   map[string]any{"type": "string", "description": "file path"},
			"offset": map[string]any{"type": "integer", "description": "first line to read, 1-based"},
			"limit":  map[string]any{"type": "integer", "description": "max lines to read"},
		},
		required: []string{"path"},
		run:      scoutReadFile,
	},
	{
		name:     "list_dir",
		desc:     "List directory entries (name, dir flag, size) inside the allowed workspace roots.",
		props:    map[string]any{"path": map[string]any{"type": "string", "description": "directory path"}},
		required: []string{"path"},
		run:      scoutListDir,
	},
	{
		name: "write_file",
		desc: "Write a file inside the allowed workspace roots, creating parent directories. Overwrites existing content.",
		props: map[string]any{
			"path":    map[string]any{"type": "string", "description": "file path"},
			"content": map[string]any{"type": "string", "description": "full file content"},
		},
		required: []string{"path", "content"},
		run:      scoutWriteFile,
	},
	{
		name: "run_command",
		desc: "Run a shell command in the working directory. Returns combined stdout/stderr. Use for builds, tests, git, and inspection.",
		props: map[string]any{
			"command":         map[string]any{"type": "string", "description": "shell command"},
			"timeout_seconds": map[string]any{"type": "integer", "description": "timeout, default 120, max 600"},
		},
		required: []string{"command"},
		run:      scoutRunCommand,
	},
	{
		name:  "workspace_status",
		desc:  "List Droves workspaces, panes and running agents (id, status, cwd, title). Use the pane_id values with agent_history and terminal_output.",
		props: map[string]any{},
		run:   scoutWorkspaceStatus,
	},
	{
		name: "agent_history",
		desc: "Read the transcript of the agent running in a pane (messages, tool calls). Use pane_id or terminal_id from workspace_status; limit selects the last N entries (default 50, max 200).",
		props: map[string]any{
			"pane_id":     map[string]any{"type": "string", "description": "pane id from workspace_status"},
			"terminal_id": map[string]any{"type": "string", "description": "terminal id alternative to pane_id"},
			"limit":       map[string]any{"type": "integer", "description": "last N entries, default 50"},
		},
		run: scoutAgentHistory,
	},
	{
		name: "workspace_diff",
		desc: "Show git changes of a Droves workspace. Omit path for the change summary (entries + counts); pass path (+ optional kind: staged/unstaged/untracked/conflicted) for one file's diff. workspace_id defaults to the workspace containing the working directory.",
		props: map[string]any{
			"workspace_id": map[string]any{"type": "string", "description": "workspace id from workspace_status"},
			"path":         map[string]any{"type": "string", "description": "repo-relative file path for a single-file diff"},
			"kind":         map[string]any{"type": "string", "description": "staged|unstaged|untracked|conflicted"},
		},
		run: scoutWorkspaceDiff,
	},
	{
		name: "terminal_output",
		desc: "Read recent terminal output of a pane (unwrapped text). Use pane_id or terminal_id from workspace_status; lines defaults to 120, max 1000.",
		props: map[string]any{
			"pane_id":     map[string]any{"type": "string", "description": "pane id from workspace_status"},
			"terminal_id": map[string]any{"type": "string", "description": "terminal id alternative to pane_id"},
			"lines":       map[string]any{"type": "integer", "description": "lines to read, default 120"},
		},
		run: scoutTerminalOutput,
	},
}

// callScoutTool dispatches one OpenAI tool call by name.
func callScoutTool(tc *scoutToolContext, name string, args json.RawMessage) string {
	for _, tool := range scoutToolDefs {
		if tool.name == name {
			return tool.run(tc, args)
		}
	}
	return fmt.Sprintf("unknown tool %q", name)
}

// scoutOpenAITools is the OpenAI function-calling tool catalog.
func scoutOpenAITools() []map[string]any {
	out := make([]map[string]any, 0, len(scoutToolDefs))
	for _, tool := range scoutToolDefs {
		params := map[string]any{
			"type":       "object",
			"properties": tool.props,
		}
		if len(tool.required) > 0 {
			params["required"] = tool.required
		}
		out = append(out, map[string]any{
			"type": "function",
			"function": map[string]any{
				"name":        tool.name,
				"description": tool.desc,
				"parameters":  params,
			},
		})
	}
	return out
}
