# Complete Game Workflows

[中文说明](game-workflows.zh.md)

`plan_game_workflow` and `run_game_workflow` are the compact server-side loop for goals that cannot be completed reliably by selecting one small tool set once. They do not replace the 217 atomic capabilities. They compose and execute those capabilities through a persistent, evidence-gated plan.

## Why the workflow can exceed eight tools

The existing workflow router keeps one ad-hoc model turn cheap: it returns at most 8 atomic tools by default and never more than 10. That is a visible discovery/context budget, not a project capability limit. The complete-goal fallback can route semantic clauses separately and merge their names into one durable plan, so the full workflow is not capped at ten.

A complete goal is stored as a DAG that may contain many atomic steps. With `max_steps` omitted or set to zero, `run_game_workflow` chooses a 4/8/16/32-call checkpoint slice based on remaining work and prior rounds. A positive value controls only that call. Reaching either boundary returns a resumable yield and leaves every pending step in the durable DAG. Only schema-required inputs for the current step are requested. Hidden supplementary tools execute internally without changing their enabled state, rebuilding `tools/list`, or invalidating the discovery route cache.

| Boundary | Limit | Purpose |
| --- | ---: | --- |
| Ad-hoc routed tool set | 8 default, 10 hard maximum | Keep one model turn small |
| Atomic calls per workflow round | Adaptive 4/8/16/32 by default; caller override is one-call only | Bound one turn's load without bounding the goal |
| Full persisted DAG | Goal-dependent | Preserve all capabilities required for correctness |
| Automatic repair attempts | Evidence-adaptive by default; optional positive caller policy | Continue when evidence changes; replan after 3 identical failures |
| Async polls per step | No completion ceiling; checkpoint marker every 120 polls | A slow valid job can finish without creating a hot loop |
| Compact receipts | All distinct evidence retained; identical polls/results aggregate | Preserve proof while avoiding repeated-token growth |

## Production profiles

Profiles are composable. An objective can select one profile or combine several into one intention-preserving plan. Distinct writes are never removed merely because they call the same tool: a gameplay scene and a UI scene remain two separately labelled `create_scene` steps. Repeated deterministic reads can still reuse the normal result cache.

| Profile | Closed loop |
| --- | --- |
| `gameplay_feature` | inspect project/input → create scene/script/input → save → compile → play → runtime-error gate |
| `ui_screen` | inspect scene → create theme/UI/layout → save → runtime screenshot → visual baseline |
| `script_repair` | discover broken scripts → read/modify → compile → project tests |
| `asset_pipeline` | inspect resources/import → reimport → dependency and optional glTF validation |
| `animation_audio` | author animation/keys → inspect runtime animation/audio → apply state → runtime evidence |
| `level_design` | inspect scenes → create scene/TileSet/cells → save → persistence and visual gates |
| `runtime_debug` | inspect editor errors → start probe/game → inspect live state/output/tree → no-error gate |
| `localization` | list → extract → import translations |
| `performance` | capture runtime snapshot/memory trend → optionally optimize code → compile → budget and error gates |
| `quality_assurance` | discover tests → compile all project scripts → run and poll the test batch |
| `project_health` | audit scripts/dependencies/cycles/migration; mutation is included only when the objective explicitly requests a fix |
| `release_export` | inspect preset/templates → platform-specific preparation → validate → export → smoke test artifact |

Runtime steps automatically receive `install_runtime_probe` and `run_project` prerequisites. An Android configuration step is generated only for an Android target. A read-only audit never authorizes migration writes.

## Basic use

Plan a complete objective:

```json
{
  "action": "plan",
  "objective": "Create a playable 2D controller with a pause menu, run project tests, and export a smoke-tested Linux build"
}
```

The planner either returns `planned`, requests clarification, or reports the exact missing capabilities. Exact atomic names are always retained as objective evidence. For an unfamiliar composite objective, the local schema-free router may merge more than ten capabilities across semantic clauses. If any clause remains uncovered, planning returns `needs_clarification` with `uncovered_requirements`; it never persists the matched subset as the whole goal.

Advance the plan:

```json
{
  "expected_workflow_id": "<id returned by the planner>"
}
```

Omit `max_steps` (or pass `0`) for adaptive execution. A positive value is useful when a client deliberately wants a smaller or larger current slice, but it cannot delete or complete remaining work.

When a current atomic step has required parameters, the runner returns `needs_input` with `step_id`, `tool_name`, and `missing_inputs`. Supply only that step's arguments:

```json
{
  "expected_workflow_id": "<same id>",
  "step_inputs": {
    "wf_004": {
      "scene_name": "Player",
      "root_type": "CharacterBody2D"
    }
  }
}
```

Inputs are ephemeral: credentials, source payloads and paths passed while running are not copied into the durable goal contract. Planner-owned control arguments, such as a localization action, cannot be overridden by `step_inputs`.

## States and completion

| Status | Meaning | Next action |
| --- | --- | --- |
| `planned` / `running` | More authorized steps remain | Call the runner again |
| `needs_input` | Current tool schema has required fields not supplied | Send arguments under the returned step id |
| `waiting` | Async work is pending or a transient failure retained the checkpoint | Honor `retry_after_ms` when present, then call again; no repair is consumed |
| `repairing` / `retry_required` | A declared repair is ready or needs another input/attempt | Supply repair inputs if requested; changed evidence may continue |
| `replan_required` | The same failure repeated three times, a verifier has no repair, or an explicit repair policy ended | Change inputs/capabilities instead of repeating identical work |
| `blocked` | A capability disappeared, integrity failed, or a protected path was targeted | Correct the hard constraint, then replan |
| `recovery_required` | A non-idempotent mutation was dispatched before restart and its outcome is unknown | Inspect project state and replan; safe reads/idempotent calls replay automatically |
| `cancelled` | The workflow was explicitly cancelled | Create/replan a workflow |
| `completed` | Every step is done and every objective gate references a passing engine receipt | Goal contract is satisfied |

The following never count as completion:

- `pending`, `running`, `partial`, `skipped`, `unconfigured`, `stale`, timeout or cancellation;
- an empty verifier result;
- zero discovered tests reported as a passing test run;
- script verification with any failed script;
- a performance verdict without measured checks;
- a visual verdict without measured diff data;
- a health audit in a failing state;
- task fields manually changed to `done` without a matching passing receipt.

## Integrity and safety

Before every runner round, the engine recompiles the expected blueprint from the persisted goal contract and compares the exact step order, tools, arguments, dependencies, repair declarations and objective gate set. A changed blueprint stops before any atomic handler runs.

The default protected roots are `res://addons/godot_mcp` and `res://.mcp`. Candidate paths are resolved and simplified before comparison, so a path such as `res://scenes/../addons/godot_mcp/...` cannot bypass protection. Additional protected paths may be declared while planning. Meta/control tools cannot be nested inside a workflow, and the runner has no arbitrary `tool_name` parameter.

`expected_workflow_id` provides compare-and-swap protection for run, replan and cancel operations. This prevents an agent with a stale response from advancing a newer plan.

Default responses are projections: at most four ready step IDs/names/stages plus progress and counters. They omit the durable DAG, arguments, receipts and atomic schemas unless `include_plan=true` or the current step actually needs inputs. This keeps long workflows cheap to resume. Identical pending receipts aggregate an occurrence counter; distinct completion evidence is never discarded.

## What “complete” can guarantee

The workflow guarantees that the registered capability plan is not silently reduced and that success is not reported without the declared local evidence. It cannot manufacture an unavailable asset, API credential, export template, platform SDK, product decision, or unsupported atomic capability. Those conditions return `needs_input` or `blocked` with a concrete reason. This fail-closed behavior is what keeps “completed” meaningful while still allowing the agent to resume after the prerequisite is supplied.
