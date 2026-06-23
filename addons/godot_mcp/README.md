# Godot MCP Native Addon

This directory is the distributable Godot addon. Copy `addons/godot_mcp` into any Godot 4.7 project to run an MCP server inside the editor.

## What ships here

- `plugin.cfg` and `mcp_server_native.gd` — the editor plugin entry point.
- `native_mcp/` — JSON-RPC/MCP core, HTTP/SSE and stdio transports, auth, settings, tunnel support and tool-state management.
- `tools/` — the 214 registered MCP tools.
- `runtime/mcp_runtime_probe.gd` — optional autoload used to inspect and drive a running game.
- `ui/` — the MCP dock panel, tool manager and detail views.
- `translations/` — panel text and tool descriptions.

## Quick start

1. Copy this folder to `res://addons/godot_mcp` in your project.
2. Enable **Godot MCP Native** in **Project → Project Settings → Plugins**.
3. Open the **MCP** dock and click **Start Server**.
4. Connect an MCP client to `http://localhost:9080/mcp`.

```json
{
  "mcpServers": {
    "godot-mcp": {
      "url": "http://localhost:9080/mcp"
    }
  }
}
```

## Tool model

The addon registers 214 tools:

- 30 core tools enabled by default.
- 182 advanced tools registered but disabled until enabled from the panel or `enable_tools`.
- 2 always-on meta tools: `list_tool_catalog` and `enable_tools`.

See the project-level [Tools Reference](../../docs/tools/README.md).

## Configuration

Settings are edited from the MCP dock and stored in `user://mcp_settings.cfg`. Common settings are `transport_mode`, `http_port`, `auth_enabled`, `auth_token`, `auto_start`, `security_level`, `rate_limit` and `sse_enabled`.

Headless startup:

```bash
godot --editor --path /path/to/project -- --mcp-server --mcp-port=9080
```

## Documentation

Start with the repository [README](../../README.md), [Getting Started](../../docs/getting-started.md), [Configuration](../../docs/configuration.md) and [Tools Reference](../../docs/tools/README.md).

## License

MIT. See [LICENSE](../../LICENSE).
