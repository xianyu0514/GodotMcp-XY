extends "res://addons/gut/test.gd"

## rename_script_symbol 的替换一致性测试：
## 实际写入内容、dry_run 预览与 replacement_count 必须三者一致，
## max_results 预算按"实际替换次数"而非"改动行数"记账。

const ScriptTools = preload("res://addons/godot_mcp/tools/script_tools_native.gd")
const TEMP_DIR: String = "res://.tmp_rename_symbol"

var _tools: RefCounted
var _path: String

func before_each() -> void:
	DirAccess.make_dir_recursive_absolute(TEMP_DIR)
	_tools = ScriptTools.new()
	_path = TEMP_DIR.path_join("player.gd")

func after_each() -> void:
	_tools = null
	for file_name: String in DirAccess.get_files_at(TEMP_DIR):
		DirAccess.remove_absolute(TEMP_DIR.path_join(file_name))
	DirAccess.remove_absolute(TEMP_DIR)

func _write(content: String) -> void:
	var file: FileAccess = FileAccess.open(_path, FileAccess.WRITE)
	file.store_string(content)
	file.close()

func _read() -> String:
	var file: FileAccess = FileAccess.open(_path, FileAccess.READ)
	var content: String = file.get_as_text()
	file.close()
	return content

func test_replaces_line_start_matches_with_exact_count() -> void:
	# 复现线上缺陷：RegEx.sub 第 4 参误传"替换数量"为偏移，
	# 行首匹配被跳过但计数仍报 2（speed + speed → speed + velocity）。
	_write("speed + speed\n")
	var result: Dictionary = _tools._rename_symbol_in_file(_path, "speed", "velocity", true, false, 200)
	assert_eq(_read(), "velocity + velocity\n", "line-start matches must be replaced")
	assert_eq(int(result.get("replacement_count", -1)), 2, "count must equal actual replacements")

func test_replaces_symbol_at_column_zero() -> void:
	_write("speed = 10\nvar other = speed\n")
	var result: Dictionary = _tools._rename_symbol_in_file(_path, "speed", "velocity", true, false, 200)
	assert_eq(_read(), "velocity = 10\nvar other = velocity\n", "column-zero symbol must be replaced")
	assert_eq(int(result.get("replacement_count", -1)), 2, "both occurrences counted")

func test_budget_limits_replacements_not_lines() -> void:
	# 回归：旧实现按"改动行数"记账，预算 3 实际可写 4+ 处替换。
	_write("speed + speed\nspeed + speed\nspeed + speed\n")
	var result: Dictionary = _tools._rename_symbol_in_file(_path, "speed", "velocity", true, false, 3)
	assert_eq(int(result.get("replacement_count", -1)), 3, "budget must cap actual replacements")
	assert_eq(
		_read(),
		"velocity + velocity\nvelocity + speed\nspeed + speed\n",
		"first 3 matches replaced, remainder untouched"
	)

func test_budget_zero_keeps_file_unchanged() -> void:
	_write("speed = 1\n")
	var result: Dictionary = _tools._rename_symbol_in_file(_path, "speed", "velocity", true, false, 0)
	assert_eq(result.size(), 0, "no budget must report no changes")
	assert_eq(_read(), "speed = 1\n", "file must stay unchanged")

func test_word_boundaries_prevent_false_matches() -> void:
	_write("speedy = 1\n_speed = 2\nmy_speed = 3\nspeed_max = 4\n")
	var result: Dictionary = _tools._rename_symbol_in_file(_path, "speed", "velocity", true, false, 200)
	assert_eq(result.size(), 0, "sub-identifiers and prefixed names must not match")
	assert_eq(_read(), "speedy = 1\n_speed = 2\nmy_speed = 3\nspeed_max = 4\n", "file untouched")

func test_case_insensitive_replaces_all_variants() -> void:
	_write("Speed + SPEED\n")
	var result: Dictionary = _tools._rename_symbol_in_file(_path, "speed", "velocity", false, false, 200)
	assert_eq(_read(), "velocity + velocity\n", "case-insensitive replaces all casings")
	assert_eq(int(result.get("replacement_count", -1)), 2, "count matches actual replacements")

func test_case_sensitive_skips_other_casings() -> void:
	_write("Speed + speed\n")
	var result: Dictionary = _tools._rename_symbol_in_file(_path, "speed", "velocity", true, false, 200)
	assert_eq(_read(), "Speed + velocity\n", "only exact-case match replaced")
	assert_eq(int(result.get("replacement_count", -1)), 1, "count is 1")

func test_dry_run_leaves_file_unchanged_and_preview_matches_apply() -> void:
	var source: String = "speed + speed\nspeed\n"
	_write(source)
	var preview: Dictionary = _tools._rename_symbol_in_file(_path, "speed", "velocity", true, true, 200)
	assert_eq(_read(), source, "dry_run must not write")
	assert_eq(int(preview.get("replacement_count", -1)), 3, "preview counts all matches")

	var applied: Dictionary = _tools._rename_symbol_in_file(_path, "speed", "velocity", true, false, 200)
	var preview_lines: PackedStringArray = []
	for change: Dictionary in preview.get("changes", []):
		preview_lines.append(str(change.get("after", "")))
	var applied_lines: PackedStringArray = []
	for change: Dictionary in applied.get("changes", []):
		applied_lines.append(str(change.get("after", "")))
	assert_eq(preview_lines, applied_lines, "dry_run preview must equal applied result")
	assert_eq(_read(), "velocity + velocity\nvelocity\n", "applied write is exact")

func test_no_match_returns_empty() -> void:
	_write("var health = 100\n")
	var result: Dictionary = _tools._rename_symbol_in_file(_path, "speed", "velocity", true, false, 200)
	assert_eq(result.size(), 0, "no matches must return empty dict")
	assert_eq(_read(), "var health = 100\n", "file untouched")

func test_tool_level_respects_max_results_across_files() -> void:
	_write("speed + speed\n")
	var second_path: String = TEMP_DIR.path_join("enemy.gd")
	var file: FileAccess = FileAccess.open(second_path, FileAccess.WRITE)
	file.store_string("speed + speed\n")
	file.close()

	var result: Dictionary = _tools._tool_rename_script_symbol({
		"symbol_name": "speed",
		"new_name": "velocity",
		"search_path": TEMP_DIR,
		"dry_run": false,
		"max_results": 3,
		"include_extensions": [".gd"],
	})
	assert_eq(int(result.get("replacement_count", -1)), 3, "tool-level budget caps total replacements")
	assert_false(result.has("error"), "tool call must succeed: %s" % [result.get("error", "")])

	var remaining: int = 0
	for file_name: String in ["player.gd", "enemy.gd"]:
		for line: String in _file_lines(TEMP_DIR.path_join(file_name)):
			remaining += line.count("speed")
	assert_eq(remaining, 1, "exactly one match must survive the budget cap")

func test_tool_level_missing_params() -> void:
	assert_has(_tools._tool_rename_script_symbol({"new_name": "velocity"}), "error")
	assert_has(_tools._tool_rename_script_symbol({"symbol_name": "speed"}), "error")
	assert_has(
		_tools._tool_rename_script_symbol({"symbol_name": "speed", "new_name": "speed"}),
		"error",
		"identical names must be rejected"
	)
	assert_has(
		_tools._tool_rename_script_symbol({"symbol_name": "speed", "new_name": "not an ident"}),
		"error",
		"invalid identifier must be rejected"
	)

func _file_lines(path: String) -> PackedStringArray:
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if not file:
		return PackedStringArray()
	var content: String = file.get_as_text()
	file.close()
	return content.split("\n")
