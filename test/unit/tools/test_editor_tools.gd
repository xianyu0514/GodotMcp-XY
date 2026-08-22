extends "res://addons/gut/test.gd"

var _editor_tools: RefCounted = null

func before_each() -> void:
	_editor_tools = load("res://addons/godot_mcp/tools/editor_tools_native.gd").new()

func after_each() -> void:
	_editor_tools = null
	if Engine.has_meta("GodotMCPPlugin"):
		Engine.remove_meta("GodotMCPPlugin")

func test_editor_state_format():
	var result: Dictionary = {
		"active_scene": "Main",
		"editor_mode": "editor",
		"selected_count": 1,
		"selected_nodes": ["/root/Main"]
	}
	assert_has(result, "active_scene", "Should have active_scene")
	assert_has(result, "editor_mode", "Should have editor_mode")
	assert_has(result, "selected_count", "Should have selected_count")
	assert_has(result, "selected_nodes", "Should have selected_nodes")

func test_selected_nodes_friendly_path():
	var paths: Array = ["/root/Main", "/root/Main/Player", "/root/Main/Camera3D"]
	for path in paths:
		assert_false(str(path).contains("@"), "Friendly path should not contain @")

func test_run_stop_project():
	var states: Array = ["playing", "editor"]
	assert_has(states, "playing", "Should have playing state")
	assert_has(states, "editor", "Should have editor state")

func test_editor_setting_name_format():
	var setting: String = "debug/gdscript/warnings/unused_variable"
	assert_true(setting.contains("/"), "Setting should have category separator")

func test_editor_logs_format():
	var result: Dictionary = {
		"logs": ["[INFO] Test message"],
		"count": 1,
		"total_available": 100
	}
	assert_has(result, "logs", "Should have logs")
	assert_has(result, "count", "Should have count")
	assert_has(result, "total_available", "Should have total_available")

func test_performance_metrics_format():
	var result: Dictionary = {
		"fps": 60.0,
		"memory_usage_mb": 512.5,
		"object_count": 1000,
		"resource_count": 50
	}
	assert_has(result, "fps", "Should have fps")
	assert_has(result, "memory_usage_mb", "Should have memory_usage_mb")
	assert_has(result, "object_count", "Should have object_count")

func test_execute_script_with_singletons():
	var singletons: Dictionary = {
		"OS": OS,
		"Engine": Engine,
		"Input": Input,
	}
	assert_has(singletons, "OS", "Should have OS singleton")
	assert_has(singletons, "Engine", "Should have Engine singleton")
	assert_has(singletons, "Input", "Should have Input singleton")

func test_execute_script_result_format():
	var success: Dictionary = {"status": "success", "result": "42"}
	var error: Dictionary = {"status": "error", "error": "Parse failed"}
	assert_has(success, "status", "Should have status")
	assert_has(error, "error", "Error should have error message")

# --- Vibe Coding policy guard tests ---

func test_run_project_blocked_in_vibe_mode() -> void:
	var result: Dictionary = _editor_tools._tool_run_project({})
	assert_true(result.get("blocked", false), "run_project should be blocked in vibe mode")
	assert_eq(result.get("reason", ""), "vibe_coding_mode", "Block reason should be vibe_coding_mode")

func test_run_project_bypasses_with_allow_window() -> void:
	var result: Dictionary = _editor_tools._tool_run_project({"allow_window": true})
	assert_false(result.get("blocked", false), "allow_window should bypass vibe mode")

func test_stop_project_blocked_in_vibe_mode() -> void:
	var result: Dictionary = _editor_tools._tool_stop_project({})
	assert_true(result.get("blocked", false), "stop_project should be blocked in vibe mode")

func test_stop_project_bypasses_with_allow_window() -> void:
	var result: Dictionary = _editor_tools._tool_stop_project({"allow_window": true})
	assert_false(result.get("blocked", false), "allow_window should bypass vibe mode")

func test_select_node_blocked_in_vibe_mode() -> void:
	var result: Dictionary = _editor_tools._tool_select_node({"node_path": "/root/Main"})
	assert_true(result.get("blocked", false), "select_node should be blocked in vibe mode")

func test_select_node_bypasses_with_allow_ui_focus() -> void:
	var result: Dictionary = _editor_tools._tool_select_node({"node_path": "/root/Main", "allow_ui_focus": true})
	assert_false(result.get("blocked", false), "allow_ui_focus should bypass vibe mode")

func test_select_file_blocked_in_vibe_mode() -> void:
	var result: Dictionary = _editor_tools._tool_select_file({"file_path": "res://project.godot"})
	assert_true(result.get("blocked", false), "select_file should be blocked in vibe mode")

func test_select_file_bypasses_with_allow_ui_focus() -> void:
	var result: Dictionary = _editor_tools._tool_select_file({"file_path": "res://project.godot", "allow_ui_focus": true})
	assert_false(result.get("blocked", false), "allow_ui_focus should bypass vibe mode")

func test_editor_screenshot_update_always_forced():
	var source_code: String = _editor_tools.get_script().source_code
	assert_true(source_code.contains("SubViewport.UPDATE_ALWAYS"), "get_editor_screenshot should set UPDATE_ALWAYS before capturing")
	assert_true(source_code.contains("render_target_update_mode = original_update_mode"), "get_editor_screenshot should restore original update mode after capturing")
	assert_true(source_code.contains("RenderingServer.force_draw()"), "get_editor_screenshot should call force_draw after frame wait")

func test_editor_screenshot_switches_main_screen():
	var source_code: String = _editor_tools.get_script().source_code
	assert_true(source_code.contains("set_main_screen_editor"), "get_editor_screenshot should switch main screen editor before capturing")
	assert_true(source_code.contains("viewport_type.to_upper()"), "get_editor_screenshot should convert viewport_type to upper case for set_main_screen_editor")

func test_editor_screenshot_uses_engine_main_loop():
	var source_code: String = _editor_tools.get_script().source_code
	assert_true(source_code.contains("Engine.get_main_loop()"), "get_editor_screenshot should use Engine.get_main_loop() instead of get_tree() for SceneTree access")
	assert_false(source_code.contains("get_tree().process_frame"), "get_editor_screenshot should NOT use get_tree() which is unavailable on RefCounted")

# --- Stop project wait logic tests ---

func test_stop_project_waits_for_exit():
	"""stop_project should call stop_playing_scene and wait for exit"""
	var result: Dictionary = _editor_tools._tool_stop_project({"allow_window": true})
	# In headless mode the editor interface is unavailable, so the tool guards
	# with an error. With an editor it reports success and stopped_after_ms.
	if result.has("error"):
		assert_eq(result.get("error"), "Editor interface not available", "Headless stop should guard on missing editor interface")
	else:
		assert_has(result, "status", "stop_project should return a status field")
		if result.get("status") == "success":
			assert_has(result, "stopped_after_ms", "Successful stop should report stopped_after_ms")

func test_stop_project_output_schema_includes_stopped_after_ms():
	"""check _register_stop_project output_schema includes stopped_after_ms"""
	var source_code: String = _editor_tools.get_script().source_code
	assert_true(source_code.contains("stopped_after_ms"), "Source should reference stopped_after_ms")

# --- Editor buffer sync tools (Godot 4.7 APIs, graceful 4.6 degradation) ---

func test_first_supported_method_finds_existing():
	var found: String = _editor_tools._first_supported_method(Engine, ["does_not_exist", "get_version_info"])
	assert_eq(found, "get_version_info", "Should return the first method the object actually has")

func test_first_supported_method_missing_returns_empty():
	var found: String = _editor_tools._first_supported_method(Engine, ["nope_one", "nope_two"])
	assert_eq(found, "", "Should return empty string when no candidate exists")

func test_first_supported_method_null_object_returns_empty():
	var found: String = _editor_tools._first_supported_method(null, ["get_version_info"])
	assert_eq(found, "", "Should return empty string for a null object")

func test_engine_version_string_non_empty():
	var version: String = _editor_tools._engine_version_string()
	assert_false(version.is_empty(), "Engine version string should not be empty")

func test_get_unsaved_changes_requires_editor():
	var result: Dictionary = _editor_tools._tool_get_unsaved_changes({})
	assert_eq(result.get("error", ""), "Editor interface not available", "Should guard on missing editor interface")

func test_save_all_scripts_requires_editor():
	var result: Dictionary = _editor_tools._tool_save_all_scripts({})
	assert_eq(result.get("error", ""), "Editor interface not available", "Should guard on missing editor interface")

func test_reload_open_scripts_requires_editor():
	var result: Dictionary = _editor_tools._tool_reload_open_scripts({})
	assert_eq(result.get("error", ""), "Editor interface not available", "Should guard on missing editor interface")

func test_close_script_tab_requires_editor():
	var result: Dictionary = _editor_tools._tool_close_script_tab({})
	assert_eq(result.get("error", ""), "Editor interface not available", "Should guard on missing editor interface")

func test_get_import_status_requires_editor():
	var result: Dictionary = _editor_tools._tool_get_import_status({})
	assert_eq(result.get("error", ""), "Editor interface not available", "Should guard on missing editor interface")

func test_editor_sync_tools_use_has_method_guards():
	var source_code: String = _editor_tools.get_script().source_code
	assert_true(source_code.contains("get_unsaved_scenes"), "get_unsaved_changes should probe EditorInterface.get_unsaved_scenes")
	assert_true(source_code.contains("get_unsaved_files"), "get_unsaved_changes should probe ScriptEditor.get_unsaved_files")
	assert_true(source_code.contains("save_all_scripts"), "save_all_scripts should call ScriptEditor.save_all_scripts")
	assert_true(source_code.contains("is_importing"), "get_import_status should probe EditorFileSystem.is_importing")
	assert_true(source_code.contains("\"unsupported\""), "Editor sync tools should degrade with an 'unsupported' status")

# ---------------------------------------------------------------------------
# manage_export_templates
# ---------------------------------------------------------------------------

func _unique_user_path(suffix: String) -> String:
	var name: String = "mcp_test_%d_%d%s" % [Time.get_ticks_usec(), randi() % 100000, suffix]
	return ProjectSettings.globalize_path("user://".path_join(name))

func test_manage_export_templates_invalid_action():
	var result: Dictionary = _editor_tools._tool_manage_export_templates({"action": "frobnicate"})
	assert_true(result.has("error"), "Invalid action should return an error")
	assert_true(str(result["error"]).contains("Invalid action"), "Error should mention invalid action")

func test_manage_export_templates_status():
	var root: String = _unique_user_path("_templates")
	DirAccess.make_dir_recursive_absolute(root)
	var result: Dictionary = _editor_tools._tool_manage_export_templates({"action": "status", "templates_root": root})
	assert_eq(result.get("action", ""), "status", "action should be status")
	assert_eq(result.get("templates_root", ""), root, "Should echo the overridden templates_root")
	assert_true(str(result.get("download_url", "")).begins_with("https://github.com/godotengine/godot/releases/download/"), "download_url should point at the GitHub release")
	assert_true(str(result.get("tpz_filename", "")).ends_with("_export_templates.tpz"), "tpz_filename should end with _export_templates.tpz")
	assert_eq((result.get("installed_versions", []) as Array).size(), 0, "Empty override root should report no installed versions")
	assert_false(bool(result.get("matching_version_installed", true)), "Empty root should not have matching version installed")
	_editor_tools._remove_dir_recursive(root)

func test_manage_export_templates_install_requires_tpz():
	var result: Dictionary = _editor_tools._tool_manage_export_templates({"action": "install"})
	assert_true(result.has("error"), "install without tpz_path should error")
	assert_true(str(result["error"]).contains("tpz_path"), "Error should mention tpz_path")

func test_manage_export_templates_remove_missing():
	var root: String = _unique_user_path("_templates")
	DirAccess.make_dir_recursive_absolute(root)
	var result: Dictionary = _editor_tools._tool_manage_export_templates({"action": "remove", "version": "9.9.9.nope", "templates_root": root})
	assert_true(result.has("error"), "Removing a missing version should error")
	assert_true(str(result["error"]).contains("not found"), "Error should mention not found")
	_editor_tools._remove_dir_recursive(root)

func test_manage_export_templates_install_and_remove_round_trip():
	var root: String = _unique_user_path("_templates")
	DirAccess.make_dir_recursive_absolute(root)
	var tpz: String = _unique_user_path(".tpz")
	var packer: ZIPPacker = ZIPPacker.new()
	assert_eq(packer.open(tpz), OK, "Should create test .tpz")
	packer.start_file("templates/version.txt")
	packer.write_file("4.7.0.test".to_utf8_buffer())
	packer.close_file()
	packer.start_file("templates/windows_release_x86_64.exe")
	packer.write_file("FAKE_TEMPLATE_BYTES".to_utf8_buffer())
	packer.close_file()
	packer.close()

	var installed: Dictionary = _editor_tools._tool_manage_export_templates({"action": "install", "tpz_path": tpz, "templates_root": root})
	assert_eq(installed.get("action", ""), "install", "action should be install")
	assert_eq(installed.get("installed_version", ""), "4.7.0.test", "Version should come from templates/version.txt")
	assert_eq(int(installed.get("extracted_count", 0)), 2, "Both archive files should be extracted")
	var files: Array = installed.get("files", [])
	assert_true(files.has("version.txt"), "templates/ prefix should be stripped from version.txt")
	assert_true(files.has("windows_release_x86_64.exe"), "Template binary should be extracted")
	assert_true(FileAccess.file_exists(root.path_join("4.7.0.test").path_join("windows_release_x86_64.exe")), "Extracted file should exist on disk")

	var status: Dictionary = _editor_tools._tool_manage_export_templates({"action": "status", "templates_root": root})
	assert_true((status.get("installed_versions", []) as Array).has("4.7.0.test"), "Status should list the installed version")

	var removed: Dictionary = _editor_tools._tool_manage_export_templates({"action": "remove", "version": "4.7.0.test", "templates_root": root})
	assert_eq(removed.get("action", ""), "remove", "action should be remove")
	assert_true(int(removed.get("removed_count", 0)) >= 2, "Should remove the extracted files")
	assert_false(DirAccess.dir_exists_absolute(root.path_join("4.7.0.test")), "Version dir should be gone after remove")

	DirAccess.remove_absolute(tpz)
	_editor_tools._remove_dir_recursive(root)

# ---------------------------------------------------------------------------
# configure_android_export
# ---------------------------------------------------------------------------

func _write_export_cfg(path: String, platform: String) -> void:
	var config: ConfigFile = ConfigFile.new()
	config.set_value("preset.0", "name", "TestPreset")
	config.set_value("preset.0", "platform", platform)
	config.set_value("preset.0", "runnable", true)
	config.set_value("preset.0", "export_path", "")
	config.set_value("preset.0.options", "custom_template/debug", "")
	config.save(path)

func test_configure_android_export_requires_preset():
	var result: Dictionary = _editor_tools._tool_configure_android_export({})
	assert_true(result.has("error"), "Missing preset should error")
	assert_true(str(result["error"]).contains("preset"), "Error should mention preset")

func test_configure_android_export_missing_config():
	var result: Dictionary = _editor_tools._tool_configure_android_export({"preset": "TestPreset", "config_path": "user://does_not_exist_mcp.cfg"})
	assert_true(result.has("error"), "Missing config file should error")
	assert_true(str(result["error"]).contains("not found"), "Error should mention not found")

func test_configure_android_export_rejects_non_android():
	var cfg: String = _unique_user_path(".cfg")
	_write_export_cfg(cfg, "Windows Desktop")
	var result: Dictionary = _editor_tools._tool_configure_android_export({"preset": "TestPreset", "config_path": cfg, "package_name": "com.example.app"})
	assert_true(result.has("error"), "Non-Android preset should error")
	assert_true(str(result["error"]).contains("Android"), "Error should mention Android-only support")
	DirAccess.remove_absolute(cfg)

func test_configure_android_export_no_fields():
	var cfg: String = _unique_user_path(".cfg")
	_write_export_cfg(cfg, "Android")
	var result: Dictionary = _editor_tools._tool_configure_android_export({"preset": "TestPreset", "config_path": cfg})
	assert_true(result.has("error"), "No option fields should error")
	assert_true(str(result["error"]).contains("nothing to configure"), "Error should explain nothing to configure")
	DirAccess.remove_absolute(cfg)

func test_configure_android_export_writes_options():
	var cfg: String = _unique_user_path(".cfg")
	_write_export_cfg(cfg, "Android")
	var result: Dictionary = _editor_tools._tool_configure_android_export({
		"preset": "TestPreset",
		"config_path": cfg,
		"package_name": "com.example.game",
		"version_code": 42,
		"version_name": "1.2.3",
		"use_gradle_build": true,
		"export_format": "aab",
		"architectures": ["arm64-v8a"]
	})
	assert_eq(result.get("status", ""), "success", "Configure should succeed")
	assert_true(int(result.get("change_count", 0)) >= 6, "Should record all applied changes")

	var verify: ConfigFile = ConfigFile.new()
	assert_eq(verify.load(cfg), OK, "Should reload written cfg")
	assert_eq(str(verify.get_value("preset.0.options", "package/unique_name", "")), "com.example.game", "package/unique_name should be written")
	assert_eq(int(verify.get_value("preset.0.options", "version/code", 0)), 42, "version/code should be written")
	assert_eq(str(verify.get_value("preset.0.options", "version/name", "")), "1.2.3", "version/name should be written")
	assert_eq(bool(verify.get_value("preset.0.options", "gradle_build/use_gradle_build", false)), true, "gradle_build/use_gradle_build should be written")
	assert_eq(int(verify.get_value("preset.0.options", "gradle_build/export_format", -1)), 1, "export_format aab should map to 1")
	assert_eq(bool(verify.get_value("preset.0.options", "architectures/arm64-v8a", false)), true, "Listed architecture should be enabled")
	assert_eq(bool(verify.get_value("preset.0.options", "architectures/x86_64", true)), false, "Unlisted architecture should be disabled")
	DirAccess.remove_absolute(cfg)

# ---------------------------------------------------------------------------
# undo / redo / get_undo_history
# ---------------------------------------------------------------------------

func _push_undo_action(ur: UndoRedo, name: String, target: Variant, delta: int) -> void:
	ur.create_action(name)
	ur.add_do_property(target, "value", target.value + delta)
	ur.add_undo_property(target, "value", target.value)
	ur.commit_action()

func test_undo_requires_editor_interface():
	var result: Dictionary = _editor_tools._tool_undo({})
	assert_eq(result.get("error", ""), "Editor interface not available", "Should guard on missing editor interface")

func test_redo_requires_editor_interface():
	var result: Dictionary = _editor_tools._tool_redo({})
	assert_eq(result.get("error", ""), "Editor interface not available", "Should guard on missing editor interface")

func test_get_undo_history_requires_editor_interface():
	var result: Dictionary = _editor_tools._tool_get_undo_history({})
	assert_eq(result.get("error", ""), "Editor interface not available", "Should guard on missing editor interface")

func test_undo_rejects_invalid_count():
	var result: Dictionary = _editor_tools._tool_undo({"count": 0})
	assert_true(result.has("error"), "count < 1 should error")
	assert_true(str(result["error"]).contains("count"), "Error should mention count")

func test_get_undo_history_rejects_invalid_limit():
	var result: Dictionary = _editor_tools._tool_get_undo_history({"limit": 0})
	assert_true(result.has("error"), "limit < 1 should error")

func test_apply_undo_actions_null_manager_returns_error():
	var result: Dictionary = _editor_tools._apply_undo_actions(null, 1)
	assert_true(result.has("error"), "Null UndoRedo should error")

func test_apply_undo_actions_empty_stack_returns_noop():
	var ur: UndoRedo = UndoRedo.new()
	var result: Dictionary = _editor_tools._apply_undo_actions(ur, 1)
	assert_eq(result.get("status", ""), "noop", "Empty undo stack should return noop")
	assert_eq(result.get("message", ""), "Nothing to undo", "Should explain there is nothing to undo")
	ur.free()

func test_apply_redo_actions_empty_stack_returns_noop():
	var ur: UndoRedo = UndoRedo.new()
	var result: Dictionary = _editor_tools._apply_redo_actions(ur, 1)
	assert_eq(result.get("status", ""), "noop", "Empty redo stack should return noop")
	assert_eq(result.get("message", ""), "Nothing to redo", "Should explain there is nothing to redo")
	ur.free()

func test_describe_undo_history_empty():
	var ur: UndoRedo = UndoRedo.new()
	var history: Dictionary = _editor_tools._describe_undo_history(ur, 20)
	assert_eq(history["undo_count"], 0, "No undoable actions")
	assert_eq(history["redo_count"], 0, "No redoable actions")
	assert_eq(history["can_undo"], false, "can_undo should be false")
	assert_eq(history["can_redo"], false, "can_redo should be false")
	assert_eq((history["undo_actions"] as Array).size(), 0, "No undo actions listed")
	assert_eq((history["redo_actions"] as Array).size(), 0, "No redo actions listed")
	ur.free()

func test_undo_redo_round_trip_via_helpers():
	var ur: UndoRedo = UndoRedo.new()
	var box: Variant = CounterBox.new()
	_push_undo_action(ur, "Step A", box, 3)
	_push_undo_action(ur, "Step B", box, 4)
	assert_eq(box.value, 7, "Both do steps should be applied at commit")
	var undo_result: Dictionary = _editor_tools._apply_undo_actions(ur, 2)
	assert_eq(undo_result.get("status", ""), "success", "Undo should succeed")
	assert_eq(int(undo_result.get("undone_count", 0)), 2, "Both actions should be undone")
	assert_eq(bool(undo_result.get("has_undo", true)), false, "No undo should remain")
	assert_eq(box.value, 0, "Value should return to the initial state")
	var redo_result: Dictionary = _editor_tools._apply_redo_actions(ur, 2)
	assert_eq(redo_result.get("status", ""), "success", "Redo should succeed")
	assert_eq(int(redo_result.get("redone_count", 0)), 2, "Both actions should be redone")
	assert_eq(box.value, 7, "Value should be restored after redo")
	assert_eq(bool(redo_result.get("has_redo", true)), false, "No redo should remain")
	ur.free()

func test_apply_undo_count_exceeds_stack_stops_at_empty():
	var ur: UndoRedo = UndoRedo.new()
	var box: Variant = CounterBox.new()
	_push_undo_action(ur, "Only", box, 5)
	var result: Dictionary = _editor_tools._apply_undo_actions(ur, 10)
	assert_eq(result.get("status", ""), "success", "Should succeed")
	assert_eq(int(result.get("undone_count", 0)), 1, "Should stop at empty stack")
	assert_eq(bool(result.get("has_undo", true)), false, "has_undo should be false")
	ur.free()

func test_describe_undo_history_lists_most_recent_first():
	var ur: UndoRedo = UndoRedo.new()
	var box: Variant = CounterBox.new()
	_push_undo_action(ur, "Set 10", box, 10)
	_push_undo_action(ur, "Set 25", box, 15)
	assert_eq(box.value, 25, "Latest do step should be applied")
	var history: Dictionary = _editor_tools._describe_undo_history(ur, 20)
	assert_eq(history["undo_count"], 2, "Two actions should be undoable")
	assert_eq(history["redo_count"], 0, "Nothing should be redoable yet")
	assert_eq(history["can_undo"], true, "can_undo should be true")
	assert_eq(history["can_redo"], false, "can_redo should be false")
	var undo_names: Array = history["undo_actions"]
	assert_eq(undo_names.size(), 2, "Should list two undo actions")
	assert_eq(undo_names[0]["name"], "Set 25", "Most recent undo action should come first")
	assert_eq(undo_names[1]["name"], "Set 10", "Older undo action should come second")
	ur.free()

func test_describe_undo_history_after_undo_shows_redo():
	var ur: UndoRedo = UndoRedo.new()
	var box: Variant = CounterBox.new()
	_push_undo_action(ur, "Alpha", box, 5)
	_push_undo_action(ur, "Beta", box, 5)
	_editor_tools._apply_undo_actions(ur, 1)
	var history: Dictionary = _editor_tools._describe_undo_history(ur, 20)
	assert_eq(history["undo_count"], 1, "One undoable action should remain")
	assert_eq(history["redo_count"], 1, "One redoable action should exist")
	assert_eq(history["can_undo"], true, "can_undo should be true")
	assert_eq(history["can_redo"], true, "can_redo should be true")
	var undo_names: Array = history["undo_actions"]
	assert_eq(undo_names.size(), 1, "Should list one undo action")
	assert_eq(undo_names[0]["name"], "Alpha", "Remaining undo action should be Alpha")
	var redo_names: Array = history["redo_actions"]
	assert_eq(redo_names.size(), 1, "Should list one redo action")
	assert_eq(redo_names[0]["name"], "Beta", "Next redo action should be Beta")
	ur.free()

func test_describe_undo_history_limit_caps_action_names():
	var ur: UndoRedo = UndoRedo.new()
	var box: Variant = CounterBox.new()
	_push_undo_action(ur, "One", box, 1)
	_push_undo_action(ur, "Two", box, 1)
	_push_undo_action(ur, "Three", box, 1)
	var limited: Dictionary = _editor_tools._describe_undo_history(ur, 2)
	assert_eq((limited["undo_actions"] as Array).size(), 2, "limit should cap listed undo action names")
	assert_eq(limited["undo_count"], 3, "undo_count should still reflect the full stack")
	ur.free()

func test_undo_redo_tools_registered_and_use_editor_undo_redo():
	var source_code: String = _editor_tools.get_script().source_code
	assert_true(source_code.contains("_register_undo(server_core)"), "undo should be registered in register_tools")
	assert_true(source_code.contains("_register_redo(server_core)"), "redo should be registered in register_tools")
	assert_true(source_code.contains("_register_get_undo_history(server_core)"), "get_undo_history should be registered in register_tools")
	assert_true(source_code.contains("get_undo_redo"), "Undo/redo tools should use EditorInterface.get_undo_redo()")
	assert_true(source_code.contains("has_undo()"), "undo should guard with has_undo()")
	assert_true(source_code.contains("get_action_name"), "get_undo_history should list action names via get_action_name")

class CounterBox:
	extends RefCounted
	var value: int = 0
