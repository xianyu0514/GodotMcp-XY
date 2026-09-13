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
			return scripted_results[expression]
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
	var enemy_steps: Array = tools._enemy_play_steps()
	var enemy_expressions: Array = []
	for step_value in enemy_steps:
		var leg2: Dictionary = (step_value.get("assert", {}) as Dictionary)
		if not leg2.is_empty():
			enemy_expressions.append(str(leg2.get("expression", "")))
	assert_has(enemy_expressions, "deaths_count")
	assert_has(enemy_expressions, "position.x")
