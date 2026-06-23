# Playbook: Single Slice — PLAN → EXECUTE → RUN → VERIFY → FIX (executable)

A concrete, repeatable runbook for taking **one** ready task from the task graph
to a verified, evidence-backed `done`. Run the same loop for every slice so each
result is objective and reproducible.

This is the operational companion to the conceptual
[Autonomous Iteration Harness](autonomous-iteration-harness.md): same five
phases, but with the exact `manage_task_plan` calls and the gate-evaluation step
that decides `met` from measured numbers instead of a self-asserted boolean.

## Preconditions

- A task graph exists (see [GDD → Task Graph](playbook-gdd-to-task-graph.md)).
- Enable only the tool groups the task needs (`enable_tools`); start from core.

## Phase 1 — PLAN: pick the next ready task

```json
{ "tool": "manage_task_plan", "args": { "action": "next" } }
```

Take the first ready task; read its `dod` (and gates). Mark it in progress:

```json
{ "tool": "manage_task_plan", "args": { "action": "set_status", "id": "<task-id>", "status": "in_progress" } }
```

## Phase 2 — EXECUTE: smallest coherent edit

- Inspect before writing (`get_project_structure`, `get_scene_structure`, `read_script`).
- Apply the minimal set of Node/Scene/Script/Project edits for this task only.
- Follow existing project conventions; keep changes backward compatible.

## Phase 3 — RUN: bring the target scene live

```text
run_project  →  await_scene_ready  →  install_runtime_probe (if needed)  →  get_runtime_scene_tree
```

## Phase 4 — VERIFY: measure, then write the verdict into the gate

Run the assert tool that matches each gated criterion, then feed the **observed
metrics back** so `manage_task_plan` computes `met` objectively:

- `no_runtime_errors` gate → run `assert_no_runtime_errors`, then:

```json
{ "tool": "manage_task_plan", "args": { "action": "set_dod", "id": "<task-id>", "index": 1, "observed": { "error_count": 0 } } }
```

- `performance_budget` gate → run `assert_performance_budget` (or `play_and_verify`), then:

```json
{ "tool": "manage_task_plan", "args": { "action": "set_dod", "id": "<task-id>", "index": 2, "observed": { "min_fps": 58, "max_memory_mb": 180 } } }
```

- `visual_baseline` gate → run `assert_visual_baseline`, then:

```json
{ "tool": "manage_task_plan", "args": { "action": "set_dod", "id": "<task-id>", "index": 0, "observed": { "diff_pixels": 9, "diff_ratio": 0.0004 } } }
```

`set_dod` with `observed` sets `met` from the gate, stores the verdict as
`evidence`, and records `last_evaluation`. Manual (gateless) criteria are set the
old way: `{ "action": "set_dod", "id": "...", "index": N, "met": true, "evidence": "..." }`.

## Phase 5 — FIX or COMPLETE

Try to close the task:

```json
{ "tool": "manage_task_plan", "args": { "action": "set_status", "id": "<task-id>", "status": "done" } }
```

- If every DoD criterion is `met`, the task is marked `done`.
- If any gated criterion failed, `set_status='done'` is **refused**. Do not force
  it. Instead: capture the failing `checks`/`failures` from the criterion's
  `last_evaluation`, patch the smallest likely cause (Phase 2), re-run the failed
  check (Phase 3–4), and re-evaluate. Repeat until the gate passes.
- `force:true` exists for genuinely manual sign-off only; never use it to bypass
  a failing objective gate.

Then loop back to Phase 1 for the next ready task.

## Recovery rules

Continue autonomously on clear local causes (wrong path but file exists, a scene
needs reimport, a disabled tool can be enabled via `enable_tools`, a failing gate
with an obvious implementation fix).

Stop and ask a human only for: missing credentials/paid keys, a self-contradictory
GDD, a change that would remove safety/auth controls, or a failing metric that
needs a *design* decision rather than an implementation fix.

## Pseudocode

```text
task = manage_task_plan(next).first_ready
manage_task_plan(set_status, task, "in_progress")
implement(task)                        # smallest coherent edit
run_project(); install_runtime_probe()
for crit in task.dod:
    if crit.gate:
        observed = run_matching_assert(crit.gate)        # measure
        manage_task_plan(set_dod, task, crit.index, observed)   # objective met
    else:
        manage_task_plan(set_dod, task, crit.index, met=manual_check())
result = manage_task_plan(set_status, task, "done")      # refused if a gate failed
if result.error: fix(task.failing_gate); retry
```
