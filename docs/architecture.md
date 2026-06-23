# Architecture

Godot MCP Native is a Godot editor plugin that embeds an MCP server in the editor process. The server exposes editor, project and runtime capabilities through JSON-RPC/MCP tools while using Godot APIs as the execution boundary.

## High-level view

```text
MCP client
  │ HTTP/SSE or stdio
  ▼
Transport layer
  │ JSON-RPC messages
  ▼
MCP server core
  ├─ tool registry and classification
  ├─ auth, rate limit and security checks
  ├─ resources/prompts support
  └─ notifications
      │
      ▼
Tool modules ── Godot EditorInterface / ProjectSettings / ResourceLoader
      │
      └─ Runtime probe autoload for running-game inspection and control
```

## Plugin lifecycle

1. Godot loads `addons/godot_mcp/plugin.cfg`.
2. `mcp_server_native.gd` is instantiated as an `EditorPlugin`.
3. Settings are loaded from `user://mcp_settings.cfg`.
4. Tool modules, resources and UI are registered.
5. The server starts when the user clicks **Start Server**, when `auto_start` is true, or when Godot launches with `--mcp-server`.
6. Connected clients call MCP tools through HTTP/SSE or stdio.

## Core components

| Component | Responsibility |
| --- | --- |
| `mcp_server_native.gd` | EditorPlugin entry point, settings wiring, panel registration and server lifecycle. |
| `native_mcp/mcp_server_core.gd` | JSON-RPC/MCP method handling, tool registry, notifications and server-wide options. |
| `native_mcp/mcp_http_server.gd` | HTTP endpoint and SSE transport. |
| `native_mcp/mcp_stdio_server.gd` | stdio transport for clients that spawn the server process. |
| `native_mcp/mcp_types.gd` | Protocol constants and shared data structures. |
| `native_mcp/mcp_tool_classifier.gd` | Source of truth for tool tier (`core`, `supplementary`, `meta`) and group membership. |
| `native_mcp/mcp_auth_manager.gd` | Bearer-token validation. |
| `native_mcp/settings_manager.gd` | Persistent user settings. |
| `native_mcp/tool_state_manager.gd` | Per-tool enable/disable state. |
| `native_mcp/mcp_tunnel_manager.gd` | Cloudflare Quick Tunnel process supervision. |
| `native_mcp/mcp_cloudflared_provider.gd` | Download/verification helper for `cloudflared`. |

## Tool modules

Each category is implemented in one file under `addons/godot_mcp/tools/`:

| File | Category | Tools |
| --- | --- | ---: |
| `node_tools_native.gd` | Node | 26 |
| `script_tools_native.gd` | Script | 17 |
| `scene_tools_native.gd` | Scene | 12 |
| `editor_tools_native.gd` | Editor | 24 |
| `debug_tools_native.gd` | Debug & Runtime | 73 |
| `project_tools_native.gd` | Project | 60 |
| `meta_tools_native.gd` | Meta | 2 |

Tool registration uses `server_core.register_tool(...)` with name, description, input schema, callable, output schema, annotations, category and group. The classifier controls whether a tool is core, advanced or meta.

## Core, advanced and meta tiers

- **Core:** 30 high-value tools enabled by default.
- **Advanced:** 182 tools registered but hidden from `tools/list` until enabled.
- **Meta:** 2 always-on discovery tools: `list_tool_catalog` and `enable_tools`.

This design keeps the default client context small without making specialized capabilities unavailable.

## Runtime probe

`runtime/mcp_runtime_probe.gd` is an Autoload used by runtime tools. It lets the MCP server inspect and drive a running game without relying solely on edit-time state.

Runtime probe capabilities include:

- Live scene tree inspection.
- Runtime node property updates and method calls.
- Expression/condition evaluation.
- Input action and event simulation.
- Animation, AnimationTree, material, shader, theme, TileMap and audio-bus control.
- Screenshot, performance and memory snapshots.
- Deterministic play verification workflows.

## UI

The MCP dock is implemented under `addons/godot_mcp/ui/`.

| UI file | Role |
| --- | --- |
| `mcp_panel_native.tscn` / `mcp_panel_native.gd` | Main dock: start/stop, settings, tunnel controls, logs and tool management. |
| `mcp_tool_item.gd` | Individual tool row/toggle. |
| `mcp_tool_group_item.gd` | Group-level expand/collapse and enablement. |
| `mcp_tool_detail_panel.gd` | Tool details and schema display. |
| `mcp_category_nav_item.gd` | Category navigation. |

## Utilities

| Utility | Purpose |
| --- | --- |
| `utils/path_validator.gd` | Validate project/user paths before file operations. |
| `utils/resource_utils.gd` | Resource load/save and serialization helpers. |
| `utils/script_utils.gd` | Script parsing and manipulation helpers. |
| `utils/node_utils.gd` | Node lookup and property helpers. |
| `utils/payload_utils.gd` | Normalize/validate tool payloads. |
| `utils/vibe_coding_policy.gd` | Guardrails for editor focus/window behavior. |
| `utils/async_job_runner.gd` | Background job orchestration for long-running work. |

## Security model

Security is layered rather than delegated to a shell:

1. **Transport boundary:** HTTP/SSE stays on localhost by default; stdio is process-local.
2. **Authentication:** optional Bearer-token auth for HTTP clients.
3. **Rate limiting:** request throttling protects the editor from accidental floods.
4. **Path validation:** file/resource tools validate project-relative and user paths.
5. **Tool tiering:** advanced tools are disabled until explicitly enabled.
6. **Godot API execution:** tools use editor/runtime APIs instead of arbitrary OS command execution.

When exposing the server beyond localhost, enable auth and use the strict security level.
