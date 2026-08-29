# Remote & Cloud Access

The MCP server starts on localhost by default. Remote access is only needed when the MCP client runs outside the same machine as Godot: a cloud IDE, another workstation, or a hosted AI tool.

## Mental model

```text
Remote MCP client ── public HTTPS URL ── tunnel ── localhost:9080 ── Godot MCP server
```

The public URL should point to the local MCP endpoint with `/mcp` appended.

## Before exposing the server

1. Enable `auth_enabled` in the MCP panel.
2. Set a long random `auth_token`.
3. Keep `security_level = 1`.
4. Enable only the advanced tool groups needed for the task.
5. Stop the tunnel when the remote session is done.

## Option A — Built-in Cloudflare Quick Tunnel

The MCP panel can manage a Cloudflare Quick Tunnel through `cloudflared`.

1. Start the local MCP server.
2. Enable auth if the tunnel will be shared.
3. Use the tunnel control in the MCP panel.
4. Copy the generated `https://*.trycloudflare.com` URL.
5. Configure the client with `<public-url>/mcp`.

### Tunnel lifetime and automatic restore

The built-in tunnel belongs to the user session, not to the current Godot
process. After **Start free tunnel** succeeds:

- reloading the project, disabling/re-enabling the plugin, or closing Godot does
  not terminate `cloudflared`;
- reopening the same project validates the saved PID, executable and unique log
  path, then restores the same `trycloudflare.com` URL instead of creating a new
  Quick Tunnel;
- only **Stop tunnel** terminates the managed process and removes its session;
- shutting down the computer naturally ends the process. On the next boot, stale
  metadata is rejected and no replacement tunnel is started automatically.

The process is launched independently with a durable `cloudflared.log`. The log
and small `session.json` ownership record are stored under the OS user's
`GodotMcp-XY/tunnels/<project-hash>/` data directory. The command line is checked
before a restored PID can be stopped, so a PID reused after reboot cannot cause
an unrelated process to be terminated.

The panel shows each startup stage instead of waiting silently. Reusable local
installations are checked first. If a download is required, live MiB progress is
shown; a source that makes no progress for 12 seconds or remains unusually slow
while fallbacks are available is replaced automatically. **Stop tunnel** cancels
the current download. After `cloudflared` starts, the panel
waits up to 30 seconds for the Quick Tunnel URL; a timeout stops the incomplete
process and shows the durable log path. Tunnel source, launch, restore, timeout
and exit events are also flushed immediately to `mcp_server.log` for diagnosis.

While Godot is closed, the public hostname remains allocated to the live tunnel
process, but its `localhost:<port>` origin is unavailable. Requests may therefore
fail until Godot and the local MCP server are running again.

The Start action is local-first and checks these sources in order:

1. The optional **Local cloudflared** override in the panel.
2. A `cloudflared` executable already available on the editor process `PATH`.
3. The plugin's checksum-verified shared cache.
4. Checksum-verified `user://cloudflared` caches from the current or another local Godot project; a match is copied into the shared cache without deleting the old file.

Only when no local source is reusable does the plugin download the pinned official binary. Managed downloads are shared across all Godot projects for the current OS user and isolated by pinned version plus OS/architecture:

| OS | Shared cache root |
| --- | --- |
| Windows | `%APPDATA%\GodotMcp-XY\cloudflared` |
| macOS | `~/Library/Application Support/GodotMcp-XY/cloudflared` |
| Linux/BSD | `$XDG_DATA_HOME/GodotMcp-XY/cloudflared`, normally `~/.local/share/GodotMcp-XY/cloudflared` |

The cache root contains `<pinned-version>/<platform>/`, so different plugin versions, x64 and ARM builds cannot overwrite one another.

The manual path field remains available on supported platforms. Use it when Godot was launched from a desktop environment whose `PATH` does not include a package-manager installation.

Example client config:

```json
{
  "mcpServers": {
    "godot-mcp": {
      "url": "https://example.trycloudflare.com/mcp",
      "headers": {
        "Authorization": "Bearer your-secret-token-here"
      }
    }
  }
}
```

### Manual Cloudflare fallback

If you manage `cloudflared` yourself:

```bash
cloudflared tunnel --url http://localhost:9080
```

Use the generated public base URL plus `/mcp`.

## Option B — Tailscale Funnel

Tailscale Funnel is useful when both machines are already in a Tailscale workflow.

```bash
tailscale funnel 9080
```

Then configure the client with the Funnel URL plus `/mcp` and the auth header.

## Option C — ngrok

ngrok works well for short-lived manual sessions:

```bash
ngrok http 9080
```

Use the HTTPS forwarding URL plus `/mcp`.

## stdio-only clients over a public URL

If the client only supports stdio but can run a local command, bridge with `mcp-remote`:

```json
{
  "mcpServers": {
    "godot-mcp": {
      "command": "npx",
      "args": [
        "-y",
        "mcp-remote",
        "https://example.trycloudflare.com/mcp",
        "--header",
        "Authorization: Bearer your-secret-token-here"
      ]
    }
  }
}
```

## Troubleshooting

| Symptom | Check |
| --- | --- |
| Public URL opens but MCP calls fail | Ensure the client URL ends with `/mcp`. |
| 401/403 responses | Confirm the Bearer token exactly matches `auth_token`. |
| Tunnel starts but no URL appears | Check the MCP panel logs or run the tunnel command manually. |
| Tunnel startup remains on one stage | Download progress is shown and stalled sources switch after 12 seconds; URL discovery ends after 30 seconds. Use **Stop tunnel** to cancel immediately, then inspect the log path shown in the status line. |
| Godot reopened but the old URL was not restored | The computer was restarted, `cloudflared` exited, or its saved PID no longer matches the managed command. Start a new tunnel. |
| The restored URL responds with an origin error | Start the local MCP server on the saved HTTP port; the tunnel can outlive Godot, but the origin cannot. |
| The panel wants to download again | Check that the local override points to a file, or place `cloudflared` on the editor process `PATH`. Current-version managed and legacy files must pass the pinned SHA-256 check before reuse. |
| Client connects but tools are missing | Enable the required advanced groups with the MCP panel or `enable_tools`. |
| Connection is slow | Prefer a tunnel geographically close to the client and avoid enabling all advanced tools. |

## Shutdown checklist

- Stop the remote client session.
- Click **Stop tunnel** when the public session is finished. Closing Godot alone
  intentionally leaves it running until the next Godot session or computer
  shutdown.
- Rotate the token if it was shared outside your machine.
- Disable any advanced tool groups no longer needed.
