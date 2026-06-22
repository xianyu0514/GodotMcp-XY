# Gameplay Spec Template: Turning "Feel" into Verifiable Metrics

"Feel" is not testable; numbers are. This template translates subjective design
goals into **quantified metrics** that map directly to plugin assertions
(`play_and_verify`, `assert_runtime_condition`, `await_runtime_condition`,
`evaluate_runtime_expression`). It is the bridge between the
[planner](gdd-to-tasks.md) and the [iteration harness](autonomous-iteration-harness.md).

## How to use it

1. Pick a behavior with "feel" (jumping, dashing, hit-stop, enemy timing).
2. Fill in the spec table: parameter, target value, tolerance, and how it is
   measured at runtime.
3. Copy the metrics into the task's `done_when` so they are enforced.

## Spec table

| Parameter | Symbol | Target | Tolerance | Runtime measurement |
| --- | --- | --- | --- | --- |
| Gravity | `g` | 980 px/s² | ±5% | read `player.gravity` via `evaluate_runtime_expression` |
| Jump height | `h` | 96 px | ±8 px | peak drop in `player.position.y` after `jump` input |
| Time to apex | `t_apex` | 0.35 s | ±0.05 s | time from jump press to vertical velocity ≈ 0 |
| Coyote time | `t_coyote` | 0.10 s | ±0.02 s | jump still succeeds within window after leaving ledge |
| Jump buffer | `t_buffer` | 0.12 s | ±0.02 s | jump pressed before landing still triggers on land |
| Max run speed | `v_max` | 240 px/s | ±5% | steady-state `abs(player.velocity.x)` while holding move |
| Terminal fall | `v_term` | 600 px/s | ±10% | max `player.velocity.y` in a long fall |

The physics relationships are consistent, so you can derive values instead of
guessing: `g = 2*h / t_apex²` and initial jump velocity `v0 = 2*h / t_apex`.

## Mapping metrics to assertions

Each metric becomes one or more assertions. Conceptual mapping (exact tool
arguments depend on your scene):

```
# Jump height — inject input, then assert the peak rise.
play_and_verify(
  scene = "res://player/player.tscn",
  steps = [ press("jump"), wait(0.4) ],
  assertions = [
    # player rose at least (h - tolerance) pixels from start
    "start_y - min_y >= 88"
  ]
)

# Coyote time — walk off a ledge, wait < t_coyote, jump must still work.
await_runtime_condition("player.is_on_floor() == false")
# within 0.10s:
assert_runtime_condition("player_jumped_successfully == true")

# Max run speed — hold move and sample steady-state velocity.
evaluate_runtime_expression("abs(player.velocity.x)")  # expect ~240 ±5%
```

## Acceptance block (paste into a task `done_when`)

```
done_when:
  - "gravity within 5% of 980"
  - "jump_height within 8px of 96"
  - "coyote_time within 0.02s of 0.10"
  - "max_run_speed within 5% of 240"
  - "play_and_verify golden path passes"
```

## Notes

- Prefer **steady-state** samples over single frames for velocity metrics.
- Sample over a few frames and average to avoid frame-timing noise.
- Keep tolerances explicit — an assertion with no tolerance will flap.
- When a metric fails, the [iteration harness](autonomous-iteration-harness.md)
  feeds the measured-vs-target delta back into the fix step (e.g. "jump 12px
  short → raise `v0`").
