extends "res://addons/gut/test.gd"

const PresetManagerScript = preload("res://addons/godot_mcp/native_mcp/mcp_tool_preset_manager.gd")

var _manager = null
var _classifier = null
var _all_names: Array = []

func before_each():
	_manager = PresetManagerScript.new()
	_classifier = load("res://addons/godot_mcp/native_mcp/mcp_tool_classifier.gd").new()
	_all_names = []
	for tool_name in _classifier.get_all_tools():
		_all_names.append(tool_name)

func after_each():
	_manager = null
	_classifier = null
	_all_names = []

func _count_enabled(states: Dictionary) -> int:
	var n: int = 0
	for key in states:
		if states[key]:
			n += 1
	return n

func test_preset_ids_count():
	assert_eq(_manager.get_preset_ids().size(), 6, "Should expose 6 built-in presets")

func test_has_preset():
	assert_true(_manager.has_preset("minimal_core"), "minimal_core should exist")
	assert_false(_manager.has_preset("does_not_exist"), "Unknown preset should not exist")

func test_minimal_core_enables_only_core_tools():
	var states: Dictionary = _manager.resolve_preset_states("minimal_core", _all_names)
	assert_eq(_count_enabled(states), 30, "minimal_core should enable exactly the 30 core tools")
	assert_true(states["create_node"], "Core tool create_node should be enabled")
	assert_false(states["reload_project"], "Supplementary tool should be disabled in minimal_core")

func test_all_enables_everything():
	var states: Dictionary = _manager.resolve_preset_states("all", _all_names)
	assert_eq(_count_enabled(states), _all_names.size(), "all preset should enable every registered tool")
	assert_eq(_count_enabled(states), 201, "all preset should enable 201 tools")

func test_debugging_includes_core_plus_debug_advanced():
	var states: Dictionary = _manager.resolve_preset_states("debugging", _all_names)
	assert_eq(_count_enabled(states), 97, "debugging = 30 core + 67 Debug-Advanced")
	assert_true(states["create_node"], "Core tool should remain enabled")
	assert_true(states["get_runtime_info"], "Debug-Advanced tool should be enabled")
	assert_false(states["run_export"], "Unrelated Project-Advanced tool should stay disabled")

func test_level_design_enables_authoring_groups():
	var states: Dictionary = _manager.resolve_preset_states("level_design", _all_names)
	assert_eq(_count_enabled(states), 74, "level_design = 30 core + 8 + 9 + 8 + 19 advanced authoring tools")
	assert_true(states["connect_signal"], "Node-Write-Advanced tool should be enabled")
	assert_false(states["get_runtime_info"], "Debug-Advanced tool should be disabled for level design")

func test_unknown_preset_disables_all():
	var states: Dictionary = _manager.resolve_preset_states("nope", _all_names)
	assert_eq(_count_enabled(states), 0, "Unknown preset should disable everything")

func test_states_json_round_trip():
	var states: Dictionary = _manager.resolve_preset_states("debugging", _all_names)
	var text: String = PresetManagerScript.states_to_json(states)
	var result: Dictionary = PresetManagerScript.states_from_json(text, _all_names)
	assert_true(result["ok"], "Round-trip parse should succeed")
	assert_eq(result["states"], states, "Round-trip should reproduce the same enabled-state map")

func test_states_from_json_rejects_invalid():
	var result: Dictionary = PresetManagerScript.states_from_json("{\"foo\": 1}", _all_names)
	assert_false(result["ok"], "Missing enabled_tools should be rejected")

func test_states_from_json_ignores_unknown_tool_names():
	var text: String = "{\"version\": 1, \"enabled_tools\": [\"create_node\", \"ghost_tool\"]}"
	var result: Dictionary = PresetManagerScript.states_from_json(text, _all_names)
	assert_true(result["ok"], "Valid format should parse")
	assert_true(result["states"]["create_node"], "Known tool should be enabled")
	assert_false(result["states"].has("ghost_tool"), "Unknown tool name should be ignored, not added")

func test_export_import_file_round_trip():
	var states: Dictionary = _manager.resolve_preset_states("automation_qa", _all_names)
	var path: String = "user://test_preset_round_trip.json"
	var ok: bool = PresetManagerScript.export_states_to_file(states, path)
	assert_true(ok, "Export should succeed")
	var result: Dictionary = PresetManagerScript.import_states_from_file(path, _all_names)
	assert_true(result["ok"], "Import should succeed")
	assert_eq(result["states"], states, "File round-trip should reproduce the same map")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))

func test_import_missing_file_fails_gracefully():
	var result: Dictionary = PresetManagerScript.import_states_from_file("user://does_not_exist_xyz.json", _all_names)
	assert_false(result["ok"], "Importing a missing file should fail gracefully")
