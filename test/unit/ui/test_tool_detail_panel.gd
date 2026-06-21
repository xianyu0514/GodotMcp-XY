extends "res://addons/gut/test.gd"

# Tests for the Tool Manager right-hand detail pane (mcp_tool_detail_panel.gd).

func _make_panel() -> MCPToolDetailPanel:
	var panel: MCPToolDetailPanel = MCPToolDetailPanel.new()
	add_child_autofree(panel)
	panel.setup(null)
	return panel

func _sample_info() -> Dictionary:
	return {
		"name": "create_node",
		"description": "Create a node in the scene tree",
		"category": "core",
		"group": "Node-Write",
		"group_display": "Nodes",
		"enabled": true,
		"input_schema": {
			"type": "object",
			"properties": {
				"parent_path": {"type": "string", "description": "Parent node path"},
				"node_type": {"type": "string"},
			},
			"required": ["parent_path", "node_type"],
		},
		"output_schema": {"type": "object", "properties": {"node_path": {"type": "string"}}},
		"annotations": {"destructiveHint": true},
	}

func test_show_empty_renders_hint():
	var panel: MCPToolDetailPanel = _make_panel()
	panel.show_empty()
	assert_gt(panel._content.get_child_count(), 0, "Empty state still renders a hint")

func test_show_tool_populates_content():
	var panel: MCPToolDetailPanel = _make_panel()
	panel.show_tool(_sample_info())
	assert_gt(panel._content.get_child_count(), 1, "Tool detail builds multiple sections")

func test_example_args_uses_type_placeholders():
	var panel: MCPToolDetailPanel = _make_panel()
	var schema: Dictionary = {
		"type": "object",
		"properties": {
			"label": {"type": "string"},
			"count": {"type": "integer"},
			"flag": {"type": "boolean"},
		},
	}
	var args: Dictionary = panel._example_args(schema)
	assert_eq(args["label"], "...", "String params get a string placeholder")
	assert_eq(args["count"], 0, "Integer params default to 0")
	assert_eq(args["flag"], false, "Boolean params default to false")

func test_example_value_prefers_default_then_enum():
	var panel: MCPToolDetailPanel = _make_panel()
	assert_eq(panel._example_value({"type": "string", "default": "hi"}), "hi", "Default wins")
	assert_eq(panel._example_value({"type": "string", "enum": ["a", "b"]}), "a", "Enum first value")

func test_ai_prompt_includes_name_and_required():
	var panel: MCPToolDetailPanel = _make_panel()
	var prompt: String = panel._compose_ai_prompt(_sample_info())
	assert_string_contains(prompt, "create_node")
	assert_string_contains(prompt, "parent_path")
	assert_string_contains(prompt, "node_type")
