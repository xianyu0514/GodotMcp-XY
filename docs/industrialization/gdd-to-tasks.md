# Planner Playbook: GDD → Executable Task List

This is the **design & planning loop**. It is a playbook (a procedure the AI
follows), not a tool. Goal: take a one-sentence request such as *"make a 2D
platformer"* and produce an **ordered, verifiable task list** that the
[autonomous iteration harness](autonomous-iteration-harness.md) can execute.

## Step 1 — Write a one-page GDD

Capture only what is needed to build a vertical slice. Keep it short.

```
Title:        <name>
Pitch:        <one sentence>
Genre/Camera: <e.g. 2D side-scroller, fixed gravity>
Core loop:    <what the player does for 30 seconds>
Win/Lose:     <conditions>
Scope (slice):<the smallest playable thing, e.g. "1 level, 1 enemy, reach the flag">
```

## Step 2 — Decompose into ordered tasks

Always decompose in **dependency order** across these tracks. Earlier tracks
unblock later ones.

1. **Project setup** — input actions (`upsert_project_input_action`),
   autoloads (`add_project_autoload`), project settings (`set_project_setting`).
2. **Assets (placeholder-first)** — generate placeholder sprites and SFX with
   [`generate_asset`](../tools/project-tools.md) so later scene work is never
   blocked on art. Example: player sprite, enemy sprite, tile, jump SFX.
3. **Characters** — scene + script per actor (player controller, enemy AI).
4. **Levels** — tilemap / scene layout (`create_tileset`, `create_scene`).
5. **UI** — HUD, menus (`create_theme`, Control nodes).
6. **Audio wiring** — hook generated `AudioStream`s to events.
7. **Verification** — gameplay-spec assertions + tests (see below).

Each task must be small (a few minutes of work) and end in a **checkable
result**. Use this shape:

```
- id: player-jump
  track: characters
  depends_on: [setup-input, asset-player-sprite]
  do: "Add CharacterBody2D player with move/jump in player.gd"
  done_when:
    - "scene res://player/player.tscn exists and opens"
    - "play_and_verify: player y decreases by >= jump_height_px within 0.4s of jump"
```

## Step 3 — Attach a gameplay spec

For anything that has "feel" (movement, combat timing), translate it into
numbers using the [gameplay spec template](gameplay-spec-template.md) and add
those metrics to the task's `done_when`. This is what connects planning to the
asset/verify loops: every subjective goal becomes an assertion.

## Step 4 — Define done (DoD) for the slice

The slice is done when **all** of:

- Every task's `done_when` passes.
- `run_project_tests` reports 0 failures.
- `play_and_verify` of the golden path (start → core loop → win) succeeds.
- `audit_project_health` / `detect_broken_scripts` report no broken scripts.
- No placeholder asset remains on the "must be real" list (if the GDD requires
  final art).

## Worked example: "make a 2D platformer" (vertical slice)

```
setup-input        upsert_project_input_action: move_left/right, jump
asset-player        generate_asset type=sprite  prompt="green platformer hero"   -> res://art/player.png
asset-enemy         generate_asset type=sprite  prompt="red slime enemy"          -> res://art/slime.png
asset-tile          generate_asset type=texture prompt="grey stone platform tile" -> res://art/tile.png
asset-jump-sfx      generate_asset type=sfx     prompt="retro jump blip"          -> res://audio/jump.wav
player-controller   create_scene + attach_script (CharacterBody2D + gravity/jump)
enemy-patrol        create_scene + attach_script (patrol AI)
level-1             create_tileset + create_scene (platforms + flag)
hud                 create_theme + Control (coins/health)
audio-wire          play jump.wav on jump
verify-slice        play_and_verify golden path + gameplay-spec assertions
```

Hand this list to the [autonomous iteration harness](autonomous-iteration-harness.md).
