package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
)

const (
	autostartUnit  = "droves-bridge.service"
	autostartLabel = "dev.droves.bridge"
	autostartTask  = "droves-bridge"
)

type autostartStatus struct {
	Manager   string `json:"manager"`
	Installed bool   `json:"installed"`
	Active    bool   `json:"active"`
}

func quietCmd(program string, args ...string) bool {
	return exec.Command(program, args...).Run() == nil
}

func runCmd(program string, args ...string) error {
	cmd := exec.Command(program, args...)
	out, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("%s %s: %v: %s", program, strings.Join(args, " "), err, strings.TrimSpace(string(out)))
	}
	return nil
}

func currentExe() (string, error) {
	exe, err := os.Executable()
	if err != nil {
		return "", err
	}
	return filepath.Abs(exe)
}

func autostartPath() (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	switch runtime.GOOS {
	case "linux":
		return filepath.Join(home, ".config/systemd/user", autostartUnit), nil
	case "darwin":
		return filepath.Join(home, "Library/LaunchAgents", autostartLabel+".plist"), nil
	case "windows":
		return "", nil
	default:
		return "", fmt.Errorf("autostart is only supported on Linux, macOS and Windows")
	}
}

func quoteSystemd(s string) string {
	s = strings.ReplaceAll(s, `\`, `\\`)
	s = strings.ReplaceAll(s, `"`, `\"`)
	s = strings.ReplaceAll(s, `%`, `%%`)
	s = strings.ReplaceAll(s, `$`, `$$$$`)
	return `"` + s + `"`
}

func xmlEscape(s string) string {
	s = strings.ReplaceAll(s, `&`, `&amp;`)
	s = strings.ReplaceAll(s, `<`, `&lt;`)
	s = strings.ReplaceAll(s, `>`, `&gt;`)
	s = strings.ReplaceAll(s, `"`, `&quot;`)
	return s
}

func autostartCommand(exe string) string {
	return fmt.Sprintf("%s run -addr 127.0.0.1:13030 -web %s", quoteSystemd(exe), quoteSystemd(defaultWebDir()))
}

func defaultWebDir() string {
	if v := os.Getenv("DROVES_WEB_DIR"); v != "" {
		return v
	}
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".local/share/droves/web")
}

func systemdUnit(exe string) string {
	return fmt.Sprintf(`[Unit]
Description=Droves bridge (herdr backend)
After=network.target herdr-server.service
Wants=herdr-server.service

[Service]
Type=simple
ExecStart=%s
Restart=always
RestartSec=3
NoNewPrivileges=yes
# the bridge writes workspace files; a private /tmp would hide them from the user's shells
PrivateTmp=no
[Install]
WantedBy=default.target
`, autostartCommand(exe))
}

func launchdPlist(exe string) string {
	home, _ := os.UserHomeDir()
	log := filepath.Join(home, ".local/state/droves-bridge", "autostart.log")
	e := xmlEscape(exe)
	w := xmlEscape(defaultWebDir())
	l := xmlEscape(log)
	return fmt.Sprintf(`<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>%s</string>
    <key>ProgramArguments</key>
    <array>
        <string>%s</string>
        <string>run</string>
        <string>-addr</string>
        <string>127.0.0.1:13030</string>
        <string>-web</string>
        <string>%s</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>%s</string>
    <key>StandardErrorPath</key>
    <string>%s</string>
</dict>
</plist>
`, autostartLabel, e, w, l, l)
}

func windowsTaskCommand(exe string) string {
	return fmt.Sprintf(`"%s" run -addr 127.0.0.1:13030 -web "%s"`, exe, defaultWebDir())
}

func autostartInstalled() bool {
	switch runtime.GOOS {
	case "linux", "darwin":
		p, err := autostartPath()
		return err == nil && fileExists(p)
	case "windows":
		return quietCmd("schtasks", "/Query", "/TN", autostartTask)
	default:
		return false
	}
}

func autostartActive() bool {
	switch runtime.GOOS {
	case "linux":
		return autostartInstalled() && quietCmd("systemctl", "--user", "is-active", "--quiet", autostartUnit)
	case "darwin":
		return autostartInstalled() && quietCmd("launchctl", "print", fmt.Sprintf("gui/%d/%s", os.Getuid(), autostartLabel))
	case "windows":
		return autostartInstalled()
	default:
		return false
	}
}

func fileExists(p string) bool {
	st, err := os.Stat(p)
	return err == nil && !st.IsDir()
}

func autostartEnable() (string, error) {
	exe, err := currentExe()
	if err != nil {
		return "", err
	}
	switch runtime.GOOS {
	case "linux":
		p, err := autostartPath()
		if err != nil {
			return "", err
		}
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			return "", err
		}
		if err := os.WriteFile(p, []byte(systemdUnit(exe)), 0o644); err != nil {
			return "", err
		}
		if err := runCmd("systemctl", "--user", "daemon-reload"); err != nil {
			return "", err
		}
		if err := runCmd("systemctl", "--user", "enable", "--now", autostartUnit); err != nil {
			_ = os.Remove(p)
			_ = runCmd("systemctl", "--user", "daemon-reload")
			return "", fmt.Errorf("unit could not start (no user session or dbus?); removed %s: %w", p, err)
		}
		user := os.Getenv("USER")
		if user == "" {
			user = os.Getenv("LOGNAME")
		}
		if user == "" || !quietCmd("loginctl", "enable-linger", user) {
			return fmt.Sprintf("enabled for your login session; run `loginctl enable-linger $USER` once for boot start (%s)", p), nil
		}
		return fmt.Sprintf("enabled at boot and login (%s)", p), nil
	case "darwin":
		p, err := autostartPath()
		if err != nil {
			return "", err
		}
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			return "", err
		}
		if err := os.WriteFile(p, []byte(launchdPlist(exe)), 0o644); err != nil {
			return "", err
		}
		domain := fmt.Sprintf("gui/%d", os.Getuid())
		_ = quietCmd("launchctl", "bootout", domain+"/"+autostartLabel)
		if err := runCmd("launchctl", "bootstrap", domain, p); err != nil {
			_ = os.Remove(p)
			return "", fmt.Errorf("launchctl could not load the agent; removed %s: %w", p, err)
		}
		return fmt.Sprintf("enabled at login (%s)", p), nil
	case "windows":
		_ = quietCmd("schtasks", "/Delete", "/TN", autostartTask, "/F")
		if err := runCmd("schtasks", "/Create", "/TN", autostartTask, "/SC", "ONLOGON", "/RL", "LIMITED", "/TR", windowsTaskCommand(exe), "/F"); err != nil {
			return "", err
		}
		if !quietCmd("schtasks", "/Run", "/TN", autostartTask) {
			_ = quietCmd("schtasks", "/Delete", "/TN", autostartTask, "/F")
			return "", fmt.Errorf("the task was created but could not start; removed it")
		}
		return "enabled at login (scheduled task droves-bridge)", nil
	default:
		return "", fmt.Errorf("autostart is only supported on Linux, macOS and Windows")
	}
}

func autostartDisable() (string, error) {
	switch runtime.GOOS {
	case "linux":
		_ = quietCmd("systemctl", "--user", "disable", "--now", autostartUnit)
		p, _ := autostartPath()
		if p != "" && fileExists(p) {
			if err := os.Remove(p); err != nil {
				return "", err
			}
		}
		_ = quietCmd("systemctl", "--user", "daemon-reload")
		return "autostart disabled", nil
	case "darwin":
		domain := fmt.Sprintf("gui/%d", os.Getuid())
		_ = quietCmd("launchctl", "bootout", domain+"/"+autostartLabel)
		p, _ := autostartPath()
		if p != "" && fileExists(p) {
			if err := os.Remove(p); err != nil {
				return "", err
			}
		}
		return "autostart disabled", nil
	case "windows":
		_ = quietCmd("schtasks", "/End", "/TN", autostartTask)
		if autostartInstalled() {
			if err := runCmd("schtasks", "/Delete", "/TN", autostartTask, "/F"); err != nil {
				return "", err
			}
		}
		return "autostart disabled", nil
	default:
		return "", fmt.Errorf("autostart is only supported on Linux, macOS and Windows")
	}
}

func restartManaged() bool {
	switch runtime.GOOS {
	case "linux":
		return autostartActive() && quietCmd("systemctl", "--user", "restart", autostartUnit)
	case "darwin":
		return autostartActive() && quietCmd("launchctl", "kickstart", "-k", fmt.Sprintf("gui/%d/%s", os.Getuid(), autostartLabel))
	case "windows":
		if !autostartInstalled() {
			return false
		}
		_ = quietCmd("schtasks", "/End", "/TN", autostartTask)
		return quietCmd("schtasks", "/Run", "/TN", autostartTask)
	default:
		return false
	}
}
func stopManaged() bool {
	switch runtime.GOOS {
	case "linux":
		return autostartActive() && quietCmd("systemctl", "--user", "stop", autostartUnit)
	case "darwin":
		return autostartActive() && quietCmd("launchctl", "bootout", fmt.Sprintf("gui/%d/%s", os.Getuid(), autostartLabel))
	case "windows":
		return autostartInstalled() && quietCmd("schtasks", "/End", "/TN", autostartTask)
	default:
		return false
	}
}

func runStop() int {
	if autostartActive() {
		if stopManaged() {
			fmt.Println("service stopped")
			return 0
		}
		fmt.Fprintln(os.Stderr, "droves-bridge stop: the autostart service is installed but could not be stopped")
		return 1
	}
	fmt.Fprintln(os.Stderr, "droves-bridge stop: no managed service is active")
	fmt.Fprintln(os.Stderr, "if you started it in a terminal, press Ctrl-C there")
	return 1
}

func runAutostart(args []string) int {
	fs := flagSet("autostart")
	on := fs.Bool("enable", false, "enable autostart at login and boot")
	off := fs.Bool("disable", false, "disable autostart")
	status := fs.Bool("status", false, "show autostart status (default)")
	if err := fs.Parse(args); err != nil {
		return flagExit(err)
	}
	if *on && *off {
		fmt.Fprintln(os.Stderr, "droves-bridge autostart: use only one of -enable or -disable")
		return 2
	}
	if *on {
		msg, err := autostartEnable()
		if err != nil {
			fmt.Fprintf(os.Stderr, "droves-bridge autostart: %v\n", err)
			return 1
		}
		fmt.Println(msg)
		return 0
	}
	if *off {
		msg, err := autostartDisable()
		if err != nil {
			fmt.Fprintf(os.Stderr, "droves-bridge autostart: %v\n", err)
			return 1
		}
		fmt.Println(msg)
		return 0
	}
	_ = status
	st := autostartStatus{Manager: runtime.GOOS, Installed: autostartInstalled(), Active: autostartActive()}
	if st.Active {
		fmt.Println("autostart enabled and running")
	} else if st.Installed {
		fmt.Println("autostart enabled, not running")
	} else {
		fmt.Println("autostart disabled")
		fmt.Println("enable it with: droves-bridge autostart -enable")
	}
	return 0
}
func runRestart() int {
	if autostartActive() {
		if restartManaged() {
			fmt.Println("service restarted")
			return 0
		}
		fmt.Fprintln(os.Stderr, "droves-bridge restart: the autostart service is installed but could not be restarted")
		return 1
	}
	fmt.Fprintln(os.Stderr, "droves-bridge restart: no managed service is active")
	fmt.Fprintln(os.Stderr, "start the bridge with: droves-bridge autostart -enable")
	return 1
}
