extends "res://addons/gut/test.gd"

const CORE_SCRIPT = preload("res://addons/godot_mcp/native_mcp/mcp_server_core.gd")

var _core = null
var _calls: Dictionary = {}


func before_each() -> void:
	_core = CORE_SCRIPT.new()
	_calls = {}


func after_each() -> void:
	_core = null


func _read_handler(args: Dictionary) -> Dictionary:
	var key: String = str(args.get("key", args.get("script_path", "default")))
	_calls[key] = int(_calls.get(key, 0)) + 1
	return {"key": key, "calls": _calls[key]}


func _write_handler(_args: Dictionary) -> Dictionary:
	return {"status": "success"}


func _register_read(name: String, group: String = "Project") -> void:
	_core.register_tool(name, "Read", {"type": "object"}, Callable(self, "_read_handler"), {},
		MCPTypes.MCPTool.create_annotations(true, false, true, false), "core", group)


func _register_write(name: String, group: String) -> void:
	_core.register_tool(name, "Write", {"type": "object"}, Callable(self, "_write_handler"), {},
		MCPTypes.MCPTool.create_annotations(false, false, true, false), "core", group)


func _call(name: String, args: Dictionary = {}) -> Dictionary:
	return {
		"jsonrpc": "2.0", "id": 1, "method": "tools/call",
		"params": {"name": name, "arguments": args}
	}


func test_scene_write_preserves_unrelated_script_and_project_entries() -> void:
	_register_read("get_scene_structure", "Scene")
	_register_read("read_script", "Script")
	_register_read("get_project_structure", "Project")
	_register_write("create_node", "Node-Write")

	await _core._handle_tool_call(_call("get_scene_structure", {"key": "scene"}))
	await _core._handle_tool_call(_call("read_script", {"script_path": "res://player.gd"}))
	await _core._handle_tool_call(_call("get_project_structure", {"key": "project"}))
	assert_eq(_core._result_cache.size(), 3)

	await _core._handle_tool_call(_call("create_node"))
	assert_eq(_core._result_cache.size(), 3, "Domain invalidation is O(1) and leaves stale entries for lazy eviction")
	await _core._handle_tool_call(_call("get_scene_structure", {"key": "scene"}))
	await _core._handle_tool_call(_call("read_script", {"script_path": "res://player.gd"}))
	await _core._handle_tool_call(_call("get_project_structure", {"key": "project"}))

	assert_eq(_calls.get("scene", 0), 2, "Scene reads recompute after a node mutation")
	assert_eq(_calls.get("res://player.gd", 0), 1, "Script reads remain hot after a scene-only mutation")
	assert_eq(_calls.get("project", 0), 1, "Project tree scan remains hot when no files were added")


func test_script_write_invalidates_only_matching_path() -> void:
	_register_read("read_script", "Script")
	_register_write("modify_script", "Script")
	var player: Dictionary = {"script_path": "res://player.gd"}
	var enemy: Dictionary = {"script_path": "res://enemy.gd"}

	await _core._handle_tool_call(_call("read_script", player))
	await _core._handle_tool_call(_call("read_script", enemy))
	await _core._handle_tool_call(_call("modify_script", player))
	await _core._handle_tool_call(_call("read_script", player))
	await _core._handle_tool_call(_call("read_script", enemy))

	assert_eq(_calls.get("res://player.gd", 0), 2)
	assert_eq(_calls.get("res://enemy.gd", 0), 1, "Unmodified script content stays cached")


func test_runtime_write_preserves_all_project_cache_entries() -> void:
	_register_read("get_scene_structure", "Scene")
	_register_write("update_runtime_node_property", "Debug-Advanced")
	await _core._handle_tool_call(_call("get_scene_structure", {"key": "scene"}))
	var generation_before: int = _core._cache_generation
	await _core._handle_tool_call(_call("update_runtime_node_property"))
	await _core._handle_tool_call(_call("get_scene_structure", {"key": "scene"}))
	assert_eq(_calls.get("scene", 0), 1)
	assert_eq(_core._cache_generation, generation_before, "No project revision changes for runtime-only writes")


func test_unknown_writer_invalidates_every_cached_domain() -> void:
	_register_read("get_scene_structure", "Scene")
	_register_read("read_script", "Script")
	_register_write("plugin_defined_writer", "Custom")
	await _core._handle_tool_call(_call("get_scene_structure", {"key": "scene"}))
	await _core._handle_tool_call(_call("read_script", {"script_path": "res://player.gd"}))
	await _core._handle_tool_call(_call("plugin_defined_writer"))
	await _core._handle_tool_call(_call("get_scene_structure", {"key": "scene"}))
	await _core._handle_tool_call(_call("read_script", {"script_path": "res://player.gd"}))
	assert_eq(_calls.get("scene", 0), 2)
	assert_eq(_calls.get("res://player.gd", 0), 2)


func test_resource_write_invalidates_only_matching_resource_path() -> void:
	_register_read("read_resource_properties", "Project-Advanced")
	_register_write("update_resource_properties", "Project-Advanced")
	var player_data: Dictionary = {"resource_path": "res://data/player.tres", "key": "player_resource"}
	var enemy_data: Dictionary = {"resource_path": "res://data/enemy.tres", "key": "enemy_resource"}
	await _core._handle_tool_call(_call("read_resource_properties", player_data))
	await _core._handle_tool_call(_call("read_resource_properties", enemy_data))
	await _core._handle_tool_call(_call("update_resource_properties", {
		"resource_path": "res://data/player.tres"
	}))
	await _core._handle_tool_call(_call("read_resource_properties", player_data))
	await _core._handle_tool_call(_call("read_resource_properties", enemy_data))
	assert_eq(_calls.get("player_resource", 0), 2)
	assert_eq(_calls.get("enemy_resource", 0), 1, "Unmodified resource remains cached")


func test_project_setting_write_preserves_scene_and_resource_reads() -> void:
	_register_read("get_project_settings", "Project")
	_register_read("get_scene_structure", "Scene")
	_register_read("read_resource_properties", "Project-Advanced")
	_register_write("set_project_setting", "Project-Advanced")
	await _core._handle_tool_call(_call("get_project_settings", {"key": "settings"}))
	await _core._handle_tool_call(_call("get_scene_structure", {"key": "scene"}))
	await _core._handle_tool_call(_call("read_resource_properties", {
		"resource_path": "res://data/player.tres", "key": "resource"
	}))
	await _core._handle_tool_call(_call("set_project_setting"))
	await _core._handle_tool_call(_call("get_project_settings", {"key": "settings"}))
	await _core._handle_tool_call(_call("get_scene_structure", {"key": "scene"}))
	await _core._handle_tool_call(_call("read_resource_properties", {
		"resource_path": "res://data/player.tres", "key": "resource"
	}))
	assert_eq(_calls.get("settings", 0), 2)
	assert_eq(_calls.get("scene", 0), 1)
	assert_eq(_calls.get("resource", 0), 1)


func test_create_script_invalidates_file_catalogs_but_not_scene_content() -> void:
	_register_read("list_project_scripts", "Script")
	_register_read("list_project_resources", "Project")
	_register_read("get_project_structure", "Project-Advanced")
	_register_read("get_scene_structure", "Scene")
	_register_write("create_script", "Script")
	for entry in [
		["list_project_scripts", "scripts"],
		["list_project_resources", "resources"],
		["get_project_structure", "project"],
		["get_scene_structure", "scene"]
	]:
		await _core._handle_tool_call(_call(entry[0], {"key": entry[1]}))
	await _core._handle_tool_call(_call("create_script", {"script_path": "res://new_file.gd"}))
	for entry in [
		["list_project_scripts", "scripts"],
		["list_project_resources", "resources"],
		["get_project_structure", "project"],
		["get_scene_structure", "scene"]
	]:
		await _core._handle_tool_call(_call(entry[0], {"key": entry[1]}))
	assert_eq(_calls.get("scripts", 0), 2)
	assert_eq(_calls.get("resources", 0), 2)
	assert_eq(_calls.get("project", 0), 2)
	assert_eq(_calls.get("scene", 0), 1, "Creating a detached script does not change the edited scene")
