# Tools Reference

Godot MCP Native registers **221 MCP tools**: 28 core tools, 189 advanced tools and 4 always-on meta tools. The classifier in `addons/godot_mcp/native_mcp/mcp_tool_classifier.gd` is the source of truth for tier and group membership.

## Category summary

| Category | Tools | Core | Advanced | Page |
| --- | ---: | ---: | ---: | --- |
| Node | 26 | 9 | 17 | [node-tools.md](node-tools.md) |
| Script | 18 | 6 | 12 | [script-tools.md](script-tools.md) |
| Scene | 12 | 4 | 8 | [scene-tools.md](scene-tools.md) |
| Editor | 27 | 3 | 24 | [editor-tools.md](editor-tools.md) |
| Debug & Runtime | 73 | 3 | 70 | [debug-tools.md](debug-tools.md) |
| Project | 61 | 3 | 58 | [project-tools.md](project-tools.md) |
| Meta | 4 | — | — | [meta-tools.md](meta-tools.md) |
| **Total** | **221** | **28** | **189** | |

Meta tools are counted separately because they are always enabled and exist to manage the visible tool surface.

## Core vs advanced

- **Core** tools are enabled on startup and returned by `tools/list` immediately.
- **Advanced** tools are registered but disabled by default, then enabled from the MCP panel or with `enable_tools`.
- **Meta** tools (`list_tool_catalog`, `search_tools`, `get_tool_details`, `enable_tools`) are always available, including in minimal presets.

This keeps the initial tool list small enough for AI clients while preserving access to specialized editor/runtime capabilities.

## Discovery workflow

Progressive discovery mirrors the official MCP pattern: catalog → search → details → enable.

1. Start with core tools and meta tools.
2. Call `list_tool_catalog` with a `group` or `query` filter to inspect available tools, or `search_tools` with multiple keywords (AND) to pinpoint tools for a task.
3. Call `get_tool_details` for the exact schema of a specific tool before invoking it.
4. Call `enable_tools` with explicit `tools`, `groups` or a preset.
5. Wait for `notifications/tools/list_changed` and let the client refresh.
6. Disable advanced groups when the task is complete if you want to shrink the tool surface again.

Example:

```json
{
  "name": "enable_tools",
  "arguments": {
    "groups": ["Debug-Advanced"],
    "enabled": true
  }
}
```

## Category pages

Each category page lists every tool with tier and description:

- [Node Tools](node-tools.md)
- [Script Tools](script-tools.md)
- [Scene Tools](scene-tools.md)
- [Editor Tools](editor-tools.md)
- [Debug & Runtime Tools](debug-tools.md)
- [Project Tools](project-tools.md)
- [Meta Tools](meta-tools.md)

## Implementation map

| Category | Implementation file |
| --- | --- |
| Node | `addons/godot_mcp/tools/node_tools_native.gd` |
| Script | `addons/godot_mcp/tools/script_tools_native.gd` |
| Scene | `addons/godot_mcp/tools/scene_tools_native.gd` |
| Editor | `addons/godot_mcp/tools/editor_tools_native.gd` |
| Debug & Runtime | `debug_tools_native.gd`（主）+ `debug_bridge_tools.gd` / `debug_runtime_tools.gd` / `debug_verify_tools.gd` |
| Project | `project_tools_native.gd`（主）+ `project_resources_tools.gd` / `project_assets_tools.gd` / `project_tileset_tools.gd` / `project_verification_tools.gd` / `project_workflow_tools.gd` |
| Meta | `addons/godot_mcp/tools/meta_tools_native.gd` |

To add or change a tool, follow [Contributing → Adding a new MCP tool](../contributing.md#adding-a-new-mcp-tool).
