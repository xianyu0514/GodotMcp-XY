extends "res://addons/gut/test.gd"

func test_project_info_format():
	var result: Dictionary = {
		"project_name": "Godot MCP Native",
		"project_path": "F:/gitProjects/Godot-MCP-Native/",
		"project_version": "",
		"project_description": "",
		"main_scene": "res://TestScene.tscn"
	}
	assert_has(result, "project_name", "Should have project_name")
	assert_has(result, "project_path", "Should have project_path")
	assert_has(result, "main_scene", "Should have main_scene")

func test_project_settings_filter():
	var settings: Dictionary = {
		"application/config/name": "Godot MCP Native",
		"application/run/main_scene": "res://TestScene.tscn",
		"debug/gdscript/warnings/unused_variable": true
	}
	var filtered: Dictionary = {}
	for key in settings:
		if key.begins_with("application/"):
			filtered[key] = settings[key]
	assert_eq(filtered.size(), 2, "Should filter to application/ settings only")
	assert_false(filtered.has("debug/gdscript/warnings/unused_variable"), "Should not have debug settings")

func test_project_settings_no_filter():
	var settings: Dictionary = {
		"application/config/name": "Godot MCP Native",
		"debug/gdscript/warnings/unused_variable": true
	}
	assert_eq(settings.size(), 2, "Without filter should return all settings")

func test_resource_extensions():
	var extensions: Array = [
		".tres", ".res", ".png", ".jpg", ".jpeg", ".webp", ".svg",
		".ogg", ".wav", ".mp3", ".glb", ".gltf", ".obj",
		".tscn", ".gd", ".cfg", ".json", ".gdshader"
	]
	assert_has(extensions, ".tscn", "Should include .tscn")
	assert_has(extensions, ".gd", "Should include .gd")
	assert_has(extensions, ".png", "Should include .png")
	assert_has(extensions, ".gdshader", "Should include .gdshader")

func test_resource_path_safety():
	assert_true(MCPTypes.is_path_safe("res://icon.svg"), "res:// resource should be safe")
	assert_false(MCPTypes.is_path_safe("C:\\Windows\\icon.png"), "Windows path should be unsafe")

func test_create_resource_types():
	var valid_types: Array = ["Curve", "Gradient", "StyleBoxFlat", "Animation"]
	assert_has(valid_types, "Curve", "Should support Curve resource")
	assert_has(valid_types, "Gradient", "Should support Gradient resource")

func test_resource_uri_format():
	var uri: String = "godot://scene/list"
	assert_true(uri.begins_with("godot://"), "Resource URI should start with godot://")

func test_collect_project_autoloads_from_properties_marks_singletons_and_sorts():
	var project_tools: RefCounted = load("res://addons/godot_mcp/tools/project_tools_native.gd").new()
	var properties: Array = [
		{"name": "autoload/GameState"},
		{"name": "autoload/Bootstrap"},
		{"name": "display/window/size/viewport_width"}
	]
	var values: Dictionary = {
		"autoload/GameState": "*res://autoload/game_state.gd",
		"autoload/Bootstrap": "res://autoload/bootstrap.gd"
	}
	var orders: Dictionary = {
		"autoload/GameState": 40,
		"autoload/Bootstrap": 12
	}
	var autoloads: Array = project_tools._collect_project_autoloads_from_properties(properties, values, orders)
	assert_eq(autoloads.size(), 2, "Should collect two autoload entries")
	assert_eq(autoloads[0].name, "Bootstrap", "Should sort autoloads by project setting order")
	assert_eq(autoloads[0].path, "res://autoload/bootstrap.gd", "Should preserve non-singleton autoload path")
	assert_false(autoloads[0].is_singleton, "Non-prefixed autoload should not be marked singleton")
	assert_eq(autoloads[1].name, "GameState", "Should include singleton autoload name")
	assert_eq(autoloads[1].path, "res://autoload/game_state.gd", "Singleton autoload should strip the * prefix")
	assert_true(autoloads[1].is_singleton, "Prefixed autoload should be marked singleton")

func test_normalize_global_class_entries_preserves_metadata():
	var project_tools: RefCounted = load("res://addons/godot_mcp/tools/project_tools_native.gd").new()
	var classes: Array = [
		{
			"class": "MyRuntimeNode",
			"path": "res://scripts/my_runtime_node.gd",
			"base": "Node",
			"language": "GDScript",
			"is_tool": false,
			"is_abstract": false,
			"icon": ""
		}
	]
	var normalized: Array = project_tools._normalize_global_class_entries(classes)
	assert_eq(normalized.size(), 1, "Should normalize one global class entry")
	assert_eq(normalized[0].name, "MyRuntimeNode", "Should expose class name as name")
	assert_eq(normalized[0].path, "res://scripts/my_runtime_node.gd", "Should preserve script path")
	assert_eq(normalized[0].base, "Node", "Should preserve base type")
	assert_eq(normalized[0].language, "GDScript", "Should preserve language")
	assert_false(normalized[0].is_tool, "Should preserve tool flag")

func test_get_class_api_metadata_returns_classdb_metadata():
	var project_tools: RefCounted = load("res://addons/godot_mcp/tools/project_tools_native.gd").new()
	var result: Dictionary = project_tools._tool_get_class_api_metadata({
		"class_name": "Node",
		"filter": "process"
	})
	assert_eq(result.source, "classdb", "Engine classes should be sourced from ClassDB")
	assert_eq(result.class_name, "Node", "Should report requested class name")
	assert_eq(result.base_class, "Object", "Should report Node base class")
	assert_gt(result.methods.size(), 0, "Filtered ClassDB methods should be returned")
	assert_gt(result.properties.size(), 0, "Filtered ClassDB properties should be returned")
	assert_true(result.signals.is_empty(), "Process filter should exclude unrelated signals")
	for method in result.methods:
		assert_true(str(method.get("name", "")).to_lower().contains("process"), "Filtered methods should match filter text")

func test_get_class_api_metadata_returns_global_class_metadata_with_base_api():
	var project_tools: RefCounted = load("res://addons/godot_mcp/tools/project_tools_native.gd").new()
	var result: Dictionary = project_tools._tool_get_class_api_metadata({
		"class_name": "ProjectToolsNative",
		"include_base_api": true
	})
	var has_initialize: bool = false
	for method in result.methods:
		if method.get("name", "") == "initialize":
			has_initialize = true
			break
	assert_eq(result.source, "global_class", "Project class should be sourced from global_class metadata")
	assert_eq(result.class_name, "ProjectToolsNative", "Should report requested global class name")
	assert_eq(result.script_path, "res://addons/godot_mcp/tools/project_tools_native.gd", "Should preserve global class script path")
	assert_eq(result.base_class, "RefCounted", "Should preserve global class base type")
	assert_gt(result.methods.size(), 0, "Global class script methods should be returned")
	assert_true(has_initialize, "Should include script-defined methods")
	assert_true(result.has("base_api"), "Should include base API metadata when requested")
	assert_eq(result.base_api.get("class_name", ""), "RefCounted", "Base API should be resolved from ClassDB")

func test_get_class_api_metadata_reports_missing_class():
	var project_tools: RefCounted = load("res://addons/godot_mcp/tools/project_tools_native.gd").new()
	var result: Dictionary = project_tools._tool_get_class_api_metadata({"class_name": "DefinitelyMissingClass123"})
	assert_has(result, "error", "Missing classes should return an error payload")

# --- run_project_test async runner ---

const _EXISTING_TEST_PATH: String = "res://test/unit/test_async_job_runner.gd"

func _fake_slow_result() -> Dictionary:
	OS.delay_msec(200)
	return {"status": "passed", "framework": "fake"}

func _fake_finished_result() -> Dictionary:
	return {"status": "passed", "framework": "fake", "exit_code": 0}

func test_run_project_test_rejects_empty_path():
	var project_tools: RefCounted = load("res://addons/godot_mcp/tools/project_tools_native.gd").new()
	var result: Dictionary = project_tools._tool_run_project_test({"test_path": ""})
	assert_has(result, "error", "Empty test_path should return an error without starting a job")
	assert_eq(project_tools._test_runner.active_count(), 0, "No job is started for invalid input")

func test_run_project_test_rejects_path_outside_test_dir():
	var project_tools: RefCounted = load("res://addons/godot_mcp/tools/project_tools_native.gd").new()
	var result: Dictionary = project_tools._tool_run_project_test({"test_path": "res://addons/godot_mcp/plugin.cfg"})
	assert_has(result, "error", "A path outside res://test/ should be rejected")
	assert_eq(project_tools._test_runner.active_count(), 0, "No job is started for a rejected path")

func test_run_project_test_rejects_missing_file():
	var project_tools: RefCounted = load("res://addons/godot_mcp/tools/project_tools_native.gd").new()
	var result: Dictionary = project_tools._tool_run_project_test({"test_path": "res://test/unit/does_not_exist.gd"})
	assert_has(result, "error", "A missing test file should be rejected")
	assert_eq(project_tools._test_runner.active_count(), 0, "No job is started for a missing file")

func test_run_project_test_returns_pending_while_running():
	var project_tools: RefCounted = load("res://addons/godot_mcp/tools/project_tools_native.gd").new()
	project_tools._test_runner.start(_EXISTING_TEST_PATH, Callable(self, "_fake_slow_result"))
	var result: Dictionary = project_tools._tool_run_project_test({"test_path": _EXISTING_TEST_PATH})
	assert_eq(result.get("status"), "pending", "A running job reports pending when polled via the tool")
	assert_has(result, "elapsed_ms", "Pending status reports elapsed time")
	project_tools._test_runner.flush()

func test_run_project_test_returns_result_when_finished():
	var project_tools: RefCounted = load("res://addons/godot_mcp/tools/project_tools_native.gd").new()
	project_tools._test_runner.start(_EXISTING_TEST_PATH, Callable(self, "_fake_finished_result"))
	OS.delay_msec(250)
	var result: Dictionary = project_tools._tool_run_project_test({"test_path": _EXISTING_TEST_PATH})
	assert_eq(result.get("status"), "passed", "A finished job returns the worker result via the tool")
	assert_eq(result.get("framework"), "fake", "The worker result payload is forwarded unchanged")
	assert_false(project_tools._test_runner.has_job(_EXISTING_TEST_PATH), "The finished job is cleared after polling")

func test_run_project_test_rejects_when_too_many_jobs():
	var project_tools: RefCounted = load("res://addons/godot_mcp/tools/project_tools_native.gd").new()
	var seed_paths: Array[String] = [
		"res://test/unit/test_mcp_types.gd",
		"res://test/unit/test_path_validator.gd",
		"res://test/unit/test_config_manager.gd",
		"res://test/unit/tools/test_project_tools.gd"
	]
	for path in seed_paths:
		project_tools._test_runner.start(path, Callable(self, "_fake_slow_result"))
	assert_eq(project_tools._test_runner.active_count(), project_tools.MAX_CONCURRENT_TEST_JOBS, "Runner saturated to the concurrency cap")
	var result: Dictionary = project_tools._tool_run_project_test({"test_path": _EXISTING_TEST_PATH})
	assert_has(result, "error", "Starting another run beyond the cap is rejected")
	project_tools._test_runner.flush()

# --- run_project_tests batch async runner ---

func _batch_job_key(params: Dictionary) -> String:
	var search_path: String = str(params.get("search_path", "res://test")).strip_edges()
	if search_path.is_empty():
		search_path = "res://test"
	var framework: String = str(params.get("framework", "")).strip_edges().to_lower()
	var only_runnable: bool = bool(params.get("only_runnable", true))
	return search_path + "|" + framework + "|" + str(only_runnable)

func _fake_batch_result() -> Dictionary:
	return {"status": "passed", "total_count": 2, "passed_count": 2, "failed_count": 0}

func test_run_project_tests_starts_batch_and_returns_pending():
	var project_tools: RefCounted = load("res://addons/godot_mcp/tools/project_tools_native.gd").new()
	var params: Dictionary = {"search_path": "res://test/unit", "framework": "gut"}
	project_tools._batch_test_runner.start(_batch_job_key(params), Callable(self, "_fake_slow_result"))
	var result: Dictionary = project_tools._tool_run_project_tests(params)
	assert_eq(result.get("status"), "pending", "A running batch reports pending when polled via the tool")
	assert_has(result, "elapsed_ms", "Pending batch status reports elapsed time")
	project_tools._batch_test_runner.flush()

func test_run_project_tests_returns_result_when_finished():
	var project_tools: RefCounted = load("res://addons/godot_mcp/tools/project_tools_native.gd").new()
	var params: Dictionary = {"search_path": "res://test/unit", "framework": "gut"}
	project_tools._batch_test_runner.start(_batch_job_key(params), Callable(self, "_fake_batch_result"))
	OS.delay_msec(50)
	var result: Dictionary = project_tools._tool_run_project_tests(params)
	assert_eq(result.get("status"), "passed", "A finished batch returns the aggregated worker result via the tool")
	assert_eq(result.get("total_count"), 2, "The aggregated batch payload is forwarded unchanged")
	assert_false(project_tools._batch_test_runner.has_job(_batch_job_key(params)), "The finished batch job is cleared after polling")

func test_run_project_tests_rejects_when_too_many_batches():
	var project_tools: RefCounted = load("res://addons/godot_mcp/tools/project_tools_native.gd").new()
	for i in range(project_tools.MAX_CONCURRENT_TEST_JOBS):
		project_tools._batch_test_runner.start("batch_" + str(i), Callable(self, "_fake_slow_result"))
	assert_eq(project_tools._batch_test_runner.active_count(), project_tools.MAX_CONCURRENT_TEST_JOBS, "Batch runner saturated to the concurrency cap")
	var result: Dictionary = project_tools._tool_run_project_tests({"search_path": "res://test/unit", "framework": "gut"})
	assert_has(result, "error", "Starting another batch beyond the cap is rejected")
	project_tools._batch_test_runner.flush()

func test_single_and_batch_runs_share_one_concurrency_budget():
	var project_tools: RefCounted = load("res://addons/godot_mcp/tools/project_tools_native.gd").new()
	# Saturate the shared budget with a mix of single and batch jobs so the total,
	# not each runner independently, reaches MAX_CONCURRENT_TEST_JOBS.
	project_tools._test_runner.start("res://test/unit/test_mcp_types.gd", Callable(self, "_fake_slow_result"))
	project_tools._test_runner.start("res://test/unit/test_path_validator.gd", Callable(self, "_fake_slow_result"))
	for i in range(project_tools.MAX_CONCURRENT_TEST_JOBS - 2):
		project_tools._batch_test_runner.start("batch_" + str(i), Callable(self, "_fake_slow_result"))
	assert_eq(project_tools._active_test_job_count(), project_tools.MAX_CONCURRENT_TEST_JOBS, "Single and batch jobs together saturate the shared cap")
	var batch_result: Dictionary = project_tools._tool_run_project_tests({"search_path": "res://test/unit", "framework": "gut"})
	assert_has(batch_result, "error", "A new batch is rejected once the shared budget is full")
	var single_result: Dictionary = project_tools._tool_run_project_test({"test_path": _EXISTING_TEST_PATH})
	assert_has(single_result, "error", "A new single run is rejected once the shared budget is full")
	project_tools._test_runner.flush()
	project_tools._batch_test_runner.flush()
