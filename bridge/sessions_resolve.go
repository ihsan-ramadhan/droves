package main

import (
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
)

// normalizeAgentName maps herdr agent labels and CLI aliases to the canonical
// parser key used by recordParserFor and resolveSessionFile.
func normalizeAgentName(name string) string {
	switch strings.ToLower(strings.TrimSpace(name)) {
	case "claude", "claude-code":
		return "claude"
	case "pi", "pi-agent", "pi-coding-agent":
		return "pi"
	case "omp", "oh-my-pi":
		return "omp"
	case "codex":
		return "codex"
	case "grok", "grok-build":
		return "grok"
	case "kimi", "kimi-code":
		return "kimi"
	case "muse", "muse-code":
		return "muse"
	case "agy", "antigravity", "antigravity-cli":
		return "agy"
	case "jcode", "j-code":
		return "jcode"
	default:
		return strings.ToLower(strings.TrimSpace(name))
	}
}

// resolveCache memoizes id→path lookups; session files are immutable once a
// session ends and the path of a live session does not change.
var resolveCache sync.Map // key: agent|root|id → path

func cachedResolve(key string) (string, bool) {
	if v, ok := resolveCache.Load(key); ok {
		return v.(string), true
	}
	return "", false
}

func cacheResolve(key, path string) {
	resolveCache.Store(key, path)
}

// validSessionID rejects values that could escape the search root.
func validSessionID(id string) bool {
	return id != "" && id != "." && id != ".." && !strings.ContainsAny(id, `/\`+"\x00")
}

// newestJSONL returns the most recently modified file whose base name matches
// want among files walked under root.
func newestJSONL(root string, want func(base string) bool) (string, error) {
	var best string
	var bestMod int64
	err := filepath.WalkDir(root, func(path string, d os.DirEntry, err error) error {
		if err != nil {
			return nil // skip unreadable subtrees
		}
		if d.IsDir() || !strings.HasSuffix(path, ".jsonl") {
			return nil
		}
		if !want(d.Name()) {
			return nil
		}
		st, err := d.Info()
		if err != nil {
			return nil
		}
		if best == "" || st.ModTime().UnixNano() > bestMod {
			best, bestMod = path, st.ModTime().UnixNano()
		}
		return nil
	})
	if err != nil {
		return "", err
	}
	return best, nil
}

// sortedJSONLFiles lists *.jsonl under root sorted by mod time, newest first.
func sortedJSONLFiles(root string) ([]string, error) {
	var files []string
	err := filepath.WalkDir(root, func(path string, d os.DirEntry, err error) error {
		if err != nil {
			return nil
		}
		if !d.IsDir() && strings.HasSuffix(path, ".jsonl") {
			files = append(files, path)
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	type fi struct {
		path string
		mod  int64
	}
	infos := make([]fi, 0, len(files))
	for _, p := range files {
		if st, err := os.Stat(p); err == nil {
			infos = append(infos, fi{p, st.ModTime().UnixNano()})
		}
	}
	sort.Slice(infos, func(i, j int) bool { return infos[i].mod > infos[j].mod })
	out := make([]string, len(infos))
	for i, f := range infos {
		out[i] = f.path
	}
	return out, nil
}

// resolveSessionFile maps a herdr session id to a transcript path for agents
// whose hooks report kind="id" instead of kind="path". Returns "" when the
// agent has no resolver or the file cannot be found.
func resolveSessionFile(agent, id, cwd string) string {
	if !validSessionID(id) {
		return ""
	}
	switch normalizeAgentName(agent) {
	case "claude":
		return resolveClaudeSession(id)
	case "codex":
		p, _ := resolveCodexSession(id, cwd)
		return p
	case "grok":
		p, _ := resolveGrokSession(id, cwd)
		return p
	case "kimi":
		p, _ := resolveKimiSession(id, cwd)
		return p
	case "pi":
		return resolvePiSession(id)
	case "omp":
		return resolveOmpSession(id)
	case "jcode":
		if path := jcodeSessionPath(id); path != "" {
			return path
		}
		return recentJcodeSession(cwd)
	}
	return ""
}

func claudeProjectsRoot() string {
	if dir := os.Getenv("CLAUDE_CONFIG_DIR"); dir != "" {
		return filepath.Join(dir, "projects")
	}
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".claude", "projects")
}

// resolveClaudeSession finds ~/.claude/projects/**/<id>.jsonl (cwd-slug dirs).
func resolveClaudeSession(id string) string {
	key := "claude|" + claudeProjectsRoot() + "|" + id
	if p, ok := cachedResolve(key); ok {
		return p
	}
	root := claudeProjectsRoot()
	path, err := newestJSONL(root, func(base string) bool {
		return base == id+".jsonl"
	})
	if err != nil || path == "" {
		return ""
	}
	cacheResolve(key, path)
	return path
}

func piSessionsRoots() []string {
	var roots []string
	if dir := os.Getenv("PI_CODING_AGENT_DIR"); dir != "" {
		roots = append(roots, filepath.Join(dir, "sessions"))
	}
	home, _ := os.UserHomeDir()
	roots = append(roots, filepath.Join(home, ".pi", "agent", "sessions"))
	return roots
}

// resolvePiSession finds <ts>_<id>.jsonl or <id>.jsonl under pi session roots.
func resolvePiSession(id string) string {
	for _, root := range piSessionsRoots() {
		key := "pi|" + root + "|" + id
		if p, ok := cachedResolve(key); ok {
			if p != "" {
				return p
			}
			continue
		}
		path, err := newestJSONL(root, func(base string) bool {
			return base == id+".jsonl" || strings.HasSuffix(base, "_"+id+".jsonl")
		})
		if err == nil && path != "" {
			cacheResolve(key, path)
			return path
		}
	}
	return ""
}

func ompSessionsRoots() []string {
	var roots []string
	home, _ := os.UserHomeDir()
	roots = append(roots, filepath.Join(home, ".omp", "agent", "sessions"))
	if xdg := os.Getenv("XDG_DATA_HOME"); xdg != "" {
		roots = append(roots, filepath.Join(xdg, "omp", "sessions"))
	}
	return roots
}

// resolveOmpSession mirrors resolvePiSession for omp session roots.
func resolveOmpSession(id string) string {
	for _, root := range ompSessionsRoots() {
		key := "omp|" + root + "|" + id
		if p, ok := cachedResolve(key); ok {
			if p != "" {
				return p
			}
			continue
		}
		path, err := newestJSONL(root, func(base string) bool {
			return base == id+".jsonl" || strings.HasSuffix(base, "_"+id+".jsonl")
		})
		if err == nil && path != "" {
			cacheResolve(key, path)
			return path
		}
	}
	return ""
}
