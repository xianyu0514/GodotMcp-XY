# Architecture

Godot MCP Native embeds an MCP server inside the Godot editor process. There is no broker,
sidecar, or language runtime between the AI client and the engine — requests are handled by
GDScript that already has first-class access to `EditorInterface`, the `SceneTree`,
`ClassDB`, and the resource system.

## High-level view

```
AI client (Claude / Cursor / Cline / …)
        │  JSON-RPC over HTTP(+SSE) or stdio
        ▼
Transport  (mcp_http_server.gd | mcp_stdio_server.gd)
        │  decoded MCP request
        ▼
Server core (mcp_server_core.gd)
   ├─ auth check ............ mcp_auth_manager.gd
   ├─ tool registry ......... per-category *_tools_native.gd
   ├─ classification ........ mcp_tool_classifier.gd
   ├─ resources ............. mcp_resource_manager.gd
   └─ debugger bridge ....... mcp_debugger_bridge.gd
        │  Godot editor / engine APIs
        ▼
Editor state, scenes, scripts, resources  ── and ──  the running game (via the runtime probe)
```

A request flows in one direction and back: the transport decodes it, the core authenticates
and dispatches it to the registered tool `Callable`, the tool acts on the engine, and the
result is serialised back to the client over the same transport.

## Plugin lifecycle

`mcp_server_native.gd` is the `EditorPlugin` entry point. On load it:

1. Reads `user://mcp_settings.cfg` (so headless `--mcp-server` runs honour the saved config).
2. Applies any command-line overrides (`--mcp-port`, `--mcp-transport`).
3. Constructs the server core, registers every tool, and adds the **MCP** dock panel.
4. Optionally auto-starts the server when `auto_start` is set or `--mcp-server` is present.

## Core components

| File | Responsibility |
| --- | --- |
| `native_mcp/mcp_server_core.gd` | The hub: tool registration, JSON-RPC dispatch, signal bus. |
| `native_mcp/mcp_transport_base.gd` | Abstract base shared by all transports. |
| `native_mcp/mcp_http_server.gd` | HTTP/SSE transport; serves `/mcp` (default port 9080). |
| `native_mcp/mcp_stdio_server.gd` | stdio transport for local-process clients. |
| `native_mcp/mcp_types.gd` | JSON-RPC / MCP protocol constants and the `MCPTool` data class. |
| `native_mcp/mcp_tool_classifier.gd` | Maps each tool to `{category, group}`; enforces `CORE_MAX_COUNT = 30`. |
| `native_mcp/mcp_resource_manager.gd` | MCP resource reads, listing and subscriptions. |
| `native_mcp/mcp_debugger_bridge.gd` | Bridges Godot's debugger to MCP (breakpoints, stack frames, variables). |
| `native_mcp/mcp_auth_manager.gd` | HTTP Bearer-token authentication. |
| `native_mcp/config_manager.gd` | Generic config file read/write with checksum. |
| `native_mcp/settings_manager.gd` | Editor-facing settings + defaults, persisted to `user://`. |
| `native_mcp/tool_state_manager.gd` | Per-tool enabled/disabled state. |
| `native_mcp/translation_manager.gd` | Panel and tool-description localisation. |

## Tools

Tool implementations live in `addons/godot_mcp/tools/`, one file per category:

| File | Category | Tools |
| --- | --- | ---: |
| `node_tools_native.gd` | Node | 26 |
| `script_tools_native.gd` | Script | 17 |
| `scene_tools_native.gd` | Scene | 12 |
| `editor_tools_native.gd` | Editor | 23 |
| `debug_tools_native.gd` | Debug & Runtime | 71 |
| `project_tools_native.gd` | Project | 53 |
| | **Total** | **202** |

Each tool registers a name, JSON input/output schema, a handler `Callable`, annotations, and
its category/group. The classifier decides whether a tool ships as **core** (enabled by
default) or **advanced** (registered but disabled until the user turns it on). See the
[Tools Reference](tools/README.md) for the full list.

## Runtime probe

`runtime/mcp_runtime_probe.gd` is an **autoload singleton** (`MCPRuntimeProbe`) that ships
with the plugin. When a project runs, the probe gives the debug/runtime tools a live channel
into the game: the runtime scene tree, node inspection and mutation, expression evaluation,
input injection, and animation / audio / shader / theme / tilemap control. The first probe
request typically returns `pending`; calling again returns the cached response.

## UI

The dock panel under `addons/godot_mcp/ui/` is built from plain Godot Control nodes:

- `mcp_panel_native.gd` — the main panel: start/stop, transport configuration, log viewer,
  and tool management.
- `mcp_tool_group_item.gd` / `mcp_tool_item.gd` — collapsible group and per-tool toggles.

## Utilities

Shared helpers in `addons/godot_mcp/utils/` keep the tools small and consistent:

- `node_utils.gd`, `resource_utils.gd`, `script_utils.gd` — node lookup and resource/script I/O.
- `path_validator.gd` — validates paths before any file operation.
- `vibe_coding_policy.gd` — guards interactive operations (`allow_ui_focus` / `allow_window`).

## Security model

Because the server runs inside the engine, it never shells out to the OS. Instead it:

- validates every incoming path through `path_validator.gd`;
- gates HTTP access behind optional Bearer-token auth (`mcp_auth_manager.gd`);
- applies a configurable `security_level` and `rate_limit`;
- uses Godot's own `FileAccess` / `DirAccess` / `ClassDB` APIs rather than string-built
  commands, removing an entire class of command-injection risks.
