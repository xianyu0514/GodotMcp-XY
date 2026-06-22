# Tools Reference

The plugin exposes **202 MCP tools** to connected AI clients, split into 6 categories.
Every tool is listed — with its tier and description — in the category page it belongs to.

## Categories

| Category | Tools | Core | Advanced | Page |
| --- | ---: | ---: | ---: | --- |
| Node | 26 | 9 | 17 | [node-tools.md](node-tools.md) |
| Script | 17 | 7 | 10 | [script-tools.md](script-tools.md) |
| Scene | 12 | 4 | 8 | [scene-tools.md](scene-tools.md) |
| Editor | 23 | 4 | 19 | [editor-tools.md](editor-tools.md) |
| Debug & Runtime | 71 | 3 | 68 | [debug-tools.md](debug-tools.md) |
| Project | 53 | 3 | 50 | [project-tools.md](project-tools.md) |
| **Total** | **202** | **30** | **172** | |

## Core vs. advanced

Tools are classified by `addons/godot_mcp/native_mcp/mcp_tool_classifier.gd`, which is the
single source of truth for the tables above.

- **Core** — the 30 highest-value tools. They are enabled automatically and returned by
  `tools/list` as soon as the server starts. The cap is `CORE_MAX_COUNT = 30`.
- **Advanced** — the remaining 172 tools. They are registered but **disabled by default**
  (`enabled = (category == "core")`), so they are hidden from `tools/list` until you turn
  them on. This keeps the default tool surface small and focused for the model.

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
| Project | `project_tools_native.gd` |

To add a new tool, follow [Contributing → Adding a tool](../contributing.md#adding-a-new-tool).
