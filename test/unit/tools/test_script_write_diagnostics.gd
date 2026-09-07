extends "res://addons/gut/test.gd"

const ScriptTools = preload("res://addons/godot_mcp/tools/script_tools_native.gd")
const WriteDiagnostics = preload("res://addons/godot_mcp/utils/script_write_diagnostics.gd")
const TEMP_DIR: String = "res://.tmp_script_write_diagnostics"

var _tools: RefCounted

func before_each() -> void:
	DirAccess.make_dir_recursive_absolute(TEMP_DIR)
	_tools = ScriptTools.new()

func after_each() -> void:
	_tools = null
	for file_name in DirAccess.get_files_at(TEMP_DIR):
		DirAccess.remove_absolute(TEMP_DIR.path_join(file_name))
	DirAccess.remove_absolute(TEMP_DIR)

func _write(name: String, content: String) -> String:
	var path: String = TEMP_DIR.path_join(name)
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	file.store_string(content)
	file.close()
	return path

func _handle_expected_parse_errors() -> void:
	for error in get_errors():
		error.handled = true

func test_create_returns_checked_diagnostics_without_changing_write_success() -> void:
	var path: String = TEMP_DIR.path_join("valid.gd")
	var result: Dictionary = _tools._tool_create_script({"script_path": path, "content": "extends RefCounted\n"})
	assert_eq(result.get("status"), "success")
	assert_eq(result.get("validation_status"), "passed", "Successful writes also report compilation")
	assert_eq(result.get("diagnostics", ["missing"]), [])
	assert_true(FileAccess.file_exists(path))

func test_create_reports_engine_error_line_while_preserving_written_source() -> void:
	var path: String = TEMP_DIR.path_join("broken.gd")
	var content: String = "extends RefCounted\n\nfunc broken(\n"
	var result: Dictionary = _tools._tool_create_script({"script_path": path, "content": content})
	_handle_expected_parse_errors()
	assert_eq(result.get("status"), "success", "The write committed even though compilation failed")
	assert_eq(result.get("validation_status"), "failed")
	assert_eq(FileAccess.get_file_as_string(path), content)
	var diagnostics: Array = result.get("diagnostics", [])
	assert_gt(diagnostics.size(), 0)
	if not diagnostics.is_empty():
		assert_eq(diagnostics[0].get("path"), path)
		assert_gt(int(diagnostics[0].get("line", 0)), 0, "Use the engine's line number")
		assert_eq(diagnostics[0].get("severity"), "error")
		assert_false(String(diagnostics[0].get("message", "")).is_empty())

func test_modify_validates_final_line_edit_and_does_not_reuse_cached_source() -> void:
	var path: String = _write("cached.gd", "extends RefCounted\nvar answer: int = 42\n")
	var cached: GDScript = load(path)
	var instance: RefCounted = cached.new()
	var result: Dictionary = _tools._tool_modify_script({"script_path": path, "content": "var answer: int =", "line_number": 2})
	_handle_expected_parse_errors()
	assert_eq(result.get("validation_status"), "failed", "An old cached valid Script is not proof of the new write")
	assert_true(FileAccess.get_file_as_string(path).contains("var answer: int =\n"))
	assert_same(ResourceLoader.get_cached_ref(path), cached, "Do not replace the Script held by live objects")
	assert_eq(instance.get("answer"), 42, "A failed reload must preserve existing instance state")

func test_repair_clears_previous_diagnostics() -> void:
	var path: String = _write("repair.gd", "extends RefCounted\n")
	var broken: Dictionary = _tools._tool_modify_script({"script_path": path, "content": "extends RefCounted\nfunc broken(\n"})
	_handle_expected_parse_errors()
	var repaired: Dictionary = _tools._tool_modify_script({"script_path": path, "content": "extends RefCounted\n"})
	assert_eq(broken.get("validation_status"), "failed")
	assert_eq(repaired.get("validation_status"), "passed")
	assert_eq(repaired.get("diagnostics", ["missing"]), [], "Diagnostics are scoped to this write")

func test_relative_preload_is_resolved_from_saved_script_directory() -> void:
	_write("dependency.gd", "extends RefCounted\nconst VALUE: int = 7\n")
	var result: Dictionary = _tools._tool_create_script({
		"script_path": TEMP_DIR.path_join("dependent.gd"),
		"content": "extends RefCounted\nconst Dependency = preload(\"dependency.gd\")\n"})
	assert_eq(result.get("validation_status"), "passed", "Validation retains the actual resource path")

func test_csharp_write_is_explicitly_not_checked_by_gdscript() -> void:
	var path: String = TEMP_DIR.path_join("Player.cs")
	var created: Dictionary = _tools._tool_create_script({"script_path": path, "content": "using Godot;\npublic partial class Player : Node {}\n"})
	var modified: Dictionary = _tools._tool_modify_script({"script_path": path, "content": "// C# is compiled by the project .NET build\n"})
	for result in [created, modified]:
		assert_eq(result.get("status"), "success")
		assert_eq(result.get("validation_status"), "not_checked")
		assert_eq(result.get("diagnostics", ["missing"]), [])
		assert_false(String(result.get("validation_hint", "")).is_empty())

func test_invalid_write_arguments_do_not_produce_a_validation_success() -> void:
	var result: Dictionary = _tools._tool_create_script({"script_path": TEMP_DIR.path_join("unsupported.txt")})
	assert_has(result, "error")
	assert_false(result.has("validation_status"))

func test_abstract_script_is_valid_without_being_instantiable() -> void:
	var result: Dictionary = _tools._tool_create_script({"script_path": TEMP_DIR.path_join("abstract_base.gd"), "content": "@abstract\nextends RefCounted\n"})
	assert_eq(result.get("validation_status"), "passed")

func test_diagnostics_limit_keeps_error_verdict_after_warning_overflow() -> void:
	var capture: WriteDiagnostics.Capture = WriteDiagnostics.Capture.new()
	for index in range(64):
		capture._log_error("", "res://script.gd", index + 1, "warning", "", false, Logger.ERROR_TYPE_WARNING, [])
	assert_false(capture.has_errors)
	assert_false(capture.truncated)
	capture._log_error("", "res://script.gd", 65, "error", "", false, Logger.ERROR_TYPE_SCRIPT, [])
	assert_true(capture.has_errors, "Truncation must never hide a failure verdict")
	assert_true(capture.truncated)
	assert_eq(capture.entries.size(), 64, "Diagnostics remain bounded")

func test_modify_preserves_validation_opt_out() -> void:
	var path: String = _write("unchecked.gd", "extends RefCounted\n")
	var result: Dictionary = _tools._tool_modify_script({"script_path": path, "content": "func broken(\n", "validate": false})
	_handle_expected_parse_errors()
	assert_eq(result.get("validation_status"), "not_checked")
	assert_false(result.has("validation"), "The existing opt-out omits the legacy summary")
	assert_eq(FileAccess.get_file_as_string(path), "func broken(\n")

func test_modify_retains_legacy_validation_summary() -> void:
	var path: String = _write("legacy.gd", "extends RefCounted\n")
	var result: Dictionary = _tools._tool_modify_script({"script_path": path, "content": "extends RefCounted\n"})
	assert_true(result.get("validation", {}).get("valid", false))
	assert_eq(result.get("validation", {}).get("error_count"), 0)
