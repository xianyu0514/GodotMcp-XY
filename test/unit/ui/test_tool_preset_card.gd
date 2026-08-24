extends "res://addons/gut/test.gd"

const PanelScript = preload("res://addons/godot_mcp/ui/mcp_panel_native.gd")
const PresetManagerScript = preload("res://addons/godot_mcp/native_mcp/mcp_tool_preset_manager.gd")

class FakeServerCore:
	var states: Dictionary = {}

	func _init() -> void:
		var classifier = MCPToolClassifier.new()
		for tool_name in classifier.get_all_tools():
			states[tool_name] = false

	func get_registered_tools() -> Array:
		var tools: Array = []
		for tool_name in states:
			tools.append({"name": tool_name, "enabled": states[tool_name]})
		return tools

	func set_tool_enabled(tool_name: String, enabled: bool) -> void:
		states[tool_name] = enabled

func _make_panel() -> Node:
	var panel: Node = PanelScript.new()
	panel._preset_manager = PresetManagerScript.new()
	panel._translation_manager = MCPTranslationManager.new()
	panel._translation_manager.load_all()
	autofree(panel)
	return panel

func test_profile_controls_live_in_one_compact_toolbar():
	var panel: Node = _make_panel()
	var content: VBoxContainer = VBoxContainer.new()
	autofree(content)
	panel._build_preset_row(content)
	assert_eq(content.get_child_count(), 1, "Profile controls are one cohesive surface")
	assert_true(content.get_child(0) is PanelContainer, "Profile controls use a subtle panel")
	assert_true(panel._preset_bar is HBoxContainer, "Every profile control shares one horizontal toolbar")
	assert_eq(panel._preset_description_label.get_parent(), panel._preset_bar, "Description does not create a second row")
	assert_true(panel._preset_option.size_flags_horizontal == Control.SIZE_EXPAND_FILL, "Dropdown expands in narrow docks")
	assert_not_null(panel._preset_description_label, "Selected preset has an explanation")
	assert_not_null(panel._preset_count_label, "Selected preset shows its tool count")
	assert_false(panel._preset_option.get_item_tooltip(1).is_empty(), "Dropdown items explain the preset on hover")
	assert_false(panel._preset_option.get_item_text(1).contains("\n"), "Profiles use concise single-line labels")
	assert_lte(panel._preset_option.custom_minimum_size.y, 42.0, "Larger profile selector stays compact")
	assert_gte(panel._preset_option.get_theme_font_size("font_size"), 15, "Profile selection matches editor text scale")
	assert_gte(panel._preset_description_label.get_theme_font_size("font_size"), 14, "Profile guidance remains legible")

func test_selecting_preset_refreshes_explanation_and_count():
	var panel: Node = _make_panel()
	var content: VBoxContainer = VBoxContainer.new()
	autofree(content)
	panel._build_preset_row(content)
	var index: int = panel._preset_manager.get_preset_ids().find("level_design")
	panel._preset_option.select(index)
	panel._on_preset_selected(index)
	assert_false(panel._preset_description_label.text.is_empty(), "Preset explanation is visible before applying")
	assert_string_contains(panel._preset_count_label.text, "80", "Level design preview reports enabled tool count")

func test_profile_dropdown_keeps_common_tasks_immediately_discoverable():
	var panel: Node = _make_panel()
	var content: VBoxContainer = VBoxContainer.new()
	autofree(content)
	panel._build_preset_row(content)
	assert_eq(panel._preset_option.item_count, 12, "All built-in task profiles remain available")
	var labels: String = ""
	for i in panel._preset_option.item_count:
		labels += panel._preset_option.get_item_text(i) + " "
	assert_string_contains(labels, "2D", "2D work is visible in the selector")
	assert_string_contains(labels, "3D", "3D work is visible in the selector")
	assert_string_contains(labels, "UI", "UI work is visible in the selector")
	assert_gte(panel._preset_label.get_theme_font_size("font_size"), 15, "Compact profile label matches editor text scale")

func test_tools_workspace_gives_detail_pane_a_real_sidebar_share():
	var panel: Node = _make_panel()
	var tools_tab: VBoxContainer = panel._create_tools_tab()
	add_child_autofree(tools_tab)
	tools_tab.size = Vector2(1600, 900)
	await get_tree().process_frame
	assert_not_null(panel._tools_middle_split, "Tool list and detail use an explicit responsive split")
	assert_true(
		panel._tool_list_pane.size_flags_horizontal == Control.SIZE_EXPAND_FILL,
		"Tool list participates in proportional layout"
	)
	assert_true(
		panel._tool_detail_panel.size_flags_horizontal == Control.SIZE_EXPAND_FILL,
		"Right sidebar participates in proportional layout"
	)
	assert_gte(panel._tool_detail_panel.custom_minimum_size.x, 380.0, "Right sidebar keeps a readable minimum width")
	assert_gte(panel._tool_list_pane.size_flags_stretch_ratio, 2.0, "Tool list remains the primary workspace")
	assert_gte(panel._tool_detail_panel.size_flags_stretch_ratio, 1.0, "Right sidebar receives a deliberate share")
	assert_lte(panel._tool_list_pane.size_flags_stretch_ratio, 3.0, "Right sidebar is not squeezed below roughly one quarter")
	var sidebar_share: float = panel._tool_detail_panel.size.x / panel._tools_middle_split.size.x
	assert_between(sidebar_share, 0.24, 0.38, "Desktop layout gives the detail sidebar about one quarter to one third")

func test_profile_toolbar_applies_a_task_without_unrelated_tools():
	var panel: Node = _make_panel()
	var content: VBoxContainer = VBoxContainer.new()
	autofree(content)
	panel._server_core = FakeServerCore.new()
	panel._build_preset_row(content)
	var index: int = panel._preset_manager.get_preset_ids().find("game_2d")
	panel._preset_option.select(index)
	panel._on_preset_selected(index)
	panel._on_apply_preset_pressed()
	assert_true(panel._server_core.states.get("create_node", false), "A task profile enables its required core tools")
	assert_false(panel._server_core.states.get("generate_3d_asset", true), "The 2D task leaves unrelated 3D tooling disabled")
	assert_string_contains(panel._preset_count_label.text, "47", "The compact toolbar reports the selected tool count")
