package main

import (
	"context"
	"strings"
	"time"
)

// watchAgentStatus turns herdr status transitions into task notices. The first snapshot only seeds state; notifications fire when a pane leaves working.
func (s *Server) watchAgentStatus(ctx context.Context) {
	previous := map[string]string{}
	ticker := time.NewTicker(2 * time.Second)
	defer ticker.Stop()
	for {
		snap, err := s.snapshot(ctx)
		if err != nil {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				continue
			}
		}
		current := make(map[string]string, len(snap.Panes))
		for _, pane := range snap.Panes {
			status := pane.AgentStatus
			current[pane.PaneID] = status
			before, seen := previous[pane.PaneID]
			if !seen || before == status || before != "working" {
				continue
			}
			kind := ""
			switch status {
			case "done", "idle":
				kind = "completed"
			case "blocked":
				kind = "blocked"
			}
			if kind == "" {
				continue
			}
			title := pane.StrippedTitle
			if title == "" {
				title = pane.TerminalTitle
			}
			if title == "" {
				title = pane.Agent
			}
			workspace := snap.Workspace(pane.WorkspaceID)
			label := ""
			if workspace != nil {
				label = workspace.Label
			}
			s.notifyAll(map[string]any{"event": "task_notification", "data": map[string]any{
				"kind":         kind,
				"title":        strings.TrimSpace(title),
				"body":         label,
				"agent":        pane.Agent,
				"workspace_id": pane.WorkspaceID,
				"tab_id":       pane.TabID,
				"pane_id":      pane.PaneID,
			}})
		}
		previous = current
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
	}
}
