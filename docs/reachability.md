# Reachability

The bridge listens on loopback by default. Publishing it is a separate choice,
and no code path in the client assumes a particular tunnel. Pick one of these,
or point any other tunnel or reverse proxy at `127.0.0.1:13030`.

| Provider | Who can dial | What you need |
| --- | --- | --- |
| `none` | the machine itself | nothing; the default |
| `tailscale` | devices on your tailnet | `tailscale` CLI, logged-in node |
| `tailscale-funnel` | the open internet | Funnel enabled for that node; port 443/8443/10000 only |
| `cloudflared` | whoever your Cloudflare Access policy allows | `cloudflared` CLI, remotely-managed tunnel token |
| your own proxy | whoever the proxy allows | HTTP forwarding to loopback, e.g. Pangolin, Netbird, SSH reverse + Caddy |

A quick tunnel (`*.trycloudflare.com`) is fine for a one-off test, not for a
bridge that holds a long-lived session cookie.

## Run it

```sh
# tailnet only
droves-bridge -expose tailscale

# public, beta, bandwidth-capped; put an identity gate in front of it
droves-bridge -expose tailscale-funnel

# Cloudflare Tunnel: store the token once, then start the bridge
droves-bridge expose token -provider cloudflared <TOKEN>
droves-bridge -expose cloudflared -public-url https://droves.example.com

# inspect what is published
droves-bridge expose -provider tailscale
```

The `expose` subcommand also works standalone while the bridge is not running.
`-public-url` matters when a provider cannot report the hostname itself, which
is the case for a Cloudflare Tunnel: the hostname and the ingress rules live in
the Cloudflare dashboard, not on this machine. The bridge stores the token at
`<state-dir>/expose/cloudflared-token` with mode `0600` and passes it via
`--token` by file, never in argv.

To stop publishing what this bridge started:

```sh
droves-bridge expose -provider tailscale off
```

Tailscale's `--bg` config survives a bridge restart, so `off` is explicit. Only
the handler pointing at this bridge's loopback address is cleared; other
services on the node are left alone.

## Proxy setup

If your proxy terminates TLS, pass the address clients actually dial:

```sh
droves-bridge -public-url https://droves.example.com/bridge \
  -trusted-proxies 127.0.0.0/8,::1
```

That path is the mount prefix: the bridge answers `/bridge/api/login`,
`/bridge/ws` and serves the web build at `/bridge/droves/`. Rebuild the web
bundle with a matching `<base href>` (`flutter build web --base-href /bridge/`)
and copy it into the web directory. Otherwise use a proxy that rewrites the
prefix away before forwarding to loopback.

Only addresses in `-trusted-proxies` may set `X-Forwarded-For`,
`X-Forwarded-Proto` and `X-Forwarded-Host`. This keeps the login rate limit
tied to the real client instead of one shared loopback address, and it stops a
client from forging the HTTPS scheme that decides whether the session cookie is
`Secure`. A WebSocket Origin equal to `r.Host`, the configured public URL, or a
trusted `X-Forwarded-Host` is accepted; everything else gets 403.

## Security boundary

A public tunnel without an identity gate leaves only the bridge token between
the internet and terminal input, file writes and Git actions. Prefer a private
mesh, Cloudflare Access, Pangolin's identity gate, or an authenticated reverse
proxy. Tailscale Funnel is public and beta, with a bandwidth cap: use it for a
quick test, not as the default for an always-on bridge.
