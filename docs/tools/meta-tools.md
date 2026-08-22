# Meta Tools

[← Tools reference](README.md)

**4 tools** — always-on meta tools.

Always-on discovery and enablement tools. They keep the default tool list small while preserving access to the full 224-tool catalog.

## Recommended workflow

1. Call `list_tool_catalog` to discover tools without loading every schema; each entry includes the MCP annotation flags (`readOnlyHint`, `destructiveHint`, `idempotentHint`, `openWorldHint`).
2. Call `search_tools` with keywords (AND) or a group filter to pinpoint tools for a task.
3. Call `get_tool_details` for the exact schema of a specific tool before invoking it.
4. Call `enable_tools` with a group, explicit tool list or preset.
5. After enablement, the server emits `notifications/tools/list_changed` so clients refresh their visible tools.

## Tool list

### Meta (4)

| Tool | Tier | Description |
| --- | --- | --- |
| `list_tool_catalog` | meta | List the registered MCP tools grouped by category, with a one-line description, whether each is currently enabled (visible in tools/list), and the readOnlyHint/destructiveHint/idempotentHint/openWorldHint flags from each tool's MCP annotations. Use this to discover capabilities without loading every full tool schema, then call enable_tools to switch on just what you need. Filter by group/query to keep the response small. |
| `search_tools` | meta | Search the registered MCP tool catalog by keywords and/or group, returning each matching tool's name, group, category, enabled state, a one-line description, and the readOnlyHint/destructiveHint/idempotentHint/openWorldHint flags from its MCP annotations. More focused than list_tool_catalog: supports multiple space-separated keywords with AND semantics (every keyword must appear in the tool name or description, case-insensitive). Use it to pinpoint the right tools for a task, then call get_tool_details for the exact schema or enable_tools to activate them. |
| `get_tool_details` | meta | Return the full registration record for one MCP tool — complete description, inputSchema, outputSchema, annotations, category, group and enabled state — so a client can fetch the exact schema before calling a tool without loading every tool. Use list_tool_catalog or search_tools to discover tool names first. Returns found=false with a hint when the name is not registered. |
| `enable_tools` | meta | Enable or disable MCP tools on demand so only the tools you need are visible in tools/list (saving context/compute). Pass 'tools' and/or 'groups' to toggle specific items, or 'preset' to apply a curated profile wholesale. Emits notifications/tools/list_changed so the client refreshes its tool list. Core and meta tools always stay enabled. |
