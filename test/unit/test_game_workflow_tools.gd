extends "res://addons/gut/test.gd"

const BlueprintsScript = preload("res://addons/godot_mcp/native_mcp/goal_blueprints.gd")

func test_goal_blueprint_verbs_bilingual():
	var verbs: Dictionary = BlueprintsScript.match_verbs(
		"arrow-key player movement, collect a coin, show a win label")
	assert_true(bool(verbs.get("movement", false)), "English movement verb matched")
	assert_true(bool(verbs.get("collectible", false)), "English collectible verb matched")
	assert_true(bool(verbs.get("win", false)), "English win verb matched")
	var zh: Dictionary = BlueprintsScript.match_verbs(
		"方向键移动的角色吃到金币后显示胜利")
	assert_true(bool(zh.get("movement", false)), "Chinese movement verb matched")
	assert_true(bool(zh.get("collectible", false)), "Chinese collectible verb matched")
	assert_true(bool(zh.get("win", false)), "Chinese win verb matched")
	var none: Dictionary = BlueprintsScript.match_verbs(
		"a story about tea")
	assert_false(BlueprintsScript.has_any_verb(none),
		"Unrelated objective produces no blueprint")

func test_goal_blueprint_controller_compiles_and_moves():
	var source: String = BlueprintsScript.controller_script(
		"arrow-key movement, collectible coin, win label")
	assert_true(source.contains("move_and_slide()"), "Blueprint contains real movement")
	assert_true(source.contains("_on_coin_touched"), "Blueprint contains pickup logic")
	assert_true(source.contains("You Win!"), "Blueprint contains win condition")
	var test_script: GDScript = GDScript.new()
	test_script.source_code = source
	assert_eq(test_script.reload(), OK, "Composed blueprint must compile cleanly")
	var movement_only: String = BlueprintsScript.controller_script("arrow-key movement only")
	assert_true(movement_only.contains("move_and_slide()"), "Movement-only keeps movement")
	assert_false(movement_only.contains("_on_coin_touched"), "Movement-only drops pickup block")

func test_platformer_objective_matches_movement_blueprint():
	# 插件自带 prompt 示例就是 "2D platformer vertical slice"——
	# platformer/jump 词表缺失会让这类目标拿不到移动蓝图与 CharacterBody2D 根。
	var verbs: Dictionary = BlueprintsScript.match_verbs("2D platformer with jumping")
	assert_true(bool(verbs.get("movement", false)), "platformer counts as movement")
	var source: String = BlueprintsScript.controller_script("2D platformer with coins")
	assert_true(source.contains("move_and_slide()"), "Platformer blueprint keeps real movement")
	var zh: Dictionary = BlueprintsScript.match_verbs("平台跳跃小游戏")
	assert_true(bool(zh.get("movement", false)), "Chinese platformer verb matched")

func test_platformer_goal_gets_sideview_jump_blueprint_not_topdown():
	# 语义修复回归：platformer/jump 目标此前拿到俯视 8 方向蓝图——能编译能跑
	# 但跳不起来，门禁全绿却没达成目标。现在必须生成带重力与跳跃的横版控制器。
	var source: String = BlueprintsScript.controller_script("2D platformer with jumping and coins")
	assert_true(source.contains("JUMP_SPEED"), "Side-view blueprint has a jump impulse")
	assert_true(source.contains("is_on_floor()"), "Side-view blueprint has a ground check")
	assert_true(source.contains("_gravity"), "Side-view blueprint applies gravity")
	assert_false(source.contains("get_vector("), "Side-view blueprint must not be top-down")
	var test_script: GDScript = GDScript.new()
	test_script.source_code = source
	assert_eq(test_script.reload(), OK, "Side-view blueprint must compile cleanly")

func test_jump_verbs_bilingual_and_jump_only_still_activates_blueprint():
	var zh: Dictionary = BlueprintsScript.match_verbs("横版平台跳跃，按空格跳")
	assert_true(bool(zh.get("jump", false)), "Chinese jump verb matched")
	assert_true(bool(zh.get("movement", false)), "Chinese jump implies movement")
	var top_down: Dictionary = BlueprintsScript.match_verbs("arrow-key movement only")
	assert_false(bool(top_down.get("jump", false)), "Top-down goal has no jump verb")
	# side-scroll/gravity 只在 JUMP 词表：不能因此漏掉蓝图（jump 蕴含 movement）。
	var jump_only: Dictionary = BlueprintsScript.match_verbs("side-scrolling gravity game")
	assert_true(BlueprintsScript.has_any_verb(jump_only),
		"Jump-only keywords still activate a blueprint")
	var jump_only_source: String = BlueprintsScript.controller_script("side-scrolling gravity game")
	assert_true(jump_only_source.contains("is_on_floor()"),
		"Jump-only objective gets the side-view controller")

func test_topdown_goal_keeps_eight_direction_blueprint():
	var source: String = BlueprintsScript.controller_script("arrow-key movement, collect coins")
	assert_true(source.contains("get_vector("), "Top-down blueprint keeps 8-direction movement")
	assert_false(source.contains("JUMP_SPEED"), "Top-down blueprint has no jump impulse")

func test_collectible_only_controller_extends_character_body():
	# 金币/胜利蓝图同样依赖物理体：任意动词命中的控制器都必须 extends CharacterBody2D，
	# 根节点派生条件（game_workflow_tools.gd）与这里保持一致。
	var source: String = BlueprintsScript.controller_script("collect a coin and show a win label")
	assert_true(source.contains("extends CharacterBody2D"),
		"Collectible-only controller still extends CharacterBody2D")

func test_goal_semantic_test_script_compiles_and_targets_verbs():
	# 移动+收集目标：断言位移与"走到并吃到 + 胜利标签"。
	var source: String = BlueprintsScript.semantic_test_script(
		"arrow-key movement, collect a coin, show a win label",
		"res://scenes/gameplay-feature.tscn")
	assert_true(source.contains("test_goal_semantics"), "Semantic suite has a test method")
	assert_true(source.contains("collects the coin"), "Collection is asserted for collectible goals")
	assert_true(source.contains("win label appears"), "Win label is asserted")
	var script: GDScript = GDScript.new()
	script.source_code = source
	assert_eq(script.reload(), OK, "Semantic suite must compile cleanly")

func test_goal_semantic_test_jump_variant_asserts_upward_launch():
	var source: String = BlueprintsScript.semantic_test_script(
		"2D platformer with jumping and coins", "res://scenes/gameplay-feature.tscn")
	assert_true(source.contains("jump input launches"), "Jump goals assert upward motion")
	assert_true(source.contains("horizontal input moves"), "Jump goals assert horizontal movement")
	var script: GDScript = GDScript.new()
	script.source_code = source
	assert_eq(script.reload(), OK, "Jump semantic suite must compile cleanly")

func test_goal_semantic_test_collect_only_skips_reach_assertion():
	# 纯收集目标（无移动动词）不能断言"走到并吃到"——玩家不会动，只能断言
	# 拾取体与标签存在。
	var source: String = BlueprintsScript.semantic_test_script(
		"a win label after collecting", "res://scenes/gameplay-feature.tscn")
	assert_false(source.contains("reaches and collects"),
		"Collect-only goals must not assert unreachable collection")
	assert_true(source.contains("contains the collectible"), "Existence checks remain")

func test_goal_semantic_test_empty_for_unrelated_objectives():
	assert_eq(BlueprintsScript.semantic_test_script("a story about tea", "res://scenes/x.tscn"),
		"", "Unrelated goals generate no semantic suite")
	assert_eq(BlueprintsScript.semantic_test_script("arrow-key movement", ""),
		"", "Missing scene path generates no semantic suite")
