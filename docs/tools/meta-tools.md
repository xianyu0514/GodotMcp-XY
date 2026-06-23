# Meta Tools

[← Tools reference](README.md)

**2 tools** — always-on meta tools.

Always-on discovery and enablement tools. They keep the default tool list small while preserving access to the full 214-tool catalog.

## Recommended workflow

1. Call `list_tool_catalog` to discover tools without loading every schema.
2. Call `enable_tools` with a group, explicit tool list or preset.
3. After enablement, the server emits `notifications/tools/list_changed` so clients refresh their visible tools.

## Tool list

### Meta (2)

| Tool | Tier | Description |
| --- | --- | --- |
| `list_tool_catalog` | meta | List the registered MCP tools grouped by category, with a one-line description and whether each is currently enabled (visible in tools/list). Use this to discover capabilities without loading every full tool schema, then call enable_tools to switch on just what you need. Filter by group/query to keep the response small. |
| `enable_tools` | meta | Enable or disable MCP tools on demand so only the tools you need are visible in tools/list (saving context/compute). Pass 'tools' and/or 'groups' to toggle specific items, or 'preset' to apply a curated profile wholesale. Emits notifications/tools/list_changed so the client refreshes its tool list. Core and meta tools always stay enabled. |
