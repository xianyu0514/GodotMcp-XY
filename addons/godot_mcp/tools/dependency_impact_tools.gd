@tool
class_name DependencyImpactTools
extends RefCounted

# 变更影响预览（M5 首版）：query_change_impact 在增量依赖索引之上回答
# "改这些文件会波及谁 / 它们依赖谁"，是大型项目安全局部修改的第一步。
#
# 设计约束（对应大型 2D 审计 2026-09-19 的第一项交付验收）：
# - 完整影响、不截断闭包：索引覆盖全部 owner 文件（无 MAX_*_SCAN 上限），
#   传递闭包用 BFS + visited；本工具只做结果分页，分页无损可续查。
# - 诚实边界：不在索引中的目标进 unknown_targets；闭包内文件的非字面量
#   load(...) 以 dynamic_unknowns 披露（行号 + 片段），不冒充确定关系。
# - 新鲜度由证据驱动：优先消费 server_core 的外部变更路径日志做增量
#   更新（游标被环形日志丢弃或无路径 fallback 批次时退化为全量重建，
#   并在 index.freshness 里如实报告模式）；无日志源时每次全量重建。
# - 缓存复用：走 get_or_compute_read_snapshot（与 find_resource_usages
#   同一资源/脚本域 revision tag），文件变化后旧结果自然失效。

const DependencyIndexScript = preload("res://addons/godot_mcp/tools/dependency_index.gd")

## dynamic_unknowns 的条数上限（防止极端项目的巨型披露淹没结果）。
const MAX_DYNAMIC_UNKNOWNS: int = 50

var _editor_interface: EditorInterface = null
var _server_core: RefCounted = null
var _index: ProjectDependencyIndex = null
var _change_cursor: int = -1
## 索引根目录。生产语义固定 res://（全项目影响分析）；测试注入子树
## 夹具以避免整仓扫描。无用户面参数。
var _index_root: String = "res://"

func initialize(editor_interface: EditorInterface) -> void:
	_editor_interface = editor_interface

func register_tools(server_core: RefCounted) -> void:
	_server_core = server_core
	_register_query_change_impact(server_core)

# ============================================================================
# query_change_impact
# ============================================================================

func _register_query_change_impact(server_core: RefCounted) -> void:
	var tool_name: String = "query_change_impact"
	var description: String = "Query the transitive change impact of project files over an incrementally maintained dependency index (identity is full res:// path + UID; same-name files in different directories never conflate). direction=dependents answers 'what does changing these files affect' (direct and nested-scene indirect, each entry carries an evidence chain); direction=dependencies answers 'what do these files need'. Non-literal load() calls inside the affected set are surfaced as dynamic_unknowns — static analysis does not claim them. Results are losslessly paged (limit/offset). Read-only."

	var input_schema: Dictionary = {
		"type": "object",
		"properties": {
			"target_paths": {
				"type": "array",
				"items": {"type": "string"},
				"description": "One or more project file paths, e.g. ['res://actors/enemy.gd']. UIDs are resolved by path identity."
			},
			"direction": {
				"type": "string",
				"enum": ["dependents", "dependencies"],
				"description": "dependents (default): files transitively affected by changing the targets. dependencies: files the targets transitively need.",
				"default": "dependents"
			},
			"max_depth": {
				"type": "integer",
				"description": "Maximum BFS depth. -1 (default) = unlimited; cycles always terminate.",
				"default": -1
			},
			"limit": {
				"type": "integer",
				"description": "Maximum impact entries to return. Default 500.",
				"default": 500
			},
			"offset": {
				"type": "integer",
				"description": "Zero-based impact offset. Continue with next_offset while has_more is true.",
				"default": 0
			}
		},
		"required": ["target_paths"]
	}

	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"target_paths": {"type": "array"},
			"direction": {"type": "string"},
			"max_depth": {"type": "integer"},
			"index": {"type": "object", "description": "indexed_files/edge_count/dynamic_hint_count + freshness evidence"},
			"unknown_targets": {"type": "array", "description": "targets not present in the index (honest emptiness)"},
			"impact": {"type": "array", "items": {"type": "object"}},
			"dynamic_unknowns": {"type": "array", "description": "non-literal load() hints inside the affected set"},
			"dynamic_unknown_truncated": {"type": "boolean"},
			"total_count": {"type": "integer"},
			"truncated": {"type": "boolean"},
			"offset": {"type": "integer"},
			"limit": {"type": "integer"},
			"returned_count": {"type": "integer"},
			"has_more": {"type": "boolean"},
			"next_offset": {"type": "integer"}
		}
	}

	var annotations: Dictionary = {
		"readOnlyHint": true,
		"destructiveHint": false,
		"idempotentHint": true,
		"openWorldHint": false
	}

	server_core.register_tool(tool_name, description, input_schema,
		Callable(self, "_tool_query_change_impact"),
		output_schema, annotations,
		"supplementary", "Project-Advanced")

func _tool_query_change_impact(params: Dictionary) -> Dictionary:
	var raw_targets: Variant = params.get("target_paths", [])
	if not (raw_targets is Array) or (raw_targets as Array).is_empty():
		return {"error": "Missing required parameter: target_paths (non-empty array)"}
	var target_paths: Array[String] = []
	for target_value in raw_targets:
		var target: String = DependencyIndexScript.normalize_path(target_value)
		if target.is_empty():
			continue
		if not target_paths.has(target):
			target_paths.append(target)
	target_paths.sort()
	if target_paths.is_empty():
		return {"error": "target_paths contains no usable path"}

	var direction: String = str(params.get("direction", "dependents"))
	if direction != "dependents" and direction != "dependencies":
		return {"error": "Invalid direction: " + direction + " (expect dependents|dependencies)"}
	var max_depth: int = int(params.get("max_depth", -1))
	var limit: int = int(params.get("limit", 500))
	var offset: int = int(params.get("offset", 0))

	var snapshot: Dictionary = _get_or_compute_read_snapshot(
		"query_change_impact",
		{"target_paths": target_paths, "direction": direction, "max_depth": max_depth},
		func() -> Dictionary: return _scan_change_impact(target_paths, direction, max_depth))
	return _paginate_snapshot(snapshot, "impact", limit, offset)

# ============================================================================
# 索引新鲜度与扫描
# ============================================================================

## 依据外部变更路径日志增量更新索引；游标失效/无路径 fallback/无日志源
## 时全量重建。返回 freshness 证据（模式 + 变更路径数），随结果披露。
func _ensure_index_fresh() -> Dictionary:
	if _index == null:
		_index = DependencyIndexScript.new()
		_index.build(_index_root)
		_change_cursor = _current_log_size()
		return {"mode": "full_build", "refreshed_paths": 0}

	if _server_core == null or not _server_core.has_method("external_changes_since"):
		_index.build(_index_root)
		return {"mode": "full_rebuild_no_source", "refreshed_paths": 0}

	var changes: Dictionary = _server_core.external_changes_since(_change_cursor)
	_change_cursor = int(changes.get("next_index", _change_cursor))
	if not bool(changes.get("available", false)) or bool(changes.get("fallback", false)):
		_index.build(_index_root)
		return {"mode": "full_rebuild_stale_cursor", "refreshed_paths": 0}

	var paths: Array = changes.get("paths", [])
	var structural: bool = not (changes.get("structural_paths", []) as Array).is_empty()
	if paths.is_empty() and not structural:
		return {"mode": "incremental", "refreshed_paths": 0}
	var applied: Dictionary = _index.apply_changes(paths, _index_root, structural)
	return {
		"mode": "incremental",
		"refreshed_paths": int(applied.get("reparsed", 0)) + int(applied.get("removed", 0))
			+ int(applied.get("reconciled", 0)),
	}

func _current_log_size() -> int:
	if _server_core == null or not _server_core.has_method("external_changes_since"):
		return 0
	return int(_server_core.external_changes_since(0).get("next_index", 0))

func _scan_change_impact(target_paths: Array[String], direction: String,
		max_depth: int) -> Dictionary:
	var freshness: Dictionary = _ensure_index_fresh()
	var index_stats: Dictionary = _index.stats()

	var unknown_targets: Array = []
	for target in target_paths:
		if not _index.is_known(target):
			unknown_targets.append(target)

	# 多目标闭包按文件合并：depth 取最小、evidence 取最短链、matched_via
	# 保留首个来源，matched_targets 记录该文件因哪些目标入选。
	var merged: Dictionary = {}
	for target in target_paths:
		var closure: Array = []
		if direction == "dependents":
			closure = _index.dependents_of(target, max_depth)
		else:
			closure = _index.dependencies_of(target, max_depth)
		for entry_value in closure:
			var entry: Dictionary = entry_value
			var path: String = String(entry["path"])
			if not merged.has(path):
				merged[path] = {
					"path": path,
					"depth": int(entry["depth"]),
					"evidence": entry["evidence"],
					"matched_via": String(entry["matched_via"]),
					"matched_targets": [target],
				}
				continue
			var existing: Dictionary = merged[path]
			if int(entry["depth"]) < int(existing["depth"]):
				existing["depth"] = int(entry["depth"])
				existing["evidence"] = entry["evidence"]
				existing["matched_via"] = String(entry["matched_via"])
			var targets: Array = existing["matched_targets"]
			if not targets.has(target):
				targets.append(target)

	var impact: Array = merged.values()
	impact.sort_custom(func(a, b) -> bool:
		if int(a["depth"]) != int(b["depth"]):
			return int(a["depth"]) < int(b["depth"])
		return String(a["path"]) < String(b["path"])
	)

	# 未知关系披露：目标与影响闭包内文件的非字面量 load 疑点。
	var affected: Array = target_paths.duplicate()
	for entry in impact:
		affected.append(String((entry as Dictionary)["path"]))
	var dynamic_unknowns: Array = _index.dynamic_load_hints(affected)
	var dynamic_truncated: bool = dynamic_unknowns.size() > MAX_DYNAMIC_UNKNOWNS
	if dynamic_truncated:
		dynamic_unknowns = dynamic_unknowns.slice(0, MAX_DYNAMIC_UNKNOWNS)

	var index_report: Dictionary = index_stats.duplicate()
	index_report["freshness"] = freshness

	return {
		"target_paths": target_paths,
		"direction": direction,
		"max_depth": max_depth,
		"index": index_report,
		"unknown_targets": unknown_targets,
		"impact": impact,
		"impact_count": impact.size(),
		"total_count": impact.size(),
		"dynamic_unknowns": dynamic_unknowns,
		"dynamic_unknown_truncated": dynamic_truncated,
	}

# ============================================================================
# 缓存 / 分页（与 ProjectResourcesTools 同一套约定）
# ============================================================================

func _get_or_compute_read_snapshot(tool_name: String, arguments: Dictionary,
		producer: Callable) -> Dictionary:
	if _server_core and _server_core.has_method("get_or_compute_read_snapshot"):
		return _server_core.get_or_compute_read_snapshot(tool_name, arguments, producer)
	var produced: Variant = producer.call()
	return produced if produced is Dictionary else {}

func _paginate_snapshot(snapshot: Dictionary, items_key: String, limit: int,
		offset: int) -> Dictionary:
	var result: Dictionary = snapshot.duplicate()
	var page: Dictionary = PayloadUtils.paginate_list(
		snapshot.get(items_key, []), limit, offset)
	result[items_key] = page["items"]
	for field in ["total_count", "truncated", "offset", "limit", "returned_count", "has_more"]:
		result[field] = page[field]
	if page.has("next_offset"):
		result["next_offset"] = page["next_offset"]
	else:
		result.erase("next_offset")
	return result
