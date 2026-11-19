package main

import (
	"bufio"
	"context"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"sync"
	"time"
)

// Herdr resizes panes only for the shell owning the surface; one endpoint
// connection points at the watched pane, reads stay on the NDJSON control socket
type ShellEndpoint struct {
	path  string
	herdr *Herdr

	mu      sync.Mutex
	desired shellRequest
	hasWork bool
	conn    net.Conn
	bootID  string
	paneID  string
	cols    int
	rows    int
	closed  bool

	wake chan struct{}
	quit chan struct{}
}

type shellRequest struct {
	paneID string
	cols   int
	rows   int
}

const (
	endpointGeneration = 1
	endpointHelloKind  = "endpoint.hello.v1"
	endpointSnapKind   = "shell.snapshot.v1"
	endpointMaxFrame   = 64 << 20
)

func NewShellEndpoint(path string, herdr *Herdr) *ShellEndpoint {
	e := &ShellEndpoint{
		path:  path,
		herdr: herdr,
		wake:  make(chan struct{}, 1),
		quit:  make(chan struct{}),
	}
	go e.run()
	return e
}

// Resize never blocks on the Herdr socket; only the newest geometry is applied
func (e *ShellEndpoint) Resize(paneID string, cols, rows int) {
	if e == nil || paneID == "" || cols < 2 || rows < 2 {
		return
	}
	e.mu.Lock()
	e.desired = shellRequest{paneID: paneID, cols: cols, rows: rows}
	e.hasWork = true
	e.mu.Unlock()
	e.wakeup()
}

// Release gives the surface back to the next Herdr client, usually the desktop UI
func (e *ShellEndpoint) Release() {
	if e == nil {
		return
	}
	e.mu.Lock()
	e.hasWork = false
	conn := e.conn
	e.conn = nil
	e.bootID = ""
	e.paneID = ""
	e.cols = 0
	e.rows = 0
	e.mu.Unlock()
	if conn != nil {
		_ = conn.Close()
	}
}

func (e *ShellEndpoint) Close() {
	if e == nil {
		return
	}
	e.mu.Lock()
	if e.closed {
		e.mu.Unlock()
		return
	}
	e.closed = true
	conn := e.conn
	e.conn = nil
	e.mu.Unlock()
	close(e.quit)
	if conn != nil {
		_ = conn.Close()
	}
}

func (e *ShellEndpoint) run() {
	ticker := time.NewTicker(time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-e.quit:
			return
		case <-e.wake:
		case <-ticker.C:
			e.reclaim()
			continue
		}
		for {
			e.mu.Lock()
			if e.closed {
				e.mu.Unlock()
				return
			}
			if !e.hasWork {
				e.mu.Unlock()
				break
			}
			req := e.desired
			e.hasWork = false
			e.mu.Unlock()

			if err := e.apply(req); err != nil {
				log.Printf("terminal resize: %v", err)
			}
		}
	}
}

func (e *ShellEndpoint) wakeup() {
	select {
	case e.wake <- struct{}{}:
	default:
	}
}

// desktop interaction steals the shared pane geometry; reclaim the viewer's grid
// only while this pane stays focused, otherwise the next resize reclaims it
func (e *ShellEndpoint) reclaim() {
	e.mu.Lock()
	conn, bootID, paneID := e.conn, e.bootID, e.paneID
	cols, rows := e.cols, e.rows
	e.mu.Unlock()
	if conn == nil || paneID == "" || cols < 2 || rows < 2 || e.herdr == nil {
		return
	}

	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	raw, err := e.herdr.Call(ctx, "pane.current", nil)
	if err != nil {
		return
	}
	var current struct {
		Pane struct {
			PaneID string `json:"pane_id"`
		} `json:"pane"`
		PaneID string `json:"pane_id"`
	}
	if json.Unmarshal(raw, &current) != nil {
		return
	}
	if id := current.Pane.PaneID; id != "" && id != paneID {
		return
	} else if id == "" && current.PaneID != paneID {
		return
	}

	raw, err = e.herdr.Call(ctx, "pane.layout", map[string]any{"pane_id": paneID})
	if err != nil {
		return
	}
	var layout struct {
		Layout struct {
			Area struct {
				Width  int `json:"width"`
				Height int `json:"height"`
			} `json:"area"`
		} `json:"layout"`
	}
	if json.Unmarshal(raw, &layout) != nil {
		return
	}
	if layout.Layout.Area.Width == cols && layout.Layout.Area.Height == rows {
		return
	}

	e.mu.Lock()
	if e.conn != conn || e.paneID != paneID || e.cols != cols || e.rows != rows {
		e.mu.Unlock()
		return
	}
	e.mu.Unlock()
	if err := writeFocus(conn, bootID, paneID); err != nil {
		e.drop(conn)
		return
	}
	if err := writeResize(conn, cols, rows); err != nil {
		e.drop(conn)
	}
}

func writeFocus(conn net.Conn, bootID, paneID string) error {
	body, _ := json.Marshal(map[string]any{
		"id":     "droves-focus",
		"method": "pane.focus",
		"params": map[string]any{"pane_id": paneID},
	})
	var payload []byte
	payload = appendVarint(payload, 15) // ClientShellEndpointRequest
	payload = appendString(payload, bootID)
	payload = appendString(payload, string(body))
	return writeEndpointFrame(conn, payload)
}

func writeResize(conn net.Conn, cols, rows int) error {
	var payload []byte
	payload = appendVarint(payload, 12) // ClientShellResize
	payload = appendVarint(payload, 0)  // cell_width_px
	payload = appendVarint(payload, 0)  // cell_height_px
	payload = appendVarint(payload, uint64(cols))
	payload = appendVarint(payload, uint64(rows))
	payload = append(payload, 0) // pixel_mouse
	return writeEndpointFrame(conn, payload)
}

func (e *ShellEndpoint) apply(req shellRequest) error {
	if err := e.ensure(req); err != nil {
		return err
	}

	e.mu.Lock()
	conn := e.conn
	bootID := e.bootID
	paneID := e.paneID
	cols, rows := e.cols, e.rows
	e.mu.Unlock()
	if conn == nil {
		return errors.New("herdr endpoint closed")
	}

	if paneID != req.paneID {
		if err := writeFocus(conn, bootID, req.paneID); err != nil {
			e.drop(conn)
			return fmt.Errorf("focus pane: %w", err)
		}
		e.mu.Lock()
		if e.conn == conn {
			e.paneID = req.paneID
		}
		e.mu.Unlock()
	}

	if cols == req.cols && rows == req.rows && paneID == req.paneID {
		return nil
	}
	if err := writeResize(conn, req.cols, req.rows); err != nil {
		e.drop(conn)
		return fmt.Errorf("resize pane: %w", err)
	}
	e.mu.Lock()
	if e.conn == conn {
		e.cols = req.cols
		e.rows = req.rows
	}
	e.mu.Unlock()
	return nil
}

func (e *ShellEndpoint) ensure(req shellRequest) error {
	e.mu.Lock()
	if e.closed {
		e.mu.Unlock()
		return errors.New("endpoint controller is closed")
	}
	if e.conn != nil {
		e.mu.Unlock()
		return nil
	}
	e.mu.Unlock()

	d := net.Dialer{Timeout: 2 * time.Second}
	conn, err := d.Dial("unix", e.path)
	if err != nil {
		return fmt.Errorf("connect %s: %w", e.path, err)
	}
	br := bufio.NewReaderSize(conn, 64<<10)
	if err := conn.SetDeadline(time.Now().Add(3 * time.Second)); err != nil {
		_ = conn.Close()
		return err
	}

	hello, _ := json.Marshal(map[string]any{
		"generation":           endpointGeneration,
		"cell_width_px":        0,
		"cell_height_px":       0,
		"surface_size":         map[string]int{"cols": req.cols, "rows": req.rows},
		"pixel_mouse":          false,
		"direct_graphics":      false,
		"endpoint_keybindings": false,
		"mouse_capture":        false,
		"surface_active":       true,
		"surface_delta":        false,
		"surface_reuse":        false,
		"snapshot_codecs":      []string{"shell.snapshot.v1"},
		"surface_codecs":       []string{"shell.surface.v1"},
		"input_codecs":         []string{"shell.input.semantic.v1"},
		"blob_codecs":          []string{"shell.blob.v1"},
	})
	var payload []byte
	payload = appendVarint(payload, 20) // EndpointControl
	payload = appendString(payload, endpointHelloKind)
	payload = appendString(payload, string(hello))
	if err := writeEndpointFrame(conn, payload); err != nil {
		_ = conn.Close()
		return fmt.Errorf("endpoint hello: %w", err)
	}

	bootID := ""
	for bootID == "" {
		kind, data, err := readEndpointControl(br)
		if err != nil {
			_ = conn.Close()
			return fmt.Errorf("endpoint handshake: %w", err)
		}
		if kind != endpointSnapKind {
			continue
		}
		var raw struct {
			BootID string `json:"boot_id"`
		}
		if err := json.Unmarshal([]byte(data), &raw); err != nil {
			_ = conn.Close()
			return fmt.Errorf("endpoint snapshot: %w", err)
		}
		bootID = raw.BootID
	}
	if err := conn.SetDeadline(time.Time{}); err != nil {
		_ = conn.Close()
		return err
	}

	e.mu.Lock()
	if e.closed || e.conn != nil {
		e.mu.Unlock()
		_ = conn.Close()
		return nil
	}
	e.conn = conn
	e.bootID = bootID
	e.paneID = ""
	e.cols = req.cols
	e.rows = req.rows
	e.mu.Unlock()
	go e.readLoop(conn, br)
	return nil
}

func (e *ShellEndpoint) readLoop(conn net.Conn, br *bufio.Reader) {
	defer e.drop(conn)
	for {
		if _, err := readEndpointPayload(br); err != nil {
			return
		}
	}
}

func (e *ShellEndpoint) drop(conn net.Conn) {
	e.mu.Lock()
	if e.conn == conn {
		e.conn = nil
		e.bootID = ""
		e.paneID = ""
		e.cols = 0
		e.rows = 0
	}
	e.mu.Unlock()
	_ = conn.Close()
}

func writeEndpointFrame(w io.Writer, payload []byte) error {
	if len(payload) > endpointMaxFrame {
		return errors.New("endpoint frame too large")
	}
	var head [4]byte
	binary.LittleEndian.PutUint32(head[:], uint32(len(payload)))
	if _, err := w.Write(head[:]); err != nil {
		return err
	}
	_, err := w.Write(payload)
	return err
}

func readEndpointPayload(r io.Reader) ([]byte, error) {
	var head [4]byte
	if _, err := io.ReadFull(r, head[:]); err != nil {
		return nil, err
	}
	n := binary.LittleEndian.Uint32(head[:])
	if n > endpointMaxFrame {
		return nil, fmt.Errorf("oversized endpoint frame: %d", n)
	}
	payload := make([]byte, n)
	if _, err := io.ReadFull(r, payload); err != nil {
		return nil, err
	}
	return payload, nil
}

func readEndpointControl(r io.Reader) (string, string, error) {
	payload, err := readEndpointPayload(r)
	if err != nil {
		return "", "", err
	}
	off := 0
	variant, err := readVarint(payload, &off)
	if err != nil {
		return "", "", err
	}
	if variant != 20 {
		return "", "", nil
	}
	kind, err := readBincodeString(payload, &off)
	if err != nil {
		return "", "", err
	}
	data, err := readBincodeString(payload, &off)
	if err != nil {
		return "", "", err
	}
	return kind, data, nil
}

func appendVarint(dst []byte, v uint64) []byte {
	switch {
	case v < 251:
		return append(dst, byte(v))
	case v <= 0xffff:
		return append(dst, 251, byte(v), byte(v>>8))
	case v <= 0xffffffff:
		return append(dst, 252, byte(v), byte(v>>8), byte(v>>16), byte(v>>24))
	default:
		dst = append(dst, 253)
		for i := 0; i < 8; i++ {
			dst = append(dst, byte(v>>(8*i)))
		}
		return dst
	}
}

func appendString(dst []byte, s string) []byte {
	dst = appendVarint(dst, uint64(len(s)))
	return append(dst, s...)
}

func readVarint(src []byte, off *int) (uint64, error) {
	if *off >= len(src) {
		return 0, io.ErrUnexpectedEOF
	}
	first := src[*off]
	*off++
	switch {
	case first < 251:
		return uint64(first), nil
	case first == 251:
		if *off+2 > len(src) {
			return 0, io.ErrUnexpectedEOF
		}
		v := uint64(binary.LittleEndian.Uint16(src[*off:]))
		*off += 2
		return v, nil
	case first == 252:
		if *off+4 > len(src) {
			return 0, io.ErrUnexpectedEOF
		}
		v := uint64(binary.LittleEndian.Uint32(src[*off:]))
		*off += 4
		return v, nil
	case first == 253:
		if *off+8 > len(src) {
			return 0, io.ErrUnexpectedEOF
		}
		v := binary.LittleEndian.Uint64(src[*off:])
		*off += 8
		return v, nil
	default:
		return 0, fmt.Errorf("bincode: invalid varint marker %d", first)
	}
}

func readBincodeString(src []byte, off *int) (string, error) {
	n, err := readVarint(src, off)
	if err != nil {
		return "", err
	}
	if n > uint64(len(src)-*off) {
		return "", io.ErrUnexpectedEOF
	}
	s := string(src[*off : *off+int(n)])
	*off += int(n)
	return s, nil
}
