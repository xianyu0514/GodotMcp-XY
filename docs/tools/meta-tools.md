# Meta Tools

[← Tools reference](README.md)

**4 tools** — always-on meta tools.

Always-on discovery and enablement tools. They keep the default tool list small while preserving access to the full 221-tool catalog.

## Recommended workflow

1. Call `search_tools` with a short English or Chinese task intent. It ranks a maximum of 12 candidates by default without embeddings or another model call.
2. Call `enable_tools` with the smallest explicit result-name list, group or focused preset. All changes in one request are applied atomically.
3. The server emits `notifications/tools/list_changed` only when visibility actually changed; use the refreshed `tools/list` schema directly. Call `get_tool_details` only when comparing candidates or when the client cannot refresh.
4. Use `list_tool_catalog({"summary_only": true})` only to browse group counts. Reuse its `catalog_revision` as `known_revision` to avoid retransmitting an unchanged catalog.

For OpenAI Responses API clients, combine the built-in `tool_search` tool with the Godot MCP server configured with `defer_loading: true`. The model initially receives only the server label/instructions and loads deferred definitions on demand. Keep the server label and description specific (for example `godot_editor`) so tool search routes game-development requests correctly.

Tool-state changes invalidate only the three discovery cache entries. Cached scene/project reads remain hot; project-mutating tools still invalidate the complete result cache.

## Design references

- [OpenAI tool search](https://developers.openai.com/api/docs/guides/tools-tool-search/) and [connectors/MCP](https://developers.openai.com/api/docs/guides/tools-connectors-mcp/) — deferred loading and namespace quality.
- [OpenAI Codex tool-search handler](https://github.com/openai/codex/blob/main/codex-rs/core/src/tools/handlers/tool_search.rs) — deterministic local ranking and stable catalog indexing.
- [DeepSeek Harness tool execution pipeline](https://github.com/deepseek-ai/deepseek-harness/blob/master/docs/tool-execution-pipeline.zh.md) and [MCP client](https://github.com/deepseek-ai/deepseek-harness/blob/master/packages/mcp/mcp-client/README.zh.md) — plugin seams, stable-generation swaps and cache-friendly execution.

## Tool list

### Meta (4)

| Tool | Tier | Description |
| --- | --- | --- |
| `list_tool_catalog` | meta | Browse deterministic group summaries or filtered per-tool entries. `summary_only=true` omits tool arrays, while `known_revision` returns a minimal `not_modified` response when the catalog is unchanged. |
| `search_tools` | meta | Rank tools from short English or Chinese task intent using a deterministic local lexical scorer. Common Godot terms are expanded without embeddings; the default result limit is 12 and the hard maximum is 50. |
| `get_tool_details` | meta | Return the full registration record for one MCP tool — complete description, inputSchema, outputSchema, annotations, category, group and enabled state — so a client can fetch the exact schema before calling a tool without loading every tool. Use list_tool_catalog or search_tools to discover tool names first. Returns found=false with a hint when the name is not registered. |
| `enable_tools` | meta | Apply tools, groups or one of 12 presets as one atomic visibility transition. Returns compact `changed_tools`/counts by default; use `include_enabled_tools=true` only when the complete enabled list is needed. No-op calls do not trigger a client refresh. |
