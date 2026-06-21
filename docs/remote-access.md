# Remote & cloud access

The MCP server runs **inside the Godot editor**, so it lives wherever the editor runs —
usually `127.0.0.1:9080` on your workstation. You do not need to move it to a cloud host
to let a remote teammate or a hosted AI client reach it. Instead, expose the local port
through a **free tunnel**: the tunnel terminates a public HTTPS URL and forwards traffic
to your local server. This is zero-cost, needs no server to maintain, and keeps the editor
on the machine that owns the project.

> **Security first.** A public URL means anyone who learns it can drive your editor. Before
> exposing the server, enable **Bearer-token authentication** in the panel (Transport →
> *Enable auth*) and treat the token like a password. See the [checklist](#security-checklist).

## How it fits together

```
AI client ──HTTPS──> tunnel edge ──encrypted tunnel──> cloudflared (your PC) ──> 127.0.0.1:9080
```

Because `cloudflared` (or any tunnel daemon) runs on the **same machine** as the editor, it
connects to `127.0.0.1`. You therefore do **not** need to turn on *Allow remote* — leaving
the server bound to localhost is fine and more secure; the tunnel is the only public ingress.

## Option A — Cloudflare Quick Tunnel (recommended, no account)

1. Install `cloudflared` ([downloads](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/)).
2. Start the MCP server in the panel (HTTP transport, port `9080`).
3. Run:

   ```bash
   cloudflared tunnel --url http://localhost:9080
   ```

   The panel's **Remote / Cloud access** card has a *Copy tunnel command* button that
   produces this line with your current port already filled in.
4. `cloudflared` prints a public URL, e.g. `https://random-words-1234.trycloudflare.com`.
   Paste it into the panel's **Public URL** field and click *Copy HTTP config* (or
   *Copy Claude (mcp-remote)*) to get a ready-to-paste client config.

Quick Tunnel URLs are **ephemeral** (they change each run). For a stable hostname, create a
free Cloudflare account and a [named tunnel](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/).

## Option B — Tailscale Funnel

If your team already uses [Tailscale](https://tailscale.com/), `tailscale funnel 9080`
publishes the local port on your tailnet's public HTTPS hostname. Good when you want the
endpoint reachable only to a known group rather than the whole internet.

## Option C — ngrok

`ngrok http 9080` also works (free tier). URLs are ephemeral and rate-limited, and it
requires a (free) account + authtoken.

## Connecting clients to the public URL

The panel generates both forms for you from the **Public URL** field:

### URL-capable clients (Cursor, Cline, generic MCP)

```json
{
  "mcpServers": {
    "godot-mcp": {
      "url": "https://your-tunnel.trycloudflare.com/mcp",
      "headers": { "Authorization": "Bearer <your-token>" }
    }
  }
}
```

### stdio-only clients (Claude Desktop)

Claude Desktop cannot open an HTTP MCP connection directly, so it uses the
[`mcp-remote`](https://www.npmjs.com/package/mcp-remote) npm bridge (requires Node.js):

```json
{
  "mcpServers": {
    "godot-mcp": {
      "command": "npx",
      "args": [
        "-y", "mcp-remote", "https://your-tunnel.trycloudflare.com/mcp",
        "--header", "Authorization: Bearer <your-token>"
      ]
    }
  }
}
```

The *Copy Claude (mcp-remote)* button emits exactly this, with the public URL and token
filled in. The `Authorization` header is only added when auth is enabled in the panel.

## Security checklist

- [ ] **Enable Bearer-token auth** before exposing the server, and use a long random token.
- [ ] Keep the server bound to localhost (do **not** enable *Allow remote*); let the tunnel
      be the only public entry point.
- [ ] Share the public URL + token over a private channel; rotate the token if it leaks.
- [ ] Stop the tunnel (and the server) when you are done — an ephemeral Quick Tunnel URL
      stops working as soon as `cloudflared` exits.
- [ ] Consider the **STRICT** security level (Settings → Security) to tighten path/command
      validation while the server is publicly reachable.
