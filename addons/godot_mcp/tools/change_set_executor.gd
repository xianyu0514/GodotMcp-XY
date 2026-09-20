class_name ChangeSetExecutor
extends RefCounted

# 可恢复的跨文件变更单执行器（M5 第二交付：大型 2D 审计 2026-09-19 步骤 2）。
#
# 设计约束（审计原文口径）：
# - 预览绑定原始版本：每个 modify 操作必须携带 expected_content_hash，
#   与磁盘不符即在动手之前拒绝——不覆盖任何读版本之后的变化。
# - 日志不可写则禁止开始：与 rename_script_symbol 的降级运行不同，这里
#   把"journal 写入失败"作为硬门禁（审计明确批评该降级点）。
# - 多文件写入不假装原子：逐文件"写入→读回→推进日志"，中断点可观测；
#   中间状态未闭合前绝不宣布成功（requires_recovery 不是错误，是状态）。
# - 恢复以磁盘实况为准：同 change_set_id 重放时逐文件分类
#   untouched/applied/diverged——只续做 untouched，跳过 applied，
#   diverged（含中断后的手工修改）停在明确冲突处，绝不覆盖。
# - 幂等：已 committed 的变更单重放返回 receipt（重验磁盘），不重写；
#   committed 后磁盘被回滚/改动则拒绝并交出分类证据，要求显式新单。
#
# 纯逻辑支持层（同 ChangeJournal），不注册 MCP 工具、不耦合编辑器接口；
# 工具层（apply_change_set）负责缓冲区守卫与写后同步。

const ChangeJournalScript = preload("res://addons/godot_mcp/tools/change_journal.gd")

## edits 模式只接受文本资源：对二进制 .res/.png 做字符串替换会损坏文件。
const TEXT_EXTENSIONS: Array[String] = [
	".gd", ".cs", ".tscn", ".tres", ".cfg", ".json", ".gdshader", ".gdinc",
	".txt", ".md", ".py",
]

# ============================================================================
# 预览（dry-run 计算与执行共用：绑定同一份 before/after 指纹）
# ============================================================================

## 对一组操作做完整预检与指纹计算。任何失败都发生在写入之前：
## - modify：文件存在、文本扩展、expected_content_hash 匹配磁盘、
##   每条 edit 的 old_text 在内容中恰好出现一次（唯一替换约定）。
## - create：文件不存在、new_content 非空。
## 返回 {entries: [{path, action, before_hash, after_hash, replacement_counts,
## edits, new_content}]} 或 {error}。entries 自带编辑载荷，执行阶段
## 不再依赖磁盘外的任何请求字段。
static func compute_preview(operations: Array) -> Dictionary:
	if operations.is_empty():
		return {"error": "operations must be a non-empty array"}
	var entries: Array = []
	var seen_paths: Dictionary = {}
	for operation_value in operations:
		if not (operation_value is Dictionary):
			return {"error": "each operation must be an object"}
		var operation: Dictionary = operation_value
		var path: String = _normalized(String(operation.get("path", "")))
		if path.is_empty():
			return {"error": "each operation needs a non-empty path"}
		if seen_paths.has(path):
			return {"error": "duplicate operation path: %s" % path}
		seen_paths[path] = true
		if not _is_text_extension(path):
			return {"error": "path '%s' is not a text resource; edits only support %s" % [path, ", ".join(TEXT_EXTENSIONS)]}

		var edits: Array = operation.get("edits", []) as Array
		var new_content: String = String(operation.get("new_content", ""))
		var is_create: bool = not new_content.is_empty() or bool(operation.get("create", false))

		if is_create:
			if not edits.is_empty():
				return {"error": "operation '%s': create mode takes new_content, not edits" % path}
			if FileAccess.file_exists(path):
				return {"error": "operation '%s': create target already exists (use edits to modify)" % path}
			if new_content.is_empty():
				return {"error": "operation '%s': create mode needs non-empty new_content" % path}
			entries.append({
				"path": path,
				"action": "create",
				"before_hash": "",
				"after_hash": new_content.sha256_text(),
				"replacement_counts": [],
				"edits": [],
				"new_content": new_content,
			})
			continue

		if not FileAccess.file_exists(path):
			return {"error": "operation '%s': file not found" % path}
		var file: FileAccess = FileAccess.open(path, FileAccess.READ)
		if file == null:
			return {"error": "operation '%s': could not open for reading" % path}
		var content: String = file.get_as_text()
		file.close()
		var expected_hash: String = String(operation.get("expected_content_hash", ""))
		if expected_hash.is_empty():
			return {"error": "operation '%s': modify requires expected_content_hash (pin the version you read; read_script returns content_hash)" % path}
		var current_hash: String = content.sha256_text()
		if current_hash != expected_hash:
			return {
				"error": "operation '%s': disk content hash no longer matches expected_content_hash — the file changed since it was read; re-read and rebuild the change set" % path,
				"path": path,
				"expected_content_hash": expected_hash,
				"current_content_hash": current_hash,
			}
		if edits.is_empty():
			return {"error": "operation '%s': modify needs at least one edit (or use new_content for create)" % path}
		var replacement_counts: Array = []
		for edit_value in edits:
			if not (edit_value is Dictionary):
				return {"error": "operation '%s': each edit must be an object" % path}
			var edit: Dictionary = edit_value
			var old_text: String = String(edit.get("old_text", ""))
			var new_text: String = String(edit.get("new_text", ""))
			if old_text.is_empty():
				return {"error": "operation '%s': edit.old_text must be non-empty" % path}
			if old_text == new_text:
				return {"error": "operation '%s': edit.old_text equals new_text" % path}
			var occurrences: int = content.count(old_text)
			if occurrences != 1:
				return {"error": "operation '%s': edit.old_text occurs %d times (must be exactly once — unique replacement contract)" % [path, occurrences]}
			content = content.replace(old_text, new_text)
			replacement_counts.append(1)
		entries.append({
			"path": path,
			"action": "modify",
			"before_hash": current_hash,
			"after_hash": content.sha256_text(),
			"replacement_counts": replacement_counts,
			"edits": edits,
			"new_content": "",
		})
	return {"entries": entries}

# ============================================================================
# 执行 / 恢复协议
# ============================================================================

## 执行或恢复一个变更单。request:
##   intent: string（必填）
##   operations: Array（必填，见 compute_preview）
##   change_set_id: string（可选；缺省生成并在结果返回——重放必须带回）
##   dry_run: bool（默认 false；true 时只做预览，不写 journal/文件）
##   journal_path: string（测试注入；默认 res://.mcp/change_journal.json）
##   interrupt_after: int（仅测试：写入第 N 个文件后停在 prepared）
static func apply(request: Dictionary) -> Dictionary:
	var intent: String = String(request.get("intent", "")).strip_edges()
	if intent.is_empty():
		return {"error": "Missing required parameter: intent"}
	var journal_path: String = String(request.get("journal_path", ChangeJournalScript.DEFAULT_JOURNAL_PATH))
	var change_set_id: String = String(request.get("change_set_id", "")).strip_edges()
	if change_set_id.is_empty():
		change_set_id = _new_change_set_id()
	var intent_prefix: String = "change_set %s:" % change_set_id

	var operations: Variant = request.get("operations", [])
	if not (operations is Array):
		return {"error": "Missing required parameter: operations (non-empty array)"}

	# —— 恢复/幂等路径：同 id 已有记录时按磁盘实况分类，绝不盲目重写 ——
	var latest: Dictionary = ChangeJournalScript.latest_operation_by_tool(intent_prefix, journal_path)
	if not latest.is_empty():
		return _replay_existing(change_set_id, latest, operations, journal_path, request)

	# —— 全新变更单：预检 → journal 落盘成功才动手 ——
	var preview: Dictionary = compute_preview(operations)
	if preview.has("error"):
		preview["change_set_id"] = change_set_id
		return preview
	if bool(request.get("dry_run", false)):
		return {
			"change_set_id": change_set_id,
			"intent": intent,
			"dry_run": true,
			"outcome": "planned",
			"preview": _public_preview(preview["entries"]),
			"notes": ["Nothing was written. Re-submit with the same change_set_id to execute; interrupting execution and re-submitting resumes from per-file disk state."],
		}

	var journal_entries: Array = []
	for entry_value in preview["entries"]:
		var entry: Dictionary = entry_value
		journal_entries.append({
			"path": entry["path"],
			"before_hash": entry["before_hash"],
			"after_hash": entry["after_hash"],
			"replacement_count": int((entry["replacement_counts"] as Array).size()),
		})
	# 硬门禁：journal 写不进就不动手（不降级）。
	var begun: Dictionary = ChangeJournalScript.begin_operation(
		"%s %s" % [intent_prefix, intent], journal_entries, journal_path)
	if begun.has("error"):
		return {
			"error": "change journal is not writable; refusing to start the change set without a recovery log: %s" % String(begun["error"]),
			"change_set_id": change_set_id,
		}
	var operation_id: String = String((begun.get("operation", {}) as Dictionary).get("operation_id", ""))

	var paths: Array = []
	for entry_value in journal_entries:
		paths.append(String((entry_value as Dictionary).get("path", "")))
	ChangeJournalScript.supersede_pending_touching(paths, operation_id, journal_path)

	return _execute_entries(change_set_id, intent, operation_id, preview["entries"],
		[], request, journal_path)

## 逐文件执行：已 applied 跳过、磁盘仍为 before 则写、其余冲突即停。
## 每次写入后立即读回指纹并推进 journal；interrupt_after 命中时停在
## prepared（requires_recovery），绝不宣布成功。
## pre_applied_report 是恢复路径带入的 already_applied 报告（前置合并）。
static func _execute_entries(change_set_id: String, intent: String,
		operation_id: String, entries: Array, pre_applied_report: Array,
		request: Dictionary, journal_path: String) -> Dictionary:
	var interrupt_after: int = int(request.get("interrupt_after", -1))
	var files_report: Array = pre_applied_report.duplicate()
	var mismatches: Array = []
	var written: int = 0
	var conflicted: Array = []
	for entry_value in entries:
		var entry: Dictionary = entry_value
		var path: String = String(entry["path"])
		var before_hash: String = String(entry["before_hash"])
		var after_hash: String = String(entry["after_hash"])
		var disk_hash: String = ChangeJournalScript.file_sha256(path)

		if not after_hash.is_empty() and disk_hash == after_hash:
			files_report.append({"path": path, "state": "already_applied"})
			continue
		if not before_hash.is_empty() and disk_hash != before_hash:
			files_report.append({
				"path": path,
				"state": "conflicted",
				"issue": "disk content is neither the read version nor the planned result — refusing to overwrite",
			})
			conflicted.append(path)
			continue
		if before_hash.is_empty() and FileAccess.file_exists(path):
			# create 目标已出现且不匹配 after：视为冲突，不覆盖。
			files_report.append({"path": path, "state": "conflicted",
				"issue": "create target appeared before execution"})
			conflicted.append(path)
			continue

		var write_error: String = _write_entry(entry)
		written += 1
		if not write_error.is_empty():
			mismatches.append({"path": path, "issue": "write failed: %s" % write_error})
			files_report.append({"path": path, "state": "write_failed",
				"issue": write_error})
			continue
		if ChangeJournalScript.file_sha256(path) != after_hash:
			mismatches.append({"path": path, "issue": "post-write readback does not match the planned fingerprint"})
			files_report.append({"path": path, "state": "readback_mismatch"})
			continue
		ChangeJournalScript.mark_file_applied(operation_id, path, journal_path)
		files_report.append({"path": path, "state": "applied"})

		if interrupt_after > 0 and written == interrupt_after:
			return {
				"change_set_id": change_set_id,
				"intent": intent,
				"outcome": "requires_recovery",
				"operation_id": operation_id,
				"files": files_report,
				"notes": ["Interrupted after %d file write(s); the journal stays prepared. Re-submit the same change_set_id with the same operations to resume or classify." % written],
			}

	if not conflicted.is_empty():
		ChangeJournalScript.finish_operation(operation_id, false, mismatches, journal_path)
		return {
			"change_set_id": change_set_id,
			"intent": intent,
			"outcome": "conflict",
			"operation_id": operation_id,
			"files": files_report,
			"conflicted_paths": conflicted,
			"notes": ["Some files diverged from the change set (manual edits after interruption, or an unexpected create target). Those files were left untouched; resolve them explicitly."],
		}

	var verified: bool = mismatches.is_empty()
	ChangeJournalScript.finish_operation(operation_id, verified, mismatches, journal_path)
	return {
		"change_set_id": change_set_id,
		"intent": intent,
		"outcome": "committed" if verified else "failed",
		"operation_id": operation_id,
		"files": files_report,
		"verification": {"verified": verified, "mismatches": mismatches},
	}

## 同 id 重放：按磁盘实况分类后收口、续做或拒绝——绝不重复生效。
static func _replay_existing(change_set_id: String, latest: Dictionary,
		operations: Array, journal_path: String, request: Dictionary) -> Dictionary:
	var result_id: Dictionary = {"change_set_id": change_set_id}
	var phase: String = String(latest.get("phase", ""))
	var verdict: Dictionary = ChangeJournalScript.classify_operation(latest)

	# 请求必须与记录一致（路径集合 + 读版本指纹，纯静态比对不碰磁盘）。
	var consistency: Dictionary = _request_matches_record(operations, latest)
	if consistency.has("error"):
		if phase in ChangeJournalScript.FINAL_PHASES:
			result_id["error"] = "change_set_id '%s' already exists with different operations; use a new change_set_id" % change_set_id
			result_id["prior_phase"] = phase
			return result_id
		result_id["error"] = String(consistency["error"])
		return result_id

	if phase == "committed":
		if String(verdict.get("action", "")) == "complete_receipt":
			var receipt: Dictionary = {
				"change_set_id": change_set_id,
				"intent": String(latest.get("intent", "")),
				"outcome": "receipt",
				"operation_id": String(latest.get("operation_id", "")),
				"files": verdict["files"],
				"verification": latest.get("verification", {}),
				"notes": ["This change set is already committed and the disk still matches every planned fingerprint. Nothing was rewritten."],
			}
			return receipt
		result_id["error"] = "change_set_id '%s' is committed but the disk no longer matches (rolled back or manually edited); inspect the verdict and use a new change_set_id to rewrite" % change_set_id
		result_id["prior_phase"] = phase
		result_id["verdict"] = verdict
		return result_id

	if phase == "failed" or phase == "superseded":
		result_id["error"] = "change_set_id '%s' is in terminal phase '%s'; start a new change set" % [change_set_id, phase]
		result_id["verdict"] = verdict
		return result_id

	# phase == prepared：恢复执行。
	if String(verdict.get("action", "")) == "conflict":
		return {
			"change_set_id": change_set_id,
			"intent": String(latest.get("intent", "")),
			"outcome": "conflict",
			"operation_id": String(latest.get("operation_id", "")),
			"files": verdict["files"],
			"conflicted_paths": _diverged_paths(verdict),
			"notes": ["Interrupted change set has manually-modified file(s); they were left untouched. Resolve them, then start a new change set."],
		}
	if bool(request.get("dry_run", false)):
		return {
			"change_set_id": change_set_id,
			"intent": String(latest.get("intent", "")),
			"dry_run": true,
			"outcome": "recoverable",
			"operation_id": String(latest.get("operation_id", "")),
			"verdict": verdict,
		}
	# complete_receipt：全部已应用但未收口（中断在最后一次 mark 与 finish
	# 之间）——补收口即完成，不重写任何文件。
	if String(verdict.get("action", "")) == "complete_receipt":
		ChangeJournalScript.finish_operation(String(latest.get("operation_id", "")),
			true, [], journal_path)
		return {
			"change_set_id": change_set_id,
			"intent": String(latest.get("intent", "")),
			"outcome": "resumed_committed",
			"operation_id": String(latest.get("operation_id", "")),
			"files": verdict["files"],
			"verification": {"verified": true, "mismatches": []},
			"notes": ["All files were already applied on disk; only the journal receipt was completed. No file was rewritten."],
		}
	# resume / re_prepare：applied 文件转为 already_applied 报告，只对
	# untouched 子集重新预检并执行（diverged 已被 conflict 分支拦截）。
	var pre_applied_report: Array = []
	var resume_operations: Array = []
	var untouched_set: Dictionary = {}
	for file_value in verdict.get("files", []):
		var file_entry: Dictionary = file_value
		if String(file_entry.get("state", "")) == "applied":
			pre_applied_report.append({"path": String(file_entry.get("path", "")), "state": "already_applied"})
		else:
			untouched_set[String(file_entry.get("path", ""))] = true
	for operation_value in operations:
		var operation: Dictionary = operation_value
		if untouched_set.has(_normalized(String(operation.get("path", "")))):
			resume_operations.append(operation)
	if resume_operations.is_empty():
		# 全部 applied 却没走到 complete_receipt（记录里 state 未推进）：
		# 逐文件读回核对后补收口。
		var readback_mismatches: Array = []
		for report_value in pre_applied_report:
			var report: Dictionary = report_value
			var path: String = String(report["path"])
			if ChangeJournalScript.file_sha256(path) != _recorded_after_hash(latest, path):
				readback_mismatches.append({"path": path, "issue": "recorded applied file no longer matches its planned fingerprint"})
		ChangeJournalScript.finish_operation(String(latest.get("operation_id", "")),
			readback_mismatches.is_empty(), readback_mismatches, journal_path)
		return {
			"change_set_id": change_set_id,
			"intent": String(latest.get("intent", "")),
			"outcome": "resumed_committed" if readback_mismatches.is_empty() else "failed",
			"operation_id": String(latest.get("operation_id", "")),
			"files": pre_applied_report,
			"verification": {"verified": readback_mismatches.is_empty(), "mismatches": readback_mismatches},
		}
	var preview: Dictionary = compute_preview(resume_operations)
	if preview.has("error"):
		result_id["error"] = "resume re-validation failed: %s" % String(preview["error"])
		result_id["verdict"] = verdict
		return result_id
	# 重放重算的结果必须与记录的计划一致：同读版本、不同 edits 的"篡改
	# 重放"（expected_content_hash 未变但产出的 after 不同）在此拦截。
	for entry_value in preview["entries"]:
		var entry: Dictionary = entry_value
		var entry_path: String = String(entry["path"])
		if String(entry["after_hash"]) != _recorded_after_hash(latest, entry_path):
			result_id["error"] = "replayed operation for '%s' produces a different result than the recorded plan" % entry_path
			result_id["verdict"] = verdict
			return result_id
	var result: Dictionary = _execute_entries(change_set_id,
		String(latest.get("intent", "")), String(latest.get("operation_id", "")),
		preview["entries"], pre_applied_report, request, journal_path)
	if String(result.get("outcome", "")) == "committed":
		result["outcome"] = "resumed_committed"
	return result

# ============================================================================
# 内部辅助
# ============================================================================

## 请求操作与既有记录的静态一致性：路径集合一致；modify 的
## expected_content_hash 与记录 before_hash 一致；create 的 new_content
## 指纹与记录 after_hash 一致。不读磁盘——applied 文件的磁盘已是新内容。
static func _request_matches_record(operations: Array, record: Dictionary) -> Dictionary:
	var record_by_path: Dictionary = {}
	for file_value in record.get("files", []):
		var file_entry: Dictionary = file_value
		record_by_path[String(file_entry.get("path", ""))] = file_entry
	var request_paths: Dictionary = {}
	for operation_value in operations:
		if not (operation_value is Dictionary):
			return {"error": "replayed operations failed validation: each operation must be an object"}
		var operation: Dictionary = operation_value
		var path: String = _normalized(String(operation.get("path", "")))
		request_paths[path] = true
		if not record_by_path.has(path):
			return {"error": "replayed operations add file '%s' not present in the recorded change set" % path}
		var recorded: Dictionary = record_by_path[path]
		var recorded_before: String = String(recorded.get("before_hash", ""))
		var new_content: String = String(operation.get("new_content", ""))
		if not new_content.is_empty() or bool(operation.get("create", false)):
			if new_content.sha256_text() != String(recorded.get("after_hash", "")):
				return {"error": "replayed create operation for '%s' produces a different result than the recorded plan" % path}
		else:
			if String(operation.get("expected_content_hash", "")) != recorded_before:
				return {"error": "replayed operation for '%s' pins a different read version than the recorded one" % path}
	for path_value in record_by_path:
		if not request_paths.has(String(path_value)):
			return {"error": "replayed operations miss recorded file '%s'" % String(path_value)}
	return {"ok": true}

static func _recorded_after_hash(record: Dictionary, path: String) -> String:
	for file_value in record.get("files", []):
		var file_entry: Dictionary = file_value
		if String(file_entry.get("path", "")) == path:
			return String(file_entry.get("after_hash", ""))
	return ""

## 预览的对外形态：剥离编辑载荷（内容可能很大），保留决策所需字段。
static func _public_preview(entries: Array) -> Array:
	var public_entries: Array = []
	for entry_value in entries:
		var entry: Dictionary = entry_value
		public_entries.append({
			"path": entry["path"],
			"action": entry["action"],
			"before_hash": entry["before_hash"],
			"after_hash": entry["after_hash"],
			"edit_count": (entry["replacement_counts"] as Array).size(),
		})
	return public_entries

static func _write_entry(entry: Dictionary) -> String:
	var path: String = String(entry["path"])
	if String(entry.get("action", "")) == "create":
		return _write_text_file(path, String(entry.get("new_content", "")))
	# modify：以磁盘当前内容（== before_hash 已验证）重放替换，再落盘。
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		return "could not open for reading"
	var content: String = file.get_as_text()
	file.close()
	for edit_value in entry.get("edits", []):
		var edit: Dictionary = edit_value
		content = content.replace(String(edit.get("old_text", "")), String(edit.get("new_text", "")))
	return _write_text_file(path, content)

static func _write_text_file(path: String, content: String) -> String:
	var base_dir: String = path.get_base_dir()
	if not base_dir.is_empty() and base_dir != "res://":
		var abs_dir: String = ProjectSettings.globalize_path(base_dir)
		if not DirAccess.dir_exists_absolute(abs_dir):
			var make_error: Error = DirAccess.make_dir_recursive_absolute(abs_dir)
			if make_error != OK and not DirAccess.dir_exists_absolute(abs_dir):
				return "could not create directory %s" % base_dir
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return "could not open for writing"
	file.store_string(content)
	file.close()
	return ""

static func _diverged_paths(verdict: Dictionary) -> Array:
	var diverged: Array = []
	for file_value in verdict.get("files", []):
		var file_state: String = String((file_value as Dictionary).get("state", ""))
		if file_state == "diverged":
			diverged.append(String((file_value as Dictionary).get("path", "")))
	return diverged

static func _new_change_set_id() -> String:
	return "cs_%d" % int(Time.get_unix_time_from_system() * 1000.0)

static func _is_text_extension(path: String) -> bool:
	for extension in TEXT_EXTENSIONS:
		if path.ends_with(extension):
			return true
	return false

static func _normalized(path_value: String) -> String:
	var normalized: String = path_value.strip_edges().replace("\\", "/")
	if normalized.begins_with("res:/") and not normalized.begins_with("res://"):
		normalized = "res://" + normalized.substr(5)
	while normalized.contains("//") and not normalized.begins_with("res://"):
		normalized = normalized.replace("//", "/")
	return normalized
