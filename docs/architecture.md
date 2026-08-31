# Architecture

Godot MCP Native is a Godot editor plugin that embeds an MCP server in the editor process. The server exposes editor, project and runtime capabilities through JSON-RPC/MCP tools while using Godot APIs as the execution boundary.

## High-level view

```text
MCP client
  │ HTTP/SSE or stdio
  ▼
Transport layer
  │ JSON-RPC messages
  ▼
MCP server core
  ├─ tool registry and classification
  ├─ auth, rate limit and security checks
  ├─ resources/prompts support
  └─ notifications
      │
      ▼
Tool modules ── Godot EditorInterface / ProjectSettings / ResourceLoader
      │
      └─ Runtime probe autoload for running-game inspection and control
```

## Plugin lifecycle

1. Godot loads `addons/godot_mcp/plugin.cfg`.
2. `mcp_server_native.gd` is instantiated as an `EditorPlugin`.
3. Settings are loaded from `user://mcp_settings.cfg`.
4. Tool modules, resources and UI are registered.
5. The server starts when the user clicks **Start Server**, when `auto_start` is true, or when Godot launches with `--mcp-server`.
6. Connected clients call MCP tools through HTTP/SSE or stdio.

## Core components

| Component | Responsibility |
| --- | --- |
| `mcp_server_native.gd` | EditorPlugin entry point, settings wiring, panel registration and server lifecycle. |
| `native_mcp/mcp_server_core.gd` | JSON-RPC/MCP method handling, tool registry, notifications, result caching and lossless large-result resources. |
| `native_mcp/cache_revision_index.gd` | Dependency-tagged result-cache revisions and mutation impact routing; enables O(1) lazy invalidation instead of whole-cache flushes. |
| `native_mcp/cache_change_tracker.gd` | Per-frame editor event coalescing and filesystem path-set diffs for precise external-change invalidation. |
| `native_mcp/game_workflow_engine.gd` | Pure deterministic compiler, blueprint integrity checker, evidence evaluator and bounded-repair state machine for complete goals. |
| `native_mcp/mcp_http_server.gd` | HTTP endpoint and SSE transport. |
| `native_mcp/mcp_stdio_server.gd` | stdio transport for clients that spawn the server process. |
| `native_mcp/mcp_types.gd` | Protocol constants and shared data structures. |
| `native_mcp/tools_manifest.gd` | Single source of truth for tool tier (`core`, `supplementary`, `meta`) and group membership — one entry per tool (`{name: {category, group}}`), consumed by the classifier and enforced by consistency tests. |
| `native_mcp/mcp_tool_classifier.gd` | Tool classification lookup API (`get_tool_category` / `get_tool_group` / `is_core_tool` …), generated at init from `MCPToolsManifest.TOOLS`. |
| `native_mcp/mcp_auth_manager.gd` | Bearer-token validation. |
| `native_mcp/settings_manager.gd` | Persistent user settings. |
| `native_mcp/tool_state_manager.gd` | Per-tool enable/disable state. |
| `native_mcp/mcp_tunnel_manager.gd` | Project-scoped Cloudflare Quick Tunnel session persistence, supervisor/child PID identity validation and automatic restore across plugin/editor restarts. |
| `native_mcp/mcp_tunnel_supervisor.gd` | Independent headless pipe owner: captures cloudflared stdout/stderr into the durable log, retries bounded failed or stalled pre-URL attempts, and survives the editor until explicit stop or computer shutdown. |
| `native_mcp/mcp_cloudflared_provider.gd` | Download/verification helper for `cloudflared`. |

## Tool modules

Each category is implemented in one or more files under `addons/godot_mcp/tools/`. The
Project category was split from the 9393-line `project_tools_native.gd` into one main
module (shared helpers + project-info/config/input/autoload/class-metadata/test-runner
tools) plus five domain modules (resources, assets, tileset, verification, workflow).
The Debug category was split the same way: the 4480-line `debug_tools_native.gd` keeps
the main class (shared static helpers + logs/misc + script execution) and the bridge,
runtime-probe and verify domains moved into three dedicated modules:

| File | Category | Tools |
| --- | --- | ---: |
| `node_tools_native.gd` | Node | 26 |
| `script_tools_native.gd` | Script | 18 |
| `scene_tools_native.gd` | Scene | 12 |
| `editor_tools_native.gd` | Editor | 27 |
| `debug_tools_native.gd` | Debug (main: logs/misc + shared static helpers) | 6 |
| `debug_bridge_tools.gd` | Debug (bridge + execution control) | 28 |
| `debug_runtime_tools.gd` | Debug (runtime probe) | 38 |
| `debug_verify_tools.gd` | Debug (verify gates: play_and_verify/perf budget/runtime errors) | 3 |
| `project_tools_native.gd` | Project (main: info/config/input/autoload/class metadata/tests) | 16 |
| `project_resources_tools.gd` | Project (resources: create/read/update/deps/migration/UID) | 21 |
| `project_assets_tools.gd` | Project (assets: generate/3D/slice/glTF/gradient/drawable/PCK/render) | 9 |
| `project_tileset_tools.gd` | Project (TileSet: create/layers/collision/terrain/inspect) | 5 |
| `project_verification_tools.gd` | Project (verification: visual baseline/screenshot diff) | 2 |
| `project_workflow_tools.gd` | Project (workflow: bump_version/theme/animation/task plan/localization) | 8 |
| `meta_tools_native.gd` | Meta | 4 |
| `game_workflow_tools.gd` | Meta (durable plan/run orchestration) | 2 |

Tool registration uses `server_core.register_tool(...)` with name, description, input schema, callable, output schema, annotations, category and group. The category/group come from the single manifest (`native_mcp/tools_manifest.gd`), which the classifier reads to answer whether a tool is core, advanced or meta. `test_mcp_tool_classifier.gd` enforces that the manifest, the classifier and the runtime registry never drift (tool-name sets and per-tool category/group must match).

## Core, advanced and meta tiers

- **Core:** 28 high-value tools enabled by default.
- **Advanced:** 197 tools registered but hidden from `tools/list` until enabled.
- **Meta:** 6 always-on tools: four discovery tools plus `plan_game_workflow` and `run_game_workflow`.

This design keeps the default client context small without making specialized capabilities unavailable.

`native_mcp/workflow_router.gd` is a pure-logic discovery layer shared by `enable_tools(workflow_query=...)` and `search_tools(mode="workflow")`. It does not register another MCP tool or duplicate schemas. It builds one immutable, normalized capability index per definition-only registry revision; name, group, official English description and Chinese translation are normalized once instead of once per route. Canonical names and complete bilingual descriptions also feed an O(1) exact-intent map, avoiding a catalog scan on single-tool requests. MCPServerCore estimates each canonical `tools/list` definition once at registration with the same deterministic DSH-inspired estimator used by the schema budget gate. Core definitions have zero incremental activation cost because they are already visible; supplementary definitions retain their estimated token cost in the immutable index.

Eleven pre-normalized game-development seeds plus an adaptive fallback greedily cover intent terms and emit only a bounded list of names grouped into inspect/execute/verify stages. The immutable index precomputes normalized atomic-name signatures, per-segment frequency weights and schema costs. At route time, light bilingual concept expansion and plural normalization prefer signatures supported by explicit action/object evidence; related read actions (`inspect`/`get`/`list`/`find`/`scan`) share intent without allowing an unrelated partial object match. Verifiers for the same object family are deduplicated, and weak description/group-only fallback candidates stop below the confidence floor. The fallback ranks newly covered semantic evidence first, then coverage, semantic value per incremental schema token (using integer cross multiplication), lower cost and lexical name for byte-stable ties.

Exact names and complete official English/Chinese descriptions keep strict priority regardless of cost, which makes all 226 atomic capabilities directly routable while the default workflow payload remains capped at 8 names (hard maximum 10). Every route exposes supplementary schema tokens added, full-load supplementary tokens and the normalized savings ratio. A deterministic regression corpus protects usefulness rather than tool-count reduction alone: 48 balanced English/Chinese tasks across 12 production domains contain 174 required atomic-tool groups plus representative forbidden cross-domain distractors. The current gate records 100% Recall@8, 100% complete-task success, 97.30% verification-stage recall, zero known distractors and 97.34% average schema-token savings. Uncached local routing is separately gated at P95 below 5 ms.

Normalized `(goal, budget)` keys feed a separate 64-entry LRU of deep-copied route results. MCPServerCore advances the definition revision only when a tool is registered or unregistered; enabling and disabling tools advances the client-facing catalog revision but intentionally preserves the semantic index and route cache. This split keeps task switching deterministic, makes equivalent whitespace/case variants share a route, and avoids repeated catalog normalization or routing work during long editor sessions. Filtered workflow previews use a short-lived local index so they cannot contaminate the complete-catalog cache.

The direct `enable_tools` path routes and applies the result in one MCP call. Its default task-switch behavior preserves core/meta, disables only currently enabled supplementary tools outside the new route, and enables the selected route through one `apply_tool_states` batch. This produces at most one catalog revision and one `tools/list_changed` notification, avoids rebuilding state once per tool, and keeps the visible schema set stable for subsequent prompt-cache hits. `replace_supplementary=false` provides an explicit additive mode.

## Complete-game workflow execution

`native_mcp/game_workflow_engine.gd` composes 12 reusable production profiles into a durable, goal-dependent DAG. This is deliberately separate from `workflow_router.gd`: the router minimizes the schemas visible for one ad-hoc turn, while the workflow engine preserves every step needed by a multi-phase outcome. A DAG can exceed ten tools; `run_game_workflow` chooses adaptive 4/8/16/32-call checkpoint slices, and an explicit positive `max_steps` affects only one call. A slice yields resumably and never removes pending goal work.

The stored goal contract is the single source of truth. Before every round, the engine recompiles the blueprint and compares its exact tools, arguments, order, dependencies, repair declarations, objective gates and SHA-256 identity. Stale workflow IDs use compare-and-swap protection. A persisted in-progress mutation is not replayed after interruption; the caller receives `recovery_required` and must inspect/replan.

`MCPServerCore.invoke_planned_tool()` is an internal-only dispatch path. It authorizes exactly one blueprint tool, rejects discovery/control recursion, validates the normal input schema, and executes hidden atomic tools without changing tool visibility. Read steps reuse the same revision-aware cache; write steps advance the same precise dependency revisions as ordinary calls. This prevents a long workflow from rebuilding `tools/list` or exposing all 226 atomic schemas.

Completion is fail-closed. Pending jobs remain pending without consuming a repair attempt; failed verification may invoke only the blueprint's declared repair tool and is bounded to two attempts by default (three maximum). A goal reaches `completed` only when every task is done and every objective gate references a compact engine-issued passing receipt. Protected roots, path normalization, receipt limits and polling limits keep the durable state bounded. See [Complete Game Workflows](game-workflows.md).

## Result cache and revisions

Expensive deterministic reads use an in-memory LRU bounded by both 64 entries and 32 MiB of serialized raw-result bytes, with canonical argument keys, preformatted MCP payloads, single-flight deduplication and a 60-second out-of-band edit backstop. Byte-pressure and count-pressure share the same recency order; a value larger than the total byte budget is returned normally but not retained. `cache_revision_index.gd` assigns each cached read a compact dependency snapshot (scene content, file catalogs, project settings, import state, tool catalog, or exact script/resource paths).

Mutating tools advance only the revisions they can affect. The write path therefore touches a bounded number of integers and never scans or clears the LRU. Stale entries are removed lazily when their key is requested, while unrelated entries stay hot. Script and resource reads are path-scoped; runtime-only debugger writes preserve all editor/project entries. Unknown or plugin-defined writers fail safe by advancing the global revision. This increases hit rate without weakening correctness, and the existing TTL still bounds changes made outside MCP.

Changes made outside MCP use the same revision graph instead of waiting for that TTL. The EditorPlugin subscribes to Godot 4.7 `EditorFileSystem` reload, reimport, source, script-class and generic filesystem signals; its own resource/scene save signals; and `ProjectSettings.settings_changed`. `cache_change_tracker.gd` coalesces bursts into one deferred batch per process frame and takes at most one recursive filesystem snapshot for that batch. Path-bearing events map to exact `script:<path>` and `resource:<path>` dependencies. The symmetric difference between the previous and current path sets marks additions, deletions and renames so only the affected script, scene, resource and project catalogs advance.

Correctness stays fail-safe: if a generic filesystem event has neither a path-bearing companion nor a structural path diff, every file-backed dependency domain advances while immutable tool discovery and runtime-only state remain hot. The 60-second TTL remains the final out-of-band safety backstop until every editor/platform event source is proven complete. Internal diagnostics record coalesced event batches, precise path count, bounded fallback count and the active TTL without adding an MCP tool or schema.

Stable directory and source scans add a view-independent snapshot layer inside the same revision-aware LRU. The key excludes presentation-only `limit` and `offset`, so all pages of an identical query reuse one sorted full scan and only slice the requested view; extension filters are case-normalized, deduplicated and sorted so equivalent queries share a key. Each page returns `offset`, effective `limit`, `returned_count`, `total_count`, `has_more` and, when applicable, `next_offset`. Snapshot retention is independently capped at 8 entries and 4 MiB per entry; oversized scans still return complete page results but are not retained. Stateful mutation output such as `apply_migration_fixes` deliberately stays outside this paging model because re-executing a writer could make later pages observe different project state; its large responses remain recoverable through the lossless result resource path below.

Successful JSON payloads above 50,000 UTF-8 bytes use lossless late materialization. The normal tool result retains the existing head/tail preview and appends an MCP [`resource_link`](https://modelcontextprotocol.io/specification/2025-11-25/schema#resourcelink) whose `godot-mcp://result/<sha256>` URI addresses the immutable spill file. A client retrieves it through standard [`resources/read`](https://modelcontextprotocol.io/specification/2025-11-25/server/resources#reading-resources); each response contains at most 16 KiB, ends on a UTF-8 code-point boundary and advertises the exact next URI in `_meta.nextUri`. Concatenating pages yields the byte-identical JSON and the advertised SHA-256 provides an end-to-end integrity check.

This path adds no MCP tool, no tool schema and no `resources/list` entry, so it does not enlarge the persistent model prefix or churn discovery caches. Content addressing reuses an existing verified spill file for identical results. Actionable errors and source/log readers remain complete inline, and hashing, directory or write failures return the complete inline result instead of sacrificing functionality. The regression gate uses a 204,211-byte multilingual payload: its initial MCP result is 8,951 bytes (95.62% avoided), while 13 bounded reads reconstruct the exact original.

### Cache diagnostics and session gate

`MCPServerCore.get_cache_diagnostics()` and `WorkflowRouter.get_diagnostics()` are internal test/diagnostic surfaces, not MCP tools. They expose common request, hit/reuse, handler-execution, eviction and capacity metrics for the result LRU, `tools/list`, scan snapshots, workflow routes and spill files. Sequential cache hits and single-flight twin serves remain individually visible, while the aggregate result `reuse_rate` counts both as avoided handler executions.

The deterministic fixture in `test/unit/fixtures/cache_session_trace.json` replays one representative `inspect → edit → run → debug → verify` task. It primes scene, script and project reads; performs a path-scoped script mutation; proves unrelated scene/project entries stay hot while the modified script is recomputed; reuses one resource scan across five pages; and repeats normalized routes, tool-list requests and a content-addressed spill. CI prints the measured rates and fails if any layer falls below its checked baseline. This adds no network, model call, runtime monitor, tool or schema.

## Runtime probe

`runtime/mcp_runtime_probe.gd` is an Autoload used by runtime tools. It lets the MCP server inspect and drive a running game without relying solely on edit-time state.

Runtime probe capabilities include:

- Live scene tree inspection.
- Runtime node property updates and method calls.
- Expression/condition evaluation.
- Input action and event simulation.
- Animation, AnimationTree, material, shader, theme, TileMap and audio-bus control.
- Screenshot, performance and memory snapshots.
- Deterministic play verification workflows.

## UI

The MCP dock is implemented under `addons/godot_mcp/ui/`.

| UI file | Role |
| --- | --- |
| `mcp_panel_native.tscn` / `mcp_panel_native.gd` | Main dock: start/stop, settings, tunnel controls, logs and tool management. |
| `mcp_tool_item.gd` | Individual tool row/toggle. |
| `mcp_tool_group_item.gd` | Group-level expand/collapse and enablement. |
| `mcp_tool_detail_panel.gd` | Tool details and schema display. |
| `mcp_category_nav_item.gd` | Category navigation. |

## Utilities

| Utility | Purpose |
| --- | --- |
| `utils/path_validator.gd` | Validate project/user paths before file operations. |
| `utils/payload_utils.gd` | Normalize/validate tool payloads. |
| `utils/vibe_coding_policy.gd` | Guardrails for editor focus/window behavior. |
| `utils/async_job_runner.gd` | Background job orchestration for long-running work. |

## Security model

Security is layered rather than delegated to a shell:

1. **Transport boundary:** HTTP/SSE stays on localhost by default; stdio is process-local.
2. **Authentication:** optional Bearer-token auth for HTTP clients.
3. **Rate limiting:** request throttling protects the editor from accidental floods.
4. **Path validation:** file/resource tools validate project-relative and user paths.
5. **Tool tiering:** advanced tools are disabled until explicitly enabled.
6. **Godot API execution:** tools use editor/runtime APIs instead of arbitrary OS command execution.

When exposing the server beyond localhost, enable auth and use the strict security level.
