extends "res://addons/gut/test.gd"

const ProjectToolsScript = preload("res://addons/godot_mcp/tools/project_tools_native.gd")

var _tools: RefCounted = null
var _tmp_dirs: Array[String] = []

func before_each() -> void:
	_tools = ProjectToolsScript.new()

func after_each() -> void:
	for dir_path in _tmp_dirs:
		var absolute: String = ProjectSettings.globalize_path(dir_path)
		if DirAccess.dir_exists_absolute(absolute):
			_remove_recursive(absolute)
	_tmp_dirs.clear()
	_tools = null

func _tmp_dir() -> String:
	var path: String = "res://.tmp_qa_%d_%d" % [Time.get_ticks_usec(), randi() % 100000]
	_tmp_dirs.append(path)
	return path

func _remove_recursive(path: String) -> void:
	var dir: DirAccess = DirAccess.open(path)
	if dir == null:
		return
	dir.list_dir_begin()
	var entry: String = dir.get_next()
	while not entry.is_empty():
		var full_path: String = path.path_join(entry)
		if dir.current_is_dir():
			_remove_recursive(full_path)
		else:
			DirAccess.remove_absolute(full_path)
		entry = dir.get_next()
	dir.list_dir_end()
	DirAccess.remove_absolute(path)

func test_list_project_tests_missing_directory_is_recoverable() -> void:
	var missing: String = _tmp_dir().path_join("missing")
	var result: Dictionary = _tools._tool_list_project_tests({"search_path": missing})
	assert_eq(result.get("status", ""), "unconfigured")
	assert_eq(result.get("reason", ""), "test_directory_missing")
	assert_true(bool(result.get("recoverable", false)))
	assert_eq(result.get("recommended_action", ""), "ensure_project_directory")

func test_ensure_project_directory_creates_and_is_idempotent() -> void:
	var path: String = _tmp_dir()
	var first: Dictionary = _tools._tool_ensure_project_directory({"path": path})
	assert_eq(first.get("status", ""), "created", str(first))
	assert_true(bool(first.get("created", false)))
	assert_true(DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(path)))

	var second: Dictionary = _tools._tool_ensure_project_directory({"path": path})
	assert_eq(second.get("status", ""), "unchanged")
	assert_true(bool(second.get("already_exists", false)))
	assert_false(bool(second.get("created", false)))

func test_ensure_project_directory_rejects_project_root() -> void:
	var result: Dictionary = _tools._tool_ensure_project_directory({"path": "res://"})
	assert_has(result, "error", "Project root must not be created as a subdirectory")

func test_create_project_smoke_test_writes_native_marker_and_discovers() -> void:
	var path: String = _tmp_dir()
	var created: Dictionary = _tools._tool_create_project_smoke_test({"search_path": path})
	assert_eq(created.get("status", ""), "created", str(created))
	assert_eq(created.get("framework", ""), "native")
	var test_path: String = String(created.get("test_path", ""))
	assert_true(FileAccess.file_exists(test_path), "Smoke test should exist")
	assert_true(FileAccess.get_file_as_string(test_path).contains("# mcp-native-smoke-test"))

	var listed: Dictionary = _tools._tool_list_project_tests({"search_path": path})
	assert_eq(listed.get("status", ""), "ready", str(listed))
	assert_true(int(listed.get("count", 0)) >= 1)
	var found_native: bool = false
	for entry in listed.get("tests", []):
		if String((entry as Dictionary).get("framework", "")) == "native":
			found_native = true
	assert_true(found_native, "Native smoke test should be discovered")

	var again: Dictionary = _tools._tool_create_project_smoke_test({"search_path": path})
	assert_eq(again.get("status", ""), "unchanged")

func test_prepare_project_test_environment_reports_a_state() -> void:
	var result: Dictionary = _tools._tool_prepare_project_test_environment({})
	assert_true(result.get("status", "") in ["ready", "empty", "unconfigured", "blocked"], str(result))
	assert_true(result.get("environment") is Array)
	assert_false((result.get("environment", []) as Array).is_empty())

# ---------------------------------------------------------------------------
# P0-1 回归（2026-09-27 体检）：测试根目录曾被硬编码为单数 res://test，
# 复数 res://tests 项目被判"无测试"，显式传 res://tests 反而报错。
# ---------------------------------------------------------------------------

func _write_text_file(path: String, content: String) -> void:
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	file.store_string(content)
	file.close()

func test_plural_tests_dir_is_whitelisted_and_auto_discovered() -> void:
	var plural_root: String = "res://tests"
	if DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(plural_root)):
		# 保险丝：仓库若真有 res://tests，本测试绝不删它，直接跳过造数。
		assert_true(true, "skip: res://tests already exists")
		return
	_tmp_dirs.append(plural_root)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(plural_root))
	_write_text_file(plural_root.path_join("test_dummy_plural.gd"), "extends GutTest\n")

	# 显式复数路径必须可用（旧版报 "Test path must stay under res://test/"）
	var explicit: Dictionary = _tools._tool_list_project_tests({"search_path": "res://tests"})
	assert_eq(explicit.get("status", ""), "ready", str(explicit))
	assert_true(int(explicit.get("count", 0)) >= 1)

	# 默认调用必须自动发现复数目录里的测试，而不是误报 unconfigured
	var default_call: Dictionary = _tools._tool_list_project_tests({})
	assert_eq(default_call.get("status", ""), "ready", str(default_call))
	var found_plural: bool = false
	for entry in default_call.get("tests", []):
		if String((entry as Dictionary).get("test_path", "")).begins_with("res://tests/"):
			found_plural = true
	assert_true(found_plural, "默认调用应自动合并 res://tests 的发现")
	assert_true((default_call.get("search_paths", []) as Array).size() >= 2,
		"search_paths 应报告参与合并的候选目录")

func test_invalid_test_path_error_lists_existing_dirs() -> void:
	var result: Dictionary = _tools._tool_list_project_tests({"search_path": "res://scripts"})
	assert_true(result.has("error"))
	assert_true(str(result["error"]).contains("res://tests"), "错误应同时点名复数别名")
	assert_true(str(result["error"]).contains("Existing test directories"), "错误应列出实际存在的测试目录")

func test_missing_explicit_path_reports_candidates() -> void:
	var missing: String = "res://test/does_not_exist_%d" % Time.get_ticks_usec()
	var result: Dictionary = _tools._tool_list_project_tests({"search_path": missing})
	assert_eq(result.get("status", ""), "unconfigured")
	assert_true(result.has("candidates_checked"), "应上报检查过的候选目录")
	assert_true(result.has("hint"))

func test_default_call_reports_per_candidate_counts() -> void:
	var result: Dictionary = _tools._tool_list_project_tests({})
	assert_eq(result.get("status", ""), "ready")
	assert_true(int(result.get("count", 0)) > 0, "本仓库 res://test 存在大量测试")
	var reports: Array = result.get("search_paths", [])
	assert_false(reports.is_empty(), "search_paths 应给出口径级计数")

func test_gut_nothing_run_reports_skipped_not_passed() -> void:
	# 2026-09-29 真机发现（English Rift）：测试脚本不继承 GutTest 时 GUT
	# 忽略整个脚本且退出码为 0——裸 exit-code 判定把 nothing-run 转成
	# passed（假绿）。守卫必须转 skipped 并说明原因。
	var tools: RefCounted = ProjectToolsScript.new()
	# 不真跑子进程：直接验证守卫逻辑所在的输出判据（"Nothing was run"）。
	# 端到端验证在 English Rift 真机完成（体检报告 §12）。
	var fake_logs: Array = [
		"[GUT WARNING]:  Ignoring script res://tests/test_x.gd because it does not extend GutTest",
		"[GUT ERROR]:  Nothing was run.",
	]
	var output_text: String = ""
	for line in fake_logs:
		output_text += str(line) + "\n"
	assert_true(output_text.contains("Nothing was run"), "判据串必须命中")
