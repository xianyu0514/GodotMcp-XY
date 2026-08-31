# Tools Reference

Godot MCP Native registers **232 MCP tools**: 28 core tools, 198 advanced tools and 6 always-on meta tools. The manifest in `addons/godot_mcp/native_mcp/tools_manifest.gd` is the source of truth for tier and group membership.

## Category summary

| Category | Tools | Core | Advanced | Page |
| --- | ---: | ---: | ---: | --- |
| Node | 26 | 9 | 17 | [node-tools.md](node-tools.md) |
| Script | 18 | 6 | 12 | [script-tools.md](script-tools.md) |
| Scene | 12 | 4 | 8 | [scene-tools.md](scene-tools.md) |
| Editor | 27 | 3 | 24 | [editor-tools.md](editor-tools.md) |
| Debug & Runtime | 74 | 3 | 71 | [debug-tools.md](debug-tools.md) |
| Project | 69 | 3 | 66 | [project-tools.md](project-tools.md) |
| Meta | 6 | — | — | [meta-tools.md](meta-tools.md) |
| **Total** | **232** | **28** | **198** | |

Meta tools are counted separately because they are always enabled and exist to manage the visible tool surface.

## Core vs advanced

- **Core** tools are enabled on startup and returned by `tools/list` immediately.
- **Advanced** tools are registered but disabled by default, then enabled from the MCP panel or with `enable_tools`.
- **Meta** tools (four discovery tools plus `plan_game_workflow` and `run_game_workflow`) are always available, including in minimal presets.

This keeps the initial tool list small enough for AI clients while preserving access to specialized editor/runtime capabilities.

## Discovery workflow

Progressive discovery uses a one-call fast path while retaining preview and manual controls.

1. Start with core tools and meta tools.
2. For a complete multi-phase outcome, use the persistent [Complete Game Workflow](../game-workflows.md). Its full DAG is not constrained by the one-turn discovery budget.
3. For a short goal that needs more capability, call `enable_tools` once with `workflow_query`. Local routing and activation happen together; the result contains at most 8 inspect/execute/verify names and no schemas.
4. By default the call preserves core/meta and replaces the previous task's supplementary set, keeping later prompts small and stable. Set `replace_supplementary=false` only to extend the same task.
5. Wait for `notifications/tools/list_changed` and let the client refresh the enabled schemas.
6. Use `search_tools` only to preview/compare, `get_tool_details` only when the client cannot refresh, and `list_tool_catalog(summary_only=true)` only to browse groups and the 225/225 coverage summary.

Example:

```json
{
  "name": "enable_tools",
  "arguments": {
    "workflow_query": "debug the running player and verify the fix"
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
