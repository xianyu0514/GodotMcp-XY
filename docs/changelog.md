# Changelog

This file summarises notable changes. Detailed, commit-level history lives in the Git log.
The format is loosely based on [Keep a Changelog](https://keepachangelog.com/).

## 1.0.7-pre1 (current)

- **206 MCP tools** across 6 categories (30 core, 174 advanced) plus 2 always-on **meta**
  tools (`list_tool_catalog`, `enable_tools`) for on-demand tool discovery, classified by
  `mcp_tool_classifier.gd` with a `CORE_MAX_COUNT` of 30. The MCP `initialize` response
  carries an `instructions` field describing the lazy-loading workflow, so compatible clients
  auto-inject it without any manual prompt setup.
- Dual transport: **HTTP/SSE** (default, port `9080`) and **stdio**.
- **Runtime probe** autoload for inspecting and driving a running game (scene tree, node
  inspection/mutation, expression evaluation, input injection, animation/audio/shader/theme
  /tilemap control).
- HTTP **Bearer-token authentication**, configurable `security_level` and `rate_limit`.
- **MCP dock panel** with start/stop, transport configuration, log viewer, per-tool and
  per-group enable/disable, and localisation.
- Headless `--mcp-server` launch that honours `user://mcp_settings.cfg`, with
  `--mcp-port` / `--mcp-transport` command-line overrides for parallel instances.
- Godot 4.7-aware tools (editor buffer sync, migration scanning/fixes, Control offset
  transform, drawable textures, conic gradients, TileSet layer configuration).
- **Client config generator** — *Copy Config* menu in the panel emits ready-to-paste HTTP
  or stdio client configuration with the current port and auth token pre-filled.
- **Server self-check** — one-click HTTP reachability probe from the status bar.
- **Tool presets** — one-click enable/disable of curated tool collections (Minimal,
  Level Design, Debugging, QA Automation, Art & Resources, All), with JSON export/import
  for sharing a configuration across a team.
- **Remote / cloud access** — a Settings card turns a public tunnel URL (e.g. Cloudflare)
  into ready-to-paste remote client configs, including an `mcp-remote` bridge config for
  stdio-only clients (Claude Desktop) and a one-click `cloudflared` tunnel command. See
  [Remote & Cloud Access](remote-access.md).
- **Built-in one-click Cloudflare tunnel** — *Start free tunnel* in the Remote / Cloud
  access card auto-downloads the official, version-pinned `cloudflared` (SHA-256 verified,
  cached under `user://`), launches a Quick Tunnel, and auto-fills the detected public URL —
  no manual install or command. An optional path field reuses a self-managed binary.
- **Fix:** the generated stdio config now includes `--editor`, which the `EditorPlugin`
  requires to start in headless mode (the previous snippet never launched the server).
- **`manage_task_plan`** — a durable task graph + Definition-of-Done store (backed by
  `TaskPlanStore`) that persists the plan → execute → run → verify → fix loop to versioned
  JSON (default `res://.mcp/task_plan.json`), so an AI can resume a build across sessions.
  Supports init/add_task/update_task/set_status/set_dod/get/next/remove_task with dependency
  and cycle validation, a DoD gate on marking tasks done, and next-actionable + progress
  queries.

## 1.0.6

- Expanded advanced tool coverage and tool-management UI.
- HTTP server reliability and port-conflict handling improvements.

## 1.0.3

- Native, dependency-free MCP server inside the editor (no Node.js bridge).
- Initial core tool set for nodes, scripts, scenes, the editor, debugging, and project data.

---

For the precise contents of any release, browse the tagged commits in the repository.
