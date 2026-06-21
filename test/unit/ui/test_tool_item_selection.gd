extends "res://addons/gut/test.gd"

# Tests for row selection in the Tool Manager:
# MCPToolItem selection state + tool_selected signal, and the forwarding /
# get_tool_items helpers on MCPToolGroupItem.

func _make_item(name: String) -> MCPToolItem:
	var item: MCPToolItem = MCPToolItem.new()
	add_child_autofree(item)
	item.setup(name, "desc", true, "core", "Node-Write")
	return item

func _make_group() -> MCPToolGroupItem:
	var group: MCPToolGroupItem = MCPToolGroupItem.new()
	add_child_autofree(group)
	group.setup("Node-Write", [
		{"name": "create_node", "description": "Create a node", "enabled": true, "category": "core"},
		{"name": "delete_node", "description": "Delete a node", "enabled": true, "category": "core"},
	], null)
	return group

func _left_click() -> InputEventMouseButton:
	var event: InputEventMouseButton = InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = true
	return event

func test_set_selected_tracks_state():
	var item: MCPToolItem = _make_item("create_node")
	assert_false(item.is_selected(), "Rows start unselected")
	item.set_selected(true)
	assert_true(item.is_selected(), "set_selected(true) marks the row selected")
	item.set_selected(false)
	assert_false(item.is_selected(), "set_selected(false) clears selection")

func test_left_click_emits_tool_selected():
	var item: MCPToolItem = _make_item("create_node")
	watch_signals(item)
	item._gui_input(_left_click())
	assert_signal_emitted_with_parameters(item, "tool_selected", ["create_node"])

func test_set_selected_does_not_emit():
	var item: MCPToolItem = _make_item("create_node")
	watch_signals(item)
	item.set_selected(true)
	assert_signal_not_emitted(item, "tool_selected", "Programmatic selection stays silent")

func test_group_lists_its_tool_items():
	var group: MCPToolGroupItem = _make_group()
	var items: Array = group.get_tool_items()
	assert_eq(items.size(), 2, "get_tool_items returns every tool row")
	var names: Array = [items[0].get_tool_name(), items[1].get_tool_name()]
	assert_true(names.has("create_node"), "Includes create_node")
	assert_true(names.has("delete_node"), "Includes delete_node")

func test_group_forwards_tool_selected():
	var group: MCPToolGroupItem = _make_group()
	watch_signals(group)
	var first: MCPToolItem = group.get_tool_items()[0]
	first._gui_input(_left_click())
	assert_signal_emitted_with_parameters(group, "tool_selected", [first.get_tool_name()])
