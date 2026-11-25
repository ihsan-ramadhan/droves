package main

import (
	"context"
	"errors"
	"fmt"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

// cloudflaredExposer supervises one outbound connector. The tunnel token is the
// only credential: whoever holds it can run the tunnel, so it lives in the
// state dir at 0600 and is passed by file, never by argv.
type cloudflaredExposer struct {
	ingress  *Ingress
	stateDir string

	mu      sync.Mutex
	cmd     *exec.Cmd
	port    int
	lastErr string
}

func (c *cloudflaredExposer) Name() string { return "cloudflared" }

func (c *cloudflaredExposer) tokenPath() string {
	return statePath(c.stateDir, "cloudflared-token")
}

func (c *cloudflaredExposer) metricsAddr() string {
	return fmt.Sprintf("127.0.0.1:%d", c.port)
}

// startPort is fixed so a restart reuses the known metrics address instead of
// guessing which one the running connector grabbed.
func (c *cloudflaredExposer) startPort() int {
	if c.port != 0 {
		return c.port
	}
	return 20245
}

func (c *cloudflaredExposer) token() (string, error) {
	token := readStateFile(c.tokenPath())
	if token == "" {
		return "", fmt.Errorf("no tunnel token at %s", c.tokenPath())
	}
	return token, nil
}

func (c *cloudflaredExposer) binary() (string, error) {
	path, err := exec.LookPath("cloudflared")
	if err != nil {
		return "", fmt.Errorf("cloudflared is not installed or not on PATH")
	}
	return path, nil
}

// ready reports whether the connector has an active edge connection. cloudflared
// publishes /ready on its metrics listener exactly for this.
func (c *cloudflaredExposer) ready(ctx context.Context) bool {
	client := &http.Client{Timeout: 2 * time.Second}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, "http://"+c.metricsAddr()+"/ready", nil)
	if err != nil {
		return false
	}
	resp, err := client.Do(req)
	if err != nil {
		return false
	}
	defer resp.Body.Close()
	return resp.StatusCode == http.StatusOK
}

func (c *cloudflaredExposer) Status(ctx context.Context) (Exposure, error) {
	exp := Exposure{Provider: c.Name()}
	url := c.ingress.PublicURL()
	exp.URL = url
	if _, err := c.token(); err != nil {
		exp.State = exposeOff
		exp.Detail = err.Error()
		return exp, nil
	}
	if c.ready(ctx) {
		exp.State = exposePublished
		exp.Detail = "connector is connected to Cloudflare"
		if url == "" {
			exp.State = exposePartial
			exp.Detail += "; set -public-url to the hostname routed to this tunnel"
		}
		return exp, nil
	}
	c.mu.Lock()
	lastErr := c.lastErr
	running := c.cmd != nil
	c.mu.Unlock()
	if lastErr != "" {
		exp.State = exposeError
		exp.Detail = lastErr
		return exp, nil
	}
	exp.State = exposeOff
	if running {
		exp.Detail = "connector started but has no edge connection yet"
	} else {
		exp.Detail = "connector is not running"
	}
	return exp, nil
}

// Ensure launches the connector and waits for the edge handshake so a caller
// knows whether the address is usable instead of assuming it.
func (c *cloudflaredExposer) Ensure(ctx context.Context, localAddr string) (string, error) {
	_ = localAddr // the tunnel's ingress rules live in Cloudflare, not here
	if _, err := c.token(); err != nil {
		return "", err
	}
	bin, err := c.binary()
	if err != nil {
		return "", err
	}
	c.mu.Lock()
	if c.cmd != nil && c.cmd.Process != nil && c.cmd.ProcessState == nil {
		c.mu.Unlock()
		return c.waitReady(ctx)
	}
	if c.port == 0 {
		port, err := freeLocalPort()
		if err != nil {
			c.mu.Unlock()
			return "", err
		}
		c.port = port
	}
	tokenFile := c.tokenPath()
	if err := os.Chmod(tokenFile, 0o600); err != nil {
		c.mu.Unlock()
		return "", err
	}
	cmd := exec.Command(bin,
		"tunnel",
		"--metrics", c.metricsAddr(),
		"--no-autoupdate",
		"run",
		"--token-file", tokenFile,
	)
	cmd.Stdout = nil
	cmd.Stderr = nil
	if err := cmd.Start(); err != nil {
		c.mu.Unlock()
		return "", fmt.Errorf("cloudflared: %w", err)
	}
	c.cmd = cmd
	c.lastErr = ""
	c.mu.Unlock()

	// reap in the background; a dead connector must not leave a zombie or keep
	// Status claiming it is running
	go func() {
		err := cmd.Wait()
		c.mu.Lock()
		if c.cmd == cmd {
			c.cmd = nil
			if err != nil {
				c.lastErr = fmt.Sprintf("connector exited: %v", err)
			}
		}
		c.mu.Unlock()
	}()
	return c.waitReady(ctx)
}

func (c *cloudflaredExposer) waitReady(ctx context.Context) (string, error) {
	deadline := time.Now().Add(25 * time.Second)
	for {
		if c.ready(ctx) {
			url := c.ingress.PublicURL()
			if url == "" {
				return "", errors.New("connector is up; pass -public-url with the hostname routed to this tunnel")
			}
			return url, nil
		}
		if time.Now().After(deadline) {
			c.mu.Lock()
			lastErr := c.lastErr
			c.mu.Unlock()
			if lastErr != "" {
				return "", errors.New(lastErr)
			}
			return "", errors.New("cloudflared did not report ready within 25s")
		}
		select {
		case <-ctx.Done():
			return "", ctx.Err()
		case <-time.After(500 * time.Millisecond):
		}
	}
}

func (c *cloudflaredExposer) Teardown(ctx context.Context) error {
	c.mu.Lock()
	cmd := c.cmd
	c.cmd = nil
	c.mu.Unlock()
	if cmd == nil || cmd.Process == nil {
		return nil
	}
	if err := cmd.Process.Signal(os.Interrupt); err != nil {
		return cmd.Process.Kill()
	}
	return nil
}

// freeLocalPort keeps the metrics listener from colliding with whatever else
// the host already runs.
func freeLocalPort() (int, error) {
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return 0, err
	}
	defer l.Close()
	return l.Addr().(*net.TCPAddr).Port, nil
}

// SetToken stores the tunnel token, which is the whole credential for a
// remotely-managed tunnel.
func (c *cloudflaredExposer) SetToken(token string) error {
	token = strings.TrimSpace(token)
	if token == "" {
		return errors.New("empty tunnel token")
	}
	if err := os.MkdirAll(filepath.Dir(c.tokenPath()), 0o700); err != nil {
		return err
	}
	return writeStateFile(c.tokenPath(), token)
}
