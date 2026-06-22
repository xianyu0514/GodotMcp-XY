# Tools Reference

The plugin exposes **205 MCP tools** to connected AI clients: 6 functional categories plus
a small always-on **Meta** group for tool discovery. Every tool is listed — with its tier and
description — in the category page it belongs to.

## Categories

| Category | Tools | Core | Advanced | Page |
| --- | ---: | ---: | ---: | --- |
| Node | 26 | 9 | 17 | [node-tools.md](node-tools.md) |
| Script | 17 | 7 | 10 | [script-tools.md](script-tools.md) |
| Scene | 12 | 4 | 8 | [scene-tools.md](scene-tools.md) |
| Editor | 23 | 4 | 19 | [editor-tools.md](editor-tools.md) |
| Debug & Runtime | 71 | 3 | 68 | [debug-tools.md](debug-tools.md) |
| Project | 54 | 3 | 51 | [project-tools.md](project-tools.md) |
| Meta | 2 | — | — | [meta-tools.md](meta-tools.md) |
| **Total** | **205** | **30** | **173** | |

(The 2 Meta tools are always-on and counted separately from the 30 core / 173 advanced split.)

## Core vs. advanced

Tools are classified by `addons/godot_mcp/native_mcp/mcp_tool_classifier.gd`, which is the
single source of truth for the tables above.

- **Core** — the 30 highest-value tools. They are enabled automatically and returned by
  `tools/list` as soon as the server starts. The cap is `CORE_MAX_COUNT = 30`.
- **Advanced** — the remaining 173 tools. They are registered but **disabled by default**
  (`enabled = (category == "core" or category == "meta")`), so they are hidden from
  `tools/list` until you turn them on. This keeps the default tool surface small and focused
  for the model.
- **Meta** — 2 always-on tools (`list_tool_catalog`, `enable_tools`) that are never hidden,
  not even by the `minimal_core` preset, so the model can always discover and switch on more
  capabilities on demand. See [meta-tools.md](meta-tools.md).

## Meta tools (tool discovery)

The **Meta** group is the key to keeping `tools/list` small without losing access to the full
toolset. Both tools have `category = "meta"`, are always enabled, and survive every preset.

| Tool | What it does |
| --- | --- |
| `list_tool_catalog` | Lists registered tools grouped by category, with a one-line description and each tool's enabled state — **without** loading every full schema. Filter by `group` or `query`, or pass `enabled_only` / `include_descriptions` to shrink the response. |
| `enable_tools` | Enables/disables tools on demand. Pass `tools` and/or `groups` (with `enabled`, and optional `exclusive` to reset to a core-only baseline first), or `preset` to apply a curated profile wholesale. Emits `notifications/tools/list_changed` so the client refreshes its tool list. Core and meta tools always stay enabled. |

**Lazy-loading workflow:** start from `minimal_core` (≈32 visible tools) → call
`list_tool_catalog({group: "Debug-Advanced"})` to discover what's available →
`enable_tools({groups: ["Debug-Advanced"]})` (or `enable_tools({preset: "debugging"})`) to
switch them on. This keeps the steady-state context to just the core tools plus the catalog
tool, minimising token/compute cost. See also the
[task → preset guide](../configuration.md#tool-presets).

**Delivered automatically on connect.** The server returns this workflow in the MCP
`initialize` response's `instructions` field, so compatible clients inject it into the model's
system context the moment it connects — no manual prompt or rule file needed. (Clients that
ignore `instructions` simply don't get the hint; the tools still work the same way.)

### Enabling advanced tools

- **In the editor:** open the **MCP** dock panel, expand a tool group, and toggle the tools
  you want. Selections are grouped so you can enable a whole group at once.
- **In tests / scripts:** call `core.set_tool_enabled("tool_name", true)` on the server core.

## Naming

Tool names use `snake_case` (for example `create_node`, `get_runtime_scene_tree`). Some
clients surface a kebab-case alias in their UI; the wire protocol always uses the
`snake_case` name shown in these tables.

## How tools are organised internally

Each category maps to one implementation file under `addons/godot_mcp/tools/`:

| Category | Implementation file |
| --- | --- |
| Node | `node_tools_native.gd` |
| Script | `script_tools_native.gd` |
| Scene | `scene_tools_native.gd` |
| Editor | `editor_tools_native.gd` |
| Debug & Runtime | `debug_tools_native.gd` |
| Meta | `meta_tools_native.gd` |
| Project | `project_tools_native.gd` |

To add a new tool, follow [Contributing → Adding a tool](../contributing.md#adding-a-new-tool).
