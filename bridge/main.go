package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"
)

// overridden at build time with -ldflags "-X main.bridgeVersion=..."
var bridgeVersion = "0.1.1"

type Config struct {
	Addr         string
	TokenFile    string
	WebDir       string
	Socket       string
	ClientSocket string
	StateDir     string
}

type Server struct {
	cfg         Config
	token       string
	herdr       *Herdr
	shell       *ShellEndpoint
	sessions    *SessionStore
	terms       *TerminalManager
	transcripts *Transcripts
	ranger      *Ranger
	clients     map[*Client]struct{}
	mu          sync.Mutex
	version     string
}

func main() {
	log.SetFlags(log.LstdFlags | log.Lmsgprefix)
	log.SetPrefix("droves-bridge: ")
	cfg := Config{}
	home, _ := os.UserHomeDir()
	flag.StringVar(&cfg.Addr, "addr", envOr("DROVES_BRIDGE_ADDR", "127.0.0.1:13030"), "HTTP listen address")
	flag.StringVar(&cfg.TokenFile, "token-file", envOr("DROVES_TOKEN_FILE", filepath.Join(home, ".config/droves-bridge/token")), "token file")
	flag.StringVar(&cfg.WebDir, "web", envOr("DROVES_WEB_DIR", "../build/web"), "Flutter web build")
	flag.StringVar(&cfg.Socket, "herdr", envOr("DROVES_HERDR_SOCKET", filepath.Join(home, ".config/herdr/herdr.sock")), "herdr control socket")
	flag.StringVar(&cfg.ClientSocket, "herdr-client", envOr("DROVES_HERDR_CLIENT_SOCKET", defaultClientSocket(home)), "herdr client surface socket")
	flag.StringVar(&cfg.StateDir, "state", envOr("DROVES_STATE_DIR", filepath.Join(home, ".local/state/droves-bridge")), "state directory")
	showVersion := flag.Bool("version", false, "print version and exit")
	flag.Parse()
	if *showVersion {
		fmt.Println(bridgeVersion)
		return
	}
	cfg.WebDir = expandHome(cfg.WebDir)
	cfg.TokenFile = expandHome(cfg.TokenFile)
	cfg.Socket = expandHome(cfg.Socket)
	cfg.ClientSocket = expandHome(cfg.ClientSocket)
	cfg.StateDir = expandHome(cfg.StateDir)

	token, err := loadOrCreateToken(cfg.TokenFile)
	if err != nil {
		log.Fatalf("token: %v", err)
	}
	if err := os.MkdirAll(cfg.StateDir, 0o700); err != nil {
		log.Fatalf("state: %v", err)
	}
	srv := &Server{
		cfg:      cfg,
		token:    token,
		herdr:    &Herdr{SocketPath: cfg.Socket},
		sessions: NewSessionStore(filepath.Join(cfg.StateDir, "sessions.json")),
		clients:  make(map[*Client]struct{}),
		version:  bridgeVersion,
	}
	srv.shell = NewShellEndpoint(cfg.ClientSocket, srv.herdr)
	srv.terms = NewTerminalManager(srv)
	srv.transcripts = NewTranscripts()
	srv.ranger = NewRanger(srv)

	mux := http.NewServeMux()
	mux.HandleFunc("/api/health", srv.handleHealth)
	mux.HandleFunc("/api/login", srv.handleLogin)
	mux.HandleFunc("/api/terminal-upload", srv.authed(srv.handleTerminalUpload))
	mux.HandleFunc("/api/file/upload", srv.authed(srv.handleFileUpload))
	mux.HandleFunc("/api/file/delete", srv.authed(srv.handleFileDelete))
	mux.HandleFunc("/ws", srv.handleWebSocket)
	mux.HandleFunc("/droves/", srv.handleStatic)
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/" {
			http.Redirect(w, r, "/droves/", http.StatusFound)
			return
		}
		http.NotFound(w, r)
	})

	httpSrv := &http.Server{
		Addr:              cfg.Addr,
		Handler:           mux,
		ReadHeaderTimeout: 10 * time.Second,
		IdleTimeout:       90 * time.Second,
		MaxHeaderBytes:    1 << 20,
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	go func() {
		<-ctx.Done()
		srv.shell.Close()
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = httpSrv.Shutdown(shutdownCtx)
	}()
	log.Printf("listening on %s (herdr %s, web %s)", cfg.Addr, cfg.Socket, cfg.WebDir)
	if err := httpSrv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Fatalf("listen: %v", err)
	}
}

func envOr(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func defaultClientSocket(home string) string {
	if v := os.Getenv("HERDR_CLIENT_SOCKET_PATH"); v != "" {
		return v
	}
	return filepath.Join(home, ".config/herdr/herdr-client.sock")
}

func loadOrCreateToken(path string) (string, error) {
	b, err := os.ReadFile(path)
	if err == nil {
		token := strings.TrimSpace(string(b))
		if len(token) < 24 {
			return "", errors.New("existing token is too short")
		}
		return token, nil
	}
	if !errors.Is(err, os.ErrNotExist) {
		return "", err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return "", err
	}
	token, err := randomToken(32)
	if err != nil {
		return "", err
	}
	if err := os.WriteFile(path, []byte(token+"\n"), 0o600); err != nil {
		return "", err
	}
	if err := os.Chmod(path, 0o600); err != nil {
		return "", err
	}
	return token, nil
}

func (s *Server) handleHealth(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{
		"ok":      true,
		"service": "droves-bridge",
		"version": s.version,
	})
}

func (s *Server) authed(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if !s.sessions.Valid(r) {
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		next(w, r)
	}
}

func writeJSON(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(value)
}

func (s *Server) notifyAll(v any) {
	s.mu.Lock()
	clients := make([]*Client, 0, len(s.clients))
	for c := range s.clients {
		clients = append(clients, c)
	}
	s.mu.Unlock()
	for _, c := range clients {
		c.enqueue(v, false)
	}
}

func (s *Server) push(method string, params map[string]any) {
	s.notifyAll(map[string]any{method: params})
}

func formatErr(err error) map[string]any {
	msg := "internal error"
	if err != nil {
		msg = err.Error()
	}
	return map[string]any{"error": map[string]any{"message": msg}}
}

func (s *Server) handleStatic(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	rel := strings.TrimPrefix(r.URL.Path, "/droves/")
	if rel == "" || strings.HasSuffix(rel, "/") {
		rel += "index.html"
	}
	rel = filepath.Clean(rel)
	if strings.HasPrefix(rel, "..") || filepath.IsAbs(rel) {
		http.NotFound(w, r)
		return
	}
	full := filepath.Join(s.cfg.WebDir, rel)
	if st, err := os.Stat(full); err != nil || st.IsDir() {
		// Flutter routes via hash; a missing asset must 404, not become index.html
		if filepath.Ext(rel) != "" {
			http.NotFound(w, r)
			return
		}
		full = filepath.Join(s.cfg.WebDir, "index.html")
	}
	f, err := os.Open(full)
	if err != nil {
		http.Error(w, "Droves web build is missing. Set DROVES_WEB_DIR or run flutter build web.", http.StatusNotFound)
		return
	}
	defer f.Close()
	st, err := f.Stat()
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	// the web shell and the update manifest must never be served stale: a cached
	// bootstrap keeps pointing at the previous build and the update prompt lies
	switch filepath.Base(rel) {
	case "index.html", "flutter_bootstrap.js", "flutter_service_worker.js", "version.json", "update.json":
		w.Header().Set("Cache-Control", "no-cache")
	default:
		w.Header().Set("Cache-Control", "public, max-age=3600")
	}
	http.ServeContent(w, r, full, st.ModTime(), f)
}

func expandHome(path string) string {
	if path == "~" || strings.HasPrefix(path, "~/") {
		if home, err := os.UserHomeDir(); err == nil {
			return filepath.Join(home, strings.TrimPrefix(path, "~/"))
		}
	}
	return path
}
