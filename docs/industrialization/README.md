# Industrialized AI Game Production with Godot MCP

Godot MCP Native can support more than one-off editor edits. With the right tool presets, specs and verification gates, an AI assistant can run an iterative production loop for a small game slice.

## The three loops

| Loop | Purpose | Representative tools |
| --- | --- | --- |
| **Planning loop** | Convert a game design document into executable tasks and done criteria. | `manage_task_plan`, `get_project_info`, `get_project_structure` |
| **Production loop** | Create scenes, scripts, resources, input actions, TileSets and placeholder/generated assets. | Node, Scene, Script and Project tools; `generate_asset`, `slice_sprite_sheet`, `inspect_gltf_asset` |
| **Verification loop** | Run the game, collect runtime state and enforce regression gates. | `run_project`, `install_runtime_probe`, `play_and_verify`, `assert_performance_budget`, `assert_no_runtime_errors`, `assert_visual_baseline` |

## Recommended workflow

1. Write or import a one-page GDD.
2. Convert the GDD into ordered tasks with clear acceptance criteria.
3. Attach measurable gameplay specs for feel-sensitive mechanics.
4. Execute one vertical slice at a time.
5. Run deterministic verification before moving to the next slice.
6. Record learnings and failures in the task plan so the next loop starts with context.

## Tool presets

Start with core tools. Enable advanced groups only for the current loop:

- Planning: `Project-Advanced` for `manage_task_plan` and project audits.
- Production: `Node-Write-Advanced`, `Scene-Advanced`, `Script-Advanced`, selected `Project-Advanced` asset/resource tools.
- Verification: `Debug-Advanced` plus runtime probe and regression gate tools.

## Bring-your-own providers

`generate_asset` can be wired to external asset providers through project configuration and provider presets. Keep API keys out of source control and prefer dedicated, minimally scoped provider credentials.

## Read next

Concepts:

- [Planner Playbook: GDD → Executable Task List](gdd-to-tasks.md)
- [Gameplay Spec Template](gameplay-spec-template.md)
- [Autonomous Iteration Harness](autonomous-iteration-harness.md)

Executable playbooks (exact `manage_task_plan` calls + machine-checkable DoD gates):

- [Playbook: GDD → Task Graph](playbook-gdd-to-task-graph.md)
- [Playbook: Single Slice — PLAN → EXECUTE → RUN → VERIFY → FIX](playbook-single-slice.md)
