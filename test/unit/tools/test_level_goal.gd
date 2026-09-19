extends "res://addons/gut/test.gd"

## 多关卡目标族测试（质量维度：内容深度）：
## 1) 蓝图：level 动词（LEVEL_COUNT/current_level、非最终关显示通关文案
##    且不重置计数、Enter 换关重置、最终关→title 关卡归 1、重生按关卡
##    布局、gameover 归位 L1）；蕴含状态机
## 2) 证据腿：L1 通关 → L2 换关（清零+原点+playing）→ 最终胜利 → 回 L1
## 3) 腿的关卡感知：状态/收集腿的第一轮胜利文案跟随 levels_merged
## 4) 合并目标与规划路由

const BlueprintsScript = preload("res://addons/godot_mcp/native_mcp/goal_blueprints.gd")
const WorkflowToolsScript = preload("res://addons/godot_mcp/tools/game_workflow_tools.gd")

const LEVEL_GOAL := "Add a second level after the first win."

# ============================================================================
# 关键词、蕴含与计数
# ============================================================================

func test_level_keywords_and_implication() -> void:
	assert_true(BlueprintsScript._mentions(LEVEL_GOAL, BlueprintsScript.LEVEL_KEYWORDS))
	assert_true(BlueprintsScript._mentions("加一个第二关", BlueprintsScript.LEVEL_KEYWORDS))
	var verbs: Dictionary = BlueprintsScript.match_verbs(LEVEL_GOAL)
	assert_true(bool(verbs.get("level", false)), "objective matches the level verb")
	var source: String = BlueprintsScript.controller_script(LEVEL_GOAL)
	assert_true(source.contains("var game_state"), "level implies the state machine (progression via win->Enter)")
	assert_true(source.contains("coins_collected"), "state machine implies collectibles")

func test_level_count_parsing() -> void:
	assert_eq(BlueprintsScript._level_count("Add a second level after the first win."), 2,
		"'a second level' means two levels")
	assert_eq(BlueprintsScript._level_count("Add 3 levels of gameplay."), 3, "explicit digits parse")
	assert_eq(BlueprintsScript._level_count("add levels"), 2, "default is the minimal verifiable progression")

# ============================================================================
# 蓝图：关卡机制
# ============================================================================

func test_level_controller_wiring() -> void:
	var source: String = BlueprintsScript.controller_script(LEVEL_GOAL)
	assert_true(source.contains("LEVEL_COUNT: int = 2"), "two levels configured")
	assert_true(source.contains("var current_level: int = 1"), "observable level counter")
	assert_true(source.contains("\"Level %d Clear!\" % current_level"), "non-final clear shows the level text")
	assert_true(source.contains("current_level += 1"), "Enter advances the level")
	assert_true(source.contains("current_level = 1"), "final win / restart resets to level one")
	assert_true(source.contains("base_x"), "coin respawn is level-parameterized")

func test_level_clear_does_not_reset_counters() -> void:
	# 关键设计约束：非最终关的通关**不重置计数**——收集/反馈等值断言在
	# 关卡合并后的回归语境里必须原样成立（重置只在 Enter 换关时发生）。
	var source: String = BlueprintsScript.controller_script(LEVEL_GOAL)
	var clear_pos: int = source.find("Level %d Clear!")
	assert_gt(clear_pos, -1, "level clear emission exists")
	var window: String = source.substr(clear_pos, 400)
	assert_false(window.contains("coins_collected = 0"),
		"the clear itself must not reset the coin counter")
	var advance_pos: int = source.find("current_level += 1")
	var advance_window: String = source.substr(advance_pos, 300)
	assert_true(advance_window.contains("coins_collected = 0"),
		"the Enter transition resets the board for the next level")

func test_full_level_composition_compiles() -> void:
	var source: String = BlueprintsScript.controller_script(
		"arrow-key movement, 3 collectible coins, title screen with restart, " \
		+ "game over screen with lives, a second level after the first win")
	var script := GDScript.new()
	script.source_code = source
	assert_eq(script.reload(), OK, "the full merged game compiles cleanly")
	var plain: String = BlueprintsScript.controller_script("arrow-key movement, collectible coin, win label")
	var plain_script := GDScript.new()
	plain_script.source_code = plain
	assert_eq(plain_script.reload(), OK, "stateless compositions stay clean (no orphan elif)")

func test_gameover_resets_to_level_one() -> void:
	var source: String = BlueprintsScript.controller_script(
		"game over screen with lives, a second level after the first win")
	var gameover_pos: int = source.find("elif game_state == \"gameover\"")
	var window: String = source.substr(gameover_pos, 300)
	assert_true(window.contains("current_level = 1"), "game over returns the player to level one")

# ============================================================================
# 证据腿与关卡感知
# ============================================================================

func test_level_legs_walk_three_levels() -> void:
	# 三关样板支撑：level_count=3 时腿走 L1→L2→L3 全弧线
	var tools: RefCounted = WorkflowToolsScript.new()
	var steps: Array = tools._level_play_steps(3)
	var expressions: Array = []
	for step_value in steps:
		var leg: Dictionary = (step_value as Dictionary).get("assert", {})
		if not leg.is_empty():
			expressions.append(String(leg.get("expression", "")) + "=>" + str(leg.get("expected", "")))
	# 逐关通关断言（1|true|win / 2|true|win / 3|true|win）
	assert_has(expressions, "str(current_level) + \"|\" + str(coins_collected == COINS_TO_WIN) + \"|\" + game_state=>3|true|win",
		"the final of three levels is level three")
	# 中间关入口显微镜（2 与 3）
	var has_l3_entry: bool = false
	for e_value in expressions:
		var e: String = str(e_value)
		if e.contains("_pickup_log") and e.ends_with("3|0|playing|0|"):
			has_l3_entry = true
	assert_true(has_l3_entry, "the level-3 entry microscope exists")

func test_level_legs_walk_both_levels() -> void:
	var tools: RefCounted = WorkflowToolsScript.new()
	var steps: Array = tools._level_play_steps()
	var expressions: Array = []
	for step_value in steps:
		var leg: Dictionary = (step_value as Dictionary).get("assert", {})
		if not leg.is_empty():
			expressions.append(String(leg.get("expression", "")))
	assert_has(expressions, "str(current_level) + \"|\" + str(coins_collected == COINS_TO_WIN) + \"|\" + game_state",
		"level one completes without advancing (forensic encoding)")
	assert_has(expressions, "str(current_level) + \"|\" + str(coins_collected) + \"|\" + game_state",
		"Enter advances to a fresh level two (values visible on failure)")

func test_state_legs_are_level_aware() -> void:
	var tools: RefCounted = WorkflowToolsScript.new()
	var plain: Array = tools._state_play_steps()
	var plain_text: String = ""
	for step_value in plain:
		var leg: Dictionary = (step_value as Dictionary).get("assert", {})
		if str(leg.get("expression", "")) == "_win_label.text":
			plain_text = str(leg.get("expected", ""))
	assert_eq(plain_text, "You Win!", "without levels the first win text is unchanged")
	var merged: Array = tools._state_play_steps(true)
	var merged_text: String = ""
	for step_value in merged:
		var leg: Dictionary = (step_value as Dictionary).get("assert", {})
		if str(leg.get("expression", "")) == "_win_label.text":
			merged_text = str(leg.get("expected", ""))
	assert_eq(merged_text, "Level 1 Clear!", "with levels merged the first win text follows")

func test_collect_legs_are_level_aware() -> void:
	var tools: RefCounted = WorkflowToolsScript.new()
	var plain: Array = tools._collect_play_steps()
	var merged: Array = tools._collect_play_steps("coins_collected", true)
	var texts: Array = []
	for steps_set in [plain, merged]:
		for step_value in steps_set:
			var leg: Dictionary = (step_value as Dictionary).get("assert", {})
			if str(leg.get("expression", "")) == "_win_label.text":
				texts.append(str(leg.get("expected", "")))
	assert_eq(texts[0], "You Win!", "plain collect legs keep the win text")
	assert_eq(texts[1], "Level 1 Clear!", "level-merged collect legs expect the clear text")

# ============================================================================
# 合并目标与规划路由
# ============================================================================

func test_merged_objective_includes_level_part() -> void:
	var tools: RefCounted = WorkflowToolsScript.new()
	var merged: String = tools._build_merged_objective(
		{"movement": true, "collectible": true, "level": true},
		"arrow-key movement with 3 collectible coins")
	assert_string_contains(merged, "level", "merged objective keeps the level verb")

func test_level_objective_compiles_into_verifiable_plan() -> void:
	var EngineScriptT = preload("res://addons/godot_mcp/native_mcp/game_workflow_engine.gd")
	var ManifestScriptT = preload("res://addons/godot_mcp/native_mcp/tools_manifest.gd")
	var available: Array[String] = []
	for tool_name in ManifestScriptT.tool_names():
		available.append(tool_name)
	var result: Dictionary = EngineScriptT.new().compile(
		LEVEL_GOAL, {"profiles": ["gameplay_feature"]}, available)
	assert_false(result.has("error"), str(result.get("error", "")))
	var tool_names: Array = []
	for task_value in result["plan"].get("tasks", []):
		tool_names.append(String((task_value as Dictionary).get("tool_name", "")))
	assert_has(tool_names, "create_script", "level goal writes the controller")
	assert_has(tool_names, "play_and_verify", "level goal gates on runtime evidence")
