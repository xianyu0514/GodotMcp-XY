extends "res://addons/gut/test.gd"

## M3 首版变更日志测试：
## 1) ChangeJournal 纯逻辑生命周期与恢复分类（中断矩阵：
##    re_prepare / resume / complete_receipt / conflict）
## 2) rename_script_symbol 工具级接线（两遍应用、指纹绑定、
##    手工修改冲突拒绝 R4、旧 pending 接续与取代、幂等重跑 R3）

const ScriptTools = preload("res://addons/godot_mcp/tools/script_tools_native.gd")
const ChangeJournal = preload("res://addons/godot_mcp/tools/change_journal.gd")

const TEMP_DIR: String = "res://.tmp_rename_journal"
const TOOL_JOURNAL: String = "res://.mcp/change_journal.json"

var _tools: RefCounted

func before_each() -> void:
	DirAccess.make_dir_recursive_absolute(TEMP_DIR)
	_tools = ScriptTools.new()
	_reset_tool_journal()

func after_each() -> void:
	_tools = null
	_reset_tool_journal()
	for file_name: String in DirAccess.get_files_at(TEMP_DIR):
		DirAccess.remove_absolute(TEMP_DIR.path_join(file_name))
	DirAccess.remove_absolute(TEMP_DIR)

func _reset_tool_journal() -> void:
	if FileAccess.file_exists(TOOL_JOURNAL):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(TOOL_JOURNAL))

func _write(path: String, content: String) -> void:
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	file.store_string(content)
	file.close()

func _read(path: String) -> String:
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	var content: String = file.get_as_text()
	file.close()
	return content

# ============================================================================
# ChangeJournal 纯逻辑
# ============================================================================

func test_begin_mark_finish_lifecycle_persists_every_step() -> void:
	var journal_path: String = TEMP_DIR + "/journal.json"
	var path_a: String = TEMP_DIR + "/a.gd"
	var path_b: String = TEMP_DIR + "/b.gd"
	_write(path_a, "speed = 1\n")
	_write(path_b, "speed = 2\n")
	var entries: Array = [
		{"path": path_a, "before_hash": "speed = 1\n".sha256_text(), "after_hash": "velocity = 1\n".sha256_text(), "replacement_count": 1},
		{"path": path_b, "before_hash": "speed = 2\n".sha256_text(), "after_hash": "velocity = 2\n".sha256_text(), "replacement_count": 1},
	]
	var begun: Dictionary = ChangeJournal.begin_operation("rename speed -> velocity", entries, journal_path)
	assert_false(begun.has("error"), str(begun.get("error", "")))
	var operation_id: String = begun["operation"]["operation_id"]

	var mid: Dictionary = ChangeJournal.load_journal(journal_path)
	assert_eq(String((mid["operations"] as Array)[0]["phase"]), "prepared",
		"record is visible on disk before any file write")

	assert_false(ChangeJournal.mark_file_applied(operation_id, path_a, journal_path).has("error"))
	var after_a: Dictionary = ChangeJournal.load_journal(journal_path)
	var file_states: Dictionary = {}
	for file_value in (after_a["operations"] as Array)[0]["files"]:
		file_states[file_value["path"]] = file_value["state"]
	assert_eq(file_states[path_a], "applied", "first file write advances its journal state immediately")
	assert_eq(file_states[path_b], "planned", "second file stays planned until written")

	assert_false(ChangeJournal.finish_operation(operation_id, true, [], journal_path).has("error"))
	var done: Dictionary = ChangeJournal.load_journal(journal_path)
	var record: Dictionary = (done["operations"] as Array)[0]
	assert_eq(String(record["phase"]), "committed")
	assert_true(bool(record["verification"]["verified"]))
	assert_eq(ChangeJournal.pending_operations_touching([path_a], journal_path).size(), 0,
		"committed operations are no longer pending")

func test_finish_failed_records_mismatches() -> void:
	var journal_path: String = TEMP_DIR + "/journal.json"
	var begun: Dictionary = ChangeJournal.begin_operation("intent", [
		{"path": TEMP_DIR + "/a.gd", "before_hash": "x", "after_hash": "y", "replacement_count": 1},
	], journal_path)
	var mismatches: Array = [{"path": TEMP_DIR + "/a.gd", "issue": "post-write disk content does not match"}]
	ChangeJournal.finish_operation(begun["operation"]["operation_id"], false, mismatches, journal_path)
	var journal: Dictionary = ChangeJournal.load_journal(journal_path)
	var record: Dictionary = (journal["operations"] as Array)[0]
	assert_eq(String(record["phase"]), "failed")
	assert_eq((record["verification"]["mismatches"] as Array).size(), 1)

func test_classify_interruption_matrix() -> void:
	var journal_path: String = TEMP_DIR + "/journal.json"
	var path_a: String = TEMP_DIR + "/a.gd"
	var path_b: String = TEMP_DIR + "/b.gd"
	var before_a: String = "speed = 1\n"
	var after_a: String = "velocity = 1\n"
	var before_b: String = "speed = 2\n"
	var after_b: String = "velocity = 2\n"
	var entries: Array = [
		{"path": path_a, "before_hash": before_a.sha256_text(), "after_hash": after_a.sha256_text(), "replacement_count": 1},
		{"path": path_b, "before_hash": before_b.sha256_text(), "after_hash": after_b.sha256_text(), "replacement_count": 1},
	]

	# 崩溃在 prepare 之后：全部 untouched → re_prepare
	_write(path_a, before_a)
	_write(path_b, before_b)
	var record: Dictionary = ChangeJournal.begin_operation("intent", entries, journal_path)["operation"]
	var verdict: Dictionary = ChangeJournal.classify_operation(record)
	assert_eq(String(verdict["action"]), "re_prepare", "crash after prepare: nothing was written")

	# 崩溃在首文件写入后：mixed → resume（重跑幂等补齐）
	_write(path_a, after_a)
	assert_eq(String(ChangeJournal.classify_operation(record)["action"]), "resume")

	# 崩溃在末文件写入后（回执前）：全部 applied → complete_receipt
	_write(path_b, after_b)
	assert_eq(String(ChangeJournal.classify_operation(record)["action"]), "complete_receipt")

	# 手工修改：diverged → conflict，且指名冲突文件
	_write(path_b, "hand = edited\n")
	var conflict: Dictionary = ChangeJournal.classify_operation(record)
	assert_eq(String(conflict["action"]), "conflict")
	var diverged: Array = []
	for file_value in conflict["files"]:
		if String(file_value["state"]) == "diverged":
			diverged.append(String(file_value["path"]))
	assert_has(diverged, path_b, "conflict verdict names the manually-modified file")

func test_classify_missing_file_is_conflict() -> void:
	var journal_path: String = TEMP_DIR + "/journal.json"
	var path_a: String = TEMP_DIR + "/gone.gd"
	var begun: Dictionary = ChangeJournal.begin_operation("intent", [
		{"path": path_a, "before_hash": "x".sha256_text(), "after_hash": "y".sha256_text(), "replacement_count": 1},
	], journal_path)
	assert_eq(String(ChangeJournal.classify_operation(begun["operation"])["action"]), "conflict",
		"a deleted target file is a conflict, not a pass")

func test_supersede_pending_keeps_audit_and_skips_self() -> void:
	var journal_path: String = TEMP_DIR + "/journal.json"
	var path_a: String = TEMP_DIR + "/a.gd"
	_write(path_a, "speed = 1\n")
	var first: Dictionary = ChangeJournal.begin_operation("first", [
		{"path": path_a, "before_hash": "speed = 1\n".sha256_text(), "after_hash": "velocity = 1\n".sha256_text(), "replacement_count": 1},
	], journal_path)["operation"]
	var second: Dictionary = ChangeJournal.begin_operation("second", [
		{"path": path_a, "before_hash": "speed = 1\n".sha256_text(), "after_hash": "velocity = 1\n".sha256_text(), "replacement_count": 1},
	], journal_path)["operation"]

	var result: Dictionary = ChangeJournal.supersede_pending_touching([path_a], String(second["operation_id"]), journal_path)
	assert_false(result.has("error"), str(result.get("error", "")))
	var superseded_ids: Array = result["superseded"]
	assert_has(superseded_ids, String(first["operation_id"]), "stale pending operation is superseded")
	assert_false(superseded_ids.has(String(second["operation_id"])), "supersede must not supersede itself")

	var journal: Dictionary = ChangeJournal.load_journal(journal_path)
	var phases: Dictionary = {}
	for operation_value in journal["operations"]:
		phases[operation_value["operation_id"]] = operation_value["phase"]
	assert_eq(String(phases[first["operation_id"]]), "superseded")
	assert_eq(String(phases[second["operation_id"]]), "prepared", "the new operation stays live")
	assert_eq(ChangeJournal.pending_operations_touching([path_a], journal_path).size(), 1)

# ============================================================================
# rename_script_symbol 工具级接线（默认 journal 路径）
# ============================================================================

func _tool_rename(symbol: String, replacement: String, dry_run: bool, max_results: int = 50) -> Dictionary:
	return _tools._tool_rename_script_symbol({
		"symbol_name": symbol,
		"new_name": replacement,
		"search_path": TEMP_DIR,
		"dry_run": dry_run,
		"max_results": max_results,
		"include_extensions": [".gd"],
	})

func test_apply_creates_committed_journal_record() -> void:
	var path_a: String = TEMP_DIR + "/player.gd"
	var path_b: String = TEMP_DIR + "/enemy.gd"
	_write(path_a, "speed = 1\n")
	_write(path_b, "speed = 2\n")

	var result: Dictionary = _tool_rename("speed", "velocity", false)
	assert_false(result.has("error"), str(result.get("error", "")))
	assert_eq(int(result["replacement_count"]), 2)
	var journal_info: Dictionary = result.get("change_journal", {})
	assert_eq(String(journal_info.get("phase", "")), "committed")
	assert_true(bool(journal_info.get("verified", false)))
	assert_eq(int(journal_info.get("file_count", 0)), 2)

	var journal: Dictionary = ChangeJournal.load_journal(TOOL_JOURNAL)
	assert_false(journal.has("error"))
	var record: Dictionary = (journal["operations"] as Array)[0]
	assert_eq(String(record["phase"]), "committed")
	for file_value in record["files"]:
		assert_eq(String(file_value["state"]), "applied", str(file_value["path"]) + " recorded as applied")
	assert_eq(_read(path_a), "velocity = 1\n")
	assert_eq(_read(path_b), "velocity = 2\n")

func test_dry_run_creates_no_journal_record() -> void:
	_write(TEMP_DIR + "/player.gd", "speed = 1\n")
	var result: Dictionary = _tool_rename("speed", "velocity", true)
	assert_true(result.get("dry_run", false))
	assert_false(FileAccess.file_exists(TOOL_JOURNAL), "preview must not persist an operation record")

func test_prior_diverged_operation_refuses_and_preserves_manual_edit() -> void:
	var path_a: String = TEMP_DIR + "/player.gd"
	var original: String = "speed = 1\n"
	_write(path_a, original)
	# 模拟崩溃后手工修改：pending 记录存在，磁盘既不是 before 也不是 after
	ChangeJournal.begin_operation("interrupted rename", [
		{"path": path_a, "before_hash": original.sha256_text(),
		 "after_hash": "velocity = 1\n".sha256_text(), "replacement_count": 1},
	])
	var manual_content: String = "speed = 1  # hand-tuned\n"
	_write(path_a, manual_content)

	var result: Dictionary = _tool_rename("speed", "velocity", false)
	assert_has(result, "error", "rename must refuse when a prior operation diverged (R4)")
	assert_eq(String((result.get("prior_operation", {}) as Dictionary).get("action", "")), "conflict")
	assert_eq(_read(path_a), manual_content, "the manual edit is preserved untouched")

func test_prior_pending_without_conflict_resumes_and_supersedes() -> void:
	var path_a: String = TEMP_DIR + "/player.gd"
	var original: String = "speed = 1\n"
	_write(path_a, original)
	# 模拟崩溃在 prepare 之后（磁盘仍是原内容，无手工修改）
	var stale: Dictionary = ChangeJournal.begin_operation("interrupted rename", [
		{"path": path_a, "before_hash": original.sha256_text(),
		 "after_hash": "velocity = 1\n".sha256_text(), "replacement_count": 1},
	])["operation"]

	var result: Dictionary = _tool_rename("speed", "velocity", false)
	assert_false(result.has("error"), str(result.get("error", "")))
	var resumed: Array = result.get("resumed_prior_operations", [])
	assert_eq(resumed.size(), 1, "the stale pending operation is reported as resumed context")
	assert_eq(String((resumed[0] as Dictionary).get("action", "")), "re_prepare")
	assert_eq(_read(path_a), "velocity = 1\n", "the rename completes the intended change")

	var journal: Dictionary = ChangeJournal.load_journal(TOOL_JOURNAL)
	var phases: Dictionary = {}
	for operation_value in journal["operations"]:
		phases[operation_value["operation_id"]] = operation_value["phase"]
	assert_eq(String(phases[stale["operation_id"]]), "superseded",
		"stale pending record is closed as superseded, not left dangling")
	assert_true(phases.values().has("committed"))

func test_rerun_after_completion_is_idempotent_and_clean() -> void:
	var path_a: String = TEMP_DIR + "/player.gd"
	_write(path_a, "speed = 1\n")
	assert_false(_tool_rename("speed", "velocity", false).has("error"))

	var again: Dictionary = _tool_rename("speed", "velocity", false)
	assert_false(again.has("error"), str(again.get("error", "")))
	assert_eq(int(again["replacement_count"]), 0, "nothing left to rename")
	# 无事可做 = 没有写入 = 不产生新的操作记录（journal 只记录写操作）
	assert_false(again.has("change_journal"), "a no-op rerun creates no journal record")
	assert_eq(_read(path_a), "velocity = 1\n")
	assert_eq(ChangeJournal.pending_operations_touching([path_a], TOOL_JOURNAL).size(), 0,
		"R3: no dangling pending operations after a completed rename")
