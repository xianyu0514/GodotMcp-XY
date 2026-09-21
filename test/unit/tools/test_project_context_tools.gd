extends "res://addons/gut/test.gd"

## gather_task_context（M4 首版）单元测试：
## 关键词提取（英/中/停用词/映射透明）、桶装配（入口脚本/引用场景/
## preload 资源/受影响测试）、预算截断、确定性排序、空目标与缺参诚实返回。

const ProjectContextTools = preload("res://addons/godot_mcp/tools/project_context_tools.gd")

const TEMP_DIR: String = "res://.tmp_task_context"

var _tools: RefCounted

func before_each() -> void:
	DirAccess.make_dir_recursive_absolute(TEMP_DIR)
	DirAccess.make_dir_recursive_absolute(TEMP_DIR + "/scenes")
	DirAccess.make_dir_recursive_absolute(TEMP_DIR + "/scripts")
	DirAccess.make_dir_recursive_absolute("res://test/.tmp_ctx_tests")
	_tools = ProjectContextTools.new()

func after_each() -> void:
	_tools = null
	_remove_tree(TEMP_DIR)
	_remove_tree("res://test/.tmp_ctx_tests")

func _remove_tree(path: String) -> void:
	if not DirAccess.dir_exists_absolute(path):
		return
	for sub_name: String in DirAccess.get_directories_at(path):
		if sub_name == "." or sub_name == "..":
			continue
		_remove_tree(path.path_join(sub_name))
	for file_name: String in DirAccess.get_files_at(path):
		DirAccess.remove_absolute(path.path_join(file_name))
	DirAccess.remove_absolute(path)

func _write(path: String, content: String) -> void:
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	file.store_string(content)
	file.close()

# ============================================================================
# 关键词提取
# ============================================================================

func test_extract_keywords_english_drops_stopwords() -> void:
	var keywords: Dictionary = ProjectContextTools._extract_keywords("Add a dash to the existing player controller")
	assert_has(keywords["ascii"], "dash")
	assert_has(keywords["ascii"], "player")
	assert_has(keywords["ascii"], "controller")
	assert_false(keywords["ascii"].has("add"), "making-verbs are not search terms")
	assert_false(keywords["ascii"].has("the"))

func test_extract_keywords_chinese_maps_through_term_table() -> void:
	var keywords: Dictionary = ProjectContextTools._extract_keywords("给玩家加冲刺")
	assert_has(keywords["zh_mappings"], "冲刺")
	assert_has(keywords["terms"], "dash")
	assert_has(keywords["terms"], "player")
	assert_true((keywords["ascii"] as Array).is_empty(), "no ascii words in a pure zh goal")

func test_extract_keywords_numbers_are_ignored() -> void:
	var keywords: Dictionary = ProjectContextTools._extract_keywords("increase 100 speed")
	assert_false(keywords["terms"].has("100"))
	assert_has(keywords["terms"], "speed")

# ============================================================================
# 工具级桶装配
# ============================================================================

func _seed_fixture_project() -> void:
	_write(TEMP_DIR + "/scripts/player.gd", """
extends CharacterBody2D

const SPEED := 300.0
var speed: float = 100.0
signal dash_started
func _physics_process(_delta: float) -> void:
	pass
func start_dash() -> void:
	emit_signal("dash_started")
""".strip_edges() + "\n")
	_write(TEMP_DIR + "/scripts/enemy_patrol.gd", "extends Node2D\nvar patrol_speed := 50.0\n")
	_write(TEMP_DIR + "/scenes/player_scene.tscn",
		'[gd_scene format=2]\n[ext_resource type="Script" path="res://%s/scripts/player.gd" id="1"]\n[node name="Player" type="CharacterBody2D"]\n[node name="Body" type="ColorRect" parent="."]\n[node name="Collision" type="CollisionShape2D" parent="."]\n[node name="Cam" type="Camera2D" parent="."]\n[node name="Sfx" type="AudioStreamPlayer" parent="."]\n' % TEMP_DIR.trim_prefix("res://"))
	_write("res://test/.tmp_ctx_tests/test_player_dash.gd", "extends GutTest\n# references player.gd dash behaviour\n")

func test_gather_assembles_all_buckets_with_provenance() -> void:
	_seed_fixture_project()
	var result: Dictionary = _tools._tool_gather_task_context({
		"goal": "add a dash to the player",
		"search_path": TEMP_DIR,
	})
	assert_false(result.has("error"), str(result.get("error", "")))

	var entries: Array = result["entry_scripts"]
	assert_eq(entries.size(), 1, "player.gd is the single keyword-matching script")
	var entry: Dictionary = entries[0]
	assert_eq(String(entry["path"]), TEMP_DIR + "/scripts/player.gd")
	assert_has(entry["name_keyword_matches"], "player")
	assert_has(entry["symbol_matches"], "start_dash")
	assert_has(entry["symbol_matches"], "dash_started")
	assert_false(str(entry["content_hash"]).is_empty(), "entry carries a content hash for read_script pinning")

	var scene_objects: Array = result.get("scene_objects", [])
	assert_eq(scene_objects.size(), 1, "the referenced scene is classified")
	var roles: Dictionary = scene_objects[0].get("roles", {})
	assert_eq(String(scene_objects[0].get("root_type", "")), "CharacterBody2D", "root type reported")
	assert_eq((roles.get("body", []) as Array).size(), 1, "Player classified as body")
	assert_eq((roles.get("visual", []) as Array).size(), 1, "ColorRect Body classified as visual")
	assert_eq((roles.get("collision", []) as Array).size(), 1, "CollisionShape2D classified")
	assert_eq((roles.get("camera", []) as Array).size(), 1, "Camera2D classified")
	assert_eq((roles.get("audio", []) as Array).size(), 1, "AudioStreamPlayer classified")

	var scenes: Array = result["referencing_scenes"]
	assert_eq(scenes.size(), 1, "player_scene.tscn references player.gd")
	assert_eq(String(scenes[0]["path"]), TEMP_DIR + "/scenes/player_scene.tscn")
	assert_eq(str(scenes[0]["references_scripts"][0]), TEMP_DIR + "/scripts/player.gd")

	# affected_tests 扫描整个 res://test（生产口径）：仓库自带测试也可能
	# 引用 player，因此断言"夹具测试在列且每个条目确有引用"，不锁总数。
	var tests: Array = result["affected_tests"]
	var fixture_hit: bool = false
	for test_entry in tests:
		if String((test_entry as Dictionary)["path"]) == "res://test/.tmp_ctx_tests/test_player_dash.gd":
			fixture_hit = true
	assert_true(fixture_hit, "test file referencing the entry script is surfaced")

	assert_true(result["truncated"].has("entry_scripts"), "truncated flags are explicit")
	var follow_up: Array = result["follow_up"]
	assert_gt(follow_up.size(), 0, "exact follow-up reads are provided")
	assert_true(String(follow_up[0]).contains("read_script "), "follow-up pins the entry read")

func test_gather_zh_goal_finds_dash_symbol() -> void:
	_seed_fixture_project()
	var result: Dictionary = _tools._tool_gather_task_context({
		"goal": "给玩家加冲刺",
		"search_path": TEMP_DIR,
	})
	assert_false(result.has("error"), str(result.get("error", "")))
	var entries: Array = result["entry_scripts"]
	assert_eq(entries.size(), 1)
	assert_has(entries[0]["symbol_matches"], "start_dash", "zh 冲刺 maps to dash and matches symbols")

func test_gather_bucket_budget_truncates_deterministically() -> void:
	for i in range(7):
		_write(TEMP_DIR + "/scripts/dash_%d.gd" % i, "extends Node\nvar dash := %d\n" % i)
	var result: Dictionary = _tools._tool_gather_task_context({
		"goal": "dash",
		"search_path": TEMP_DIR,
		"max_items_per_bucket": 3,
	})
	var entries: Array = result["entry_scripts"]
	assert_eq(entries.size(), 3, "bucket respects max_items_per_bucket")
	assert_true(bool(result["truncated"]["entry_scripts"]), "truncation is reported")
	# 同 rank 按路径字典序：确定性截断
	assert_eq(String(entries[0]["path"]) < String(entries[1]["path"]), true)

func test_gather_preload_resources_reported_with_existence() -> void:
	_write(TEMP_DIR + "/scripts/loader.gd", 'extends Node\nconst TEX = preload("res://missing_texture.png")\n')
	var result: Dictionary = _tools._tool_gather_task_context({
		"goal": "loader",
		"search_path": TEMP_DIR,
	})
	var resources: Array = result["related_resources"]
	assert_eq(resources.size(), 1)
	assert_eq(String(resources[0]["path"]), "res://missing_texture.png")
	assert_false(bool(resources[0]["exists"]), "missing resource existence is reported honestly")

func test_gather_empty_goal_errors_and_unmatchable_goal_is_honest() -> void:
	assert_has(_tools._tool_gather_task_context({"goal": ""}), "error")
	assert_has(_tools._tool_gather_task_context({}), "error", "missing goal errors")

	var result: Dictionary = _tools._tool_gather_task_context({"goal": "美化一下"})
	assert_false(result.has("error"))
	assert_eq((result["entry_scripts"] as Array).size(), 0)
	assert_gt((result["notes"] as Array).size(), 0, "unmatchable goal explains itself in notes")

func test_gather_deterministic_across_runs() -> void:
	_seed_fixture_project()
	var first: Dictionary = _tools._tool_gather_task_context({"goal": "add a dash to the player", "search_path": TEMP_DIR})
	var second: Dictionary = _tools._tool_gather_task_context({"goal": "add a dash to the player", "search_path": TEMP_DIR})
	assert_eq(first["entry_scripts"], second["entry_scripts"], "same goal yields identical entries")
	assert_eq(first["referencing_scenes"], second["referencing_scenes"])

# ============================================================================
# 引用精确性（M5：完整路径/UID 匹配，同名脚本不混淆）
# ============================================================================

func test_same_name_scripts_do_not_conflate_scene_references() -> void:
	# 场景只引用 ui/player.gd；actors/player.gd 是同名的另一个脚本。
	# 旧的文件名子串匹配会把两者都算作被引用（审计第一缺口）。
	DirAccess.make_dir_recursive_absolute(TEMP_DIR + "/scripts/actors")
	DirAccess.make_dir_recursive_absolute(TEMP_DIR + "/scripts/ui")
	_write(TEMP_DIR + "/scripts/actors/player.gd", "extends Node\nvar from_actors := true\n")
	_write(TEMP_DIR + "/scripts/ui/player.gd", "extends Control\nvar from_ui := true\n")
	_write(TEMP_DIR + "/scenes/game.tscn",
		'[gd_scene format=2]\n[ext_resource type="Script" path="res://%s/scripts/ui/player.gd" id="1"]\n[node name="Main" type="Node"]\n' % TEMP_DIR.trim_prefix("res://"))

	var result: Dictionary = _tools._tool_gather_task_context({
		"goal": "player", "search_path": TEMP_DIR,
	})
	assert_false(result.has("error"))
	var entries: Array = result["entry_scripts"]
	assert_eq(entries.size(), 2, "both same-name scripts match the keyword")

	var scenes: Array = result["referencing_scenes"]
	assert_eq(scenes.size(), 1)
	var scene_entry: Dictionary = scenes[0]
	assert_eq((scene_entry["references_scripts"] as Array),
		[TEMP_DIR + "/scripts/ui/player.gd"],
		"only the actually-referenced same-name script is reported")
	assert_eq(String(scene_entry["match"]), "exact_path_or_uid")

func test_follow_up_points_to_complete_impact_query() -> void:
	_seed_fixture_project()
	var result: Dictionary = _tools._tool_gather_task_context({
		"goal": "add a dash to the player", "search_path": TEMP_DIR,
	})
	var impact_hint: String = ""
	for step in result["follow_up"]:
		if String(step).contains("query_change_impact"):
			impact_hint = String(step)
			break
	assert_false(impact_hint.is_empty(),
		"follow-up names the index-backed impact query for complete continuation")
	assert_true(impact_hint.contains(TEMP_DIR + "/scripts/player.gd"),
		"the hint carries the entry path as an explicit target")
