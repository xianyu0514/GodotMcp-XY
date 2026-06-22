extends "res://addons/gut/test.gd"

# Tests for the card-based Settings tab layout (mcp_panel_native.gd).

const PanelScript = preload("res://addons/godot_mcp/ui/mcp_panel_native.gd")
const ProviderScript = preload("res://addons/godot_mcp/native_mcp/mcp_cloudflared_provider.gd")

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
	assert_eq(cards, 7, "Settings group into connection / transport / behavior / security / remote / asset generation / general cards")

func test_settings_registers_section_titles() -> void:
	var panel: Node = _make_panel()
	autofree(panel._create_settings_tab())
	assert_eq(panel._section_titles.size(), 6, "Relabelable section titles registered for refresh")

func test_manual_path_field_visibility_matches_platform_support() -> void:
	var panel: Node = _make_panel()
	autofree(panel._create_settings_tab())
	assert_not_null(panel._tunnel_binary_edit, "Manual cloudflared path field still exists")
	var supported: bool = not ProviderScript.detect_platform_key().is_empty()
	assert_eq(panel._tunnel_binary_row.visible, not supported, "Manual path row visible only when no prebuilt binary exists")

func test_settings_exposes_asset_provider_card() -> void:
	var panel: Node = _make_panel()
	autofree(panel._create_settings_tab())
	assert_not_null(panel._asset_provider_option, "Asset provider dropdown created")
	assert_not_null(panel._asset_key_env_edit, "API key env-var field created")
	# 1 'none' entry + one per built-in preset.
	assert_eq(panel._asset_provider_option.item_count, AssetProviderPresets.preset_ids().size() + 1, "Provider dropdown lists none + every preset")
	assert_eq(panel._selected_asset_preset_id(), "", "Defaults to 'none' (offline placeholder)")

func test_settings_exposes_log_actions() -> void:
	var panel: Node = _make_panel()
	autofree(panel._create_settings_tab())
	assert_not_null(panel._open_log_button, "Open-log button created")
	assert_not_null(panel._clear_log_button, "Clear-log button created")
