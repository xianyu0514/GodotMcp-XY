# fixture_manager.gd — 测试 Fixture 作用域与一次性清理
#
# 背景：覆盖测试会创建大量 fault_* / coverage_* / probe_* 临时资源，散落在
# res:// 各处，最后清理非常费力，还容易把测试垃圾误判成项目健康问题。
#
# 约定：
#   - 所有 fixture 归属一个 fixture_id，默认落在 res://.mcp/fixtures/<id>/
#   - .mcp 已被项目健康扫描与依赖扫描排除（见 generated_cache_filter）
#   - cleanup(fixture_id) 一次清空该 scope 的全部文件与登记的节点
#   - 每个 scope 带租约（lease），超时可被自动回收，防止僵尸 fixture 累积

class_name MCPFixtureManager
extends RefCounted

## fixture 根目录。位于 .mcp 下，天然被生成缓存过滤规则排除。
const FIXTURE_ROOT: String = "res://.mcp/fixtures"

## 默认租约时长。超时未续约的 scope 会被 cleanup_expired 回收。
const DEFAULT_LEASE_MS: int = 24 * 60 * 60 * 1000

## 单次 cleanup 允许删除的最大文件数，防止误删扩散
const MAX_REMOVE_PER_CLEANUP: int = 2000

## 允许的 fixture 名称字符
const MANIFEST_NAME: String = "manifest.json"

var _scopes: Dictionary = {}
var _created_scopes: int = 0
var _removed_files: int = 0
var _removed_dirs: int = 0
var _failed_removals: int = 0


# ---------------------------------------------------------------------------
# 作用域管理
# ---------------------------------------------------------------------------

## 创建一个 fixture 作用域。
##
## options:
##   root: String         —— 自定义根目录（必须仍在 .mcp/fixtures 下）
##   lease_ms: int        —— 租约时长
##   tags: Array          —— 便于报告的标签
##   description: String
func create_scope(name: String, options: Dictionary = {}) -> Dictionary:
	var clean_name: String = _safe_name(name)
	if clean_name.is_empty():
		clean_name = "scope_%d" % (_created_scopes + 1)
	var custom_root: String = String(options.get("root", "")).strip_edges()
	var root: String = custom_root
	if root.is_empty():
		root = "%s/%s_%s" % [FIXTURE_ROOT, clean_name, _short_id()]
	if not _is_fixture_path(root):
		return {"error": "fixture root must live under %s, got '%s'" % [FIXTURE_ROOT, root]}
	if _scopes.has(root):
		return {
			"fixture_id": root,
			"root": root,
			"reused": true,
			"paths": (_scopes[root] as Dictionary).get("paths", [])
		}
	var lease_ms: int = int(options.get("lease_ms", DEFAULT_LEASE_MS))
	var scope: Dictionary = {
		"fixture_id": root,
		"name": clean_name,
		"root": root,
		"created_at": Time.get_datetime_string_from_system(true),
		"created_at_msec": Time.get_ticks_msec(),
		"lease_ms": maxi(0, lease_ms),
		"paths": [],
		"directories": [],
		"nodes": [],
		"tags": _string_array(options.get("tags", [])),
		"description": String(options.get("description", ""))
	}
	if DirAccess.make_dir_recursive_absolute(root) != OK and not DirAccess.dir_exists_absolute(root):
		return {"error": "cannot create fixture directory: " + root}
	_scopes[root] = scope
	_created_scopes += 1
	_write_manifest(scope)
	var result: Dictionary = scope.duplicate(true)
	result["reused"] = false
	return result


## 登记一个由该 scope 创建的文件路径
func register_path(fixture_id: String, path: String) -> Dictionary:
	var scope: Dictionary = _require_scope(fixture_id)
	if scope.is_empty():
		return {"error": "unknown fixture scope: " + fixture_id}
	var normalized: String = _normalize(path)
	if normalized.is_empty():
		return {"error": "path is required"}
	var paths: Array = scope["paths"]
	if not normalized in paths:
		paths.append(normalized)
	var directory: String = normalized.get_base_dir()
	var directories: Array = scope["directories"]
	if directory.begins_with(scope["root"]) and not directory in directories:
		directories.append(directory)
	_write_manifest(scope)
	return {"fixture_id": fixture_id, "path": normalized, "tracked": paths.size()}


## 登记一个由该 scope 创建的场景节点路径（清理时提示需要撤销的编辑）
func register_node(fixture_id: String, node_path: String) -> Dictionary:
	var scope: Dictionary = _require_scope(fixture_id)
	if scope.is_empty():
		return {"error": "unknown fixture scope: " + fixture_id}
	var normalized: String = node_path.strip_edges()
	if normalized.is_empty():
		return {"error": "node_path is required"}
	var nodes: Array = scope["nodes"]
	if not normalized in nodes:
		nodes.append(normalized)
	return {"fixture_id": fixture_id, "node_path": normalized, "tracked": nodes.size()}


func get_scope(fixture_id: String) -> Dictionary:
	var scope: Dictionary = _require_scope(fixture_id)
	if scope.is_empty():
		return {}
	return scope.duplicate(true)


func list_scopes() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for root_value in _scopes:
		var scope: Dictionary = _scopes[root_value]
		result.append({
			"fixture_id": String(scope.get("fixture_id", "")),
			"name": String(scope.get("name", "")),
			"root": String(scope.get("root", "")),
			"created_at": String(scope.get("created_at", "")),
			"paths": (scope.get("paths", []) as Array).size(),
			"nodes": (scope.get("nodes", []) as Array).size(),
			"tags": scope.get("tags", []),
			"expired": is_expired(String(scope.get("fixture_id", "")))
		})
	result.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return String(a.get("fixture_id", "")) < String(b.get("fixture_id", ""))
	)
	return result


func is_expired(fixture_id: String) -> bool:
	var scope: Dictionary = _require_scope(fixture_id)
	if scope.is_empty():
		return false
	var lease: int = int(scope.get("lease_ms", DEFAULT_LEASE_MS))
	if lease <= 0:
		return false
	return Time.get_ticks_msec() - int(scope.get("created_at_msec", 0)) > lease


# ---------------------------------------------------------------------------
# 清理
# ---------------------------------------------------------------------------

## 清理一个 scope：删除登记的文件、目录以及目录内未被登记的残留文件。
## 返回 {fixture_id, removed_files, removed_dirs, failed, nodes_to_revert}
func cleanup(fixture_id: String) -> Dictionary:
	var scope: Dictionary = _require_scope(fixture_id)
	if scope.is_empty():
		return {"error": "unknown fixture scope: " + fixture_id}
	var removed_files: int = 0
	var removed_dirs: int = 0
	var failed: Array[String] = []
	var budget: int = MAX_REMOVE_PER_CLEANUP

	# 1) 删除登记的文件
	var paths: Array = scope.get("paths", [])
	paths.sort()
	paths.reverse()
	for path_value in paths:
		if budget <= 0:
			failed.append("cleanup budget exhausted")
			break
		var path: String = String(path_value)
		if FileAccess.file_exists(path):
			if DirAccess.remove_absolute(path) != OK:
				failed.append(path)
				continue
			removed_files += 1
			budget -= 1
		# 同时清理 Godot 的 .import 与 .uid 伴随文件
		for suffix in [".import", ".uid"]:
			var companion: String = path + suffix
			if FileAccess.file_exists(companion):
				DirAccess.remove_absolute(companion)

	# 2) 删除整个 scope 目录（含未登记的残留）
	var root: String = String(scope.get("root", ""))
	if not root.is_empty() and DirAccess.dir_exists_absolute(root):
		var residual: int = _remove_tree(root, budget)
		removed_files += residual
		budget -= residual
		if DirAccess.dir_exists_absolute(root):
			failed.append(root + " (directory remains)")
		else:
			removed_dirs += 1

	# 3) 删除登记的子目录（若位于 root 之外）
	var directories: Array = scope.get("directories", [])
	directories.sort()
	directories.reverse()
	for directory_value in directories:
		var directory: String = String(directory_value)
		if directory == root or not DirAccess.dir_exists_absolute(directory):
			continue
		removed_files += _remove_tree(directory, budget)
		removed_dirs += 1

	_scopes.erase(root)
	_removed_files += removed_files
	_removed_dirs += removed_dirs
	_failed_removals += failed.size()
	return {
		"fixture_id": fixture_id,
		"root": root,
		"removed_files": removed_files,
		"removed_dirs": removed_dirs,
		"failed": failed,
		"nodes_to_revert": (scope.get("nodes", []) as Array).duplicate()
	}


## 清理全部 scope
func cleanup_all() -> Dictionary:
	var cleaned: Array[Dictionary] = []
	var failed: Array[String] = []
	for root_value in (_scopes.keys() as Array).duplicate():
		var result: Dictionary = cleanup(String(root_value))
		if result.has("error"):
			failed.append(String(result["error"]))
			continue
		cleaned.append({
			"fixture_id": String(result.get("fixture_id", "")),
			"removed_files": int(result.get("removed_files", 0)),
			"removed_dirs": int(result.get("removed_dirs", 0))
		})
	return {"cleaned": cleaned, "failed": failed, "scopes": cleaned.size()}


## 回收过期 scope
func cleanup_expired() -> Dictionary:
	var cleaned: Array[String] = []
	for root_value in (_scopes.keys() as Array).duplicate():
		var fixture_id: String = String(root_value)
		if is_expired(fixture_id):
			cleanup(fixture_id)
			cleaned.append(fixture_id)
	return {"cleaned": cleaned, "count": cleaned.size()}


## 磁盘上的孤儿 fixture 目录（有目录但没有活动 scope 记录）
func find_orphans() -> Array[String]:
	var orphans: Array[String] = []
	var dir: DirAccess = DirAccess.open(FIXTURE_ROOT)
	if dir == null:
		return orphans
	dir.list_dir_begin()
	var entry: String = dir.get_next()
	while not entry.is_empty():
		if dir.current_is_dir() and not entry.begins_with("."):
			var full_path: String = "%s/%s" % [FIXTURE_ROOT, entry]
			if not _scopes.has(full_path):
				orphans.append(full_path)
		entry = dir.get_next()
	dir.list_dir_end()
	orphans.sort()
	return orphans


## 清理磁盘上的孤儿目录
func cleanup_orphans() -> Dictionary:
	var removed: Array[String] = []
	for path in find_orphans():
		_remove_tree(path, MAX_REMOVE_PER_CLEANUP)
		if not DirAccess.dir_exists_absolute(path):
			removed.append(path)
	return {"removed": removed, "count": removed.size()}


func stats() -> Dictionary:
	var tracked_paths: int = 0
	for root_value in _scopes:
		tracked_paths += ((_scopes[root_value] as Dictionary).get("paths", []) as Array).size()
	return {
		"scopes": _scopes.size(),
		"tracked_paths": tracked_paths,
		"created_scopes": _created_scopes,
		"removed_files": _removed_files,
		"removed_dirs": _removed_dirs,
		"failed_removals": _failed_removals,
		"root": FIXTURE_ROOT,
		"orphans": find_orphans().size()
	}


# ---------------------------------------------------------------------------
# 内部实现
# ---------------------------------------------------------------------------

func _require_scope(fixture_id: String) -> Dictionary:
	var key: String = fixture_id.strip_edges()
	if key.is_empty():
		return {}
	if _scopes.has(key):
		return _scopes[key]
	# 允许用 name 反查
	for root_value in _scopes:
		var scope: Dictionary = _scopes[root_value]
		if String(scope.get("name", "")) == key:
			return scope
	return {}


func _remove_tree(path: String, budget: int) -> int:
	if not DirAccess.dir_exists_absolute(path):
		return 0
	var removed: int = 0
	var remaining: int = budget
	var dir: DirAccess = DirAccess.open(path)
	if dir == null:
		return 0
	dir.list_dir_begin()
	var entry: String = dir.get_next()
	while not entry.is_empty():
		var full_path: String = "%s/%s" % [path, entry]
		if dir.current_is_dir():
			removed += _remove_tree(full_path, remaining)
		else:
			if remaining > 0:
				DirAccess.remove_absolute(full_path)
				removed += 1
				remaining -= 1
		entry = dir.get_next()
	dir.list_dir_end()
	var parent: DirAccess = DirAccess.open(path.get_base_dir())
	if parent != null:
		parent.remove(path)
	return removed


func _write_manifest(scope: Dictionary) -> void:
	var payload: String = JSON.stringify(scope, "\t")
	var file: FileAccess = FileAccess.open(
		"%s/%s" % [String(scope.get("root", "")), MANIFEST_NAME], FileAccess.WRITE)
	if file == null:
		return
	file.store_string(payload)
	file.close()


static func _is_fixture_path(path: String) -> bool:
	var normalized: String = _normalize(path)
	return normalized == FIXTURE_ROOT or normalized.begins_with(FIXTURE_ROOT + "/")


static func _safe_name(value: String) -> String:
	var text: String = value.strip_edges().to_lower()
	var result: String = ""
	for character in text:
		var code: int = character.unicode_at(0)
		var is_alnum: bool = (code >= 48 and code <= 57) or (code >= 97 and code <= 122)
		if is_alnum or character == "_" or character == "-":
			result += character
		elif character == " ":
			result += "_"
	return result.substr(0, 48)


static func _short_id() -> String:
	return String.num(Time.get_ticks_usec() % 100000000, 0).pad_zeros(8)


static func _normalize(path_value: Variant) -> String:
	var normalized: String = str(path_value).strip_edges().replace("\\", "/")
	if normalized.begins_with("res:/") and not normalized.begins_with("res://"):
		normalized = "res://" + normalized.substr(5)
	while normalized.contains("//") and not normalized.begins_with("res://"):
		normalized = normalized.replace("//", "/")
	return normalized.trim_suffix("/")


static func _string_array(value: Variant) -> Array[String]:
	var result: Array[String] = []
	if not (value is Array):
		return result
	for item in (value as Array):
		result.append(String(item))
	return result
