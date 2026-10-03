extends "res://addons/gut/test.gd"

# 2026-10-03 English Rift 台账（mcp-status.md）假信号家族修复回归测试：
#   - P0-1/S1：非 GutTest 测试文件显式标 framework=custom，零执行批次顶层
#     打 gate_warning —— "exit 0 / failed 0" 与"全绿"不可混淆；
#   - P0-2/S2：get_project_structure 深度截断显式标记，默认深度 5；
#   - P1-1：read_script 行窗口（content_hash 仍锚定全文件，乐观锁不破）；
#   - P1-2/S4：非脚本扩展指名正确工具（read_project_file / apply_change_set）；
#   - P1-3/S10：modify_script 行尾归一化兜底 + 失败诊断；
#   - S12：search_in_files 空结果三态自解释。

const SCRIPT_TOOLS = preload("res://addons/godot_mcp/tools/script_tools_native.gd")
const PROJECT_TOOLS = preload("res://addons/godot_mcp/tools/project_tools_native.gd")

var _script_tools: RefCounted = null
var _project_tools: RefCounted = null
var _tmp_dir: String = "res://.tmp_ledger_tests"


func before_each() -> void:
	_script_tools = SCRIPT_TOOLS.new()
	_project_tools = PROJECT_TOOLS.new()
	DirAccess.make_dir_recursive_absolute(_tmp_dir)


func after_each() -> void:
	_script_tools = null
	_project_tools = null
	# 递归清理：DirAccess.remove_absolute 只删空目录；fixture .gd 残留在
	# res:// 下会被 detect_broken_scripts/verify_scripts 的默认扫描吸入，
	# 污染后续测试的计数断言（实测踩过）。
	var dir: DirAccess = DirAccess.open(_tmp_dir)
	if dir:
		dir.list_dir_begin()
		var entry: String = dir.get_next()
		while not entry.is_empty():
			if entry != "." and entry != ".." and not dir.current_is_dir():
				DirAccess.remove_absolute(_tmp_dir + "/" + entry)
			entry = dir.get_next()
		dir.list_dir_end()
	DirAccess.remove_absolute(_tmp_dir)


func _write_tmp(file_name: String, content: String) -> String:
	var path: String = _tmp_dir + "/" + file_name
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	file.store_string(content)
	file.close()
	return path


# ============================================================================
# P0-1 / S1：framework 误标修复 + 零执行门禁
# ============================================================================

func test_gut_detection_recognizes_both_gut_styles() -> void:
	assert_true(PROJECT_TOOLS._file_extends_gut_test(
		_write_tmp("gut_class.gd", "extends GutTest\n\nfunc test_x() -> void:\n\tpass\n")),
		"extends GutTest must be detected as GUT")
	assert_true(PROJECT_TOOLS._file_extends_gut_test(
		_write_tmp("gut_path.gd", "extends \"res://addons/gut/test.gd\"\n\nfunc test_x() -> void:\n\tpass\n")),
		"extends gut/test.gd must be detected as GUT")
	assert_false(PROJECT_TOOLS._file_extends_gut_test(
		_write_tmp("custom_runner.gd", "extends RefCounted\n\nfunc run_all() -> void:\n\tpass\n")),
		"Custom harness (RefCounted) must NOT be labeled GUT")
	assert_false(PROJECT_TOOLS._file_extends_gut_test(
		_write_tmp("no_extends.gd", "func helper() -> void:\n\tpass\n")),
		"File without extends is not a GUT test")


func test_zero_execution_batch_gets_gate_warning_with_custom_hint() -> void:
	var result: Dictionary = PROJECT_TOOLS._append_zero_execution_gate_warning({
		"status": "skipped", "total_count": 3, "passed_count": 0, "failed_count": 0,
		"skipped_count": 3,
		"results": [
			{"status": "skipped", "framework": "custom"},
			{"status": "skipped", "framework": "custom"},
			{"status": "skipped", "framework": "custom"},
		]
	})
	assert_eq(String(result["gate_verdict"]), "no_evidence_custom_runner",
		"All-custom zero-execution batch must carry the custom-runner verdict")
	assert_true(String(result["gate_warning"]).contains("NOT a green gate"),
		"Gate warning must explicitly negate the green interpretation")
	assert_true(String(result["gate_warning"]).contains("run_tests.gd"),
		"Gate warning must suggest running the project's own runner")


func test_zero_execution_all_gut_batch_gets_generic_gate_warning() -> void:
	var result: Dictionary = PROJECT_TOOLS._append_zero_execution_gate_warning({
		"status": "skipped", "total_count": 2, "passed_count": 0, "failed_count": 0,
		"skipped_count": 2,
		"results": [
			{"status": "skipped", "framework": "gut"},
			{"status": "skipped", "framework": "gut"},
		]
	})
	assert_eq(String(result["gate_verdict"]), "no_evidence",
		"Zero-execution all-GUT batch still carries the generic no-evidence verdict")


func test_executed_batches_do_not_get_gate_warning() -> void:
	var passed_result: Dictionary = PROJECT_TOOLS._append_zero_execution_gate_warning({
		"status": "passed", "total_count": 2, "passed_count": 1, "failed_count": 0,
		"skipped_count": 1, "results": []})
	assert_false(passed_result.has("gate_verdict"),
		"A batch with real executions must not carry a gate warning")
	var empty_result: Dictionary = PROJECT_TOOLS._append_zero_execution_gate_warning({
		"status": "skipped", "total_count": 0, "passed_count": 0, "failed_count": 0,
		"skipped_count": 0, "results": []})
	assert_false(empty_result.has("gate_verdict"),
		"Empty discovery has its own reason field; no gate warning")


# ============================================================================
# P0-2 / S2：get_project_structure 深度截断显式化
# ============================================================================

func test_project_structure_flags_truncation_and_defaults_to_depth_5() -> void:
	var default_call: Dictionary = _project_tools._tool_get_project_structure({})
	assert_eq(int(default_call["max_depth"]), 5, "Default depth must be 5, not 3")
	# 本仓库 addons/godot_mcp/tools 层级 ≥4，depth=1 必然截断。
	var shallow: Dictionary = _project_tools._tool_get_project_structure({"max_depth": 1})
	assert_true(bool(shallow["truncated_by_depth"]),
		"Depth-1 scan of this repo must be flagged as truncated")
	assert_gt(int(shallow["unexplored_directory_count"]), 0,
		"Truncated scan must count unexplored subdirectories")
	assert_true(String(shallow.get("depth_note", "")).contains("NOT scanned"),
		"Depth note must say what was excluded")
	var deep: Dictionary = _project_tools._tool_get_project_structure({"max_depth": 12})
	assert_false(bool(deep["truncated_by_depth"]),
		"A depth-12 scan of this repo should cover everything")


# ============================================================================
# P1-1：read_script 行窗口（hash 锚定全文件）
# ============================================================================

const PAGED_FILE_BODY: String = "line0\nline1\nline2\nline3\nline4\n"

func test_read_script_paging_windows_content_but_keeps_whole_file_hash() -> void:
	var path: String = _write_tmp("paged.gd", PAGED_FILE_BODY)
	var full: Dictionary = _script_tools._tool_read_script({"script_path": path})
	assert_eq(String(full["content"]), PAGED_FILE_BODY, "Whole-file read unchanged")
	assert_false(bool(full["has_more"]), "Whole read has no next page")

	var page: Dictionary = _script_tools._tool_read_script({
		"script_path": path, "offset_lines": 2, "max_lines": 2})
	assert_eq(String(page["content"]), "line2\nline3", "Window must return exactly the requested lines")
	assert_eq(int(page["returned_line_count"]), 2)
	assert_eq(int(page["next_offset_lines"]), 4, "Next page starts at the cut line")
	assert_true(bool(page["has_more"]), "Two-page read must have more")
	# 关键契约：分页不改变乐观锁锚点。
	assert_eq(String(page["content_hash"]), String(full["content_hash"]),
		"Paged read must return the WHOLE-file hash")

	var tail: Dictionary = _script_tools._tool_read_script({
		"script_path": path, "offset_lines": 4, "max_lines": 10})
	assert_eq(String(tail["content"]), "line4\n", "Tail window clips at file end")
	assert_false(bool(tail["has_more"]), "Last page has no next")

	var overflow: Dictionary = _script_tools._tool_read_script({
		"script_path": path, "offset_lines": 99})
	assert_eq(String(overflow["content"]), "", "Offset past EOF returns empty content")
	assert_false(bool(overflow["has_more"]), "Offset past EOF has no next page")


func test_read_script_paging_preserves_crlf_bytes() -> void:
	var crlf_path: String = _write_tmp("crlf_paged.gd", "alpha\r\nbeta\r\ngamma\r\n")
	var paged: Dictionary = _script_tools._tool_read_script({
		"script_path": crlf_path, "offset_lines": 1, "max_lines": 1})
	# \r 保留在行内容里：窗口重组不丢字节，hash 仍等于原文。
	assert_eq(String(paged["content"]), "beta\r", "CRLF bytes must survive windowing")
	var full: Dictionary = _script_tools._tool_read_script({"script_path": crlf_path})
	assert_eq(String(paged["content_hash"]), String(full["content_hash"]),
		"CRLF paged hash equals whole-file hash")


func test_read_script_rejects_non_script_with_tool_hint() -> void:
	var json_path: String = _write_tmp("data.json", "{\"k\": 1}")
	var result: Dictionary = _script_tools._tool_read_script({"script_path": json_path})
	assert_eq(String(result["error_code"]), "not_a_script",
		"Non-script extensions must be rejected with the typed error")
	assert_true(String(result["next_step"]).contains("read_project_file"),
		"Self-heal hint must name the right tool")


# ============================================================================
# P1-3 / S10：modify_script 行尾归一化
# ============================================================================

func test_modify_script_normalizes_lf_old_text_against_crlf_file() -> void:
	var path: String = _write_tmp("crlf_edit.gd", "func a():\r\n\tpass\r\nfunc b():\r\n\tpass\r\n")
	var result: Dictionary = _script_tools._tool_modify_script({
		"script_path": path,
		"old_text": "func a():\n\tpass\n",
		"content": "func a():\n\treturn 1\n",
		"validate": false
	})
	assert_eq(String(result["status"]), "success",
		"LF old_text against CRLF file must succeed via normalization")
	assert_true(bool(result["line_endings_normalized"]),
		"Normalization must be reported to the caller")
	var after: String = FileAccess.get_file_as_string(path)
	assert_true(after.contains("func a():\r\n\treturn 1\r\n"),
		"Replacement text must follow the file's CRLF style")
	assert_true(after.contains("func b():\r\n\tpass\r\n"),
		"Untouched block must keep its original CRLF bytes")


func test_modify_script_normalizes_crlf_old_text_against_lf_file() -> void:
	var path: String = _write_tmp("lf_edit.gd", "func a():\n\tpass\n")
	var result: Dictionary = _script_tools._tool_modify_script({
		"script_path": path,
		"old_text": "func a():\r\n\tpass\r\n",
		"content": "func a():\r\n\treturn 2\r\n",
		"validate": false
	})
	assert_eq(String(result["status"]), "success",
		"CRLF old_text against LF file must succeed via normalization")
	assert_true(bool(result["line_endings_normalized"]), "Normalization reported")
	assert_true(FileAccess.get_file_as_string(path).contains("return 2"),
		"Edit content must land in the file")


func test_modify_script_missing_text_reports_line_ending_diagnosis() -> void:
	var path: String = _write_tmp("crlf_miss.gd", "func a():\r\n\tpass\r\n")
	var result: Dictionary = _script_tools._tool_modify_script({
		"script_path": path,
		"old_text": "completely different text",
		"content": "x",
		"validate": false
	})
	assert_eq(String(result["error_code"]), "text_not_found", "Genuine miss still fails")
	assert_eq(String(result["file_line_endings"]), "CRLF", "Failure must report file style")
	assert_eq(String(result["old_text_line_endings"]), "LF", "Failure must report old_text style")


func test_modify_script_rejects_non_script_with_change_set_hint() -> void:
	var json_path: String = _write_tmp("write_me.json", "{}")
	var result: Dictionary = _script_tools._tool_modify_script({
		"script_path": json_path, "content": "{\"k\": 1}"})
	assert_eq(String(result["error_code"]), "not_a_script",
		"Write side must also reject non-scripts with the typed error")
	assert_true(String(result["next_step"]).contains("apply_change_set"),
		"Write-side hint must name apply_change_set")


# ============================================================================
# S12：search_in_files 空结果三态
# ============================================================================

func test_search_in_files_empty_reasons_are_distinguishable() -> void:
	_write_tmp("haystack.gd", "func needle() -> void:\n\tpass\n")
	var no_match: Dictionary = _script_tools._tool_search_in_files({
		"pattern": "quantum_unicorns", "search_path": _tmp_dir, "file_extensions": [".gd"]})
	assert_eq(int(no_match["total_matches"]), 0, "Precondition: zero matches")
	assert_eq(String(no_match["empty_reason"]), "pattern_matched_nothing",
		"Files were searched but nothing matched")

	var wrong_ext: Dictionary = _script_tools._tool_search_in_files({
		"pattern": "needle", "search_path": _tmp_dir, "file_extensions": [".zig"]})
	assert_eq(String(wrong_ext["empty_reason"]), "no_files_matched_extensions",
		"Zero candidate files is a different conclusion from zero matches")
