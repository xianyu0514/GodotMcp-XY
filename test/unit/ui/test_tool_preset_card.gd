extends "res://addons/gut/test.gd"

const PanelScript = preload("res://addons/godot_mcp/ui/mcp_panel_native.gd")
const PresetManagerScript = preload("res://addons/godot_mcp/native_mcp/mcp_tool_preset_manager.gd")

func _make_panel() -> Node:
	var panel: Node = PanelScript.new()
	panel._preset_manager = PresetManagerScript.new()
	panel._translation_manager = MCPTranslationManager.new()
	panel._translation_manager.load_all()
	autofree(panel)
	return panel

func test_preset_controls_live_in_a_responsive_card():
	var panel: Node = _make_panel()
	var content: VBoxContainer = VBoxContainer.new()
	autofree(content)
	panel._build_preset_row(content)
	assert_eq(content.get_child_count(), 1, "Preset area is one cohesive block")
	assert_true(content.get_child(0) is PanelContainer, "Preset controls use a card container")
	assert_true(panel._preset_option.size_flags_horizontal == Control.SIZE_EXPAND_FILL, "Dropdown expands in narrow docks")
	assert_not_null(panel._preset_description_label, "Selected preset has an explanation")
	assert_not_null(panel._preset_count_label, "Selected preset shows its tool count")
	assert_false(panel._preset_option.get_item_tooltip(1).is_empty(), "Dropdown items explain the preset on hover")

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
