package main

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"sync/atomic"
	"time"
)

// Herdr speaks one NDJSON request per Unix-socket connection
type Herdr struct {
	SocketPath string
	seq        atomic.Uint64
}

type herdrEnvelope struct {
	ID     string          `json:"id"`
	Result json.RawMessage `json:"result"`
	Error  *struct {
		Code    string `json:"code"`
		Message string `json:"message"`
	} `json:"error"`
}

func (h *Herdr) Call(ctx context.Context, method string, params any) (json.RawMessage, error) {
	if params == nil {
		params = map[string]any{}
	}
	body, err := json.Marshal(map[string]any{
		"id":     fmt.Sprintf("droves-%d", h.seq.Add(1)),
		"method": method,
		"params": params,
	})
	if err != nil {
		return nil, err
	}
	if len(body) > 1024*1024 {
		return nil, fmt.Errorf("%s: request exceeds herdr's 1 MiB limit", method)
	}
	d := net.Dialer{Timeout: 5 * time.Second}
	conn, err := d.DialContext(ctx, "unix", h.SocketPath)
	if err != nil {
		return nil, fmt.Errorf("herdr socket: %w", err)
	}
	defer conn.Close()
	deadline := time.Now().Add(10 * time.Second)
	if at, ok := ctx.Deadline(); ok && at.Before(deadline) {
		deadline = at
	}
	_ = conn.SetDeadline(deadline)
	if _, err := conn.Write(append(body, '\n')); err != nil {
		return nil, fmt.Errorf("herdr write: %w", err)
	}
	line, err := bufio.NewReaderSize(conn, 1<<20).ReadBytes('\n')
	if err != nil {
		return nil, fmt.Errorf("herdr read: %w", err)
	}
	if len(line) > 4<<20 {
		return nil, errors.New("herdr response exceeds 4 MiB")
	}
	var env herdrEnvelope
	if err := json.Unmarshal(line, &env); err != nil {
		return nil, fmt.Errorf("herdr response: %w", err)
	}
	if env.Error != nil {
		return nil, fmt.Errorf("%s: %s", env.Error.Code, env.Error.Message)
	}
	if env.Result == nil {
		return nil, errors.New("herdr returned no result")
	}
	return env.Result, nil
}

type Agent struct {
	PaneID         string       `json:"pane_id"`
	TerminalID     string       `json:"terminal_id"`
	WorkspaceID    string       `json:"workspace_id"`
	TabID          string       `json:"tab_id"`
	Agent          string       `json:"agent"`
	AgentStatus    string       `json:"agent_status"`
	Cwd            string       `json:"cwd"`
	ForegroundCwd  string       `json:"foreground_cwd"`
	Focused        bool         `json:"focused"`
	TerminalTitle  string       `json:"terminal_title"`
	StrippedTitle  string       `json:"terminal_title_stripped"`
	AgentSession   AgentSession `json:"agent_session"`
	StateChangeSeq int64        `json:"state_change_seq"`
	CompletionSeq  int64        `json:"completion_seq"`
	Scroll         *PaneScroll  `json:"scroll"`
}

type AgentSession struct {
	Agent  string `json:"agent"`
	Kind   string `json:"kind"`
	Source string `json:"source"`
	Value  string `json:"value"`
}

type PaneScroll struct {
	OffsetFromBottom    int `json:"offset_from_bottom"`
	MaxOffsetFromBottom int `json:"max_offset_from_bottom"`
	ViewportRows        int `json:"viewport_rows"`
}

type Pane struct {
	PaneID        string      `json:"pane_id"`
	TerminalID    string      `json:"terminal_id"`
	WorkspaceID   string      `json:"workspace_id"`
	TabID         string      `json:"tab_id"`
	Agent         string      `json:"agent"`
	AgentStatus   string      `json:"agent_status"`
	Cwd           string      `json:"cwd"`
	ForegroundCwd string      `json:"foreground_cwd"`
	Focused       bool        `json:"focused"`
	TerminalTitle string      `json:"terminal_title"`
	StrippedTitle string      `json:"terminal_title_stripped"`
	Scroll        *PaneScroll `json:"scroll"`
	Revision      int64       `json:"revision"`
}

type Tab struct {
	TabID       string `json:"tab_id"`
	WorkspaceID string `json:"workspace_id"`
	Label       string `json:"label"`
	Number      int    `json:"number"`
	PaneCount   int    `json:"pane_count"`
	AgentStatus string `json:"agent_status"`
	Focused     bool   `json:"focused"`
}

type Workspace struct {
	WorkspaceID string `json:"workspace_id"`
	Label       string `json:"label"`
	Number      int    `json:"number"`
	PaneCount   int    `json:"pane_count"`
	TabCount    int    `json:"tab_count"`
	AgentStatus string `json:"agent_status"`
	ActiveTabID string `json:"active_tab_id"`
	Focused     bool   `json:"focused"`
}

type Snapshot struct {
	Agents             []Agent     `json:"agents"`
	Panes              []Pane      `json:"panes"`
	Tabs               []Tab       `json:"tabs"`
	Workspaces         []Workspace `json:"workspaces"`
	FocusedPaneID      string      `json:"focused_pane_id"`
	FocusedTabID       string      `json:"focused_tab_id"`
	FocusedWorkspaceID string      `json:"focused_workspace_id"`
	Protocol           int         `json:"protocol"`
	Version            string      `json:"version"`
}

func (h *Herdr) Snapshot(ctx context.Context) (*Snapshot, error) {
	raw, err := h.Call(ctx, "session.snapshot", nil)
	if err != nil {
		return nil, err
	}
	var out struct {
		Snapshot *Snapshot `json:"snapshot"`
	}
	if err := json.Unmarshal(raw, &out); err != nil {
		return nil, err
	}
	if out.Snapshot == nil {
		return nil, errors.New("herdr snapshot is empty")
	}
	return out.Snapshot, nil
}

func (s *Snapshot) PaneByTerminal(id string) *Pane {
	for i := range s.Panes {
		if s.Panes[i].TerminalID == id {
			return &s.Panes[i]
		}
	}
	return nil
}

func (s *Snapshot) Pane(id string) *Pane {
	for i := range s.Panes {
		if s.Panes[i].PaneID == id {
			return &s.Panes[i]
		}
	}
	return nil
}

func (s *Snapshot) AgentForPane(paneID string) *Agent {
	for i := range s.Agents {
		if s.Agents[i].PaneID == paneID {
			return &s.Agents[i]
		}
	}
	return nil
}

func (s *Snapshot) Workspace(id string) *Workspace {
	for i := range s.Workspaces {
		if s.Workspaces[i].WorkspaceID == id {
			return &s.Workspaces[i]
		}
	}
	return nil
}

// WorkspaceRoot returns the focused pane's process cwd for Git and file operations
func (s *Snapshot) WorkspaceRoot(id string) string {
	var fallback string
	for _, p := range s.Panes {
		if p.WorkspaceID != id {
			continue
		}
		cwd := p.ForegroundCwd
		if cwd == "" {
			cwd = p.Cwd
		}
		if cwd == "" {
			continue
		}
		if p.Focused {
			return cwd
		}
		if fallback == "" {
			fallback = cwd
		}
	}
	return fallback
}
