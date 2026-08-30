# Meta Tools

[← Tools reference](README.md)

**6 tools** — always-on meta tools.

Always-on discovery and orchestration tools. They keep the default tool list small while preserving all 225 atomic capabilities and complete multi-phase goals.

## Recommended workflow

1. For a complete game outcome, call `plan_game_workflow`, then advance it with `run_game_workflow`. The persisted DAG can use every required atomic capability; adaptive checkpoint slices yield without truncating it.
2. For a short ad-hoc task, pass the task goal directly to `enable_tools` as `workflow_query`. The server routes and activates a bounded `inspect → execute → verify` set in the same call, with no embedding/model/network request and no copied schema.
3. Workflow activation keeps core/meta tools and, by default, removes supplementary tools left by the previous task. This bounds every following `tools/list`; use `replace_supplementary=false` only when intentionally extending the same task.
4. Use `search_tools` only to preview a route or compare candidates. `mode="tools"` ranks at most 12 single capabilities; `mode="workflow"` previews at most 10 names. Exact atomic names and complete official English/Chinese descriptions route to one tool.
5. The server applies all visibility changes as one catalog revision and emits `notifications/tools/list_changed` only when something changed. Use the refreshed schemas directly; call `get_tool_details` only when the client cannot refresh.
6. Use `list_tool_catalog({"summary_only": true})` only to browse group counts and the compact `workflow_coverage` report. Reuse its `catalog_revision` as `known_revision` to avoid retransmitting an unchanged catalog.

The immutable workflow index includes every non-meta atomic tool (225/225). Tool metadata is normalized once per definition-only registry revision; enable/disable changes do not rebuild it. Canonical schema-token cost is also estimated once when each tool is registered. Selection maximizes newly covered intent terms first, then uses semantic value per incremental token for equal-coverage candidates; exact atomic names and complete descriptions always win regardless of cost. Normalized `(goal, budget)` results live in a bounded 64-entry LRU, so repeated task activation and whitespace/case variants avoid recomputation without unbounded memory growth. Eleven pre-normalized workflow seeds improve common gameplay, UI, asset, animation/audio, level, debugging, performance, QA, localization, release and project-health goals; any long-tail capability falls back to the same deterministic atomic index instead of adding another permanent workflow or model call.

Workflow-route results include `estimated_added_schema_tokens`, `estimated_full_load_schema_tokens` and `estimated_token_savings_ratio`. Costs describe supplementary definitions only because core/meta schemas are already visible. They are deterministic routing estimates, not billing measurements.

```json
{
  "name": "enable_tools",
  "arguments": {
    "workflow_query": "build a 2D player controller and verify it runs"
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

### Meta (6)

| Tool | Tier | Description |
| --- | --- | --- |
| `list_tool_catalog` | meta | Browse deterministic group summaries or filtered per-tool entries. `summary_only=true` omits tool arrays, while `known_revision` returns a minimal `not_modified` response when the catalog is unchanged. |
| `search_tools` | meta | `mode=tools` ranks exact candidates; `mode=workflow` builds a compact, cost-aware inspect/execute/verify route. Both paths are deterministic and local. Workflow results contain names plus three aggregate token-cost metrics, default to 8 tools, hard-cap at 10 and cover all 225 non-meta atomic tools through the immutable bilingual index. Unfiltered routes reuse a 64-entry LRU; filters remain isolated. |
| `get_tool_details` | meta | Return the full registration record for one MCP tool — complete description, inputSchema, outputSchema, annotations, category, group and enabled state — so a client can fetch the exact schema before calling a tool without loading every tool. Use list_tool_catalog or search_tools to discover tool names first. Returns found=false with a hint when the name is not registered. |
| `enable_tools` | meta | Fast path: `workflow_query` locally routes and activates the minimum bounded, cost-aware task set in this one call. Core/meta stay visible and old supplementary tools are replaced by default; set `replace_supplementary=false` to extend the current task. Manual tools, groups and 12 presets remain supported. Returns compact changes/counts and aggregate token-cost metrics; no-op calls do not refresh the client. |
| `plan_game_workflow` | meta | Compile, inspect, replan or cancel a durable goal contract across 12 composable production profiles. Unknown goals request clarification and missing required capabilities block instead of being omitted. |
| `run_game_workflow` | meta | Advance an adaptive blueprint-authorized slice, requesting only current-step inputs. It checkpoints async/transient work, safely recovers restartable operations, replans repeated failures and returns completed only after objective receipts pass. |
