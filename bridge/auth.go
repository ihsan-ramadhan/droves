package main

import (
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"os"
	"sync"
	"time"
)

type SessionStore struct {
	mu    sync.Mutex
	byID  map[string]time.Time
	tries map[string]attempt
	path  string
}

type attempt struct {
	count int
	until time.Time
}

func NewSessionStore(path string) *SessionStore {
	s := &SessionStore{
		byID:  make(map[string]time.Time),
		tries: make(map[string]attempt),
		path:  path,
	}
	s.load()
	return s
}

func (s *SessionStore) load() {
	data, err := os.ReadFile(s.path)
	if err != nil {
		return
	}
	var byID map[string]time.Time
	if json.Unmarshal(data, &byID) != nil {
		return
	}
	now := time.Now()
	for id, exp := range byID {
		if now.Before(exp) {
			s.byID[id] = exp
		}
	}
}

func (s *SessionStore) saveLocked() {
	if s.path == "" {
		return
	}
	data, err := json.Marshal(s.byID)
	if err != nil {
		return
	}
	tmp := s.path + ".tmp"
	if os.WriteFile(tmp, data, 0o600) == nil {
		_ = os.Rename(tmp, s.path)
	}
}

func randomToken(n int) (string, error) {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(b), nil
}

func (s *SessionStore) create() (string, error) {
	id, err := randomToken(32)
	if err != nil {
		return "", err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	now := time.Now()
	for key, exp := range s.byID {
		if now.After(exp) {
			delete(s.byID, key)
		}
	}
	s.byID[id] = now.Add(30 * 24 * time.Hour)
	s.saveLocked()
	return id, nil
}

func (s *SessionStore) Valid(r *http.Request) bool {
	c, err := r.Cookie("droves_session")
	if err != nil || c.Value == "" {
		return false
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	exp, ok := s.byID[c.Value]
	if !ok {
		return false
	}
	if time.Now().After(exp) {
		delete(s.byID, c.Value)
		s.saveLocked()
		return false
	}
	return true
}

func (s *SessionStore) allowed(ip string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	a, ok := s.tries[ip]
	if !ok {
		return true
	}
	if time.Now().After(a.until) {
		delete(s.tries, ip)
		return true
	}
	return a.count < 8
}

func (s *SessionStore) fail(ip string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	a := s.tries[ip]
	a.count++
	a.until = time.Now().Add(2 * time.Minute)
	s.tries[ip] = a
}

func (s *SessionStore) clear(ip string) {
	s.mu.Lock()
	delete(s.tries, ip)
	s.mu.Unlock()
}

func tokenEqual(got, want string) bool {
	g := sha256.Sum256([]byte(got))
	w := sha256.Sum256([]byte(want))
	return subtle.ConstantTimeCompare(g[:], w[:]) == 1
}

func (s *Server) handleLogin(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	ip := s.ingress.ClientIP(r)
	if !s.sessions.allowed(ip) {
		writeJSON(w, http.StatusTooManyRequests, map[string]any{"error": "too many attempts; wait two minutes"})
		return
	}
	var body struct {
		Password string `json:"password"`
		Token    string `json:"token"`
	}
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4096))
	if err := dec.Decode(&body); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "invalid JSON body"})
		return
	}
	got := body.Password
	if got == "" {
		got = body.Token
	}
	if !tokenEqual(got, s.token) {
		s.sessions.fail(ip)
		writeJSON(w, http.StatusUnauthorized, map[string]any{"error": "invalid token"})
		return
	}
	s.sessions.clear(ip)
	id, err := s.sessions.create()
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]any{"error": "could not create session"})
		return
	}
	// a tunnel terminates TLS before the bridge sees it, and a base path mount
	// must scope the cookie to the same prefix the client calls back on
	http.SetCookie(w, &http.Cookie{
		Name:     "droves_session",
		Value:    id,
		Path:     s.ingress.CookiePath(),
		HttpOnly: true,
		Secure:   s.ingress.Secure(r),
		SameSite: http.SameSiteStrictMode,
		MaxAge:   30 * 24 * 60 * 60,
	})
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}
