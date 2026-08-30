# Godot MCP Native Addon

This directory is the distributable Godot addon. Copy `addons/godot_mcp` into any Godot 4.7 project to run an MCP server inside the editor.

## What ships here

- `plugin.cfg` and `mcp_server_native.gd` — the editor plugin entry point.
- `native_mcp/` — JSON-RPC/MCP core, HTTP/SSE and stdio transports, auth, settings, tunnel support and tool-state management.
- `tools/` — the 231 registered MCP tools.
- `runtime/mcp_runtime_probe.gd` — optional autoload used to inspect and drive a running game.
- `ui/` — the MCP dock panel, tool manager and detail views.
- `translations/` — panel text and tool descriptions.

The Tool Manager offers task-focused 2D, 3D, UI, asset/animation, debug/test and release views, plus 12 practical presets with purpose and tool-count previews. These views filter and toggle only their curated tools while preserving the existing core/extended tiers and groups.

## Quick start

1. Copy this folder to `res://addons/godot_mcp` in your project.
2. Enable **Godot MCP Native** in **Project → Project Settings → Plugins**.
3. Open the **MCP** dock and click **Start Server**.
4. Connect an MCP client to `http://localhost:9080/mcp`.

```json
{
  "mcpServers": {
    "godot-mcp": {
      "url": "http://localhost:9080/mcp"
    }
  }
}
```

## Tool model

The addon registers 231 tools:

- 28 core tools enabled by default.
- 197 advanced tools registered but disabled until enabled from the panel or `enable_tools`.
- 6 always-on meta tools: four discovery tools plus `plan_game_workflow` and `run_game_workflow`.

Complete goals use the two workflow tools to compile 12 reusable production profiles into a durable DAG. The DAG can exceed ten atomic capabilities while each runner round stays capped at four calls; hidden tools execute without visibility churn, and completion requires objective receipts. Short tasks continue to use `enable_tools` with the unchanged 8-tool default/10-tool hard discovery budget.

Discovery is progressive and cache-friendly: one `enable_tools` call with `workflow_query` locally routes an English/Chinese goal and atomically activates a bounded inspect/execute/verify set. An immutable normalized index covers all 225 non-meta atomic tools by exact name and official English/Chinese description, returns names without schemas and defaults to an 8-tool budget. Precomputed name signatures plus direct action/object evidence improve natural-task precision before the token-cost fallback; the 48-task bilingual production gate records 100% Recall@8 and complete-task success with 97.34% average supplementary-schema savings. Schema-token costs are estimated once per definition; equal-coverage candidates are chosen by semantic value per incremental token, while exact atomic requests retain strict priority. A 64-entry LRU reuses normalized goals; visibility changes preserve its definition revision, index and routes. The activation path preserves core/meta and replaces old supplementary task tools by default, while `replace_supplementary=false` adds tools incrementally. Catalog revisions and dependency-tagged result revisions avoid flushing unrelated scene/script/resource reads; exact script and resource paths expire lazily.

Large successful results keep a compatible preview and expose their exact JSON through a standard content-addressed `resource_link`. `resources/read` returns UTF-8-safe 16 KiB pages with `_meta.nextUri`; errors and source/log readers remain complete inline, and spill failure never replaces a complete result.

Stable high-volume list and scan tools use one lossless `limit`/`offset` contract and reuse a revision-safe full-scan snapshot across pages. Snapshots have independent 8-entry and 4 MiB-per-entry gates; stateful mutations are never re-executed merely to fetch another page.

See the project-level [Tools Reference](../../docs/tools/README.md).

## Configuration

Settings are edited from the MCP dock and stored in `user://mcp_settings.cfg`. Common settings are `transport_mode`, `http_port`, `auth_enabled`, `auth_token`, `auto_start`, `security_level`, `rate_limit` and `sse_enabled`.

Headless startup:

```bash
godot --editor --path /path/to/project -- --mcp-server --mcp-port=9080
```

## Documentation

Start with the repository [README](../../README.md), [Getting Started](../../docs/getting-started.md), [Configuration](../../docs/configuration.md) and [Tools Reference](../../docs/tools/README.md).

## License

MIT. See [LICENSE](../../LICENSE).
