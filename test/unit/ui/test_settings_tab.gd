extends "res://addons/gut/test.gd"

# Tests for the card-based Settings tab layout (mcp_panel_native.gd).

const PanelScript = preload("res://addons/godot_mcp/ui/mcp_panel_native.gd")
const TranslationManagerScript = preload("res://addons/godot_mcp/native_mcp/translation_manager.gd")

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

func test_manual_path_field_is_always_visible_as_a_local_reuse_fallback() -> void:
	var panel: Node = _make_panel()
	autofree(panel._create_settings_tab())
	assert_not_null(panel._tunnel_binary_edit, "Manual cloudflared path field still exists")
	assert_true(panel._tunnel_binary_row.visible, "Every platform should allow selecting an existing local cloudflared binary")

func test_tunnel_start_uses_local_binary_resolution_before_download() -> void:
	var panel: Node = _make_panel()
	var source: String = panel.get_script().source_code
	assert_true(source.contains("resolve_local_binary"), "Tunnel start should probe configured, PATH, shared and legacy installs")

func test_panel_restores_tunnel_but_never_stops_it_during_exit() -> void:
	var panel: Node = _make_panel()
	var source: String = panel.get_script().source_code
	var exit_start: int = source.find("func _exit_tree()")
	var next_method: int = source.find("\nfunc ", exit_start + 1)
	var exit_body: String = source.substr(exit_start, next_method - exit_start)
	assert_true(source.contains("_restore_tunnel_session()"), "Panel should reattach after project or plugin reload")
	assert_true(exit_body.contains("_tunnel_manager.detach()"), "Panel exit should release local ownership only")
	assert_false(exit_body.contains("_tunnel_manager.stop()"), "Closing Godot must never stop a user-started tunnel")

func test_tunnel_status_retranslates_with_the_rest_of_the_chinese_ui() -> void:
	var panel: Node = _make_panel()
	panel._translation_manager = TranslationManagerScript.new()
	panel._translation_manager.load_all()
	panel._translation_manager.set_locale("en")
	autofree(panel._create_settings_tab())
	assert_true(panel._tunnel_status_label.text.begins_with("Tunnel"), "Fixture starts in English")

	panel._translation_manager.set_locale("zh")
	panel._refresh_translations()
	assert_eq(
		panel._tunnel_status_label.text,
		panel._tr("ui.tunnel_idle"),
		"Persistent tunnel status must switch language together with the panel"
	)
	assert_true(panel._tunnel_status_label.text.contains("隧道未运行"))
	panel._set_tunnel_status("ui.tunnel_starting", [3])
	assert_eq(panel._tunnel_status_label.text, "正在连接 Cloudflare... 已等待 3 秒")
	panel._set_tunnel_status("ui.tunnel_start_slow", [30, "C:/tunnel.log"])
	assert_true(panel._tunnel_status_label.text.contains("监督进程仍在自动恢复"))
	assert_false(panel._tunnel_status_label.text.contains("Tunnel is taking longer"))
	panel._set_tunnel_status("ui.tunnel_downloading", [1, 3, "2.5/51.6 MiB", 12])
	assert_eq(
		panel._tunnel_status_label.text,
		"正在下载 cloudflared（来源 1/3；2.5/51.6 MiB；停滞 12 秒自动切源）..."
	)

func test_tunnel_start_has_bounded_waits_and_visible_diagnostics() -> void:
	var panel: Node = _make_panel()
	var source: String = panel.get_script().source_code
	assert_true(source.contains("CLOUDFLARED_DOWNLOAD_STALL_SECONDS"), "Stalled sources should switch quickly without rejecting a progressing slow download")
	assert_true(source.contains("TUNNEL_CONNECT_SLOW_WARNING_SECONDS"), "Slow Quick Tunnel provisioning should become visible")
	assert_true(source.contains("_tunnel_http.timeout = 0.0"), "Large downloads use the progress watchdog instead of a fragile total timeout")
	assert_true(source.contains("_on_tunnel_download_watchdog"), "Download progress and source switching must be monitored")
	assert_true(source.contains("ui.tunnel_start_slow"), "A slow connection must remain visible without being killed")
	assert_true(source.contains("_record_tunnel_event"), "Tunnel stages and failures must be written to the MCP log")
	var poll_start: int = source.find("func _on_tunnel_poll_timeout()")
	var poll_end: int = source.find("func _set_tunnel_status_live", poll_start)
	var poll_body: String = source.substr(poll_start, poll_end - poll_start)
	assert_false(
		poll_body.contains("_tunnel_manager.stop()"),
		"A live cloudflared process must never be force-stopped only because URL discovery exceeded 30 seconds"
	)
	assert_true(
		PanelScript.should_switch_cloudflared_download(0, 5000, 12000, false),
		"A source with no progress must stop even when it is the final fallback"
	)
	assert_true(
		PanelScript.should_switch_cloudflared_download(1024, 12000, 1000, true),
		"A very slow source should give a remaining mirror a chance"
	)
	assert_false(
		PanelScript.should_switch_cloudflared_download(1024, 12000, 1000, false),
		"The final source may continue while bytes are still arriving"
	)
	assert_false(
		PanelScript.should_switch_cloudflared_download(8 * 1024 * 1024, 12000, 1000, true),
		"A healthy download must not be replaced"
	)

func test_settings_exposes_asset_provider_card() -> void:
	var panel: Node = _make_panel()
	autofree(panel._create_settings_tab())
	assert_not_null(panel._asset_provider_option, "Asset provider dropdown created")
	assert_not_null(panel._asset_key_env_edit, "API key env-var field created")
	# 1 'none' entry + one per built-in preset.
	assert_eq(panel._asset_provider_option.item_count, AssetProviderPresets.preset_ids().size() + 1, "Provider dropdown lists none + every preset")
	assert_eq(panel._selected_asset_preset_id(), "", "Defaults to 'none' (offline placeholder)")

func test_asset_provider_card_relabels_on_locale_switch() -> void:
	var panel: Node = _make_panel()
	autofree(panel._create_settings_tab())
	# Inject a real translation manager (the bare panel stub has none) so the
	# locale switch path is exercised instead of crashing on a null manager.
	panel._translation_manager = load("res://addons/godot_mcp/native_mcp/translation_manager.gd").new()
	panel._translation_manager.set_locale("zh")
	panel._refresh_translations()
	assert_eq(panel._asset_provider_label.text, panel._tr("ui.asset_provider"), "provider label refreshed to active locale")
	assert_eq(panel._asset_key_env_label.text, panel._tr("ui.asset_key_env"), "key-env label refreshed")
	assert_eq(panel._asset_endpoint_label.text, panel._tr("ui.asset_endpoint"), "endpoint label refreshed")
	assert_eq(panel._asset_key_env_edit.placeholder_text, panel._tr("ui.asset_key_env_placeholder"), "key-env placeholder refreshed")
	assert_eq(panel._asset_endpoint_edit.placeholder_text, panel._tr("ui.asset_endpoint_placeholder"), "endpoint placeholder refreshed")
	assert_eq(panel._asset_provider_option.get_item_text(0), panel._tr("ui.asset_provider_none"), "'none' dropdown item refreshed")
	assert_not_null(panel._asset_provider_hint_label, "hint is a member var so it can be refreshed")
	assert_eq(panel._asset_provider_hint_label.text, panel._tr("ui.asset_provider_hint"), "hint refreshed")

func test_settings_exposes_log_actions() -> void:
	var panel: Node = _make_panel()
	autofree(panel._create_settings_tab())
	assert_not_null(panel._open_log_button, "Open-log button created")
	assert_not_null(panel._clear_log_button, "Clear-log button created")
