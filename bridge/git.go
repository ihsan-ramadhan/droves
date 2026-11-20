package main

import (
	"bufio"
	"bytes"
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"
)

type diffEntry struct {
	Path      string `json:"path"`
	OldPath   string `json:"old_path,omitempty"`
	Kind      string `json:"kind"`
	Additions int    `json:"additions"`
	Deletions int    `json:"deletions"`
}

func gitRun(ctx context.Context, root string, args ...string) (string, error) {
	cctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	cmd := exec.CommandContext(cctx, "git", args...)
	cmd.Dir = root
	cmd.Env = append(os.Environ(), "GIT_TERMINAL_PROMPT=0", "LC_ALL=C", "GIT_PAGER=cat")
	var out, stderr bytes.Buffer
	cmd.Stdout = &out
	cmd.Stderr = &stderr
	err := cmd.Run()
	if err != nil {
		msg := strings.TrimSpace(stderr.String())
		if msg == "" {
			msg = err.Error()
		}
		return out.String(), errors.New(msg)
	}
	return out.String(), nil
}

func (s *Server) gitRoot(ctx context.Context, p map[string]any) (string, error) {
	root, err := s.workspaceRoot(ctx, asString(p, "workspace_id"))
	if err != nil {
		return "", err
	}
	if _, err := gitRun(ctx, root, "rev-parse", "--show-toplevel"); err != nil {
		return "", fmt.Errorf("%s is not a git checkout", root)
	}
	return root, nil
}

func (s *Server) gitDiffSummary(ctx context.Context, p map[string]any) (any, error) {
	root, err := s.gitRoot(ctx, p)
	if err != nil {
		return nil, err
	}
	status, err := gitRun(ctx, root, "status", "--porcelain=v1", "--untracked-files=all")
	if err != nil {
		return nil, err
	}
	entries := map[string]*diffEntry{}
	counts := map[string]int{"staged": 0, "unstaged": 0, "untracked": 0, "conflicted": 0}
	sc := bufio.NewScanner(strings.NewReader(status))
	sc.Buffer(make([]byte, 64*1024), 4*1024*1024)
	for sc.Scan() {
		line := sc.Text()
		if len(line) < 4 {
			continue
		}
		x, y := line[0], line[1]
		path := line[3:]
		oldPath := ""
		if i := strings.Index(path, " -> "); i >= 0 {
			oldPath = path[:i]
			path = path[i+4:]
		}
		kind := "unstaged"
		switch {
		case x == '?' && y == '?':
			kind = "untracked"
		case strings.ContainsRune("U", rune(x)) || strings.ContainsRune("U", rune(y)) || (x == 'A' && y == 'A') || (x == 'D' && y == 'D'):
			kind = "conflicted"
		case x != ' ':
			kind = "staged"
		}
		e := entries[path]
		if e == nil {
			e = &diffEntry{Path: path, OldPath: oldPath, Kind: kind}
			entries[path] = e
		} else if kind == "conflicted" {
			e.Kind = kind
		} else if e.Kind == "untracked" && kind == "staged" {
			e.Kind = kind
		}
	}
	addStats := func(kind string, lines string) {
		for _, line := range strings.Split(lines, "\n") {
			fields := strings.SplitN(line, "\t", 3)
			if len(fields) != 3 {
				continue
			}
			path := fields[2]
			if i := strings.Index(path, " => "); i >= 0 {
				path = strings.Trim(path[i+4:], "{}")
			}
			e := entries[path]
			if e == nil {
				continue
			}
			if kind == "staged" && e.Kind != "staged" {
				continue
			}
			if fields[0] != "-" {
				e.Additions, _ = strconv.Atoi(fields[0])
			}
			if fields[1] != "-" {
				e.Deletions, _ = strconv.Atoi(fields[1])
			}
		}
	}
	if out, err := gitRun(ctx, root, "diff", "--numstat", "--cached"); err == nil {
		addStats("staged", out)
	}
	if out, err := gitRun(ctx, root, "diff", "--numstat"); err == nil {
		addStats("unstaged", out)
	}
	out := make([]diffEntry, 0, len(entries))
	for _, e := range entries {
		if e.Kind == "untracked" {
			if data, err := os.ReadFile(filepath.Join(root, e.Path)); err == nil {
				e.Additions = bytes.Count(data, []byte{'\n'})
				if len(data) > 0 && data[len(data)-1] != '\n' {
					e.Additions++
				}
				e.Deletions = 0
			}
		}
		counts[e.Kind]++
		out = append(out, *e)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Path < out[j].Path })
	repo := filepath.Base(root)
	return map[string]any{
		"entries":   out,
		"counts":    counts,
		"repo_name": repo,
		"root":      root,
	}, nil
}

func (s *Server) gitDiffFile(ctx context.Context, p map[string]any) (any, error) {
	root, err := s.gitRoot(ctx, p)
	if err != nil {
		return nil, err
	}
	path := asString(p, "path")
	if path == "" {
		return nil, errors.New("path is required")
	}
	if _, err := safeRel(root, path); err != nil {
		return nil, err
	}
	kind := asString(p, "kind")
	switch asString(p, "mode") {
	case "commit":
		sha := asString(p, "commit")
		if !validGitRef(sha) {
			return nil, errors.New("invalid commit")
		}
		out, err := gitRun(ctx, root, "show", "--format=", "--no-color", "--no-ext-diff", "--find-renames", "--unified=3", sha, "--", path)
		if err != nil {
			return nil, err
		}
		return map[string]any{"patch": out}, nil
	}
	switch kind {
	case "untracked":
		out, err := untrackedPatch(root, path)
		if err != nil {
			return nil, err
		}
		return map[string]any{"patch": out}, nil
	case "staged":
		out, err := gitRun(ctx, root, "diff", "--cached", "--no-color", "--no-ext-diff", "--find-renames", "--unified=3", "--", path)
		if err != nil {
			return nil, err
		}
		return map[string]any{"patch": out}, nil
	default:
		out, err := gitRun(ctx, root, "diff", "--no-color", "--no-ext-diff", "--find-renames", "--unified=3", "--", path)
		if err != nil {
			return nil, err
		}
		return map[string]any{"patch": out}, nil
	}
}

func validGitRef(ref string) bool {
	if ref == "" || len(ref) > 200 || strings.HasPrefix(ref, "-") {
		return false
	}
	for _, r := range ref {
		if !(r == '/' || r == '-' || r == '_' || r == '.' || r >= '0' && r <= '9' || r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z') {
			return false
		}
	}
	return true
}

func untrackedPatch(root, path string) (string, error) {
	full, err := safeRel(root, path)
	if err != nil {
		return "", err
	}
	data, err := os.ReadFile(full)
	if err != nil {
		return "", err
	}
	if bytes.IndexByte(data, 0) >= 0 {
		return fmt.Sprintf("diff --git a/%s b/%s\nBinary files /dev/null and b/%s differ\n", path, path, path), nil
	}
	lines := strings.Split(strings.TrimSuffix(string(data), "\n"), "\n")
	if len(data) == 0 {
		lines = nil
	}
	var b strings.Builder
	fmt.Fprintf(&b, "diff --git a/%s b/%s\nnew file mode 100644\n--- /dev/null\n+++ b/%s\n", path, path, path)
	fmt.Fprintf(&b, "@@ -0,0 +1,%d @@\n", len(lines))
	for _, line := range lines {
		b.WriteByte('+')
		b.WriteString(line)
		b.WriteByte('\n')
	}
	return b.String(), nil
}

func (s *Server) gitFileAction(ctx context.Context, p map[string]any) (any, error) {
	root, err := s.gitRoot(ctx, p)
	if err != nil {
		return nil, err
	}
	path := asString(p, "path")
	if path == "" {
		return nil, errors.New("path is required")
	}
	if _, err := safeRel(root, path); err != nil {
		return nil, err
	}
	switch asString(p, "action") {
	case "stage":
		if _, err := gitRun(ctx, root, "add", "-A", "--", path); err != nil {
			return nil, err
		}
	case "unstage":
		if _, err := gitRun(ctx, root, "restore", "--staged", "--", path); err != nil {
			if _, fallback := gitRun(ctx, root, "rm", "--cached", "--quiet", "--", path); fallback != nil {
				return nil, err
			}
		}
	default:
		return nil, fmt.Errorf("unknown git file action: %s", asString(p, "action"))
	}
	return map[string]any{"ok": true}, nil
}

func (s *Server) gitPull(ctx context.Context, p map[string]any) (any, error) {
	root, err := s.gitRoot(ctx, p)
	if err != nil {
		return nil, err
	}
	cctx, cancel := context.WithTimeout(ctx, 120*time.Second)
	defer cancel()
	cmd := exec.CommandContext(cctx, "git", "pull", "--ff-only")
	cmd.Dir = root
	cmd.Env = append(os.Environ(), "GIT_TERMINAL_PROMPT=0", "LC_ALL=C")
	var out, stderr bytes.Buffer
	cmd.Stdout = &out
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		msg := strings.TrimSpace(stderr.String())
		if msg == "" {
			msg = strings.TrimSpace(out.String())
		}
		if msg == "" {
			msg = err.Error()
		}
		return nil, errors.New(msg)
	}
	summary := strings.TrimSpace(out.String())
	if summary == "" {
		summary = "Already up to date"
	}
	return map[string]any{"summary": summary}, nil
}

func (s *Server) gitCommits(ctx context.Context, p map[string]any) (any, error) {
	root, err := s.gitRoot(ctx, p)
	if err != nil {
		return nil, err
	}
	out, err := gitRun(ctx, root, "log", "-n", "80", "--date=iso-strict", "--pretty=format:%H%x1f%h%x1f%an%x1f%aI%x1f%s")
	if err != nil {
		return nil, err
	}
	tags := map[string][]string{}
	if refs, err := gitRun(ctx, root, "for-each-ref", "--format=%(refname:short) %(objectname) %(*objectname)", "refs/tags"); err == nil {
		for _, line := range strings.Split(strings.TrimSpace(refs), "\n") {
			parts := strings.Fields(line)
			if len(parts) < 2 {
				continue
			}
			tags[parts[1]] = append(tags[parts[1]], parts[0])
			if len(parts) > 2 && parts[2] != "" {
				tags[parts[2]] = append(tags[parts[2]], parts[0])
			}
		}
	}
	commits := make([]map[string]any, 0, 80)
	for _, line := range strings.Split(out, "\n") {
		fields := strings.SplitN(line, "\x1f", 5)
		if len(fields) != 5 {
			continue
		}
		commits = append(commits, map[string]any{
			"sha":         fields[0],
			"short_sha":   fields[1],
			"author":      fields[2],
			"authored_at": fields[3],
			"subject":     fields[4],
			"tags":        tags[fields[0]],
		})
	}
	head, _ := gitRun(ctx, root, "rev-parse", "HEAD")
	return map[string]any{"commits": commits, "head": strings.TrimSpace(head)}, nil
}

func (s *Server) gitCommit(ctx context.Context, p map[string]any) (any, error) {
	root, err := s.gitRoot(ctx, p)
	if err != nil {
		return nil, err
	}
	sha := asString(p, "sha")
	if !validGitRef(sha) {
		return nil, errors.New("invalid commit")
	}
	base, _ := gitRun(ctx, root, "rev-parse", sha+"^")
	base = strings.TrimSpace(base)
	nameStatus, err := gitRun(ctx, root, "diff-tree", "--no-commit-id", "--name-status", "-r", "-M", sha)
	if err != nil {
		return nil, err
	}
	numstat, _ := gitRun(ctx, root, "diff-tree", "--no-commit-id", "--numstat", "-r", "-M", sha)
	stats := map[string][2]int{}
	for _, line := range strings.Split(numstat, "\n") {
		f := strings.SplitN(line, "\t", 3)
		if len(f) != 3 {
			continue
		}
		path := f[2]
		if i := strings.Index(path, " => "); i >= 0 {
			path = strings.Trim(path[i+4:], "{}")
		}
		var n [2]int
		n[0], _ = strconv.Atoi(f[0])
		n[1], _ = strconv.Atoi(f[1])
		stats[path] = n
	}
	entries := make([]diffEntry, 0)
	for _, line := range strings.Split(strings.TrimSpace(nameStatus), "\n") {
		if line == "" {
			continue
		}
		f := strings.Split(line, "\t")
		if len(f) < 2 {
			continue
		}
		status := f[0]
		e := diffEntry{Kind: "commit"}
		if (strings.HasPrefix(status, "R") || strings.HasPrefix(status, "C")) && len(f) >= 3 {
			e.OldPath = f[1]
			e.Path = f[2]
		} else {
			e.Path = f[1]
		}
		if n, ok := stats[e.Path]; ok {
			e.Additions, e.Deletions = n[0], n[1]
		}
		entries = append(entries, e)
	}
	return map[string]any{"entries": entries, "base": base}, nil
}

// gitCommitCreate stages the selected paths, then commits only those paths.
// The user selects files explicitly; no implicit add of anything else.
func (s *Server) gitCommitCreate(ctx context.Context, p map[string]any) (any, error) {
	root, err := s.gitRoot(ctx, p)
	if err != nil {
		return nil, err
	}
	message := strings.TrimSpace(asString(p, "message"))
	if message == "" {
		return nil, errors.New("commit message is required")
	}
	paths := asStrings(p, "paths")
	if len(paths) == 0 {
		return nil, errors.New("select at least one file")
	}
	relPaths := make([]string, 0, len(paths))
	for _, path := range paths {
		clean, err := safeRel(root, path)
		if err != nil {
			return nil, err
		}
		rel, err := filepath.Rel(root, clean)
		if err != nil {
			return nil, err
		}
		relPaths = append(relPaths, rel)
	}
	addArgs := append([]string{"add", "--"}, relPaths...)
	if _, err := gitRun(ctx, root, addArgs...); err != nil {
		return nil, err
	}
	commitArgs := append([]string{"commit", "--only", "-m", message, "--"}, relPaths...)
	out, err := gitRun(ctx, root, commitArgs...)
	if err != nil {
		return nil, err
	}
	sha, _ := gitRun(ctx, root, "rev-parse", "HEAD")
	return map[string]any{"ok": true, "output": strings.TrimSpace(out), "sha": strings.TrimSpace(sha)}, nil
}
