# Industrialized AI Game Production with Godot MCP

This guide turns the Godot MCP plugin from "an AI that can edit a project" into
**an AI that can ship a small game end to end**. It ties together three loops:

1. **Asset generation loop** — the AI can produce sprites/textures and sound
   effects, not just code.
2. **Design & planning loop** — a one-sentence idea becomes an ordered,
   verifiable task list.
3. **Autonomous iteration loop** — plan → execute → run → verify → fix →
   repeat, with memory and a clear definition of done.

Everything below is built on **existing plugin tools** plus the one new tool
this introduces, [`generate_asset`](../tools/project-tools.md). No external
runtime is required for the offline path.

## The three loops at a glance

```
                 ┌──────────────────────────────────────────────┐
                 │            Autonomous Iteration                │
                 │   plan → execute → run → verify → fix → ↺      │
                 └───────┬───────────────┬───────────────┬───────┘
                         │               │               │
                ┌────────▼──────┐ ┌──────▼───────┐ ┌─────▼────────┐
   Design &     │ GDD → tasks   │ │ build scenes │ │ play_and_    │  Verify
   Planning ───▶│ + gameplay    │ │ + scripts +  │ │ verify /     │◀── against
                │ spec metrics  │ │ ASSETS       │ │ assertions   │  metrics
                └───────────────┘ └──────┬───────┘ └──────────────┘
                                         │
                                  ┌──────▼───────┐
                  Asset           │ generate_    │
                  Generation ────▶│ asset(...)   │  placeholder-first,
                                  └──────────────┘  then real art
```

## Tool mapping (what each loop actually calls)

| Loop | Phase | Primary tools |
| --- | --- | --- |
| Asset | placeholder art | `generate_asset` (provider=placeholder), `create_gradient_texture`, `create_drawable_texture`, `draw_on_texture` |
| Asset | real/external art | `generate_asset` (provider=external), `reimport_resources`, `get_import_metadata` |
| Asset | data resources | `create_custom_resource`, `batch_create_resources`, `create_animation`, `create_tileset` |
| Design | scaffold | `create_scene`, `create_node`, `attach_script`, `write_script`, `upsert_project_input_action`, `add_project_autoload` |
| Verify | run & assert | `play_and_verify`, `assert_runtime_condition`, `await_runtime_condition`, `get_runtime_scene_tree`, `evaluate_runtime_expression` |
| Verify | tests | `run_project_tests`, `run_project_test`, `list_project_tests` |
| Verify | visual | `get_editor_screenshot`, `compare_render_screenshots` |
| Iterate | inspect/fix | `get_debug_output`, `detect_broken_scripts`, `validate_script`, `audit_project_health` |

## Read next

- [GDD → task decomposition](gdd-to-tasks.md) — the planner playbook.
- [Gameplay spec template](gameplay-spec-template.md) — turn "feel" into
  numbers you can assert.
- [Autonomous iteration harness](autonomous-iteration-harness.md) — the loop
  that drives it all, with DoD and recovery rules.
