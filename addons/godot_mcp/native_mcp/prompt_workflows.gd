extends RefCounted
## PromptWorkflows — 真实可执行的工作流 prompts（MCP prompts 能力）
##
## 为 MCP 服务器的 `prompts/list` / `prompts/get` 提供一组真实的工作流模板：
## 每个 prompt 都带 arguments 元数据与一个 get_callable（`Callable(args: Dictionary) -> Dictionary`），
## 渲染后返回 `{description?, messages: [{role, content}]}`，其中 content 是给 AI agent 的
## 逐步工具调用指令（含精确的 JSON 工具调用示例，`{{arg}}` 占位符在调用时被参数值替换）。
##
## 独立 RefCounted 类，避免把 mcp_server_native.gd 撑大。注册入口：register_to_server()。

# ============================================================================
# Prompt 模板（英文，与现有工具描述语言一致）
# ============================================================================

const PLAN_GAME_FEATURE_TEMPLATE: String = """
You are executing the "GDD to Task Graph" workflow against the Godot project through MCP tools.
This is an executable workflow template: follow the steps and call the tools in order.

Goal: {{goal}}
GDD / feature summary: {{gdd_summary}}

Step 1 — Initialize the plan:
{"tool": "manage_task_plan", "args": {"action": "init", "goal": "{{goal}}", "reset": false}}
reset:false refuses to overwrite an existing healthy plan; use reset:true only when you
intend to discard the previous plan.

Step 2 — Add tasks with dependencies and gated DoD:
Break the summary into one task per vertical-slice step. Every Definition-of-Done (DoD)
criterion that can be measured objectively carries a "gate"; inherently manual criteria omit it.
{"tool": "manage_task_plan", "args": {"action": "add_task", "task": {"title": "<task title>", "tags": ["<tag>"], "dod": [{"criterion": "<objective criterion>"}]}}}
{"tool": "manage_task_plan", "args": {"action": "add_task", "task": {"title": "<dependent task>", "depends_on": ["<id-of-prerequisite-task>"], "dod": [{"criterion": "<runs without runtime errors>", "gate": {"type": "no_runtime_errors", "max_errors": 0}}, {"criterion": "<holds frame budget>", "gate": {"type": "performance_budget", "budget": {"min_fps": 55, "max_memory_mb": 200}}}, {"criterion": "<matches golden baseline>", "gate": {"type": "visual_baseline", "max_diff_ratio": 0.005}}]}}}

Gate cheat-sheet: performance_budget (budget: min_fps >=, max_frame_time_ms / max_memory_mb / max_node_count ... <=),
no_runtime_errors (max_errors, default 0), visual_baseline (max_diff_pixels and/or max_diff_ratio).
A missing observed metric counts as a failure — you can't prove it, so it isn't met.

Step 3 — Verify the graph is sound:
{"tool": "manage_task_plan", "args": {"action": "get"}}
Confirm: no cycle error, every depends_on resolves, and progress totals look right.

Step 4 — Hand off to execution:
{"tool": "manage_task_plan", "args": {"action": "next"}}
next returns dependency-ready tasks plus blocked tasks and progress. Take the first ready
task and run the single-slice loop (execute -> run -> verify -> fix) on it.

Done when: a persisted plan exists at res://.mcp/task_plan.json, every measurable DoD
criterion has a gate, get reports no cycles, and next returns at least one ready task.
"""

const DEBUG_RUNTIME_ERROR_TEMPLATE: String = """
You are executing the "Runtime Error Debugging" workflow against the Godot project through MCP tools.
This is an executable workflow template: follow the loop and call the tools in order.

Reported error:
{{error_text}}
{{context_block}}

1. Collect — {"tool": "get_editor_logs", "args": {"source": "runtime"}} (and {"source": "editor_panel"} if needed):
   pull recent logs and locate the stack frames that mention the error above.
2. Locate — {"tool": "read_script", "args": {"script_path": "<path from the stack trace>"}}:
   read the offending script around the reported line.
3. Diagnose — {"tool": "validate_script", "args": {"script_path": "<script path>"}}:
   confirm there are no parse errors, then identify the root cause (null instance, wrong
   type, out-of-range access, missing signal connection, ...).
4. Fix — apply the smallest coherent edit to the script (modify_script on the read content / create_script for a new file / execute_editor_script).
   Keep the change backward compatible and consistent with project conventions.
5. Re-verify — re-run validate_script on the edited script, then {"tool": "run_project", "args": {}}
   and pull get_editor_logs again. Confirm the original error is gone and no new error appeared.
6. If the error persists or a new one appears, loop back to step 2 with the newest log output.

Stop and ask a human only if the fix would require a design decision or would remove safety/auth controls.
"""

const REVIEW_SCENE_TEMPLATE: String = """
You are executing the "Scene Structure Review" workflow against the Godot project through MCP tools.
This is an executable workflow template: call the tools in order and report findings.

{{focus_block}}

1. {"tool": "get_scene_structure", "args": {"max_depth": -1}} — read the full scene tree of the
   currently open scene: node types, names, hierarchy.
2. {"tool": "list_nodes", "args": {"recursive": true}} — enumerate nodes for a flat checklist
   (use parent_path to zoom into a subtree, limit to bound the response).
3. {"tool": "audit_scene_node_persistence", "args": {}} — find nodes whose owner/persistence
   state is missing or invalid (affects scene saving and inheritance).
4. {"tool": "audit_scene_inheritance", "args": {}} — classify local nodes, instance roots and
   local additions inside instanced subtrees; report mismatch problems.

Deliver a structured review: tree summary (total nodes, max depth), suspicious nodes,
persistence/inheritance issues, and a prioritized fix list with the smallest safe edit for each.
"""

const RUN_TEST_SUITE_TEMPLATE: String = """
You are executing the "Run Test Suite" workflow against the Godot project through MCP tools.
This is an executable workflow template: call the tools in order.

{{target_dir_block}}

1. Discover — {"tool": "list_project_tests", "args": {"search_path": "{{target_dir}}"}} —
   list Python integration tests and GUT unit tests, including whether each is runnable.
2. Run — {"tool": "run_project_tests", "args": {"search_path": "{{target_dir}}", "only_runnable": true}} —
   the first call returns status "pending"; call again with the same arguments to poll until
   the aggregated result arrives (total_count / passed_count / failed_count / skipped_count).
3. Collect structured results — summarize the aggregate counts, then list every failure with
   its test path and reported message.
4. For each failure, run the runtime-error debugging workflow on the reported message, then
   re-run the affected test ({"tool": "run_project_test", "args": {"test_path": "<path>"}})
   until it passes.
"""

const VISUAL_PLAYTEST_TEMPLATE: String = """
You are executing the "Visual Playtest" workflow against the Godot project through MCP tools.
This is an executable workflow template: run the loop and call the tools in order.

Scenario: {{scenario}}

1. Launch — {"tool": "run_project", "args": {}} — start the game (optionally pass scene_path
   to run a specific scene).
2. Probe — {"tool": "install_runtime_probe", "args": {}} — the first call returns "pending";
   call again to get the cached response before proceeding.
3. Drive — {"tool": "play_and_verify", "args": {"steps": [{"action": "<input action>", "wait_frames": 30, "screenshot": true}], "assertions": [{"expression": "<runtime expression>", "description": "<what to check>"}], "deterministic": true}} —
   script the scenario inputs, screenshot the result frame, and evaluate runtime assertions.
   Set fail_on_runtime_error true (default) so captured errors fail the report.
4. Compare — {"tool": "assert_visual_baseline", "args": {"candidate_path": "<screenshot path>", "baseline_path": "<golden path>", "max_diff_ratio": 0.005}} —
   if the baseline file is missing it is bootstrapped from the candidate and the gate passes;
   otherwise the diff metrics (diff_pixel_count / diff_ratio / rmse) decide the verdict.
5. Verdict — the playtest passes only if every assertion holds, no runtime errors were captured,
   and the diff is within tolerance. On failure, identify the smallest visual cause, patch it,
   and re-run steps 3-4 until the gate passes.
"""

const ONBOARD_NEW_PROJECT_TEMPLATE: String = """
You are executing the "New Project Onboarding" workflow against the Godot project through MCP tools.
This is an executable workflow template: call the tools in order.

1. {"tool": "get_project_info", "args": {}} — project name, version, renderer, main scene, feature tags.
2. {"tool": "get_project_structure", "args": {"max_depth": 3}} — folder layout and file-type statistics.
3. {"tool": "list_tool_catalog", "args": {}} — discover the full tool catalog: which groups exist
   and which are currently enabled.
4. {"tool": "enable_tools", "args": {"groups": ["<needed groups>"]}} — enable only the groups the
   upcoming work needs (start from the core baseline; core and meta tools always stay enabled).

Deliver a concise onboarding brief: what the project is, its structure, autoloads and conventions
you noticed, available tooling, and a recommended first task.
"""

const FIX_COMPILE_ERRORS_TEMPLATE: String = """
You are executing the "Fix Compile Errors" workflow against the Godot project through MCP tools.
This is an executable workflow template: run the loop until validation is clean.

Script paths: {{script_paths_block}}

1. Validate — for each path: {"tool": "validate_script", "args": {"script_path": "<path>"}} —
   collect structured errors with line numbers (and warnings).
2. Read — {"tool": "read_script", "args": {"script_path": "<path>"}} — read the script around
   each reported error line to understand the failing construct.
3. Fix — apply the smallest coherent edit (modify_script on the read content / create_script for a new file / execute_editor_script), keeping the
   change backward compatible and consistent with project conventions.
4. Re-validate — re-run validate_script on the edited script until it reports valid with no errors.
5. Check for cascade — validate any scripts that depend on the fixed one, then run the project
   and pull {"tool": "get_editor_logs", "args": {"source": "runtime"}} to confirm no new errors appeared.
"""

# ============================================================================


const CHARACTER_RECIPE_TEMPLATE: String = """
You are executing the "Character Visuals + Hit Feedback" recipe against the Godot project through MCP tools. Everything here ships WITH the plugin — no external scripts.

Goal: {{goal}}

Step 0 — Activate toolset (supplementary tools are off by design):
{"tool": "enable_tools", "args": {"workflow_query": "{{goal}}"}}

Step 1 — Locate the existing player (never assume node names):
{"tool": "gather_task_context", "args": {"goal": "{{goal}} player visual"}}
scene_objects classifies each scene's nodes by role (body/visual/collision/camera/audio). Bind to a scene whose root is the CharacterBody2D when possible; instanced players bind their instance_of source; per-scene player children bind directly.

Step 2 — Ensure the Skin component (idempotent; re-runs update, never duplicate):
Create res://scripts/player/character_skin.gd (Sprite2D script: idle/move rows from one sheet, facing flip, pixel_offset pivot alignment, use_block_visual toggle keeps the original ColorRect reachable), then ensure the node with {"tool": "create_node", "args": {"parent_path": "<player>", "node_type": "Sprite2D", "node_name": "Skin", "on_name_conflict": "skip"}} and attach via batch attach_script — it saves an EXTERNAL reference (updates to the .gd reach the game).

Step 3 — Ensure the HitFeedback component (idempotent): a Node2D script with flash_color/flash_seconds, one-shot particles, camera_shake (auto-creates a Camera2D when the scene has none — shake must never silently no-op), and hitstop (Engine.time_scale dip with an ignore_time_scale timer). Wire it into the existing damage entry by apply_change_set: read_script for the hash, replace the block that plays the hit SFX with the same block plus a play_hit_feedback call. No damage entry yet? Attach the component and say so — do not invent wiring.

Step 4 — Sheet (placeholder when the user has none): {"tool": "generate_asset", "args": {"resource_path": "res://art/player_skin.tres", "prompt": "player sheet", "type": "sprite", "provider": "placeholder", "pattern": "sprite_sheet", "width": 120, "height": 60, "frame_columns": 4, "frame_rows": 2, "colors": [{"r": 0.25, "g": 0.55, "b": 0.95}, {"r": 0.98, "g": 0.85, "b": 0.35}]}} — .tres is immediately referenceable. A user-provided PNG needs an import scan first.

Step 5 — Verify with a requirement contract (the delivery checklist is plugin-built). Shape (fill the items with one behavior_check per requirement, built per the facts below — each item boots a FRESH run and must be self-contained):
{"tool": "run_verification_queue", "args": {"command": "create", "strict": true, "requirements": ["movement", "flash", "shake", "particles", "hitstop"], "items": [{"kind": "behavior_check", "requirement": "movement", "label": "r1", "detail": {"scene_path": "<scene>", "steps": [{"action": "move_right", "pressed": true, "wait_ms": 600, "assert": {"expression": "<expr>", "displacement_min": 60, "description": "movement held"}}]}}]}} Assert per-effect audit fields, not vibes: flash set then recovered, shake magnitude >= 1 and reset, particles emitted, hitstop engaged and restored, movement displacement. Advance slices to a terminal state and read the checklist: ANY requirement not verified = the overall outcome is incomplete — report it as incomplete.
"""

const MELEE_ENEMY_RECIPE_TEMPLATE: String = """
You are executing the "Melee Enemy Behavior" recipe against the Godot project through MCP tools. Ships WITH the plugin.

Goal: {{goal}}

Step 0 — Activate toolset: {"tool": "enable_tools", "args": {"workflow_query": "enemy behavior combat chase attack"}}

Step 1 — Locate the existing enemy via gather_task_context scene_objects (an Area2D body with a visual child; instanced enemies bind their source scene). Create res://scripts/combat/melee_brain.gd — a Node child "MeleeBrain" on the enemy root: patrol (origin-anchored) -> chase when the player enters detect_range -> windup with a warning-color flash -> one hit per swing (attacks_landed counter, hit only within attack_range on the facing side) -> recover -> cooldown. Expose every knob @export: detect_range, chase_range, chase_speed, attack_range, windup_seconds, hit_damage, hit_knockback, recover_seconds, attack_cooldown. Wire death->drop through apply_change_set on the enemy's take_damage dead-branch: notify the brain, which spawns exactly one coin.

Step 2 — Boss-vs-grunt tuning is DATA, not code: grunt and boss are the same script with different EnemyStats resources (knockback_resistance 0 vs 0.9). "Normal enemies knock back easily, boss resists" = edit the stats resources, never branch the behavior script.

Step 3 — Contract-verify with run_verification_queue (strict, requirements: detect+chase, windup telegraphs, single hit per swing, death stops attacking, drop exactly once; each item boots a FRESH run). Timing facts that bite: death-window reads must land inside the ~0.22s before queue_free; each requirement item boots its own run, so an item that needs a dead enemy must kill it itself; enemy instances without a stats resource silently refuse take_damage — wire stats.

Step 4 — Natural-language tuning maps to @export reads: "attack windup more obvious" -> windup_seconds up; "chase shorter" -> chase_range down. After ANY script change, re-verify the affected requirements only.
"""

const MENU_RECIPE_TEMPLATE: String = """
You are executing the "Game Menu & HUD" recipe against the Godot project through MCP tools. Ships WITH the plugin.

Goal: {{goal}}

Step 0 — Activate toolset: {"tool": "enable_tools", "args": {"workflow_query": "ui menu hud button pause interaction"}}

Step 1 — Locate context with gather_task_context (which scene the menu enters FROM, where game state lives). Build the menu with create_scene (root Control) + batch_scene_node_edits (VBoxContainer + Buttons); attach ONE external controller script and wire EVERY button with connect_signal ("pressed" -> handler). attach_script keeps the EXTERNAL reference — an embedded copy makes every later edit to the .gd never reach the game. A button left unwired is a defect, not a style choice: list each button -> effect before building.

Step 2 — Standard wirings: Start -> get_tree().change_scene_to_file(gameplay scene); Quit -> get_tree().quit(); Pause -> get_tree().paused = true (toggle); HUD listens to a state autoload via Signal (never polls). Two PAUSE TRAPS that bite every project: (a) paused freezes EVERYTHING — the pause menu and its buttons must live under a node with process_mode = PROCESS_MODE_WHEN_PAUSED or the resume click never registers; (b) a decorative full-screen overlay drawn ABOVE buttons eats their clicks unless mouse_filter = MOUSE_FILTER_IGNORE.

Step 3 — Interaction verification is CLICK-THROUGH, not screenshots: play_and_verify steps send a mouse_button event at the button's runtime rect_center (read get_global_rect() at runtime, never guess pixel positions), then assert the effect — scene path changed / get_tree().paused == true / state signal fired. Shape:
{"tool": "run_verification_queue", "args": {"command": "create", "strict": true, "requirements": ["menu_renders", "start_changes_scene", "pause_resume_roundtrip", "hud_reflects_state"], "items": [{"kind": "behavior_check", "requirement": "pause_resume_roundtrip", "label": "r3", "detail": {"scene_path": "<menu scene>", "steps": [{"event": {"type": "mouse_button", "position": "<pause rect_center>", "button_index": 1, "pressed": true}, "wait_ms": 300, "assert": {"expression": "get_tree().paused == true", "description": "paused after click"}}, {"event": {"type": "mouse_button", "position": "<resume rect_center>", "button_index": 1, "pressed": true}, "wait_ms": 300, "assert": {"expression": "get_tree().paused == false", "description": "resumed after second click"}}]}}]}} Each item boots a FRESH run, must be self-contained, and carries at least one assertion — zero-assertion runs are smoke and the strict contract rejects them. ANY requirement not verified = the overall outcome is incomplete; report it as incomplete.

Step 4 — After ANY script or theme change, prove it reached the running game with verify_change_effect (names the embedded-copy / unsaved-buffer / instance-override killers when they bite). Visual tuning is theme data, not per-node overrides: create_theme + set_theme_item ("bigger text" = font_size) + set_default_theme.
"""
const ANY_GAME_RECIPE_TEMPLATE: String = """
You are executing the "Any Game" universal making method against the Godot project through MCP tools. Ships WITH the plugin.

Goal: {{goal}}

This is the UNIVERSAL entry: route every piece of the goal to the fastest safe path, and never fake completion. Quality here is genre-independent — the evidence surface (runtime expressions, simulated input, FRESH boots, strict contracts) is identical for a platformer, a puzzle, a card game or something nobody has shipped with this plugin before.

Step 0 — Activate toolset: {"tool": "enable_tools", "args": {"workflow_query": "game creation scene script input verify"}}

Step 1 — Decompose the goal into pillars (movement, combat, enemies, items/pickups, maps/levels, menus/HUD, save, audio, game feel, win/lose, plus the goal's unique mechanic). For each pillar, prefer a SHIPPED recipe when it matches — they carry session-tested operational truths:
  character visuals + hit feedback -> make_game_character
  melee enemy (patrol/detect/chase/windup/hit/death-drop) -> make_melee_enemy
  menus, HUD, pause -> make_game_menu
  one cross-file change -> make_game_change
  a long multi-phase goal -> plan_game_workflow (durable DAG, evidence-gated completion)

Step 2 — For a pillar with NO shipped recipe, run the general loop (this is the method that makes "any game" safe):
  a) gather_task_context — never assume names; find the real scenes, scripts and the input map.
  b) Build the SMALLEST PLAYABLE SLICE of that pillar: one external script (attach_script keeps the EXTERNAL reference), signals wired (never polls), values exposed as @export knobs.
  c) BEFORE tuning, write acceptance as a strict requirement contract: {"tool": "run_verification_queue", "args": {"command": "create", "strict": true, "requirements": ["<r1>", "<r2>"], "items": [{"kind": "behavior_check", "requirement": "<r1>", "detail": {"scene_path": "<res://scenes/main.tscn>", "steps": [{"wait_ms": 300, "assert": {"expression": "<one runtime expression proving r1>", "description": "<what this proves>"}}]}}]}} — one behavior_check per requirement, each item boots a FRESH run and carries at least one assertion; zero-assertion runs are smoke and the strict contract rejects them.
  d) Advance to a terminal state; ANY unverified requirement = the overall outcome is incomplete — report it as incomplete, never summarize past a gap.
  e) Iterate smallest-loop: change ONE knob -> verify_change_effect proves it reached the running game (embedded script copy / unsaved editor buffer / host-scene instance override are named with the exact fix when they bite) -> re-verify only the affected requirements.

Step 3 — Genre guidance is DATA, not permission: turn-based = state machines and timers, not physics; physics-driven = rigid bodies + applied forces (assert DISPLACEMENT, never vibes); puzzle = deterministic input sequences (play_and_verify deterministic=true, frame-stepped); card/strategy = data tables + rules script, UI via the menu recipe; dialogue/narrative = data + the UI recipe; 3D = same atomic tools (nodes/scripts/expressions are dimension-agnostic) with generate_3d_asset for placeholders.

Step 4 — Quality floor (every game, no exceptions): assert_no_runtime_errors after every milestone; assert_performance_budget once gameplay stabilizes; screenshot key screens; release_export_flow (export smoke) before calling the game done.

Step 5 — Close honestly: report the plugin-built checklist verbatim (verified/unverified per requirement), name what you did NOT verify and why, and suggest the next three sentences the user could say (tune a knob / add a pillar / ship it).
"""
const GAME_MAP_RECIPE_TEMPLATE: String = """
You are executing the "Game Map / Level" recipe against the Godot project through MCP tools. Ships WITH the plugin.

Goal: {{goal}}

Step 0 — Activate toolset: {"tool": "enable_tools", "args": {"workflow_query": "level design tilemap tileset scene input verify"}}

Step 1 — Locate context with gather_task_context (which scene the level is entered FROM, where the player and enemy scenes live — never assume names). Create the level scene, then build the tile layer in order: create_tileset -> configure_tileset_layers (physics layer FIRST — walls need collision before painting matters) -> set_tile_collision_polygon per wall tile -> ASSIGN the TileSet to the TileMapLayer or painted cells will not render. Paint with set_tilemap_layer_cells (4.x single-layer API; the runtime probe's region tools are dual-compatible with legacy TileMap).

Step 2 — Populate by instancing: the player at the spawn tile, enemies from their scenes, pickups along the route. HOST rule: the level INSTANCES those scenes, so verify against the LEVEL scene, and property overrides placed here WIN over base-scene values (verify_change_effect's hosts step names any mask with the exact fix).

Step 3 — Contract-verify traversal BEFORE tuning: {"tool": "run_verification_queue", "args": {"command": "create", "strict": true, "requirements": ["movement", "walls_block", "goal_reachable"], "items": [{"kind": "behavior_check", "requirement": "walls_block", "detail": {"scene_path": "<res://scenes/level_01.tscn>", "steps": [{"action": "move_right", "pressed": true, "wait_ms": 600, "assert": {"expression": "<player global position x>", "displacement_max": 8, "description": "wall stops the player"}}]}}]}} — displacement asserts are RELATIVE (displacement_min/displacement_max), never absolute thresholds (a level starting away from the origin fails absolute checks for no reason). After any batch tile write, physics needs one settled frame before collision assertions. Each item boots a FRESH run of the LEVEL.

Step 4 — Tune via data, one change at a time; after ANY script change, verify_change_effect proves it reached the running game. Retuning many level files at once: batch_update_scene_files with expect_current keeps per-level specials (a boss arena keeps its wider corridor while every standard corridor narrows).

Step 5 — Close honestly: report the plugin-built checklist verbatim, name unverified requirements, suggest the next sentences (tune difficulty / add a hazard / wire the goal to win-lose).
"""

const GAME_PICKUP_RECIPE_TEMPLATE: String = """
You are executing the "Pickup / Collectible" recipe against the Godot project through MCP tools. Ships WITH the plugin.

Goal: {{goal}}

Step 0 — Activate toolset: {"tool": "enable_tools", "args": {"workflow_query": "item pickup area2d signal scene verify"}}

Step 1 — Locate context with gather_task_context (player scene, where state lives, whether an autoload exists). Build the pickup: Area2D root + visual child + monitoring on; collect on the body_entered SIGNAL (never poll in _physics_process); the collected pickup queue_frees itself — reads about the NODE must land inside the free window or assert on the COUNTER instead (the death-window lesson: reads after queue_free see nothing).

Step 2 — State: the counter lives on the player or a state autoload and is updated THROUGH a signal (decoupled, per project convention). Double-collect protection: disable/queue_free in the same callback that increments — assert it with two quick walks over the same spot.

Step 3 — Contract BEFORE tuning: {"tool": "run_verification_queue", "args": {"command": "create", "strict": true, "requirements": ["pickup_increments_counter", "pickup_disappears", "no_double_collect"], "items": [{"kind": "behavior_check", "requirement": "pickup_increments_counter", "detail": {"scene_path": "<res://scenes/level_01.tscn>", "steps": [{"action": "move_right", "pressed": true, "wait_ms": 800, "assert": {"expression": "<counter expression, e.g. get_node('/root/GameState').coins>", "expected": 1, "operator": "gte", "description": "coin counted"}}]}}]}} — each item boots a FRESH run and is self-contained (an item that needs two coins collected must walk past both itself).

Step 4 — Place pickups by instancing in levels; per-level specials (value, respawn flag) survive batch retunes via expect_current. Feel knobs (magnet radius, bob speed) are @export data — tune one, then verify_change_effect proves the change reached the running game.

Step 5 — Close honestly: checklist verbatim, unverified named, next sentences suggested (add a rare pickup / wire coins to a shop / persist the collection).
"""

const GAME_SAVE_RECIPE_TEMPLATE: String = """
You are executing the "Save / Continue" recipe against the Godot project through MCP tools. Ships WITH the plugin.

Goal: {{goal}}

Step 0 — Activate toolset: {"tool": "enable_tools", "args": {"workflow_query": "save load file scene verify"}}

Step 1 — THE PATH RULE: save files MUST live under user:// (res:// is READ-ONLY in exported builds — writing there works in the editor and silently fails after export, the trap that only bites at ship time). Write via FileAccess with a version field, and save an EXPLICIT field list (position, hp, collected ids) — never serialized object references.

Step 2 — Triggers: a save point, autosave on milestone, or a menu entry (wire the menu via make_game_menu). Load path: on boot, if the save exists, restore state BEFORE the first frame of gameplay (continue), else start fresh. The save MODULE is one external script (attach_script keeps the EXTERNAL reference) reading/writing user:// and exposing save()/load() through signals.

Step 3 — Contract, exploiting the one thing that DOES cross FRESH boots — the user:// FILE (runtime state does not): {"tool": "run_verification_queue", "args": {"command": "create", "strict": true, "requirements": ["save_writes_file", "fresh_boot_restores", "no_save_means_new_game"], "items": [{"kind": "behavior_check", "requirement": "save_writes_file", "detail": {"scene_path": "<res://scenes/level_01.tscn>", "steps": [{"action": "interact_save", "pressed": true, "wait_ms": 400, "assert": {"expression": "FileAccess.file_exists('user://save.json')", "description": "save file written"}}]}}, {"kind": "behavior_check", "requirement": "fresh_boot_restores", "detail": {"scene_path": "<res://scenes/level_01.tscn>", "steps": [{"wait_ms": 300, "assert": {"expression": "<restored state expression, e.g. get_node('/root/GameState').hp>", "expected": 2, "description": "continued from the save"}}]}}]}} — item 2 boots FRESH and still sees the save because the FILE persisted; that is the whole proof of continue.

Step 4 — After ANY change to the save module, verify_change_effect proves it reached the running game; changing the save SCHEMA bumps the version field and migrates old files (a player's save must never crash a new build).

Step 5 — Close honestly: checklist verbatim, unverified named, next sentences suggested (add a save point / autosave on level end / show the save slot in the menu).
"""




# Prompt 注册表
# ============================================================================

const ITERATE_PLAY_VERIFY_TEMPLATE: String = """
You are executing the "Iterate: Play, Verify, Fix" loop against the Godot project through MCP tools.
Repeat the loop until every gate passes or you have isolated a root cause you cannot fix.

Target: {{target}}
Gates: {{gates}}

1. Play — {"tool": "run_project", "args": {"scene_path": "<scene if not the main scene>"}}.
   For an orchestrated one-shot, {"tool": "play_and_verify"} already runs, samples and gates.
2. Observe — {"tool": "get_editor_logs", "args": {"source": "runtime"}} for errors;
   {"tool": "get_runtime_info"} and {"tool": "evaluate_runtime_expression", "args": {"expression": "<state to check>"}}
   for live state while the game runs.
3. Gate — {"tool": "assert_no_runtime_errors", "args": {"max_errors": 0}} and, when a frame
   budget applies, {"tool": "assert_performance_budget", "args": {"budget": {"min_fps": 55}}}.
   Scenario-specific expectations: {"tool": "assert_runtime_condition", "args": {"expression": "<expr>"}}.
4. Fix — when a gate fails, read the reported error/state, patch the smallest coherent cause
   (script or scene edit), stop with {"tool": "stop_project"}, and restart from step 1.
5. Cap — after 3 consecutive identical failures with no progress, stop and report the isolated
   root cause instead of looping.

Done when: assert_no_runtime_errors passes, every requested gate reports pass, and the last
play session reached the scenario's expected state.
"""

const RELEASE_EXPORT_FLOW_TEMPLATE: String = """
You are executing the "Release Export Checklist" workflow against the Godot project through MCP tools.

Platform: {{platform}}
Notes: {{notes}}

1. Templates — {"tool": "manage_export_templates", "args": {"action": "status"}}: matching_version_installed
   must be true; when false, download with {"action": "download"} and poll {"action": "download_status"}.
2. Preset — {"tool": "inspect_export_presets"} then {"tool": "validate_export_preset"}: resolve every
   reported issue (export_path, template availability, platform fields) before exporting.
3. Version — {"tool": "bump_version"}: raise the project version per the requested step and record
   the changelog entry it returns.
4. Export — {"tool": "run_export"} for the target preset; the result carries the artifact path.
5. Smoke — {"tool": "smoke_test_export", "args": {"launch": true}}: the product must exist and the
   launched process must exit with the expected code.
6. Report — summarize artifact path, size, version and smoke verdict in one block.

Done when: steps 1-5 all pass; any blocking failure is reported with the exact tool message.
"""

const MAKE_GAME_CHANGE_TEMPLATE: String = """
You are executing the "Recoverable Change" workflow against the Godot project through MCP tools.
This is an executable workflow template: follow the steps in order; never skip the preview or the verification, and never report a write as done before its gates pass.

Change: {{change}}
Acceptance: {{acceptance}}

Step 0 — Activate the toolset (supplementary tools are off by design, not broken):
{"tool": "enable_tools", "args": {"workflow_query": "{{change}}"}} — one call routes the tools this loop needs. If a call ever answers "Tool is disabled", the error embeds the exact enable call; unknown argument names surface in _schema_warnings with the schema's real property list.

Step 1 — Frame acceptance first. If no acceptance was given, write 1-3 objective, observable conditions before touching anything (e.g. "validate_script passes on touched scripts", "player moves 100px right under fixed input", "zero runtime errors").

Step 2 — Orient (read-only):
{"tool": "gather_task_context", "args": {"goal": "{{change}}"}} — entry scripts, referencing scenes, input actions, related resources and affected tests for this goal.
{"tool": "query_change_impact", "args": {"target_paths": ["<entry script or scene paths from the step above>"]}} — transitive dependents with evidence. Follow has_more/next_offset to the end; treat unknown_targets and dynamic_unknowns as risk to inspect, not as proof of safety.

Step 3 — Pin read versions before editing:
{"tool": "read_script", "args": {"script_path": "<path>"}} — or {"tool": "batch_read_scripts", "args": {"script_paths": ["<paths>"]}} for several. Keep each returned content_hash: every modify operation must carry the expected_content_hash of the read that produced it.

Step 4 — Preview, then commit:
{"tool": "apply_change_set", "args": {"intent": "{{change}}", "operations": [{"path": "<path>", "expected_content_hash": "<hash from step 3>", "edits": [{"old_text": "<snippet that occurs exactly once>", "new_text": "<replacement>"}]}], "change_set_id": "<stable id you reuse>", "dry_run": true}}
Review the preview (fingerprints, per-file edit counts), then commit the SAME change_set_id and operations with "dry_run": false. On interruption re-submit the same id: applied files are skipped and manually-edited files stop at an explicit conflict — never widen edits to work around a conflict.
Scene/node edits that the text schema cannot express go through the focused scene tools instead; do not force them into the change set.

Step 5 — Compile gate: {"tool": "validate_script", "args": {"script_path": "<each touched script>"}} — zero errors required before any behavior claim.

Step 6 — Behavior gate — pick the cheapest tool that actually observes the acceptance:
{"tool": "play_and_verify", "args": {"steps": [{"action": "<input action>", "wait_frames": 30, "screenshot": true}], "assertions": [{"expression": "<runtime expression for one acceptance condition>", "description": "<the acceptance condition>"}], "deterministic": true}}
For multi-slice verification use {"tool": "run_verification_queue", "args": {"command": "create", "goal": "{{change}}", "items": [{"kind": "script_check", "label": "<what>", "detail": {"scripts": ["<paths>"]}}, {"kind": "external", "label": "<behavior to run>", "detail": "<how>"}]}} then {"command": "advance"}; an external item is recorded with {"command": "record"} only after you actually ran it — recording a verdict is not the same as producing one.
Runtime errors, if any: {"tool": "get_editor_logs", "args": {"source": "runtime"}}.

Step 7 — Persist and report:
If a task plan exists, feed measured outcomes back: {"tool": "manage_task_plan", "args": {"action": "set_dod", "id": "<task id>"}} and {"tool": "manage_task_plan", "args": {"action": "set_status", "id": "<task id>", "status": "<new status>"}}.
Report in one block: files changed and why (intent), evidence per acceptance condition (tool receipts, screenshots), what was NOT verified, and how to resume or inspect (the change_set_id).

Operational notes (verified against a live editor): create_scene writes the file but does not open it — open_scene {"scene_path": ..., "allow_ui_focus": true} before creating nodes; run_project/stop_project take {"allow_window": true}; install the runtime probe BEFORE run_project and wait for the debugger session before driving input; set_property accepts [x, y] arrays; WASD bindings use {"type": "key", "physical_keycode": <int>}.

Rules: after 3 identical consecutive failures stop retrying and report the isolated root cause; a committed change is "written, pending verification" until steps 5-6 pass; conflicts and missing prerequisites are reported, never silently skipped.
"""

var _prompts: Dictionary = {}  # name -> {name, description, arguments, callable}

func _init() -> void:
	_register_all()

func _register_all() -> void:
	_add_prompt(
		"plan_game_feature",
		"Turn a one-sentence GDD / feature request into an executable manage_task_plan task graph with gated Definition-of-Done, then hand off the first ready task.",
		[
			{"name": "gdd_summary", "description": "One-paragraph game design document / feature request the plan must implement.", "required": true},
			{"name": "goal", "description": "Overall goal statement for the task plan (e.g. '2D platformer vertical slice').", "required": true}
		],
		Callable(self, "_get_plan_game_feature")
	)
	_add_prompt(
		"debug_runtime_error",
		"Debug a runtime error end-to-end: collect logs, locate the failing code, fix the root cause and re-verify until the error is gone.",
		[
			{"name": "error_text", "description": "The exact error message / stack trace reported by the runtime.", "required": true},
			{"name": "context", "description": "Optional context: what was happening, scene/script involved, expected behavior.", "required": false}
		],
		Callable(self, "_get_debug_runtime_error")
	)
	_add_prompt(
		"review_scene",
		"Audit the currently open scene: full structure, node checklist, persistence and inheritance issues, with a prioritized fix list.",
		[
			{"name": "focus", "description": "Optional area to focus the review on (e.g. a node subtree, persistence, inheritance).", "required": false}
		],
		Callable(self, "_get_review_scene")
	)
	_add_prompt(
		"run_test_suite",
		"Discover and run the project test suite, collect structured pass/fail results, and drive failing tests back to green.",
		[
			{"name": "target_dir", "description": "Optional res:// test directory to scope discovery and runs. Default res://test.", "required": false}
		],
		Callable(self, "_get_run_test_suite")
	)
	_add_prompt(
		"visual_playtest",
		"Run a visual regression playtest: launch the game, drive the scenario with the runtime probe, screenshot, compare against the golden baseline and judge the result.",
		[
			{"name": "scenario", "description": "The playtest scenario to drive: inputs, expected states, and what to screenshot.", "required": true}
		],
		Callable(self, "_get_visual_playtest")
	)
	_add_prompt(
		"onboard_new_project",
		"Onboard onto a new Godot project: gather project info and structure, discover the tool catalog, and enable only the tool groups the upcoming work needs.",
		[],
		Callable(self, "_get_onboard_new_project")
	)
	_add_prompt(
		"fix_compile_errors",
		"Fix GDScript compile/validation errors in a feedback loop: validate, read, patch, re-validate, and check dependent scripts for cascading failures.",
		[
			{"name": "script_paths", "description": "Optional comma-separated script paths to fix. When omitted, discover offending scripts from validation errors.", "required": false}
		],
		Callable(self, "_get_fix_compile_errors")
	)
	_add_prompt(
		"iterate_play_verify",
		"Run the play -> verify -> fix loop: launch the project, pull runtime logs and live state, gate on no-runtime-errors / performance / scenario conditions, patch the smallest cause and repeat until green.",
		[
			{"name": "target", "description": "What to verify, e.g. 'enemy wave spawner keeps 55 fps with zero runtime errors'.", "required": true},
			{"name": "gates", "description": "Optional gate list, e.g. 'no_runtime_errors, min_fps=55, player.y never < 0'. Defaults to no-runtime-errors.", "required": false}
		],
		Callable(self, "_get_iterate_play_verify")
	)
	_add_prompt(
		"release_export_flow",
		"Walk the release export checklist: template availability, preset validation, version bump, export, launched smoke test and a final report.",
		[
			{"name": "platform", "description": "Target platform/preset, e.g. 'Windows Desktop'.", "required": false},
			{"name": "notes", "description": "Optional release notes or version step, e.g. 'patch bump, fix controller pause'.", "required": false}
		],
		Callable(self, "_get_release_export_flow")
	)
	_add_prompt(
		"make_game_change",
		"One requirement through the recoverable change loop: frame acceptance, gather context and impact, pin read versions, preview + commit an apply_change_set, then verify (compile + behavior) and report evidence with resume handles.",
		[
			{"name": "change", "description": "What to change, in natural language (EN/ZH), e.g. 'increase player acceleration and keep collision intact'.", "required": true},
			{"name": "acceptance", "description": "Optional objective acceptance conditions. When omitted you must write them before editing.", "required": false}
		],
		Callable(self, "_get_make_game_change")
	)
	_add_prompt(
		"make_game_character",
		"Attach visuals, animation and full hit feedback to an EXISTING player through atomic tools (idempotent; requirement-contract verified) — the shipped character recipe.",
		[
			{"name": "goal", "description": "What the character should look and feel like, e.g. 'sprite-sheet knight with punchy hit feedback'.", "required": true}
		],
		Callable(self, "_get_make_game_character")
	)
	_add_prompt(
		"make_melee_enemy",
		"Turn an existing enemy into a melee fighter: patrol, detect, chase, telegraphed windup, single-hit swing, recover, death drop — all knobs live-tunable; grunt-vs-boss is stats data.",
		[
			{"name": "goal", "description": "The enemy behavior wanted, e.g. 'chaser that telegraphs then strikes once'.", "required": true}
		],
		Callable(self, "_get_melee_enemy")
	)
	_add_prompt(
		"make_game_menu",
		"Build a menu/HUD that actually works when clicked: buttons wired to external scripts, pause that survives being paused, HUD fed by signals — then click-through verified with a requirement contract.",
		[
			{"name": "goal", "description": "The menu or HUD wanted, e.g. 'main menu with start/quit plus a pause overlay'.", "required": true}
		],
		Callable(self, "_get_make_game_menu")
	)
	_add_prompt(
		"make_any_game",
		"The universal entry for ANY game: route each pillar to a shipped recipe when one matches, run the general make->strict-contract->verify loop for pillars that have none, keep the genre-independent quality floor (no runtime errors, performance budget, export smoke), and close with the plugin-built checklist. Quality does not depend on the genre being known.",
		[
			{"name": "goal", "description": "The game or game part wanted, any genre, e.g. 'a physics golf game with 9 holes and par tracking'.", "required": true}
		],
		Callable(self, "_get_make_any_game")
	)
	_add_prompt(
		"make_game_map",
		"Build a playable level: tileset with collision FIRST, painted walls, instanced player/enemies/pickups at spawn — then traversal contract-verified (movement, walls block, goal reachable) with RELATIVE displacement asserts against the LEVEL scene (host overrides named).",
		[
			{"name": "goal", "description": "What is wanted, e.g. 'a 30x20 tile level with walls and a goal tile' / 'coins worth 1 and a rare gem worth 5' / 'autosave on level end and continue from the menu'.", "required": true}
		],
		Callable(self, "_get_make_game_map")
	)
	_add_prompt(
		"make_game_pickup",
		"Make collectibles that actually count: Area2D + body_entered signal (never polls), counter on the player/autoload via signal, double-collect protection, death-window-aware assertions — strict contract (increments / disappears / no double collect) per FRESH run.",
		[
			{"name": "goal", "description": "What is wanted, e.g. 'a 30x20 tile level with walls and a goal tile' / 'coins worth 1 and a rare gem worth 5' / 'autosave on level end and continue from the menu'.", "required": true}
		],
		Callable(self, "_get_make_game_pickup")
	)
	_add_prompt(
		"make_game_save",
		"Add save/continue that survives export: user:// files (res:// is read-only in builds), explicit field lists with versioning, restore before first gameplay frame — proven by the one thing that crosses FRESH boots, the save FILE itself.",
		[
			{"name": "goal", "description": "What is wanted, e.g. 'a 30x20 tile level with walls and a goal tile' / 'coins worth 1 and a rare gem worth 5' / 'autosave on level end and continue from the menu'.", "required": true}
		],
		Callable(self, "_get_make_game_save")
	)

func _add_prompt(name: String, description: String, arguments: Array[Dictionary], callable: Callable) -> void:
	_prompts[name] = {
		"name": name,
		"description": description,
		"arguments": arguments,
		"callable": callable
	}

# 每个配方的双语触发关键词；enable_tools 路由命中时向客户端提示可用配方。
const PROMPT_KEYWORDS: Dictionary = {
	"iterate_play_verify": ["iterate", "playtest", "verify loop", "gate", "fps", "runtime error",
		"迭代", "试玩", "验证循环", "帧率", "运行时错误", "性能"],
	"release_export_flow": ["export", "release", "ship", "build", "smoke test", "version bump",
		"导出", "发布", "出货", "打包", "冒烟", "版本"],
	"fix_compile_errors": ["compile", "parse error", "syntax", "validation error",
		"编译", "语法错误", "解析错误", "校验错误"],
	"debug_runtime_error": ["runtime error", "stack trace", "crash", "debug",
		"运行错误", "堆栈", "崩溃", "调试"],
	"plan_game_feature": ["gdd", "feature request", "task graph", "vertical slice", "plan",
		"需求", "功能设计", "任务图", "规划", "计划"],
	"visual_playtest": ["visual regression", "screenshot", "baseline", "golden",
		"视觉回归", "截图", "基线", "黄金"],
	"review_scene": ["scene audit", "review scene", "persistence issue",
		"场景审计", "场景检查", "持久化"],
	"run_test_suite": ["run tests", "test suite", "unit test", "gut",
		"跑测试", "测试套件", "单元测试"],
	"onboard_new_project": ["onboard", "new project", "discover tools",
		"上手", "新项目", "工具发现"],
	"make_game_change": ["change set", "impact analysis", "cross-file change", "recoverable change",
		"变更单", "影响分析", "跨文件", "可恢复"],
	"make_game_character": ["character visual", "sprite sheet", "hit feedback", "skin", "flash", "camera shake",
		"角色外观", "精灵图", "受击反馈", "闪白", "震屏", "皮肤"],
	"make_melee_enemy": ["melee enemy", "enemy behavior", "chase", "windup", "enemy drop",
		"近战敌人", "敌人行为", "追击", "前摇", "掉落"],
	"make_game_menu": ["menu", "hud", "main menu", "pause menu", "button wiring", "ui screen",
		"菜单", "主菜单", "暂停菜单", "界面", "按钮"],
	"make_any_game": ["make any game", "make me a game", "build a game", "whatever game", "any genre",
		"做一个游戏", "随便做个游戏", "任意游戏", "任何游戏", "给我做个游戏"],
	"make_game_map": ["map", "level", "tilemap", "tileset", "level design",
		"地图", "关卡", "瓦片", "地牢"],
	"make_game_pickup": ["pickup", "collectible", "coin", "gem", "item placement",
		"拾取", "金币", "收集品", "道具"],
	"make_game_save": ["save file", "save system", "checkpoint", "continue game", "autosave",
		"存档", "检查点", "继续游戏", "自动保存"]
}

## 目标语句命中的第一个配方（关键词出现即命中，长关键词优先）；
## 未命中返回空字典。
func match_prompt(query: String) -> Dictionary:
	var text: String = query.to_lower()
	var best: Dictionary = {}
	var best_len: int = 0
	for prompt_name in PROMPT_KEYWORDS:
		for keyword in PROMPT_KEYWORDS[prompt_name]:
			var keyword_text: String = String(keyword).to_lower()
			if text.contains(keyword_text) and keyword_text.length() > best_len:
				best = {"name": prompt_name, "description": String(_prompts.get(prompt_name, {}).get("description", ""))}
				best_len = keyword_text.length()
	return best

# ============================================================================
# 查询 API
# ============================================================================

## 所有已注册 prompt 的元数据（name/description/arguments），按名称排序，供 prompts/list 使用。
func get_prompts() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for name in _prompts:
		var entry: Dictionary = _prompts[name]
		result.append({
			"name": entry["name"],
			"description": entry["description"],
			"arguments": entry["arguments"]
		})
	result.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return String(a.get("name", "")) < String(b.get("name", ""))
	)
	return result

## 单个 prompt 的元数据；未注册返回空字典。
func get_prompt(name: String) -> Dictionary:
	return _prompts.get(name, {})

## 单个 prompt 的 get_callable；未注册返回无效 Callable。
func get_callable(name: String) -> Callable:
	var entry: Variant = _prompts.get(name, null)
	if entry is Dictionary:
		return entry.get("callable", Callable())
	return Callable()

## 把全部 prompt 注册到 server core（register_prompt），返回注册数量。
func register_to_server(server: RefCounted) -> int:
	if server == null or not server.has_method("register_prompt"):
		return 0
	var count: int = 0
	for name in _prompts:
		var entry: Dictionary = _prompts[name]
		server.register_prompt(
			String(entry["name"]),
			String(entry["description"]),
			entry["arguments"],
			entry["callable"]
		)
		count += 1
	return count

# ============================================================================
# get_callable 实现（args: Dictionary -> Dictionary）
# ============================================================================

## 渲染模板：校验必填参数 -> 替换 {{arg}} 占位符 -> 返回 MCP messages 结构。
## 缺少必填参数时返回 {"error": "..."}，与工具处理函数的错误字典约定一致。
func _render(template: String, args: Dictionary, required: Array[String]) -> Dictionary:
	for arg_name in required:
		if not args.has(arg_name) or str(args.get(arg_name, "")).strip_edges().is_empty():
			return {"error": "Missing required prompt argument: " + arg_name}
	var content: String = template
	for key in args:
		content = content.replace("{{" + key + "}}", str(args[key]))
	return {
		"messages": [{
			"role": "user",
			"content": {"type": "text", "text": content}
		}]
	}

func _get_plan_game_feature(args: Dictionary) -> Dictionary:
	return _render(PLAN_GAME_FEATURE_TEMPLATE, args, ["gdd_summary", "goal"])

func _get_debug_runtime_error(args: Dictionary) -> Dictionary:
	var content: String = DEBUG_RUNTIME_ERROR_TEMPLATE
	var context: String = str(args.get("context", "")).strip_edges()
	content = content.replace("{{context_block}}", "\nContext: " + context if not context.is_empty() else "")
	return _render(content, args, ["error_text"])

func _get_review_scene(args: Dictionary) -> Dictionary:
	var content: String = REVIEW_SCENE_TEMPLATE
	var focus: String = str(args.get("focus", "")).strip_edges()
	content = content.replace("{{focus_block}}", "Focus: " + focus if not focus.is_empty() else "")
	return _render(content, args, [])

func _get_run_test_suite(args: Dictionary) -> Dictionary:
	var content: String = RUN_TEST_SUITE_TEMPLATE
	var target_dir: String = str(args.get("target_dir", "")).strip_edges()
	if target_dir.is_empty():
		content = content.replace("{{target_dir_block}}", "No target directory given — using the default res://test.")
		content = content.replace("{{target_dir}}", "res://test")
	else:
		content = content.replace("{{target_dir_block}}", "Target directory: " + target_dir)
		content = content.replace("{{target_dir}}", target_dir)
	return _render(content, args, [])

func _get_visual_playtest(args: Dictionary) -> Dictionary:
	return _render(VISUAL_PLAYTEST_TEMPLATE, args, ["scenario"])

func _get_iterate_play_verify(args: Dictionary) -> Dictionary:
	var content: String = ITERATE_PLAY_VERIFY_TEMPLATE
	var gates: String = str(args.get("gates", "")).strip_edges()
	if gates.is_empty():
		gates = "no runtime errors (max_errors=0)"
	content = content.replace("{{gates}}", gates)
	return _render(content, args, ["target"])

func _get_release_export_flow(args: Dictionary) -> Dictionary:
	var content: String = RELEASE_EXPORT_FLOW_TEMPLATE
	var platform: String = str(args.get("platform", "")).strip_edges()
	if platform.is_empty():
		platform = "the project's default export preset"
	var notes: String = str(args.get("notes", "")).strip_edges()
	if notes.is_empty():
		notes = "none"
	content = content.replace("{{platform}}", platform).replace("{{notes}}", notes)
	return _render(content, args, [])

func _get_onboard_new_project(args: Dictionary) -> Dictionary:
	return _render(ONBOARD_NEW_PROJECT_TEMPLATE, args, [])

func _get_fix_compile_errors(args: Dictionary) -> Dictionary:
	var content: String = FIX_COMPILE_ERRORS_TEMPLATE
	var paths: String = str(args.get("script_paths", "")).strip_edges()
	if paths.is_empty():
		content = content.replace("{{script_paths_block}}", "None specified — discover offending scripts from validation errors.")
	else:
		content = content.replace("{{script_paths_block}}", paths)
	return _render(content, args, [])

func _get_make_game_character(args: Dictionary) -> Dictionary:
	return _render(CHARACTER_RECIPE_TEMPLATE, args, ["goal"])


func _get_melee_enemy(args: Dictionary) -> Dictionary:
	return _render(MELEE_ENEMY_RECIPE_TEMPLATE, args, ["goal"])


func _get_make_game_menu(args: Dictionary) -> Dictionary:
	return _render(MENU_RECIPE_TEMPLATE, args, ["goal"])


func _get_make_any_game(args: Dictionary) -> Dictionary:
	return _render(ANY_GAME_RECIPE_TEMPLATE, args, ["goal"])


func _get_make_game_map(args: Dictionary) -> Dictionary:
	return _render(GAME_MAP_RECIPE_TEMPLATE, args, ["goal"])


func _get_make_game_pickup(args: Dictionary) -> Dictionary:
	return _render(GAME_PICKUP_RECIPE_TEMPLATE, args, ["goal"])


func _get_make_game_save(args: Dictionary) -> Dictionary:
	return _render(GAME_SAVE_RECIPE_TEMPLATE, args, ["goal"])


func _get_make_game_change(args: Dictionary) -> Dictionary:
	var content: String = MAKE_GAME_CHANGE_TEMPLATE
	var acceptance: String = str(args.get("acceptance", "")).strip_edges()
	if acceptance.is_empty():
		acceptance = "none given — write 1-3 objective conditions in Step 1 before editing"
	content = content.replace("{{acceptance}}", acceptance)
	return _render(content, args, ["change"])
