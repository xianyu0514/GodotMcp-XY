# Tools Reference

Godot MCP Native registers **214 MCP tools**: 30 core tools, 182 advanced tools and 2 always-on meta tools. The classifier in `addons/godot_mcp/native_mcp/mcp_tool_classifier.gd` is the source of truth for tier and group membership.

## Category summary

| Category | Tools | Core | Advanced | Page |
| --- | ---: | ---: | ---: | --- |
| Node | 26 | 9 | 17 | [node-tools.md](node-tools.md) |
| Script | 17 | 7 | 10 | [script-tools.md](script-tools.md) |
| Scene | 12 | 4 | 8 | [scene-tools.md](scene-tools.md) |
| Editor | 24 | 4 | 20 | [editor-tools.md](editor-tools.md) |
| Debug & Runtime | 73 | 3 | 70 | [debug-tools.md](debug-tools.md) |
| Project | 60 | 3 | 57 | [project-tools.md](project-tools.md) |
| Meta | 2 | — | — | [meta-tools.md](meta-tools.md) |
| **Total** | **214** | **30** | **182** | |

Meta tools are counted separately because they are always enabled and exist to manage the visible tool surface.

## Core vs advanced

- **Core** tools are enabled on startup and returned by `tools/list` immediately.
- **Advanced** tools are registered but disabled by default, then enabled from the MCP panel or with `enable_tools`.
- **Meta** tools (`list_tool_catalog`, `enable_tools`) are always available, including in minimal presets.

This keeps the initial tool list small enough for AI clients while preserving access to specialized editor/runtime capabilities.

## Discovery workflow

1. Start with core tools and meta tools.
2. Call `list_tool_catalog` with a `group` or `query` filter to inspect available tools.
3. Call `enable_tools` with explicit `tools`, `groups` or a preset.
4. Wait for `notifications/tools/list_changed` and let the client refresh.
5. Disable advanced groups when the task is complete if you want to shrink the tool surface again.

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
| Debug & Runtime | `addons/godot_mcp/tools/debug_tools_native.gd` |
| Project | `addons/godot_mcp/tools/project_tools_native.gd` |
| Meta | `addons/godot_mcp/tools/meta_tools_native.gd` |

To add or change a tool, follow [Contributing → Adding a new MCP tool](../contributing.md#adding-a-new-mcp-tool).
