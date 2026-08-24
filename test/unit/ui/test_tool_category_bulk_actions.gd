extends "res://addons/gut/test.gd"

const PanelScript = preload("res://addons/godot_mcp/ui/mcp_panel_native.gd")

class FakeClassifier extends RefCounted:
	func get_domain_tools(domain_name: String) -> Array[String]:
		if domain_name == "2d":
			return ["create_node", "create_tileset"]
		return []

func _make_group(group_name: String, tool_names: Array[String]) -> MCPToolGroupItem:
	var group: MCPToolGroupItem = MCPToolGroupItem.new()
	add_child_autofree(group)
	var tools: Array = []
	for tool_name in tool_names:
		tools.append({
			"name": tool_name,
			"description": tool_name,
			"enabled": true,
			"category": "supplementary"
		})
	group.setup(group_name, tools, null)
	return group

func test_disable_all_only_changes_current_task_category():
	var panel = PanelScript.new()
	panel._selected_category = "__domain__2d"
	panel._tool_classifier = FakeClassifier.new()
	var shared_group: MCPToolGroupItem = _make_group("Node-Write", ["create_node"])
	var mixed_group: MCPToolGroupItem = _make_group("Project-Advanced", ["create_tileset", "generate_3d_asset"])
	panel._group_widgets = {
		"Node-Write": shared_group,
		"Project-Advanced": mixed_group
	}

	panel._set_scope_enabled(false)

	assert_false(shared_group.get_tool_items()[0].is_enabled(), "Shared tool in current 2D category is disabled")
	assert_false(mixed_group.get_tool_items()[0].is_enabled(), "2D-only tool in current category is disabled")
	assert_true(mixed_group.get_tool_items()[1].is_enabled(), "3D-only tool outside current category is unchanged")
	panel.free()

func test_enable_all_only_changes_current_group_category():
	var panel = PanelScript.new()
	panel._selected_category = "Node-Write"
	var node_group: MCPToolGroupItem = _make_group("Node-Write", ["create_node"])
	var project_group: MCPToolGroupItem = _make_group("Project-Advanced", ["create_tileset"])
	panel._group_widgets = {
		"Node-Write": node_group,
		"Project-Advanced": project_group
	}
	node_group.set_group_enabled(false)
	project_group.set_group_enabled(false)

	panel._set_scope_enabled(true)

	assert_true(node_group.get_tool_items()[0].is_enabled(), "Current group tool is enabled")
	assert_false(project_group.get_tool_items()[0].is_enabled(), "Other category remains unchanged")
	panel.free()
