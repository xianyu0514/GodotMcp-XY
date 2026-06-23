extends "res://addons/gut/test.gd"

var _state_manager = null
var _server_core = null

func before_each():
	_state_manager = load("res://addons/godot_mcp/native_mcp/tool_state_manager.gd").new()
	_server_core = load("res://addons/godot_mcp/native_mcp/mcp_server_core.gd").new()

func after_each():
	if _server_core and _server_core.is_running():
		_server_core.stop()
	var path: String = _state_manager.get_storage_path()
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)
	_state_manager = null
	_server_core = null

func test_state_manager_initializes():
	assert_ne(_state_manager, null, "State manager should initialize")

func test_load_state_returns_empty_when_no_file():
	var state: Dictionary = _state_manager.load_state()
	assert_eq(state.size(), 0, "Should return empty dict when no state file exists")

func test_save_and_load_state():
	var test_states: Dictionary = {
		"create_node": true,
		"delete_node": false,
		"read_script": true
	}
	var saved: bool = _state_manager.save_state(test_states)
	assert_true(saved, "Save should succeed")

	var loaded: Dictionary = _state_manager.load_state()
	assert_eq(loaded.size(), 3, "Should load 3 tools")
	assert_eq(loaded["create_node"], true, "create_node should be enabled")
	assert_eq(loaded["delete_node"], false, "delete_node should be disabled")
	assert_eq(loaded["read_script"], true, "read_script should be enabled")

func test_load_empty_section_returns_empty():
	var result: Dictionary = _state_manager.load_state()
	assert_true(result is Dictionary, "Result should be a Dictionary")

func test_apply_states_to_server():
	_server_core.register_tool("test_tool_1", "Test 1", {"type": "object"}, func(args): return {})
	_server_core.register_tool("test_tool_2", "Test 2", {"type": "object"}, func(args): return {})

	var states: Dictionary = {
		"test_tool_1": false,
		"test_tool_2": true
	}
	_state_manager.apply_states_to_server(_server_core, states)

	assert_true(_server_core.has_tool("test_tool_1"), "Tool should still exist")
	assert_true(_server_core.has_tool("test_tool_2"), "Tool should still exist")

	var tools: Array = _server_core.get_registered_tools()
	for t in tools:
		if t["name"] == "test_tool_1":
			assert_false(t["enabled"], "test_tool_1 should be disabled")
		if t["name"] == "test_tool_2":
			assert_true(t["enabled"], "test_tool_2 should be enabled")

func test_apply_states_ignores_unregistered_tools():
	_server_core.register_tool("real_tool", "Real", {"type": "object"}, func(args): return {})
	var states: Dictionary = {
		"real_tool": false,
		"fake_tool": true
	}
	_state_manager.apply_states_to_server(_server_core, states)

	var tools: Array = _server_core.get_registered_tools()
	assert_eq(tools.size(), 1, "Only real tool should exist")

func test_capture_states_from_server():
	_server_core.register_tool("tool_a", "A", {"type": "object"}, func(args): return {})
	_server_core.register_tool("tool_b", "B", {"type": "object"}, func(args): return {})
	_server_core.set_tool_enabled("tool_a", false)

	var captured: Dictionary = _state_manager.capture_states_from_server(_server_core)
	assert_eq(captured.size(), 2, "Should capture 2 tools")
	assert_eq(captured["tool_a"], false, "tool_a should be disabled")
	assert_eq(captured["tool_b"], true, "tool_b should be enabled")

func test_validate_core_tool_limit():
	_server_core.register_tool("tool", "Test", {"type": "object"}, func(args): return {})
	var states: Dictionary = {"tool": true}
	var result: Dictionary = _state_manager.validate_core_tool_limit(states)
	assert_has(result, "over_limit", "Result should have over_limit")
	assert_has(result, "enabled_core_count", "Result should have enabled_core_count")
	assert_has(result, "core_limit", "Result should have core_limit")
	assert_has(result, "message", "Result should have message")
	assert_eq(result["core_limit"], 30, "Core limit should be 30 (CORE_MAX_COUNT)")

func test_get_storage_path():
	var path: String = _state_manager.get_storage_path()
	assert_true(path.ends_with("mcp_tool_state.cfg"), "Path should end with mcp_tool_state.cfg")

func test_save_and_load_with_checksum():
	var test_states: Dictionary = {"tool_x": true}
	_state_manager.save_state(test_states)

	var loaded: Dictionary = _state_manager.load_state()
	assert_eq(loaded["tool_x"], true, "State should persist with checksum verification")

func test_validate_config_integrity_no_meta():
	var config: ConfigFile = ConfigFile.new()
	config.set_value("tools", "test", true)
	var result: bool = _state_manager._validate_config_integrity(config)
	assert_false(result, "Config without meta section should be invalid")

func test_storage_version_constant():
	assert_eq(_state_manager.storage_version, 1, "Storage version should be 1")

func test_config_file_name_constant():
	assert_eq(_state_manager.config_file_name, "mcp_tool_state.cfg", "Config file name should be mcp_tool_state.cfg")