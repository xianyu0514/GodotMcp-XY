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
