package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// runExpose reports or configures the publishing provider without starting the
// bridge, so an operator can check reachability while debugging a tunnel.
func runExpose(args []string) int {
	home, _ := os.UserHomeDir()
	cfg := Config{
		StateDir:     envOr("DROVES_STATE_DIR", filepath.Join(home, ".local/state/droves-bridge")),
		PublicURL:    envOr("DROVES_PUBLIC_URL", ""),
		BasePath:     envOr("DROVES_BASE_PATH", ""),
		TrustedPeers: envOr("DROVES_TRUSTED_PROXIES", "127.0.0.0/8,::1"),
		Expose:       envOr("DROVES_EXPOSE", "none"),
		ExposePort:   envIntOr("DROVES_EXPOSE_PORT", 0),
	}
	fs := flagSet("expose")
	fs.StringVar(&cfg.Expose, "provider", cfg.Expose, "none, tailscale, tailscale-funnel or cloudflared")
	fs.StringVar(&cfg.PublicURL, "public-url", cfg.PublicURL, "address clients use")
	fs.IntVar(&cfg.ExposePort, "expose-port", cfg.ExposePort, "HTTPS port for tailscale")
	action := "status"
	if len(args) > 0 && !strings.HasPrefix(args[0], "-") {
		action = args[0]
		args = args[1:]
	}
	if err := fs.Parse(args); err != nil {
		return flagExit(err)
	}

	ingress, err := parseIngress(cfg.PublicURL, cfg.TrustedPeers)
	if err != nil {
		fmt.Fprintf(os.Stderr, "expose: %v\n", err)
		return 1
	}
	ingress.SetBasePath(cfg.BasePath)
	exposer, err := newExposer(cfg.Expose, cfg.StateDir, ingress)
	if err != nil {
		fmt.Fprintf(os.Stderr, "expose: %v\n", err)
		return 1
	}

	switch action {
	case "token":
		if fs.NArg() == 0 {
			fmt.Fprintln(os.Stderr, "pass the token: droves-bridge expose token -provider cloudflared <TOKEN>")
			return 2
		}
		cf, ok := exposer.(*cloudflaredExposer)
		if !ok {
			fmt.Fprintln(os.Stderr, "expose token: only the cloudflared provider takes a token")
			return 2
		}
		if err := cf.SetToken(fs.Arg(0)); err != nil {
			fmt.Fprintf(os.Stderr, "expose token: %v\n", err)
			return 1
		}
		fmt.Printf("token stored at %s (mode 0600)\n", cf.tokenPath())
		return 0
	case "status":
		if exposer == nil {
			fmt.Println("provider: none (reachable on loopback only)")
			return 0
		}
		if ts, ok := exposer.(*tailscaleExposer); ok {
			ts.port = cfg.ExposePort
		}
		ctx, cancel := exposureTimeout()
		defer cancel()
		exp, err := exposer.Status(ctx)
		if err != nil {
			fmt.Fprintf(os.Stderr, "expose: %v\n", err)
			return 1
		}
		printExposure(exp)
		if exp.State == exposeError {
			return 1
		}
		return 0
	case "off":
		ctx, cancel := exposureTimeout()
		defer cancel()
		if exposer == nil {
			return 0
		}
		if err := exposer.Teardown(ctx); err != nil {
			fmt.Fprintf(os.Stderr, "expose off: %v\n", err)
			return 1
		}
		fmt.Printf("%s: cleared\n", exposer.Name())
		return 0
	default:
		fmt.Fprintf(os.Stderr, "unknown expose action %q (want status, token or off)\n", action)
		return 2
	}
}

func printExposure(exp Exposure) {
	fmt.Printf("provider: %s\n", exp.Provider)
	fmt.Printf("state:    %s\n", exp.State)
	if exp.URL != "" {
		fmt.Printf("url:      %s\n", exp.URL)
	}
	if exp.Detail != "" {
		fmt.Printf("detail:   %s\n", exp.Detail)
	}
}
