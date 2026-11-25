package main

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// Exposer publishes a loopback bridge to wherever a phone can reach it. A
// provider owns one mechanism; the bridge only needs the address it produced.
type Exposer interface {
	Name() string
	// Ensure publishes localAddr and returns the URL a client should dial.
	Ensure(ctx context.Context, localAddr string) (string, error)
	// Status reports what is published right now without changing it.
	Status(ctx context.Context) (Exposure, error)
	Teardown(ctx context.Context) error
}

type Exposure struct {
	Provider string `json:"provider"`
	State    string `json:"state"`
	URL      string `json:"url,omitempty"`
	Detail   string `json:"detail,omitempty"`
}

const (
	exposeOff       = "off"
	exposePublished = "published"
	exposePartial   = "partial"
	exposeError     = "error"
)

// newExposer resolves a provider name. An unknown name is an operator typo,
// so it fails loudly instead of silently serving loopback only.
func newExposer(name, stateDir string, ingress *Ingress) (Exposer, error) {
	switch strings.ToLower(strings.TrimSpace(name)) {
	case "", "none":
		return nil, nil
	case "tailscale":
		return &tailscaleExposer{ingress: ingress}, nil
	case "tailscale-funnel":
		return &tailscaleExposer{ingress: ingress, funnel: true}, nil
	case "cloudflared":
		return &cloudflaredExposer{ingress: ingress, stateDir: stateDir}, nil
	default:
		return nil, fmt.Errorf("unknown expose provider %q (want none, tailscale or cloudflared)", name)
	}
}

// exposureTimeout bounds an external CLI so a hung tunnel cannot stall start.
func exposureTimeout() (context.Context, context.CancelFunc) {
	return context.WithTimeout(context.Background(), 30*time.Second)
}

func statePath(dir, name string) string {
	return filepath.Join(dir, "expose", name)
}

func readStateFile(path string) string {
	b, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(b))
}

func writeStateFile(path, value string) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	return os.WriteFile(path, []byte(value+"\n"), 0o600)
}
