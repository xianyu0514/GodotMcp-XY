extends "res://addons/gut/test.gd"

## 状态连续性与减量语义测试（开发建议第 2 步）：
## 1) 完整存档：lives/level 入档、读档恢复、读档先于生成、初始金币按
##    恢复后的关卡布局摆位（退出后能准确继续游戏）
## 2) 减量语义："把敌人减少到一个" = 集合（设为请求数），按种类限定

const BlueprintsScript = preload("res://addons/godot_mcp/native_mcp/goal_blueprints.gd")
const WorkflowToolsScript = preload("res://addons/godot_mcp/tools/game_workflow_tools.gd")
const ModelStoreScript = preload("res://addons/godot_mcp/tools/game_model_store.gd")

const FULL_GAME := "arrow-key movement, 3 collectible coins, save/load, " \
	+ "title screen with restart, game over screen with lives, a second level after the first win"

# ============================================================================
# 完整存档
# ============================================================================

func test_save_persists_lives_and_level() -> void:
	var source: String = BlueprintsScript.controller_script(FULL_GAME)
	assert_true(source.contains("data[\"lives\"] = lives"), "lives are saved")
	assert_true(source.contains("data[\"level\"] = current_level"), "level is saved")
	assert_true(source.contains("lives = int(parsed.get(\"lives\""), "lives are restored")
	assert_true(source.contains("current_level = int(parsed.get(\"level\""), "level is restored")

func test_load_runs_before_anything_spawns() -> void:
	# 恢复 current_level 必须发生在金币生成之前——初始布局才能落在
	# 恢复后的关卡基址上（读档在生成之后 = L2 恢复摆的是 L1 金币）。
	var source: String = BlueprintsScript.controller_script(FULL_GAME)
	assert_lt(source.find("load_game()"), source.find("_coin_area = Area2D.new()"),
		"load_game precedes the initial coin spawn")

func test_initial_spawn_is_level_aware() -> void:
	var source: String = BlueprintsScript.controller_script(FULL_GAME)
	# 夹紧公式：簇基址随关右移但不越过敌带安全线（末枚 <= 200px）。
	assert_true(source.contains("var base_x: float = minf(110.0 + (current_level - 1) * 40.0, 200.0 - float(COINS_TO_WIN - 1) * 40.0)"),
		"the initial cluster follows the restored level (clamped before the enemy band)")
	var script := GDScript.new()
	script.source_code = source
	assert_eq(script.reload(), OK, "the full merged game still compiles")

func test_plain_save_stays_unpolluted() -> void:
	var source: String = BlueprintsScript.controller_script(
		"arrow-key movement, collectible coin, win label, save/load")
	assert_false(source.contains("current_level"), "no level refs without the level verb")
	assert_false(source.contains("lives"), "no lives refs without the game_over verb")
	var script := GDScript.new()
	script.source_code = source
	assert_eq(script.reload(), OK, "plain compositions stay clean")

# ============================================================================
# 减量语义
# ============================================================================

func test_reduce_request_parsing() -> void:
	assert_true(BlueprintsScript.is_reduce_request("把三个敌人减少到一个"))
	assert_true(BlueprintsScript.is_reduce_request("reduce the enemies down to one"))
	assert_false(BlueprintsScript.is_reduce_request("再加一个敌人"), "additive stays additive")
	assert_false(BlueprintsScript.is_reduce_request("Add 3 collectible coins."))

func test_merged_count_reduce_is_set_semantics() -> void:
	# existing=3, "减少到一个" → 1（取最大等于无视指令）。
	var tmp := "user://tmp_test_reduce_model.json"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	f.store_string(JSON.stringify({"counts": {"enemies": 3}}))
	f.close()
	assert_eq(ModelStoreScript.merged_count("enemies", 1, false, tmp, true), 1,
		"reduce sets the count to the requested value")
	assert_eq(ModelStoreScript.merged_count("enemies", 2, false, tmp, false), 3,
		"plain totals keep the max semantics")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(tmp))

func test_merged_objective_honors_reduce() -> void:
	var tools: RefCounted = WorkflowToolsScript.new()
	var merged: String = tools._build_merged_objective(
		{"movement": true, "collectible": true, "enemy": true},
		"reduce the enemies down to one")
	assert_string_contains(merged, "1 patrolling enemies",
		"'reduce to one enemy' expresses as a set, not a max")
