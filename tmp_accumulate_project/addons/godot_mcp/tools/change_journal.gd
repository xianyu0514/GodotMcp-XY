class_name ChangeJournal
extends RefCounted

# 可恢复跨文件修改的操作日志（M3 首版：.gd 文件 + rename_script_symbol）。
#
# 设计约束（对应评测任务 R3/R4 与路线图 M3）：
# - "操作是否完成"与"项目文件实际是什么状态"分开记录：journal 记录操作
#   意图、每个目标文件的原/预期内容指纹与写入阶段；恢复判定永远以磁盘
#   实况为准做分类，不信任 journal 自述的进度。
# - 多文件写入不假装操作系统级原子性：每个文件写成功后立即推进该文件
#   状态并落盘 journal，中断点因此可观测。
# - 与手工修改冲突时保留文件并报告，绝不覆盖（R4 契约）。
#
# 该文件是纯逻辑支持层（同 TaskPlanStore），不注册 MCP 工具、不耦合
# 编辑器接口；工具层负责参数校验与调用。
#
# Persisted shape (default path res://.mcp/change_journal.json):
# {
#   "schema_version": 1,
#   "operations": [
#     {
#       "operation_id": "op_<epoch_ms>_<seq>",
#       "intent": "rename_script_symbol speed -> velocity",
#       "phase": "prepared|committed|failed|superseded",
#       "created_at": "ISO8601", "finished_at": "ISO8601",
#       "files": [
#         {
#           "path": "res://scripts/player.gd",
#           "before_hash": "sha256...", "after_hash": "sha256...",
#           "replacement_count": 2,
#           "state": "planned|applied"
#         }
#       ],
#       "verification": {"verified": true, "checked_at": "...", "mismatches": []},
#       "superseded_by": "op_..."   # 仅 superseded 阶段存在
#     }
#   ]
# }

const SCHEMA_VERSION: int = 1
const DEFAULT_JOURNAL_PATH: String = "res://.mcp/change_journal.json"
const STAGING_SUFFIX: String = ".next"

## 非终态阶段：处于这些阶段的操作记录意味着可能存在未完成的写入，
## 恢复流程（classify_operation）必须重新核对这些操作涉及的所有文件。
const FINAL_PHASES: Array = ["committed", "failed", "superseded"]

# ============================================================================
# 持久化
# ============================================================================

## 读取 journal；文件不存在返回空骨架（首次使用），损坏返回 error。
static func load_journal(path: String = DEFAULT_JOURNAL_PATH) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {"schema_version": SCHEMA_VERSION, "operations": []}
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {"error": "could not open change journal '%s' for reading" % path}
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	file.close()
	if not (parsed is Dictionary):
		return {"error": "change journal '%s' is not a JSON object" % path}
	var journal: Dictionary = parsed
	if int(journal.get("schema_version", 0)) != SCHEMA_VERSION:
		return {"error": "unsupported change journal schema_version in '%s'" % path}
	if not (journal.get("operations") is Array):
		return {"error": "change journal '%s' has no operations array" % path}
	return journal

## 暂存写入 + 校验 + 原子提升：崩溃在任何窗口都留下可读的旧一代或新一代。
static func save_journal(journal: Dictionary, path: String = DEFAULT_JOURNAL_PATH) -> Dictionary:
	var base_dir: String = path.get_base_dir()
	if not base_dir.is_empty():
		var abs_dir: String = ProjectSettings.globalize_path(base_dir)
		if not DirAccess.dir_exists_absolute(abs_dir):
			var make_error: Error = DirAccess.make_dir_recursive_absolute(abs_dir)
			if make_error != OK and not DirAccess.dir_exists_absolute(abs_dir):
				return {"error": "could not create directory '%s'" % base_dir}
	var staging_path: String = path + STAGING_SUFFIX
	var staged_text: String = JSON.stringify(journal, "\t")
	var file: FileAccess = FileAccess.open(staging_path, FileAccess.WRITE)
	if file == null:
		return {"error": "could not open '%s' for writing" % staging_path}
	file.store_string(staged_text)
	file.close()
	# 校验暂存代可解析后再提升，避免半写的 JSON 变成主文件。
	var reparsed: Variant = JSON.parse_string(staged_text)
	if not (reparsed is Dictionary):
		DirAccess.remove_absolute(staging_path)
		return {"error": "staged change journal failed validation at '%s'" % staging_path}
	var absolute_staging: String = ProjectSettings.globalize_path(staging_path)
	var absolute_primary: String = ProjectSettings.globalize_path(path)
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(absolute_primary)
	var rename_error: Error = DirAccess.rename_absolute(absolute_staging, absolute_primary)
	if rename_error != OK:
		return {"error": "could not promote staged change journal '%s': %s" % [path, error_string(rename_error)]}
	return {"saved": true}

# ============================================================================
# 操作生命周期
# ============================================================================

## 在写入任何文件之前创建操作记录（phase=prepared，所有文件 state=planned）。
## file_entries 每项：{path, before_hash, after_hash, replacement_count}。
## 预览（dry_run 计算出的替换与指纹）与应用由同一记录绑定。
static func begin_operation(intent: String, file_entries: Array,
		journal_path: String = DEFAULT_JOURNAL_PATH) -> Dictionary:
	var journal: Dictionary = load_journal(journal_path)
	if journal.has("error"):
		return journal
	var record: Dictionary = {
		"operation_id": _new_operation_id(journal),
		"intent": intent,
		"phase": "prepared",
		"created_at": _now(),
		"finished_at": "",
		"files": [],
		"verification": {"verified": false, "checked_at": "", "mismatches": []},
	}
	for entry_value in file_entries:
		var entry: Dictionary = entry_value if entry_value is Dictionary else {}
		record["files"].append({
			"path": String(entry.get("path", "")),
			"before_hash": String(entry.get("before_hash", "")),
			"after_hash": String(entry.get("after_hash", "")),
			"replacement_count": int(entry.get("replacement_count", 0)),
			"state": "planned",
		})
	(journal["operations"] as Array).append(record)
	var save_result: Dictionary = save_journal(journal, journal_path)
	if save_result.has("error"):
		return save_result
	return {"operation": record, "journal_path": journal_path}

## 单个文件写入成功后立即推进其状态并落盘（中断点可观测的关键）。
static func mark_file_applied(operation_id: String, file_path: String,
		journal_path: String = DEFAULT_JOURNAL_PATH) -> Dictionary:
	var mutation: Dictionary = _mutate_operation(operation_id, journal_path,
		func(operation: Dictionary) -> bool:
			for file_value in operation.get("files", []):
				var entry: Dictionary = file_value
				if String(entry.get("path", "")) == file_path:
					entry["state"] = "applied"
					return true
			return false)
	return mutation

## 操作收口：全部文件写入并校验后 finish（phase=committed, verified），
## 校验发现撕裂写入时 phase=failed 并保留 mismatches 证据。
static func finish_operation(operation_id: String, verified: bool, mismatches: Array,
		journal_path: String = DEFAULT_JOURNAL_PATH) -> Dictionary:
	return _mutate_operation(operation_id, journal_path,
		func(operation: Dictionary) -> bool:
			operation["phase"] = "committed" if verified else "failed"
			operation["finished_at"] = _now()
			operation["verification"] = {
				"verified": verified,
				"checked_at": _now(),
				"mismatches": mismatches,
			}
			return true)

## 新操作开始时，把同文件范围内的旧 pending 记录取代（superseded），
## 防止 journal 被历史未收口操作永久污染；被取代记录保留分类快照供审计。
static func supersede_pending_touching(file_paths: Array, superseded_by: String,
		journal_path: String = DEFAULT_JOURNAL_PATH) -> Dictionary:
	var journal: Dictionary = load_journal(journal_path)
	if journal.has("error"):
		return journal
	var path_set: Dictionary = {}
	for path_value in file_paths:
		path_set[String(path_value)] = true
	var superseded_ids: Array = []
	for operation_value in journal["operations"]:
		var operation: Dictionary = operation_value
		# 跳过调用方自身：supersede 在 begin_operation 之后执行，
		# 新操作（prepared）也触碰同一批文件，但不应取代自己。
		if String(operation.get("operation_id", "")) == String(superseded_by):
			continue
		if String(operation.get("phase", "")) in FINAL_PHASES:
			continue
		var touches: bool = false
		for file_value in operation.get("files", []):
			if path_set.has(String((file_value as Dictionary).get("path", ""))):
				touches = true
				break
		if touches:
			var verdict: Dictionary = classify_operation(operation)
			operation["phase"] = "superseded"
			operation["finished_at"] = _now()
			operation["superseded_by"] = superseded_by
			operation["superseded_verdict"] = verdict.get("action", "")
			superseded_ids.append(operation.get("operation_id", ""))
	if superseded_ids.is_empty():
		return {"superseded": []}
	var save_result: Dictionary = save_journal(journal, journal_path)
	if save_result.has("error"):
		return save_result
	return {"superseded": superseded_ids}

## 仍未收口（非终态）且涉及任一给定文件的操作记录。
static func pending_operations_touching(file_paths: Array,
		journal_path: String = DEFAULT_JOURNAL_PATH) -> Array:
	var journal: Dictionary = load_journal(journal_path)
	if journal.has("error"):
		return []
	var path_set: Dictionary = {}
	for path_value in file_paths:
		path_set[String(path_value)] = true
	var pending: Array = []
	for operation_value in journal["operations"]:
		var operation: Dictionary = operation_value
		if String(operation.get("phase", "")) in FINAL_PHASES:
			continue
		for file_value in operation.get("files", []):
			if path_set.has(String((file_value as Dictionary).get("path", ""))):
				pending.append(operation)
				break
	return pending

# ============================================================================
# 单文件观察式写入（M3 slice 2：场景/资源保存）
# ============================================================================

## 文件内容指纹；文件不存在返回空串（create 类操作的 before 语义）。
static func file_sha256(file_path: String) -> String:
	if not FileAccess.file_exists(file_path):
		return ""
	var file: FileAccess = FileAccess.open(file_path, FileAccess.READ)
	if file == null:
		return ""
	var content: String = file.get_as_text()
	file.close()
	return content.sha256_text()

## 单文件一次性记录（观察式）：调用方先读 before 指纹、执行写入、再读
## after 指纹后落一条 committed/failed 记录。与多文件两阶段（begin→mark→
## finish）不同，单文件写入的崩溃窗口内重放即恢复（幂等覆盖），journal
## 的价值是收据证据（供工作流恢复分类）与审计。kind: "create"|"modify"。
static func record_write_operation(intent: String, file_path: String,
		before_hash: String, after_hash: String, verified: bool,
		journal_path: String = DEFAULT_JOURNAL_PATH) -> Dictionary:
	var journal: Dictionary = load_journal(journal_path)
	if journal.has("error"):
		return journal
	var record: Dictionary = {
		"operation_id": _new_operation_id(journal),
		"intent": intent,
		"phase": "committed" if verified else "failed",
		"created_at": _now(),
		"finished_at": _now(),
		"files": [{
			"path": file_path,
			"before_hash": before_hash,
			"after_hash": after_hash,
			"replacement_count": 0,
			"state": "applied" if verified else "planned",
		}],
		"verification": {
			"verified": verified,
			"checked_at": _now(),
			"mismatches": [] if verified else [{"path": file_path, "issue": "post-write readback failed"}],
		},
	}
	(journal["operations"] as Array).append(record)
	var save_result: Dictionary = save_journal(journal, journal_path)
	if save_result.has("error"):
		return save_result
	return {"operation": record, "journal_path": journal_path}

## 全部未收口（非终态）操作——恢复流程的排查入口。
static func pending_operations(journal_path: String = DEFAULT_JOURNAL_PATH) -> Array:
	var journal: Dictionary = load_journal(journal_path)
	if journal.has("error"):
		return []
	var pending: Array = []
	for operation_value in journal["operations"]:
		var operation: Dictionary = operation_value
		if not String(operation.get("phase", "")) in FINAL_PHASES:
			pending.append(operation)
	return pending

## 该工具最近一条任意阶段的操作（intent 以 "tool_name " 开头）——恢复时
## 判断"上一次写入是否真的落盘"。
static func latest_operation_by_tool(tool_name: String,
		journal_path: String = DEFAULT_JOURNAL_PATH) -> Dictionary:
	var journal: Dictionary = load_journal(journal_path)
	if journal.has("error"):
		return {}
	var prefix: String = tool_name + " "
	var operations: Array = journal["operations"]
	for index in range(operations.size() - 1, -1, -1):
		var operation: Dictionary = operations[index]
		if String(operation.get("intent", "")).begins_with(prefix):
			return operation
	return {}

# ============================================================================
# 恢复分类（以磁盘实况为准）
# ============================================================================

## 对一条操作记录做恢复分类。逐文件比对当前内容指纹：
##   untouched（仍为原内容）/ applied（已是预期新内容）/ diverged（其他，
##   含文件缺失——视为手工改动或外部破坏，一律冲突，绝不覆盖）。
## 操作级建议（恢复代理可直接执行的动作）：
##   conflict          存在 diverged：保留文件、报告冲突，人工裁决
##   complete_receipt  全部 applied：工作已完成，补回执即可（rename 重跑
##                     会得到 0 处替换，天然幂等收口）
##   resume            部分应用：重跑同一操作，符号级幂等只补剩余替换
##   re_prepare        全部 untouched：操作从未发生，可从头重新准备
static func classify_operation(operation: Dictionary) -> Dictionary:
	var files_verdict: Array = []
	var has_diverged: bool = false
	var applied_count: int = 0
	var untouched_count: int = 0
	var total: int = 0
	for file_value in operation.get("files", []):
		var entry: Dictionary = file_value
		var file_path: String = String(entry.get("path", ""))
		total += 1
		var state: String = _current_file_state(file_path,
			String(entry.get("before_hash", "")), String(entry.get("after_hash", "")))
		match state:
			"applied":
				applied_count += 1
			"untouched":
				untouched_count += 1
			_:
				has_diverged = true
		files_verdict.append({"path": file_path, "state": state})
	var action: String = "re_prepare"
	if has_diverged:
		action = "conflict"
	elif applied_count == total and total > 0:
		action = "complete_receipt"
	elif applied_count > 0 and untouched_count > 0:
		action = "resume"
	return {
		"operation_id": operation.get("operation_id", ""),
		"intent": operation.get("intent", ""),
		"action": action,
		"files": files_verdict,
		"applied_count": applied_count,
		"untouched_count": untouched_count,
	}

static func _current_file_state(file_path: String, before_hash: String, after_hash: String) -> String:
	if not FileAccess.file_exists(file_path):
		# create 类操作（无 before_hash）：文件不存在 = 从未发生（untouched）；
		# modify 类：原文件被删 = 冲突。
		if before_hash.is_empty():
			return "untouched"
		return "diverged"
	var file: FileAccess = FileAccess.open(file_path, FileAccess.READ)
	if file == null:
		return "diverged"
	var content: String = file.get_as_text()
	file.close()
	var current_hash: String = content.sha256_text()
	if not after_hash.is_empty() and current_hash == after_hash:
		return "applied"
	if not before_hash.is_empty() and current_hash == before_hash:
		return "untouched"
	if before_hash.is_empty():
		# create 类：文件存在但不是记录的 after 内容 = 分歧
		return "diverged"
	return "diverged"

# ============================================================================
# 内部辅助
# ============================================================================

static func _new_operation_id(journal: Dictionary) -> String:
	var sequence: int = (journal.get("operations") as Array).size() + 1
	return "op_%d_%03d" % [Time.get_unix_time_from_system() * 1000.0, sequence]

static func _now() -> String:
	return Time.get_datetime_string_from_system(true, true)

static func _mutate_operation(operation_id: String, journal_path: String,
		mutator: Callable) -> Dictionary:
	var journal: Dictionary = load_journal(journal_path)
	if journal.has("error"):
		return journal
	for operation_value in journal["operations"]:
		var operation: Dictionary = operation_value
		if String(operation.get("operation_id", "")) != String(operation_id):
			continue
		if not mutator.call(operation):
			return {"error": "operation '%s' does not reference the requested file" % operation_id}
		var save_result: Dictionary = save_journal(journal, journal_path)
		if save_result.has("error"):
			return save_result
		return {"operation": operation}
	return {"error": "operation '%s' not found in change journal" % operation_id}
