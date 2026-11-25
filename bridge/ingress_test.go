package main

import (
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestClientIPFromTrustedProxy(t *testing.T) {
	in, err := parseIngress("", "127.0.0.0/8,::1")
	if err != nil {
		t.Fatal(err)
	}
	r := httptest.NewRequest(http.MethodPost, "/api/login", nil)
	r.RemoteAddr = "127.0.0.1:5555"
	r.Header.Set("X-Forwarded-For", "10.0.0.1, 203.0.113.4")
	if got := in.ClientIP(r); got != "203.0.113.4" {
		t.Fatalf("ClientIP = %q", got)
	}

	r2 := httptest.NewRequest(http.MethodPost, "/api/login", nil)
	r2.RemoteAddr = "203.0.113.9:5555"
	r2.Header.Set("X-Forwarded-For", "198.51.100.7")
	if got := in.ClientIP(r2); got != "203.0.113.9" {
		t.Fatalf("untrusted ClientIP = %q", got)
	}
}

func TestAllowsOriginBehindProxy(t *testing.T) {
	in, err := parseIngress("https://droves.example.com/bridge", "127.0.0.0/8,::1")
	if err != nil {
		t.Fatal(err)
	}
	r := httptest.NewRequest(http.MethodGet, "/ws", nil)
	r.RemoteAddr = "127.0.0.1:5555"
	r.Host = "127.0.0.1:13030"
	r.Header.Set("X-Forwarded-Host", "droves.example.com")
	if !in.AllowsOrigin(r, "https://droves.example.com") {
		t.Fatal("public origin was rejected")
	}
	if in.AllowsOrigin(r, "https://evil.example.com") {
		t.Fatal("unrelated origin was allowed")
	}
}

func TestSecureFollowsForwardedProto(t *testing.T) {
	in, err := parseIngress("", "127.0.0.0/8,::1")
	if err != nil {
		t.Fatal(err)
	}
	r := httptest.NewRequest(http.MethodPost, "/api/login", nil)
	r.RemoteAddr = "127.0.0.1:5555"
	r.Header.Set("X-Forwarded-Proto", "https")
	if !in.Secure(r) {
		t.Fatal("cookie must be Secure behind TLS-terminating proxy")
	}
	if in.CookiePath() != "/" {
		t.Fatalf("CookiePath = %q", in.CookiePath())
	}
	in.SetBasePath("/bridge")
	if in.CookiePath() != "/bridge/" {
		t.Fatalf("mounted CookiePath = %q", in.CookiePath())
	}
}

func TestParseIngressRejectsBadInput(t *testing.T) {
	if _, err := parseIngress("ftp://host", ""); err == nil {
		t.Fatal("accepted non-http public URL")
	}
	if _, err := parseIngress("", "not-an-ip"); err == nil {
		t.Fatal("accepted bad proxy CIDR")
	}
}
