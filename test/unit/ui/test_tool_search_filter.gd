extends "res://addons/gut/test.gd"

# Tests for the Tool Manager search/filter (mcp_tool_item.gd, mcp_tool_group_item.gd).

func _make_group() -> MCPToolGroupItem:
	var group: MCPToolGroupItem = MCPToolGroupItem.new()
	add_child_autofree(group)
	var items: Array = [
		{"name": "create_node", "description": "Create a node", "enabled": true, "category": "core"},
		{"name": "delete_node", "description": "Delete a node", "enabled": true, "category": "core"}
	]
	group.setup("Node-Write", items, null)
	return group

func test_tool_item_matches_filter():
	var item: MCPToolItem = MCPToolItem.new()
	add_child_autofree(item)
	item.setup("create_node", "Create a new node in the scene", true, "core", "Node-Write")
	assert_true(item.matches_filter("create"), "Matches by tool name")
	assert_true(item.matches_filter("scene"), "Matches by description")
	assert_false(item.matches_filter("zzz"), "No match for unrelated query")
	assert_true(item.matches_filter(""), "Empty query matches everything")

func test_group_filter_by_tool_name():
	var group: MCPToolGroupItem = _make_group()
	assert_eq(group.apply_filter("create"), 1, "Only create_node matches 'create'")

func test_group_filter_empty_shows_all():
	var group: MCPToolGroupItem = _make_group()
	assert_eq(group.apply_filter(""), 2, "Empty query shows all tools")

func test_group_filter_shared_term():
	var group: MCPToolGroupItem = _make_group()
	assert_eq(group.apply_filter("node"), 2, "Both tools match 'node'")

func test_group_name_match_reveals_all_tools():
	var group: MCPToolGroupItem = _make_group()
	assert_eq(group.apply_filter("write"), 2, "Group name match reveals all tools")

func test_group_uses_card_container():
	var group: MCPToolGroupItem = _make_group()
	assert_eq(group.get_child_count(), 1, "Group wraps its content in a single card")
	assert_true(group.get_child(0) is PanelContainer, "Card is a PanelContainer")
	assert_not_null(group.get_tool_container(), "Tool container resolvable after refactor")

func test_collapse_hides_description_label():
	var manager: MCPTranslationManager = MCPTranslationManager.new()
	manager.load_all()
	var group: MCPToolGroupItem = MCPToolGroupItem.new()
	add_child_autofree(group)
	group.setup("Node-Write", [
		{"name": "create_node", "description": "Create a node", "enabled": true, "category": "core"}
	], manager)
	var desc: Label = group._get_desc_label()
	assert_not_null(desc, "Group with a translated description renders a DescLabel")
	assert_true(desc.visible, "Description is visible while expanded")
	group._toggle_collapse()
	assert_false(desc.visible, "Description hides together with the tool list when collapsed")
	assert_false(group.get_tool_container().visible, "Tool list hidden when collapsed")
	group._toggle_collapse()
	assert_true(desc.visible, "Description returns when expanded again")
