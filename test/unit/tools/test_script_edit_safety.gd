extends "res://addons/gut/test.gd"

const ScriptTools = preload("res://addons/godot_mcp/tools/script_tools_native.gd")
const TEMP_DIR: String = "res://.tmp_script_edit_safety"
const SOURCE: String = "extends RefCounted\n# 保留手工注释\nvar speed: int = 100\n"
var _tools: RefCounted
var _path: String

class FakeScriptEditor extends RefCounted:
	var unsaved: PackedStringArray = []
	func get_unsaved_files() -> PackedStringArray:
		return unsaved

func test_buffer_guard_blocks_only_target_and_reports_unavailable_api() -> void:
	var editor: FakeScriptEditor = FakeScriptEditor.new()
	editor.unsaved = PackedStringArray([_path])
	assert_eq(_tools._script_buffer_write_guard(editor, _path).get("error_code"), "unsaved_script_changes")
	editor.unsaved = PackedStringArray(["res://other.gd"])
	assert_false(_tools._script_buffer_write_guard(editor, _path).has("error"))
	assert_true(_tools._script_buffer_write_guard(editor, _path).get("supported", false))
	assert_false(_tools._script_buffer_write_guard(null, _path).get("supported", true))
	assert_false(_tools._script_buffer_write_guard(RefCounted.new(), _path).get("supported", true))

func test_buffer_guard_normalizes_absolute_paths_and_windows_case() -> void:
	var editor: FakeScriptEditor = FakeScriptEditor.new()
	editor.unsaved = PackedStringArray([ProjectSettings.globalize_path(_path)])
	assert_has(_tools._script_buffer_write_guard(editor, _path), "error")
	if OS.get_name() == "Windows":
		editor.unsaved = PackedStringArray([_path.to_upper().replace("RES://", "res://")])
		assert_has(_tools._script_buffer_write_guard(editor, _path), "error")

func test_csharp_guarded_edit_keeps_not_checked_status() -> void:
	_path = TEMP_DIR.path_join("Player.cs")
	var source: String = "// 原有说明\npublic class Player { public int Speed = 100; }\n"
	_write(source)
	var result: Dictionary = _edit({"old_text": "Speed = 100", "content": "Speed = 200", "expected_content_hash": source.sha256_text().to_upper(), "validate": true})
	assert_eq(result.get("validation_status"), "not_checked")
	assert_eq(_source(), source.replace("100", "200"))

func before_each() -> void:
	DirAccess.make_dir_recursive_absolute(TEMP_DIR)
	_tools = ScriptTools.new()
	_path = TEMP_DIR.path_join("player.gd")
	_write(SOURCE)

func after_each() -> void:
	_tools = null
	for file_name: String in DirAccess.get_files_at(TEMP_DIR):
		DirAccess.remove_absolute(TEMP_DIR.path_join(file_name))
	DirAccess.remove_absolute(TEMP_DIR)

func _write(content: String) -> void:
	var file: FileAccess = FileAccess.open(_path, FileAccess.WRITE)
	file.store_string(content)
	file.close()

func _source() -> String:
	var file: FileAccess = FileAccess.open(_path, FileAccess.READ)
	var content: String = file.get_buffer(file.get_length()).get_string_from_utf8()
	file.close()
	return content

func _edit(extra: Dictionary) -> Dictionary:
	var params: Dictionary = {"script_path": _path, "content": "extends RefCounted\n", "validate": false}
	params.merge(extra, true)
	return _tools._tool_modify_script(params)

func test_read_and_batch_read_return_revision_of_exact_text() -> void:
	var content: String = SOURCE.replace("\n", "\r\n")
	_write(content)
	var single: Dictionary = _tools._tool_read_script({"script_path": _path})
	var batch: Dictionary = _tools._tool_batch_read_scripts({"script_paths": [_path]})
	assert_eq(single.get("content"), content)
	assert_eq(single.get("content_hash"), content.sha256_text())
	assert_eq(batch["results"][0].get("content_hash"), single.get("content_hash"))

func test_matching_revision_allows_legacy_replacement_and_returns_next_revision() -> void:
	var updated: String = SOURCE.replace("100", "200")
	var result: Dictionary = _edit({"content": updated, "expected_content_hash": SOURCE.sha256_text()})
	assert_eq(result.get("status"), "success")
	assert_eq(result.get("content_hash"), updated.sha256_text())
	assert_eq(_source(), updated)

func test_stale_revision_preserves_manual_changes() -> void:
	var manual: String = SOURCE + "var health: int = 7\n"
	_write(manual)
	var result: Dictionary = _edit({"expected_content_hash": SOURCE.sha256_text()})
	assert_eq(result.get("error_code"), "content_conflict")
	assert_eq(result.get("current_content_hash"), manual.sha256_text())
	assert_false(result.has("validation_status"))
	assert_eq(_source(), manual)

func test_same_length_change_is_a_conflict() -> void:
	_write(SOURCE.replace("100", "101"))
	assert_eq(_edit({"expected_content_hash": SOURCE.sha256_text()}).get("error_code"), "content_conflict")
	assert_eq(_source(), SOURCE.replace("100", "101"))

func test_exact_text_edit_preserves_surrounding_code() -> void:
	var result: Dictionary = _edit({"old_text": "var speed: int = 100", "content": "var speed: int = 250"})
	assert_eq(result.get("status"), "success")
	assert_eq(_source(), SOURCE.replace("100", "250"))

func test_exact_text_edit_supports_multiline_deletion() -> void:
	var result: Dictionary = _edit({"old_text": "# 保留手工注释\nvar speed: int = 100\n", "content": ""})
	assert_eq(result.get("status"), "success")
	assert_eq(_source(), "extends RefCounted\n")

func test_missing_anchor_preserves_file() -> void:
	assert_eq(_edit({"old_text": "missing"}).get("error_code"), "text_not_found")
	assert_eq(_source(), SOURCE)

func test_duplicate_anchor_preserves_file() -> void:
	_write(SOURCE + "# speed\n")
	assert_eq(_edit({"old_text": "speed"}).get("error_code"), "ambiguous_text")
	assert_eq(_source(), SOURCE + "# speed\n")

func test_overlapping_matches_are_ambiguous() -> void:
	_write("# aaa\n")
	assert_eq(_edit({"old_text": "aa"}).get("error_code"), "ambiguous_text")
	assert_eq(_source(), "# aaa\n")

func test_out_of_range_line_never_falls_back_to_full_replacement() -> void:
	assert_has(_edit({"line_number": 999}), "error")
	assert_eq(_source(), SOURCE)

func test_negative_and_fractional_lines_are_rejected() -> void:
	for line: Variant in [-1, 1.5, "2", true]:
		assert_has(_edit({"line_number": line}), "error")
		assert_eq(_source(), SOURCE)

func test_zero_line_retains_legacy_whole_file_replacement() -> void:
	assert_eq(_edit({"line_number": 0}).get("status"), "success")
	assert_eq(_source(), "extends RefCounted\n")

func test_line_edit_preserves_crlf_and_final_newline() -> void:
	_write(SOURCE.replace("\n", "\r\n"))
	assert_eq(_edit({"line_number": 3, "content": "var speed: int = 2"}).get("status"), "success")
	assert_eq(_source(), SOURCE.replace("100", "2").replace("\n", "\r\n"))

func test_line_edit_accepts_integral_json_number_and_no_final_newline() -> void:
	_write("extends RefCounted\nvar speed: int = 100")
	assert_eq(_edit({"line_number": 2.0, "content": "var speed: int = 2"}).get("status"), "success")
	assert_eq(_source(), "extends RefCounted\nvar speed: int = 2")

func test_invalid_edit_modes_and_hashes_preserve_file() -> void:
	for params: Dictionary in [
		{"old_text": ""}, {"old_text": 7}, {"old_text": "speed", "line_number": 3},
		{"expected_content_hash": ""}, {"expected_content_hash": "abc"}, {"expected_content_hash": 2},
		{"expected_content_hash": "z".repeat(64)}, {"content": ""}, {"content": 4}]:
		assert_has(_edit(params), "error", str(params))
		assert_eq(_source(), SOURCE)

func test_new_revision_can_be_used_for_next_edit() -> void:
	var first: Dictionary = _edit({"old_text": "100", "content": "200", "expected_content_hash": SOURCE.sha256_text()})
	var second: Dictionary = _edit({"old_text": "200", "content": "300", "expected_content_hash": first.get("content_hash", "")})
	assert_eq(second.get("status"), "success")
	assert_eq(_source(), SOURCE.replace("100", "300"))
