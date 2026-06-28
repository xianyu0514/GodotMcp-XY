# Changelog

All notable user-facing changes are tracked here.

## Unreleased

- `set_dod` now rejects whitespace-only criterion text on the single-criterion path (both creating a new criterion by text and renaming an existing one by index), returning an error instead of persisting an empty-text criterion. This matches the non-empty rule already enforced on the full-list / `add_task` path.
- Made DoD criterion text consistently trimmed on every storage path. `set_dod` now stores the trimmed `criterion` (matching how criteria are matched and created), and `_normalize_dod` (used by `add_task` and full-list `set_dod`) now trims string entries and rejects whitespace-only ones, the same as dict entries. Previously a `criterion` passed with surrounding whitespace (e.g. `"  fps ok  "`) could be persisted with padding yet matched trimmed, causing lookups to miss and duplicate entries to appear.
- Performance: cut redundant work on the per-request hot path without changing any behavior. The script sandbox (`execute_script` / `execute_editor_script` / `evaluate_*` guard) now compiles each denylist RegEx once and reuses it from a process-lifetime cache instead of recompiling ~26 patterns on every scan, and strips string/comment content with an O(n) buffer join instead of O(n²) per-character concatenation. The JSON-RPC server no longer builds full-request/response `JSON.stringify` strings for debug logging when the log level is above DEBUG (the default), so every `tools/list`, `tools/call`, `resources/list`, and incoming message skips that wasted serialization.
- Made `set_dod` single-criterion updates transactional: the new-criterion path validates all error conditions (invalid gate, `observed` without a gate, non-dict `observed`) before appending, and the existing-criterion path mutates a copy that is only committed once every check passes. A failed call no longer leaves a half-created criterion or a partially-modified one (e.g. a gate attached but the subsequent `observed` evaluation rejected) in the task's DoD.
- Hardened node-creation type validation in `create_node` and `batch_scene_node_edits` create ops: they now reject non-Node classes (e.g. `Resource`, `RefCounted`) and abstract Node classes (e.g. `CanvasItem`) up front with a clear, actionable error instead of letting `ClassDB.instantiate` return null and crashing on the subsequent property assignment. The check is a pure `ClassDB`-only helper (`class_exists` → Node-derived → instantiable), so it's deterministic and unit-tested. Concrete Node types are unaffected.
- Tightened `manage_task_plan` DoD gate evaluation: `set_dod` now evaluates `observed` against the gate even when it creates a brand-new criterion by `criterion` text (previously the metrics were silently ignored and `met` defaulted to false on that path), and an invalid gate no longer leaves a half-created criterion behind. A `no_runtime_errors` gate now requires an actual measurement — an empty `observed` is treated as "can't prove ⇒ not met" instead of passing on a default of 0, matching the other gate types. Also refreshed the `manage_task_plan` tool description in the translation files and documented the optional `gate`/`last_evaluation` DoD fields in the persisted schema.
- Closed a script-sandbox bypass and reduced false positives: `execute_script`'s single-line Expression path is now scanned by the same guard (previously only the multi-line/`execute_editor_script` path was), so a single-line `OS.execute(...)` can no longer slip through under STRICT security. The filesystem check no longer flags Godot scene-tree node paths (`/root/...`) and only treats `~`/`~/` as a home-dir path instead of matching any string containing a tilde (e.g. `"~5 enemies"`); out-of-project absolute and system paths (`/etc/`, `/var/`, drive letters, `~/...`) stay blocked.
- Hardened `manage_task_plan` Definition-of-Done with optional machine-checkable `gate`s so the VERIFY phase decides `met` objectively instead of self-asserting. A DoD criterion can declare a gate of type `performance_budget` (a `budget` of min_fps/max_frame_time_ms/max_physics_frame_time_ms/max_object_count/max_resource_count/max_rendered_objects/max_memory_mb/max_node_count, mirroring `assert_performance_budget`), `no_runtime_errors` (`max_errors`, default 0), or `visual_baseline` (`max_diff_pixels`/`max_diff_ratio`). On `set_dod`, passing `observed` measured metrics auto-computes `met` from the gate and records the verdict as evidence. No new MCP tool; this deepens an existing one and the catalog stays at 215 tools.
- Added a script sandbox guard for `execute_editor_script`, `evaluate_debug_expression` and `evaluate_runtime_expression`: under STRICT `security_level` (the default), scripts/expressions are scanned by a configurable capability denylist (OS process execution, out-of-project filesystem paths, networking, other dangerous APIs) and rejected with a structured `blocked` result before execution. PERMISSIVE mode keeps the previous unrestricted behavior. No new MCP tool is added; the guard hardens existing tools and the catalog stays at 215 tools.
- Expanded the MCP tool catalog to 215 tools by adding the ship-loop closure and localization tools.
- Added `smoke_test_export` (Editor-Advanced): post-export smoke test that resolves the artifact, optionally exports first, asserts the product file exists, and launches it to capture and check the exit code — an objective, runnable-build gate.
- Added `bump_version` (Project-Advanced): semantic version bump written back to project.godot plus an automatic dated changelog entry, with a `dry_run` mode.
- Added `manage_localization` (Project-Advanced): single action-based localization workflow — `list` registered `.translation` files, `extract` translatable keys from scenes/scripts into a Godot CSV (preserving existing translations), `import` that CSV into per-locale `.translation` files registered in ProjectSettings, and `export` registered translations back to CSV for round-trip checks. All write actions support `dry_run`.
- Added external-generation budget guards: `generate_asset` and `generate_3d_asset` external calls now honor a configurable call-count/limit window (`external_gen_budget`, `external_gen_budget_window_sec`) and reject calls over budget. Default 0 keeps it unlimited and backward-compatible.
- Added a minimal GitHub Actions CI workflow (headless import + GUT unit tests).
- Refined and normalized the documentation set: root README, Chinese README, addon README files, configuration, architecture, testing, contributing, remote access, industrialization guides and generated tool-reference pages.
- Repaired corrupted Chinese documentation text in repository-facing docs and agent skill guides.
- Clarified the 215-tool model: 30 core tools, 183 advanced tools and 2 always-on meta tools.

## 1.0.7-pre1 (current)

- Expanded the MCP tool catalog to 212 tools.
- Added `generate_3d_asset` (Project-Advanced): bring-your-own-key text-to-3D generation that submits a job to an external provider (meshy/tripo presets), polls until completion, downloads and validates the glTF/GLB into `res://`, and inspects the result by default.
- Added asset-closure workflows including sprite-sheet slicing and glTF/GLB inspection.
- Added deterministic `play_and_verify` workflows for frame-stepped playtesting and game-feel metrics.
- Added regression gates for visual baselines, performance budgets and runtime errors.
- Improved project-level automation around task plans, resource dependency checks, migration scans, TileSets, render output and generated assets.

## 1.0.6

- Improved runtime/debug tooling and project inspection workflows.
- Expanded integration coverage for runtime probe and editor automation flows.

## 1.0.3

- Stabilized the native Godot MCP server architecture.
- Added core scene, node, script, editor, debug and project tools.
- Added HTTP/SSE and stdio transports.
