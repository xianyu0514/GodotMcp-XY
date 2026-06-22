# Autonomous Iteration Harness

This is the loop that ties the [planner](gdd-to-tasks.md), the
[gameplay spec](gameplay-spec-template.md), and the
[asset generation tool](../tools/project-tools.md) together so the AI can drive
a task to completion **without stopping to ask a human on every failure**.

> Failure is data. The harness routes failures back into a fix step and retries
> until the definition of done passes or a hard stop condition is hit.

## The loop

```
        ┌──────────────────────────── memory ───────────────────────────┐
        │ task list · attempts · last error · measured metrics · assets  │
        └────────────────────────────────────────────────────────────────┘
            │            ▲                                        ▲
            ▼            │                                        │
   ┌──────┐   ┌────────┐   ┌─────┐   ┌────────┐   ┌─────┐
   │ PLAN │──▶│EXECUTE │──▶│ RUN │──▶│ VERIFY │──▶│ DoD?│──▶ done
   └──────┘   └────────┘   └─────┘   └────────┘   └──┬──┘
                  ▲                                   │ no
                  │              ┌──────┐             │
                  └──────────────│ FIX  │◀────────────┘
                                 └──────┘
```

## Phases

### 1. PLAN
Pop the next task whose `depends_on` are all done. If none are ready and tasks
remain, that is a planning bug — surface it. Each task carries its `do` action
and a `done_when` list (see the planner playbook).

### 2. EXECUTE
Perform the task's action with the relevant tools:
- **Assets:** `generate_asset` (placeholder-first), `create_custom_resource`,
  `batch_create_resources`, `create_tileset`, `create_animation`.
- **Scenes/scripts:** `create_scene`, `create_node`, `attach_script`,
  `write_script`, `update_resource_properties`.
- **Project:** `upsert_project_input_action`, `add_project_autoload`,
  `set_project_setting`, `create_theme`.

### 3. RUN
Bring the change to life: `play_and_verify` (runs the scene and applies input
steps) or `run_project_test` / `run_project_tests` for logic. For edit-time
checks use `validate_script` and `detect_broken_scripts` first to fail fast.

### 4. VERIFY
Check the task's `done_when` using assertions:
- Runtime metrics → `assert_runtime_condition`, `await_runtime_condition`,
  `evaluate_runtime_expression`, `get_runtime_scene_tree`.
- Tests → `run_project_tests` (expect 0 failures).
- Visuals → `get_editor_screenshot` + `compare_render_screenshots`.

### 5. DoD gate
If every `done_when` passes, mark the task done and record results in memory.
If not, go to FIX.

### 6. FIX
Diagnose with `get_debug_output`, the measured-vs-target delta from VERIFY, and
`audit_project_health`. Apply the smallest change that addresses the specific
failure, then loop back to RUN. Do **not** re-plan the whole task on the first
failure — fix and retry.

## Memory (carry between iterations)

Keep a compact record so retries are informed, not blind:

```
task_id, attempt_count, status,
last_action, last_error,
metrics: { jump_height: 84 (target 96), ... },
assets: { player_sprite: res://art/player.png, ... },
decisions: [ "raised v0 from 380 to 430 after 12px short jump" ]
```

## Definition of Done (slice-level)

Stop the loop as **success** only when all hold:

- [ ] Every task `done_when` passes.
- [ ] `run_project_tests` → 0 failures.
- [ ] `play_and_verify` golden path (start → core loop → win) passes.
- [ ] `detect_broken_scripts` / `audit_project_health` → clean.
- [ ] Gameplay-spec metrics within tolerance.
- [ ] Required real assets in place (no placeholders left on the must-replace list).

## Recovery rules (when NOT to stop and ask)

Auto-recover (retry FIX) for:
- Failed assertions / metric out of tolerance → adjust params, retry.
- Broken script / parse error → fix syntax, retry.
- Missing asset → `generate_asset` a placeholder, retry.
- Missing input action / autoload → create it, retry.

## Hard stop conditions (DO surface to the human)

Stop and report when:
- The same task fails **N times** (default 3) with no progress (same error).
- A task needs a real external credential/endpoint that is not configured
  (`generate_asset` provider=external returns `unconfigured`).
- A design decision is genuinely ambiguous (two valid interpretations change
  the slice).
- A destructive or irreversible action would be required.

## Putting it together (pseudocode)

```
plan = decompose(gdd)              # planner playbook
memory = {}
while not dod_met(plan, memory):
    task = next_ready(plan, memory)
    execute(task)                  # generate_asset / create_scene / ...
    run(task)                      # play_and_verify / run_project_tests
    result = verify(task)          # assertions + metrics
    if result.passed:
        mark_done(task, memory)
    else:
        if task.attempts >= 3 or needs_human(result):
            surface_to_human(task, result); break
        fix(task, result, memory)  # smallest change addressing result.delta
```
