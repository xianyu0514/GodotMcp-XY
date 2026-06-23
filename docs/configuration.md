# Configuration

All runtime behaviour is controlled by a small set of settings. You edit them from the
**MCP** dock panel; they are persisted and also honoured by headless launches.

## Settings reference

These are the canonical keys and defaults (from
`addons/godot_mcp/native_mcp/settings_manager.gd`):

| Setting | Default | Purpose |
| --- | --- | --- |
| `transport_mode` | `"http"` | Active transport: `"http"` or `"stdio"`. |
| `http_port` | `9080` | TCP port for the HTTP transport. |
| `auth_enabled` | `false` | Require a Bearer token on every HTTP request. |
| `auth_token` | `""` | The expected token (use ≥ 16 chars in production). |
| `sse_enabled` | `true` | Allow Server-Sent Events streaming responses over HTTP. |
| `allow_remote` | `false` | Accept connections from non-localhost addresses. |
| `cors_origin` | `"*"` | `Access-Control-Allow-Origin` value for browser clients. |
| `auto_start` | `false` | Start the server automatically when the plugin loads. |
| `log_level` | `2` | Verbosity (higher = more detail). |
| `security_level` | `1` | Strictness of path/operation validation. |
| `rate_limit` | `1000` | Max requests per window before throttling. |
| `language` | `"en"` | UI language for the dock panel. |

### Persistence

Settings are saved to **`user://mcp_settings.cfg`** (section `[settings]`) with an integrity
checksum. Because the file lives under `user://`, it survives editor restarts and is shared
between interactive and headless runs of the same project.

## Transports

### HTTP / SSE (default)

- Listens on `http://localhost:<http_port>/mcp` (the root path `/` is also accepted).
- Standard request/response JSON-RPC, plus optional **SSE** streaming when `sse_enabled` is
  on and the client requests it.
- Best for editor integrations, remote access, and clients that speak `streamableHttp`.

### stdio

- Communicates over standard input/output, the classic local-process MCP model.
- Selected with `transport_mode = "stdio"` (or `--mcp-transport=stdio` on the command line).
- See [`configuration/mcp-stdio-config-example.json`](configuration/mcp-stdio-config-example.json)
  for a client snippet.

## Authentication

When `auth_enabled` is `true`, every HTTP request must carry a Bearer token:

```
Authorization: Bearer <auth_token>
```

- The header name is matched case-insensitively (`authorization`).
- A missing or wrong token returns **`401 Unauthorized`**.
- Use a strong token (≥ 16 characters mixing letters, digits and symbols) and never commit
  it to version control.

## Headless & command-line launch

Run the editor as an MCP server with no UI:

```bash
godot --editor --path /path/to/project -- --mcp-server
```

Headless `--mcp-server` mode **reads `user://mcp_settings.cfg`**, so the port, transport and
auth options you configured in the panel are respected.

### CLI flag overrides

Flags after `--` take precedence over the persisted config — useful for CI and for running
isolated instances:

| Flag | Value | Effect |
| --- | --- | --- |
| `--mcp-server` | — | Enable MCP server mode for this launch. |
| `--mcp-port=N` | `1024`–`65535` | Override `http_port` (out-of-range values are ignored). |
| `--mcp-transport=MODE` | `http` \| `stdio` | Override `transport_mode` (unknown values ignored). |

### Multiple instances in parallel

Give each instance its own port:

```bash
godot --editor --path /path/to/projectA -- --mcp-server --mcp-port=9080
godot --editor --path /path/to/projectB -- --mcp-server --mcp-port=19081
```

## Client configuration

The default port is `9080` and the endpoint is `/mcp`. Pick the form your client supports.

### Direct HTTP URL

```json
{
  "mcpServers": {
    "godot-mcp": { "url": "http://localhost:9080/mcp" }
  }
}
```

### HTTP with authentication

```json
{
  "mcpServers": {
    "godot-mcp": {
      "url": "http://localhost:9080/mcp",
      "headers": { "Authorization": "Bearer your-secret-token-here" }
    }
  }
}
```

### Through the `mcp-remote` bridge (e.g. Claude Desktop)

```json
{
  "mcpServers": {
    "godot-mcp": {
      "command": "npx",
      "args": ["mcp-remote", "http://localhost:9080/mcp"]
    }
  }
}
```

Per-client variants (Cursor, Trae, Cline, OpenCode, Codex) are listed in
[Getting Started → Connect an AI client](getting-started.md#5-connect-an-ai-client).

### Generate snippets from the panel

You don't have to write these by hand. The status bar exposes a **Copy Config** menu that
copies a ready-to-paste configuration to the clipboard, with the current port and (when
enabled) the auth token already filled in:

- **HTTP (Cursor / Cline)** — emits the `url` form shown above, adding the `Authorization`
  header automatically when authentication is enabled.
- **stdio (Claude Desktop)** — emits a `command`/`args` form that launches this project
  with `--editor --headless ... -- --mcp-server --mcp-transport=stdio`, using the running
  editor's executable and project path. `--editor` is required: the server is an
  `EditorPlugin`, so it only starts when the editor loads.

The **Self-Check** button next to it issues a quick HTTP probe to the running server and
reports whether the endpoint is reachable, so customers can confirm connectivity before
wiring up a client.

To reach the server from a remote client or the cloud, use the **Remote / Cloud access**
card in Settings — see [Remote & Cloud Access](remote-access.md).

## Tool presets

The Tool Manager tab includes a **preset selector** so teams can switch the enabled tool set
in one click instead of toggling tools individually. Each preset enables the 30 core tools
(plus the 2 always-on meta tools) and the advanced groups relevant to a workflow:

| Preset | `preset` id | Enables | Typical use |
| --- | --- | --- | --- |
| Minimal (core only) | `minimal_core` | 30 core + 2 meta | Smallest, safest surface for vibe-coding |
| Level Design | `level_design` | core + node/scene/editor authoring | Building and arranging scenes |
| Debugging | `debugging` | core + runtime/debugger tools | Inspecting a running game |
| QA Automation | `automation_qa` | core + debug + project (test runners) | Automated test and input flows |
| Art & Resources | `art_resources` | core + resource/scene authoring | Themes, tilesets, materials, resources |
| All tools | `all` | every registered tool (212) | Power users |

The AI can also apply these presets itself without touching the panel by calling the
`enable_tools` meta tool with a `preset` id (e.g. `enable_tools({preset: "debugging"})`), or
discover individual tools first with `list_tool_catalog`. See
[Meta tools](tools/README.md#meta-tools-tool-discovery).

Presets can be shared across a team:

- **Export** writes the currently enabled tools to a `.json` file
  (`{ "version": 1, "enabled_tools": [...] }`).
- **Import** reads such a file and applies it; unknown tool names are ignored, so a preset
  exported from a newer build still loads safely.

A team lead can export one curated file and distribute it so every client starts from the
same tool configuration.

## Security recommendations

- **Production:** turn on `auth_enabled` and set a strong `auth_token`.
- **Remote access:** keep `allow_remote` off unless required, and front the server with TLS
  (HTTPS) when exposing it on a network.
- **Tokens:** never commit them; rotate if leaked.
- **CORS:** narrow `cors_origin` from `"*"` to the specific origins you trust for browser
  clients.
