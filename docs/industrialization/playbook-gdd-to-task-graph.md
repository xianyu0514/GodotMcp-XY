# Playbook: GDD → Task Graph (executable)

A concrete, repeatable runbook that turns a one-page GDD into a persisted task
graph with **machine-checkable Definition-of-Done gates**, using only
`manage_task_plan`. Run the same steps every time so the plan is deterministic
and survives across sessions (`res://.mcp/task_plan.json`).

This is the operational companion to the conceptual
[GDD → Executable Task List](gdd-to-tasks.md). Where that doc explains *what* a
good task looks like, this one gives the *exact* tool calls.

## Preconditions

- Enable the `Project-Advanced` group (for `manage_task_plan`) via `enable_tools`.
- Have a one-page GDD (see [gdd-to-tasks.md](gdd-to-tasks.md), Step 1).

## Step 1 — Initialize the plan

```json
{ "tool": "manage_task_plan", "args": { "action": "init", "goal": "2D platformer vertical slice", "reset": false } }
```

`reset:false` refuses to overwrite an existing healthy plan. Use `reset:true`
only when intentionally discarding the previous plan.

## Step 2 — Add tasks with dependencies and gated DoD

Add one task per vertical-slice step. Each DoD criterion that can be measured
objectively carries a `gate`; criteria that are inherently manual omit it.

```json
{ "tool": "manage_task_plan", "args": { "action": "add_task", "task": {
  "title": "Create input actions: move_left/move_right/jump/pause",
  "tags": ["input"],
  "dod": [
    { "criterion": "All four input actions are registered" }
  ]
}}}
```

```json
{ "tool": "manage_task_plan", "args": { "action": "add_task", "task": {
  "title": "Responsive 2D player controller",
  "depends_on": ["<id-of-input-task>"],
  "tags": ["gameplay", "player"],
  "dod": [
    { "criterion": "Player moves left/right with configured input actions" },
    { "criterion": "Runs without runtime errors during smoke test",
      "gate": { "type": "no_runtime_errors", "max_errors": 0 } },
    { "criterion": "Holds the frame budget",
      "gate": { "type": "performance_budget", "budget": { "min_fps": 55, "max_memory_mb": 200 } } }
  ]
}}}
```

```json
{ "tool": "manage_task_plan", "args": { "action": "add_task", "task": {
  "title": "Title screen matches approved mockup",
  "tags": ["ui"],
  "dod": [
    { "criterion": "Title screen visually matches the golden baseline",
      "gate": { "type": "visual_baseline", "max_diff_ratio": 0.005 } }
  ]
}}}
```

### Gate cheat-sheet

| Gate `type` | Thresholds (objective) | Observed metrics on `set_dod` |
| --- | --- | --- |
| `performance_budget` | `budget` keyed like `assert_performance_budget`: `min_fps` (≥), `max_frame_time_ms` / `max_physics_frame_time_ms` / `max_object_count` / `max_resource_count` / `max_rendered_objects` / `max_memory_mb` / `max_node_count` (≤) | same keys, e.g. `{ "min_fps": 58, "max_memory_mb": 180 }` |
| `no_runtime_errors` | `max_errors` (default 0) | `{ "error_count": 0 }` or `{ "errors": [...] }` |
| `visual_baseline` | `max_diff_pixels` and/or `max_diff_ratio` | `{ "diff_pixels": 12, "diff_ratio": 0.001 }` |

A missing observed metric counts as a failure — you can't prove it, so it isn't met.

## Step 3 — Verify the graph is sound

```json
{ "tool": "manage_task_plan", "args": { "action": "get" } }
```

Confirm: no cycle error, every `depends_on` resolves, and `progress` totals look
right. `add_task` rejects dependency cycles at insert time.

## Step 4 — Hand off to execution

```json
{ "tool": "manage_task_plan", "args": { "action": "next" } }
```

`next` returns dependency-ready tasks plus blocked tasks and progress. Take the
first ready task into the [single-slice loop](playbook-single-slice.md).

## Done criteria for this playbook

- A persisted plan exists at `res://.mcp/task_plan.json`.
- Every measurable DoD criterion has a `gate`; manual ones are intentional.
- `get` reports no cycles and resolvable dependencies.
- `next` returns at least one ready task.
