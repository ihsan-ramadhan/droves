package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"sync"
	"time"
	"unicode/utf8"
)

type TerminalManager struct {
	srv      *Server
	mu       sync.Mutex
	sessions map[string]*TerminalSession
}

type TerminalSession struct {
	mgr    *TerminalManager
	id     string
	paneID string

	mu      sync.Mutex
	clients map[*Client]struct{}
	cols    int
	rows    int
	offset  int
	last    string
	stopped bool
	stop    chan struct{}
	wake    chan struct{}
}

func NewTerminalManager(srv *Server) *TerminalManager {
	return &TerminalManager{srv: srv, sessions: make(map[string]*TerminalSession)}
}

func (m *TerminalManager) Attach(ctx context.Context, c *Client, terminalID string, cols, rows int) error {
	if terminalID == "" {
		return errors.New("terminal_id is required")
	}
	snap, err := m.srv.snapshot(ctx)
	if err != nil {
		return err
	}
	pane := snap.PaneByTerminal(terminalID)
	if pane == nil {
		return fmt.Errorf("terminal %s is not attached to a pane", terminalID)
	}
	if cols < 2 {
		cols = 100
	}
	if rows < 2 {
		rows = 30
	}
	m.mu.Lock()
	sess := m.sessions[terminalID]
	if sess == nil {
		sess = &TerminalSession{
			mgr:     m,
			id:      terminalID,
			paneID:  pane.PaneID,
			clients: make(map[*Client]struct{}),
			cols:    cols,
			rows:    rows,
			stop:    make(chan struct{}),
			wake:    make(chan struct{}, 1),
		}
		m.sessions[terminalID] = sess
		go sess.run()
	}
	m.mu.Unlock()

	sess.mu.Lock()
	sess.clients[c] = struct{}{}
	if cols > 0 {
		sess.cols = cols
	}
	if rows > 0 {
		sess.rows = rows
	}
	sess.mu.Unlock()
	c.addTerminal(terminalID)
	m.srv.shell.Resize(pane.PaneID, cols, rows)
	sess.kick()
	return nil
}

func (m *TerminalManager) Detach(c *Client, terminalID string) {
	m.mu.Lock()
	sess := m.sessions[terminalID]
	m.mu.Unlock()
	if sess == nil {
		return
	}
	sess.mu.Lock()
	delete(sess.clients, c)
	empty := len(sess.clients) == 0
	sess.mu.Unlock()
	if empty {
		m.stop(terminalID, sess)
	}
}

func (m *TerminalManager) DetachClient(c *Client) {
	for _, terminalID := range c.terminals() {
		m.Detach(c, terminalID)
	}
}

func (m *TerminalManager) stop(terminalID string, sess *TerminalSession) {
	m.mu.Lock()
	if m.sessions[terminalID] == sess {
		delete(m.sessions, terminalID)
	}
	empty := len(m.sessions) == 0
	m.mu.Unlock()
	sess.mu.Lock()
	if !sess.stopped {
		sess.stopped = true
		close(sess.stop)
	}
	sess.mu.Unlock()
	if empty {
		m.srv.shell.Release()
	}
}

func (m *TerminalManager) Resize(terminalID string, cols, rows int) {
	if cols < 2 || rows < 2 {
		return
	}
	m.mu.Lock()
	sess := m.sessions[terminalID]
	m.mu.Unlock()
	if sess == nil {
		return
	}
	sess.mu.Lock()
	sess.cols = cols
	sess.rows = rows
	paneID := sess.paneID
	sess.mu.Unlock()
	m.srv.shell.Resize(paneID, cols, rows)
	sess.kick()
}

func (m *TerminalManager) Input(ctx context.Context, terminalID, data string) error {
	m.mu.Lock()
	sess := m.sessions[terminalID]
	m.mu.Unlock()
	if sess == nil {
		return errors.New("terminal is not attached")
	}
	return sess.input(ctx, data)
}

func (m *TerminalManager) Scroll(ctx context.Context, c *Client, terminalID string, lines int, up bool) error {
	m.mu.Lock()
	sess := m.sessions[terminalID]
	m.mu.Unlock()
	if sess == nil {
		return errors.New("terminal is not attached")
	}
	if lines <= 0 {
		lines = 3
	}
	sess.mu.Lock()
	if up {
		sess.offset += lines
	} else {
		sess.offset -= lines
		if sess.offset < 0 {
			sess.offset = 0
		}
	}
	offset := sess.offset
	sess.mu.Unlock()
	_, err := m.srv.herdr.Call(ctx, "pane.scroll", map[string]any{
		"pane_id":            sess.paneID,
		"offset_from_bottom": offset,
	})
	if err != nil {
		return err
	}
	sess.mu.Lock()
	sess.last = "\x00force"
	sess.mu.Unlock()
	sess.kick()
	return nil
}

func (s *TerminalSession) kick() {
	select {
	case s.wake <- struct{}{}:
	default:
	}
}

func (s *TerminalSession) run() {
	ticker := time.NewTicker(180 * time.Millisecond)
	defer ticker.Stop()
	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
	_ = s.repaint(ctx)
	cancel()
	for {
		select {
		case <-ticker.C:
		case <-s.wake:
		case <-s.stop:
			return
		}
		ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
		_ = s.repaint(ctx)
		cancel()
	}
}

func (s *TerminalSession) repaint(ctx context.Context) error {
	raw, err := s.mgr.srv.herdr.Call(ctx, "pane.read", map[string]any{
		"pane_id":    s.paneID,
		"source":     "visible",
		"format":     "ansi",
		"strip_ansi": false,
	})
	if err != nil {
		return err
	}
	var wrap struct {
		Read *struct {
			Text string `json:"text"`
		} `json:"read"`
		Text string `json:"text"`
	}
	if err := json.Unmarshal(raw, &wrap); err != nil {
		return err
	}
	text := wrap.Text
	if wrap.Read != nil && wrap.Read.Text != "" {
		text = wrap.Read.Text
	}
	s.mu.Lock()
	if s.stopped {
		s.mu.Unlock()
		return nil
	}
	changed := text != s.last
	if changed {
		s.last = text
	}
	cols, rows := s.cols, s.rows
	clients := make([]*Client, 0, len(s.clients))
	for c := range s.clients {
		clients = append(clients, c)
	}
	s.mu.Unlock()
	if !changed {
		return nil
	}
	if cols < 2 {
		cols = 100
	}
	if rows < 2 {
		rows = 30
	}
	// Herdr returns the visible screen, not a delta; repaint from a clean origin
	frame := "\x1b[0m\x1b[H\x1b[2J" + text
	b64 := base64.StdEncoding.EncodeToString([]byte(frame))
	payload := map[string]any{"terminal": map[string]any{
		"terminal_id": s.id,
		"width":       cols,
		"height":      rows,
		"full":        true,
		"bytes":       b64,
	}}
	for _, c := range clients {
		c.enqueue(payload, false)
	}
	return nil
}

func (s *TerminalSession) input(ctx context.Context, data string) error {
	// strip bracketed paste markers; typing them literally breaks shells without the mode
	data = strings.ReplaceAll(data, "\x1b[200~", "")
	data = strings.ReplaceAll(data, "\x1b[201~", "")

	var pending strings.Builder
	flush := func() error {
		if pending.Len() == 0 {
			return nil
		}
		text := pending.String()
		pending.Reset()
		_, err := s.mgr.srv.herdr.Call(ctx, "pane.send_text", map[string]any{
			"pane_id": s.paneID,
			"text":    text,
		})
		return err
	}
	sendKey := func(key string) error {
		if err := flush(); err != nil {
			return err
		}
		_, err := s.mgr.srv.herdr.Call(ctx, "pane.send_keys", map[string]any{
			"pane_id": s.paneID,
			"keys":    []string{key},
		})
		return err
	}

	for i := 0; i < len(data); {
		if data[i] == 0x1b {
			if i+2 < len(data) && data[i+1] == '[' {
				if key, used, ok := csiKey(data[i:]); ok {
					if err := sendKey(key); err != nil {
						return err
					}
					i += used
					continue
				}
			}
			if i+1 < len(data) && data[i+1] == 'O' && i+2 < len(data) {
				if key, ok := ss3Key(data[i+2]); ok {
					if err := sendKey(key); err != nil {
						return err
					}
					i += 3
					continue
				}
			}
			if i+1 < len(data) && data[i+1] == '\x1b' {
				if err := sendKey("esc"); err != nil {
					return err
				}
				i++
				continue
			}
			if i+1 < len(data) {
				if data[i+1] < 0x20 || data[i+1] == 0x7f {
					if err := sendKey("esc"); err != nil {
						return err
					}
					i++
					continue
				}
			}
			if err := sendKey("esc"); err != nil {
				return err
			}
			i++
			continue
		}
		b := data[i]
		if b == '\r' || b == '\n' {
			if err := sendKey("enter"); err != nil {
				return err
			}
			i++
			continue
		}
		if b == '\t' {
			if err := sendKey("tab"); err != nil {
				return err
			}
			i++
			continue
		}
		if b == 0x7f || b == 0x08 {
			if err := sendKey("backspace"); err != nil {
				return err
			}
			i++
			continue
		}
		if b < 0x20 {
			ch := byte('a' + b - 1)
			if b == 0 {
				ch = ' '
			} else if b >= 0x1c && b <= 0x1f {
				ch = []byte{'\\', ']', '^', '_'}[b-0x1c]
			}
			if err := sendKey("ctrl-" + string(ch)); err != nil {
				return err
			}
			i++
			continue
		}
		_, size := utf8.DecodeRuneInString(data[i:])
		if size <= 0 {
			size = 1
		}
		pending.WriteString(data[i : i+size])
		i += size
	}
	return flush()
}

func csiKey(s string) (string, int, bool) {
	// s starts with ESC [.
	j := 2
	for j < len(s) && (s[j] >= '0' && s[j] <= '9' || s[j] == ';') {
		j++
	}
	if j >= len(s) {
		return "", 0, false
	}
	final := s[j]
	body := s[2:j]
	used := j + 1
	switch final {
	case 'A':
		return modKey("up", body), used, true
	case 'B':
		return modKey("down", body), used, true
	case 'C':
		return modKey("right", body), used, true
	case 'D':
		return modKey("left", body), used, true
	case 'H':
		return modKey("home", body), used, true
	case 'F':
		return modKey("end", body), used, true
	case 'Z':
		return "backtab", used, true
	case '~':
		num, _ := strconv.Atoi(strings.Split(body, ";")[0])
		names := map[int]string{
			1: "home", 2: "insert", 3: "delete", 4: "end",
			5: "pageup", 6: "pagedown", 7: "home", 8: "end",
			11: "f1", 12: "f2", 13: "f3", 14: "f4", 15: "f5",
			17: "f6", 18: "f7", 19: "f8", 20: "f9", 21: "f10",
			23: "f11", 24: "f12",
		}
		if name, ok := names[num]; ok {
			return modKey(name, body), used, true
		}
	}
	return "", 0, false
}

func modKey(name, body string) string {
	parts := strings.Split(body, ";")
	if len(parts) < 2 {
		return name
	}
	n, _ := strconv.Atoi(parts[1])
	bits := n - 1
	var mods []string
	if bits&1 != 0 {
		mods = append(mods, "shift")
	}
	if bits&2 != 0 {
		mods = append(mods, "alt")
	}
	if bits&4 != 0 {
		mods = append(mods, "ctrl")
	}
	if bits&8 != 0 {
		mods = append(mods, "super")
	}
	if len(mods) == 0 {
		return name
	}
	return strings.Join(mods, "-") + "-" + name
}

func ss3Key(final byte) (string, bool) {
	switch final {
	case 'A':
		return "up", true
	case 'B':
		return "down", true
	case 'C':
		return "right", true
	case 'D':
		return "left", true
	case 'H':
		return "home", true
	case 'F':
		return "end", true
	case 'P':
		return "f1", true
	case 'Q':
		return "f2", true
	case 'R':
		return "f3", true
	case 'S':
		return "f4", true
	}
	return "", false
}
