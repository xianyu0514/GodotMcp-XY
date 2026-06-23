# Changelog

This file summarises notable changes. Detailed, commit-level history lives in the Git log.
The format is loosely based on [Keep a Changelog](https://keepachangelog.com/).

## 1.0.7-pre1 (current)

- **212 MCP tools** across 6 categories (30 core, 180 advanced) plus 2 always-on **meta**
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
- **`play_and_verify` — deterministic headless playtest + game-feel metrics.** A new
  `deterministic=true` mode makes per-step `wait_frames` (and `settle_frames`) advance an
  exact number of physics frames *inside* the game (`await physics_frame`) instead of a
  wall-clock approximation, so a scripted run is frame-stepped, fps-independent and
  reproducible. Paired with a new `sample` parameter, the whole stepped run is executed in a
  single debugger round-trip (backed by a new runtime-probe `advance_frames` command) and
  returns a frame-indexed `trajectory` plus per-label `metrics` (min/max/first/last/delta/
  range/peak frame+time). Assertions can now target those metrics via
  `{metric, aggregate, operator, expected}`, and `include_trajectory=false` keeps responses
  compact on long runs. Backward compatible: defaults leave the original wall-clock behavior
  unchanged.
- **Regression gates** — three pass/fail tools that turn a playtest into an automated
  ratchet so changes can be checked for *no regression*:
  - **`assert_visual_baseline`** (Project-Advanced): visual-regression gate. Compares a
    candidate screenshot against a stored baseline (golden) image and passes only within
    tolerances (`max_diff_pixels`, `max_diff_ratio`, `rmse_threshold`, with a per-pixel delta
    threshold). Bootstraps the baseline from the candidate when missing (or
    `update_baseline=true`), can emit a diff heatmap PNG to `diff_output_path`, and fails on
    dimension mismatch.
  - **`assert_performance_budget`** (Debug-Advanced): performance budget gate. Captures a
    runtime performance snapshot and checks it against a `budget` (`min_fps`,
    `max_frame_time_ms`, `max_physics_frame_time_ms`, `max_object_count`,
    `max_resource_count`, `max_rendered_objects`, `max_memory_mb`, `max_node_count`),
    returning a per-metric breakdown. Accepts an explicit `snapshot` to evaluate offline.
  - **`assert_no_runtime_errors`** (Debug-Advanced): runtime-error hard gate. Scans the
    categorized debugger output and fails if any error events are present; `categories` and
    `since_sequence` let you gate a specific window of a run.
- **Asset closure** — two tools that take generated/imported raw assets the rest of the way
  to animation-ready, usable resources:
  - **`slice_sprite_sheet`** (Project-Advanced): slices a sprite sheet texture into a
    `SpriteFrames` resource (`.tres`). Grid is given as `{h_frames, v_frames}` or
    `{cell_width, cell_height}` with optional `margin`/`spacing`; frames are indexed
    row-major. Pass `animations` (`{name, frames OR start_frame+end_frame, fps, loop}`) for
    named clips, or omit for a single looping `default` clip. `create_scene=true` also saves
    an `AnimatedSprite2D` scene wired to the SpriteFrames with the first clip autoplaying.
  - **`inspect_gltf_asset`** (Project-Advanced): imports a glTF/GLB with `GLTFDocument` and
    reports a structural summary (mesh/material/animation/skin/camera/light/node counts plus
    names) and validation warnings (no meshes, meshes without materials, no animations), so a
    generated or downloaded 3D asset can be verified before use. Read-only.
- **External generation** — bring-your-own-key text-to-3D:
  - **`generate_3d_asset`** (Project-Advanced): generates a 3D model (glTF/GLB) from a text
    prompt via an external text-to-3D provider and lands it into `res://`. Asynchronous flow:
    submits a job, polls the provider's status endpoint until success/failure, downloads the
    resulting glTF/GLB, validates the bytes (GLB magic / JSON glTF), saves it, and by default
    runs `inspect_gltf_asset` on the result and writes a `.gen.json` manifest. Pick a `preset`
    (`meshy_text_to_3d`, `tripo_text_to_3d`) to fill the submit/status endpoints, request body
    and field paths from a built-in template, or set them manually. **Bring-your-own-key:** the
    API key is read from an OS env var named by the preset (e.g. `MESHY_API_KEY` /
    `TRIPO_API_KEY`), never logged or stored — the plugin ships only request templates and the
    user supplies their own key and pays their own provider quota. Returns `unconfigured` when
    no preset/`submit_endpoint` is set so callers can skip or fall back.
  - New `model3d` provider presets (`meshy_text_to_3d`, `tripo_text_to_3d`) added to
    `AssetProviderPresets`, alongside the existing image/audio presets.

## 1.0.6

- Expanded advanced tool coverage and tool-management UI.
- HTTP server reliability and port-conflict handling improvements.

## 1.0.3

- Native, dependency-free MCP server inside the editor (no Node.js bridge).
- Initial core tool set for nodes, scripts, scenes, the editor, debugging, and project data.

---

For the precise contents of any release, browse the tagged commits in the repository.
