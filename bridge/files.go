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
	"sort"
	"strings"
	"time"
	"unicode/utf8"
)

func safeRel(root, rel string) (string, error) {
	if strings.IndexByte(rel, 0) >= 0 {
		return "", errors.New("invalid path")
	}
	cleanRoot, err := filepath.Abs(root)
	if err != nil {
		return "", err
	}
	full := filepath.Clean(filepath.Join(cleanRoot, filepath.FromSlash(rel)))
	if full != cleanRoot && !strings.HasPrefix(full, cleanRoot+string(os.PathSeparator)) {
		return "", errors.New("path escapes the workspace")
	}
	return full, nil
}

func (s *Server) fileList(p map[string]any) (any, error) {
	root, err := s.workspaceRoot(context.Background(), asString(p, "workspace_id"))
	if err != nil {
		return nil, err
	}
	rel := asString(p, "path")
	full, err := safeRel(root, rel)
	if err != nil {
		return nil, err
	}
	items, err := os.ReadDir(full)
	if err != nil {
		return nil, err
	}
	showHidden := asBool(p, "show_hidden")
	out := make([]map[string]any, 0, len(items))
	for _, item := range items {
		name := item.Name()
		if !showHidden && strings.HasPrefix(name, ".") {
			continue
		}
		info, err := item.Info()
		if err != nil {
			continue
		}
		typ := "file"
		if item.IsDir() {
			typ = "directory"
		} else if !info.Mode().IsRegular() {
			continue
		}
		childRel := filepath.ToSlash(filepath.Join(rel, name))
		out = append(out, map[string]any{
			"name": name,
			"path": childRel,
			"type": typ,
			"size": info.Size(),
		})
	}
	sort.Slice(out, func(i, j int) bool {
		di := out[i]["type"] == "directory"
		dj := out[j]["type"] == "directory"
		if di != dj {
			return di
		}
		return out[i]["name"].(string) < out[j]["name"].(string)
	})
	return map[string]any{"entries": out, "path": filepath.ToSlash(rel)}, nil
}

func (s *Server) fileRead(p map[string]any) (any, error) {
	root, err := s.workspaceRoot(context.Background(), asString(p, "workspace_id"))
	if err != nil {
		return nil, err
	}
	full, err := safeRel(root, asString(p, "path"))
	if err != nil {
		return nil, err
	}
	f, err := os.Open(full)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	st, err := f.Stat()
	if err != nil {
		return nil, err
	}
	if st.IsDir() {
		return nil, errors.New("path is a directory")
	}
	const limit = 2 << 20
	data, err := io.ReadAll(io.LimitReader(f, limit+1))
	if err != nil {
		return nil, err
	}
	truncated := len(data) > limit
	if truncated {
		data = data[:limit]
	}
	binary := bytes.IndexByte(data, 0) >= 0 || !utf8.Valid(data)
	return map[string]any{
		"text":      string(data),
		"truncated": truncated,
		"binary":    binary,
		"size":      st.Size(),
	}, nil
}

var searchSkip = map[string]bool{
	".git": true, "node_modules": true, ".dart_tool": true, "build": true,
	".venv": true, "venv": true, "target": true, "dist": true, ".idea": true,
	".next": true, ".cache": true,
}

func (s *Server) fileSearch(ctx context.Context, p map[string]any) (any, error) {
	root, err := s.workspaceRoot(ctx, asString(p, "workspace_id"))
	if err != nil {
		return nil, err
	}
	query := asString(p, "query")
	if query == "" {
		return map[string]any{"results": []any{}}, nil
	}
	if asString(p, "mode") == "content" {
		return searchContent(ctx, root, query)
	}
	lower := strings.ToLower(query)
	results := make([]map[string]any, 0, 64)
	filepath.WalkDir(root, func(path string, d os.DirEntry, err error) error {
		if err != nil {
			return nil
		}
		if len(results) >= 300 {
			return filepath.SkipAll
		}
		if d.IsDir() {
			if path != root && searchSkip[d.Name()] {
				return filepath.SkipDir
			}
			return nil
		}
		if !d.Type().IsRegular() {
			return nil
		}
		if strings.Contains(strings.ToLower(d.Name()), lower) {
			rel, err := filepath.Rel(root, path)
			if err == nil {
				results = append(results, map[string]any{"path": filepath.ToSlash(rel)})
			}
		}
		return nil
	})
	return map[string]any{"results": results}, nil
}

func searchContent(ctx context.Context, root, query string) (any, error) {
	cctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	args := []string{
		"--json", "--no-messages", "--fixed-strings", "--smart-case",
		"--max-count", "4", "--max-filesize", "2M",
		"--glob", "!.git/**", "--glob", "!node_modules/**", "--glob", "!build/**",
		"--", query, ".",
	}
	cmd := exec.CommandContext(cctx, "rg", args...)
	cmd.Dir = root
	var out bytes.Buffer
	cmd.Stdout = &out
	cmd.Stderr = io.Discard
	err := cmd.Run()
	if err != nil {
		if cmd.ProcessState != nil && cmd.ProcessState.ExitCode() == 1 {
			return map[string]any{"results": []any{}}, nil
		}
		if errors.Is(cctx.Err(), context.DeadlineExceeded) {
			return nil, errors.New("search timed out")
		}
		// rg missing or failed: fall back to a bounded text scan.
		return searchFallback(root, query)
	}
	results := make([]map[string]any, 0, 64)
	sc := bufio.NewScanner(bytes.NewReader(out.Bytes()))
	sc.Buffer(make([]byte, 64*1024), 4*1024*1024)
	seen := map[string]int{}
	for sc.Scan() {
		var event struct {
			Type string `json:"type"`
			Data struct {
				Path struct {
					Text string `json:"text"`
				} `json:"path"`
				Lines struct {
					Text string `json:"text"`
				} `json:"lines"`
				LineNumber int `json:"line_number"`
			} `json:"data"`
		}
		if json.Unmarshal(sc.Bytes(), &event) != nil || event.Type != "match" {
			continue
		}
		rel, err := filepath.Rel(root, event.Data.Path.Text)
		if err != nil {
			continue
		}
		rel = filepath.ToSlash(rel)
		if seen[rel] >= 4 {
			continue
		}
		seen[rel]++
		snippet := strings.TrimRight(event.Data.Lines.Text, "\r\n")
		if len(snippet) > 400 {
			snippet = snippet[:400]
		}
		results = append(results, map[string]any{
			"path":    rel,
			"line":    event.Data.LineNumber,
			"snippet": strings.TrimSpace(snippet),
		})
		if len(results) >= 300 {
			break
		}
	}
	return map[string]any{"results": results}, nil
}

func searchFallback(root, query string) (any, error) {
	lower := strings.ToLower(query)
	results := make([]map[string]any, 0, 32)
	filepath.WalkDir(root, func(path string, d os.DirEntry, err error) error {
		if err != nil || len(results) >= 100 {
			return nil
		}
		if d.IsDir() {
			if path != root && searchSkip[d.Name()] {
				return filepath.SkipDir
			}
			return nil
		}
		if !d.Type().IsRegular() {
			return nil
		}
		data, err := os.ReadFile(path)
		if err != nil || bytes.IndexByte(data, 0) >= 0 || len(data) > 2<<20 {
			return nil
		}
		rel, _ := filepath.Rel(root, path)
		for i, line := range strings.Split(string(data), "\n") {
			if strings.Contains(strings.ToLower(line), lower) {
				results = append(results, map[string]any{
					"path": filepath.ToSlash(rel), "line": i + 1, "snippet": strings.TrimSpace(line),
				})
				if len(results) >= 100 {
					break
				}
			}
		}
		return nil
	})
	return map[string]any{"results": results}, nil
}

func (s *Server) fileMkdir(p map[string]any) (any, error) {
	root, err := s.workspaceRoot(context.Background(), asString(p, "workspace_id"))
	if err != nil {
		return nil, err
	}
	dir, err := safeRel(root, asString(p, "directory"))
	if err != nil {
		return nil, err
	}
	name := asString(p, "name")
	if name == "" || name == "." || name == ".." || strings.ContainsAny(name, `/\`) {
		return nil, errors.New("invalid folder name")
	}
	if err := os.Mkdir(filepath.Join(dir, name), 0o755); err != nil {
		return nil, err
	}
	return map[string]any{"ok": true}, nil
}

func (s *Server) fileMove(p map[string]any) (any, error) {
	root, err := s.workspaceRoot(context.Background(), asString(p, "workspace_id"))
	if err != nil {
		return nil, err
	}
	src, err := safeRel(root, asString(p, "path"))
	if err != nil {
		return nil, err
	}
	dir, err := safeRel(root, asString(p, "directory"))
	if err != nil {
		return nil, err
	}
	if src == root {
		return nil, errors.New("cannot move the workspace root")
	}
	if err := os.Rename(src, filepath.Join(dir, filepath.Base(src))); err != nil {
		// rename fails across devices; copy regular files instead
		info, statErr := os.Stat(src)
		if statErr != nil || info.IsDir() {
			return nil, err
		}
		data, readErr := os.ReadFile(src)
		if readErr != nil {
			return nil, err
		}
		dst := filepath.Join(dir, filepath.Base(src))
		if writeErr := os.WriteFile(dst, data, info.Mode()); writeErr != nil {
			return nil, writeErr
		}
		return map[string]any{"ok": true}, os.Remove(src)
	}
	return map[string]any{"ok": true}, nil
}

func (s *Server) handleTerminalUpload(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	filename := filepath.Base(r.URL.Query().Get("filename"))
	if filename == "" || filename == "." || filename == ".." {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "invalid filename"})
		return
	}
	dir := filepath.Join(s.cfg.StateDir, "uploads")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]any{"error": err.Error()})
		return
	}
	prefix, err := randomToken(6)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]any{"error": err.Error()})
		return
	}
	path := filepath.Join(dir, prefix+"-"+filename)
	if err := receiveUpload(w, r, path, 64<<20); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": err.Error()})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"path": path, "name": filename})
}

func (s *Server) handleFileUpload(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	root, err := s.workspaceRoot(r.Context(), r.URL.Query().Get("workspace_id"))
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": err.Error()})
		return
	}
	dir, err := safeRel(root, r.URL.Query().Get("directory"))
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": err.Error()})
		return
	}
	name := r.URL.Query().Get("filename")
	if name == "" || name == "." || name == ".." || strings.ContainsAny(name, `/\`) {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "invalid filename"})
		return
	}
	if st, err := os.Stat(dir); err != nil || !st.IsDir() {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "directory does not exist"})
		return
	}
	path := filepath.Join(dir, name)
	if err := receiveUpload(w, r, path, 20<<20); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": err.Error()})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

func receiveUpload(w http.ResponseWriter, r *http.Request, path string, limit int64) error {
	body := http.MaxBytesReader(w, r.Body, limit)
	tmp := path + ".droves-tmp"
	f, err := os.OpenFile(tmp, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0o644)
	if err != nil {
		return err
	}
	_, copyErr := io.Copy(f, body)
	closeErr := f.Close()
	if copyErr != nil {
		os.Remove(tmp)
		return fmt.Errorf("upload: %w", copyErr)
	}
	if closeErr != nil {
		os.Remove(tmp)
		return closeErr
	}
	if err := os.Rename(tmp, path); err != nil {
		os.Remove(tmp)
		return err
	}
	return nil
}

func (s *Server) handleFileDelete(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	root, err := s.workspaceRoot(r.Context(), r.URL.Query().Get("workspace_id"))
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": err.Error()})
		return
	}
	rel := r.URL.Query().Get("path")
	full, err := safeRel(root, rel)
	if err != nil || full == root || rel == "" {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "invalid path"})
		return
	}
	if err := os.RemoveAll(full); err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]any{"error": err.Error()})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}
