extends "res://addons/gut/test.gd"

## ChangeSetExecutor（M5 第二交付）单元测试：预览绑定读版本、journal 不可写
## 禁止开始、逐文件中断（第 1/居中/最后）、恢复续做、重复提交幂等、
## 手工修改冲突保护、create 模式、一致性拒绝。

const ExecutorScript = preload("res://addons/godot_mcp/tools/change_set_executor.gd")
const ChangeJournalScript = preload("res://addons/godot_mcp/tools/change_journal.gd")

const TMP: String = "res://.tmp_change_set"
const JOURNAL: String = TMP + "/journal.json"

func before_each() -> void:
	DirAccess.make_dir_recursive_absolute(TMP + "/src")
	_reset_fixture()

func after_each() -> void:
	_remove_tree(TMP)

func _reset_fixture() -> void:
	_write(TMP + "/src/a.gd", "extends Node\nvar speed := 10\n")
	_write(TMP + "/src/b.gd", "extends Node\nvar speed := 20\n")
	_write(TMP + "/src/c.gd", "extends Node\nvar speed := 30\n")
	if FileAccess.file_exists(JOURNAL):
		DirAccess.remove_absolute(JOURNAL)

func _operations() -> Array:
	return [
		{"path": TMP + "/src/a.gd", "expected_content_hash": _hash(TMP + "/src/a.gd"),
			"edits": [{"old_text": "var speed := 10", "new_text": "var speed := 11"}]},
		{"path": TMP + "/src/b.gd", "expected_content_hash": _hash(TMP + "/src/b.gd"),
			"edits": [{"old_text": "var speed := 20", "new_text": "var speed := 21"}]},
		{"path": TMP + "/src/c.gd", "expected_content_hash": _hash(TMP + "/src/c.gd"),
			"edits": [{"old_text": "var speed := 30", "new_text": "var speed := 31"}]},
	]

func _request(extra: Dictionary = {}) -> Dictionary:
	var base: Dictionary = {
		"intent": "bump speed constants",
		"operations": _operations(),
		"change_set_id": "cs_test_1",
		"journal_path": JOURNAL,
	}
	for key in extra:
		base[key] = extra[key]
	return base

# ============================================================================
# 预览与前置拒绝
# ============================================================================

func test_dry_run_returns_preview_and_writes_nothing() -> void:
	var result: Dictionary = ExecutorScript.apply(_request({"dry_run": true}))
	assert_false(result.has("error"), str(result.get("error", "")))
	assert_eq(String(result["outcome"]), "planned")
	assert_eq((result["preview"] as Array).size(), 3)
	assert_eq(String((result["preview"] as Array)[0]["action"]), "modify")
	assert_eq(_read(TMP + "/src/a.gd"), "extends Node\nvar speed := 10\n", "nothing written")
	assert_false(FileAccess.file_exists(JOURNAL), "dry run does not touch the journal")

func test_stale_expected_hash_rejected_before_any_write() -> void:
	var operations: Array = _operations()
	(operations[0] as Dictionary)["expected_content_hash"] = String("0").repeat(64)
	var result: Dictionary = ExecutorScript.apply(_request({"operations": operations}))
	assert_has(result, "error")
	assert_true(String(result["error"]).contains("no longer matches"), str(result["error"]))
	assert_eq(_read(TMP + "/src/b.gd"), "extends Node\nvar speed := 20\n", "no file touched")

func test_non_unique_edit_rejected() -> void:
	_write(TMP + "/src/a.gd", "extends Node\nvar dup := 1\nvar dup := 1\n")
	var operations: Array = [
		{"path": TMP + "/src/a.gd", "expected_content_hash": _hash(TMP + "/src/a.gd"),
			"edits": [{"old_text": "var dup := 1", "new_text": "var dup := 2"}]},
	]
	var result: Dictionary = ExecutorScript.apply(_request({"operations": operations}))
	assert_has(result, "error")
	assert_true(String(result["error"]).contains("exactly once"), str(result["error"]))

func test_journal_unwritable_refuses_to_start() -> void:
	# journal 路径指向一个已存在的目录 → 保存必然失败 → 硬门禁。
	var result: Dictionary = ExecutorScript.apply(_request({"journal_path": TMP + "/src"}))
	assert_has(result, "error")
	assert_true(String(result["error"]).contains("refusing to start"), str(result["error"]))
	assert_eq(_read(TMP + "/src/a.gd"), "extends Node\nvar speed := 10\n",
		"no file written without a recovery log")

# ============================================================================
# 执行与中断恢复（第 1 / 居中 / 最后一个文件后中断）
# ============================================================================

func test_commit_all_files_with_readback() -> void:
	var result: Dictionary = ExecutorScript.apply(_request())
	assert_false(result.has("error"), str(result.get("error", "")))
	assert_eq(String(result["outcome"]), "committed")
	assert_eq(_read(TMP + "/src/a.gd"), "extends Node\nvar speed := 11\n")
	assert_eq(_read(TMP + "/src/c.gd"), "extends Node\nvar speed := 31\n")
	assert_true(bool(result["verification"]["verified"]))

func test_interrupt_after_first_file_requires_recovery() -> void:
	var result: Dictionary = ExecutorScript.apply(_request({"interrupt_after": 1}))
	assert_eq(String(result["outcome"]), "requires_recovery")
	assert_eq(_read(TMP + "/src/a.gd"), "extends Node\nvar speed := 11\n", "first file applied")
	assert_eq(_read(TMP + "/src/b.gd"), "extends Node\nvar speed := 20\n", "rest untouched")
	var journal: Dictionary = ChangeJournalScript.load_journal(JOURNAL)
	assert_eq(String((journal["operations"] as Array)[0]["phase"]), "prepared",
		"journal stays prepared across the interruption")

func test_interrupt_after_middle_and_last_file() -> void:
	var operations: Array = _operations()
	var middle: Dictionary = ExecutorScript.apply(_request({"operations": operations, "interrupt_after": 2}))
	assert_eq(String(middle["outcome"]), "requires_recovery")
	assert_eq(_read(TMP + "/src/c.gd"), "extends Node\nvar speed := 30\n")

	# 最后一个文件写入后、finish 之前中断：全部内容已应用但未收口。
	_reset_fixture()
	var last: Dictionary = ExecutorScript.apply(_request({"operations": operations, "interrupt_after": 3}))
	assert_eq(String(last["outcome"]), "requires_recovery")
	assert_eq(_read(TMP + "/src/c.gd"), "extends Node\nvar speed := 31\n")
	# 此状态重放 → complete_receipt 收口，不再写入。
	var replay: Dictionary = ExecutorScript.apply(_request({"operations": operations}))
	assert_eq(String(replay["outcome"]), "resumed_committed", str(replay))
	assert_eq(_read(TMP + "/src/a.gd"), "extends Node\nvar speed := 11\n")

func test_resume_after_interrupt_completes_remaining_files() -> void:
	var operations: Array = _operations()
	ExecutorScript.apply(_request({"operations": operations, "interrupt_after": 1}))
	var resumed: Dictionary = ExecutorScript.apply(_request({"operations": operations}))
	assert_eq(String(resumed["outcome"]), "resumed_committed", str(resumed))
	var states: Dictionary = {}
	for file_entry in resumed["files"]:
		states[String((file_entry as Dictionary)["path"])] = String((file_entry as Dictionary)["state"])
	assert_eq(String(states[TMP + "/src/a.gd"]), "already_applied", "applied file is skipped, not rewritten")
	assert_eq(String(states[TMP + "/src/b.gd"]), "applied")
	assert_eq(_read(TMP + "/src/b.gd"), "extends Node\nvar speed := 21\n")
	assert_eq(_read(TMP + "/src/c.gd"), "extends Node\nvar speed := 31\n")
	var journal: Dictionary = ChangeJournalScript.load_journal(JOURNAL)
	assert_eq(String((journal["operations"] as Array)[0]["phase"]), "committed")

func test_repeat_after_commit_returns_receipt_without_rewriting() -> void:
	var operations: Array = _operations()
	ExecutorScript.apply(_request({"operations": operations}))
	var receipt: Dictionary = ExecutorScript.apply(_request({"operations": operations}))
	assert_eq(String(receipt["outcome"]), "receipt", str(receipt))
	assert_eq(_read(TMP + "/src/a.gd"), "extends Node\nvar speed := 11\n",
		"committed content stays exactly one application")
	assert_eq(String((receipt["notes"] as Array)[0]).contains("Nothing was rewritten"), true)

# ============================================================================
# 手工修改保护（R4 契约）
# ============================================================================

func test_manual_edit_during_interruption_conflicts_and_is_preserved() -> void:
	var operations: Array = _operations()
	ExecutorScript.apply(_request({"operations": operations, "interrupt_after": 1}))
	# 用户在 b.gd 上手工修改。
	_write(TMP + "/src/b.gd", "extends Node\nvar speed := 999\n")
	var result: Dictionary = ExecutorScript.apply(_request({"operations": operations}))
	assert_eq(String(result["outcome"]), "conflict", str(result))
	assert_eq(_read(TMP + "/src/b.gd"), "extends Node\nvar speed := 999\n",
		"manual work is preserved, never overwritten")
	assert_has(result["conflicted_paths"], TMP + "/src/b.gd")

func test_committed_then_manually_rolled_back_requires_new_id() -> void:
	var operations: Array = _operations()
	ExecutorScript.apply(_request({"operations": operations}))
	_write(TMP + "/src/a.gd", "extends Node\nvar speed := 10\n")
	var result: Dictionary = ExecutorScript.apply(_request({"operations": operations}))
	assert_has(result, "error")
	assert_true(String(result["error"]).contains("no longer matches"), str(result["error"]))

# ============================================================================
# 身份与一致性
# ============================================================================

func test_same_id_with_different_operations_rejected() -> void:
	var operations: Array = _operations()
	ExecutorScript.apply(_request({"operations": operations, "interrupt_after": 1}))
	var tampered: Array = operations.duplicate(true)
	(tampered[2] as Dictionary)["edits"] = [{"old_text": "var speed := 30", "new_text": "var speed := 77"}]
	var result: Dictionary = ExecutorScript.apply(_request({"operations": tampered}))
	assert_has(result, "error")
	assert_true(String(result["error"]).contains("different read version")
		or String(result["error"]).contains("different operations")
		or String(result["error"]).contains("different result"), str(result["error"]))

func test_missing_operation_for_recorded_file_rejected() -> void:
	var operations: Array = _operations()
	ExecutorScript.apply(_request({"operations": operations, "interrupt_after": 1}))
	var partial: Array = operations.duplicate(true)
	partial.remove_at(2)
	var result: Dictionary = ExecutorScript.apply(_request({"operations": partial}))
	assert_has(result, "error")
	assert_true(String(result["error"]).contains("miss recorded file"), str(result["error"]))

# ============================================================================
# create 模式
# ============================================================================

func test_create_mode_writes_new_file_and_recovers() -> void:
	var operations: Array = [
		{"path": TMP + "/src/new_config.json", "new_content": "{\"speed\": 11}\n"},
	]
	var result: Dictionary = ExecutorScript.apply(_request({"operations": operations,
		"change_set_id": "cs_create_1"}))
	assert_eq(String(result["outcome"]), "committed", str(result))
	assert_eq(_read(TMP + "/src/new_config.json"), "{\"speed\": 11}\n")

	# create 目标已存在再重放 → receipt（内容一致）。
	var replay: Dictionary = ExecutorScript.apply(_request({"operations": operations,
		"change_set_id": "cs_create_1"}))
	assert_eq(String(replay["outcome"]), "receipt", str(replay))

func test_create_target_collision_conflicts() -> void:
	_write(TMP + "/src/collide.json", "{}\n")
	var operations: Array = [
		{"path": TMP + "/src/collide.json", "new_content": "{\"a\": 1}\n"},
	]
	var result: Dictionary = ExecutorScript.apply(_request({"operations": operations}))
	assert_has(result, "error")
	assert_eq(_read(TMP + "/src/collide.json"), "{}\n", "existing file untouched")

func test_generated_id_returned_for_caller_replay() -> void:
	var operations: Array = [
		{"path": TMP + "/src/a.gd", "expected_content_hash": _hash(TMP + "/src/a.gd"),
			"edits": [{"old_text": "var speed := 10", "new_text": "var speed := 12"}]},
	]
	var first: Dictionary = ExecutorScript.apply({
		"intent": "one file", "operations": operations, "journal_path": JOURNAL,
	})
	assert_false(first.has("error"), str(first.get("error", "")))
	assert_eq(String(first["outcome"]), "committed")
	assert_false(String(first["change_set_id"]).is_empty(), "generated id is returned")
	# 带回生成的 id 重放 → receipt。
	var replay: Dictionary = ExecutorScript.apply({
		"intent": "one file", "operations": operations, "journal_path": JOURNAL,
		"change_set_id": first["change_set_id"],
	})
	assert_eq(String(replay["outcome"]), "receipt")

# ============================================================================
# 参数校验
# ============================================================================

func test_parameter_validation() -> void:
	assert_has(ExecutorScript.apply({}), "error")
	assert_has(ExecutorScript.apply({"intent": "x"}), "error")
	assert_has(ExecutorScript.apply({"intent": "", "operations": []}), "error")
	assert_has(ExecutorScript.apply({"intent": "x", "operations": "nope"}), "error")
	assert_has(ExecutorScript.apply({"intent": "x", "operations": [], "journal_path": JOURNAL}), "error")

# ============================================================================
# 夹具
# ============================================================================

func _write(path: String, content: String) -> void:
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	file.store_string(content)
	file.close()

func _read(path: String) -> String:
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		return ""
	var content: String = file.get_as_text()
	file.close()
	return content

func _hash(path: String) -> String:
	return _read(path).sha256_text()

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
