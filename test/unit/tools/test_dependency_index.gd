extends "res://addons/gut/test.gd"

## ProjectDependencyIndex（M5 首版）单元测试：
## 同名脚本不混淆、嵌套场景间接引用（传递闭包 + 证据链）、循环可终止、
## 深度限制、增量更新（编辑/删除/结构对账/幂等跳过）、动态 load 疑点、
## 悬空 UID 边、方向查询、确定性、project.godot 入口边。

const DependencyIndexScript = preload("res://addons/godot_mcp/tools/dependency_index.gd")

const TMP: String = "res://.tmp_dep_index"

var _index: RefCounted

func before_each() -> void:
	_make_dir(TMP + "/actors")
	_make_dir(TMP + "/ui")
	_make_dir(TMP + "/scenes")
	_make_dir(TMP + "/enemy")
	_make_dir(TMP + "/levels")
	_make_dir(TMP + "/scripts")
	_write(TMP + "/actors/player.gd", "extends Node\nvar actor_only := true\n")
	_write(TMP + "/ui/player.gd", "extends Control\nvar ui_only := true\n")
	_write(TMP + "/scenes/game.tscn", _scene_with_ext(
		"Script", TMP + "/ui/player.gd"))
	_write(TMP + "/enemy/enemy.gd", "extends CharacterBody2D\nvar hp := 10\n")
	_write(TMP + "/enemy/enemy.tscn", _scene_with_ext(
		"Script", TMP + "/enemy/enemy.gd"))
	_write(TMP + "/levels/level.tscn", _scene_with_ext(
		"PackedScene", TMP + "/enemy/enemy.tscn"))
	_index = DependencyIndexScript.new()
	_index.build(TMP)

func after_each() -> void:
	_index = null
	_remove_tree(TMP)

# ============================================================================
# 验收 1：同名脚本不混淆（完整路径身份）
# ============================================================================

func test_same_name_scripts_are_not_confused() -> void:
	var ui_dependents: Array = _index.dependents_of(TMP + "/ui/player.gd")
	assert_eq(ui_dependents.size(), 1, "game.tscn references ui/player.gd only")
	assert_eq(String(ui_dependents[0]["path"]), TMP + "/scenes/game.tscn")

	var actor_dependents: Array = _index.dependents_of(TMP + "/actors/player.gd")
	assert_eq(actor_dependents.size(), 0,
		"actors/player.gd is referenced by nothing — file-name matching must not leak here")

# ============================================================================
# 验收 2：嵌套场景的间接引用（传递闭包 + 证据链）
# ============================================================================

func test_transitive_dependents_through_nested_scenes() -> void:
	var dependents: Array = _index.dependents_of(TMP + "/enemy/enemy.gd")
	assert_eq(dependents.size(), 2, "enemy.tscn (direct) + level.tscn (indirect)")

	var first: Dictionary = dependents[0]
	assert_eq(String(first["path"]), TMP + "/enemy/enemy.tscn")
	assert_eq(int(first["depth"]), 1)
	assert_eq(first["evidence"], [TMP + "/enemy/enemy.gd", TMP + "/enemy/enemy.tscn"])

	var second: Dictionary = dependents[1]
	assert_eq(String(second["path"]), TMP + "/levels/level.tscn")
	assert_eq(int(second["depth"]), 2)
	assert_eq(second["evidence"], [
		TMP + "/enemy/enemy.gd", TMP + "/enemy/enemy.tscn", TMP + "/levels/level.tscn"])

func test_max_depth_limits_closure() -> void:
	var dependents: Array = _index.dependents_of(TMP + "/enemy/enemy.gd", 1)
	assert_eq(dependents.size(), 1, "only the direct dependent survives depth=1")
	assert_eq(String(dependents[0]["path"]), TMP + "/enemy/enemy.tscn")

func test_dependencies_direction_reports_requirement_chain() -> void:
	var dependencies: Array = _index.dependencies_of(TMP + "/levels/level.tscn")
	assert_eq(dependencies.size(), 2)
	assert_eq(String(dependencies[0]["path"]), TMP + "/enemy/enemy.tscn")
	assert_eq(String(dependencies[1]["path"]), TMP + "/enemy/enemy.gd")

# ============================================================================
# 验收 3：循环依赖必须可终止
# ============================================================================

func test_cycles_terminate() -> void:
	_write(TMP + "/scripts/a.gd", 'extends Node\nconst B = preload("%s/scripts/b.gd")\n' % TMP)
	_write(TMP + "/scripts/b.gd", 'extends Node\nconst A = preload("%s/scripts/a.gd")\n' % TMP)
	var change: Dictionary = _index.apply_changes(
		[TMP + "/scripts/a.gd", TMP + "/scripts/b.gd"])
	assert_eq(int(change["reparsed"]), 2)

	var dependents: Array = _index.dependents_of(TMP + "/scripts/a.gd")
	var paths: Array = []
	for entry in dependents:
		paths.append(String((entry as Dictionary)["path"]))
	assert_has(paths, TMP + "/scripts/b.gd", "b.gd preloads a.gd")
	assert_false(paths.has(TMP + "/scripts/a.gd"), "the target itself never re-enters")

# ============================================================================
# 验收 4：增量更新（编辑 / 删除 / 结构对账 / 幂等）
# ============================================================================

func test_incremental_update_after_edit() -> void:
	_write(TMP + "/scenes/game.tscn", _scene_with_ext(
		"Script", TMP + "/actors/player.gd"))
	var change: Dictionary = _index.apply_changes([TMP + "/scenes/game.tscn"])
	assert_eq(int(change["reparsed"]), 1)

	var actor_dependents: Array = _index.dependents_of(TMP + "/actors/player.gd")
	assert_eq(actor_dependents.size(), 1, "the new edge is visible")
	assert_eq(String(actor_dependents[0]["path"]), TMP + "/scenes/game.tscn")

	var ui_dependents: Array = _index.dependents_of(TMP + "/ui/player.gd")
	assert_eq(ui_dependents.size(), 0, "the stale edge is gone")

func test_repeated_notification_is_idempotent() -> void:
	var first: Dictionary = _index.apply_changes([TMP + "/scenes/game.tscn"])
	assert_eq(int(first["skipped"]), 1, "unchanged hash skips reparse")
	assert_eq(int(first["reparsed"]), 0)

func test_removed_file_edges_are_dropped() -> void:
	DirAccess.remove_absolute(ProjectDependencyIndex.normalize_path(TMP + "/enemy/enemy.tscn"))
	var change: Dictionary = _index.apply_changes([TMP + "/enemy/enemy.tscn"])
	assert_eq(int(change["removed"]), 1)

	var dependents: Array = _index.dependents_of(TMP + "/enemy/enemy.gd")
	var paths: Array = []
	for entry in dependents:
		paths.append(String((entry as Dictionary)["path"]))
	assert_false(paths.has(TMP + "/enemy/enemy.tscn"), "deleted file leaves the graph")

func test_structural_reconcile_picks_up_new_files() -> void:
	_write(TMP + "/scenes/new_entry.tscn", _scene_with_ext(
		"Script", TMP + "/enemy/enemy.gd"))
	var change: Dictionary = _index.apply_changes([], TMP, true)
	assert_eq(int(change["reconciled"]), 1, "the new file enters the index")

	var dependents: Array = _index.dependents_of(TMP + "/enemy/enemy.gd")
	var paths: Array = []
	for entry in dependents:
		paths.append(String((entry as Dictionary)["path"]))
	assert_has(paths, TMP + "/scenes/new_entry.tscn")

# ============================================================================
# 验收 5：动态依赖明确显示未知（不冒充确定关系）
# ============================================================================

func test_dynamic_load_is_flagged_not_assumed() -> void:
	_write(TMP + "/scripts/dyn_loader.gd",
		'extends Node\nvar res = load("res://" + name)\n')
	_index.apply_changes([TMP + "/scripts/dyn_loader.gd"])

	var hints: Array = _index.dynamic_load_hints([TMP + "/scripts/dyn_loader.gd"])
	assert_eq(hints.size(), 1, "one non-literal load call is reported")
	assert_eq(String(hints[0]["path"]), TMP + "/scripts/dyn_loader.gd")
	assert_eq(int(hints[0]["line"]), 2)
	assert_true(String(hints[0]["snippet"]).contains("load("))

	assert_eq(_index.direct_edges(TMP + "/scripts/dyn_loader.gd").size(), 0,
		"a dynamic load creates no deterministic edge")

func test_literal_preload_creates_deterministic_edge() -> void:
	_write(TMP + "/scripts/loader.gd",
		'extends Node\nconst T = preload("%s/enemy/enemy.gd")\n' % TMP)
	_index.apply_changes([TMP + "/scripts/loader.gd"])

	var edges: Array = _index.direct_edges(TMP + "/scripts/loader.gd")
	assert_eq(edges.size(), 1)
	assert_eq(String(edges[0]["target"]), TMP + "/enemy/enemy.gd")
	assert_eq(String(edges[0]["kind"]), "script_preload")

func test_dangling_uid_edge_is_reported_not_navigated() -> void:
	# 注入式：直接构造悬空 UID 边。真实调用 ResourceUID.uid_to_path 查
	# 未注册 UID 时引擎会打印 "Unrecognized UID" 错误（生产环境中这本
	# 就是应看到的诚实报告），但 GUT 会把引擎错误判为测试失败。
	_index._file_hashes[TMP + "/scripts/uid_loader.gd"] = "injected"
	_index._out_edges[TMP + "/scripts/uid_loader.gd"] = [{
		"target": "",
		"uid": "uid://c0notregistered000000000",
		"kind": "script_preload",
		"line": 1,
		"matched_via": "uid",
	}]

	var edges: Array = _index.direct_edges(TMP + "/scripts/uid_loader.gd")
	assert_eq(edges.size(), 1)
	assert_eq(String(edges[0]["target"]), "", "unresolvable uid keeps target empty")
	assert_true(String(edges[0]["uid"]).begins_with("uid://"))

	var dependencies: Array = _index.dependencies_of(TMP + "/scripts/uid_loader.gd")
	assert_eq(dependencies.size(), 0, "dangling uid does not navigate")

# ============================================================================
# project.godot 入口边与确定性
# ============================================================================

func test_project_settings_autoload_is_an_entry_edge() -> void:
	# 注入式：不写真实 ProjectSettings（引擎对 autoload 段的路径↔UID
	# 内部转换会向测试输出注入 Unrecognized UID 噪声错误）。
	var fake_properties: Array = [
		{"name": "autoload/__dep_index_probe__"},
		{"name": "application/run/main_scene"},
	]
	var getter := func(property_name: String) -> String:
		if property_name == "application/run/main_scene":
			return TMP + "/scenes/game.tscn"
		return "*" + TMP + "/actors/player.gd"
	_index._index_project_settings_with(fake_properties, getter)

	var actor_dependents: Array = _index.dependents_of(TMP + "/actors/player.gd")
	assert_eq(actor_dependents.size(), 1, "fake autoload surfaces as a dependent")
	assert_eq(String(actor_dependents[0]["path"]), "res://project.godot")
	assert_eq(String(actor_dependents[0]["matched_via"]), "path")

	var scene_dependents: Array = _index.dependents_of(TMP + "/scenes/game.tscn")
	assert_eq(String((scene_dependents[0] as Dictionary)["path"]),
		"res://project.godot", "main_scene is an entry edge too")

func test_closure_is_deterministic_across_rebuilds() -> void:
	var first: Array = _index.dependents_of(TMP + "/enemy/enemy.gd")
	_index.build(TMP)
	var second: Array = _index.dependents_of(TMP + "/enemy/enemy.gd")
	assert_eq(first, second, "identical fixtures yield identical closures")

func test_unknown_target_returns_empty_honestly() -> void:
	assert_eq(_index.dependents_of("res://not_indexed_anywhere.gd").size(), 0)
	assert_eq(_index.dependencies_of("res://not_indexed_anywhere.gd").size(), 0)

# ============================================================================
# 夹具
# ============================================================================

func _make_dir(path: String) -> void:
	DirAccess.make_dir_recursive_absolute(path)

func _write(path: String, content: String) -> void:
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	file.store_string(content)
	file.close()

func _scene_with_ext(resource_type: String, target_path: String) -> String:
	return '[gd_scene format=2]\n[ext_resource type="%s" path="%s" id="1"]\n[node name="Main" type="Node"]\n' % [
		resource_type, target_path]

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
