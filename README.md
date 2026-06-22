# Godot MCP Native

[![Godot](https://img.shields.io/badge/Godot-4.7-478CBF?logo=godot-engine&logoColor=white)](https://godotengine.org)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![Version](https://img.shields.io/badge/version-1.0.7--pre1-orange.svg)](docs/changelog.md)
[![Tools](https://img.shields.io/badge/MCP%20tools-204-blue.svg)](docs/tools/README.md)

> 中文文档见 [README.zh.md](README.zh.md)

**Drive Godot from your AI assistant.** Godot MCP Native is an editor plugin that runs a
[Model Context Protocol](https://modelcontextprotocol.io) server *inside* Godot, so AI
clients like Claude, Cursor, Cline and Codex can read and edit your project — scenes,
scripts, nodes, resources, and even the running game — through natural language.

No Node.js. No Python bridge. No external server to babysit. The protocol is implemented in
GDScript and talks directly to the engine.

---

## Why this plugin

- **Native & dependency-free** — the MCP server is part of the editor process; there is
  nothing else to install or keep running.
- **Two transports** — HTTP/SSE (default, port `9080`) for editor and remote clients, and
  stdio for local-process clients.
- **204 tools, sensibly scoped** — 30 high-value *core* tools are on by default; 172 more
  *advanced* tools are one click away when you need them.
- **Runtime-aware** — a probe lets the AI inspect and manipulate a *running* game, not just
  edit-time state: live scene tree, expression evaluation, input injection, animation/audio
  /shader/tilemap control.
- **Safe by construction** — optional Bearer-token auth, path validation, and engine APIs
  instead of shelling out to the OS.

## Install

**Asset Library (recommended):** open **AssetLib** in Godot, search **"Godot MCP Native"**,
then **Download → Install**.

**Manual:** copy `addons/godot_mcp` into your project's `addons/` folder.

Then enable it in **Project → Project Settings → Plugins**. A new **MCP** dock panel appears.

➡️ Full walkthrough: [docs/getting-started.md](docs/getting-started.md)

## Connect in 30 seconds

1. In the **MCP** panel, pick **HTTP** and click **Start** (default port `9080`).
2. Point your client at `http://localhost:9080/mcp`:

```json
{
  "mcpServers": {
    "godot-mcp": { "url": "http://localhost:9080/mcp" }
  }
}
```

3. Ask your assistant: *"Get the Godot project info."* — it calls `get_project_info` and
   you're connected.

Snippets for Claude Desktop, Cursor, Trae, Cline, OpenCode and Codex are in
[Getting Started](docs/getting-started.md#5-connect-an-ai-client) and
[Configuration](docs/configuration.md#client-configuration).

## What the AI can do

The plugin exposes **204 tools** in six categories (plus 2 always-on *meta* tools for tool discovery). Each links to a full, per-tool reference.

| Category | Tools | What it covers |
| --- | ---: | --- |
| [Node](docs/tools/node-tools.md) | 26 | Create/edit nodes, signals, groups, anchors, batch edits, audits |
| [Script](docs/tools/script-tools.md) | 17 | Read/write/validate GDScript & C#, search, symbol indexing |
| [Scene](docs/tools/scene-tools.md) | 12 | Create/open/save scenes, structure, prefab instancing, tilemaps |
| [Editor](docs/tools/editor-tools.md) | 23 | Run/stop, screenshots, selection, inspector, export, buffer sync |
| [Debug & Runtime](docs/tools/debug-tools.md) | 71 | Logs, debugger, breakpoints, profilers, live runtime control |
| [Project](docs/tools/project-tools.md) | 53 | Settings, resources, input map, audits, 4.7 migration, assets |
| [Meta](docs/tools/README.md#meta-tools-tool-discovery) | 2 | Always-on tool discovery & on-demand enabling (`list_tool_catalog`, `enable_tools`) |

Only the 30 **core** tools (plus 2 always-on **meta** tools) are enabled by default — enable any of the 172 **advanced** tools
from the MCP panel. See the [Tools Reference](docs/tools/README.md).

### Example prompts

```
Add a Camera2D to the current scene and make it follow the player.
Create a main menu scene with Play, Options and Quit buttons.
Read my movement script and refactor it to use a state machine.
Run the project, then tell me the live FPS and node count.
```

## Configuration

Configure everything from the MCP panel; settings persist to `user://mcp_settings.cfg`.

| Setting | Default | Setting | Default |
| --- | --- | --- | --- |
| `transport_mode` | `http` | `sse_enabled` | `true` |
| `http_port` | `9080` | `auto_start` | `false` |
| `auth_enabled` | `false` | `security_level` | `1` |
| `auth_token` | `""` | `rate_limit` | `1000` |

Headless launch and CLI overrides:

```bash
godot --editor --path /path/to/project -- --mcp-server --mcp-port=9080
```

➡️ Details: [docs/configuration.md](docs/configuration.md)

## Requirements

- Godot Engine 4.7 (GL Compatibility renderer).
- No runtime dependencies. `npx` is only needed for clients that connect via `mcp-remote`;
  Python 3.8+ is only needed to run the integration tests.

## Documentation

- [Getting Started](docs/getting-started.md)
- [Configuration](docs/configuration.md)
- [Architecture](docs/architecture.md)
- [Tools Reference](docs/tools/README.md)
- [Testing](docs/testing.md)
- [Contributing](docs/contributing.md)
- [Changelog](docs/changelog.md)

## Contributing

Issues and pull requests are welcome. Please read [docs/contributing.md](docs/contributing.md)
for conventions, the tool-authoring workflow, and the docs-update checklist.

## License

Released under the [MIT License](LICENSE).

## Author

**xianyu0514**

## Acknowledgments

- The Godot Engine team.
- The Model Context Protocol specification and community.
- Anthropic's Claude, which inspired this integration.

---

*Community plugin — not officially affiliated with Godot Engine or Anthropic.*
