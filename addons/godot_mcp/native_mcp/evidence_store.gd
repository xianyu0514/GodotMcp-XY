# evidence_store.gd — 工作流证据落盘与引用
#
# 背景：Workflow 对工具结果做过过度压缩，assert_performance_budget 原本返回
# fps / frame_time / checks[] / thresholds / actual_values，进入 receipt 后只剩
# "status: completed"，导致失败时根本无法定位是哪一条检查没过。
#
# 原则：**大结果不删除，而是落盘**。receipt 只保留 evidence_ref + evidence_digest，
# 需要复查时按 ref 取回完整证据。这样既控制了回执体积，又不丢失可验证性。

class_name MCPEvidenceStore
extends RefCounted

## 证据根目录。放在 .mcp 下，与生成缓存一起被项目健康扫描排除。
const EVIDENCE_ROOT: String = "res://.mcp/evidence"

## 超过此字节数的证据落盘，回执内只保留引用 + 摘要。
## 50KB 与 server_core 的内联上限对齐，避免证据在回执里二次膨胀。
const INLINE_EVIDENCE_MAX_BYTES: int = 50000

## 回执内联摘要最多保留的顶层键数量
const SUMMARY_MAX_KEYS: int = 24

## 单个摘要值的最大字符数
const SUMMARY_MAX_VALUE_CHARS: int = 200

## 数组摘要最多保留的元素数
const SUMMARY_MAX_ARRAY_ITEMS: int = 8

const TokenEstimatorScript = preload("res://addons/godot_mcp/utils/token_estimator.gd")

# ---------------------------------------------------------------------------
# 公开 API
# ---------------------------------------------------------------------------

## 保存一条步骤证据。
##
## 返回（永不失败，落盘失败时降级为内联）：
## {
##   evidence,          # 完整证据（未超限）或紧凑摘要（已落盘）
##   evidence_ref,      # 落盘路径，未落盘时为空
##   evidence_digest,   # 完整证据的 sha256
##   evidence_bytes,    # 完整证据的序列化字节数
##   evidence_spilled,  # 是否落盘
##   evidence_degraded  # 落盘失败但内容超限（证据可能被截断）
## }
static func store(workflow_id: String, step_id: String, tool_name: String,
		result: Variant, outcome: Dictionary = {}) -> Dictionary:
	var payload: Dictionary = {
		"workflow_id": workflow_id,
		"step_id": step_id,
		"tool_name": tool_name,
		"recorded_at": Time.get_datetime_string_from_system(true),
		"outcome": outcome,
		"result": result if result != null else {}
	}
	var canonical: String = TokenEstimatorScript.canonical_json(payload)
	var digest: String = _sha256(canonical)
	var bytes: int = canonical.to_utf8_buffer().size()

	if bytes <= INLINE_EVIDENCE_MAX_BYTES:
		return {
			"evidence": payload,
			"evidence_ref": "",
			"evidence_digest": digest,
			"evidence_bytes": bytes,
			"evidence_spilled": false,
			"evidence_degraded": false
		}

	var relative_path: String = "%s/%s.json" % [_safe_segment(workflow_id), _safe_segment(step_id)]
	if _write_evidence(relative_path, canonical):
		return {
			"evidence": _compact_summary(payload),
			"evidence_ref": "%s/%s" % [EVIDENCE_ROOT, relative_path],
			"evidence_digest": digest,
			"evidence_bytes": bytes,
			"evidence_spilled": true,
			"evidence_degraded": false
		}
	# 落盘失败：保留摘要并显式标记降级，绝不静默丢弃证据
	return {
		"evidence": _compact_summary(payload),
		"evidence_ref": "",
		"evidence_digest": digest,
		"evidence_bytes": bytes,
		"evidence_spilled": false,
		"evidence_degraded": true
	}


## 按 evidence_ref 取回完整证据。读取失败返回带 error 的字典。
static func load_evidence(evidence_ref: String) -> Variant:
	var path: String = evidence_ref.strip_edges()
	if path.is_empty():
		return {"error": "evidence_ref is required"}
	if not path.begins_with(EVIDENCE_ROOT):
		return {"error": "evidence_ref must live under %s" % EVIDENCE_ROOT}
	if not FileAccess.file_exists(path):
		return {"error": "evidence file not found: " + path}
	var text: String = FileAccess.get_file_as_string(path)
	if text.is_empty():
		return {"error": "evidence file is empty: " + path}
	var parsed: Variant = JSON.parse_string(text)
	if parsed == null:
		return {"error": "evidence file is not valid JSON: " + path}
	return parsed


## 列出某个工作流的全部证据引用（按路径排序）
static func list_evidence(workflow_id: String) -> Array[Dictionary]:
	var directory: String = "%s/%s" % [EVIDENCE_ROOT, _safe_segment(workflow_id)]
	var entries: Array[Dictionary] = []
	var dir: DirAccess = DirAccess.open(directory)
	if dir == null:
		return entries
	dir.list_dir_begin()
	var file_name: String = dir.get_next()
	while not file_name.is_empty():
		if not dir.current_is_dir() and file_name.ends_with(".json"):
			var full_path: String = "%s/%s" % [directory, file_name]
			entries.append({
				"evidence_ref": full_path,
				"step_id": file_name.substr(0, file_name.length() - 5),
				"bytes": int(FileAccess.get_file_as_string(full_path).to_utf8_buffer().size())
			})
		file_name = dir.get_next()
	dir.list_dir_end()
	entries.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return String(a.get("step_id", "")) < String(b.get("step_id", ""))
	)
	return entries


## 清理某个工作流的证据；返回删除数量。
static func clear_workflow(workflow_id: String) -> int:
	var directory: String = "%s/%s" % [EVIDENCE_ROOT, _safe_segment(workflow_id)]
	return _remove_directory_recursive(directory)


## 清理全部证据；返回删除数量。
static func clear_all() -> int:
	return _remove_directory_recursive(EVIDENCE_ROOT)


## 证据库统计：工作流数量、文件数量、总字节数
static func stats() -> Dictionary:
	var root: DirAccess = DirAccess.open(EVIDENCE_ROOT)
	if root == null:
		return {"workflows": 0, "files": 0, "bytes": 0}
	var workflows: int = 0
	var files: int = 0
	var total_bytes: int = 0
	root.list_dir_begin()
	var workflow_name: String = root.get_next()
	while not workflow_name.is_empty():
		if root.current_is_dir() and not workflow_name.begins_with("."):
			workflows += 1
			var workflow_dir: DirAccess = DirAccess.open("%s/%s" % [EVIDENCE_ROOT, workflow_name])
			if workflow_dir == null:
				workflow_name = root.get_next()
				continue
			workflow_dir.list_dir_begin()
			var file_name: String = workflow_dir.get_next()
			while not file_name.is_empty():
				if not workflow_dir.current_is_dir() and file_name.ends_with(".json"):
					files += 1
					total_bytes += FileAccess.get_file_as_string(
						"%s/%s/%s" % [EVIDENCE_ROOT, workflow_name, file_name]).to_utf8_buffer().size()
				file_name = workflow_dir.get_next()
			workflow_dir.list_dir_end()
		workflow_name = root.get_next()
	root.list_dir_end()
	return {"workflows": workflows, "files": files, "bytes": total_bytes}


# ---------------------------------------------------------------------------
# 内部实现
# ---------------------------------------------------------------------------

## 生成回执内联摘要：保留判定字段与关键数值，截断大数组/长字符串。
## 与旧的 _compact_result_summary 不同，这里保留"哪些检查项、实际值多少"。
static func _compact_summary(payload: Dictionary) -> Dictionary:
	var result_value: Variant = payload.get("result", {})
	var summary: Dictionary = {
		"tool_name": payload.get("tool_name", ""),
		"step_id": payload.get("step_id", ""),
		"recorded_at": payload.get("recorded_at", ""),
		"truncated": true
	}
	var outcome: Variant = payload.get("outcome", {})
	if outcome is Dictionary:
		summary["outcome"] = {
			"status": (outcome as Dictionary).get("status_name", ""),
			"objective_proven": (outcome as Dictionary).get("objective_proven", false),
			"category": (outcome as Dictionary).get("category", "")
		}
	if not (result_value is Dictionary):
		summary["result_type"] = type_string(typeof(result_value))
		return summary
	var data: Dictionary = result_value
	var keys: Array = data.keys()
	keys.sort()
	var kept: int = 0
	for key_value in keys:
		if kept >= SUMMARY_MAX_KEYS:
			summary["omitted_keys"] = keys.size() - kept
			break
		var key: String = String(key_value)
		summary[key] = _compact_value(data[key_value], 0)
		kept += 1
	return summary


static func _compact_value(value: Variant, depth: int) -> Variant:
	if value is Dictionary:
		var data: Dictionary = value
		if depth >= 2:
			return "{%d keys}" % data.size()
		var compact: Dictionary = {}
		var index: int = 0
		var keys: Array = data.keys()
		keys.sort()
		for key_value in keys:
			if index >= SUMMARY_MAX_KEYS:
				compact["_omitted"] = keys.size() - index
				break
			compact[String(key_value)] = _compact_value(data[key_value], depth + 1)
			index += 1
		return compact
	if value is Array:
		var items: Array = value
		var compact_items: Array = []
		for index in range(mini(items.size(), SUMMARY_MAX_ARRAY_ITEMS)):
			compact_items.append(_compact_value(items[index], depth + 1))
		if items.size() > SUMMARY_MAX_ARRAY_ITEMS:
			compact_items.append("...+%d more" % (items.size() - SUMMARY_MAX_ARRAY_ITEMS))
		return compact_items
	if value is String:
		var text: String = value
		if text.length() > SUMMARY_MAX_VALUE_CHARS:
			return text.substr(0, SUMMARY_MAX_VALUE_CHARS) + "…"
		return text
	return value


static func _write_evidence(relative_path: String, content: String) -> bool:
	var full_path: String = "%s/%s" % [EVIDENCE_ROOT, relative_path]
	var directory: String = full_path.get_base_dir()
	var make_error: int = DirAccess.make_dir_recursive_absolute(directory)
	if make_error != OK and not DirAccess.dir_exists_absolute(directory):
		return false
	var file: FileAccess = FileAccess.open(full_path, FileAccess.WRITE)
	if file == null:
		return false
	file.store_string(content)
	file.close()
	return FileAccess.file_exists(full_path)


## 目录段名净化：防止 workflow_id / step_id 里的特殊字符逃逸出证据目录
static func _safe_segment(value: String) -> String:
	var text: String = value.strip_edges()
	if text.is_empty():
		return "unknown"
	var result: String = ""
	for character in text:
		if _is_safe_char(character):
			result += character
		else:
			result += "_"
	return result.substr(0, 64)


static func _is_safe_char(character: String) -> bool:
	if character.length() != 1:
		return false
	var code: int = character.unicode_at(0)
	var is_alnum: bool = (code >= 48 and code <= 57) or \
		(code >= 65 and code <= 90) or (code >= 97 and code <= 122)
	return is_alnum or character == "_" or character == "-"


static func _remove_directory_recursive(path: String) -> int:
	if not DirAccess.dir_exists_absolute(path):
		return 0
	var removed: int = 0
	var dir: DirAccess = DirAccess.open(path)
	if dir == null:
		return 0
	dir.list_dir_begin()
	var entry: String = dir.get_next()
	while not entry.is_empty():
		var full_path: String = "%s/%s" % [path, entry]
		if dir.current_is_dir():
			if not entry.begins_with("."):
				removed += _remove_directory_recursive(full_path)
		else:
			removed += 1
		entry = dir.get_next()
	dir.list_dir_end()
	var parent: DirAccess = DirAccess.open(path.get_base_dir())
	if parent != null:
		parent.remove(path)
	return removed


static func _sha256(text: String) -> String:
	return text.sha256_text()
