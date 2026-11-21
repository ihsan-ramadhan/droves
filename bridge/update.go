package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"time"
)

const defaultReleasesURL = "https://github.com/ihsan-ramadhan/droves/releases/latest/download"

type updateManifest struct {
	Version string `json:"version"`
	Notes   string `json:"notes"`
}

func releaseBase() string {
	if v := os.Getenv("DROVES_RELEASES_URL"); v != "" {
		return strings.TrimRight(v, "/")
	}
	return defaultReleasesURL
}

func platformAsset() (string, error) {
	switch runtime.GOOS {
	case "linux", "darwin":
		if runtime.GOARCH != "amd64" && runtime.GOARCH != "arm64" {
			return "", fmt.Errorf("unsupported architecture %s/%s", runtime.GOOS, runtime.GOARCH)
		}
	case "windows":
		if runtime.GOARCH != "amd64" {
			return "", fmt.Errorf("unsupported architecture %s/%s", runtime.GOOS, runtime.GOARCH)
		}
	default:
		return "", fmt.Errorf("unsupported operating system %s", runtime.GOOS)
	}
	name := fmt.Sprintf("droves-bridge-%s-%s", runtime.GOOS, runtime.GOARCH)
	if runtime.GOOS == "windows" {
		name += ".exe"
	}
	return name, nil
}

func versionParts(v string) [3]int {
	var out [3]int
	v = strings.TrimPrefix(strings.TrimSpace(v), "v")
	if i := strings.IndexAny(v, "+"); i >= 0 {
		v = v[:i]
	}
	for i, part := range strings.Split(v, ".") {
		if i >= 3 {
			break
		}
		n, _ := strconv.Atoi(part)
		out[i] = n
	}
	return out
}

func newerVersion(latest, current string) bool {
	a, b := versionParts(latest), versionParts(current)
	for i := range a {
		if a[i] != b[i] {
			return a[i] > b[i]
		}
	}
	return false
}

func fetchUpdateManifest(client *http.Client, base string) (updateManifest, error) {
	var m updateManifest
	resp, err := client.Get(base + "/update.json")
	if err != nil {
		return m, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return m, fmt.Errorf("update manifest: HTTP %d", resp.StatusCode)
	}
	if err := json.NewDecoder(resp.Body).Decode(&m); err != nil {
		return m, err
	}
	if m.Version == "" {
		return m, fmt.Errorf("update manifest has no version")
	}
	return m, nil
}

func downloadToFile(client *http.Client, url, path string) error {
	resp, err := client.Get(url)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("%s: HTTP %d", url, resp.StatusCode)
	}
	f, err := os.Create(path)
	if err != nil {
		return err
	}
	if _, err := io.Copy(f, resp.Body); err != nil {
		f.Close()
		return err
	}
	return f.Close()
}

func verifyChecksum(sumFile, asset, path string) error {
	b, err := os.ReadFile(sumFile)
	if err != nil {
		return err
	}
	want := ""
	for _, line := range strings.Split(string(b), "\n") {
		parts := strings.Fields(line)
		if len(parts) >= 2 && parts[len(parts)-1] == asset {
			want = strings.ToLower(parts[0])
			break
		}
	}
	if want == "" {
		return fmt.Errorf("no checksum for %s", asset)
	}
	f, err := os.Open(path)
	if err != nil {
		return err
	}
	defer f.Close()
	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		return err
	}
	if got := hex.EncodeToString(h.Sum(nil)); got != want {
		return fmt.Errorf("checksum mismatch for %s: got %s, want %s", asset, got, want)
	}
	return nil
}

func copyExecutable(src, dst string) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	out, err := os.OpenFile(dst, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o755)
	if err != nil {
		return err
	}
	if _, err := io.Copy(out, in); err != nil {
		out.Close()
		return err
	}
	if err := out.Chmod(0o755); err != nil {
		out.Close()
		return err
	}
	return out.Close()
}

func executablePath() (string, error) {
	exe, err := os.Executable()
	if err != nil {
		return "", err
	}
	return filepath.EvalSymlinks(exe)
}

func applyPending(pending, target string) error {
	if err := os.Rename(pending, target); err != nil {
		return fmt.Errorf("replace %s: %w", target, err)
	}
	return nil
}

type installResult struct {
	version     string
	staged      bool
	restarted   bool
	restartHint string
}

func installUpdate(base string, manifest updateManifest, quiet bool) (installResult, error) {
	var res installResult
	res.version = manifest.Version
	exe, err := executablePath()
	if err != nil {
		return res, err
	}
	pending := exe + ".new"

	asset, err := platformAsset()
	if err != nil {
		return res, err
	}
	client := &http.Client{Timeout: 30 * time.Second}
	tmp, err := os.MkdirTemp("", "droves-update-")
	if err != nil {
		return res, err
	}
	defer os.RemoveAll(tmp)

	releaseURL := strings.TrimRight(base, "/")
	binPath := filepath.Join(tmp, asset)
	sumPath := filepath.Join(tmp, "SHA256SUMS.txt")
	if !quiet {
		fmt.Printf("downloading %s version %s\n", asset, manifest.Version)
	}
	if err := downloadToFile(client, releaseURL+"/"+asset, binPath); err != nil {
		return res, err
	}
	if err := downloadToFile(client, releaseURL+"/SHA256SUMS.txt", sumPath); err != nil {
		return res, err
	}
	if err := verifyChecksum(sumPath, asset, binPath); err != nil {
		return res, err
	}

	stage := pending + ".tmp"
	if err := copyExecutable(binPath, stage); err != nil {
		return res, err
	}
	if err := os.Rename(stage, pending); err != nil {
		return res, err
	}
	if err := applyPending(pending, exe); err != nil {
		res.staged = true
		res.restartHint = "the running binary is locked; stop the bridge and run: droves-bridge update -apply"
		return res, nil
	}
	if autostartActive() {
		if restartManaged() {
			res.restarted = true
		} else {
			res.restartHint = "could not restart the managed service; run: droves-bridge restart"
		}
	} else {
		res.restartHint = "restart the bridge process to load the new binary"
	}
	return res, nil
}

func runUpdate(args []string) int {
	fs := flagSet("update")
	base := fs.String("base", releaseBase(), "GitHub Releases download URL")
	checkOnly := fs.Bool("check", false, "only report whether a newer release exists")
	applyOnly := fs.Bool("apply", false, "apply a binary staged by an earlier update")
	if err := fs.Parse(args); err != nil {
		return flagExit(err)
	}

	exe, err := executablePath()
	if err != nil {
		fmt.Fprintf(os.Stderr, "droves-bridge update: executable path: %v\n", err)
		return 1
	}
	pending := exe + ".new"

	if *applyOnly {
		if _, err := os.Stat(pending); err != nil {
			fmt.Fprintf(os.Stderr, "droves-bridge update: no staged binary at %s\n", pending)
			return 1
		}
		if err := applyPending(pending, exe); err != nil {
			fmt.Fprintf(os.Stderr, "droves-bridge update: %v\n", err)
			return 1
		}
		fmt.Printf("applied staged update to %s\n", exe)
		return 0
	}

	client := &http.Client{Timeout: 30 * time.Second}
	manifest, err := fetchUpdateManifest(client, strings.TrimRight(*base, "/"))
	if err != nil {
		fmt.Fprintf(os.Stderr, "droves-bridge update: %v\n", err)
		return 1
	}
	if !newerVersion(manifest.Version, bridgeVersion) {
		fmt.Printf("droves-bridge %s is up to date (latest release: %s)\n", bridgeVersion, manifest.Version)
		return 0
	}
	if *checkOnly {
		fmt.Printf("update available: %s -> %s\n%s\nRun: droves-bridge update\n", bridgeVersion, manifest.Version, manifest.Notes)
		return 0
	}

	res, err := installUpdate(*base, manifest, false)
	if err != nil {
		fmt.Fprintf(os.Stderr, "droves-bridge update: %v\n", err)
		return 1
	}
	if res.staged {
		fmt.Println(res.restartHint)
		if runtime.GOOS == "windows" {
			fmt.Println("on Windows, also stop any service holding droves-bridge.exe before applying")
		}
		return 0
	}
	fmt.Printf("installed %s (release %s)\n", filepath.Base(exe), res.version)
	if res.restarted {
		fmt.Println("service restarted on the new binary")
	} else if res.restartHint != "" {
		fmt.Println(res.restartHint)
	}
	return 0
}

func maybeAutoUpdate(cfg Config) {
	if os.Getenv("DROVES_NO_UPDATE_CHECK") == "1" {
		return
	}
	client := &http.Client{Timeout: 8 * time.Second}
	manifest, err := fetchUpdateManifest(client, releaseBase())
	if err != nil || !newerVersion(manifest.Version, bridgeVersion) {
		return
	}

	stamp := filepath.Join(cfg.StateDir, "last-notified-version")
	if b, err := os.ReadFile(stamp); err == nil && strings.TrimSpace(string(b)) == manifest.Version {
		return
	}
	log.Printf("auto update: %s -> %s", bridgeVersion, manifest.Version)
	res, err := installUpdate(releaseBase(), manifest, true)
	if err != nil {
		log.Printf("auto update failed: %v", err)
		return
	}
	_ = os.MkdirAll(filepath.Dir(stamp), 0o700)
	_ = os.WriteFile(stamp, []byte(manifest.Version+"\n"), 0o600)
	if res.staged {
		log.Printf("auto update staged %s; finish with: droves-bridge update -apply", res.version)
		return
	}
	if res.restarted {
		log.Printf("auto update installed %s; service restarted", res.version)
		return
	}
	if res.restartHint != "" {
		log.Printf("auto update installed %s; %s", res.version, res.restartHint)
	}
}
