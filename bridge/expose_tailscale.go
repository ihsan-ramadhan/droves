package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os/exec"
	"strconv"
	"strings"
)

// tailscaleExposer configures the local tailscaled. It never starts a daemon:
// a bridge on a machine without Tailscale stays loopback only.
type tailscaleExposer struct {
	ingress *Ingress
	// funnel publishes to the open internet instead of the tailnet
	funnel bool
	// port is the HTTPS port Tailscale listens on, 0 picks the default
	port int
}

func (t *tailscaleExposer) Name() string {
	if t.funnel {
		return "tailscale-funnel"
	}
	return "tailscale"
}

type tailscaleServeStatus struct {
	TCP         map[string]json.RawMessage `json:"TCP"`
	Web         map[string]tailscaleWeb    `json:"Web"`
	AllowFunnel map[string]bool            `json:"AllowFunnel"`
}

type tailscaleWeb struct {
	Handlers map[string]struct {
		Proxy string `json:"Proxy"`
	} `json:"Handlers"`
}

func (t *tailscaleExposer) binary() (string, error) {
	path, err := exec.LookPath("tailscale")
	if err != nil {
		return "", fmt.Errorf("tailscale is not installed or not on PATH")
	}
	return path, nil
}

func (t *tailscaleExposer) serveJSON(ctx context.Context) (*tailscaleServeStatus, error) {
	bin, err := t.binary()
	if err != nil {
		return nil, err
	}
	out, err := exec.CommandContext(ctx, bin, "serve", "status", "--json").Output()
	if err != nil {
		return nil, fmt.Errorf("tailscale serve status: %w", err)
	}
	var st tailscaleServeStatus
	if len(strings.TrimSpace(string(out))) > 0 {
		if err := json.Unmarshal(out, &st); err != nil {
			return nil, fmt.Errorf("tailscale serve status: %w", err)
		}
	}
	return &st, nil
}

// ownEndpoint finds the serve entry pointing at this bridge, so status reports
// what the bridge published rather than whatever else the node serves.
func (t *tailscaleExposer) ownEndpoint(st *tailscaleServeStatus, localAddr string) (host string, port int, funnel bool) {
	want := "http://" + localAddr
	for key, web := range st.Web {
		for _, h := range web.Handlers {
			if !strings.EqualFold(strings.TrimSuffix(h.Proxy, "/"), strings.TrimSuffix(want, "/")) {
				continue
			}
			host, port = splitHostPort(key)
			if port == 0 {
				port = 443
			}
			return host, port, st.AllowFunnel[key]
		}
	}
	return "", 0, false
}

func splitHostPort(v string) (string, int) {
	idx := strings.LastIndexByte(v, ':')
	if idx < 0 {
		return v, 0
	}
	port, err := strconv.Atoi(v[idx+1:])
	if err != nil {
		return v, 0
	}
	return v[:idx], port
}

func (t *tailscaleExposer) Status(ctx context.Context) (Exposure, error) {
	exp := Exposure{Provider: t.Name()}
	st, err := t.serveJSON(ctx)
	if err != nil {
		exp.State = exposeError
		exp.Detail = err.Error()
		return exp, nil
	}
	addr := "127.0.0.1:13030"
	if host, port, funnel := t.ownEndpoint(st, addr); host != "" {
		scheme := "https"
		url := fmt.Sprintf("%s://%s", scheme, host)
		if port != 443 {
			url += ":" + strconv.Itoa(port)
		}
		exp.State = exposePublished
		exp.URL = url
		if funnel {
			exp.Provider = "tailscale-funnel"
			exp.Detail = "reachable from the open internet"
		} else {
			exp.Detail = "reachable from your tailnet only"
		}
		return exp, nil
	}
	exp.State = exposeOff
	exp.Detail = "no serve entry points at this bridge"
	return exp, nil
}

// Ensure runs serve (or funnel) for the bridge and returns the URL it published.
// --bg keeps the config in tailscaled, so a bridge restart does not republish.
// A failed publish never tears an existing route down: the previous endpoint
// may still be serving and is reported by Status as partial.
func (t *tailscaleExposer) Ensure(ctx context.Context, localAddr string) (string, error) {
	bin, err := t.binary()
	if err != nil {
		return "", err
	}
	sub := "serve"
	if t.funnel {
		sub = "funnel"
	}
	args := []string{sub, "--bg", "--yes"}
	if t.port != 0 {
		args = append(args, "--https", strconv.Itoa(t.port))
	}
	args = append(args, localAddr)
	out, err := exec.CommandContext(ctx, bin, args...).CombinedOutput()
	if err != nil {
		return "", fmt.Errorf("tailscale %s: %v: %s", sub, err, strings.TrimSpace(string(out)))
	}
	st, err := t.serveJSON(ctx)
	if err != nil {
		return "", err
	}
	host, port, funnel := t.ownEndpoint(st, localAddr)
	if host == "" {
		return "", fmt.Errorf("tailscale %s ran but no serve entry matches %s", sub, localAddr)
	}
	if port == 0 {
		port = 443
	}
	url := fmt.Sprintf("https://%s", host)
	if port != 443 {
		url += ":" + strconv.Itoa(port)
	}
	if !funnel && t.funnel {
		return url, fmt.Errorf("funnel is not enabled for %s; run tailscale funnel --bg %s and check the admin console", host, localAddr)
	}
	return url, nil
}

// Teardown removes only this bridge's handler; other services on the node keep
// whatever the operator configured.
func (t *tailscaleExposer) Teardown(ctx context.Context) error {
	bin, err := t.binary()
	if err != nil {
		return err
	}
	st, err := t.serveJSON(ctx)
	if err != nil {
		return err
	}
	host, port, _ := t.ownEndpoint(st, "127.0.0.1:13030")
	if host == "" {
		return nil
	}
	sub := "serve"
	if t.funnel {
		sub = "funnel"
	}
	target := fmt.Sprintf("https://%s:%d", host, port)
	if port == 443 {
		target = "https://" + host
	}
	out, err := exec.CommandContext(ctx, bin, sub, "clear", target).CombinedOutput()
	if err != nil {
		return fmt.Errorf("tailscale %s clear: %v: %s", sub, err, strings.TrimSpace(string(out)))
	}
	return nil
}
