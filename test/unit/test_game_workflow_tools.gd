
func test_goal_blueprint_verbs_bilingual():
	var verbs: Dictionary = load("res://addons/godot_mcp/native_mcp/goal_blueprints.gd").match_verbs(
		"arrow-key player movement, collect a coin, show a win label")
	assert_true(bool(verbs.get("movement", false)), "English movement verb matched")
	assert_true(bool(verbs.get("collectible", false)), "English collectible verb matched")
	assert_true(bool(verbs.get("win", false)), "English win verb matched")
	var zh: Dictionary = load("res://addons/godot_mcp/native_mcp/goal_blueprints.gd").match_verbs(
		"方向键移动的角色吃到金币后显示胜利")
	assert_true(bool(zh.get("movement", false)), "Chinese movement verb matched")
	assert_true(bool(zh.get("collectible", false)), "Chinese collectible verb matched")
	assert_true(bool(zh.get("win", false)), "Chinese win verb matched")
	var none: Dictionary = load("res://addons/godot_mcp/native_mcp/goal_blueprints.gd").match_verbs(
		"a story about tea")
	assert_false(load("res://addons/godot_mcp/native_mcp/goal_blueprints.gd").has_any_verb(none),
		"Unrelated objective produces no blueprint")

func test_goal_blueprint_controller_compiles_and_moves():
	var blueprints: RefCounted = load("res://addons/godot_mcp/native_mcp/goal_blueprints.gd")
	var source: String = blueprints.controller_script(
		"arrow-key movement, collectible coin, win label")
	assert_true(source.contains("move_and_slide()"), "Blueprint contains real movement")
	assert_true(source.contains("_on_coin_touched"), "Blueprint contains pickup logic")
	assert_true(source.contains("You Win!"), "Blueprint contains win condition")
	var test_script: GDScript = GDScript.new()
	test_script.source_code = source
	assert_eq(test_script.reload(), OK, "Composed blueprint must compile cleanly")
	var movement_only: String = blueprints.controller_script("arrow-key movement only")
	assert_true(movement_only.contains("move_and_slide()"), "Movement-only keeps movement")
	assert_false(movement_only.contains("_on_coin_touched"), "Movement-only drops pickup block")
