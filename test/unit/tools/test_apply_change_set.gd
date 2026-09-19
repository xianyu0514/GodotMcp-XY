extends "res://addons/gut/test.gd"

## apply_change_set（M5 第二交付）工具级测试：参数校验、dry_run 预览、
## 执行与恢复 outcome 的 follow-up 指引。执行协议本身由
## test_change_set_executor.gd 覆盖（工具层是薄封装）。

const ChangeSetToolsScript = preload("res://addons/godot_mcp/tools/change_set_tools.gd")

const TMP: String = "res://.tmp_apply_cs"
const JOURNAL: String = TMP + "/journal.json"

var _tools: RefCounted

func before_each() -> void:
	DirAccess.make_dir_recursive_absolute(TMP + "/src")
	_write(TMP + "/src/a.gd", "extends Node\nvar speed := 10\n")
	_write(TMP + "/src/b.gd", "extends Node\nvar speed := 20\n")
	_tools = ChangeSetToolsScript.new()
	_tools._journal_path = JOURNAL

func after_each() -> void:
	_tools = null
	_remove_tree(TMP)

func _operations() -> Array:
	return [
		{"path": TMP + "/src/a.gd", "expected_content_hash": _hash(TMP + "/src/a.gd"),
			"edits": [{"old_text": "var speed := 10", "new_text": "var speed := 11"}]},
		{"path": TMP + "/src/b.gd", "expected_content_hash": _hash(TMP + "/src/b.gd"),
			"edits": [{"old_text": "var speed := 20", "new_text": "var speed := 21"}]},
	]

func _call(params: Dictionary, operations: Array = []) -> Dictionary:
	var base: Dictionary = {
		"intent": "bump speed",
		"operations": operations if not operations.is_empty() else _operations(),
		"change_set_id": "cs_tool_1",
	}
	for key in params:
		base[key] = params[key]
	return _tools._tool_apply_change_set(base)

func test_parameter_validation() -> void:
	assert_has(_tools._tool_apply_change_set({}), "error")
	assert_has(_tools._tool_apply_change_set({"intent": "x"}), "error")
	assert_has(_tools._tool_apply_change_set({"intent": "x", "operations": []}), "error")
	assert_has(_tools._tool_apply_change_set({"operations": [{"path": "res://x.gd"}]}), "error")

func test_dry_run_preview_with_follow_up() -> void:
	var result: Dictionary = _call({"dry_run": true})
	assert_false(result.has("error"), str(result.get("error", "")))
	assert_eq(String(result["outcome"]), "planned")
	assert_eq((result["preview"] as Array).size(), 2)
	assert_true(_follow_up_has(result, "dry_run omitted to execute"),
		"planned outcome explains how to execute")
	assert_eq(_read(TMP + "/src/a.gd"), "extends Node\nvar speed := 10\n")

func test_commit_adds_verification_follow_up() -> void:
	var result: Dictionary = _call({})
	assert_eq(String(result["outcome"]), "committed", str(result))
	assert_true(_follow_up_has(result, "verify_scripts"),
		"commit points at compile verification")
	assert_true(_follow_up_has(result, "query_change_impact"),
		"commit points at the impact review")

func test_recovery_outcome_explains_resume() -> void:
	# 执行器 interrupt_after 是内部测试钩子；工具层通过 journal 状态模拟：
	# 先提交一半（手动用 executor），再经工具重放拿到恢复 outcome。
	var operations: Array = _operations()
	var executor: RefCounted = preload("res://addons/godot_mcp/tools/change_set_executor.gd").new()
	executor.apply({
		"intent": "bump speed", "operations": operations,
		"change_set_id": "cs_tool_1", "journal_path": JOURNAL, "interrupt_after": 1,
	})
	var resumed: Dictionary = _call({}, operations)
	assert_eq(String(resumed["outcome"]), "resumed_committed", str(resumed))
	assert_eq(_read(TMP + "/src/b.gd"), "extends Node\nvar speed := 21\n")

func _follow_up_has(result: Dictionary, fragment: String) -> bool:
	for step in result.get("follow_up", []):
		if String(step).contains(fragment):
			return true
	return false

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
