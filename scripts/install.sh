#!/bin/sh
# Installs the droves bridge from GitHub Releases.
#
#   curl -fsSL https://github.com/ihsan-ramadhan/droves/releases/latest/download/install.sh | sh
#
# Environment:
#   DROVES_VERSION    tag to install (default: latest release)
#   DROVES_BIN_DIR    where the binary goes (default: ~/.local/bin)
#   DROVES_SHARE_DIR  where the web build goes (default: ~/.local/share/droves)
#   DROVES_NO_WEB     set to 1 to skip the web build
set -eu

REPO="${DROVES_REPO:-ihsan-ramadhan/droves}"
VERSION="${DROVES_VERSION:-latest}"
BIN_DIR="${DROVES_BIN_DIR:-$HOME/.local/bin}"
SHARE_DIR="${DROVES_SHARE_DIR:-$HOME/.local/share/droves}"

log() { printf '%s\n' "$*" >&2; }
die() { log "error: $*"; exit 1; }

need() {
  command -v "$1" >/dev/null 2>&1 || die "$1 is required but not installed"
}
need curl
need tar
need uname

case "$(uname -s)" in
  Linux) os=linux ;;
  Darwin) os=darwin ;;
  *) die "unsupported OS: $(uname -s). Windows users: use install.ps1" ;;
esac

case "$(uname -m)" in
  x86_64 | amd64) arch=amd64 ;;
  aarch64 | arm64) arch=arm64 ;;
  *) die "unsupported architecture: $(uname -m)" ;;
esac

if [ "$VERSION" = latest ]; then
  base="https://github.com/$REPO/releases/latest/download"
else
  base="https://github.com/$REPO/releases/download/$VERSION"
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT TERM

log "fetching droves bridge from $base"
curl -fsSL "$base/droves-bridge-$os-$arch" -o "$tmp/bridge" ||
  die "no bridge build for $os-$arch at $base"
curl -fsSL "$base/SHA256SUMS.txt" -o "$tmp/SHA256SUMS.txt" ||
  die "release has no checksums; refusing to install an unverified binary"

if [ "${DROVES_NO_WEB:-0}" != 1 ]; then
  curl -fsSL "$base/droves-web.tar.gz" -o "$tmp/web.tar.gz" ||
    die "no web build at $base"
fi

# checksums are generated next to the release assets, so match by basename
verify() {
  name=$1
  want=$(awk -v n="$name" '$2 == n { print $1 }' "$tmp/SHA256SUMS.txt")
  [ -n "$want" ] || die "no checksum for $name"
  if command -v sha256sum >/dev/null 2>&1; then
    got=$(sha256sum "$2" | awk '{ print $1 }')
  else
    got=$(shasum -a 256 "$2" | awk '{ print $1 }')
  fi
  [ "$want" = "$got" ] || die "checksum mismatch for $name"
}

verify "droves-bridge-$os-$arch" "$tmp/bridge"
[ "${DROVES_NO_WEB:-0}" = 1 ] || verify "droves-web.tar.gz" "$tmp/web.tar.gz"

mkdir -p "$BIN_DIR"
install -m 0755 "$tmp/bridge" "$BIN_DIR/droves-bridge"

if [ "${DROVES_NO_WEB:-0}" != 1 ]; then
  mkdir -p "$SHARE_DIR"
  # replace the tree so a stale Flutter build can't shadow the new one
  rm -rf "$SHARE_DIR/web"
  mkdir -p "$SHARE_DIR/web"
  tar -xzf "$tmp/web.tar.gz" -C "$SHARE_DIR/web"
  # the manifest points the app at <bridge>/droves/download/<apk>; without these
  # files the update prompt appears and then 404s
  mkdir -p "$SHARE_DIR/web/download"
  for apk in droves-arm64.apk droves-arm.apk droves-x86_64.apk; do
    curl -fsSL "$base/$apk" -o "$SHARE_DIR/web/download/$apk" ||
      log "warning: $apk not in this release"
  done
  curl -fsSL "$base/update.json" -o "$SHARE_DIR/web/update.json" ||
    log "warning: no update.json in this release; in-app update checks stay quiet"
  log "web build: $SHARE_DIR/web"
fi

log "bridge:    $BIN_DIR/droves-bridge ($("$BIN_DIR/droves-bridge" -version))"

# a running service keeps the old binary mapped; restart it onto the new one
if command -v systemctl >/dev/null 2>&1 &&
  systemctl --user cat droves-bridge.service >/dev/null 2>&1; then
  if systemctl --user restart droves-bridge.service; then
    log "service:   droves-bridge.service restarted"
  else
    log "warning: could not restart droves-bridge.service; run: systemctl --user restart droves-bridge"
  fi
elif [ "$os" = Darwin ] && command -v launchctl >/dev/null 2>&1 &&
  launchctl list 2>/dev/null | grep -q droves-bridge; then
  label=$(launchctl list | awk '/droves-bridge/ {print $3; exit}')
  if launchctl kickstart -k "gui/$(id -u)/$label" 2>/dev/null; then
    log "service:   $label restarted"
  else
    log "warning: could not restart $label; restart it manually"
  fi
fi

case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) log "note: $BIN_DIR is not on PATH" ;;
esac

cat >&2 <<EOF

Next steps
  1. install herdr: https://github.com/herdrdev/herdr
  2. start the bridge:
       droves-bridge -addr 127.0.0.1:13030 -web $SHARE_DIR/web
  3. read the access token:
       cat ~/.config/droves-bridge/token
  4. expose the port on your tailnet only:
       tailscale serve --bg 13030

Update later by running this script again.
EOF
