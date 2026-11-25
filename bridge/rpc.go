package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"strings"
)

func asString(m map[string]any, key string) string {
	v, _ := m[key].(string)
	return v
}

func asInt(m map[string]any, key string, fallback int) int {
	switch v := m[key].(type) {
	case float64:
		return int(v)
	case int:
		return v
	case json.Number:
		n, _ := v.Int64()
		return int(n)
	}
	return fallback
}

func asBool(m map[string]any, key string) bool {
	v, _ := m[key].(bool)
	return v
}

func asStrings(m map[string]any, key string) []string {
	raw, _ := m[key].([]any)
	out := make([]string, 0, len(raw))
	for _, item := range raw {
		if s, ok := item.(string); ok {
			out = append(out, s)
		}
	}
	return out
}

func (s *Server) snapshot(ctx context.Context) (*Snapshot, error) {
	return s.herdr.Snapshot(ctx)
}

func (s *Server) dispatch(ctx context.Context, c *Client, req RPCRequest) (any, error) {
	p := req.Params
	if p == nil {
		p = map[string]any{}
	}
	switch req.Method {
	case "bridge.ping":
		return map[string]any{"ok": true, "version": s.version}, nil
	case "bridge.status":
		exp := s.exposeStatus(ctx)
		return map[string]any{
			"state":        "ready",
			"version":      s.version,
			"clients":      s.countClients(),
			"herdr_socket": s.cfg.Socket,
			"exposure":     exp,
		}, nil
	case "bridge.info":
		return s.info(ctx), nil
	case "connections.list":
		return map[string]any{"connections": []any{map[string]any{
			"id":                  "local",
			"label":               "This machine",
			"state":               "connected",
			"type":                "local",
			"is_default":          true,
			"read_only":           false,
			"control_socket_path": s.cfg.Socket,
		}}}, nil
	case "connections.connect":
		return map[string]any{"ok": true}, nil

	case "workspace.list":
		snap, err := s.snapshot(ctx)
		if err != nil {
			return nil, err
		}
		out := make([]any, 0, len(snap.Workspaces))
		for _, w := range snap.Workspaces {
			out = append(out, map[string]any{
				"workspace_id":  w.WorkspaceID,
				"label":         w.Label,
				"number":        w.Number,
				"pane_count":    w.PaneCount,
				"tab_count":     w.TabCount,
				"agent_status":  w.AgentStatus,
				"cwd":           snap.WorkspaceRoot(w.WorkspaceID),
				"active_tab_id": w.ActiveTabID,
				"focused":       w.WorkspaceID == snap.FocusedWorkspaceID,
			})
		}
		return map[string]any{"workspaces": out}, nil
	case "workspace.create":
		params := map[string]any{"focus": asBool(p, "focus")}
		if cwd := asString(p, "cwd"); cwd != "" {
			params["cwd"] = cwd
		}
		if label := asString(p, "label"); label != "" {
			params["label"] = label
		}
		return s.herdrResult(ctx, "workspace.create", params)
	case "workspace.rename":
		return s.herdrResult(ctx, "workspace.rename", map[string]any{
			"workspace_id": asString(p, "workspace_id"),
			"label":        asString(p, "label"),
		})
	case "workspace.focus":
		return s.herdrResult(ctx, "workspace.focus", map[string]any{"workspace_id": asString(p, "workspace_id")})
	case "tab.list":
		snap, err := s.snapshot(ctx)
		if err != nil {
			return nil, err
		}
		ws := asString(p, "workspace_id")
		out := make([]any, 0, len(snap.Tabs))
		for _, t := range snap.Tabs {
			if ws != "" && t.WorkspaceID != ws {
				continue
			}
			out = append(out, map[string]any{
				"tab_id":       t.TabID,
				"workspace_id": t.WorkspaceID,
				"label":        t.Label,
				"number":       t.Number,
				"pane_count":   t.PaneCount,
				"agent_status": t.AgentStatus,
				"focused":      t.TabID == snap.FocusedTabID,
			})
		}
		return map[string]any{"tabs": out}, nil
	case "tab.create":
		params := map[string]any{"focus": true}
		if ws := asString(p, "workspace_id"); ws != "" {
			params["workspace_id"] = ws
		}
		if cwd := asString(p, "cwd"); cwd != "" {
			params["cwd"] = cwd
		}
		if label := asString(p, "label"); label != "" {
			params["label"] = label
		}
		return s.herdrResult(ctx, "tab.create", params)
	case "tab.rename":
		return s.herdrResult(ctx, "tab.rename", map[string]any{
			"tab_id": asString(p, "tab_id"),
			"label":  asString(p, "label"),
		})
	case "tab.close":
		return s.herdrResult(ctx, "tab.close", map[string]any{"tab_id": asString(p, "tab_id")})
	case "pane.list":
		snap, err := s.snapshot(ctx)
		if err != nil {
			return nil, err
		}
		ws := asString(p, "workspace_id")
		out := make([]any, 0, len(snap.Panes))
		for _, pane := range snap.Panes {
			if ws != "" && pane.WorkspaceID != ws {
				continue
			}
			out = append(out, paneJSON(pane))
		}
		return map[string]any{"panes": out}, nil
	case "pane.focus":
		return s.herdrResult(ctx, "pane.focus", map[string]any{"pane_id": asString(p, "pane_id")})
	case "pane.close":
		out, err := s.herdrResult(ctx, "pane.close", map[string]any{"pane_id": asString(p, "pane_id")})
		s.terms.layoutChanged()
		return out, err
	case "pane.rename":
		return s.herdrResult(ctx, "pane.rename", map[string]any{
			"pane_id": asString(p, "pane_id"),
			"label":   asString(p, "label"),
		})
	case "pane.split":
		params := map[string]any{
			"direction":      asString(p, "direction"),
			"target_pane_id": asString(p, "pane_id"),
			"workspace_id":   asString(p, "workspace_id"),
			"focus":          true,
		}
		if cwd := asString(p, "cwd"); cwd != "" {
			params["cwd"] = cwd
		}
		out, err := s.herdrResult(ctx, "pane.split", params)
		s.terms.layoutChanged()
		return out, err
	case "pane.zoom":
		mode := asString(p, "mode")
		if mode == "" {
			mode = "toggle"
		}
		out, err := s.herdrResult(ctx, "pane.zoom", map[string]any{
			"pane_id": asString(p, "pane_id"),
			"mode":    mode,
		})
		s.terms.layoutChanged()
		return out, err
	case "pane.send_text":
		return s.herdrResult(ctx, "pane.send_text", map[string]any{
			"pane_id": asString(p, "pane_id"),
			"text":    asString(p, "text"),
		})
	case "pane.send_input":
		params := map[string]any{"pane_id": asString(p, "pane_id")}
		if text := asString(p, "text"); text != "" {
			params["text"] = text
		}
		if keys := asStrings(p, "keys"); len(keys) > 0 {
			params["keys"] = keys
		}
		return s.herdrResult(ctx, "pane.send_input", params)
	case "pane.send_keys":
		return s.herdrResult(ctx, "pane.send_keys", map[string]any{
			"pane_id": asString(p, "pane_id"),
			"keys":    asStrings(p, "keys"),
		})
	case "agent.list":
		snap, err := s.snapshot(ctx)
		if err != nil {
			return nil, err
		}
		out := make([]any, 0, len(snap.Agents))
		for _, a := range snap.Agents {
			title := a.StrippedTitle
			if title == "" {
				title = a.TerminalTitle
			}
			cwd := a.ForegroundCwd
			if cwd == "" {
				cwd = a.Cwd
			}
			out = append(out, map[string]any{
				"pane_id":                 a.PaneID,
				"terminal_id":             a.TerminalID,
				"workspace_id":            a.WorkspaceID,
				"tab_id":                  a.TabID,
				"agent":                   a.Agent,
				"agent_status":            a.AgentStatus,
				"cwd":                     cwd,
				"foreground_cwd":          cwd,
				"terminal_title":          title,
				"terminal_title_stripped": title,
				"focused":                 a.Focused,
			})
		}
		return map[string]any{"agents": out}, nil

	case "terminal.attach":
		split, vcols, vrows, err := s.terms.Attach(ctx, c, asString(p, "terminal_id"), asInt(p, "cols", 80), asInt(p, "rows", 24))
		if err != nil {
			return nil, err
		}
		return map[string]any{
			"ok":     true,
			"offset": s.terms.Offset(asString(p, "terminal_id")),
			"split":  split,
			"cols":   vcols,
			"rows":   vrows,
		}, nil
	case "terminal.detach":
		s.terms.Detach(c, asString(p, "terminal_id"))
		return map[string]any{"ok": true}, nil
	case "terminal.input":
		raw, err := base64.StdEncoding.DecodeString(asString(p, "data"))
		if err != nil {
			return nil, errors.New("terminal input is not base64")
		}
		if err := s.terms.Input(ctx, c, asString(p, "terminal_id"), string(raw)); err != nil {
			return nil, err
		}
		return map[string]any{"ok": true}, nil
	case "terminal.resize":
		s.terms.Resize(c, asString(p, "terminal_id"), asInt(p, "cols", 80), asInt(p, "rows", 24))
		return map[string]any{"ok": true}, nil
	case "terminal.scroll":
		up := asString(p, "direction") != "down"
		offset, err := s.terms.Scroll(ctx, c, asString(p, "terminal_id"), asInt(p, "lines", 3), up)
		if err != nil {
			return nil, err
		}
		return map[string]any{"ok": true, "offset": offset}, nil

	case "agent_history.get":
		return s.transcripts.Get(ctx, s, p)
	case "agent_history.entry":
		return s.transcripts.Entry(ctx, s, p)
	case "agent_session.get":
		return s.transcripts.Session(ctx, s, p)

	case "git.diff_summary":
		return s.gitDiffSummary(ctx, p)
	case "git.diff_file":
		return s.gitDiffFile(ctx, p)
	case "git.file_action":
		return s.gitFileAction(ctx, p)
	case "git.pull":
		return s.gitPull(ctx, p)
	case "git.push":
		return s.gitPush(ctx, p)
	case "git.commits":
		return s.gitCommits(ctx, p)
	case "git.commit":
		return s.gitCommit(ctx, p)
	case "git.commit.create":
		return s.gitCommitCreate(ctx, p)

	case "file.list":
		return s.fileList(p)
	case "file.read":
		return s.fileRead(p)
	case "file.search":
		return s.fileSearch(ctx, p)
	case "file.mkdir":
		return s.fileMkdir(p)
	case "file.move":
		return s.fileMove(p)

	default:
		if strings.HasPrefix(req.Method, "bridge.assistant.") {
			return s.scout.Handle(ctx, req.Method, p)
		}
		return nil, fmt.Errorf("unknown bridge method: %s", req.Method)
	}
}

func (s *Server) herdrResult(ctx context.Context, method string, params map[string]any) (any, error) {
	raw, err := s.herdr.Call(ctx, method, params)
	if err != nil {
		return nil, err
	}
	if len(raw) == 0 || string(raw) == "null" {
		return map[string]any{"ok": true}, nil
	}
	var out any
	if err := json.Unmarshal(raw, &out); err != nil {
		return map[string]any{"ok": true}, nil
	}
	if m, ok := out.(map[string]any); ok {
		return m, nil
	}
	return map[string]any{"result": out}, nil
}

func paneJSON(pane Pane) map[string]any {
	title := pane.StrippedTitle
	if title == "" {
		title = pane.TerminalTitle
	}
	cwd := pane.ForegroundCwd
	if cwd == "" {
		cwd = pane.Cwd
	}
	return map[string]any{
		"pane_id":                 pane.PaneID,
		"terminal_id":             pane.TerminalID,
		"workspace_id":            pane.WorkspaceID,
		"tab_id":                  pane.TabID,
		"agent_status":            pane.AgentStatus,
		"agent":                   pane.Agent,
		"foreground_cwd":          cwd,
		"cwd":                     cwd,
		"terminal_title":          title,
		"terminal_title_stripped": title,
		"focused":                 pane.Focused,
	}
}

func (s *Server) workspaceRoot(ctx context.Context, workspaceID string) (string, error) {
	if workspaceID == "" {
		return "", errors.New("workspace_id is required")
	}
	snap, err := s.snapshot(ctx)
	if err != nil {
		return "", err
	}
	root := snap.WorkspaceRoot(workspaceID)
	if root == "" {
		return "", errors.New("workspace has no pane with a working directory")
	}
	if st, err := os.Stat(root); err != nil || !st.IsDir() {
		return "", fmt.Errorf("workspace directory is unavailable: %s", root)
	}
	return root, nil
}
