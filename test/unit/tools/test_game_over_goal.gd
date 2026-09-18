extends "res://addons/gut/test.gd"

## 游戏结束目标族测试（质量维度：死亡有意义）：
## 1) 蓝图：game_over 动词（3 命、死亡递减、命尽 gameover 态+画面、
##    Enter 全重置、win 换轮恢复生命）；蕴含敌人+状态机
## 2) 证据腿：自带解锁、站桩式击杀（按住右键耗尽 3 命）、失败画面
##    断言、重开全重置断言
## 3) 合并目标与规划路由

const BlueprintsScript = preload("res://addons/godot_mcp/native_mcp/goal_blueprints.gd")
const WorkflowToolsScript = preload("res://addons/godot_mcp/tools/game_workflow_tools.gd")

const GAME_OVER_GOAL := "Add a game over screen with 3 lives when the player dies."

# ============================================================================
# 关键词与蕴含
# ============================================================================

func test_game_over_keywords_match_bilingually() -> void:
	assert_true(BlueprintsScript._mentions(GAME_OVER_GOAL, BlueprintsScript.GAME_OVER_KEYWORDS))
	assert_true(BlueprintsScript._mentions("加一个游戏结束画面和生命数", BlueprintsScript.GAME_OVER_KEYWORDS))
	assert_false(BlueprintsScript._mentions("Add a sound effect", BlueprintsScript.GAME_OVER_KEYWORDS),
		"sound objectives stay audio-only")

func test_game_over_implies_enemy_and_state_machine() -> void:
	var verbs: Dictionary = BlueprintsScript.match_verbs(GAME_OVER_GOAL)
	assert_true(bool(verbs.get("game_over", false)), "objective matches the game_over verb")
	var source: String = BlueprintsScript.controller_script(GAME_OVER_GOAL)
	assert_true(source.contains("ENEMY_COUNT"), "game over implies enemies (something must kill)")
	assert_true(source.contains("var game_state"), "game over implies the state machine (gameover is a state)")
	assert_true(source.contains("coins_collected"), "state machine implies collectibles")
	assert_true(source.contains("move_right"), "and movement")

# ============================================================================
# 蓝图：生命系统与状态转移
# ============================================================================

func test_game_over_controller_has_lives_and_screen() -> void:
	var source: String = BlueprintsScript.controller_script(GAME_OVER_GOAL)
	assert_true(source.contains("STARTING_LIVES: int = 3"), "three lives configured")
	assert_true(source.contains("var lives: int = STARTING_LIVES"), "observable lives counter")
	assert_true(source.contains("GameOverLabel"), "the failure screen exists")
	assert_true(source.contains("lives -= 1"), "dying decrements lives")
	assert_true(source.contains("game_state = \"gameover\""), "exhausted lives end the game")

func test_game_over_enter_edge_resets_everything() -> void:
	var source: String = BlueprintsScript.controller_script(GAME_OVER_GOAL)
	var gameover_pos: int = source.find("elif game_state == \"gameover\"")
	assert_gt(gameover_pos, -1, "gameover enter-edge branch exists")
	var window: String = source.substr(gameover_pos, 420)
	assert_true(window.contains("lives = STARTING_LIVES"), "restart restores lives")
	assert_true(window.contains("coins_collected = 0"), "restart clears coins")
	assert_true(window.contains("_gameover_label.visible = false"), "restart hides the failure screen")
	assert_true(window.contains("game_state = \"title\""), "gameover returns to title")

func test_win_round_reset_restores_lives() -> void:
	var source: String = BlueprintsScript.controller_script(GAME_OVER_GOAL)
	var win_pos: int = source.find("elif game_state == \"win\"")
	var window: String = source.substr(win_pos, 420)
	assert_true(window.contains("lives = STARTING_LIVES"), "winning a round also restores lives")

# ============================================================================
# 证据腿
# ============================================================================

func test_gameover_legs_unlock_then_death_run_then_restart() -> void:
	var tools: RefCounted = WorkflowToolsScript.new()
	var steps: Array = tools._gameover_play_steps()
	# 自带解锁在最前（独立语境注册表可能还没有 state）
	assert_eq(str((steps[0] as Dictionary).get("action", "")), "ui_accept",
		"legs unlock before the death run")
	# 站桩式击杀：长按 move_right
	var has_death_hold: bool = false
	for step_value in steps:
		var step: Dictionary = step_value
		if str(step.get("action", "")) == "move_right" and bool(step.get("pressed", false)):
			assert_gt(int(step.get("wait_ms", 0)), 10000,
				"the death hold is long enough for three slow-patrol kills")
			has_death_hold = true
	assert_true(has_death_hold, "the death hold step exists")
	# 断言覆盖：gameover 态、命尽、画面可见、重开全重置
	var descriptions: Array = []
	for step_value in steps:
		var leg: Dictionary = (step_value as Dictionary).get("assert", {})
		if not leg.is_empty():
			descriptions.append(String(leg.get("expression", "")))
	assert_has(descriptions, "game_state")
	assert_has(descriptions, "_gameover_label.visible")
	assert_has(descriptions, "lives == STARTING_LIVES and coins_collected == 0")

# ============================================================================
# 合并目标与规划路由
# ============================================================================

func test_merged_objective_includes_game_over_part() -> void:
	var tools: RefCounted = WorkflowToolsScript.new()
	var merged: String = tools._build_merged_objective(
		{"movement": true, "collectible": true, "game_over": true, "enemy": true},
		"arrow-key movement with 3 collectible coins")
	assert_string_contains(merged, "game over", "merged objective keeps the game_over verb")

func test_game_over_objective_compiles_into_verifiable_plan() -> void:
	var EngineScriptT = preload("res://addons/godot_mcp/native_mcp/game_workflow_engine.gd")
	var ManifestScriptT = preload("res://addons/godot_mcp/native_mcp/tools_manifest.gd")
	var available: Array[String] = []
	for tool_name in ManifestScriptT.tool_names():
		available.append(tool_name)
	var result: Dictionary = EngineScriptT.new().compile(
		GAME_OVER_GOAL, {"profiles": ["gameplay_feature"]}, available)
	assert_false(result.has("error"), str(result.get("error", "")))
	var tool_names: Array = []
	for task_value in result["plan"].get("tasks", []):
		tool_names.append(String((task_value as Dictionary).get("tool_name", "")))
	assert_has(tool_names, "create_script", "game over goal writes the controller")
	assert_has(tool_names, "play_and_verify", "game over goal gates on runtime evidence")

func test_merged_game_over_objective_regenerates_full_wiring() -> void:
	# 增量路径：合并目标 → 全量重生保留生命系统接线。
	var source: String = BlueprintsScript.controller_script(
		"arrow-key movement, 3 collectible coins, game over screen with lives")
	assert_true(source.contains("STARTING_LIVES"), "regenerated source keeps the lives system")
	assert_true(source.contains("game_state = \"gameover\""), "and the gameover transition")
