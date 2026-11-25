package main

import (
	"context"
	"encoding/json"
	"errors"
	"log"
	"net/http"
	"sync"
	"time"

	"github.com/coder/websocket"
)

type Client struct {
	srv      *Server
	conn     *websocket.Conn
	sendCh   chan []byte
	done     chan struct{}
	once     sync.Once
	terminal map[string]struct{}
	mu       sync.Mutex
	cols     int
	rows     int
}

func (c *Client) grid() (int, int) {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.cols, c.rows
}

func (c *Client) setGrid(cols, rows int) {
	if cols < 2 || rows < 2 {
		return
	}
	c.mu.Lock()
	c.cols, c.rows = cols, rows
	c.mu.Unlock()
}

type RPCRequest struct {
	ID           json.RawMessage `json:"id"`
	Method       string          `json:"method"`
	Params       map[string]any  `json:"params"`
	ConnectionID string          `json:"connection_id"`
}

func (s *Server) handleWebSocket(w http.ResponseWriter, r *http.Request) {
	if !s.sessions.Valid(r) {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	if !s.ingress.AllowsOrigin(r, r.Header.Get("Origin")) {
		http.Error(w, "origin mismatch", http.StatusForbidden)
		return
	}
	conn, err := websocket.Accept(w, r, &websocket.AcceptOptions{
		InsecureSkipVerify: true,
		CompressionMode:    websocket.CompressionDisabled,
	})
	if err != nil {
		return
	}
	conn.SetReadLimit(16 << 20)
	ctx, cancel := context.WithCancel(context.Background())
	c := &Client{
		srv:      s,
		conn:     conn,
		sendCh:   make(chan []byte, 512),
		done:     make(chan struct{}),
		terminal: make(map[string]struct{}),
	}
	s.addClient(c)
	defer func() {
		cancel()
		c.Close()
		s.removeClient(c)
		s.terms.DetachClient(c)
	}()
	c.enqueue(map[string]any{"hello": true, "default_connection_id": "local"}, false)
	go c.writeLoop(ctx)

	for {
		typ, data, err := conn.Read(ctx)
		if err != nil {
			return
		}
		if typ != websocket.MessageText {
			continue
		}
		var req RPCRequest
		if err := json.Unmarshal(data, &req); err != nil {
			c.sendError(nil, "invalid bridge request")
			continue
		}
		if req.Method == "" {
			c.sendError(req.ID, "missing method")
			continue
		}
		go func(req RPCRequest) {
			callCtx, cancel := context.WithTimeout(ctx, 60*time.Second)
			defer cancel()
			result, err := s.dispatch(callCtx, c, req)
			if len(req.ID) == 0 || string(req.ID) == "null" {
				return
			}
			if err != nil {
				c.sendError(req.ID, err.Error())
				return
			}
			c.enqueue(map[string]any{"id": req.ID, "result": result}, true)
		}(req)
	}
}

func (c *Client) writeLoop(ctx context.Context) {
	ticker := time.NewTicker(25 * time.Second)
	defer ticker.Stop()
	for {
		select {
		case data := <-c.sendCh:
			wctx, cancel := context.WithTimeout(ctx, 10*time.Second)
			err := c.conn.Write(wctx, websocket.MessageText, data)
			cancel()
			if err != nil {
				c.Close()
				return
			}
		case <-ticker.C:
			pctx, cancel := context.WithTimeout(ctx, 10*time.Second)
			err := c.conn.Ping(pctx)
			cancel()
			if err != nil {
				c.Close()
				return
			}
		case <-c.done:
			return
		}
	}
}

func (c *Client) enqueue(v any, block bool) {
	b, err := json.Marshal(v)
	if err != nil {
		log.Printf("marshal push: %v", err)
		return
	}
	if block {
		select {
		case c.sendCh <- b:
		case <-c.done:
		}
		return
	}
	select {
	case c.sendCh <- b:
	case <-c.done:
	default:
		// repaint frames and notifications are disposable; RPC responses block
	}
}

func (c *Client) sendError(id json.RawMessage, message string) {
	if len(id) == 0 {
		id = json.RawMessage("null")
	}
	c.enqueue(map[string]any{"id": id, "error": map[string]any{"message": message}}, true)
}

func (c *Client) Close() {
	c.once.Do(func() {
		close(c.done)
		_ = c.conn.Close(websocket.StatusNormalClosure, "")
	})
}

func (c *Client) addTerminal(id string) {
	c.mu.Lock()
	c.terminal[id] = struct{}{}
	c.mu.Unlock()
}

func (c *Client) terminals() []string {
	c.mu.Lock()
	defer c.mu.Unlock()
	out := make([]string, 0, len(c.terminal))
	for id := range c.terminal {
		out = append(out, id)
	}
	return out
}

func (s *Server) addClient(c *Client) {
	s.mu.Lock()
	s.clients[c] = struct{}{}
	s.mu.Unlock()
}

func (s *Server) removeClient(c *Client) {
	s.mu.Lock()
	delete(s.clients, c)
	s.mu.Unlock()
}

func (s *Server) countClients() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return len(s.clients)
}

var errNoConnection = errors.New("connection is not available")
