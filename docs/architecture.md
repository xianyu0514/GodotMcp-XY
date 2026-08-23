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
  ├─ resources/templates/prompts/completions support
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
| `native_mcp/tools_manifest.gd` | Single source of truth for tool tier (`core`, `supplementary`, `meta`) and group membership — one entry per tool (`{name: {category, group}}`), consumed by the classifier and enforced by consistency tests. |
| `native_mcp/mcp_tool_classifier.gd` | Tool classification lookup API (`get_tool_category` / `get_tool_group` / `is_core_tool` …), generated at init from `MCPToolsManifest.TOOLS`. |
| `native_mcp/mcp_auth_manager.gd` | Bearer-token validation. |
| `native_mcp/settings_manager.gd` | Persistent user settings. |
| `native_mcp/tool_state_manager.gd` | Per-tool enable/disable state. |
| `native_mcp/mcp_tunnel_manager.gd` | Cloudflare Quick Tunnel process supervision. |
| `native_mcp/mcp_cloudflared_provider.gd` | Download/verification helper for `cloudflared`. |

## Tool modules

Each category is implemented in one or more files under `addons/godot_mcp/tools/`. The
Project category was split from the 9393-line `project_tools_native.gd` into one main
module (shared helpers + project-info/config/input/autoload/class-metadata/test-runner
tools) plus five domain modules (resources, assets, tileset, verification, workflow).
The Debug category was split the same way: the 4480-line `debug_tools_native.gd` keeps
the main class (shared static helpers + logs/misc + script execution) and the bridge,
runtime-probe and verify domains moved into three dedicated modules:

| File | Category | Tools |
| --- | --- | ---: |
| `node_tools_native.gd` | Node | 26 |
| `script_tools_native.gd` | Script | 18 |
| `scene_tools_native.gd` | Scene | 12 |
| `editor_tools_native.gd` | Editor | 27 |
| `debug_tools_native.gd` | Debug (main: logs/misc + shared static helpers) | 6 |
| `debug_bridge_tools.gd` | Debug (bridge + execution control) | 28 |
| `debug_runtime_tools.gd` | Debug (runtime probe) | 38 |
| `debug_verify_tools.gd` | Debug (verify gates: play_and_verify/visual playtest/perf budget/runtime errors) | 4 |
| `project_tools_native.gd` | Project (main: compact context/info/config/input/autoload/class metadata/tests) | 17 |
| `project_resources_tools.gd` | Project (resources: create/read/update/deps/migration/UID) | 21 |
| `project_assets_tools.gd` | Project (assets: generate/3D/slice/glTF/gradient/drawable/PCK/render) | 9 |
| `project_tileset_tools.gd` | Project (TileSet: create/layers/collision/terrain/inspect) | 5 |
| `project_verification_tools.gd` | Project (verification: visual baseline/screenshot diff) | 2 |
| `project_workflow_tools.gd` | Project (workflow: atomic change sets/version/theme/animation/task plan/localization) | 9 |
| `meta_tools_native.gd` | Meta | 4 |

Tool registration uses `server_core.register_tool(...)` with name, description, input schema, callable, output schema, annotations, category and group. The category/group come from the single manifest (`native_mcp/tools_manifest.gd`), which the classifier reads to answer whether a tool is core, advanced or meta. `test_mcp_tool_classifier.gd` enforces that the manifest, the classifier and the runtime registry never drift (tool-name sets and per-tool category/group must match).

### Tool annotations

Every registered tool is normalized to a complete MCP `annotations` object with `readOnlyHint`, `destructiveHint`, `idempotentHint` and `openWorldHint`. Explicit annotations declared by a tool always win; if a registration omits any key, `MCPTypes.normalize_tool_annotations()` fills the missing key from a conservative, name-based inference (`get_*`, `list_*`, `search_*`, etc. are read-only, while `delete_*`, `remove_*`, `clear_*`, etc. are destructive). Unknown tool names default to all-false so safety is never overestimated.

These hints flow to three places that agents already consume:

- `tools/list` exposes the standard `annotations` object so MCP clients can apply their own auto-approval policies.
- `list_tool_catalog` and `search_tools` return the same four flags per entry, letting an agent choose safe read-only discovery calls before switching on mutating tools.
- `get_registered_tools()` carries the normalized flags so the dock UI and internal discovery paths share one source of truth.

## Core, advanced and meta tiers

- **Core:** 30 high-value tools enabled by default.
- **Advanced:** 189 tools registered but hidden from `tools/list` until enabled.
- **Meta:** 4 always-on discovery tools: `list_tool_catalog`, `search_tools`, `get_tool_details` and `enable_tools`.

This design keeps the default client context small without making specialized capabilities unavailable.

The compact context loop exposes the same snapshot through the core `get_project_context` tool and the subscribable `godot://project/context` resource. The payload uses canonical ordering plus whole-content and per-section SHA-256 revisions; clients can suppress an unchanged snapshot or request only changed sections. After any successful tool marked `readOnlyHint=false`, the server emits `notifications/resources/updated` for subscribed resources.

Protocol discovery is bounded and dynamic: `tools/list`, `resources/list`, `resources/templates/list` and `prompts/list` return deterministic pages of at most 100 entries. `completion/complete` serves prompt arguments and the `godot://script/{path}` / `godot://scene/{path}` templates; template reads validate project-relative paths and load files only from `res://`.

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

High-frequency edit tools close the cheapest verification loop in-process: `create_node` and `update_node_property` return structured read-back evidence from the live node/property, while `modify_script` skips unchanged writes and compiles changed GDScript once by default. This avoids a project rescan or game launch while preventing successful transport responses from being mistaken for verified edits.

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
