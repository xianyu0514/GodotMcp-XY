class_name ProjectDependencyIndex
extends RefCounted

# 增量项目依赖索引（M5 首版）：跨场景影响分析与变更预览的数据层。
#
# 设计约束（对应大型 2D 审计 2026-09-19 的第一项交付）：
# - 身份用完整 res:// 路径与 UID，绝不使用文件名子串匹配——不同目录的
#   同名脚本（actors/player.gd vs ui/player.gd）不允许混淆。
# - 覆盖引擎解析盲区：实测 ResourceLoader.get_dependencies("*.gd") 返回
#   空数组，脚本的 preload/load 字面量依赖必须自行解析；C# 以 res://
#   字符串字面量为弱边（kind 标注，不冒充强引用）。
# - 确定关系与未知关系分开：非字面量 load(...) 无法静态求值，记录为
#   dynamic 疑点（行号 + 片段）如实报告，不声称静态扫描覆盖所有行为。
# - 索引没有扫描上限：owner 集合是全量文件列表，传递影响用 BFS 闭包
#   （visited 防循环），分页由工具层负责，这里不做截断。
# - 增量更新以内容哈希为准：同哈希重复通知不重复解析；文件消失时
#   摘除其全部出边；结构性变化（增删文件）通过 owner 集合对账补齐。
#
# 该文件是纯逻辑支持层（同 ChangeJournal/TaskPlanStore），不注册 MCP
# 工具、不耦合编辑器接口；工具层（query_change_impact、
# gather_task_context）负责参数校验、缓存与调用。

const OWNER_EXTENSIONS: Array[String] = [
	".tscn", ".scn", ".tres", ".res", ".gd", ".cs", ".material"
]
const ENGINE_PARSED_EXTENSIONS: Array[String] = [
	".tscn", ".scn", ".tres", ".res", ".material"
]
const PROJECT_SETTINGS_OWNER: String = "res://project.godot"

## 出边：owner -> Array[{target, uid, kind, matched_via, line}]
var _out_edges: Dictionary = {}
## 入边：target -> {owner -> 首条边（同对多条边合并报告）}
var _in_edges: Dictionary = {}
## 动态 load 疑点：owner -> Array[{line, snippet}]
var _dynamic_loads: Dictionary = {}
## owner -> 内容 sha256（增量判定；同哈希跳过）
var _file_hashes: Dictionary = {}

## call(开头用于定位所有 preload/load 调用头，参数形态随后判定。
const SCRIPT_CALL_HEAD_REGEX: String = "(?:\\bpreload|\\bload)\\s*\\("
## 调用头后的字符串字面量（res:// 或 uid://）。
const SCRIPT_LITERAL_REGEX: String = "\"((?:res://|uid://)[^\"]+)\""
## C# 源里任何含 res:// 的字符串字面量（弱边，kind 单独标注）。
const CS_LITERAL_REGEX: String = "\"([^\"\\r\\n]*res://[^\"\\r\\n]*)\""


# ============================================================================
# 构建 / 增量
# ============================================================================

## 全量构建：收集 search_path 下全部 owner 文件并解析；project.godot 的
## autoload 与主场景作为入口边单独索引（它们是真实的运行期依赖者）。
func build(search_path: String = "res://") -> Dictionary:
	var owners: Array[String] = []
	ProjectToolsNative._collect_resources(search_path, OWNER_EXTENSIONS, owners)
	owners.sort()
	_out_edges.clear()
	_in_edges.clear()
	_dynamic_loads.clear()
	_file_hashes.clear()
	for owner_path in owners:
		_index_one_file(owner_path)
	_index_project_settings()
	return stats()


## 应用一批外部变更路径。exists=假 → 摘除；内容同哈希 → 跳过（幂等）；
## 其余重解析。structural=真时对账 owner 集合（目录级增删后的新文件）。
## 返回 {reparsed, removed, skipped, reconciled}。
func apply_changes(paths: Array, search_path: String = "res://",
		structural: bool = false) -> Dictionary:
	var reparsed: int = 0
	var removed: int = 0
	var skipped: int = 0
	for path_value in paths:
		var path: String = normalize_path(path_value)
		if path.is_empty():
			continue
		if path == PROJECT_SETTINGS_OWNER:
			_remove_owner(PROJECT_SETTINGS_OWNER)
			_index_project_settings()
			reparsed += 1
			continue
		if not _is_owner_extension(path):
			continue
		if not FileAccess.file_exists(path):
			if _file_hashes.has(path):
				_remove_owner(path)
				removed += 1
			continue
		if _file_hashes.has(path) and FileAccess.get_sha256(path) == String(_file_hashes[path]):
			skipped += 1
			continue
		_index_one_file(path)
		reparsed += 1

	var reconciled: int = 0
	if structural:
		var current: Array[String] = []
		ProjectToolsNative._collect_resources(search_path, OWNER_EXTENSIONS, current)
		var current_set: Dictionary = {}
		for path_value in current:
			current_set[normalize_path(path_value)] = true
		for known_owner in _file_hashes.keys():
			if known_owner == PROJECT_SETTINGS_OWNER:
				continue
			if not current_set.has(known_owner):
				_remove_owner(String(known_owner))
				removed += 1
		for path_value in current_set.keys():
			var path: String = String(path_value)
			if not _file_hashes.has(path):
				_index_one_file(path)
				reconciled += 1
	return {
		"reparsed": reparsed,
		"removed": removed,
		"skipped": skipped,
		"reconciled": reconciled,
	}


func stats() -> Dictionary:
	var edge_count: int = 0
	for owner_value in _out_edges:
		edge_count += (_out_edges[owner_value] as Array).size()
	var dynamic_count: int = 0
	for owner_value in _dynamic_loads:
		dynamic_count += (_dynamic_loads[owner_value] as Array).size()
	return {
		"indexed_files": _file_hashes.size(),
		"edge_count": edge_count,
		"dynamic_hint_count": dynamic_count,
	}


func has_file(path: String) -> bool:
	return _file_hashes.has(normalize_path(path))


## 目标是否被索引认知：是已索引文件，或至少被某个文件引用（如纯纹理
## 资源不是 owner，但场景对它的引用边使影响查询仍有意义）。
func is_known(path: String) -> bool:
	var normalized: String = normalize_path(path)
	return _file_hashes.has(normalized) or _in_edges.has(normalized)


func direct_edges(owner: String) -> Array:
	var edges: Array = (_out_edges.get(normalize_path(owner), []) as Array)
	return edges.duplicate()


## 给定文件集合的动态 load 疑点（影响闭包内文件的"未知关系"披露）。
func dynamic_load_hints(paths: Array) -> Array:
	var hints: Array = []
	for path_value in paths:
		var path: String = normalize_path(str(path_value))
		for hint in (_dynamic_loads.get(path, []) as Array):
			var entry: Dictionary = (hint as Dictionary).duplicate()
			entry["path"] = path
			hints.append(entry)
	hints.sort_custom(func(a, b) -> bool:
		if int(a["line"]) != int(b["line"]):
			return int(a["line"]) < int(b["line"])
		return String(a["path"]) < String(b["path"])
	)
	return hints


# ============================================================================
# 影响查询（BFS 传递闭包，visited 防循环）
# ============================================================================

## 谁传递依赖目标（含间接）：改目标会影响到的全部文件。
## max_depth < 0 表示不限（默认）；结果按 depth 升序、路径字典序。
func dependents_of(target: String, max_depth: int = -1) -> Array:
	return _closure_over(normalize_path(target), max_depth, true)


## 目标传递依赖谁：目标正常运行/加载需要的全部文件。
func dependencies_of(target: String, max_depth: int = -1) -> Array:
	return _closure_over(normalize_path(target), max_depth, false)


func _closure_over(target: String, max_depth: int, reverse: bool) -> Array:
	if target.is_empty():
		return []
	# 目标既不是已索引文件、也没有任何入边（如从未被引用的外部资源）
	# 时诚实返回空；是 owner 但无人引用同样得到合法的空闭包。
	if not _file_hashes.has(target) and not _in_edges.has(target):
		return []
	var depth: Dictionary = {target: 0}
	var evidence: Dictionary = {target: [target]}
	var queue: Array = [target]
	var results: Array = []
	var head: int = 0
	while head < queue.size():
		var current: String = String(queue[head])
		head += 1
		var current_depth: int = int(depth[current])
		if max_depth >= 0 and current_depth >= max_depth:
			continue
		var neighbors: Dictionary = _neighbors(current, reverse)
		for neighbor_value in neighbors:
			var neighbor: String = String(neighbor_value)
			if depth.has(neighbor):
				continue
			depth[neighbor] = current_depth + 1
			var chain: Array = (evidence[current] as Array).duplicate()
			chain.append(neighbor)
			evidence[neighbor] = chain
			queue.append(neighbor)
			var edge: Dictionary = {}
			if neighbors[neighbor] is Dictionary:
				edge = neighbors[neighbor]
			results.append({
				"path": neighbor,
				"depth": current_depth + 1,
				"evidence": chain,
				"matched_via": String(edge.get("matched_via", "path")),
			})
	results.sort_custom(func(a, b) -> bool:
		if int(a["depth"]) != int(b["depth"]):
			return int(a["depth"]) < int(b["depth"])
		return String(a["path"]) < String(b["path"])
	)
	return results


func _neighbors(path: String, reverse: bool) -> Dictionary:
	if reverse:
		return _in_edges.get(path, {}) as Dictionary
	var result: Dictionary = {}
	for edge in (_out_edges.get(path, []) as Array):
		var target: String = String((edge as Dictionary).get("target", ""))
		if not target.is_empty() and not result.has(target):
			result[target] = edge
	return result


# ============================================================================
# 单文件索引
# ============================================================================

func _index_one_file(path: String) -> void:
	path = normalize_path(path)
	if not _is_owner_extension(path):
		return
	_remove_owner(path)
	var hash_value: String = FileAccess.get_sha256(path)
	if hash_value.is_empty():
		return
	_file_hashes[path] = hash_value
	var edges: Array = []
	var dynamic: Array = []
	var extension: String = path.get_extension().to_lower()
	if extension == "gd":
		var content: String = _read_text(path)
		var parsed: Dictionary = parse_script_references(content)
		edges = parsed["edges"]
		dynamic = parsed["dynamic"]
	elif extension == "cs":
		var content: String = _read_text(path)
		edges = parse_csharp_references(content)
	else:
		edges = _engine_dependencies(path)
	if not edges.is_empty():
		_out_edges[path] = edges
	if not dynamic.is_empty():
		_dynamic_loads[path] = dynamic
	for edge_value in edges:
		var edge: Dictionary = edge_value
		var target: String = String(edge.get("target", ""))
		if target.is_empty():
			continue
		if not _in_edges.has(target):
			_in_edges[target] = {}
		(_in_edges[target] as Dictionary)[path] = edge


## autoload 单例与主场景是真实的运行期依赖者：以 project.godot 为 owner
## 建立 project_setting 边，改 autoload 脚本时影响查询能看到入口。
## 属性列表与取值器可注入（单测不写真实 ProjectSettings，避免引擎对
## autoload 段的路径↔UID 内部转换把噪声错误挂到测试上）。
func _index_project_settings() -> void:
	_index_project_settings_with(ProjectSettings.get_property_list(),
		func(property_name: String) -> String:
			return str(ProjectSettings.get_setting(property_name, "")))

func _index_project_settings_with(property_list: Array, getter: Callable) -> void:
	_remove_owner(PROJECT_SETTINGS_OWNER)
	_file_hashes[PROJECT_SETTINGS_OWNER] = "settings"
	var edges: Array = []
	var main_scene: String = normalize_path(getter.call("application/run/main_scene"))
	if not main_scene.is_empty():
		edges.append(_edge(main_scene, "", "project_setting", -1))
	for property in property_list:
		var property_name: String = str((property as Dictionary).get("name", ""))
		if not property_name.begins_with("autoload/"):
			continue
		var autoload_path: String = normalize_path(
			getter.call(property_name).trim_prefix("*"))
		if autoload_path.is_empty():
			continue
		edges.append(_edge(autoload_path, "", "project_setting", -1))
	if not edges.is_empty():
		_out_edges[PROJECT_SETTINGS_OWNER] = edges
		for edge_value in edges:
			var target: String = String((edge_value as Dictionary).get("target", ""))
			if target.is_empty():
				continue
			if not _in_edges.has(target):
				_in_edges[target] = {}
			(_in_edges[target] as Dictionary)[PROJECT_SETTINGS_OWNER] = edge_value


func _remove_owner(path: String) -> void:
	path = normalize_path(path)
	_file_hashes.erase(path)
	_dynamic_loads.erase(path)
	for edge_value in (_out_edges.get(path, []) as Array):
		var target: String = String((edge_value as Dictionary).get("target", ""))
		if target.is_empty():
			continue
		if _in_edges.has(target):
			(_in_edges[target] as Dictionary).erase(path)
			if (_in_edges[target] as Dictionary).is_empty():
				_in_edges.erase(target)
	_out_edges.erase(path)


# ============================================================================
# 解析：引擎资源 / GDScript / C# / project.godot
# ============================================================================

## 引擎级解析（.tscn/.tres 等）。raw 形如 "uid://x::Type::res://path" 或
## 纯 "res://path"；uid 可解析时以 uid 为准（与 find_resource_usages 的
## matched_via 口径一致）。
static func _engine_dependencies(path: String) -> Array:
	var edges: Array = []
	for raw_dependency in ResourceLoader.get_dependencies(path):
		var raw_text: String = str(raw_dependency)
		var uid: String = ""
		var fallback_path: String = raw_text
		var resolved_path: String = raw_text
		var matched_via: String = "path"
		if raw_text.contains("::"):
			uid = raw_text.get_slice("::", 0)
			fallback_path = raw_text.get_slice("::", 2)
			resolved_path = fallback_path
			if uid.begins_with("uid://"):
				var uid_path: String = ResourceUID.uid_to_path(uid)
				if not uid_path.is_empty():
					resolved_path = uid_path
					matched_via = "uid"
		edges.append(_edge(normalize_path(resolved_path), uid, "ext_resource",
			-1, matched_via))
	return edges


## 解析 GDScript 的 preload/load 字面量依赖与非字面量动态疑点。
## 字面量含 uid:// 时经 ResourceUID 解析；未注册的 UID 保留在边上、
## target 置空（诚实呈现悬空引用，不进图导航）。
static func parse_script_references(content: String) -> Dictionary:
	var edges: Array = []
	var dynamic: Array = []
	var call_head: RegEx = RegEx.new()
	call_head.compile(SCRIPT_CALL_HEAD_REGEX)
	var literal_pattern: RegEx = RegEx.new()
	literal_pattern.compile(SCRIPT_LITERAL_REGEX)
	for match_result in call_head.search_all(content):
		var rest: String = content.substr(match_result.get_end())
		var trimmed: String = rest.strip_edges(true, false)
		if not trimmed.begins_with("\""):
			dynamic.append({
				"line": _line_of(content, match_result.get_start()),
				"snippet": _snippet_at(content, match_result.get_start()),
			})
			continue
		var literal_match: RegExMatch = literal_pattern.search(rest)
		if literal_match == null:
			dynamic.append({
				"line": _line_of(content, match_result.get_start()),
				"snippet": _snippet_at(content, match_result.get_start()),
			})
			continue
		var reference: String = literal_match.get_string(1)
		var line: int = _line_of(content, match_result.get_start())
		if reference.begins_with("uid://"):
			var uid_path: String = ResourceUID.uid_to_path(reference)
			edges.append(_edge(normalize_path(uid_path), reference,
				"script_preload", line, "uid"))
		else:
			edges.append(_edge(normalize_path(reference), "", "script_preload",
				line, "path"))
	return {"edges": edges, "dynamic": dynamic}


## C#：提取含 res:// 的字符串字面量为弱边（ResourceLoader.Load 与字符串
## 常量均覆盖；类型标注区分，不冒充 GDScript 强 preload）。
static func parse_csharp_references(content: String) -> Array:
	var edges: Array = []
	var literal_pattern: RegEx = RegEx.new()
	literal_pattern.compile(CS_LITERAL_REGEX)
	for match_result in literal_pattern.search_all(content):
		edges.append(_edge(normalize_path(match_result.get_string(1)), "",
			"cs_string_literal", _line_of(content, match_result.get_start()),
			"path"))
	return edges


static func _edge(target: String, uid: String, kind: String, line: int,
		matched_via: String = "path") -> Dictionary:
	return {
		"target": target,
		"uid": uid,
		"kind": kind,
		"line": line,
		"matched_via": matched_via,
	}


static func _read_text(path: String) -> String:
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		return ""
	var content: String = file.get_as_text()
	file.close()
	return content


static func _line_of(content: String, offset: int) -> int:
	return content.count("\n", 0, offset) + 1


static func _snippet_at(content: String, offset: int) -> String:
	var line_end: int = content.find("\n", offset)
	if line_end < 0:
		line_end = content.length()
	var snippet: String = content.substr(offset, line_end - offset).strip_edges()
	return snippet.substr(0, mini(snippet.length(), 80))


static func _is_owner_extension(path: String) -> bool:
	for extension in OWNER_EXTENSIONS:
		if path.ends_with(extension):
			return true
	return false


static func normalize_path(path_value: Variant) -> String:
	var normalized: String = str(path_value).strip_edges().replace("\\", "/")
	if normalized.begins_with("res:/") and not normalized.begins_with("res://"):
		normalized = "res://" + normalized.substr(5)
	while normalized.contains("//") and not normalized.begins_with("res://"):
		normalized = normalized.replace("//", "/")
	return normalized
