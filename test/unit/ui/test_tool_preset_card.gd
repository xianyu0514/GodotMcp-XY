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

func test_quick_start_explains_the_workflow_and_exposes_task_buttons():
	var panel: Node = _make_panel()
	var content: VBoxContainer = VBoxContainer.new()
	autofree(content)
	panel._build_quick_start(content)
	assert_eq(content.get_child_count(), 1, "Quick start is a single prominent card")
	assert_not_null(panel._quick_start_title_label, "Quick start has a visible question")
	assert_gte(panel._quick_start_title_label.get_theme_font_size("font_size"), 18, "Quick-start title is readable")
	assert_not_null(panel._quick_start_hint_label, "The three-step workflow is explained")
	assert_string_contains(panel._quick_start_hint_label.text, "1", "Workflow visibly starts at step 1")
	assert_eq(panel._quick_start_buttons.size(), 6, "Six common user tasks are available without opening a dropdown")
	for button in panel._quick_start_buttons.values():
		assert_gte(button.custom_minimum_size.y, 52.0, "Task buttons are large enough to scan and click")
		assert_gte(button.get_theme_font_size("font_size"), 14, "Task-button labels are readable")

func test_quick_start_applies_a_task_profile_and_reports_the_next_step():
	var panel: Node = _make_panel()
	var content: VBoxContainer = VBoxContainer.new()
	autofree(content)
	panel._server_core = FakeServerCore.new()
	panel._build_quick_start(content)
	panel._on_quick_start_pressed("game_2d")
	assert_true(panel._server_core.states.get("create_node", false), "A quick task enables its required core tools")
	assert_false(panel._server_core.states.get("generate_3d_asset", true), "The 2D task leaves unrelated 3D tooling disabled")
	assert_false(panel._quick_start_status_label.text.is_empty(), "Applying a task produces visible feedback")
	assert_string_contains(panel._quick_start_status_label.text, "2D", "Feedback identifies the selected task")
