extends "res://addons/gut/test.gd"

# Tests for the master-detail left navigator item (mcp_category_nav_item.gd).

func _make_item(key: String, label: String) -> MCPCategoryNavItem:
	var group: ButtonGroup = ButtonGroup.new()
	var item: MCPCategoryNavItem = MCPCategoryNavItem.new()
	add_child_autofree(item)
	item.setup(key, label, null, group)
	return item

func test_setup_stores_key():
	var item: MCPCategoryNavItem = _make_item("Node-Read", "Nodes")
	assert_eq(item.category_key, "Node-Read", "Nav item remembers its category key")
	assert_true(item.toggle_mode, "Nav item is a toggle so selection sticks")
	assert_gte(item.custom_minimum_size.y, 42.0, "Navigation targets match the editor's click scale")
	assert_gte(item.get_theme_font_size("font_size"), 15, "Navigation labels match the editor text scale")

func test_compact_mode_matches_native_filter_bar_density():
	var group: ButtonGroup = ButtonGroup.new()
	var item: MCPCategoryNavItem = MCPCategoryNavItem.new()
	add_child_autofree(item)
	item.setup("__all__", "All", null, group, 15, 1.0, true)
	assert_lte(item.custom_minimum_size.y, 36.0, "Filter chips stay as compact as Godot toolbar controls")
	assert_gte(item.get_theme_font_size("font_size"), 14, "Compact chips remain readable")

func test_count_appears_in_text():
	var item: MCPCategoryNavItem = _make_item("Node-Read", "Nodes")
	item.set_count(3, 5)
	assert_string_contains(item.text, "3", "Enabled count shown")
	assert_string_contains(item.text, "5", "Total count shown")

func test_press_emits_selection():
	var item: MCPCategoryNavItem = _make_item("__all__", "All")
	watch_signals(item)
	item.button_pressed = true
	assert_signal_emitted_with_parameters(item, "category_selected", ["__all__"])

func test_set_label_updates_text():
	var item: MCPCategoryNavItem = _make_item("__all__", "All")
	item.set_count(2, 4)
	item.set_label("Everything")
	assert_string_contains(item.text, "Everything", "set_label updates the visible base label")
	assert_string_contains(item.text, "2", "Existing count is preserved after relabel")

func test_set_selected_is_silent():
	var item: MCPCategoryNavItem = _make_item("Node-Read", "Nodes")
	watch_signals(item)
	item.set_selected(true)
	assert_signal_not_emitted(item, "category_selected")
	assert_true(item.button_pressed, "set_selected reflects in pressed state")
