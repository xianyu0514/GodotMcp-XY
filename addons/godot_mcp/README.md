# Godot MCP Native

[![Godot](https://img.shields.io/badge/Godot-4.7-478CBF?logo=godot-engine&logoColor=white)](https://godotengine.org)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![Version](https://img.shields.io/badge/version-1.0.7--pre1-orange.svg)](../../docs/changelog.md)

> 中文说明见 [README.zh.md](README.zh.md)

An editor plugin that runs a [Model Context Protocol](https://modelcontextprotocol.io) server
**inside Godot**, letting AI assistants (Claude, Cursor, Cline, Codex, …) read and edit your
project — scenes, scripts, nodes, resources, and the running game — over a standard protocol.
The server is pure GDScript: **no Node.js, no Python, no external bridge**.

## Highlights

- **204 MCP tools** in 6 categories (30 core enabled by default; 172 advanced, opt-in) plus 2 always-on meta tools for tool discovery (`list_tool_catalog`, `enable_tools`).
- **HTTP/SSE** (default port `9080`) and **stdio** transports.
- **Runtime probe** to inspect and drive a *running* game, not just edit-time state.
- Optional **Bearer-token auth**, path validation, and a configurable security level.

## Quick start

1. Enable the plugin in **Project → Project Settings → Plugins**.
2. In the **MCP** dock panel, choose **HTTP** and click **Start** (default port `9080`).
3. Point your AI client at `http://localhost:9080/mcp`:

```json
{
  "mcpServers": {
    "godot-mcp": { "url": "http://localhost:9080/mcp" }
  }
}
```

4. Ask your assistant to *"get the Godot project info"* to confirm the connection.

## Tools

| Category | Tools | Category | Tools |
| --- | ---: | --- | ---: |
| Node | 26 | Editor | 23 |
| Script | 17 | Debug & Runtime | 71 |
| Scene | 12 | Project | 53 |

Only the 30 core tools are on by default; enable advanced tools from the MCP panel.
Full list: [Tools Reference](../../docs/tools/README.md).

## Configuration

Settings live in the MCP panel and persist to `user://mcp_settings.cfg`
(`transport_mode`, `http_port`, `auth_enabled`, `auth_token`, `sse_enabled`, …).
Headless launch: `godot --editor --path <project> -- --mcp-server --mcp-port=9080`.

See [Configuration](../../docs/configuration.md) for the full reference.

## Documentation

[Getting Started](../../docs/getting-started.md) ·
[Configuration](../../docs/configuration.md) ·
[Architecture](../../docs/architecture.md) ·
[Tools](../../docs/tools/README.md) ·
[Testing](../../docs/testing.md) ·
[Contributing](../../docs/contributing.md)

## License

[MIT](LICENSE) · **Author:** xianyu0514

*Community plugin — not officially affiliated with Godot Engine or Anthropic.*
