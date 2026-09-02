extends "res://addons/gut/test.gd"

## 游戏测试框架回归：基类断言语义、套件发现、结果行解析、工具参数校验，
## 以及一次真实的 headless 子进程端到端运行（证明框架在真实引擎里可用）。

const ProjectToolsScript = preload("res://addons/godot_mcp/tools/project_tools_native.gd")
const SuiteBaseScript = preload("res://addons/godot_mcp/game_tests/game_test_suite.gd")

const FIXTURE_DIR: String = "res://test/unit/.tmp_game_suite_scan"
const FIXTURE_SUITE: String = "res://test/unit/.tmp_game_suite_run.gd"


func before_each() -> void:
	_remove_if_exists(FIXTURE_SUITE)
	_remove_if_exists(FIXTURE_SUITE + ".uid")
	_cleanup_fixture_dir()


func after_each() -> void:
	_remove_if_exists(FIXTURE_SUITE)
	_remove_if_exists(FIXTURE_SUITE + ".uid")
	_cleanup_fixture_dir()


func _remove_if_exists(path: String) -> void:
	var absolute: String = ProjectSettings.globalize_path(path)
	if FileAccess.file_exists(absolute):
		DirAccess.remove_absolute(absolute)


func _cleanup_fixture_dir(path: String = FIXTURE_DIR) -> void:
	var absolute: String = ProjectSettings.globalize_path(path)
	if not DirAccess.dir_exists_absolute(absolute):
		return
	var dir: DirAccess = DirAccess.open(absolute)
	if dir == null:
		return
	dir.list_dir_begin()
	var entries: Array[String] = []
	while true:
		var entry: String = dir.get_next()
		if entry.is_empty():
			break
		entries.append(entry)
	dir.list_dir_end()
	for entry in entries:
		if entry.begins_with("."):
			continue
		var child: String = absolute.path_join(entry)
		if DirAccess.dir_exists_absolute(child):
			_cleanup_fixture_dir(ProjectSettings.localize_path(child))
		else:
			DirAccess.remove_absolute(child)
	DirAccess.remove_absolute(absolute)


func _write_file(path: String, content: String) -> void:
	var absolute: String = ProjectSettings.globalize_path(path)
	var dir_path: String = absolute.get_base_dir()
	DirAccess.make_dir_recursive_absolute(dir_path)
	var file: FileAccess = FileAccess.open(absolute, FileAccess.WRITE)
	assert_not_null(file, "fixture write must succeed: " + path)
	file.store_string(content)
	file.close()


# ---------------------------------------------------------------------------
# 基类断言语义
# ---------------------------------------------------------------------------

func test_suite_base_records_failures_with_counters():
	var suite: RefCounted = SuiteBaseScript.new()
	suite._reset_for_test("test_example")
	assert_true(suite.check(true, "ok case"), "A passing check returns true")
	assert_false(suite.check(false, "custom message"), "A failing check returns false")
	assert_false(suite.check_eq(1, 2), "Mismatched values return false")
	assert_false(suite.check_ne(1, 1), "Equal values fail check_ne")
	assert_false(suite.check_gt(1, 5), "1 > 5 must fail")
	assert_false(suite.check_lt(5, 1), "5 < 1 must fail")
	assert_false(suite.check_not_null(null), "null fails check_not_null")
	assert_false(suite.check_is_null(7), "7 fails check_is_null")
	suite.fail("explicit")
	var failures: Array = suite.get("_failures")
	assert_eq(failures.size(), 8, "Every failing assertion records one failure")
	assert_eq(int(suite.get("_check_count")), 9, "Counter tracks all checks including the passing one")
	assert_true(String(failures[0]).contains("test_example: custom message"),
		"Failures carry the current test name prefix")
	assert_true(String(failures[1]).contains("expected 2, got 1"),
		"check_eq reports expected vs actual")

func test_suite_base_reset_clears_previous_test_state():
	var suite: RefCounted = SuiteBaseScript.new()
	suite._reset_for_test("test_first")
	suite.check(false, "first failure")
	suite._reset_for_test("test_second")
	assert_eq((suite.get("_failures") as Array).size(), 0, "Reset clears failures")
	assert_eq(int(suite.get("_check_count")), 0, "Reset clears the check counter")


# ---------------------------------------------------------------------------
# 发现与源码识别
# ---------------------------------------------------------------------------

func test_game_test_source_detection():
	var tools: RefCounted = ProjectToolsScript.new()
	assert_false(tools._is_game_test_suite_source("res://test/unit/nope.gd"),
		"Missing file is not a suite")
	_write_file(FIXTURE_SUITE, "extends \"res://addons/godot_mcp/game_tests/game_test_suite.gd\"\n\nfunc test_x() -> void:\n\tcheck(true)\n")
	assert_true(tools._is_game_test_suite_source(FIXTURE_SUITE),
		"Path-form extends is recognized")
	_write_file(FIXTURE_SUITE, "extends McpGameTestSuite\n\nfunc test_x() -> void:\n\tcheck(true)\n")
	assert_true(tools._is_game_test_suite_source(FIXTURE_SUITE),
		"Class-name extends is recognized")
	_write_file(FIXTURE_SUITE, "extends Node\n\nfunc test_x() -> void:\n\tpass\n")
	assert_false(tools._is_game_test_suite_source(FIXTURE_SUITE),
		"An unrelated script is not a suite")

func test_game_test_discovery_scans_recursively_and_skips_unrelated():
	var tools: RefCounted = ProjectToolsScript.new()
	_write_file(FIXTURE_DIR + "/deep/alpha_suite.gd",
		"extends McpGameTestSuite\n\nfunc test_a() -> void:\n\tcheck(true)\n")
	_write_file(FIXTURE_DIR + "/deep/plain.gd", "extends Node\n")
	var found: Array[String] = tools._discover_game_test_suites(FIXTURE_DIR)
	assert_eq(found.size(), 1, "Only the suite file is discovered")
	assert_eq(String(found[0]), FIXTURE_DIR + "/deep/alpha_suite.gd", "Discovery recurses")

func test_run_game_tests_zero_discovery_is_failed_not_passed():
	var tools: RefCounted = ProjectToolsScript.new()
	var result: Dictionary = tools._tool_run_game_tests({"search_path": FIXTURE_DIR})
	assert_eq(String(result.get("status", "")), "failed",
		"Zero discovered suites must never report passed")
	assert_eq(int(result.get("total_count", -1)), 0, "Zero suites reported explicitly")

func test_run_game_tests_rejects_invalid_explicit_paths():
	var tools: RefCounted = ProjectToolsScript.new()
	assert_true(tools._tool_run_game_tests({"test_paths": ["res://test/unit/not_there.gd"]}).has("error"),
		"Missing explicit suite errors")
	_write_file(FIXTURE_SUITE, "extends Node\n")
	assert_true(tools._tool_run_game_tests({"test_paths": [FIXTURE_SUITE]}).has("error"),
		"A non-suite explicit path errors instead of silently running")
	assert_true(tools._tool_run_game_tests({"test_paths": ["res://test/unit/whatever.py"]}).has("error"),
		"Non-.gd explicit path errors")


# ---------------------------------------------------------------------------
# 结果行解析
# ---------------------------------------------------------------------------

func test_game_tests_summary_parser():
	var tools: RefCounted = ProjectToolsScript.new()
	var payload: String = JSON.stringify({
		"status": "failed", "total_count": 3, "passed_count": 2, "failed_count": 1})
	var parsed: Dictionary = tools._parse_game_tests_summary([
		"[game-tests] FAIL suite.test_x", "GAME_TESTS_RESULT " + payload])
	assert_eq(String(parsed.get("status", "")), "failed", "Marker line is parsed from the tail")
	assert_eq(int(parsed.get("total_count", 0)), 3, "Payload fields survive parsing")
	assert_eq(int(parsed.get("passed_count", 0)), 2, "passed_count preserved")
	assert_true(tools._parse_game_tests_summary(["no marker here"]).is_empty(),
		"No marker yields an empty dict (caller marks failed)")
	var malformed: Dictionary = tools._parse_game_tests_summary(["GAME_TESTS_RESULT {not json"])
	assert_eq(String(malformed.get("status", "")), "failed", "Malformed payload reports failed")
	# GUT 9.3 与 Godot 4.6.3 的启动期引擎噪音（lazy_loader 单例探测）可能落进
	# 本测试的错误窗口；解析器本身不做任何文件/IO，标记已处理避免误报。
	for error in get_errors():
		error.handled = true


# ---------------------------------------------------------------------------
# 真实 headless 端到端运行（一次子进程，证明框架可用）
# ---------------------------------------------------------------------------

func test_game_tests_end_to_end_headless_run():
	var tools: RefCounted = ProjectToolsScript.new()
	# 用路径形式 extends：不依赖全局类缓存，子进程冷启动也能解析。
	_write_file(FIXTURE_SUITE, """extends "res://addons/godot_mcp/game_tests/game_test_suite.gd"

func test_passes() -> void:
	check(true, "trivial pass")
	check_eq(1 + 1, 2, "arithmetic")

func test_fails_expectedly() -> void:
	check_eq(1, 2, "deliberate mismatch")

func test_async_frames() -> void:
	await step_frames(3)
	check(_tree != null, "runner injected the SceneTree")
""")
	var suite_paths: Array[String] = [FIXTURE_SUITE]
	var result: Dictionary = tools._execute_game_tests_blocking(suite_paths, 60000)
	assert_false(result.has("error"), str(result.get("error", "")))
	assert_eq(String(result.get("status", "")), "failed",
		"One failing check must fail the whole run (never a silent pass)")
	assert_eq(int(result.get("exit_code", 0)), 1, "Runner exit code is 1 on failures")
	assert_eq(int(result.get("total_count", 0)), 3, "All three tests ran")
	assert_eq(int(result.get("passed_count", 0)), 2, "Two tests passed")
	assert_eq(int(result.get("failed_count", 0)), 1, "One test failed")
	var results: Array = result.get("results", [])
	assert_eq(results.size(), 3, "Per-test entries returned")
	var by_name: Dictionary = {}
	for entry_value in results:
		var entry: Dictionary = entry_value
		by_name[String(entry.get("test", ""))] = entry
	assert_eq(String((by_name.get("test_fails_expectedly", {}) as Dictionary).get("status", "")),
		"failed", "The failing test is reported as failed")
	assert_true(String((by_name.get("test_async_frames", {}) as Dictionary).get("status", ""))
		== "passed", "Async frame-stepping test passed in a real engine")
	var failures: Array = (by_name.get("test_fails_expectedly", {}) as Dictionary).get("failures", [])
	assert_true(String(failures[0] if not failures.is_empty() else "").contains("deliberate mismatch"),
		"Failure messages survive the subprocess boundary")
