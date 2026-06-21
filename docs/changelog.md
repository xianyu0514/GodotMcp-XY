# Changelog

This file summarises notable changes. Detailed, commit-level history lives in the Git log.
The format is loosely based on [Keep a Changelog](https://keepachangelog.com/).

## 1.0.7-pre1 (current)

- **201 MCP tools** across 6 categories (30 core, 171 advanced), classified by
  `mcp_tool_classifier.gd` with a `CORE_MAX_COUNT` of 30.
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

## 1.0.6

- Expanded advanced tool coverage and tool-management UI.
- HTTP server reliability and port-conflict handling improvements.

## 1.0.3

- Native, dependency-free MCP server inside the editor (no Node.js bridge).
- Initial core tool set for nodes, scripts, scenes, the editor, debugging, and project data.

---

For the precise contents of any release, browse the tagged commits in the repository.
