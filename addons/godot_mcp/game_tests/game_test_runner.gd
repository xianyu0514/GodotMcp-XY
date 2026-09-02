extends SceneTree

## 游戏测试 headless 运行器（无 class_name：仅作为 -s 入口加载）。
##
## 用法：
##   godot --headless --path <project> \
##     -s addons/godot_mcp/game_tests/game_test_runner.gd -- \
##     <suite.gd 或目录...> [--output-json=<path>] [--timeout-ms=<n>]
##
## 输出协议：每个测试一行人类可读日志，最后一行固定为
##   GAME_TESTS_RESULT <single-line JSON>
## 工具层（run_game_tests）解析最后一行拿结构化结果；完整控制台输出
## 原样透传，SCRIPT ERROR 等运行期报错对调用方始终可见。
## 退出码：0 = 全部通过（且至少跑了一个测试）；1 = 存在失败或零测试；3 = 超时。

const RESULT_MARKER: String = "GAME_TESTS_RESULT "
const DEFAULT_TIMEOUT_MS: int = 180000

var _suite_inputs: Array[String] = []
var _output_json_path: String = ""
var _timeout_ms: int = DEFAULT_TIMEOUT_MS
var _deadline_ms: int = 0
var _started: bool = false
var _finished: bool = false
var _results: Array[Dictionary] = []
var _exit_code: int = 0
var _suite_errors: Array[String] = []


func _initialize() -> void:
	for arg_value in OS.get_cmdline_user_args():
		var arg: String = String(arg_value)
		if arg.begins_with("--output-json="):
			_output_json_path = arg.substr("--output-json=".length()).strip_edges()
		elif arg.begins_with("--result-id="):
			# 结果文件路径双方各自从 user:// 推导：命令行只传无空格 id，
			# 避免含空格的绝对路径被参数拆分。
			var result_id: String = arg.substr("--result-id=".length()).strip_edges()
			if not result_id.is_empty():
				_output_json_path = ProjectSettings.globalize_path(
					"user://.mcp_game_tests/%s.json" % result_id)
		elif arg.begins_with("--timeout-ms="):
			_timeout_ms = int(arg.substr("--timeout-ms=".length()))
		elif arg.begins_with("--"):
			continue
		elif not arg.strip_edges().is_empty():
			_suite_inputs.append(arg.strip_edges())
	_deadline_ms = Time.get_ticks_msec() + maxi(1000, _timeout_ms)
	_run_all.call_deferred()


## 看门狗：协程卡死（await 永不返回）时由 _process 兜底退出，避免子进程
## 挂到工具层超时之外。返回 false 表示继续主循环（SceneTree._process 语义）。
func _process(_delta: float) -> bool:
	if _finished or not _started:
		return false
	if Time.get_ticks_msec() > _deadline_ms:
		_finished = true
		_print_line("[game-tests] TIMEOUT after %d ms" % _timeout_ms)
		_emit_summary("timeout")
		quit(3)
	return false


func _run_all() -> void:
	_started = true
	var suite_paths: Array[String] = []
	for entry in _suite_inputs:
		suite_paths.append_array(_collect_suite_paths(entry))
	if suite_paths.is_empty():
		_suite_errors.append("no McpGameTestSuite files found")
		_finish()
		return
	for suite_path in suite_paths:
		await _run_suite_file(suite_path)
	_finish()


func _finish() -> void:
	_finished = true
	var passed: bool = _suite_errors.is_empty() \
		and not _results.is_empty() \
		and int(_count_status("passed")) == _results.size()
	_exit_code = 0 if passed else 1
	_emit_summary("completed")
	quit(_exit_code)


func _emit_summary(phase: String) -> void:
	var payload: Dictionary = _summary_payload(phase)
	_print_line(RESULT_MARKER + JSON.stringify(payload))
	if not _output_json_path.is_empty():
		DirAccess.make_dir_recursive_absolute(_output_json_path.get_base_dir())
		var file: FileAccess = FileAccess.open(_output_json_path, FileAccess.WRITE)
		if file != null:
			file.store_string(JSON.stringify(payload, "\t"))
			file.close()


func _summary_payload(phase: String) -> Dictionary:
	return {
		"status": "passed" if _exit_code == 0 and phase == "completed" else "failed",
		"phase": phase,
		"total_count": _results.size(),
		"passed_count": _count_status("passed"),
		"failed_count": _count_status("failed"),
		"suite_errors": _suite_errors.duplicate(),
		"results": _results.duplicate()
	}


func _count_status(status: String) -> int:
	var count: int = 0
	for entry in _results:
		if String(entry.get("status", "")) == status:
			count += 1
	return count


func _collect_suite_paths(entry: String) -> Array[String]:
	var paths: Array[String] = []
	var absolute: String = ProjectSettings.globalize_path(entry)
	if FileAccess.file_exists(absolute):
		if entry.get_extension().to_lower() == "gd":
			paths.append(entry)
		return paths
	if not DirAccess.dir_exists_absolute(absolute):
		return paths
	_collect_gd_recursive(entry, paths)
	paths.sort()
	return paths


func _collect_gd_recursive(dir_res_path: String, out_paths: Array[String]) -> void:
	var dir: DirAccess = DirAccess.open(dir_res_path)
	if dir == null:
		return
	dir.list_dir_begin()
	while true:
		var name: String = dir.get_next()
		if name.is_empty():
			break
		if name.begins_with(".") or name == "addons":
			continue
		var child: String = dir_res_path.path_join(name)
		if dir.current_is_dir():
			_collect_gd_recursive(child, out_paths)
		elif name.get_extension().to_lower() == "gd":
			out_paths.append(child)
	dir.list_dir_end()


func _run_suite_file(suite_path: String) -> void:
	var script: GDScript = load(suite_path) as GDScript
	if script == null:
		_suite_errors.append("cannot load suite: %s" % suite_path)
		_print_line("[game-tests] SUITE-ERROR cannot load %s" % suite_path)
		return
	var suite: RefCounted = script.new()
	if not _is_suite_instance(suite):
		_suite_errors.append("not a McpGameTestSuite: %s" % suite_path)
		_print_line("[game-tests] SUITE-ERROR not a suite %s" % suite_path)
		return
	suite.set("_tree", self)
	var test_names: Array[String] = []
	for method_value in script.get_script_method_list():
		var method: Dictionary = method_value
		var method_name: String = String(method.get("name", ""))
		if method_name.begins_with("test_") and method_name not in test_names:
			test_names.append(method_name)
	test_names.sort()
	if test_names.is_empty():
		_suite_errors.append("suite has no test_ methods: %s" % suite_path)
		return
	_print_line("[game-tests] SUITE %s (%d tests)" % [suite_path, test_names.size()])
	suite.call("before_all")
	for test_name in test_names:
		await _run_one_test(suite, suite_path, test_name)
	suite.call("after_all")


func _is_suite_instance(value: Variant) -> bool:
	# 不用 `is SuiteBase`（本文件不持引用）：检查实例是否具备套件协议
	# （_reset_for_test/_cleanup_spawned/check 方法），足以兼容 extends 字符串路径。
	if not (value is RefCounted):
		return false
	var object: Object = value
	return object.has_method("_reset_for_test") \
		and object.has_method("_cleanup_spawned") \
		and object.has_method("check")


func _run_one_test(suite: RefCounted, suite_path: String, test_name: String) -> void:
	suite.call("_reset_for_test", test_name)
	suite.call("before_each")
	var started_ms: int = Time.get_ticks_msec()
	await suite.call(test_name)
	var failures: Array = suite.get("_failures")
	var entry: Dictionary = {
		"suite": suite_path,
		"test": test_name,
		"status": "passed" if failures.is_empty() else "failed",
		"checks": int(suite.get("_check_count")),
		"failures": failures.duplicate(),
		"duration_ms": Time.get_ticks_msec() - started_ms
	}
	suite.call("after_each")
	suite.call("_cleanup_spawned")
	_results.append(entry)
	var head: String = "PASS" if failures.is_empty() else "FAIL"
	_print_line("[game-tests] %s %s.%s (%d checks, %d ms)" % [
		head, suite_path.get_file().get_basename(), test_name,
		int(entry["checks"]), int(entry["duration_ms"])])
	for failure_value in failures:
		_print_line("[game-tests]   - %s" % String(failure_value))


func _print_line(line: String) -> void:
	print(line)
