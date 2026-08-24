# Godot MCP Native

[![Godot](https://img.shields.io/badge/Godot-4.7-478CBF?logo=godot-engine&logoColor=white)](https://godotengine.org)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![Version](https://img.shields.io/badge/version-1.0.7--pre1-orange.svg)](docs/changelog.md)
[![Tools](https://img.shields.io/badge/MCP%20tools-221-blue.svg)](docs/tools/README.md)

> 中文文档见 [README.zh.md](README.zh.md)。

**Drive Godot from your AI assistant.** Godot MCP Native is a Godot 4.7 editor plugin that runs a [Model Context Protocol](https://modelcontextprotocol.io) server inside the editor. AI clients such as Claude, Cursor, Cline, Trae, OpenCode and Codex can inspect and edit scenes, scripts, nodes, resources and the running game through standard MCP calls.

No Node.js bridge, no Python daemon and no separate server process are required. The protocol layer is implemented in GDScript and talks directly to Godot editor/runtime APIs.

## Highlights

- **Native server:** the MCP server lives in the editor process and ships with the plugin.
- **Two transports:** HTTP/SSE on `http://localhost:9080/mcp` by default, plus stdio for local-process clients.
- **221 tools with a small default surface:** 28 core tools are enabled immediately, 189 advanced tools can be enabled on demand, and 4 meta tools are always available for tool discovery.
- **Runtime-aware automation:** the runtime probe can inspect live scene trees, evaluate expressions, inject input, control animation/audio/shader/tilemap state, capture screenshots and collect performance metrics.
- **Security controls:** optional Bearer-token auth, path validation, rate limiting and a strict security mode built around Godot APIs rather than arbitrary OS shell access.

## Install

### Asset Library (recommended)

1. Open **AssetLib** in Godot.
2. Search for **Godot MCP Native**.
3. Click **Download → Install**.
4. Enable the plugin in **Project → Project Settings → Plugins**.

### Manual install

Copy `addons/godot_mcp` into your project's `addons/` directory, then enable **Godot MCP Native** from **Project Settings → Plugins**.

A new **MCP** dock appears after the plugin is enabled.

See [Getting Started](docs/getting-started.md) for the full walkthrough.

## Connect in 30 seconds

1. In the **MCP** dock, choose **HTTP** and click **Start Server**. The default endpoint is `http://localhost:9080/mcp`.
2. Configure your MCP client:

```json
{
  "mcpServers": {
    "godot-mcp": {
      "url": "http://localhost:9080/mcp"
    }
  }
}
```

3. Ask your assistant: `Get the Godot project info.` The client should call `get_project_info` and return project metadata.

Client-specific examples for Claude Desktop, Cursor, Trae, Cline, OpenCode and Codex are in [Getting Started](docs/getting-started.md#5-connect-an-ai-client) and [Configuration](docs/configuration.md#client-configuration).

## Tool surface

| Category | Tools | Core | Advanced | What it covers |
| --- | ---: | ---: | ---: | --- |
| [Node](docs/tools/node-tools.md) | 26 | 9 | 17 | Node CRUD, hierarchy edits, signals, groups, anchors, batch edits and scene audits |
| [Script](docs/tools/script-tools.md) | 18 | 6 | 12 | Read/write/validate GDScript and C#, shader validation, search, symbols and references |
| [Scene](docs/tools/scene-tools.md) | 12 | 4 | 8 | Create/open/save scenes, structure inspection, prefab-style instancing and TileMapLayer cells |
| [Editor](docs/tools/editor-tools.md) | 27 | 3 | 24 | Run/stop, screenshots, selection, inspector state, export templates, script buffers and undo/redo |
| [Debug & Runtime](docs/tools/debug-tools.md) | 73 | 3 | 70 | Logs, debugger control, profilers, runtime probe, deterministic play checks and regression gates |
| [Project](docs/tools/project-tools.md) | 61 | 3 | 58 | Settings, resources, input map, tests, migration scans, assets, TileSets, sprite/glTF workflows, task plans and localization |
| [Meta](docs/tools/meta-tools.md) | 4 | — | — | Always-on tool discovery and on-demand enablement |
| **Total** | **221** | **28** | **189** | |

Only core and meta tools are visible to `tools/list` at startup. The fastest path is one `enable_tools({"workflow_query": "..."})` call: an immutable local capability index routes the English/Chinese goal across `inspect → execute → verify` and atomically activates at most 8 of all 217 non-meta atomic tools without copying schemas. Official English/Chinese descriptions and exact names can address every atomic tool directly. Each definition's schema-token cost is estimated once at registration; among candidates with equal new intent coverage, the router favors the highest semantic value per incremental token while exact atomic requests retain strict priority. Normalized task goals reuse a bounded 64-route LRU; tool visibility changes preserve both the index and route cache, while only definition changes rebuild them. Core/meta stay visible and the previous task's supplementary tools are replaced by default, keeping following prompts small and cache-stable; additive and manual group/preset modes remain available. `search_tools` is retained for route previews and candidate comparison. Catalog revisions keep discovery responses small, while dependency-tagged cache revisions preserve unrelated scene/script/resource reads and invalidate exact script/resource paths lazily. See the [Tools Reference](docs/tools/README.md).

Oversized successful results remain fully recoverable without paying their full context cost up front. The response keeps the compatible head/tail preview and adds a standard MCP `resource_link`; `resources/read` then serves deterministic, UTF-8-safe 16 KiB pages addressed by the complete payload's SHA-256. Following `_meta.nextUri` reconstructs the exact JSON, while dynamic result links never enter `resources/list`. Critical errors and source/log readers stay complete inline, and any spill failure falls back to the complete inline result. The 204 KiB Unicode regression fixture avoids 95.62% of initial response bytes while verifying exact reconstruction.

## Example prompts

```text
Add a Camera2D to the current scene and make it follow the player.
Create a main menu scene with Play, Options and Quit buttons.
Read my movement script and refactor it into a state machine.
Run the project, then report live FPS, node count and recent runtime errors.
Enable the debugging preset, play a deterministic jump test and verify coyote time.
```

## Configuration at a glance

Settings are managed in the MCP dock and persisted to `user://mcp_settings.cfg`.

| Setting | Default | Purpose |
| --- | --- | --- |
| `transport_mode` | `http` | `http` for HTTP/SSE, `stdio` for local-process clients |
| `http_port` | `9080` | HTTP listener port |
| `sse_enabled` | `true` | Enable the SSE stream used by MCP clients that support it |
| `auth_enabled` | `false` | Require an `Authorization: Bearer <token>` header |
| `auth_token` | `""` | Token used when auth is enabled |
| `auto_start` | `false` | Start the server when the editor/plugin loads |
| `security_level` | `1` | `0` permissive, `1` strict path/security checks |
| `rate_limit` | `1000` | Requests per rate-limit window |

Headless launch example:

```bash
godot --editor --path /path/to/project -- --mcp-server --mcp-port=9080
```

See [Configuration](docs/configuration.md) for transports, auth, CLI overrides, client snippets and tool presets.

## Requirements

- Godot Engine 4.7 with the GL Compatibility renderer.
- No runtime Node.js or Python dependency for the plugin itself.
- `npx` is only needed when a stdio-only client uses `mcp-remote` to bridge to HTTP.
- Python 3.8+ and Godot/GUT are only needed when running the integration and unit test suites.

## Documentation

| Document | Use it for |
| --- | --- |
| [Getting Started](docs/getting-started.md) | Install, enable and connect the plugin |
| [Configuration](docs/configuration.md) | Ports, transports, auth, CLI flags, client snippets and presets |
| [Remote & Cloud Access](docs/remote-access.md) | Cloudflare Quick Tunnel, Tailscale Funnel, ngrok and public client URLs |
| [Architecture](docs/architecture.md) | Plugin lifecycle, server core, transports, tools, runtime probe and security model |
| [Tools Reference](docs/tools/README.md) | Every MCP tool, tier and category |
| [Industrialization Guide](docs/industrialization/README.md) | Planning, asset generation, deterministic playtesting and iteration loops |
| [Testing](docs/testing.md) | GUT unit tests, Python integration tests and validation tips |
| [Contributing](docs/contributing.md) | Coding standards, adding tools, docs checklist and PR workflow |
| [Changelog](docs/changelog.md) | Release notes |

## Contributing

Issues and pull requests are welcome. Read [Contributing](docs/contributing.md) before adding tools or changing MCP behavior so code, tests, translations and docs stay in sync.

## License

Released under the [MIT License](LICENSE).

## Author

**xianyu0514**

## Acknowledgments

- The Godot Engine team and community.
- The Model Context Protocol specification and ecosystem.
- AI assistant workflows pioneered by Claude and other MCP clients.

---

Godot MCP Native is a community plugin and is not officially affiliated with Godot Engine, Anthropic or any MCP client vendor.
