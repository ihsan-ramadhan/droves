package main

import (
	"fmt"
	"net"
	"net/http"
	"net/url"
	"strings"
	"sync"
)

// Ingress is how requests reach the bridge from outside: which hops may speak
// for the client, and the address people type. A bare Ingress means loopback
// only, which is what a bridge behind no proxy sees.
type Ingress struct {
	mu       sync.RWMutex
	public   *url.URL
	trusted  []*net.IPNet
	basePath string
}

func parseIngress(publicURL, trustedProxies string) (*Ingress, error) {
	in := &Ingress{}
	if v := strings.TrimSpace(publicURL); v != "" {
		u, err := url.Parse(v)
		if err != nil {
			return nil, fmt.Errorf("public url %q: %w", v, err)
		}
		if (u.Scheme != "http" && u.Scheme != "https") || u.Host == "" {
			return nil, fmt.Errorf("public url %q: want http(s)://host[:port][/path]", v)
		}
		u.Path = strings.TrimSuffix(u.Path, "/")
		in.public = u
		in.basePath = u.Path
	}
	for _, raw := range strings.Split(trustedProxies, ",") {
		cidr, err := parseProxyCIDR(strings.TrimSpace(raw))
		if err != nil {
			return nil, err
		}
		if cidr != nil {
			in.trusted = append(in.trusted, cidr)
		}
	}
	return in, nil
}

func parseProxyCIDR(v string) (*net.IPNet, error) {
	if v == "" {
		return nil, nil
	}
	if ip := net.ParseIP(v); ip != nil {
		if ip.To4() != nil {
			v += "/32"
		} else {
			v += "/128"
		}
	}
	_, cidr, err := net.ParseCIDR(v)
	if err != nil {
		return nil, fmt.Errorf("trusted proxy %q: want an IP or CIDR", v)
	}
	return cidr, nil
}

// SetPublicURL is called at runtime once a tunnel reports the address it
// published, so the bridge does not need the URL baked into its config.
func (in *Ingress) SetPublicURL(raw string) error {
	if in == nil {
		return nil
	}
	raw = strings.TrimSpace(raw)
	in.mu.Lock()
	defer in.mu.Unlock()
	if raw == "" {
		in.public = nil
		return nil
	}
	u, err := url.Parse(raw)
	if err != nil {
		return err
	}
	if (u.Scheme != "http" && u.Scheme != "https") || u.Host == "" {
		return fmt.Errorf("public url %q: want http(s)://host[:port][/path]", raw)
	}
	if in.basePath != "" {
		u.Path = in.basePath
	} else {
		in.basePath = strings.TrimSuffix(u.Path, "/")
		u.Path = in.basePath
	}
	in.public = u
	return nil
}

// SetBasePath lets a mount prefix exist without a public URL, which is the
// case when the proxy rewriting the path is the only thing that knows it.
func (in *Ingress) SetBasePath(p string) {
	if in == nil {
		return
	}
	in.mu.Lock()
	defer in.mu.Unlock()
	p = strings.TrimSpace(p)
	if p == "" || p == "/" {
		// no explicit prefix: keep whatever path came from -public-url
		return
	}
	in.basePath = "/" + strings.Trim(p, "/")
	if in.public != nil {
		in.public.Path = in.basePath
	}
}

func (in *Ingress) BasePath() string {
	if in == nil {
		return ""
	}
	in.mu.RLock()
	defer in.mu.RUnlock()
	return in.basePath
}

func (in *Ingress) PublicURL() string {
	if in == nil {
		return ""
	}
	in.mu.RLock()
	defer in.mu.RUnlock()
	if in.public == nil {
		return ""
	}
	return in.public.String()
}

// CookiePath keeps the session cookie inside the mount prefix.
func (in *Ingress) CookiePath() string {
	path := in.BasePath()
	if path == "" {
		return "/"
	}
	return path + "/"
}

func (in *Ingress) trustedPeer(ip net.IP) bool {
	if in == nil || ip == nil {
		return false
	}
	for _, cidr := range in.trusted {
		if cidr.Contains(ip) {
			return true
		}
	}
	return false
}

func peerIP(r *http.Request) net.IP {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		host = r.RemoteAddr
	}
	return net.ParseIP(host)
}

// ClientIP is the address a rate limit follows. Forwarded headers only count
// when the hop that set them is trusted; otherwise any client picks its own.
func (in *Ingress) ClientIP(r *http.Request) string {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		host = r.RemoteAddr
	}
	if !in.trustedPeer(net.ParseIP(host)) {
		return host
	}
	hops := strings.Split(r.Header.Get("X-Forwarded-For"), ",")
	for i := len(hops) - 1; i >= 0; i-- {
		hop := strings.TrimSpace(hops[i])
		if hop == "" {
			continue
		}
		if !in.trustedPeer(net.ParseIP(hop)) {
			return hop
		}
	}
	return host
}

// Scheme is the scheme the browser used; a tunnel terminates TLS before the
// bridge ever sees it.
func (in *Ingress) Scheme(r *http.Request) string {
	if in.trustedPeer(peerIP(r)) {
		if v := strings.ToLower(strings.TrimSpace(r.Header.Get("X-Forwarded-Proto"))); v == "http" || v == "https" {
			return v
		}
	}
	if r.TLS != nil {
		return "https"
	}
	return "http"
}

func (in *Ingress) Secure(r *http.Request) bool {
	return in.Scheme(r) == "https"
}

// AllowsOrigin guards the WebSocket. A proxy may rewrite Host, so the public
// address and a trusted Forwarded-Host count as the same origin as the page.
func (in *Ingress) AllowsOrigin(r *http.Request, origin string) bool {
	if origin == "" {
		return true
	}
	u, err := url.Parse(origin)
	if err != nil || u.Host == "" {
		return false
	}
	candidates := []string{r.Host}
	if in != nil {
		in.mu.RLock()
		if in.public != nil {
			candidates = append(candidates, in.public.Host)
		}
		in.mu.RUnlock()
		if in.trustedPeer(peerIP(r)) {
			if host := strings.TrimSpace(r.Header.Get("X-Forwarded-Host")); host != "" {
				candidates = append(candidates, host)
			}
		}
	}
	for _, c := range candidates {
		if c != "" && strings.EqualFold(c, u.Host) {
			return true
		}
	}
	return false
}

func (in *Ingress) describe() map[string]any {
	proxies := []string{}
	if in != nil {
		for _, cidr := range in.trusted {
			proxies = append(proxies, cidr.String())
		}
	}
	return map[string]any{
		"public_url":      in.PublicURL(),
		"base_path":       in.BasePath(),
		"trusted_proxies": proxies,
	}
}
