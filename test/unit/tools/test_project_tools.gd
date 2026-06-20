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

# --- reverse resource tools: find_resource_usages / list_unused_resources ---

const _REVERSE_RES_DIR: String = "res://.tmp_reverse_res_test"

func _write_text_file(path: String, content: String) -> void:
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	assert_ne(file, null, "Should be able to open temp file for writing: " + path)
	file.store_string(content)
	file.close()

func _setup_reverse_resource_fixture() -> void:
	_teardown_reverse_resource_fixture()
	var dir: DirAccess = DirAccess.open("res://")
	dir.make_dir(".tmp_reverse_res_test")
	# A leaf resource referenced by a scene.
	_write_text_file(_REVERSE_RES_DIR + "/used.tres", "[gd_resource type=\"Resource\" format=3]\n\n[resource]\n")
	# A leaf resource referenced by nobody.
	_write_text_file(_REVERSE_RES_DIR + "/orphan.tres", "[gd_resource type=\"Resource\" format=3]\n\n[resource]\n")
	# A scene that references used.tres via an ext_resource path.
	var scene_text: String = "[gd_scene load_steps=2 format=3]\n\n" \
		+ "[ext_resource type=\"Resource\" path=\"" + _REVERSE_RES_DIR + "/used.tres\" id=\"1\"]\n\n" \
		+ "[node name=\"Root\" type=\"Node\"]\n"
	_write_text_file(_REVERSE_RES_DIR + "/holder.tscn", scene_text)

func _teardown_reverse_resource_fixture() -> void:
	if not DirAccess.dir_exists_absolute(_REVERSE_RES_DIR):
		return
	var dir: DirAccess = DirAccess.open(_REVERSE_RES_DIR)
	if dir:
		dir.list_dir_begin()
		var file_name: String = dir.get_next()
		while not file_name.is_empty():
			if file_name != "." and file_name != "..":
				dir.remove(file_name)
			file_name = dir.get_next()
		dir.list_dir_end()
	DirAccess.remove_absolute(_REVERSE_RES_DIR)

func test_find_resource_usages_rejects_missing_param():
	var project_tools: RefCounted = load("res://addons/godot_mcp/tools/project_tools_native.gd").new()
	var result: Dictionary = project_tools._tool_find_resource_usages({})
	assert_has(result, "error", "Missing resource_path should return an error")

func test_find_resource_usages_rejects_missing_file():
	var project_tools: RefCounted = load("res://addons/godot_mcp/tools/project_tools_native.gd").new()
	var result: Dictionary = project_tools._tool_find_resource_usages({"resource_path": "res://.tmp_reverse_res_test/does_not_exist.tres"})
	assert_has(result, "error", "A missing target file should be rejected")

func test_find_resource_usages_reports_owner_scene():
	_setup_reverse_resource_fixture()
	var project_tools: RefCounted = load("res://addons/godot_mcp/tools/project_tools_native.gd").new()
	var result: Dictionary = project_tools._tool_find_resource_usages({
		"resource_path": _REVERSE_RES_DIR + "/used.tres",
		"search_path": _REVERSE_RES_DIR
	})
	assert_false(result.has("error"), "A valid reverse lookup should not error")
	assert_eq(int(result.get("usage_count", 0)), 1, "used.tres should be referenced by exactly one resource")
	var owners: Array = []
	for usage in result.get("usages", []):
		owners.append(str(usage.get("owner_path", "")))
	assert_has(owners, _REVERSE_RES_DIR + "/holder.tscn", "holder.tscn should be reported as a referencing owner")
	_teardown_reverse_resource_fixture()

func test_find_resource_usages_reports_no_usages_for_orphan():
	_setup_reverse_resource_fixture()
	var project_tools: RefCounted = load("res://addons/godot_mcp/tools/project_tools_native.gd").new()
	var result: Dictionary = project_tools._tool_find_resource_usages({
		"resource_path": _REVERSE_RES_DIR + "/orphan.tres",
		"search_path": _REVERSE_RES_DIR
	})
	assert_false(result.has("error"), "A valid reverse lookup should not error")
	assert_eq(int(result.get("usage_count", 0)), 0, "orphan.tres should have no referencing resources")
	_teardown_reverse_resource_fixture()

func test_list_unused_resources_flags_orphan_and_skips_referenced():
	_setup_reverse_resource_fixture()
	var project_tools: RefCounted = load("res://addons/godot_mcp/tools/project_tools_native.gd").new()
	var result: Dictionary = project_tools._tool_list_unused_resources({"search_path": _REVERSE_RES_DIR})
	assert_false(result.has("error"), "A valid unused-resource scan should not error")
	var unused: Array = result.get("unused_resources", [])
	assert_has(unused, _REVERSE_RES_DIR + "/orphan.tres", "orphan.tres should be flagged as unused")
	assert_false(unused.has(_REVERSE_RES_DIR + "/used.tres"), "used.tres is referenced and should not be flagged")
	_teardown_reverse_resource_fixture()

func test_list_unused_resources_rejects_invalid_path():
	var project_tools: RefCounted = load("res://addons/godot_mcp/tools/project_tools_native.gd").new()
	var result: Dictionary = project_tools._tool_list_unused_resources({"search_path": "C:\\Windows"})
	assert_has(result, "error", "An unsafe directory path should be rejected")

func test_resolve_resource_root_path_strips_prefix_and_resolves_uid():
	var project_tools: RefCounted = load("res://addons/godot_mcp/tools/project_tools_native.gd").new()
	assert_eq(project_tools._resolve_resource_root_path("res://scenes/main.tscn"), "res://scenes/main.tscn", "Plain res:// path should pass through")
	assert_eq(project_tools._resolve_resource_root_path("*res://autoload/game.gd"), "res://autoload/game.gd", "Leading autoload '*' should be stripped")
	assert_eq(project_tools._resolve_resource_root_path(""), "", "Empty value resolves to empty")
	var uid_id: int = ResourceUID.create_id()
	ResourceUID.add_id(uid_id, "res://scenes/world.tscn")
	var uid_text: String = ResourceUID.id_to_text(uid_id)
	assert_eq(project_tools._resolve_resource_root_path("*" + uid_text), "res://scenes/world.tscn", "uid:// entry point should resolve to its res:// path")
	ResourceUID.remove_id(uid_id)

# --- migration assistant: scan_migration_compatibility / apply_migration_fixes ---

const _MIGRATION_DIR: String = "res://.tmp_migration_test"

func _setup_migration_fixture() -> void:
	_teardown_migration_fixture()
	var dir: DirAccess = DirAccess.open("res://")
	dir.make_dir(".tmp_migration_test")
	var src: String = "extends Node\n" \
		+ "func _ready() -> void:\n" \
		+ "\tvar mask = UPDATE_WIDTH_IN_PERCENT\n" \
		+ "\tvar pos = analyzer.tap_back_pos\n" \
		+ "\tvar override_flag = audio_bus_override\n"
	_write_text_file(_MIGRATION_DIR + "/mig_a.gd", src)

func _teardown_migration_fixture() -> void:
	if not DirAccess.dir_exists_absolute(_MIGRATION_DIR):
		return
	var dir: DirAccess = DirAccess.open(_MIGRATION_DIR)
	if dir:
		dir.list_dir_begin()
		var file_name: String = dir.get_next()
		while not file_name.is_empty():
			if file_name != "." and file_name != "..":
				dir.remove(file_name)
			file_name = dir.get_next()
		dir.list_dir_end()
	DirAccess.remove_absolute(_MIGRATION_DIR)

func test_scan_migration_rejects_unsupported_version():
	var project_tools: RefCounted = load("res://addons/godot_mcp/tools/project_tools_native.gd").new()
	var result: Dictionary = project_tools._tool_scan_migration_compatibility({"target_version": "9.9"})
	assert_has(result, "error", "Unsupported target_version should return an error")

func test_scan_migration_flags_must_fix_and_behavior():
	_setup_migration_fixture()
	var project_tools: RefCounted = load("res://addons/godot_mcp/tools/project_tools_native.gd").new()
	var result: Dictionary = project_tools._tool_scan_migration_compatibility({"search_path": _MIGRATION_DIR, "include_behavior": true})
	assert_false(result.has("error"), "A valid scan should not error")
	assert_eq(int(result.get("must_fix_count", 0)), 2, "Should flag the enum rename and the removed member as must_fix")
	assert_true(int(result.get("review_count", 0)) >= 1, "audio_bus_override should be flagged for review")
	var rule_ids: Array = []
	for issue in result.get("issues", []):
		rule_ids.append(str(issue.get("rule_id", "")))
	assert_has(rule_ids, "rtl_image_update_mask_rename", "Enum rename rule should fire")
	assert_has(rule_ids, "audio_spectrum_tap_back_pos_removed", "Removed-member rule should fire")
	_teardown_migration_fixture()

func test_scan_migration_excludes_behavior_when_disabled():
	_setup_migration_fixture()
	var project_tools: RefCounted = load("res://addons/godot_mcp/tools/project_tools_native.gd").new()
	var result: Dictionary = project_tools._tool_scan_migration_compatibility({"search_path": _MIGRATION_DIR, "include_behavior": false})
	assert_false(result.has("error"), "A valid scan should not error")
	assert_eq(int(result.get("review_count", 0)), 0, "Behavior issues should be excluded when include_behavior is false")
	assert_eq(int(result.get("must_fix_count", 0)), 2, "Must-fix issues should still be reported")
	_teardown_migration_fixture()

func test_apply_migration_fixes_dry_run_does_not_write():
	_setup_migration_fixture()
	var project_tools: RefCounted = load("res://addons/godot_mcp/tools/project_tools_native.gd").new()
	var result: Dictionary = project_tools._tool_apply_migration_fixes({"search_path": _MIGRATION_DIR, "dry_run": true})
	assert_false(result.has("error"), "A valid dry-run should not error")
	assert_true(bool(result.get("dry_run", false)), "Result should report dry_run true")
	assert_eq(int(result.get("change_count", 0)), 1, "Only the auto-fixable enum rename should be a proposed change")
	var content: String = FileAccess.get_file_as_string(_MIGRATION_DIR + "/mig_a.gd")
	assert_true(content.contains("UPDATE_WIDTH_IN_PERCENT"), "Dry run must not modify the file on disk")
	_teardown_migration_fixture()

func test_apply_migration_fixes_writes_enum_rename():
	_setup_migration_fixture()
	var project_tools: RefCounted = load("res://addons/godot_mcp/tools/project_tools_native.gd").new()
	var result: Dictionary = project_tools._tool_apply_migration_fixes({"search_path": _MIGRATION_DIR, "dry_run": false})
	assert_false(result.has("error"), "A valid apply should not error")
	assert_eq(int(result.get("change_count", 0)), 1, "Should apply exactly one rewrite")
	var content: String = FileAccess.get_file_as_string(_MIGRATION_DIR + "/mig_a.gd")
	assert_false(content.contains("UPDATE_WIDTH_IN_PERCENT"), "Old enum name should be gone after apply")
	assert_true(content.contains("UPDATE_WIDTH_UNIT"), "New enum name should be present after apply")
	_teardown_migration_fixture()

func test_apply_migration_fixes_respects_rule_id_filter():
	_setup_migration_fixture()
	var project_tools: RefCounted = load("res://addons/godot_mcp/tools/project_tools_native.gd").new()
	var result: Dictionary = project_tools._tool_apply_migration_fixes({"search_path": _MIGRATION_DIR, "dry_run": true, "rule_ids": ["audio_spectrum_tap_back_pos_removed"]})
	assert_has(result, "error", "Selecting only a non-auto-fixable rule should yield no applicable fixes")
	_teardown_migration_fixture()

func test_scan_migration_excludes_plugin_own_source():
	var project_tools: RefCounted = load("res://addons/godot_mcp/tools/project_tools_native.gd").new()
	var result: Dictionary = project_tools._tool_scan_migration_compatibility({"search_path": "res://addons/godot_mcp"})
	assert_false(result.has("error"), "Scanning the plugin directory should not error")
	assert_eq(int(result.get("scanned_files", -1)), 0, "Plugin's own source must be excluded so its rule strings are not self-flagged")
	assert_eq(int(result.get("total_count", -1)), 0, "No migration issues should be reported from the plugin's own rule definitions")

const _HYGIENE_DIR: String = "res://.tmp_hygiene_test"

func _setup_hygiene_fixture() -> void:
	_teardown_hygiene_fixture()
	var dir: DirAccess = DirAccess.open("res://")
	dir.make_dir(".tmp_hygiene_test")
	var legacy_script: String = "extends Reference\n\nfunc _ready():\n\tvar names = PoolStringArray()\n\tif names.empty():\n\t\tprint(\"empty\")\n\tvar scene = preload(\"x\").instance()\n\t# yield(get_tree(), \"idle_frame\") is a comment and must be ignored\n"
	_write_text_file(_HYGIENE_DIR + "/legacy.gd", legacy_script)
	var modern_script: String = "extends RefCounted\n\nfunc _ready():\n\tvar names = PackedStringArray()\n\tif names.is_empty():\n\t\tprint(\"empty\")\n"
	_write_text_file(_HYGIENE_DIR + "/modern.gd", modern_script)
	var gdext: String = "[configuration]\nentry_symbol = \"my_extension_init\"\ncompatibility_minimum = \"4.2\"\n\n[libraries]\nlinux.x86_64 = \"res://.tmp_hygiene_test/bin/libmy.so\"\nwindows.x86_64 = \"res://.tmp_hygiene_test/bin/my.dll\"\n"
	_write_text_file(_HYGIENE_DIR + "/my.gdextension", gdext)

func _teardown_hygiene_fixture() -> void:
	if not DirAccess.dir_exists_absolute(_HYGIENE_DIR):
		return
	var dir: DirAccess = DirAccess.open(_HYGIENE_DIR)
	if dir:
		dir.list_dir_begin()
		var file_name: String = dir.get_next()
		while not file_name.is_empty():
			if file_name != "." and file_name != "..":
				dir.remove(file_name)
			file_name = dir.get_next()
		dir.list_dir_end()
	DirAccess.remove_absolute(_HYGIENE_DIR)

func test_find_deprecated_api_usage_rejects_invalid_path():
	var project_tools: RefCounted = load("res://addons/godot_mcp/tools/project_tools_native.gd").new()
	var result: Dictionary = project_tools._tool_find_deprecated_api_usage({"search_path": "C:\\Windows"})
	assert_has(result, "error", "An unsafe directory path should be rejected")

func test_find_deprecated_api_usage_flags_legacy_and_skips_modern():
	_setup_hygiene_fixture()
	var project_tools: RefCounted = load("res://addons/godot_mcp/tools/project_tools_native.gd").new()
	var result: Dictionary = project_tools._tool_find_deprecated_api_usage({"search_path": _HYGIENE_DIR, "languages": ["gd"]})
	assert_false(result.has("error"), "A valid scan should not error")
	var rule_ids: Array = []
	var files_flagged: Array = []
	for finding in result.get("findings", []):
		rule_ids.append(str(finding.get("rule_id", "")))
		files_flagged.append(str(finding.get("file", "")))
	assert_has(rule_ids, "reference_class", "extends Reference should be flagged")
	assert_has(rule_ids, "pooled_arrays", "PoolStringArray should be flagged")
	assert_has(rule_ids, "empty_method", ".empty() should be flagged")
	assert_has(rule_ids, "instance_method", ".instance() should be flagged")
	assert_false(rule_ids.has("yield_keyword"), "yield() inside a comment line should be ignored")
	assert_false(files_flagged.has(_HYGIENE_DIR + "/modern.gd"), "The modern script should produce no findings")
	_teardown_hygiene_fixture()

func test_find_deprecated_api_usage_enriches_with_classdb():
	_setup_hygiene_fixture()
	var project_tools: RefCounted = load("res://addons/godot_mcp/tools/project_tools_native.gd").new()
	var result: Dictionary = project_tools._tool_find_deprecated_api_usage({"search_path": _HYGIENE_DIR, "languages": ["gd"]})
	var checked: bool = false
	for finding in result.get("findings", []):
		if str(finding.get("rule_id", "")) == "reference_class":
			assert_eq(bool(finding.get("present_in_engine", true)), false, "Reference class should be gone from the current engine")
			assert_eq(bool(finding.get("replacement_available", false)), true, "RefCounted replacement should exist in the engine")
			checked = true
	assert_true(checked, "The reference_class finding should be present and ClassDB-enriched")
	_teardown_hygiene_fixture()

func test_detect_gdextension_addons_rejects_invalid_path():
	var project_tools: RefCounted = load("res://addons/godot_mcp/tools/project_tools_native.gd").new()
	var result: Dictionary = project_tools._tool_detect_gdextension_addons({"search_path": "C:\\Windows"})
	assert_has(result, "error", "An unsafe directory path should be rejected")

func test_detect_gdextension_addons_reports_libraries_and_missing():
	_setup_hygiene_fixture()
	var project_tools: RefCounted = load("res://addons/godot_mcp/tools/project_tools_native.gd").new()
	var result: Dictionary = project_tools._tool_detect_gdextension_addons({"search_path": _HYGIENE_DIR})
	assert_false(result.has("error"), "A valid detection scan should not error")
	assert_true(bool(result.get("has_native_extensions", false)), "The .gdextension fixture should be detected")
	assert_eq(int(result.get("extension_count", 0)), 1, "Exactly one extension should be found")
	var extension: Dictionary = result.get("extensions", [])[0]
	assert_eq(str(extension.get("entry_symbol", "")), "my_extension_init", "entry_symbol should be parsed")
	assert_eq(str(extension.get("compatibility_minimum", "")), "4.2", "compatibility_minimum should be parsed")
	assert_eq(int(extension.get("library_count", 0)), 2, "Two library targets should be parsed")
	assert_eq(int(extension.get("missing_library_count", 0)), 2, "Both library binaries are absent in the fixture")
	assert_false(bool(extension.get("all_libraries_present", true)), "Missing binaries means not all libraries are present")
	_teardown_hygiene_fixture()

func test_detect_gdextension_addons_empty_when_none():
	var project_tools: RefCounted = load("res://addons/godot_mcp/tools/project_tools_native.gd").new()
	var result: Dictionary = project_tools._tool_detect_gdextension_addons({"search_path": _REVERSE_RES_DIR})
	assert_false(result.has("error"), "Scanning a directory without extensions should not error")
	assert_false(bool(result.get("has_native_extensions", true)), "No extensions should be reported for a plain directory")

# --- create_gradient_texture ---

func test_create_gradient_texture_missing_path():
	var project_tools: RefCounted = load("res://addons/godot_mcp/tools/project_tools_native.gd").new()
	var result: Dictionary = project_tools._tool_create_gradient_texture({})
	assert_has(result, "error", "Missing resource_path should return error")

func test_create_gradient_texture_invalid_fill():
	var project_tools: RefCounted = load("res://addons/godot_mcp/tools/project_tools_native.gd").new()
	var result: Dictionary = project_tools._tool_create_gradient_texture({"resource_path": "res://.tmp_grad.tres", "fill": "bogus"})
	assert_has(result, "error", "An invalid fill mode should be rejected")

func test_create_gradient_texture_linear_saves():
	var out_path: String = "res://.tmp_grad_linear.tres"
	var project_tools: RefCounted = load("res://addons/godot_mcp/tools/project_tools_native.gd").new()
	var result: Dictionary = project_tools._tool_create_gradient_texture({
		"resource_path": out_path,
		"fill": "linear",
		"colors": ["#ff0000", "#0000ff"],
		"width": 32,
		"height": 8
	})
	assert_eq(result.get("status", ""), "success", "A linear gradient texture should save")
	assert_eq(int(result.get("stop_count", 0)), 2, "Two color stops should be recorded")
	assert_true(FileAccess.file_exists(out_path), "The texture file should exist on disk")
	var loaded = load(out_path)
	assert_true(loaded is GradientTexture2D, "The saved resource should be a GradientTexture2D")
	DirAccess.remove_absolute(out_path)

func test_create_gradient_texture_conic_guarded():
	var out_path: String = "res://.tmp_grad_conic.tres"
	var project_tools: RefCounted = load("res://addons/godot_mcp/tools/project_tools_native.gd").new()
	var result: Dictionary = project_tools._tool_create_gradient_texture({
		"resource_path": out_path,
		"fill": "conic"
	})
	var conic_available: bool = "FILL_CONIC" in ClassDB.class_get_integer_constant_list("GradientTexture2D", false)
	if conic_available:
		assert_eq(result.get("status", ""), "success", "Conic fill should save on Godot 4.7")
		assert_eq(int(result.get("fill_mode_value", -1)), 3, "Conic maps to fill value 3")
		if FileAccess.file_exists(out_path):
			DirAccess.remove_absolute(out_path)
	else:
		assert_eq(result.get("status", ""), "unsupported", "Conic fill should be unsupported on older Godot")

# --- pack_pck ---

func test_pack_pck_missing_params():
	var project_tools: RefCounted = load("res://addons/godot_mcp/tools/project_tools_native.gd").new()
	var result: Dictionary = project_tools._tool_pack_pck({"pck_path": "res://.tmp_out.pck"})
	assert_has(result, "error", "Missing files array should return error")

func test_pack_pck_packs_existing_file():
	var src_path: String = "res://.tmp_pack_src.txt"
	var pck_path: String = "res://.tmp_pack_out.pck"
	_write_text_file(src_path, "hello pck")
	var project_tools: RefCounted = load("res://addons/godot_mcp/tools/project_tools_native.gd").new()
	var result: Dictionary = project_tools._tool_pack_pck({
		"pck_path": pck_path,
		"files": [{"target_path": "res://data/hello.txt", "source_path": src_path}]
	})
	assert_eq(result.get("status", ""), "success", "Packing an existing file should succeed")
	assert_eq(int(result.get("packed_count", 0)), 1, "Exactly one file should be packed")
	assert_true(FileAccess.file_exists(pck_path), "The .pck file should be created")
	DirAccess.remove_absolute(src_path)
	DirAccess.remove_absolute(pck_path)

func test_pack_pck_skips_missing_source():
	var pck_path: String = "res://.tmp_pack_missing.pck"
	var project_tools: RefCounted = load("res://addons/godot_mcp/tools/project_tools_native.gd").new()
	var result: Dictionary = project_tools._tool_pack_pck({
		"pck_path": pck_path,
		"files": ["res://does_not_exist_12345.txt"]
	})
	assert_has(result, "error", "Packing only missing sources yields no packed files and errors")
	if FileAccess.file_exists(pck_path):
		DirAccess.remove_absolute(pck_path)

# --- configure_render_output ---

func test_configure_render_output_requires_a_setting():
	var project_tools: RefCounted = load("res://addons/godot_mcp/tools/project_tools_native.gd").new()
	var result: Dictionary = project_tools._tool_configure_render_output({"persist": false})
	assert_has(result, "error", "Calling with no settings should error")

func test_configure_render_output_sets_hdr_2d():
	var key: String = "rendering/viewport/hdr_2d"
	var had_setting: bool = ProjectSettings.has_setting(key)
	var original: Variant = ProjectSettings.get_setting(key) if had_setting else null
	var project_tools: RefCounted = load("res://addons/godot_mcp/tools/project_tools_native.gd").new()
	var result: Dictionary = project_tools._tool_configure_render_output({"hdr_2d": true, "persist": false})
	assert_eq(result.get("status", ""), "success", "Configuring render output should succeed")
	var change_status: String = ""
	for change in result.get("changes", []):
		if str(change.get("setting", "")) == key:
			change_status = str(change.get("status", ""))
	if had_setting:
		assert_eq(change_status, "updated", "hdr_2d should be updated when the setting exists")
		assert_false(bool(result.get("persisted", true)), "persist=false should not persist to disk")
		ProjectSettings.set_setting(key, original)
	else:
		assert_eq(change_status, "unsupported", "hdr_2d should be unsupported when the setting is absent")

# --- create_drawable_texture / draw_on_texture (Godot 4.7) ---

func test_create_drawable_texture_missing_path():
	var project_tools: RefCounted = load("res://addons/godot_mcp/tools/project_tools_native.gd").new()
	var result: Dictionary = project_tools._tool_create_drawable_texture({})
	assert_has(result, "error", "Missing resource_path should return error")

func test_create_drawable_texture_create_guarded():
	var out_path: String = "res://.tmp_drawable.tres"
	var project_tools: RefCounted = load("res://addons/godot_mcp/tools/project_tools_native.gd").new()
	var result: Dictionary = project_tools._tool_create_drawable_texture({
		"resource_path": out_path,
		"width": 32,
		"height": 16,
		"format": "rgba8",
		"color": {"r": 0.0, "g": 0.0, "b": 0.0, "a": 1.0}
	})
	if ClassDB.class_exists("DrawableTexture2D"):
		assert_eq(result.get("status", ""), "success", "DrawableTexture2D should be created on Godot 4.7")
		assert_eq(int(result.get("format_value", -1)), 0, "rgba8 maps to format value 0")
		assert_true(FileAccess.file_exists(out_path), "The texture file should exist on disk")
		var loaded = load(out_path)
		assert_eq(loaded.get_class() if loaded else "", "DrawableTexture2D", "The saved resource should be a DrawableTexture2D")
		DirAccess.remove_absolute(out_path)
	else:
		assert_eq(result.get("status", ""), "unsupported", "DrawableTexture2D should be unsupported on older Godot")

func test_create_drawable_texture_invalid_format_guarded():
	var project_tools: RefCounted = load("res://addons/godot_mcp/tools/project_tools_native.gd").new()
	var result: Dictionary = project_tools._tool_create_drawable_texture({
		"resource_path": "res://.tmp_drawable_bad.tres",
		"format": "bogus"
	})
	if ClassDB.class_exists("DrawableTexture2D"):
		assert_has(result, "error", "An invalid format should be rejected on Godot 4.7")
	else:
		assert_eq(result.get("status", ""), "unsupported", "DrawableTexture2D should be unsupported on older Godot")

func test_draw_on_texture_missing_path():
	var project_tools: RefCounted = load("res://addons/godot_mcp/tools/project_tools_native.gd").new()
	var result: Dictionary = project_tools._tool_draw_on_texture({})
	assert_has(result, "error", "Missing resource_path should return error")

func test_draw_on_texture_blit_guarded():
	var project_tools: RefCounted = load("res://addons/godot_mcp/tools/project_tools_native.gd").new()
	if not ClassDB.class_exists("DrawableTexture2D"):
		var unsupported: Dictionary = project_tools._tool_draw_on_texture({
			"resource_path": "res://.tmp_missing_drawable.tres",
			"operations": [{"source_path": "res://.tmp_src.tres"}]
		})
		assert_eq(unsupported.get("status", ""), "unsupported", "draw_on_texture should be unsupported on older Godot")
		return

	var tex_path: String = "res://.tmp_draw_target.tres"
	var src_path: String = "res://.tmp_draw_source.tres"
	var created: Dictionary = project_tools._tool_create_drawable_texture({
		"resource_path": tex_path,
		"width": 32,
		"height": 32
	})
	assert_eq(created.get("status", ""), "success", "Setup: drawable texture should be created")

	var img: Image = Image.create(8, 8, false, Image.FORMAT_RGBA8)
	img.fill(Color(1, 1, 1, 1))
	var src: ImageTexture = ImageTexture.create_from_image(img)
	ResourceSaver.save(src, src_path)

	var result: Dictionary = project_tools._tool_draw_on_texture({
		"resource_path": tex_path,
		"operations": [
			{"source_path": src_path, "rect": {"x": 4, "y": 4, "w": 8, "h": 8}, "modulate": {"r": 1.0, "g": 0.0, "b": 0.0, "a": 1.0}},
			{"source_path": "res://does_not_exist_98765.tres"}
		]
	})
	assert_eq(result.get("status", ""), "success", "draw_on_texture should succeed when at least one op applies")
	assert_eq(int(result.get("applied_count", 0)), 1, "Exactly one valid blit should be applied")
	assert_eq(int(result.get("skipped", []).size()), 1, "The missing source should be skipped")

	DirAccess.remove_absolute(tex_path)
	DirAccess.remove_absolute(src_path)
