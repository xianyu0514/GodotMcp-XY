extends "res://addons/gut/test.gd"

# 高返回读工具的 limit/offset 统一分页语义回归测试。

const CORE_SCRIPT = preload("res://addons/godot_mcp/native_mcp/mcp_server_core.gd")

func test_paginate_list_first_page_matches_truncate() -> void:
	var items: Array = ["a", "b", "c", "d", "e"]
	var page: Dictionary = PayloadUtils.paginate_list(items, 2)
	assert_eq(page["items"], ["a", "b"], "First page should apply limit from index 0")
	assert_eq(page["total_count"], 5, "total_count should be the full list size")
	assert_true(page["truncated"], "truncated should be true when more entries remain")


func test_paginate_list_applies_offset_before_limit() -> void:
	var items: Array = ["a", "b", "c", "d", "e"]
	var page: Dictionary = PayloadUtils.paginate_list(items, 2, 2)
	assert_eq(page["items"], ["c", "d"], "offset should skip entries before applying limit")
	assert_true(page["truncated"], "Entries after the page should still be reported")


func test_paginate_list_offset_past_end_returns_empty() -> void:
	var items: Array = ["a", "b"]
	var page: Dictionary = PayloadUtils.paginate_list(items, 10, 5)
	assert_eq(page["items"], [], "Offset beyond the list should return an empty page")
	assert_false(page["truncated"], "No remaining entries means truncated=false")


func test_high_volume_read_tools_expose_limit_offset() -> void:
	var core: RefCounted = CORE_SCRIPT.new()
	for path in [
		"res://addons/godot_mcp/tools/node_tools_native.gd",
		"res://addons/godot_mcp/tools/scene_tools_native.gd",
		"res://addons/godot_mcp/tools/script_tools_native.gd",
	]:
		var module_script: GDScript = load(path)
		var module: RefCounted = module_script.new()
		module.register_tools(core)

	for tool_name in ["list_nodes", "list_project_scenes", "list_project_scripts"]:
		var tool = core.get_tool(tool_name)
		assert_ne(tool, null, "%s should be registered" % tool_name)
		var properties: Dictionary = tool.input_schema.get("properties", {})
		assert_true(properties.has("limit"), "%s should expose unified 'limit'" % tool_name)
		assert_true(properties.has("offset"), "%s should expose unified 'offset'" % tool_name)


func test_list_project_scripts_output_schema_includes_pagination_metadata() -> void:
	var core: RefCounted = CORE_SCRIPT.new()
	var module_script: GDScript = load("res://addons/godot_mcp/tools/script_tools_native.gd")
	var module: RefCounted = module_script.new()
	module.register_tools(core)
	var tool = core.get_tool("list_project_scripts")
	assert_ne(tool, null, "list_project_scripts should be registered")
	var properties: Dictionary = tool.output_schema.get("properties", {})
	assert_true(properties.has("total_count"), "output schema should include total_count")
	assert_true(properties.has("truncated"), "output schema should include truncated")
