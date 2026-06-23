# Changelog

All notable user-facing changes are tracked here.

## Unreleased

- Refined and normalized the documentation set: root README, Chinese README, addon README files, configuration, architecture, testing, contributing, remote access, industrialization guides and generated tool-reference pages.
- Repaired corrupted Chinese documentation text in repository-facing docs and agent skill guides.
- Clarified the 212-tool model: 30 core tools, 180 advanced tools and 2 always-on meta tools.

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
