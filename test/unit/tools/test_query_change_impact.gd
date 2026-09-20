extends "res://addons/gut/test.gd"

## query_change_impact（M5 首版）工具级测试：参数校验、传递影响 +
## 证据链、分页无损续查、方向查询、多目标合并、未知目标诚实报告、
## 动态 load 披露、以及经变更日志驱动的增量更新接线。

const DependencyImpactToolsScript = preload("res://addons/godot_mcp/tools/dependency_impact_tools.gd")

const TMP: String = "res://.tmp_impact_tool"

## 与 MCPServerCore.external_changes_since 同语义的桩：游标 = next_index。
class StubServerCore:
	extends RefCounted
	var entries: Array = []

	func record_changes(paths: Array, structural: Array = []) -> void:
		entries.append({"paths": paths, "structural_paths": structural})

	func external_changes_since(log_index: int) -> Dictionary:
		var newest: int = entries.size()
		if log_index < 0 or log_index > newest:
			return {
				"available": false, "paths": [], "structural_paths": [],
				"fallback": false, "next_index": newest,
			}
		var paths: Dictionary = {}
		var structural: Dictionary = {}
		for entry_value in entries.slice(log_index):
			var entry: Dictionary = entry_value
			for path_value in entry.get("paths", []):
				paths[String(path_value)] = true
			for path_value in entry.get("structural_paths", []):
				structural[String(path_value)] = true
		return {
			"available": true,
			"paths": paths.keys(),
			"structural_paths": structural.keys(),
			"fallback": false,
			"next_index": newest,
		}

var _tools: RefCounted
var _stub: StubServerCore

func before_each() -> void:
	_make_dir(TMP + "/actors")
	_make_dir(TMP + "/ui")
	_make_dir(TMP + "/scenes")
	_make_dir(TMP + "/enemy")
	_make_dir(TMP + "/levels")
	_write(TMP + "/actors/player.gd", "extends Node\nvar actor_only := true\n")
	_write(TMP + "/ui/player.gd", "extends Control\nvar ui_only := true\n")
	_write(TMP + "/scenes/game.tscn", _scene_with_ext("Script", TMP + "/ui/player.gd"))
	_write(TMP + "/enemy/enemy.gd",
		'extends CharacterBody2D\nvar hp := 10\nvar res = load("res://" + name)\n')
	_write(TMP + "/enemy/enemy.tscn", _scene_with_ext("Script", TMP + "/enemy/enemy.gd"))
	_write(TMP + "/levels/level.tscn", _scene_with_ext("PackedScene", TMP + "/enemy/enemy.tscn"))
	_tools = DependencyImpactToolsScript.new()
	_tools._index_root = TMP
	_stub = StubServerCore.new()
	_tools._server_core = _stub

func after_each() -> void:
	_tools = null
	_stub = null
	_remove_tree(TMP)

# ============================================================================
# 参数校验
# ============================================================================

func test_missing_or_empty_targets_error() -> void:
	assert_has(_tools._tool_query_change_impact({}), "error")
	assert_has(_tools._tool_query_change_impact({"target_paths": []}), "error")
	assert_has(_tools._tool_query_change_impact({"target_paths": ["  "]}), "error")

func test_invalid_direction_errors() -> void:
	assert_has(_tools._tool_query_change_impact({
		"target_paths": [TMP + "/enemy/enemy.gd"], "direction": "sideways",
	}), "error")

# ============================================================================
# 传递影响 + 证据链 + 分页
# ============================================================================

func test_dependents_transitive_with_evidence_and_pagination() -> void:
	var result: Dictionary = _tools._tool_query_change_impact({
		"target_paths": [TMP + "/enemy/enemy.gd"],
	})
	assert_false(result.has("error"), str(result.get("error", "")))
	assert_eq(int(result["total_count"]), 2, "enemy.tscn + level.tscn")
	assert_eq(String(result["index"]["freshness"]["mode"]), "full_build")

	var impact: Array = result["impact"]
	assert_eq(String(impact[0]["path"]), TMP + "/enemy/enemy.tscn")
	assert_eq(int(impact[0]["depth"]), 1)
	assert_eq(String(impact[1]["path"]), TMP + "/levels/level.tscn")
	assert_eq(int(impact[1]["depth"]), 2)
	assert_eq(impact[1]["evidence"], [
		TMP + "/enemy/enemy.gd", TMP + "/enemy/enemy.tscn", TMP + "/levels/level.tscn"])

	# 无损分页：limit=1 时第一页只有直接依赖者，next_offset 指向第二页。
	var page_one: Dictionary = _tools._tool_query_change_impact({
		"target_paths": [TMP + "/enemy/enemy.gd"], "limit": 1,
	})
	assert_eq(int(page_one["returned_count"]), 1)
	assert_true(bool(page_one["has_more"]))
	assert_eq(int(page_one["next_offset"]), 1)
	var page_two: Dictionary = _tools._tool_query_change_impact({
		"target_paths": [TMP + "/enemy/enemy.gd"], "limit": 1, "offset": 1,
	})
	assert_eq(int(page_two["returned_count"]), 1)
	assert_eq(String((page_two["impact"] as Array)[0]["path"]), TMP + "/levels/level.tscn")
	assert_false(bool(page_two["has_more"]))

func test_dependencies_direction() -> void:
	var result: Dictionary = _tools._tool_query_change_impact({
		"target_paths": [TMP + "/levels/level.tscn"],
		"direction": "dependencies",
	})
	var impact: Array = result["impact"]
	assert_eq(impact.size(), 2)
	assert_eq(String(impact[0]["path"]), TMP + "/enemy/enemy.tscn")
	assert_eq(String(impact[1]["path"]), TMP + "/enemy/enemy.gd")

func test_same_name_targets_stay_distinct() -> void:
	var ui_result: Dictionary = _tools._tool_query_change_impact({
		"target_paths": [TMP + "/ui/player.gd"],
	})
	assert_eq(int(ui_result["total_count"]), 1)
	assert_eq(String((ui_result["impact"] as Array)[0]["path"]), TMP + "/scenes/game.tscn")

	var actor_result: Dictionary = _tools._tool_query_change_impact({
		"target_paths": [TMP + "/actors/player.gd"],
	})
	assert_eq(int(actor_result["total_count"]), 0, "actors copy is referenced by nothing")
	assert_eq((actor_result["unknown_targets"] as Array).size(), 0,
		"it is indexed and known — just unreferenced, which is not 'unknown'")

func test_multiple_targets_merge_with_matched_targets() -> void:
	var result: Dictionary = _tools._tool_query_change_impact({
		"target_paths": [TMP + "/enemy/enemy.gd", TMP + "/ui/player.gd"],
	})
	assert_eq(int(result["total_count"]), 3, "2 enemy chain + 1 game.tscn")
	var by_path: Dictionary = {}
	for entry in result["impact"]:
		by_path[String((entry as Dictionary)["path"])] = entry
	var scene_entry: Dictionary = by_path[TMP + "/scenes/game.tscn"]
	assert_eq((scene_entry["matched_targets"] as Array), [TMP + "/ui/player.gd"])
	var enemy_scene: Dictionary = by_path[TMP + "/enemy/enemy.tscn"]
	assert_eq((enemy_scene["matched_targets"] as Array), [TMP + "/enemy/enemy.gd"])

func test_unknown_target_reported_not_swallowed() -> void:
	var result: Dictionary = _tools._tool_query_change_impact({
		"target_paths": [TMP + "/enemy/enemy.gd", "res://never_seen_anywhere.gd"],
	})
	assert_eq((result["unknown_targets"] as Array), ["res://never_seen_anywhere.gd"])
	assert_eq(int(result["total_count"]), 2, "known target still answers")

func test_max_depth_limits_impact() -> void:
	var result: Dictionary = _tools._tool_query_change_impact({
		"target_paths": [TMP + "/enemy/enemy.gd"], "max_depth": 1,
	})
	assert_eq(int(result["total_count"]), 1)

func test_dynamic_load_unknowns_disclosed() -> void:
	var result: Dictionary = _tools._tool_query_change_impact({
		"target_paths": [TMP + "/enemy/enemy.gd"],
	})
	var unknowns: Array = result["dynamic_unknowns"]
	assert_eq(unknowns.size(), 1, "enemy.gd's non-literal load is disclosed")
	assert_eq(String(unknowns[0]["path"]), TMP + "/enemy/enemy.gd")
	assert_eq(int(unknowns[0]["line"]), 3)
	assert_false(bool(result["dynamic_unknown_truncated"]))

# ============================================================================
# 增量更新接线（变更日志 → 索引 apply_changes）
# ============================================================================

func test_incremental_refresh_via_change_log() -> void:
	var first: Dictionary = _tools._tool_query_change_impact({
		"target_paths": [TMP + "/actors/player.gd"],
	})
	assert_eq(int(first["total_count"]), 0)

	# 编辑 game.tscn 改引 actors/player.gd，并把该变更喂给日志。
	_write(TMP + "/scenes/game.tscn", _scene_with_ext("Script", TMP + "/actors/player.gd"))
	_stub.record_changes([TMP + "/scenes/game.tscn"])

	var second: Dictionary = _tools._tool_query_change_impact({
		"target_paths": [TMP + "/actors/player.gd"],
	})
	assert_eq(String((second["index"]["freshness"] as Dictionary)["mode"]), "incremental")
	assert_gt(int((second["index"]["freshness"] as Dictionary)["refreshed_paths"]), 0)
	assert_eq(int(second["total_count"]), 1, "the new edge is visible after refresh")
	assert_eq(String((second["impact"] as Array)[0]["path"]), TMP + "/scenes/game.tscn")

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
