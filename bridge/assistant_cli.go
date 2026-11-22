package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

// assistantCLI is one headless coding agent the Scout assistant can drive.
// CLI drivers shell out to the agent's own print mode; the "openai" driver
// talks to any OpenAI-compatible chat endpoint directly and keeps history in
// scout.json, so it needs no CLI session files at all.
type assistantCLI struct {
	name string
	bin  string // env var overriding the default binary name
	dflt string
}

// registry of supported drivers; order defines picker grouping
var assistantCLIs = []assistantCLI{
	{name: "omp", bin: "OMP_BIN", dflt: "omp"},
	{name: "pi", bin: "PI_BIN", dflt: "pi"},
	{name: "openai", bin: "", dflt: ""}, // HTTP endpoint, no binary
}

func (c assistantCLI) binary() (string, error) {
	if c.dflt == "" {
		return "", errors.New("openai driver has no binary")
	}
	name := envOr(c.bin, c.dflt)
	path, err := exec.LookPath(name)
	if err != nil {
		return "", fmt.Errorf("%s is not installed on the bridge host", c.name)
	}
	return path, nil
}

func findAssistantCLI(name string) (assistantCLI, bool) {
	for _, c := range assistantCLIs {
		if c.name == name {
			return c, true
		}
	}
	return assistantCLI{}, false
}

// assistantInvoke describes one headless run; adapters translate it into argv
// or an HTTP request. state is the CLI-specific session handle captured from
// the previous run; history is the Scout transcript for stateless drivers.
type assistantInvoke struct {
	ctx          context.Context
	cli          assistantCLI
	sessionDir   string // per Scout session, adapter-owned layout inside
	hasSession   bool   // a previous run left resumable state in sessionDir
	state        string // CLI session id captured from the previous run
	text         string
	modelRef     string // provider/id as configured
	modelID      string // bare model id for endpoint drivers
	thinking     string
	cwd          string
	extraDirs    []string
	endpoint     string // openai driver: base URL
	apiKey       string // openai driver: bearer token, may be empty
	history      []scoutMessage
	srv          *Server  // bridge internals for workspace-read tools (openai driver)
	workspaceIDs []string // allowed workspace ids; empty means all
}

// runAssistant executes the driver and returns the answer plus any new
// CLI session state to persist on the Scout session.
func runAssistant(iv assistantInvoke) (answer, newState string, err error) {
	if iv.cli.name == "openai" {
		return runOpenAI(iv)
	}
	bin, err := iv.cli.binary()
	if err != nil {
		return "", "", err
	}
	args := assistantArgv(iv)
	cmd := exec.CommandContext(iv.ctx, bin, args...)
	cmd.Dir = iv.cwd
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	err = cmd.Run()
	if iv.ctx.Err() != nil {
		return "", "", errors.New("Scout timed out")
	}
	answer = parseScoutOutput(stdout.Bytes())
	newState = extractScoutState(iv.cli.name, stdout.Bytes(), iv.state)
	if err != nil {
		msg := strings.TrimSpace(stderr.String())
		if msg == "" {
			msg = scoutCLIErrorText(stdout.Bytes())
		}
		if answer == "" && msg != "" {
			return "", newState, errors.New(truncate(msg, 2000))
		}
		if answer == "" {
			return "", newState, err
		}
	}
	if answer == "" {
		return "", newState, errors.New("Scout returned no answer")
	}
	return answer, newState, nil
}

// assistantArgv builds argv per CLI driver.
func assistantArgv(iv assistantInvoke) []string {
	switch iv.cli.name {
	case "omp":
		return ompArgv(iv)
	case "pi":
		return piArgv(iv)
	default:
		return nil
	}
}

func ompArgv(iv assistantInvoke) []string {
	args := []string{"-p", "--mode=json", "--no-title", "--auto-approve", "--max-time=12m",
		"--model", iv.modelRef}
	if iv.thinking != "" {
		args = append(args, "--thinking", iv.thinking)
	}
	if iv.cwd != "" {
		for _, dir := range iv.extraDirs {
			args = append(args, "--add-dir", dir)
		}
	}
	if err := os.MkdirAll(iv.sessionDir, 0o700); err == nil {
		args = append(args, "--session-dir", iv.sessionDir)
		if hasSessionFile(iv.sessionDir) {
			args = append(args, "--continue")
		}
	}
	return append(args, iv.text)
}

func piArgv(iv assistantInvoke) []string {
	args := []string{"-p", "--mode", "json", "--model", iv.modelRef}
	if iv.thinking != "" {
		args = append(args, "--thinking", iv.thinking)
	}
	// pi has no --add-dir; extra workspace roots are ignored for now
	if iv.state != "" {
		args = append(args, "--session", iv.state)
	}
	return append(args, iv.text)
}

// extractScoutState pulls the CLI session id out of JSONL output so the next
// run can resume it. omp keeps state in session files, so it needs none.
func extractScoutState(cli string, stdout []byte, prev string) string {
	switch cli {
	case "pi":
		sc := bufio.NewScanner(bytes.NewReader(stdout))
		sc.Buffer(make([]byte, 64*1024), 4*1024*1024)
		for sc.Scan() {
			var ev struct {
				Type string `json:"type"`
				ID   string `json:"id"`
			}
			if json.Unmarshal(sc.Bytes(), &ev) == nil && ev.Type == "session" && ev.ID != "" {
				return ev.ID
			}
		}
	}
	return prev
}

// OpenAI chat message shapes; ToolCalls/ToolCallID stay empty for plain text.
type oaiToolCall struct {
	ID       string `json:"id"`
	Type     string `json:"type"`
	Function struct {
		Name      string `json:"name"`
		Arguments string `json:"arguments"`
	} `json:"function"`
}

type oaiMessage struct {
	Role       string        `json:"role"`
	Content    string        `json:"content,omitempty"`
	ToolCalls  []oaiToolCall `json:"tool_calls,omitempty"`
	ToolCallID string        `json:"tool_call_id,omitempty"`
}

const openAIMaxToolRounds = 25

// runOpenAI drives any OpenAI-compatible chat endpoint with workspace tools.
// History lives in scout.json, so every call is stateless and self-contained;
// the tool loop runs inside this single invocation.
func runOpenAI(iv assistantInvoke) (string, string, error) {
	if iv.endpoint == "" {
		return "", "", errors.New("openai driver needs a base URL")
	}
	if iv.modelID == "" {
		return "", "", errors.New("openai driver needs a model")
	}
	messages := []oaiMessage{{Role: "system", Content: openAISystemPrompt(iv)}}
	for _, m := range iv.history {
		role := "assistant"
		if m.Role == "user" {
			role = "user"
		}
		messages = append(messages, oaiMessage{Role: role, Content: m.Text})
	}
	tools := scoutOpenAITools()
	tc := newScoutToolContext(iv)
	url := strings.TrimRight(iv.endpoint, "/") + "/chat/completions"
	client := &http.Client{Timeout: 12 * time.Minute}

	for range openAIMaxToolRounds {
		bodyMap := map[string]any{
			"model":    iv.modelID,
			"messages": messages,
			"stream":   false,
		}
		if tools != nil {
			bodyMap["tools"] = tools
			bodyMap["tool_choice"] = "auto"
		}
		body, err := json.Marshal(bodyMap)
		if err != nil {
			return "", "", err
		}
		req, err := http.NewRequestWithContext(iv.ctx, http.MethodPost, url, bytes.NewReader(body))
		if err != nil {
			return "", "", err
		}
		req.Header.Set("Content-Type", "application/json")
		if iv.apiKey != "" {
			req.Header.Set("Authorization", "Bearer "+iv.apiKey)
		}
		resp, err := client.Do(req)
		if err != nil {
			return "", "", err
		}
		data, err := io.ReadAll(io.LimitReader(resp.Body, 32<<20))
		resp.Body.Close()
		if err != nil {
			return "", "", err
		}
		if resp.StatusCode != http.StatusOK {
			msg := strings.TrimSpace(string(data))
			if len(msg) > 500 {
				msg = msg[:500]
			}
			// endpoints without tool support reject the tools field; fall back
			// to plain chat once instead of failing the whole turn
			if tools != nil && resp.StatusCode == http.StatusBadRequest &&
				(strings.Contains(strings.ToLower(msg), "tool") || strings.Contains(strings.ToLower(msg), "function")) {
				tools = nil
				continue
			}
			return "", "", fmt.Errorf("endpoint returned %d: %s", resp.StatusCode, msg)
		}
		var out struct {
			Choices []struct {
				Message oaiMessage `json:"message"`
			} `json:"choices"`
			Error *struct {
				Message string `json:"message"`
			} `json:"error"`
		}
		if json.Unmarshal(data, &out) != nil {
			return "", "", errors.New("endpoint returned invalid JSON")
		}
		if out.Error != nil && out.Error.Message != "" {
			return "", "", errors.New(truncate(out.Error.Message, 500))
		}
		if len(out.Choices) == 0 {
			return "", "", errors.New("endpoint returned no choices")
		}
		msg := out.Choices[0].Message
		if len(msg.ToolCalls) == 0 {
			answer := strings.TrimSpace(msg.Content)
			if answer == "" {
				return "", "", errors.New("Scout returned no answer")
			}
			return answer, "", nil
		}
		// echo the assistant turn with its tool calls, then answer each call
		messages = append(messages, msg)
		for _, call := range msg.ToolCalls {
			var args json.RawMessage
			if call.Function.Arguments != "" {
				args = json.RawMessage(call.Function.Arguments)
			}
			result := callScoutTool(tc, call.Function.Name, args)
			messages = append(messages, oaiMessage{
				Role:       "tool",
				ToolCallID: call.ID,
				Content:    result,
			})
		}
	}
	return "", "", errors.New("Scout exceeded the tool-call limit")
}

func openAISystemPrompt(iv assistantInvoke) string {
	var b strings.Builder
	b.WriteString("You are Scout, a coding assistant running on the user's machine via the Droves bridge. " +
		"Use the provided tools to inspect and change the workspace: read_file, list_dir, write_file, run_command. " +
		"You can also inspect the Droves workspace itself: workspace_status lists workspaces, panes and agents; " +
		"agent_history reads an agent's transcript; workspace_diff shows git changes; terminal_output reads pane output. " +
		"Paths are relative to the working directory; absolute paths must stay inside the allowed roots. " +
		"Verify your work with tools before claiming success. Keep final answers concise.")
	if iv.cwd != "" && iv.cwd != iv.sessionDir {
		fmt.Fprintf(&b, " Working directory: %s.", iv.cwd)
	}
	if len(iv.extraDirs) > 0 {
		fmt.Fprintf(&b, " Additional allowed directories: %s.", strings.Join(iv.extraDirs, ", "))
	}
	return b.String()
}

// assistantModels aggregates model catalogs across installed drivers.
// Each entry carries cli/provider/id/label/thinking_levels for the picker.
func assistantModels(ctx context.Context) []map[string]any {
	var out []map[string]any
	for _, cli := range assistantCLIs {
		if cli.name == "openai" {
			continue // custom endpoints have no catalog; the client adds them manually
		}
		if _, err := cli.binary(); err != nil {
			continue
		}
		models := cliModels(ctx, cli)
		for _, m := range models {
			m["cli"] = cli.name
		}
		out = append(out, models...)
	}
	return out
}

func cliModels(ctx context.Context, cli assistantCLI) []map[string]any {
	switch cli.name {
	case "omp":
		return ompModels(ctx, cli)
	case "pi":
		return piModels(ctx, cli)
	}
	return nil
}

func ompModels(ctx context.Context, cli assistantCLI) []map[string]any {
	bin, err := cli.binary()
	if err != nil {
		return []map[string]any{}
	}
	cctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	out, err := exec.CommandContext(cctx, bin, "models", "--json").Output()
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
	return models
}

// piModels parses `pi --list-models`: a fixed-width table with columns
// provider, model, context, max-out, thinking, images.
func piModels(ctx context.Context, cli assistantCLI) []map[string]any {
	bin, err := cli.binary()
	if err != nil {
		return []map[string]any{}
	}
	cctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	out, err := exec.CommandContext(cctx, bin, "--list-models").Output()
	if err != nil {
		return []map[string]any{}
	}
	var models []map[string]any
	for _, line := range strings.Split(string(out), "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "provider") {
			continue
		}
		fields := strings.Fields(line)
		if len(fields) < 2 {
			continue
		}
		provider, modelID := fields[0], fields[1]
		thinking := []string{}
		// positional columns: provider model context max-out thinking images
		if len(fields) >= 5 && fields[4] == "yes" {
			thinking = []string{"low", "medium", "high"}
		}
		models = append(models, map[string]any{
			"provider": provider, "id": modelID, "label": provider + "/" + modelID,
			"thinking_levels": thinking,
		})
	}
	return models
}

// sessionDirFor returns the adapter-owned session directory for one Scout session.
func sessionDirFor(stateDir, cliName, sessionID string) string {
	return filepath.Join(stateDir, "scout", cliName, sessionID)
}
