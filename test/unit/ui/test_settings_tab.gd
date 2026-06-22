extends "res://addons/gut/test.gd"

# Tests for the card-based Settings tab layout (mcp_panel_native.gd).

const PanelScript = preload("res://addons/godot_mcp/ui/mcp_panel_native.gd")

func _make_panel() -> Node:
	var panel: Node = PanelScript.new()
	autofree(panel)
	return panel

func _settings_content(panel: Node) -> VBoxContainer:
	var tab: VBoxContainer = panel._create_settings_tab()
	autofree(tab)
	var scroll: Node = tab.get_child(0)
	var margin: Node = scroll.get_child(0)
	return margin.get_child(0)

func test_settings_tab_groups_into_cards() -> void:
	var panel: Node = _make_panel()
	var content: VBoxContainer = _settings_content(panel)
	var cards: int = 0
	for child in content.get_children():
		if child is PanelContainer:
			cards += 1
	assert_eq(cards, 6, "Settings group into connection / transport / behavior / security / remote / general cards")

func test_settings_registers_section_titles() -> void:
	var panel: Node = _make_panel()
	autofree(panel._create_settings_tab())
	assert_eq(panel._section_titles.size(), 5, "Relabelable section titles registered for refresh")

func test_settings_exposes_log_actions() -> void:
	var panel: Node = _make_panel()
	autofree(panel._create_settings_tab())
	assert_not_null(panel._open_log_button, "Open-log button created")
	assert_not_null(panel._clear_log_button, "Clear-log button created")
