<div align="center">

<img src="assets/logo/droves-logo.png" alt="Droves logo" width="120" />

# Droves

**Your running agents, from your phone.**<br>
A native client for a bridge you host yourself.

![CI](https://github.com/ihsan-ramadhan/droves/actions/workflows/ci.yml/badge.svg)
![Flutter](https://img.shields.io/badge/flutter-3.50%2B-blue)
![platforms](https://img.shields.io/badge/platforms-Android%20%7C%20iOS%20%7C%20Web-informational)

</div>

Droves shows the workspaces, panes, agents, terminals, Git changes and files that
already exist on your machine. It has no agent runtime of its own: every action
goes through a bridge over a private network such as Tailscale. Android, iOS and
web share one Flutter codebase; the UI is native, not a WebView.

The machine side is [herdr](https://github.com/herdrdev/herdr), a terminal
workspace manager for AI coding agents. The bridge in `bridge/` is a small Go
service that fronts herdr's control socket: it translates herdr panes into the
RPC contract in [docs/bridge.md](docs/bridge.md), reads agent session files for
the chat transcript, and serves the web build. Without herdr and a reachable
bridge, the app opens but cannot log in or list anything.

## Features

| Area | What you get |
| --- | --- |
| Inbox | Workspaces with a waiting-agent tally, agent status and quick open |
| Agents | Every agent known to the bridge, grouped by host |
| Terminal | ANSI frames, server-side scrollback, shortcut keys, file and image paste |
| Chat | Transcript with tool calls, search, attachments, prompt sending; thinking behind a toggle |
| Changes | Diff summary, per-file diff, stage/unstage, pull, commit history |
| Files & search | Browse, read, edit, create, move, delete, search names and contents |
| Ranger | Bridge-hosted assistant with sessions and model selection |
| Machines | Multiple saved bridges per device, with per-bridge hosts |

Chat is a view over the agent's own session transcript. Sending types into the
pane, so the running CLI remains the authority.

## Quick start

Install the bridge on the machine that runs your agents. Linux and macOS:

```sh
curl -fsSL https://github.com/ihsan-ramadhan/droves/releases/latest/download/install.sh | sh
```

Windows, in PowerShell:

```powershell
irm https://github.com/ihsan-ramadhan/droves/releases/latest/download/install.ps1 | iex
```

Both scripts pull the release for your OS and architecture, verify it against
`SHA256SUMS.txt`, install the binary under `~/.local/bin` (or
`%LOCALAPPDATA%\droves\bin`), and unpack the web build with `update.json` and the
APKs beside it. They refuse to install when a checksum is missing or wrong.
[herdr](https://github.com/herdrdev/herdr) is a separate install; the bridge
finds it at `~/.config/herdr/herdr.sock`.

```sh
droves-bridge -addr 0.0.0.0:13030 -web ~/.local/share/droves/web
tailscale serve --bg 13030
cat ~/.config/droves-bridge/token
```

The first run generates the access token at `~/.config/droves-bridge/token` and
stores bridge state under `~/.local/state/droves-bridge`. Expose the port only on
a private network such as Tailscale.

Then get the client:

- **Android**: download `droves-arm64.apk` from the same release, or open the
  bridge URL and fetch the APK from its own `download/` directory.
- **iOS**: sideload the unsigned IPA with SideStore, see
  [iOS without the App Store](#ios-without-the-app-store).
- **Web**: nothing to install; log in at `https://<bridge-host>/droves/`.

Open Droves, enter the bridge URL and access token. For a tailnet bridge the URL
is the machine's tailnet name, for example
`https://machine.tailnet.ts.net:13030`.

### Updating

Rerun the installer to update the bridge and the web build. The app checks
`<bridge>/droves/update.json` on launch and when it returns to the foreground
(throttled to once every 6 hours) and shows the new version in Settings; tapping
it opens the APK download on Android or reloads the page on web.

### Building from source

```sh
git clone https://github.com/ihsan-ramadhan/droves
cd droves
flutter pub get
flutter build apk --release --split-per-abi
```

Then on the machine that runs your agents:

```sh
cd bridge
go build -ldflags "-X main.bridgeVersion=$(git describe --tags --always)" -o droves-bridge .
./droves-bridge -addr 0.0.0.0:13030 -web ../build/web
```

Web must be served by the bridge itself: browsers only attach the session cookie
to the bridge origin, so a web build hosted elsewhere cannot open `/ws`.

```sh
flutter build web --release --base-href /droves/
```

## Configuration

| Setting | Where | Notes |
| --- | --- | --- |
| Bridge URL | Connect screen | Scheme required; use the tailnet host, not loopback |
| Access token | Connect screen | Exchanged for a session cookie; stored in local preferences |
| Base path | Build time | `--base-href /droves/` for web |
| Notification kinds | Settings | Completed, blocked, Ranger run |
| Theme | Settings | Light, dark, follow system |
| Auto reconnect | Settings | Retries after the app returns to the foreground |

Saved endpoints live in `shared_preferences`. There is no config file and no
compile-time secret baked into the app.

## Build

| Target | Command |
| --- | --- |
| Android APK | `flutter build apk --release --split-per-abi` |
| Android App Bundle | `flutter build appbundle --release` |
| iOS | `flutter build ios --release --no-codesign` (macOS + Xcode) |
| Web | `flutter build web --release --base-href /droves/` |

Android requires the Android SDK; `compileSdk` is 37 because of the notification
plugin. iOS builds are unsigned unless you provide signing credentials.

Every tagged release publishes an unsigned `droves.ipa` plus a SideStore/AltStore
source at `releases/latest/download/source.json`. The source is regenerated per
tag, so a sideloaded install has a working update path without the App Store.

## iOS without the App Store

Droves is not on the App Store and cannot be: it needs a bridge URL and a token
before it shows anything, which fails App Review. On iOS the only options are
sideloading or the web build. Sideloading works because iOS lets any Apple
Account sign and install apps with a development certificate; the catch is the
certificate and the apps expire after 7 days unless something refreshes them.

We document [SideStore](https://docs.sidestore.io) because it refreshes apps on
the device itself. [AltStore Classic](https://altstore.io) works too, but it
needs AltServer running on a computer on the same network at every refresh.

### What you need

| Requirement | Detail |
| --- | --- |
| Device | iPhone or iPad, iOS/iPadOS 15.0 or newer, with a passcode |
| Apple Account | A free Apple ID is enough; no $99 membership |
| Computer | Windows, macOS, Linux or an unenrolled Chromebook, used **once** at setup |
| Wi-Fi | Refreshing and installing need Wi-Fi plus the on-device VPN; mobile data is not enough |
| App slots | A free account allows 3 signing apps at a time (SideStore counts as one) and 10 new App IDs per week |

### One-time setup

1. Install `LocalDevVPN` from the App Store and leave it installed. SideStore
   needs it running whenever it installs, updates or refreshes an app.
2. On the computer, install `usbmuxd` (Linux) or iTunes (Windows), then install
   [iloader](https://iloader.app) from its releases page.
3. Connect the device by USB, trust the computer, open iloader, sign in with your
   Apple Account, and pick **Install SideStore (Stable)**.
4. On the device: Settings → General → VPN & Device Management → trust the
   developer app named after your Apple Account.
5. On iOS 16 and newer, enable Settings → Privacy & Security → Developer Mode
   and restart.
6. Open LocalDevVPN → Connect. Open SideStore, sign in with the same account,
   and tap the `7 DAYS` counter next to SideStore to finish its own refresh.

### Install Droves

1. In SideStore, open the **Sources** tab, tap `+`, and add:
   `https://github.com/ihsan-ramadhan/droves/releases/latest/download/source.json`
2. Open the Droves page in that source and install it. SideStore downloads the
   unsigned IPA and re-signs it with your certificate.
3. Launch Droves and enter your bridge URL and token exactly as on Android.

### Update Droves

SideStore polls every source it has on its own schedule. When a release is
newer, the app shows an update badge:

1. Open LocalDevVPN → Connect.
2. Open SideStore → **My Apps** → tap the update button on Droves. The app is
   re-signed in place and its saved bridges and tokens stay.
3. If no update appears, pull to refresh the Sources tab, then check again.

Refreshing is separate from updating: SideStore must also re-sign Droves before
the 7-day certificate runs out. Leave SideStore's background refresh enabled and
keep Wi-Fi plus LocalDevVPN available; if the counter reaches zero the app stops
launching until you refresh it again.

### Limits worth knowing

- 3 signed apps at once, including SideStore itself. Droves plus SideStore is two.
- 10 distinct App IDs per week. Reinstalling the same bundle ID does not count
  again; switching between different apps does.
- A paid Apple Developer account raises expiry to 365 days and removes the
  3-app limit.
- Notifications are not wired for iOS yet: `NotificationService.init` only
  configures the Android channel. The app runs fine without them.
- Reinstalling or resetting iOS invalidates the pairing file SideStore uses;
  regenerate it with iloader.

## Security

Droves is a remote control for a machine, so the bridge is the security boundary.
Use a tailnet or another private network, keep the bridge token secret, and serve
web from the same origin as the bridge. The token is sent once to `/api/login`;
after that the client uses the returned session cookie. The app never talks to a
third-party service and never stores the token anywhere except local preferences.

Terminal input, file writes and Git actions are sent as bridge RPCs. Nothing is
executed locally on the phone.

## Development

```sh
flutter pub get
flutter analyze
flutter test
```

Live and golden checks:

```sh
flutter test --update-goldens test/golden_test.dart
flutter test --tags live --update-goldens test/live_render_test.dart
```

`test/live_render_test.dart` talks to a real bridge, is tagged `live`, and is
skipped by default. Golden PNGs under `test/goldens/` are generated evidence,
gitignored; the golden tests render and write them instead of pixel-comparing.
End-to-end and audit helpers:

```sh
BRIDGE_URL=https://machine.tailnet.ts.net BRIDGE_TOKEN=… dart run tool/smoke.dart
dart run tool/feature_audit.dart   # bridge methods each screen uses
```

Layout:

```text
lib/main.dart                  app shell and four destinations
lib/src/bridge/bridge.dart     login, WebSocket RPC, terminal frames
lib/src/model/app_state.dart   saved endpoints, theme, notifications
lib/src/ui/                    one file per screen
tool/                          live smoke test and RPC audit
test/                          widget, golden and render tests
scripts/                       install.sh and install.ps1 shipped as release assets
```

Release assets use stable names, so `releases/latest/download/<asset>` is a
permanent URL that the installers and `update.json` can point at:

| Asset | What it is |
| --- | --- |
| `droves-bridge-<os>-<arch>` | bridge binary; `linux`/`darwin`/`windows`, `amd64`/`arm64` |
| `droves-web.tar.gz` | web build, extracted into the bridge's `-web` directory |
| `droves-arm64.apk`, `droves-arm.apk`, `droves-x86_64.apk` | Android splits |
| `droves.ipa` | unsigned iOS app for SideStore/AltStore |
| `install.sh`, `install.ps1` | installers, checksum-verified |
| `update.json` | in-app update manifest, regenerated per tag |
| `source.json` | SideStore/AltStore source, regenerated per tag |
| `SHA256SUMS.txt` | checksums covering every binary above |

The publish job builds `update.json` and `source.json` from the tag, so a release
never ships a manifest that still points at the previous version.

## Docs

[Bridge contract](docs/bridge.md) · [Design direction](DESIGN.md) · [CI](.github/workflows/ci.yml)
