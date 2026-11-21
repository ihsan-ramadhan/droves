# Bridge contract

Droves is a client. The bundled bridge (`bridge/`, Go) runs beside
[herdr](https://github.com/herdrdev/herdr) and fronts its control socket: it
projects herdr panes into this contract, reads agent session files, executes
filesystem and Git operations, and exposes one HTTP origin with a WebSocket
RPC endpoint. The client implements this contract in
`lib/src/bridge/bridge.dart`; another server could too.

## Transport

| Surface | Purpose |
| --- | --- |
| `POST /api/login` | `{"password":"…"}`; `200` plus a session cookie |
| `GET /api/health` | `{"ok":true,"service":"droves-bridge","version":"…"}`; no auth |
| `GET /droves/update.json` | in-app update manifest, served `no-cache` |
| `GET /ws` | JSON RPC over WebSocket, authenticated by that cookie |
| `/droves/` | Static web build, same origin as the API; served `no-cache` so a deploy cannot leave a stale bundle |
| `POST /api/terminal-upload?filename=…` | Stage bytes for terminal paste; returns `{"path":"…"}` |
| `POST /api/file/upload` | Write one workspace file (`workspace_id`, `directory`, `filename`) |
| `POST /api/file/delete` | Delete a file (`workspace_id`, `path`) |

The login endpoint is the only one that accepts the token. Browsers hide
`Set-Cookie` from JavaScript, so web clients rely on the cookie jar and must be
served from the bridge origin. Non-loopback access should be protected by a
private network.

## Messages

The server starts with a hello frame:

```json
{"hello": true, "default_connection_id": "…"}
```

A request carries a client id, a method and parameters. `connection_id` is
required for pane, workspace and terminal methods and omitted for
bridge-global methods (`bridge.*`, `connections.*`).

```json
{"id":"d1","method":"workspace.list","params":{},"connection_id":"…"}
```

A response repeats the id and contains either `result` or `error`:

```json
{"id":"d1","result":{"workspaces":[]}}
{"id":"d1","error":{"message":"…"}}
```

Terminal output is pushed, not returned:

```json
{"terminal":{"terminal_id":"…","width":120,"height":40,"full":true,
 "bytes":"<base64 ANSI>"}}
```

`full` tells the client to reset its screen before applying the frame.
`bytes` is UTF-8 terminal output encoded as base64. Scrollback lives on the
bridge; dragging sends `terminal.scroll` and the next frame repaints the
viewport.

Other pushes use an event envelope:

```json
{"event":"task_notification","data":{"kind":"completed","title":"…","body":"…"}}
```

Task events carry `kind` (`completed`, `blocked`, `ranger`), `title`, `body`,
and optionally `agent`, `workspace_id`, `tab_id`, `pane_id`. The bridge emits
`completed` and `blocked` when a herdr pane leaves `working`; the first status
snapshot only seeds state. Clients use the optional `workspace_id`, `tab_id` and
`pane_id` to deep-link a notification tap to the matching pane. Ranger also
pushes `{"assistant": {…}}` and `{"assistant_notification": {…}}` snapshots.

## Methods

### Workspaces, tabs and panes

| Method | Parameters | Result |
| --- | --- | --- |
| `connections.list` | — | `connections`, each with `id`, `label` |
| `connections.connect` | `connection_id`, `promote_to_default` | — |
| `workspace.list` | — | `workspaces` |
| `workspace.create` | `cwd?`, `focus` | — |
| `workspace.rename` | `workspace_id`, `label` | — |
| `workspace.focus` | `workspace_id` | — |
| `tab.list` | `workspace_id` | `tabs` |
| `tab.create` | `workspace_id`, `cwd?`, `label?`, `focus` | — |
| `tab.rename` | `tab_id`, `label` | — |
| `tab.close` | `tab_id` | — |
| `pane.list` | `workspace_id` | `panes` |
| `pane.focus` | `pane_id` | — |
| `pane.rename` | `pane_id`, `label` | — |
| `pane.close` | `pane_id` | — |
| `pane.split` | `workspace_id`, `pane_id`, `direction` (`right`/`down`), `cwd?` | `pane_info` |
| `pane.zoom` | `pane_id`, `mode` (`toggle`/`on`/`off`) | `pane_zoom` |
| `pane.send_text` | `pane_id`, `text` | — |
| `pane.send_input` | `pane_id`, `text`, `keys` | — |
| `pane.send_keys` | `pane_id`, `keys` | — |
| `agent.list` | — | `agents` in pane shape |

Pane records expose `pane_id`, `terminal_id`, `workspace_id`, `tab_id`,
`agent`, `agent_status`, `cwd` (foreground cwd when known), `terminal_title`,
`terminal_title_stripped` and `focused`.

### Terminal

| Method | Parameters |
| --- | --- |
| `terminal.attach` | `terminal_id`, `cols`, `rows`; returns `offset`, `split`, `cols`, `rows` |
| `terminal.detach` | `terminal_id` |
| `terminal.input` | `terminal_id`, base64 `data` |
| `terminal.resize` | `terminal_id`, `cols`, `rows` |
| `terminal.scroll` | `terminal_id`, `direction` (`up`/`down`), `lines`, `source` |

Paste uses bracketed-paste markers around `terminal.input`; the bridge forwards
bytes to the pane unchanged. `terminal.attach` and `terminal.scroll` return the
current `offset` from the live tail, so clients show "go to latest" only when
the viewport is away from the tail.

`terminal.attach` always reports the pane's current `cols`/`rows`. The bridge
never resizes the herdr pane layout from a viewer, whether the tab is split or
not, so a phone attaching cannot change the desktop geometry. Frames carry the
pane's current `width`/`height`; clients follow them when a split, zoom or close
changes the grid mid-session.

### Transcript and Git

| Method | Parameters | Result |
| --- | --- | --- |
| `agent_history.get` | `pane_id`, `terminal_id`, `history_version: 2` | `entries` |
| `agent_history.entry` | `entry_id`, `pane_id`, `terminal_id` | Full tool payload |
| `agent_session.get` | `pane_id`, `workspace_id`, `tab_id`, `include_trajectory` | `trajectory.steps` |
| `git.diff_summary` | `workspace_id` | `entries`, `counts`, `repo_name` |
| `git.diff_file` | `workspace_id`, `path`, `kind` or `sha` + `mode: commit` | `patch` |
| `git.file_action` | `workspace_id`, `path`, `action` (`stage`/`unstage`) | — |
| `git.pull` | `workspace_id` | `summary` |
| `git.push` | `workspace_id`, optional `remote`, `branch` | `ok`, `remote`, `branch`, `sha`, `summary` |
| `git.commits` | `workspace_id` | `commits`, `head` |
| `git.commit` | `workspace_id`, `sha` | `entries`, `base` |
| `git.commit.create` | `workspace_id`, `message`, `paths` | `ok`, `sha` |

History entries use `id`, `role`, `kind` (`message`, `tool_call`,
`tool_result`, `error`), `text`, optional `tool_name`, `is_error`, `text_bytes`
and `sent_at`. Tool output over the truncation limit is fetched with
`agent_history.entry`. Reasoning never appears here; the thinking toggle
reads it from `agent_session.get`'s trajectory.

### Files

| Method | Parameters |
| --- | --- |
| `file.list` | `workspace_id`, `path`, `show_hidden`, `scope` (`workspace` or `filesystem`) |
| `file.read` | `workspace_id`, `path` |
| `file.search` | `workspace_id`, `mode` (`files`/`content`), `query` |
| `file.mkdir` | `workspace_id`, `directory`, `name` |
| `file.move` | `workspace_id`, `path`, `directory` |

Writes go through `POST /api/file/upload`. Paths are workspace-relative unless
`scope` is `filesystem`.

### Bridge

| Method | Parameters | Result |
| --- | --- | --- |
| `bridge.ping` | — | `ok`, `version` |
| `bridge.status` | — | `state`, `version`, `clients`, `herdr_socket` |

### Ranger

| Method | Parameters |
| --- | --- |
| `bridge.assistant.get` | — |
| `bridge.assistant.configure_chat` | `provider`, `model`, `thinking_level` |
| `bridge.assistant.send` | `text`, `scope`, `request_id`, `session_id?` |
| `bridge.assistant.new_session` | — |
| `bridge.assistant.select_session` | `session_id` |

