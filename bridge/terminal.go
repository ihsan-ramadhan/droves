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

	mu        sync.Mutex
	clients   map[*Client]struct{}
	cols      int
	rows      int
	paneCols  int
	paneRows  int
	paneSplit bool
	sentCols  int
	sentRows  int
	sentSplit bool
	sizeAt    time.Time
	offset    int
	last      string
	stopped   bool
	stop      chan struct{}
	wake      chan struct{}
}

func NewTerminalManager(srv *Server) *TerminalManager {
	return &TerminalManager{srv: srv, sessions: make(map[string]*TerminalSession)}
}

// layoutChanged makes every open session re-read its pane size on the next repaint instead of waiting for the periodic refresh
func (m *TerminalManager) layoutChanged() {
	m.mu.Lock()
	sessions := make([]*TerminalSession, 0, len(m.sessions))
	for _, sess := range m.sessions {
		sessions = append(sessions, sess)
	}
	m.mu.Unlock()
	for _, sess := range sessions {
		sess.mu.Lock()
		sess.sizeAt = time.Time{}
		sess.mu.Unlock()
		sess.kick()
	}
}

func (m *TerminalManager) splitPane(paneID string) bool {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	snap, err := m.srv.snapshot(ctx)
	if err != nil {
		return false
	}
	pane := snap.Pane(paneID)
	if pane == nil {
		return false
	}
	count := 0
	for _, p := range snap.Panes {
		if p.TabID == pane.TabID {
			count++
		}
	}
	return count > 1
}

func (m *TerminalManager) paneSize(ctx context.Context, paneID string) (int, int, bool) {
	raw, err := m.srv.herdr.Call(ctx, "pane.layout", map[string]any{"pane_id": paneID})
	if err != nil {
		return 0, 0, false
	}
	var layout struct {
		Layout struct {
			Panes []struct {
				PaneID string `json:"pane_id"`
				Rect   struct {
					Width  int `json:"width"`
					Height int `json:"height"`
				} `json:"rect"`
			} `json:"panes"`
		} `json:"layout"`
	}
	if json.Unmarshal(raw, &layout) != nil {
		return 0, 0, false
	}
	for _, p := range layout.Layout.Panes {
		if p.PaneID == paneID {
			return p.Rect.Width, p.Rect.Height, len(layout.Layout.Panes) > 1
		}
	}
	return 0, 0, false
}

func (m *TerminalManager) Attach(ctx context.Context, c *Client, terminalID string, cols, rows int) (bool, int, int, error) {
	if terminalID == "" {
		return false, 0, 0, errors.New("terminal_id is required")
	}
	snap, err := m.srv.snapshot(ctx)
	if err != nil {
		return false, 0, 0, err
	}
	pane := snap.PaneByTerminal(terminalID)
	if pane == nil {
		return false, 0, 0, fmt.Errorf("terminal %s is not attached to a pane", terminalID)
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

	c.setGrid(cols, rows)
	c.addTerminal(terminalID)
	sess.mu.Lock()
	sess.clients[c] = struct{}{}
	sess.mu.Unlock()
	serverCols, serverRows, split := m.paneSize(ctx, pane.PaneID)
	if serverCols <= 0 || serverRows <= 0 {
		serverCols, serverRows = cols, rows
	}
	sess.mu.Lock()
	sess.paneSplit = split
	sess.paneCols, sess.paneRows, sess.sizeAt = serverCols, serverRows, time.Now()
	sess.last = "\x00force"
	sess.mu.Unlock()
	sess.kick()

	return split, serverCols, serverRows, nil
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

func (m *TerminalManager) Resize(c *Client, terminalID string, cols, rows int) {
	if cols < 2 || rows < 2 {
		return
	}
	c.setGrid(cols, rows)
	m.mu.Lock()
	sess := m.sessions[terminalID]
	m.mu.Unlock()
	if sess == nil {
		return
	}
	sess.mu.Lock()
	sess.cols = cols
	sess.rows = rows
	paneID, split := sess.paneID, sess.paneSplit
	sess.mu.Unlock()
	if !split {
		m.srv.shell.Resize(paneID, cols, rows)
	}
	sess.kick()
}

func (m *TerminalManager) Input(ctx context.Context, c *Client, terminalID, data string) error {
	m.mu.Lock()
	sess := m.sessions[terminalID]
	m.mu.Unlock()
	if sess == nil {
		return errors.New("terminal is not attached")
	}
	if cols, rows := c.grid(); cols > 0 {
		m.Resize(c, terminalID, cols, rows)
	}
	return sess.input(ctx, data)
}

func (m *TerminalManager) Scroll(ctx context.Context, c *Client, terminalID string, lines int, up bool) (int, error) {
	m.mu.Lock()
	sess := m.sessions[terminalID]
	m.mu.Unlock()
	if sess == nil {
		return 0, errors.New("terminal is not attached")
	}
	if cols, rows := c.grid(); cols > 0 {
		m.Resize(c, terminalID, cols, rows)
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
		return 0, err
	}
	sess.mu.Lock()
	sess.last = "\x00force"
	sess.mu.Unlock()
	sess.kick()
	return offset, nil
}

func (m *TerminalManager) Offset(terminalID string) int {
	m.mu.Lock()
	sess := m.sessions[terminalID]
	m.mu.Unlock()
	if sess == nil {
		return 0
	}
	sess.mu.Lock()
	defer sess.mu.Unlock()
	return sess.offset
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
	paneCols, paneRows, split, sizeAt := s.paneCols, s.paneRows, s.paneSplit, s.sizeAt
	clients := make([]*Client, 0, len(s.clients))
	for c := range s.clients {
		clients = append(clients, c)
	}
	s.mu.Unlock()
	if paneCols <= 0 || paneRows <= 0 || time.Since(sizeAt) > 2*time.Second {
		if pc, pr, ps := s.mgr.paneSize(ctx, s.paneID); pc > 0 && pr > 0 {
			cols, rows, split = pc, pr, ps
			s.mu.Lock()
			s.paneCols, s.paneRows, s.paneSplit, s.sizeAt = pc, pr, ps, time.Now()
			s.mu.Unlock()
		}
	} else {
		cols, rows = paneCols, paneRows
	}
	if !changed {
		s.mu.Lock()
		resized := cols != s.sentCols || rows != s.sentRows || split != s.sentSplit
		s.mu.Unlock()
		if !resized {
			return nil
		}
	}
	if cols < 2 {
		cols = 100
	}
	if rows < 2 {
		rows = 30
	}
	frame := "\x1b[0m\x1b[H\x1b[2J" + text
	b64 := base64.StdEncoding.EncodeToString([]byte(frame))
	payload := map[string]any{"terminal": map[string]any{
		"terminal_id": s.id,
		"width":       cols,
		"height":      rows,
		"split":       split,
		"full":        true,
		"bytes":       b64,
	}}
	s.mu.Lock()
	s.sentCols, s.sentRows, s.sentSplit = cols, rows, split
	s.mu.Unlock()
	for _, c := range clients {
		c.enqueue(payload, false)
	}
	return nil
}

func (s *TerminalSession) input(ctx context.Context, data string) error {
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
	for _, op := range parseInput(data) {
		if op.key == "" {
			pending.WriteString(op.text)
			continue
		}
		if err := flush(); err != nil {
			return err
		}
		_, err := s.mgr.srv.herdr.Call(ctx, "pane.send_keys", map[string]any{
			"pane_id": s.paneID,
			"keys":    []string{op.key},
		})
		if err != nil {
			return err
		}
	}
	return flush()
}

type inputOp struct {
	key  string
	text string
}

func parseInput(data string) []inputOp {
	data = strings.ReplaceAll(data, "\x1b[200~", "")
	data = strings.ReplaceAll(data, "\x1b[201~", "")

	var ops []inputOp
	var pending strings.Builder
	sendKey := func(key string) {
		if pending.Len() > 0 {
			ops = append(ops, inputOp{text: pending.String()})
			pending.Reset()
		}
		ops = append(ops, inputOp{key: key})
	}

	for i := 0; i < len(data); {
		if n := mouseReportLen(data[i:]); n > 0 {
			pending.WriteString(data[i : i+n])
			i += n
			continue
		}
		if data[i] == 0x1b {
			if i+2 < len(data) && data[i+1] == '[' {
				if key, used, ok := csiKey(data[i:]); ok {
					sendKey(key)
					i += used
					continue
				}
			}
			if i+1 < len(data) && data[i+1] == 'O' && i+2 < len(data) {
				if key, ok := ss3Key(data[i+2]); ok {
					sendKey(key)
					i += 3
					continue
				}
			}
			if i+1 < len(data) && data[i+1] == '\x1b' {
				sendKey("esc")
				i++
				continue
			}
			if i+1 < len(data) {
				if data[i+1] < 0x20 || data[i+1] == 0x7f {
					sendKey("esc")
					i++
					continue
				}
			}
			sendKey("esc")
			i++
			continue
		}
		b := data[i]
		if b == '\r' || b == '\n' {
			sendKey("enter")
			i++
			continue
		}
		if b == '\t' {
			sendKey("tab")
			i++
			continue
		}
		if b == 0x7f || b == 0x08 {
			sendKey("backspace")
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
			sendKey("ctrl-" + string(ch))
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
	if pending.Len() > 0 {
		ops = append(ops, inputOp{text: pending.String()})
	}
	return ops
}

func mouseReportLen(s string) int {
	if len(s) < 3 || s[0] != 0x1b || s[1] != '[' {
		return 0
	}
	if s[2] == 'M' {
		if len(s) < 6 {
			return len(s)
		}
		return 6
	}
	if s[2] != '<' {
		return 0
	}
	for j := 3; j < len(s); j++ {
		switch {
		case s[j] >= '0' && s[j] <= '9', s[j] == ';':
			continue
		case s[j] == 'M' || s[j] == 'm':
			return j + 1
		default:
			return 0
		}
	}
	return 0
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
