# Meta Tools

[← Tools reference](README.md)

**4 tools** — always-on meta tools.

Always-on discovery and enablement tools. They keep the default tool list small while preserving access to the full 221-tool catalog.

## Recommended workflow

1. For one capability, call `search_tools` with `mode="tools"` (the default). It ranks a maximum of 12 candidates without embeddings or another model call.
2. For a multi-step goal, call `search_tools` with `mode="workflow"`. A single local catalog scan greedily covers the intent with an `inspect → execute → verify` route. The default budget is 8 tool names and the hard maximum is 10; no tool schema is copied into the result.
3. Flatten the returned stage names into one `enable_tools` call. All visibility changes are applied atomically.
4. The server emits `notifications/tools/list_changed` only when visibility actually changed; use the refreshed `tools/list` schemas directly. Call `get_tool_details` only when comparing candidates or when the client cannot refresh.
5. Use `list_tool_catalog({"summary_only": true})` only to browse group counts and the compact `workflow_coverage` report. Reuse its `catalog_revision` as `known_revision` to avoid retransmitting an unchanged catalog.

The adaptive workflow index includes every non-meta atomic tool (217/217). Eleven small curated workflow seeds improve common gameplay, UI, asset, animation/audio, level, debugging, performance, QA, localization, release and project-health goals; any long-tail capability falls back to the same deterministic atomic index instead of adding another permanent workflow or model call.

```json
{
  "name": "search_tools",
  "arguments": {
    "query": "build a 2D player controller and verify it runs",
    "mode": "workflow",
    "workflow_tool_budget": 8
  }
}
```

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
| `search_tools` | meta | `mode=tools` ranks exact candidates; `mode=workflow` builds a compact inspect/execute/verify minimum-tool route. Both paths are deterministic and local. Workflow results contain names only, default to 8 tools, hard-cap at 10 and cover all 217 non-meta atomic tools through the adaptive fallback. |
| `get_tool_details` | meta | Return the full registration record for one MCP tool — complete description, inputSchema, outputSchema, annotations, category, group and enabled state — so a client can fetch the exact schema before calling a tool without loading every tool. Use list_tool_catalog or search_tools to discover tool names first. Returns found=false with a hint when the name is not registered. |
| `enable_tools` | meta | Apply tools, groups or one of 12 presets as one atomic visibility transition. Returns compact `changed_tools`/counts by default; use `include_enabled_tools=true` only when the complete enabled list is needed. No-op calls do not trigger a client refresh. |
