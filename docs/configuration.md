# Configuration

Godot MCP Native is configured primarily from the **MCP** dock. Settings are persisted to `user://mcp_settings.cfg` and applied when the plugin starts.

## Settings reference

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `transport_mode` | string | `http` | Transport to start: `http` for HTTP/SSE or `stdio` for local-process clients. |
| `http_port` | int | `9080` | Port for the HTTP MCP endpoint. |
| `sse_enabled` | bool | `true` | Enables the SSE stream used by MCP clients that subscribe to server events. |
| `auth_enabled` | bool | `false` | Requires a Bearer token on HTTP requests. |
| `auth_token` | string | `""` | Token expected in `Authorization: Bearer <token>` when auth is enabled. |
| `auto_start` | bool | `false` | Starts the MCP server automatically when the plugin loads. |
| `security_level` | int | `1` | `0` = permissive, `1` = strict path/security checks. |
| `rate_limit` | int | `1000` | Maximum requests per rate-limit window. |
| `cloudflared_path` | string | `""` | Optional path to a `cloudflared` binary used for Quick Tunnel access. |

### Persistence

User-facing settings are stored under Godot's `user://` data directory, not in the project repository. This keeps local tokens and machine-specific paths out of source control.

## Transports

### HTTP / SSE (default)

HTTP is the easiest mode for editor-integrated and remote-capable clients.

- Endpoint: `http://localhost:<http_port>/mcp`.
- Default: `http://localhost:9080/mcp`.
- Supports auth headers and SSE notifications.
- Best for Cursor, Trae, Cline, OpenCode, Codex and generic MCP clients.

Minimal client config:

```json
{
  "mcpServers": {
    "godot-mcp": {
      "url": "http://localhost:9080/mcp"
    }
  }
}
```

### stdio

stdio is useful when a client expects to spawn the MCP server as a local process.

```json
{
  "mcpServers": {
    "godot-mcp": {
      "command": "path/to/godot",
      "args": [
        "--editor",
        "--headless",
        "--path",
        "/absolute/path/to/project",
        "--",
        "--mcp-server",
        "--mcp-transport=stdio"
      ]
    }
  }
}
```

For stdio-only clients that can run `npx`, `mcp-remote` is often simpler because Godot stays open in normal HTTP mode:

```json
{
  "mcpServers": {
    "godot-mcp": {
      "command": "npx",
      "args": ["-y", "mcp-remote", "http://localhost:9080/mcp"]
    }
  }
}
```

## Authentication

When `auth_enabled` is on, every HTTP request must include:

```http
Authorization: Bearer your-secret-token-here
```

Client config example:

```json
{
  "mcpServers": {
    "godot-mcp": {
      "url": "http://localhost:9080/mcp",
      "headers": {
        "Authorization": "Bearer your-secret-token-here"
      }
    }
  }
}
```

Security recommendations:

- Use auth whenever the endpoint is reachable beyond localhost.
- Treat `auth_token` as a local secret; do not commit it.
- Prefer a long random token.
- Rotate the token after sharing a tunnel URL.

## Headless and command-line launch

Use `--` to separate Godot arguments from plugin-specific arguments:

```bash
godot --editor --path /absolute/path/to/project -- --mcp-server --mcp-port=9080
```

Supported plugin flags:

| Flag | Effect |
| --- | --- |
| `--mcp-server` | Start the MCP server when the plugin loads. |
| `--mcp-port=<port>` | Override the persisted HTTP port for this launch. |
| `--mcp-transport=<http|stdio>` | Override the persisted transport for this launch. |

### Multiple instances

Run multiple Godot projects by assigning each instance a different port:

```bash
godot --editor --path /projects/game-a -- --mcp-server --mcp-port=9080
godot --editor --path /projects/game-b -- --mcp-server --mcp-port=9081
```

Then configure clients with separate server names and URLs.

## Client configuration

Ready-to-copy examples live in [`configuration/`](configuration/):

- [`mcp-http-config-example.json`](configuration/mcp-http-config-example.json)
- [`mcp-stdio-config-example.json`](configuration/mcp-stdio-config-example.json)

### Direct HTTP URL

```json
{
  "mcpServers": {
    "godot-mcp": {
      "url": "http://localhost:9080/mcp"
    }
  }
}
```

### HTTP through `mcp-remote`

```json
{
  "mcpServers": {
    "godot-mcp": {
      "command": "npx",
      "args": ["-y", "mcp-remote", "http://localhost:9080/mcp"]
    }
  }
}
```

### Public tunnel URL

When a tunnel exposes `https://example.trycloudflare.com`, the MCP endpoint is:

```text
https://example.trycloudflare.com/mcp
```

Use the same auth header pattern if `auth_enabled` is on.

## Tool presets

The default surface is intentionally small: 30 core tools and 2 meta tools. Advanced tools are available but hidden until enabled.

| Preset/workflow | Use when |
| --- | --- |
| `minimal_core` | You want the smallest context footprint. |
| `debugging` | You need debugger, runtime probe and performance tools. |
| Category/group enablement | You need one functional area, such as `Project-Advanced` or `Debug-Advanced`. |
| Explicit tool enablement | You know the exact tool names needed for a task. |

Typical model workflow:

1. Call `list_tool_catalog` with a `group` or `query` filter.
2. Enable only the required tools or groups with `enable_tools`.
3. Let the client refresh after `notifications/tools/list_changed`.
4. Disable advanced groups when the task no longer needs them.

## Security checklist

- Keep the server on localhost unless remote access is required.
- Enable auth before using Cloudflare, Tailscale, ngrok or any public tunnel.
- Leave `security_level = 1` unless you are diagnosing a specific local issue.
- Prefer enabling advanced tools by group/task rather than exposing all 214 tools all the time.
- Review tool calls that modify scenes, resources, project settings or exports.
