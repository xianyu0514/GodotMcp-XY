# Changelog

All notable user-facing changes are tracked here.

## Unreleased

- Expanded the MCP tool catalog to 214 tools by adding the ship-loop closure tools.
- Added `smoke_test_export` (Editor-Advanced): post-export smoke test that resolves the artifact, optionally exports first, asserts the product file exists, and launches it to capture and check the exit code — an objective, runnable-build gate.
- Added `bump_version` (Project-Advanced): semantic version bump written back to project.godot plus an automatic dated changelog entry, with a `dry_run` mode.
- Added external-generation budget guards: `generate_asset` and `generate_3d_asset` external calls now honor a configurable call-count/limit window (`external_gen_budget`, `external_gen_budget_window_sec`) and reject calls over budget. Default 0 keeps it unlimited and backward-compatible.
- Added a minimal GitHub Actions CI workflow (headless import + GUT unit tests).
- Refined and normalized the documentation set: root README, Chinese README, addon README files, configuration, architecture, testing, contributing, remote access, industrialization guides and generated tool-reference pages.
- Repaired corrupted Chinese documentation text in repository-facing docs and agent skill guides.
- Clarified the 214-tool model: 30 core tools, 182 advanced tools and 2 always-on meta tools.

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
