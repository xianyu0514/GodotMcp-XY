extends "res://addons/gut/test.gd"

## M7 暂停行为验收测试：
## 1) 蓝图暂停动词（ui_cancel 暂停/恢复、PROCESS_MODE_ALWAYS、PauseLayer）
## 2) play_and_verify 步内 assert（mid-sequence 行为断言按序求值、
##    失败即失败、与末尾断言统一记账）

const BlueprintsScript = preload("res://addons/godot_mcp/native_mcp/goal_blueprints.gd")
const VerifyToolsScript = preload("res://addons/godot_mcp/tools/debug_verify_tools.gd")
const ScriptToolsScript = preload("res://addons/godot_mcp/tools/script_tools_native.gd")

# ============================================================================
# 蓝图：暂停动词
# ============================================================================

func test_pause_keywords_match_bilingually() -> void:
	assert_true(BlueprintsScript._mentions("Add a pause menu with Esc", BlueprintsScript.PAUSE_KEYWORDS))
	assert_true(BlueprintsScript._mentions("做一个暂停菜单", BlueprintsScript.PAUSE_KEYWORDS))
	assert_false(BlueprintsScript._mentions("collect coins and win", BlueprintsScript.PAUSE_KEYWORDS))
	var verbs: Dictionary = BlueprintsScript.match_verbs("暂停菜单")
	assert_true(bool(verbs["pause"]))

func test_pause_goal_generates_controller_with_pause_logic() -> void:
	var source: String = BlueprintsScript.controller_script("做一个 Esc 暂停菜单")
	assert_false(source.is_empty(), "pause-only goals still generate a real controller")
	assert_true(source.contains("PROCESS_MODE_ALWAYS"),
		"controller must keep processing while paused, otherwise Esc cannot resume")
	assert_true(source.contains("ui_cancel"), "pause uses the built-in Esc action")
	assert_true(source.contains("set_paused"), "pause toggle function exists")
	assert_true(source.contains("PauseLabel"), "pause menu layer exists")
	assert_true(source.contains("Input.is_action_just_pressed(\"ui_cancel\")"),
		"pause is driven by action-state polling (event dispatch is unreliable for simulated actions)")
	assert_true(source.contains("if get_tree().paused:"), "world must stop while paused")

func test_movement_and_pause_combine() -> void:
	var source: String = BlueprintsScript.controller_script("arrow-key movement with a pause menu")
	assert_true(source.contains("_physics_process"), "movement block retained")
	assert_true(source.contains("set_paused"), "pause block appended")

func test_non_pause_goal_has_no_pause_block() -> void:
	var source: String = BlueprintsScript.controller_script("arrow-key movement only")
	assert_false(source.contains("set_paused"))

# ============================================================================
# play_and_verify：步内断言
# ============================================================================

class FakeRuntimeTools extends RefCounted:
	## expression -> 断言结果；未脚本化的表达式默认通过
	var scripted_results: Dictionary = {}
	var assert_calls: Array = []
	var action_calls: Array = []

	func _tool_get_runtime_info(_params: Dictionary) -> Dictionary:
		return {"status": "success", "fps": 60.0, "node_count": 5, "current_scene": "res://game.tscn"}

	func _tool_simulate_runtime_input_action(params: Dictionary) -> Dictionary:
		action_calls.append({"action": params.get("action_name", ""), "pressed": params.get("pressed", true)})
		return {"status": "success"}

	func _tool_simulate_runtime_input_event(_params: Dictionary) -> Dictionary:
		return {"status": "success"}

	func _tool_assert_runtime_condition(params: Dictionary) -> Dictionary:
		var expression: String = str(params.get("expression", ""))
		assert_calls.append(expression)
		if scripted_results.has(expression):
			var scripted: Variant = scripted_results[expression]
			# 序列脚本化：数组按调用次序弹出（前读/后读需不同结果的场景）
			if scripted is Array:
				if (scripted as Array).is_empty():
					return {"passed": true, "actual": true, "expected": params.get("expected", null)}
				var next: Variant = (scripted as Array).pop_front()
				return next if next is Dictionary else {"passed": true, "actual": true, "expected": params.get("expected", null)}
			return scripted
		return {"passed": true, "actual": true, "expected": params.get("expected", null)}

	func _tool_get_runtime_screenshot(params: Dictionary) -> Dictionary:
		return {"status": "success", "save_path": str(params.get("save_path", "")), "size": "100x100"}

var _verify: RefCounted
var _fake: FakeRuntimeTools

func before_each() -> void:
	_verify = VerifyToolsScript.new()
	_fake = FakeRuntimeTools.new()
	_verify._runtime_tools = _fake

func _run(steps: Array, assertions: Array = []) -> Dictionary:
	return await _verify._tool_play_and_verify({
		"steps": steps,
		"assertions": assertions,
		"settle_ms": 0,
	})

func test_inline_step_assert_evaluates_in_order_and_passes() -> void:
	var report: Dictionary = await _run([
		{"action": "ui_cancel", "pressed": true, "wait_ms": 10, "assert": {
			"expression": "get_tree().paused", "expected": true,
			"description": "world pauses after Esc"}},
		{"action": "ui_cancel", "pressed": false, "wait_ms": 10},
	])
	assert_eq(str(report.get("status", "")), "success", str(report.get("errors", "")))
	assert_true(bool(report["passed"]))
	assert_eq(int(report["assertions_total"]), 1, "step assert is counted")
	assert_eq(int(report["assertions_passed"]), 1)
	var first: Dictionary = report["assertions"][0]
	assert_eq(int(first["step"]), 0, "result records which step asserted")
	assert_eq(str(first["context"]), "step 0")
	assert_eq(str(first["description"]), "world pauses after Esc")
	assert_eq(_fake.assert_calls, ["get_tree().paused"], "assert evaluated right after its step")

func test_failing_inline_step_assert_fails_the_gate() -> void:
	_fake.scripted_results["get_tree().paused"] = {"passed": false, "actual": false, "expected": true}
	var report: Dictionary = await _run([
		{"action": "ui_cancel", "pressed": true, "wait_ms": 10, "assert": {
			"expression": "get_tree().paused", "expected": true}},
	])
	assert_false(bool(report["passed"]), "a failed mid-sequence assert fails the whole report")
	assert_eq(int(report["assertions_passed"]), 0)

func test_inline_assert_with_missing_expression_fails_honestly() -> void:
	var report: Dictionary = await _run([
		{"action": "ui_cancel", "pressed": true, "wait_ms": 10, "assert": {"expected": true}},
	])
	assert_false(bool(report["passed"]))
	assert_true(str(report["assertions"][0]["error"]).contains("Missing"), "empty expression is reported, not ignored")

func test_step_asserts_and_final_assertions_share_one_ledger() -> void:
	var report: Dictionary = await _run(
		[{"action": "ui_cancel", "pressed": true, "wait_ms": 10, "assert": {
			"expression": "get_tree().paused", "expected": true}}],
		[{"expression": "get_tree().paused", "expected": false, "description": "resumed at end"}])
	assert_eq(int(report["assertions_total"]), 2, "step + final assertions counted together")
	assert_eq(int(report["assertions_passed"]), 2)
	assert_true(bool(report["passed"]))

func test_pause_exercise_steps_shape() -> void:
	# 与 game_workflow_tools._pause_play_steps 相同的形态经真实编排器执行：
	# 两次 Esc + 两个步内断言 + 一次暂停画面截图。
	var steps: Array = [
		{"action": "ui_cancel", "pressed": true, "wait_ms": 10, "screenshot": true, "assert": {
			"expression": "get_tree().paused", "expected": true}},
		{"action": "ui_cancel", "pressed": false, "wait_ms": 10},
		{"action": "ui_cancel", "pressed": true, "wait_ms": 10, "assert": {
			"expression": "get_tree().paused", "expected": false}},
		{"action": "ui_cancel", "pressed": false, "wait_ms": 10},
	]
	var report: Dictionary = await _run(steps)
	assert_true(bool(report["passed"]), str(report.get("assertions", [])))
	assert_eq(int(report["steps_executed"]), 4)
	assert_eq(int(report["assertions_total"]), 2)
	assert_eq((report["screenshots"] as Array).size(), 1, "paused-state screenshot captured as evidence")

# ============================================================================
# _resolve_node_within："/root" 必须映射被编辑场景根（真机 E2E 抓到的静默错挂）
# ============================================================================

func test_resolve_root_and_dot_map_to_edited_scene_root() -> void:
	var root: Node2D = Node2D.new()
	root.name = "gameplay-feature"
	var child: Node2D = Node2D.new()
	child.name = "Child"
	root.add_child(child)
	get_tree().root.add_child(root)  # 运行时形态 /root/gameplay-feature
	var resolved_root: Node = ScriptToolsScript._resolve_node_within(root, "/root")
	var resolved_dot: Node = ScriptToolsScript._resolve_node_within(root, ".")
	var resolved_child: Node = ScriptToolsScript._resolve_node_within(root, "/root/gameplay-feature/Child")
	var resolved_relative: Node = ScriptToolsScript._resolve_node_within(root, "Child")
	assert_eq(resolved_root, root, "'/root' must resolve to the edited scene root, not the editor Window")
	assert_eq(resolved_dot, root, "'.' must resolve to the edited scene root")
	assert_eq(resolved_child, child, "scene-name absolute paths still resolve within the scene")
	assert_eq(resolved_relative, child, "relative paths still resolve")
	root.queue_free()

func test_pure_movement_goal_generates_compilable_ready() -> void:
	# 真机 E2E 抓到的两个缺陷的回归：空 _ready 函数体（非法 GDScript）与
	# 无碰撞形状的玩家（Area2D 永远探测不到——收集/死亡从未生效）。
	# 结构性修复：_ready 恒定生成玩家碰撞体，两个缺陷都不再可能出现。
	var source: String = BlueprintsScript.controller_script("arrow-key movement controller")
	assert_true(source.contains("func _ready() -> void:\n\tvar body_shape := CollisionShape2D.new()"),
		"every controller gets a player collision shape in _ready")
	assert_false(source.contains("func _ready() -> void:\n\n"),
		"_ready is never empty")

func test_enemy_goal_generates_patrol_and_respawn() -> void:
	var source: String = BlueprintsScript.controller_script("patrolling enemies that kill and respawn the player")
	assert_true(source.contains("ENEMY_HOME_X"), "enemy constants present")
	assert_true(source.contains("_on_enemy_touched"), "death handler present")
	assert_true(source.contains("deaths_count"), "observable death counter")
	assert_true(source.contains("position = Vector2.ZERO"), "respawn resets the player")
	assert_true(source.contains("_physics_process"), "patrol runs in the physics frame")

func test_collect_and_enemy_exercises_derived() -> void:
	# 派生组合：收集目标带收集腿，敌人目标带巡逻/重生腿
	var tools: RefCounted = preload("res://addons/godot_mcp/tools/game_workflow_tools.gd").new()
	var collect_steps: Array = tools._collect_play_steps()
	var descriptions: Array = []
	for step_value in collect_steps:
		var leg: Dictionary = (step_value.get("assert", {}) as Dictionary)
		if not leg.is_empty():
			descriptions.append(str(leg.get("expression", "")))
	assert_has(descriptions, "coins_collected")
	assert_has(descriptions, "_win_label.text")
	var enemy_legs: Dictionary = tools._enemy_play_legs()
	var enemy_expressions: Array = []
	for step_value in enemy_legs["steps"]:
		var leg2: Dictionary = (step_value.get("assert", {}) as Dictionary)
		if not leg2.is_empty():
			enemy_expressions.append(str(leg2.get("expression", "")))
	assert_has(enemy_expressions, "deaths_count")
	var enemy_metrics: Array = enemy_legs["assertions"]
	assert_eq(String((enemy_metrics[0] as Dictionary).get("aggregate", "")), "range",
		"patrol proof uses the phase-robust range metric")

func test_state_machine_goal_generates_flow() -> void:
	var source: String = BlueprintsScript.controller_script("a title screen with start, gameplay, win state and restart")
	assert_true(source.contains("var game_state: String = \"title\""), "observable state variable")
	assert_true(source.contains("if _enter_edge():"), "transitions use the state-polled enter edge (probe-safe)")
	assert_true(source.contains("if game_state == \"title\":"), "title->playing transition")
	assert_true(source.contains("elif game_state == \"win\":"), "win->title restart transition")
	assert_true(source.contains("game_state = \"win\""), "collect reaches win state")
	assert_true(source.contains("coins_collected = 0"), "restart resets run state")
	assert_true(source.contains("_coin_area"), "state implies collectible (win condition)")
	assert_true(source.contains("func _enter_edge() -> bool:"), "edge latch helper emitted")
	assert_false(source.contains("is_action_just_pressed(\"ui_accept\")"),
		"the unreliable just_pressed edge is gone for ui_accept")

func test_state_play_steps_assert_all_four_transitions() -> void:
	var tools: RefCounted = preload("res://addons/godot_mcp/tools/game_workflow_tools.gd").new()
	var states: Array = []
	for step_value in tools._state_play_steps():
		var leg: Dictionary = step_value.get("assert", {}) if step_value.has("assert") else {}
		if str(leg.get("expression", "")) == "game_state":
			states.append(leg.get("expected"))
	# 效果断言替代瞬态 title 断言后，直接的 game_state 断言序列为 win → playing
	#（title 由重置效果 coins==0 + 原点间接证明，见 _state_play_steps）
	assert_eq(states, ["win", "playing"],
		"direct state asserts: win -> playing (title proven via reset effects)")

func test_rename_goal_gets_native_objective_gate() -> void:
	# E4：更名目标无需显式 required_capabilities——引擎按语义插入
	# objective gate 的 rename 步骤（位于 verify_scripts 之前）。
	var EngineScriptX = preload("res://addons/godot_mcp/native_mcp/game_workflow_engine.gd")
	var ManifestScriptX = preload("res://addons/godot_mcp/native_mcp/tools_manifest.gd")
	var available: Array[String] = []
	for tool_name in ManifestScriptX.TOOLS.keys():
		available.append(tool_name)
	var result: Dictionary = EngineScriptX.new().compile(
		"arrow-key movement, then rename the field coins_collected to gems_collected",
		{"profiles": ["gameplay_feature"]}, available)
	assert_false(result.has("error"), str(result.get("error", "")))
	var keys: Array = []
	for task_value in result["plan"].get("tasks", []):
		keys.append(String((task_value as Dictionary).get("step_key", "")))
	assert_has(keys, "rename_symbol", "rename step enters the DAG natively")
	assert_lt(keys.find("rename_symbol"), keys.find("verify_scripts"),
		"rename runs before compile verification")

func test_movement_feel_legs_shape() -> void:
	var tools: RefCounted = preload("res://addons/godot_mcp/tools/game_workflow_tools.gd").new()
	var feel: Dictionary = tools._movement_feel_legs()
	var feel_step: Dictionary = feel["steps"][0]
	assert_true(bool(feel_step.has("wait_frames")), "frame-stepped input hold")
	# feel 断言已步级化：只测本腿 20 帧窗口（整轨迹 delta 会被后续死亡重置压低）
	var feel_assert: Dictionary = feel_step.get("assert", {})
	assert_true(feel_assert.has("displacement_min"), "step-level displacement assert on the hold window")
	assert_true(float(feel_assert.get("displacement_min", 0)) >= 60.0, "a real budget, not a tautology")

func test_audio_goal_generates_sfx_on_collect() -> void:
	var source: String = BlueprintsScript.controller_script("collect a coin that plays a sound effect")
	assert_true(source.contains("AudioStreamPlayer"), "sfx player created")
	assert_true(source.contains("AudioStreamWAV"), "sound generated programmatically (zero external assets)")
	assert_true(source.contains("sfx_played_count"), "observable playback counter")
	assert_true(source.contains("_sfx_player.play()"), "collection triggers playback")

func test_audio_leg_asserts_playback() -> void:
	var tools: RefCounted = preload("res://addons/godot_mcp/tools/game_workflow_tools.gd").new()
	var legs: Array = tools._audio_play_steps()
	assert_eq(str((legs[0].get("assert", {}) as Dictionary).get("expression", "")), "sfx_played_count")

func test_tuning_goal_builds_iterate_chain() -> void:
	var EngineScriptT = preload("res://addons/godot_mcp/native_mcp/game_workflow_engine.gd")
	var ManifestScriptT = preload("res://addons/godot_mcp/native_mcp/tools_manifest.gd")
	var available: Array[String] = []
	for tool_name in ManifestScriptT.TOOLS.keys():
		available.append(tool_name)
	var result: Dictionary = EngineScriptT.new().compile(
		"arrow-key movement, then make it snappier and more responsive",
		{"profiles": ["gameplay_feature"]}, available)
	assert_false(result.has("error"), str(result.get("error", "")))
	var keys: Array = []
	for task_value in result["plan"].get("tasks", []):
		keys.append(String((task_value as Dictionary).get("step_key", "")))
	assert_has(keys, "tune_baseline")
	assert_has(keys, "tune_apply")
	assert_has(keys, "tune_verify")
	assert_lt(keys.find("tune_apply"), keys.find("tune_verify"), "apply runs before verify")

func test_tuning_parse_directions() -> void:
	var tools: RefCounted = preload("res://addons/godot_mcp/tools/game_workflow_tools.gd").new()
	assert_eq(str(tools.parse_tuning_goal("让移动更跟手").get("direction", "")), "faster")
	assert_eq(str(tools.parse_tuning_goal("movement is too fast, make it slower").get("direction", "")), "slower")
	assert_true(tools.parse_tuning_goal("arrow-key movement").is_empty())

func test_multi_coin_goal_generates_correct_count() -> void:
	var source: String = BlueprintsScript.controller_script("collect 3 coins and show a win label")
	assert_true(source.contains("const COINS_TO_WIN: int = 3"), "3 coins parsed from goal")
	assert_true(source.contains("Coin%d"), "extra coin generation loop present")
	assert_true(source.contains("110.0 + coin_index * 40.0"),
		"coins cluster before the enemy patrol band (P0-3 geometry fix)")

func test_multi_param_tuning_parses() -> void:
	var tools: RefCounted = preload("res://addons/godot_mcp/tools/game_workflow_tools.gd").new()
	var enemy_tune: Dictionary = tools.parse_tuning_goal("make the enemy faster")
	assert_eq(str(enemy_tune.get("param", "")), "ENEMY_SPEED")
	var magnet_tune: Dictionary = tools.parse_tuning_goal("make the pickup magnet radius bigger, snappier")
	assert_eq(str(magnet_tune.get("param", "")), "MAGNET")

# ============================================================================
# 位移快照防污染（CI run 35343562660：手感腿 "按右键左移 110px" 实为
# 陈旧 before 缓存与新鲜 after 的差值——测量造假）
# ============================================================================

func test_displacement_assert_rejects_stale_pre_snapshot() -> void:
	# 前读返回带 error 的超时载荷（携带 last_value）——不得用该值算 delta
	_fake.scripted_results["position.x"] = {
		"passed": false, "status": "failed",
		"error": "Timeout waiting for runtime condition: position.x",
		"last_value": 114.73}
	var report: Dictionary = await _run([
		{"action": "move_right", "pressed": true, "wait_ms": 10, "assert": {
			"expression": "position.x", "displacement_min": 60,
			"description": "feel window"}},
	])
	var has_snapshot_error: bool = false
	for err_value in report.get("errors", []):
		if str((err_value as Dictionary).get("error", "")).contains("snapshot not fresh"):
			has_snapshot_error = true
	assert_true(has_snapshot_error, "stale pre-read records a loud step error")
	assert_false(bool(report.get("passed", true)), "the gate fails instead of computing a poisoned delta")
	var has_skip: bool = false
	for a_value in report.get("assertions", []):
		var a: Dictionary = a_value
		if not bool(a.get("passed", true)) and str(a.get("error", "")).contains("snapshot unavailable"):
			has_skip = true
	assert_true(has_skip, "the displacement assert is recorded as failed, not vacuously passed")

func test_displacement_assert_rejects_stale_post_snapshot() -> void:
	# 前读新鲜（100.0）、后读超时携带陈旧值（4.33）——失败断言带证据，
	# 不得用陈旧 after 算出 -95.67 的假 delta
	_fake.scripted_results["position.x"] = [
		{"passed": true, "status": "success", "last_value": 100.0},
		{"passed": false, "status": "failed",
			"error": "Timeout waiting for runtime condition: position.x",
			"last_value": 4.33},
	]
	var report: Dictionary = await _run([
		{"action": "move_right", "pressed": true, "wait_ms": 10, "assert": {
			"expression": "position.x", "displacement_min": 60,
			"description": "feel window"}},
	])
	assert_false(bool(report.get("passed", true)), "the gate fails on a stale post-read")
	var has_post_error: bool = false
	for a_value in report.get("assertions", []):
		var a: Dictionary = a_value
		if not bool(a.get("passed", true)) and str(a.get("error", "")).contains("post-step snapshot not fresh"):
			has_post_error = true
	assert_true(has_post_error, "the failed assertion carries the stale-post evidence")

func test_displacement_assert_computes_delta_from_fresh_reads() -> void:
	# 正常路径回归保护：两读都新鲜 → delta 计算与阈值判定不变
	_fake.scripted_results["position.x"] = [
		{"passed": true, "status": "success", "last_value": 100.0},
		{"passed": true, "status": "success", "last_value": 186.7},
	]
	var report: Dictionary = await _run([
		{"action": "move_right", "pressed": true, "wait_ms": 10, "assert": {
			"expression": "position.x", "displacement_min": 60,
			"description": "feel window"}},
	])
	assert_true(bool(report.get("passed", false)), str(report.get("errors", "")))
	var delta_result: Dictionary = {}
	for a_value in report.get("assertions", []):
		if (a_value as Dictionary).has("displacement"):
			delta_result = a_value
	assert_almost_eq(float(delta_result.get("displacement", 0.0)), 86.7, 0.01,
		"fresh delta = 186.7 - 100.0")
