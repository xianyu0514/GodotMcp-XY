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

func test_collectible_only_controller_extends_character_body():
	# 金币/胜利蓝图同样依赖物理体：任意动词命中的控制器都必须 extends CharacterBody2D，
	# 根节点派生条件（game_workflow_tools.gd）与这里保持一致。
	var source: String = BlueprintsScript.controller_script("collect a coin and show a win label")
	assert_true(source.contains("extends CharacterBody2D"),
		"Collectible-only controller still extends CharacterBody2D")
