package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

type Scout struct {
	srv      *Server
	mu       sync.Mutex
	state    *scoutState
	models   []map[string]any
	modelsAt time.Time
	cancels  map[string]context.CancelFunc
}

type scoutState struct {
	Config   scoutConfig     `json:"config"`
	Active   string          `json:"session_id"`
	Sessions []*scoutSession `json:"sessions"`
}

type scoutConfig struct {
	Provider          string           `json:"provider"`
	Model             string           `json:"model"`
	ThinkingLevel     string           `json:"thinking_level"`
	CLI               string           `json:"cli"`
	BaseURL           string           `json:"base_url,omitempty"`
	APIKey            string           `json:"api_key,omitempty"`
	AllowedWorkspaces []map[string]any `json:"allowed_workspaces"`
}

type scoutSession struct {
	ID       string         `json:"id"`
	Title    string         `json:"title"`
	Updated  time.Time      `json:"updated_at"`
	Messages []scoutMessage `json:"messages"`
	CLIState string         `json:"cli_state,omitempty"`
	Running  bool           `json:"-"`
}

type scoutMessage struct {
	Role string `json:"role"`
	Text string `json:"text"`
}

func NewScout(srv *Server) *Scout {
	r := &Scout{srv: srv, cancels: map[string]context.CancelFunc{}}
	// one-time move of legacy omp session dirs into the per-CLI layout
	legacy := filepath.Join(srv.cfg.StateDir, "ranger")
	scout := filepath.Join(srv.cfg.StateDir, "scout")
	if _, err := os.Stat(scout); os.IsNotExist(err) {
		if _, err := os.Stat(legacy); err == nil {
			_ = os.MkdirAll(scout, 0o700)
			_ = os.Rename(legacy, filepath.Join(scout, "omp"))
		}
	}
	r.state = r.loadState()
	return r
}

func (r *Scout) statePath() string {
	return filepath.Join(r.srv.cfg.StateDir, "scout.json")
}

func (r *Scout) loadState() *scoutState {
	state := &scoutState{}
	if data, err := os.ReadFile(r.statePath()); err == nil {
		_ = json.Unmarshal(data, state)
	} else if data, err := os.ReadFile(filepath.Join(r.srv.cfg.StateDir, "ranger.json")); err == nil {
		// legacy state from before the Scout rename
		_ = json.Unmarshal(data, state)
	}
	if state.Active == "" || state.session(state.Active) == nil {
		r.ensureSession(state)
	}
	return state
}

func (r *Scout) saveLocked() {
	data, err := json.MarshalIndent(r.state, "", "  ")
	if err != nil {
		return
	}
	tmp := r.statePath() + ".tmp"
	if os.WriteFile(tmp, data, 0o600) == nil {
		_ = os.Rename(tmp, r.statePath())
	}
}

func (r *Scout) ensureSession(state *scoutState) *scoutSession {
	id, _ := randomToken(12)
	sess := &scoutSession{ID: id, Title: "New chat", Updated: time.Now().UTC()}
	state.Sessions = append([]*scoutSession{sess}, state.Sessions...)
	state.Active = id
	return sess
}

func (s *scoutState) session(id string) *scoutSession {
	for _, sess := range s.Sessions {
		if sess.ID == id {
			return sess
		}
	}
	return nil
}

func (r *Scout) Handle(ctx context.Context, method string, p map[string]any) (any, error) {
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
	case "bridge.assistant.delete_session":
		return r.DeleteSession(asString(p, "session_id"))
	case "bridge.assistant.stop":
		return r.Stop(asString(p, "session_id"))
	}
	return nil, fmt.Errorf("unknown assistant method: %s", method)
}

func (r *Scout) Get(ctx context.Context) map[string]any {
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

func (r *Scout) configJSON() map[string]any {
	r.mu.Lock()
	defer r.mu.Unlock()
	cli := r.state.Config.CLI
	if cli == "" {
		cli = "omp"
	}
	return map[string]any{
		"provider":           r.state.Config.Provider,
		"model":              r.state.Config.Model,
		"thinking_level":     r.state.Config.ThinkingLevel,
		"cli":                cli,
		"base_url":           r.state.Config.BaseURL,
		"allowed_workspaces": r.state.Config.AllowedWorkspaces,
	}
}

func (r *Scout) allWorkspaces(ctx context.Context) []map[string]any {
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

func (r *Scout) Configure(p map[string]any) (any, error) {
	cli := asString(p, "cli")
	if cli == "" {
		cli = "omp"
	}
	if _, ok := findAssistantCLI(cli); !ok {
		return nil, fmt.Errorf("unknown assistant CLI %q", cli)
	}
	model := asString(p, "model")
	if model == "" {
		return nil, errors.New("model is required")
	}
	provider := asString(p, "provider")
	if provider == "" {
		provider = "custom"
	}
	baseURL := asString(p, "base_url")
	if cli == "openai" && baseURL == "" {
		return nil, errors.New("base_url is required for the openai driver")
	}
	r.mu.Lock()
	r.state.Config.Provider = provider
	r.state.Config.Model = model
	r.state.Config.ThinkingLevel = asString(p, "thinking_level")
	r.state.Config.CLI = cli
	r.state.Config.BaseURL = baseURL
	if key := asString(p, "api_key"); key != "" {
		r.state.Config.APIKey = key
	}
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

func (r *Scout) NewSession() (any, error) {
	r.mu.Lock()
	sess := r.ensureSession(r.state)
	r.saveLocked()
	r.mu.Unlock()
	return map[string]any{"session_id": sess.ID}, nil
}

func (r *Scout) Select(id string) (any, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.state.session(id) == nil {
		return nil, errors.New("session not found")
	}
	r.state.Active = id
	r.saveLocked()
	return map[string]any{"session_id": id}, nil
}

// Stop cancels the in-flight CLI run for a session. The run's completion
// path clears Running and pushes a fresh snapshot to all clients.
func (r *Scout) Stop(sessionID string) (any, error) {
	if sessionID == "" {
		return nil, errors.New("session_id is required")
	}
	r.mu.Lock()
	cancel, ok := r.cancels[sessionID]
	r.mu.Unlock()
	if !ok {
		return map[string]any{"stopped": false}, nil
	}
	cancel()
	return map[string]any{"stopped": true}, nil
}

// DeleteSession removes a chat and its bridge-side CLI session dirs. The
// pi/omp transcripts inside the agent's own store are left in place.
func (r *Scout) DeleteSession(id string) (any, error) {
	if id == "" {
		return nil, errors.New("session_id is required")
	}
	r.mu.Lock()
	kept := make([]*scoutSession, 0, len(r.state.Sessions))
	var removed *scoutSession
	for _, sess := range r.state.Sessions {
		if sess.ID == id {
			removed = sess
			continue
		}
		kept = append(kept, sess)
	}
	if removed == nil {
		r.mu.Unlock()
		return nil, errors.New("session not found")
	}
	r.state.Sessions = kept
	if r.state.Active == id {
		r.state.Active = ""
	}
	if r.state.Active == "" || r.state.session(r.state.Active) == nil {
		if len(r.state.Sessions) > 0 {
			r.state.Active = r.state.Sessions[0].ID
		} else {
			r.ensureSession(r.state)
		}
	}
	r.saveLocked()
	snapshot := r.snapshotLocked()
	r.mu.Unlock()
	// drop per-CLI session dirs for every known driver
	for _, cli := range assistantCLIs {
		_ = os.RemoveAll(sessionDirFor(r.srv.cfg.StateDir, cli.name, id))
	}
	r.push(snapshot)
	return map[string]any{"session_id": id}, nil
}

func (r *Scout) Send(ctx context.Context, p map[string]any) (any, error) {
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
		return nil, errors.New("Scout is already running this session")
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
	sess.Messages = append(sess.Messages, scoutMessage{Role: "user", Text: text})
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

func (r *Scout) snapshotLocked() map[string]any {
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

func (r *Scout) configLocked() map[string]any {
	cli := r.state.Config.CLI
	if cli == "" {
		cli = "omp"
	}
	return map[string]any{
		"provider":           r.state.Config.Provider,
		"model":              r.state.Config.Model,
		"thinking_level":     r.state.Config.ThinkingLevel,
		"cli":                cli,
		"base_url":           r.state.Config.BaseURL,
		"allowed_workspaces": r.state.Config.AllowedWorkspaces,
	}
}

func (r *Scout) push(snapshot map[string]any) {
	r.srv.notifyAll(map[string]any{"assistant": snapshot})
}

func (r *Scout) run(sessionID, text string, cfg scoutConfig) {
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Minute)
	defer cancel()
	r.mu.Lock()
	r.cancels[sessionID] = cancel
	r.mu.Unlock()
	r.mu.Lock()
	sess := r.state.session(sessionID)
	var history []scoutMessage
	cliState := ""
	if sess != nil {
		history = append([]scoutMessage(nil), sess.Messages...)
		cliState = sess.CLIState
	}
	r.mu.Unlock()
	answer, newState, err := r.invoke(ctx, sessionID, text, cfg, history, cliState)
	canceled := ctx.Err() == context.Canceled
	r.mu.Lock()
	delete(r.cancels, sessionID)
	sess = r.state.session(sessionID)
	if sess != nil {
		sess.Running = false
		if newState != "" {
			sess.CLIState = newState
		}
		if canceled {
			// user stopped the run: clear running, leave no answer
		} else if err != nil {
			sess.Messages = append(sess.Messages, scoutMessage{Role: "assistant", Text: "Scout failed: " + err.Error()})
		} else if answer != "" {
			sess.Messages = append(sess.Messages, scoutMessage{Role: "assistant", Text: answer})
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
	if canceled {
		return
	}
	if err != nil {
		r.srv.notifyAll(map[string]any{"assistant_notification": map[string]any{
			"title": "Scout failed", "body": err.Error(),
		}})
	} else {
		r.srv.notifyAll(map[string]any{"assistant_notification": map[string]any{
			"title": "Scout finished", "body": truncate(answer, 140),
		}})
	}
}

func (r *Scout) invoke(ctx context.Context, sessionID, text string, cfg scoutConfig, history []scoutMessage, cliState string) (string, string, error) {
	cliName := cfg.CLI
	if cliName == "" {
		cliName = "omp"
	}
	cli, ok := findAssistantCLI(cliName)
	if !ok {
		return "", "", fmt.Errorf("unknown assistant CLI %q", cliName)
	}
	snap, err := r.srv.snapshot(ctx)
	if err != nil {
		return "", "", err
	}
	var roots []string
	var workspaceIDs []string
	rootByID := map[string]string{}
	for _, ref := range cfg.AllowedWorkspaces {
		if asString(ref, "connection_id") != "" && asString(ref, "connection_id") != "local" {
			continue
		}
		id := asString(ref, "workspace_id")
		if root := snap.WorkspaceRoot(id); root != "" {
			roots = append(roots, root)
			workspaceIDs = append(workspaceIDs, id)
			rootByID[id] = root
		}
	}
	// Scout works on the workspace the user is actually looking at: the focused
	// herdr workspace wins as cwd; the rest become additional allowed dirs.
	cwd := r.srv.cfg.StateDir
	var extra []string
	if len(roots) > 0 {
		cwd = roots[0]
		if focusedRoot := rootByID[snap.FocusedWorkspaceID]; focusedRoot != "" {
			cwd = focusedRoot
		}
		for _, root := range roots {
			if root != cwd {
				extra = append(extra, root)
			}
		}
	}
	sessionDir := sessionDirFor(r.srv.cfg.StateDir, cliName, sessionID)
	// CLI drivers (omp/pi) have no workspace tools, so hand them ground truth
	// about which herdr workspace is focused instead of letting them guess.
	if cliName != "openai" {
		text = scoutWorkspaceContext(snap, cwd, roots) + "\n\n" + text
	}
	iv := assistantInvoke{
		ctx:          ctx,
		cli:          cli,
		sessionDir:   sessionDir,
		hasSession:   hasSessionFile(sessionDir),
		state:        cliState,
		text:         text,
		modelRef:     cfg.Provider + "/" + cfg.Model,
		modelID:      cfg.Model,
		thinking:     cfg.ThinkingLevel,
		cwd:          cwd,
		extraDirs:    extra,
		endpoint:     cfg.BaseURL,
		apiKey:       cfg.APIKey,
		history:      history,
		srv:          r.srv,
		workspaceIDs: workspaceIDs,
	}
	return runAssistant(iv)
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

// scoutWorkspaceContext renders a compact snapshot of herdr workspaces for
// CLI drivers that cannot call workspace tools themselves.
func scoutWorkspaceContext(snap *Snapshot, cwd string, roots []string) string {
	var b strings.Builder
	b.WriteString("[Droves context — live herdr snapshot]")
	if w := snap.Workspace(snap.FocusedWorkspaceID); w != nil {
		root := snap.WorkspaceRoot(w.WorkspaceID)
		allowed := false
		for _, r := range roots {
			if r == root {
				allowed = true
				break
			}
		}
		if allowed {
			fmt.Fprintf(&b, " Focused workspace: %s (%q), root %s — this is your working directory.", w.WorkspaceID, w.Label, root)
		} else {
			fmt.Fprintf(&b, " The user is focused on workspace %s (%q), but it is outside Scout's allowed workspaces, so you cannot work there.", w.WorkspaceID, w.Label)
		}
	} else {
		b.WriteString(" No workspace is focused right now.")
	}
	fmt.Fprintf(&b, " Your working directory is %s.", cwd)
	if len(roots) > 1 {
		b.WriteString(" Allowed workspace roots:")
		for _, root := range roots {
			fmt.Fprintf(&b, " %s", root)
		}
		b.WriteString(".")
	}
	b.WriteString(" The focus can change while you work; trust this snapshot, not memory.")
	return b.String()
}

func parseScoutOutput(data []byte) string {
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

// scoutCLIErrorText turns a failed CLI run's stdout into a readable error.
// JSON-mode drivers (omp, pi) print session JSONL on stdout even when the
// run fails, so a raw dump would leak event noise into the chat; extract the
// provider's error message instead. Plain-text stdout passes through.
func scoutCLIErrorText(stdout []byte) string {
	trimmed := strings.TrimSpace(string(stdout))
	if trimmed == "" {
		return ""
	}
	if !strings.HasPrefix(trimmed, "{") {
		return trimmed
	}
	// JSONL: hunt for an errorMessage/error field in any event
	sc := bufio.NewScanner(bytes.NewReader(stdout))
	sc.Buffer(make([]byte, 64*1024), 16*1024*1024)
	var last string
	for sc.Scan() {
		var ev map[string]any
		if json.Unmarshal(sc.Bytes(), &ev) != nil {
			continue
		}
		for _, key := range []string{"errorMessage", "error", "message"} {
			if s, ok := ev[key].(string); ok && strings.TrimSpace(s) != "" {
				last = s
			}
		}
		// omp nests the error inside the assistant message object
		if m, ok := ev["message"].(map[string]any); ok {
			for _, key := range []string{"errorMessage", "error"} {
				if s, ok := m[key].(string); ok && strings.TrimSpace(s) != "" {
					last = s
				}
			}
		}
	}
	if last != "" {
		return last
	}
	return "the assistant CLI failed without an error message"
}

func (r *Scout) Models(ctx context.Context) []map[string]any {
	r.mu.Lock()
	if len(r.models) > 0 && time.Since(r.modelsAt) < 10*time.Minute {
		out := r.models
		r.mu.Unlock()
		return out
	}
	r.mu.Unlock()
	models := assistantModels(ctx)
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
