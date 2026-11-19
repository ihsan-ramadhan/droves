package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

type Ranger struct {
	srv      *Server
	mu       sync.Mutex
	state    *rangerState
	models   []map[string]any
	modelsAt time.Time
}

type rangerState struct {
	Config   rangerConfig     `json:"config"`
	Active   string           `json:"session_id"`
	Sessions []*rangerSession `json:"sessions"`
}

type rangerConfig struct {
	Provider          string           `json:"provider"`
	Model             string           `json:"model"`
	ThinkingLevel     string           `json:"thinking_level"`
	AllowedWorkspaces []map[string]any `json:"allowed_workspaces"`
}

type rangerSession struct {
	ID       string          `json:"id"`
	Title    string          `json:"title"`
	Updated  time.Time       `json:"updated_at"`
	Messages []rangerMessage `json:"messages"`
	Running  bool            `json:"-"`
}

type rangerMessage struct {
	Role string `json:"role"`
	Text string `json:"text"`
}

func NewRanger(srv *Server) *Ranger {
	r := &Ranger{srv: srv}
	r.state = r.loadState()
	return r
}

func (r *Ranger) statePath() string {
	return filepath.Join(r.srv.cfg.StateDir, "ranger.json")
}

func (r *Ranger) loadState() *rangerState {
	state := &rangerState{}
	if data, err := os.ReadFile(r.statePath()); err == nil {
		_ = json.Unmarshal(data, state)
	}
	if state.Active == "" || state.session(state.Active) == nil {
		r.ensureSession(state)
	}
	return state
}

func (r *Ranger) saveLocked() {
	data, err := json.MarshalIndent(r.state, "", "  ")
	if err != nil {
		return
	}
	tmp := r.statePath() + ".tmp"
	if os.WriteFile(tmp, data, 0o600) == nil {
		_ = os.Rename(tmp, r.statePath())
	}
}

func (r *Ranger) ensureSession(state *rangerState) *rangerSession {
	id, _ := randomToken(12)
	sess := &rangerSession{ID: id, Title: "New chat", Updated: time.Now().UTC()}
	state.Sessions = append([]*rangerSession{sess}, state.Sessions...)
	state.Active = id
	return sess
}

func (s *rangerState) session(id string) *rangerSession {
	for _, sess := range s.Sessions {
		if sess.ID == id {
			return sess
		}
	}
	return nil
}

func (r *Ranger) Handle(ctx context.Context, method string, p map[string]any) (any, error) {
	switch method {
	case "bridge.assistant.get":
		return r.Get(ctx), nil
	case "bridge.assistant.configure_chat":
		return r.Configure(p)
	case "bridge.assistant.send":
		return r.Send(ctx, p)
	case "bridge.assistant.new_session":
		return r.NewSession()
	case "bridge.assistant.select_session":
		return r.Select(asString(p, "session_id"))
	}
	return nil, fmt.Errorf("unknown assistant method: %s", method)
}

func (r *Ranger) Get(ctx context.Context) map[string]any {
	r.mu.Lock()
	if len(r.state.Config.AllowedWorkspaces) == 0 {
		r.state.Config.AllowedWorkspaces = r.allWorkspaces(ctx)
		r.saveLocked()
	}
	state := r.state
	sess := state.session(state.Active)
	r.mu.Unlock()
	sessions := make([]map[string]any, 0, len(state.Sessions))
	for _, s := range state.Sessions {
		sessions = append(sessions, map[string]any{
			"id": s.ID, "title": s.Title, "updated_at": s.Updated.Format(time.RFC3339),
		})
	}
	messages := make([]map[string]any, 0)
	running := false
	if sess != nil {
		running = sess.Running
		for _, m := range sess.Messages {
			messages = append(messages, map[string]any{"role": m.Role, "text": m.Text})
		}
	}
	return map[string]any{
		"config":     r.configJSON(),
		"session_id": state.Active,
		"sessions":   sessions,
		"messages":   messages,
		"running":    running,
		"models":     r.Models(ctx),
	}
}

func (r *Ranger) configJSON() map[string]any {
	r.mu.Lock()
	defer r.mu.Unlock()
	return map[string]any{
		"provider":           r.state.Config.Provider,
		"model":              r.state.Config.Model,
		"thinking_level":     r.state.Config.ThinkingLevel,
		"allowed_workspaces": r.state.Config.AllowedWorkspaces,
	}
}

func (r *Ranger) allWorkspaces(ctx context.Context) []map[string]any {
	snap, err := r.srv.snapshot(ctx)
	if err != nil {
		return []map[string]any{}
	}
	out := make([]map[string]any, 0, len(snap.Workspaces))
	for _, w := range snap.Workspaces {
		out = append(out, map[string]any{
			"connection_id": "local", "workspace_id": w.WorkspaceID, "label": w.Label,
		})
	}
	return out
}

func (r *Ranger) Configure(p map[string]any) (any, error) {
	provider := asString(p, "provider")
	model := asString(p, "model")
	if provider == "" || model == "" {
		return nil, errors.New("provider and model are required")
	}
	r.mu.Lock()
	r.state.Config.Provider = provider
	r.state.Config.Model = model
	r.state.Config.ThinkingLevel = asString(p, "thinking_level")
	if raw, ok := p["allowed_workspaces"].([]any); ok && len(raw) > 0 {
		refs := make([]map[string]any, 0, len(raw))
		for _, item := range raw {
			if m, ok := item.(map[string]any); ok {
				refs = append(refs, map[string]any{
					"connection_id": asString(m, "connection_id"),
					"workspace_id":  asString(m, "workspace_id"),
				})
			}
		}
		r.state.Config.AllowedWorkspaces = refs
	}
	r.saveLocked()
	r.mu.Unlock()
	return map[string]any{"config": r.configJSON()}, nil
}

func (r *Ranger) NewSession() (any, error) {
	r.mu.Lock()
	sess := r.ensureSession(r.state)
	r.saveLocked()
	r.mu.Unlock()
	return map[string]any{"session_id": sess.ID}, nil
}

func (r *Ranger) Select(id string) (any, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.state.session(id) == nil {
		return nil, errors.New("session not found")
	}
	r.state.Active = id
	r.saveLocked()
	return map[string]any{"session_id": id}, nil
}

func (r *Ranger) Send(ctx context.Context, p map[string]any) (any, error) {
	text := strings.TrimSpace(asString(p, "text"))
	if text == "" {
		return nil, errors.New("message is empty")
	}
	if len(text) > 32_000 {
		return nil, errors.New("message is too long")
	}
	r.mu.Lock()
	cfg := r.state.Config
	if cfg.Provider == "" || cfg.Model == "" {
		r.mu.Unlock()
		return nil, errors.New("pick a model first")
	}
	sess := r.state.session(asString(p, "session_id"))
	if sess == nil {
		sess = r.state.session(r.state.Active)
	}
	if sess == nil {
		sess = r.ensureSession(r.state)
	}
	if sess.Running {
		r.mu.Unlock()
		return nil, errors.New("Ranger is already running this session")
	}
	if raw, ok := p["scope"].([]any); ok && len(raw) > 0 {
		refs := make([]map[string]any, 0, len(raw))
		for _, item := range raw {
			if m, ok := item.(map[string]any); ok {
				refs = append(refs, map[string]any{
					"connection_id": asString(m, "connection_id"),
					"workspace_id":  asString(m, "workspace_id"),
				})
			}
		}
		cfg.AllowedWorkspaces = refs
		r.state.Config.AllowedWorkspaces = refs
	}
	if len(cfg.AllowedWorkspaces) == 0 {
		cfg.AllowedWorkspaces = r.allWorkspaces(ctx)
		r.state.Config.AllowedWorkspaces = cfg.AllowedWorkspaces
	}
	sess.Messages = append(sess.Messages, rangerMessage{Role: "user", Text: text})
	if sess.Title == "New chat" {
		title := text
		if len(title) > 60 {
			title = title[:60]
		}
		sess.Title = title
	}
	sess.Updated = time.Now().UTC()
	sess.Running = true
	r.saveLocked()
	snapshot := r.snapshotLocked()
	sessionID := sess.ID
	r.mu.Unlock()
	r.push(snapshot)

	go r.run(sessionID, text, cfg)
	return map[string]any{"ok": true, "session_id": sessionID}, nil
}

func (r *Ranger) snapshotLocked() map[string]any {
	state := r.state
	sess := state.session(state.Active)
	messages := make([]map[string]any, 0)
	running := false
	if sess != nil {
		running = sess.Running
		for _, m := range sess.Messages {
			messages = append(messages, map[string]any{"role": m.Role, "text": m.Text})
		}
	}
	sessions := make([]map[string]any, 0, len(state.Sessions))
	for _, s := range state.Sessions {
		sessions = append(sessions, map[string]any{
			"id": s.ID, "title": s.Title, "updated_at": s.Updated.Format(time.RFC3339),
		})
	}
	return map[string]any{
		"config":     r.configLocked(),
		"session_id": state.Active,
		"sessions":   sessions,
		"messages":   messages,
		"running":    running,
	}
}

func (r *Ranger) configLocked() map[string]any {
	return map[string]any{
		"provider":           r.state.Config.Provider,
		"model":              r.state.Config.Model,
		"thinking_level":     r.state.Config.ThinkingLevel,
		"allowed_workspaces": r.state.Config.AllowedWorkspaces,
	}
}

func (r *Ranger) push(snapshot map[string]any) {
	r.srv.notifyAll(map[string]any{"assistant": snapshot})
}

func (r *Ranger) run(sessionID, text string, cfg rangerConfig) {
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Minute)
	defer cancel()
	answer, err := r.invoke(ctx, sessionID, text, cfg)
	r.mu.Lock()
	sess := r.state.session(sessionID)
	if sess != nil {
		sess.Running = false
		if err != nil {
			sess.Messages = append(sess.Messages, rangerMessage{Role: "assistant", Text: "Ranger failed: " + err.Error()})
		} else if answer != "" {
			sess.Messages = append(sess.Messages, rangerMessage{Role: "assistant", Text: answer})
		}
		sess.Updated = time.Now().UTC()
	}
	r.saveLocked()
	snapshot := r.snapshotLocked()
	active := r.state.Active
	r.mu.Unlock()
	if active == sessionID {
		r.push(snapshot)
	}
	if err != nil {
		r.srv.notifyAll(map[string]any{"assistant_notification": map[string]any{
			"title": "Ranger failed", "body": err.Error(),
		}})
	} else {
		r.srv.notifyAll(map[string]any{"assistant_notification": map[string]any{
			"title": "Ranger finished", "body": truncate(answer, 140),
		}})
	}
}

func (r *Ranger) invoke(ctx context.Context, sessionID, text string, cfg rangerConfig) (string, error) {
	omp, err := exec.LookPath(envOr("OMP_BIN", "omp"))
	if err != nil {
		return "", errors.New("omp is not installed on the bridge host")
	}
	snap, err := r.srv.snapshot(ctx)
	if err != nil {
		return "", err
	}
	var roots []string
	for _, ref := range cfg.AllowedWorkspaces {
		if asString(ref, "connection_id") != "" && asString(ref, "connection_id") != "local" {
			continue
		}
		if root := snap.WorkspaceRoot(asString(ref, "workspace_id")); root != "" {
			roots = append(roots, root)
		}
	}
	cwd := r.srv.cfg.StateDir
	args := []string{"-p", "--mode=json", "--no-title", "--auto-approve", "--max-time=12m",
		"--model", cfg.Provider + "/" + cfg.Model}
	if cfg.ThinkingLevel != "" {
		args = append(args, "--thinking", cfg.ThinkingLevel)
	}
	if len(roots) > 0 {
		cwd = roots[0]
		for _, root := range roots[1:] {
			args = append(args, "--add-dir", root)
		}
	}
	sessionDir := filepath.Join(r.srv.cfg.StateDir, "ranger", sessionID)
	if err := os.MkdirAll(sessionDir, 0o700); err != nil {
		return "", err
	}
	args = append(args, "--session-dir", sessionDir)
	if hasSessionFile(sessionDir) {
		args = append(args, "--continue")
	}
	args = append(args, text)
	cmd := exec.CommandContext(ctx, omp, args...)
	cmd.Dir = cwd
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	err = cmd.Run()
	if ctx.Err() != nil {
		return "", errors.New("Ranger timed out")
	}
	answer := parseRangerOutput(stdout.Bytes())
	if err != nil {
		msg := strings.TrimSpace(stderr.String())
		if msg == "" {
			msg = strings.TrimSpace(stdout.String())
		}
		if answer == "" && msg != "" {
			return "", errors.New(truncate(msg, 2000))
		}
		if answer == "" {
			return "", err
		}
	}
	return answer, nil
}

func hasSessionFile(dir string) bool {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return false
	}
	for _, e := range entries {
		if strings.HasSuffix(e.Name(), ".jsonl") {
			return true
		}
	}
	return false
}

func parseRangerOutput(data []byte) string {
	var answer string
	sc := bufio.NewScanner(bytes.NewReader(data))
	sc.Buffer(make([]byte, 64*1024), 16*1024*1024)
	for sc.Scan() {
		var event struct {
			Type    string `json:"type"`
			Message struct {
				Role    string `json:"role"`
				Content []struct {
					Type     string `json:"type"`
					Text     string `json:"text"`
					Thinking string `json:"thinking"`
				} `json:"content"`
			} `json:"message"`
		}
		if json.Unmarshal(sc.Bytes(), &event) != nil {
			continue
		}
		if event.Type != "message_end" || event.Message.Role != "assistant" {
			continue
		}
		var parts []string
		for _, block := range event.Message.Content {
			if block.Type == "text" && block.Text != "" {
				parts = append(parts, block.Text)
			}
		}
		if len(parts) > 0 {
			answer = strings.Join(parts, "\n")
		}
	}
	if answer == "" {
		// older omp builds emit plain text in print mode
		trimmed := strings.TrimSpace(string(data))
		if !strings.HasPrefix(trimmed, "{") {
			answer = trimmed
		}
	}
	return answer
}

func (r *Ranger) Models(ctx context.Context) []map[string]any {
	r.mu.Lock()
	if len(r.models) > 0 && time.Since(r.modelsAt) < 10*time.Minute {
		out := r.models
		r.mu.Unlock()
		return out
	}
	r.mu.Unlock()
	omp, err := exec.LookPath(envOr("OMP_BIN", "omp"))
	if err != nil {
		return []map[string]any{}
	}
	cctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	out, err := exec.CommandContext(cctx, omp, "models", "--json").Output()
	if err != nil {
		return []map[string]any{}
	}
	var catalog struct {
		Models []struct {
			Provider string   `json:"provider"`
			Kind     string   `json:"kind"`
			ID       string   `json:"id"`
			Name     string   `json:"name"`
			Thinking []string `json:"thinking"`
		} `json:"models"`
	}
	if json.Unmarshal(out, &catalog) != nil {
		return []map[string]any{}
	}
	models := make([]map[string]any, 0, len(catalog.Models))
	for _, m := range catalog.Models {
		if m.Kind != "" && m.Kind != "chat" {
			continue
		}
		label := m.Name
		if label == "" {
			label = m.ID
		}
		thinking := m.Thinking
		if thinking == nil {
			thinking = []string{}
		}
		models = append(models, map[string]any{
			"provider": m.Provider, "id": m.ID, "label": label,
			"thinking_levels": thinking,
		})
	}
	r.mu.Lock()
	r.models = models
	r.modelsAt = time.Now()
	r.mu.Unlock()
	return models
}

func truncate(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n]
}
