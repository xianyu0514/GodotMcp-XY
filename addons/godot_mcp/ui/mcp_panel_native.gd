@tool
extends VBoxContainer

var _plugin: EditorPlugin = null
var _server_core: RefCounted = null

var _status_label: Label = null
var _start_button: Button = null
var _stop_button: Button = null
var _auto_start_check: CheckBox = null
var _vibe_coding_mode_check: CheckBox = null
var _log_level_option: OptionButton = null
var _security_level_option: OptionButton = null
var _tools_list_container: VBoxContainer = null
var _tools_count_label: Label = null

var _transport_mode_option: OptionButton = null
var _http_config_container: VBoxContainer = null
var _http_port_spin: SpinBox = null
var _auth_enabled_check: CheckBox = null
var _auth_token_edit: LineEdit = null
var _sse_enabled_check: CheckBox = null
var _allow_remote_check: CheckBox = null
var _cors_origin_edit: LineEdit = null
var _rate_limit_spin: SpinBox = null
var _connection_info_label: Label = null

var _transport_title_label: Label = null
var _transport_mode_label: Label = null
var _http_port_label: Label = null
var _auth_token_label: Label = null
var _cors_origin_label: Label = null
var _log_level_label: Label = null
var _security_label: Label = null
var _rate_limit_label: Label = null
var _language_label: Label = null
var _refresh_tools_button: Button = null
var _open_log_button: Button = null
var _clear_log_button: Button = null
var _copy_config_button: MenuButton = null
var _self_check_button: Button = null
var _self_check_http: HTTPRequest = null
var _self_check_dialog: AcceptDialog = null

var _connection_title_label: Label = null
var _connection_hint_label: Label = null
var _local_endpoint_label: Label = null
var _local_endpoint_edit: LineEdit = null
var _local_endpoint_copy_button: Button = null
var _client_config_label: Label = null
var _public_endpoint_card: PanelContainer = null
var _public_endpoint_title_label: Label = null
var _public_endpoint_hint_label: Label = null
var _public_endpoint_edit: LineEdit = null
var _public_endpoint_copy_button: Button = null
var _remote_title_label: Label = null
var _remote_hint_label: Label = null
var _remote_url_label: Label = null
var _remote_url_edit: LineEdit = null
var _remote_copy_http_button: Button = null
var _remote_copy_bridge_button: Button = null
var _remote_copy_tunnel_button: Button = null
var _tunnel_start_button: Button = null
var _tunnel_stop_button: Button = null
var _tunnel_status_label: Label = null
var _tunnel_binary_row: HBoxContainer = null
var _tunnel_binary_label: Label = null
var _tunnel_binary_edit: LineEdit = null
var _tunnel_manager: MCPTunnelManager = null
var _tunnel_http: HTTPRequest = null
var _tunnel_poll_timer: Timer = null
var _tunnel_platform_key: String = ""
var _tunnel_download_urls: PackedStringArray = []
var _tunnel_download_index: int = 0
var _status_dot: Panel = null
var _section_titles: Array = []

var _tab_container: TabContainer = null
var _debounce_timer: Timer = null
var _group_widgets: Dictionary = {}
var _tools_search_edit: LineEdit = null
var _core_group_names: Array = []
var _supp_group_names: Array = []
var _category_nav_container: VBoxContainer = null
var _nav_group: ButtonGroup = null
var _nav_items: Dictionary = {}
var _scope_chip_group: ButtonGroup = null
var _scope_chips: Dictionary = {}
var _selected_category: String = "__recommended__"
var _detail_title: Label = null
var _detail_desc: Label = null
var _detail_count: Label = null
var _enable_all_button: Button = null
var _disable_all_button: Button = null
var _tool_detail_panel: MCPToolDetailPanel = null
var _selected_tool_name: String = ""
var _language_option: OptionButton = null

var _asset_provider_label: Label = null
var _asset_provider_option: OptionButton = null
var _asset_key_env_label: Label = null
var _asset_key_env_edit: LineEdit = null
var _asset_endpoint_label: Label = null
var _asset_endpoint_edit: LineEdit = null

var _preset_manager = null
var _preset_label: Label = null
var _preset_option: OptionButton = null
var _apply_preset_button: Button = null
var _export_preset_button: Button = null
var _import_preset_button: Button = null
var _preset_file_dialog: FileDialog = null
var _preset_dialog_save: bool = false

var _log_file_path: String = "user://mcp_server.log"
var _log_file_flush_count: int = 10
var _log_pending_write: Array[String] = []
var _log_file_initialized: bool = false
var _max_log_file_size: int = 5242880

var _translation_manager: MCPTranslationManager = null
var _settings_manager: MCPSettingsManager = null

func _ready() -> void:
	_translation_manager = MCPTranslationManager.new()
	_translation_manager.load_all()
	_settings_manager = MCPSettingsManager.new()
	_preset_manager = MCPToolPresetManager.new()
	_create_ui()
	_debounce_timer = Timer.new()
	_debounce_timer.one_shot = true
	_debounce_timer.timeout.connect(_on_debounce_timeout)
	add_child(_debounce_timer)

func _exit_tree() -> void:
	_flush_log_to_file()
	if _debounce_timer:
		_debounce_timer.stop()
	if _tunnel_poll_timer and is_instance_valid(_tunnel_poll_timer):
		_tunnel_poll_timer.stop()
	if _tunnel_manager and _tunnel_manager.is_running():
		_tunnel_manager.stop()

func set_plugin(plugin: EditorPlugin) -> void:
	_plugin = plugin
	if _translation_manager == null:
		_translation_manager = MCPTranslationManager.new()
		_translation_manager.load_all()
	if _settings_manager == null:
		_settings_manager = MCPSettingsManager.new()
	if _preset_manager == null:
		_preset_manager = MCPToolPresetManager.new()
	if _plugin and _plugin.has_method("get_native_server"):
		_server_core = _plugin.get_native_server()
	_load_settings()
	_refresh_translations()

func set_server_core(server_core: RefCounted) -> void:
	_server_core = server_core
	_update_ui_state()
	_refresh_tools_list()

func _tr(key: String) -> String:
	if _translation_manager:
		return _translation_manager.get_text(key)
	return key

func _trf(key: String, args: Array) -> String:
	var text: String = _tr(key)
	var placeholder_count: int = 0
	for i in text.length():
		if text[i] == "%":
			i += 1
			if i < text.length() and text[i] in "dsf":
				placeholder_count += 1
	if placeholder_count > 0 and placeholder_count == args.size():
		return text % args
	return text

func _create_ui() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	size_flags_horizontal = Control.SIZE_EXPAND_FILL

	add_child(_create_status_bar())

	_tab_container = TabContainer.new()
	_tab_container.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_tab_container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tab_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_child(_tab_container)

	var settings_tab: VBoxContainer = _create_settings_tab()
	var tools_tab: VBoxContainer = _create_tools_tab()

	_tab_container.add_child(settings_tab)
	_tab_container.add_child(tools_tab)

	_tab_container.set_tab_title(0, _tr("ui.settings"))
	_tab_container.set_tab_title(1, _tr("ui.tool_manager"))

	_update_ui_state()
	_refresh_tools_list()

func _create_status_bar() -> Control:
	var frame: PanelContainer = PanelContainer.new()
	frame.add_theme_stylebox_override("panel", _banner_style())

	var bar: HBoxContainer = HBoxContainer.new()
	bar.add_theme_constant_override("separation", 8)
	frame.add_child(bar)

	_status_dot = Panel.new()
	_status_dot.custom_minimum_size = Vector2(10, 10)
	_status_dot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_status_dot.add_theme_stylebox_override("panel", _dot_style(Color(0.55, 0.55, 0.6)))
	bar.add_child(_status_dot)

	_status_label = Label.new()
	_status_label.text = _tr("ui.status_unknown")
	_status_label.add_theme_font_size_override("font_size", 14)
	_status_label.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	bar.add_child(_status_label)

	_connection_info_label = Label.new()
	_connection_info_label.autowrap_mode = TextServer.AUTOWRAP_WORD
	_connection_info_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_connection_info_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	bar.add_child(_connection_info_label)

	_self_check_button = Button.new()
	_self_check_button.text = _tr("ui.self_check")
	_self_check_button.flat = true
	_self_check_button.pressed.connect(_on_self_check_pressed)
	bar.add_child(_self_check_button)

	_start_button = Button.new()
	_start_button.text = _tr("ui.start_server")
	_start_button.pressed.connect(_on_start_pressed)
	bar.add_child(_start_button)

	_stop_button = Button.new()
	_stop_button.text = _tr("ui.stop_server")
	_stop_button.pressed.connect(_on_stop_pressed)
	bar.add_child(_stop_button)

	return frame

func _banner_style() -> StyleBoxFlat:
	var style: StyleBoxFlat = StyleBoxFlat.new()
	style.bg_color = Color(1, 1, 1, 0.03)
	style.border_color = Color(1, 1, 1, 0.07)
	style.set_border_width_all(1)
	style.set_corner_radius_all(6)
	style.content_margin_left = 12
	style.content_margin_right = 12
	style.content_margin_top = 8
	style.content_margin_bottom = 8
	return style

func _dot_style(color: Color) -> StyleBoxFlat:
	var style: StyleBoxFlat = StyleBoxFlat.new()
	style.bg_color = color
	style.set_corner_radius_all(5)
	return style

func _on_copy_local_endpoint_pressed() -> void:
	DisplayServer.clipboard_set(MCPClientConfig.local_mcp_endpoint(_current_port()))
	_flash_button(_local_endpoint_copy_button, "ui.copy")

func _current_port() -> int:
	var port: int = 9080
	if _plugin and _plugin.get("http_port") != null:
		port = _plugin.http_port
	elif _http_port_spin:
		port = int(_http_port_spin.value)
	return port

func _current_transport() -> String:
	if _plugin and _plugin.get("transport_mode") != null:
		return _plugin.transport_mode
	if _transport_mode_option:
		return _transport_mode_option.get_item_text(_transport_mode_option.selected)
	return "http"

func _current_auth_token() -> String:
	if _auth_enabled_check and _auth_enabled_check.button_pressed and _auth_token_edit:
		return _auth_token_edit.text
	return ""

func _on_copy_config_id_pressed(id: int) -> void:
	var text: String = ""
	if id == 1:
		var exe: String = OS.get_executable_path()
		var project_dir: String = ProjectSettings.globalize_path("res://")
		text = MCPClientConfig.stdio_config(exe, project_dir)
	else:
		text = MCPClientConfig.http_config(_current_port(), _current_auth_token())
	DisplayServer.clipboard_set(text)
	if _copy_config_button:
		_copy_config_button.text = _tr("ui.copied")
		await get_tree().create_timer(1.2).timeout
		if is_instance_valid(_copy_config_button):
			_copy_config_button.text = _tr("ui.copy_config")

func _on_self_check_pressed() -> void:
	var running: bool = false
	if _server_core and _server_core.has_method("is_running"):
		running = _server_core.is_running()
	if not running:
		_show_self_check(_tr("ui.check_not_running"))
		return
	if _current_transport() != "http":
		_show_self_check(_tr("ui.check_stdio"))
		return
	if _self_check_http == null or not is_instance_valid(_self_check_http):
		_self_check_http = HTTPRequest.new()
		add_child(_self_check_http)
		_self_check_http.request_completed.connect(_on_self_check_completed)
	if _self_check_button:
		_self_check_button.disabled = true
	var url: String = "http://127.0.0.1:%d/" % _current_port()
	var err: int = _self_check_http.request(url, PackedStringArray(), HTTPClient.METHOD_GET)
	if err != OK:
		if _self_check_button:
			_self_check_button.disabled = false
		_show_self_check(_tr("ui.check_failed"))

func _on_self_check_completed(result: int, response_code: int, _headers: PackedStringArray, _body: PackedByteArray) -> void:
	if _self_check_button:
		_self_check_button.disabled = false
	if result == HTTPRequest.RESULT_SUCCESS and response_code > 0:
		_show_self_check(_trf("ui.check_ok", [response_code]))
	else:
		_show_self_check(_tr("ui.check_failed"))

func _show_self_check(message: String) -> void:
	if _self_check_dialog == null or not is_instance_valid(_self_check_dialog):
		_self_check_dialog = AcceptDialog.new()
		_self_check_dialog.title = _tr("ui.self_check")
		add_child(_self_check_dialog)
	_self_check_dialog.title = _tr("ui.self_check")
	_self_check_dialog.dialog_text = message
	_self_check_dialog.popup_centered()

func _create_settings_tab() -> VBoxContainer:
	var tab: VBoxContainer = VBoxContainer.new()
	tab.size_flags_vertical = Control.SIZE_EXPAND_FILL
	tab.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var scroll: ScrollContainer = ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tab.add_child(scroll)

	var margin: MarginContainer = MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 12)
	margin.add_theme_constant_override("margin_right", 12)
	margin.add_theme_constant_override("margin_top", 10)
	margin.add_theme_constant_override("margin_bottom", 10)
	margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(margin)

	var content: VBoxContainer = VBoxContainer.new()
	content.add_theme_constant_override("separation", 10)
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	margin.add_child(content)

	_section_titles.clear()
	_build_connection_card(content)
	_build_transport_card(content)
	_build_behavior_card(content)
	_build_security_card(content)
	_build_remote_card(content)
	_build_asset_provider_card(content)
	_build_general_card(content)

	return tab

func _build_connection_card(content: VBoxContainer) -> void:
	_connection_title_label = Label.new()
	_connection_title_label.text = _tr("ui.section_connection")
	var body: VBoxContainer = _settings_card(content, _connection_title_label)
	_register_section_title(_connection_title_label, "ui.section_connection")

	_connection_hint_label = Label.new()
	_connection_hint_label.text = _tr("ui.connection_hint")
	_connection_hint_label.autowrap_mode = TextServer.AUTOWRAP_WORD
	_connection_hint_label.add_theme_color_override("font_color", Color(0.72, 0.72, 0.76))
	body.add_child(_connection_hint_label)

	_local_endpoint_label = Label.new()
	_local_endpoint_label.text = _tr("ui.local_endpoint")
	_local_endpoint_edit = _make_readonly_url_edit()
	_local_endpoint_copy_button = Button.new()
	_local_endpoint_copy_button.text = _tr("ui.copy")
	_local_endpoint_copy_button.pressed.connect(_on_copy_local_endpoint_pressed)
	_build_url_row(body, _local_endpoint_label, _local_endpoint_edit, _local_endpoint_copy_button)

	_client_config_label = Label.new()
	_client_config_label.text = _tr("ui.client_config")
	_copy_config_button = MenuButton.new()
	_copy_config_button.text = _tr("ui.copy_config")
	_copy_config_button.flat = false
	var config_popup: PopupMenu = _copy_config_button.get_popup()
	config_popup.add_item(_tr("ui.copy_config_http"), 0)
	config_popup.add_item(_tr("ui.copy_config_stdio"), 1)
	config_popup.id_pressed.connect(_on_copy_config_id_pressed)
	_settings_row(body, _client_config_label, _copy_config_button, false)

	_update_local_endpoint()

## Read-only LineEdit styled as a copyable address field (text stays selectable).
func _make_readonly_url_edit() -> LineEdit:
	var edit: LineEdit = LineEdit.new()
	edit.editable = false
	edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	edit.add_theme_color_override("font_color", Color(0.85, 0.9, 1.0))
	edit.add_theme_color_override("font_uneditable_color", Color(0.85, 0.9, 1.0))
	return edit

## Row layout: label + read-only address field that expands + copy button.
func _build_url_row(parent: VBoxContainer, label: Label, edit: LineEdit, copy_button: Button) -> void:
	var row: HBoxContainer = HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	parent.add_child(row)

	label.custom_minimum_size = Vector2(120, 0)
	label.add_theme_color_override("font_color", Color(0.78, 0.78, 0.82))
	row.add_child(label)

	edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(edit)
	row.add_child(copy_button)

## Sets the local endpoint field to the current HTTP URL, or a stdio note.
func _update_local_endpoint() -> void:
	if not _local_endpoint_edit:
		return
	if _current_transport() == "http":
		_local_endpoint_edit.text = MCPClientConfig.local_mcp_endpoint(_current_port())
		if _local_endpoint_copy_button:
			_local_endpoint_copy_button.disabled = false
	else:
		_local_endpoint_edit.text = _tr("ui.endpoint_stdio")
		if _local_endpoint_copy_button:
			_local_endpoint_copy_button.disabled = true

func _build_remote_card(content: VBoxContainer) -> void:
	_remote_title_label = Label.new()
	_remote_title_label.text = _tr("ui.section_remote")
	var body: VBoxContainer = _settings_card(content, _remote_title_label)
	_register_section_title(_remote_title_label, "ui.section_remote")

	_remote_hint_label = Label.new()
	_remote_hint_label.text = _tr("ui.remote_hint")
	_remote_hint_label.autowrap_mode = TextServer.AUTOWRAP_WORD
	_remote_hint_label.add_theme_color_override("font_color", Color(0.72, 0.72, 0.76))
	body.add_child(_remote_hint_label)

	var tunnel_buttons: HBoxContainer = HBoxContainer.new()
	tunnel_buttons.add_theme_constant_override("separation", 8)
	body.add_child(tunnel_buttons)

	_tunnel_start_button = Button.new()
	_tunnel_start_button.text = _tr("ui.tunnel_start")
	_tunnel_start_button.pressed.connect(_on_tunnel_start_pressed)
	_make_primary_button(_tunnel_start_button)
	tunnel_buttons.add_child(_tunnel_start_button)

	_tunnel_stop_button = Button.new()
	_tunnel_stop_button.text = _tr("ui.tunnel_stop")
	_tunnel_stop_button.disabled = true
	_tunnel_stop_button.pressed.connect(_on_tunnel_stop_pressed)
	tunnel_buttons.add_child(_tunnel_stop_button)

	_tunnel_status_label = Label.new()
	_tunnel_status_label.text = _tr("ui.tunnel_idle")
	_tunnel_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD
	_tunnel_status_label.add_theme_color_override("font_color", Color(0.72, 0.72, 0.76))
	body.add_child(_tunnel_status_label)

	# Manual cloudflared path: a fallback shown only on platforms without a
	# prebuilt binary, where auto-download/launch cannot work.
	_tunnel_binary_row = HBoxContainer.new()
	_tunnel_binary_row.add_theme_constant_override("separation", 10)
	body.add_child(_tunnel_binary_row)
	_tunnel_binary_label = Label.new()
	_tunnel_binary_label.text = _tr("ui.tunnel_binary")
	_tunnel_binary_label.custom_minimum_size = Vector2(120, 0)
	_tunnel_binary_label.add_theme_color_override("font_color", Color(0.78, 0.78, 0.82))
	_tunnel_binary_row.add_child(_tunnel_binary_label)
	_tunnel_binary_edit = LineEdit.new()
	_tunnel_binary_edit.placeholder_text = _tr("ui.tunnel_binary_placeholder")
	_tunnel_binary_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_tunnel_binary_edit.text_changed.connect(_on_tunnel_binary_changed)
	_tunnel_binary_row.add_child(_tunnel_binary_edit)
	_tunnel_binary_row.visible = MCPCloudflaredProvider.detect_platform_key().is_empty()

	_remote_url_label = Label.new()
	_remote_url_label.text = _tr("ui.remote_url")
	_remote_url_edit = LineEdit.new()
	_remote_url_edit.placeholder_text = _tr("ui.remote_url_placeholder")
	_remote_url_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_remote_url_edit.text_changed.connect(_on_remote_url_changed)
	_settings_row(body, _remote_url_label, _remote_url_edit, true)

	_build_public_endpoint_card(body)

	var buttons: HBoxContainer = HBoxContainer.new()
	buttons.add_theme_constant_override("separation", 8)
	body.add_child(buttons)

	_remote_copy_http_button = Button.new()
	_remote_copy_http_button.text = _tr("ui.remote_copy_http")
	_remote_copy_http_button.pressed.connect(_on_remote_copy_http_pressed)
	buttons.add_child(_remote_copy_http_button)

	_remote_copy_bridge_button = Button.new()
	_remote_copy_bridge_button.text = _tr("ui.remote_copy_bridge")
	_remote_copy_bridge_button.pressed.connect(_on_remote_copy_bridge_pressed)
	buttons.add_child(_remote_copy_bridge_button)

	var spacer: Control = Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	buttons.add_child(spacer)

	_remote_copy_tunnel_button = Button.new()
	_remote_copy_tunnel_button.text = _tr("ui.remote_copy_tunnel")
	_remote_copy_tunnel_button.flat = true
	_remote_copy_tunnel_button.pressed.connect(_on_remote_copy_tunnel_pressed)
	buttons.add_child(_remote_copy_tunnel_button)

## Highlighted, auto-revealed card showing the ready-to-use public MCP endpoint
## (tunnel base + /mcp). Hidden until a public URL is available.
func _build_public_endpoint_card(parent: VBoxContainer) -> void:
	_public_endpoint_card = PanelContainer.new()
	_public_endpoint_card.add_theme_stylebox_override("panel", _accent_card_style())
	_public_endpoint_card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_public_endpoint_card.visible = false
	parent.add_child(_public_endpoint_card)

	var box: VBoxContainer = VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	_public_endpoint_card.add_child(box)

	_public_endpoint_title_label = Label.new()
	_public_endpoint_title_label.text = _tr("ui.public_endpoint")
	_public_endpoint_title_label.add_theme_font_size_override("font_size", 13)
	_public_endpoint_title_label.add_theme_color_override("font_color", Color(0.5, 0.86, 0.55))
	box.add_child(_public_endpoint_title_label)

	var row: HBoxContainer = HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	box.add_child(row)

	_public_endpoint_edit = _make_readonly_url_edit()
	_public_endpoint_edit.add_theme_color_override("font_color", Color(0.7, 0.96, 0.74))
	_public_endpoint_edit.add_theme_color_override("font_uneditable_color", Color(0.7, 0.96, 0.74))
	row.add_child(_public_endpoint_edit)

	_public_endpoint_copy_button = Button.new()
	_public_endpoint_copy_button.text = _tr("ui.copy")
	_public_endpoint_copy_button.pressed.connect(_on_copy_public_endpoint_pressed)
	row.add_child(_public_endpoint_copy_button)

	_public_endpoint_hint_label = Label.new()
	_public_endpoint_hint_label.text = _tr("ui.public_endpoint_hint")
	_public_endpoint_hint_label.autowrap_mode = TextServer.AUTOWRAP_WORD
	_public_endpoint_hint_label.add_theme_color_override("font_color", Color(0.62, 0.78, 0.64))
	box.add_child(_public_endpoint_hint_label)

func _accent_card_style() -> StyleBoxFlat:
	var style: StyleBoxFlat = StyleBoxFlat.new()
	style.bg_color = Color(0.36, 0.78, 0.42, 0.12)
	style.border_color = Color(0.36, 0.78, 0.42, 0.55)
	style.set_border_width_all(1)
	style.set_corner_radius_all(6)
	style.content_margin_left = 14
	style.content_margin_right = 14
	style.content_margin_top = 12
	style.content_margin_bottom = 12
	return style

func _button_fill_style(bg: Color) -> StyleBoxFlat:
	var style: StyleBoxFlat = StyleBoxFlat.new()
	style.bg_color = bg
	style.set_corner_radius_all(5)
	style.content_margin_left = 16
	style.content_margin_right = 16
	style.content_margin_top = 7
	style.content_margin_bottom = 7
	return style

## Styles a button as the green primary action (matches the ready-state accent).
func _make_primary_button(button: Button) -> void:
	var base: Color = Color(0.30, 0.66, 0.38)
	button.add_theme_stylebox_override("normal", _button_fill_style(base))
	button.add_theme_stylebox_override("hover", _button_fill_style(base.lightened(0.10)))
	button.add_theme_stylebox_override("pressed", _button_fill_style(base.darkened(0.12)))
	button.add_theme_color_override("font_color", Color(0.96, 1.0, 0.97))
	button.add_theme_color_override("font_hover_color", Color(1, 1, 1))

## Reveals/updates the public endpoint card from the current remote base URL.
func _update_public_endpoint() -> void:
	if not _public_endpoint_card:
		return
	var base: String = _remote_base_url().strip_edges()
	if base.is_empty():
		_public_endpoint_card.visible = false
		return
	_public_endpoint_card.visible = true
	if _public_endpoint_edit:
		_public_endpoint_edit.text = MCPClientConfig.public_mcp_endpoint(base)

func _on_remote_url_changed(_text: String) -> void:
	_update_public_endpoint()

func _on_copy_public_endpoint_pressed() -> void:
	DisplayServer.clipboard_set(MCPClientConfig.public_mcp_endpoint(_remote_base_url()))
	_flash_button(_public_endpoint_copy_button, "ui.copy")

func _flash_button(button: Button, restore_key: String) -> void:
	if button == null:
		return
	button.text = _tr("ui.copied")
	await get_tree().create_timer(1.2).timeout
	if is_instance_valid(button):
		button.text = _tr(restore_key)

func _remote_base_url() -> String:
	if _remote_url_edit:
		return _remote_url_edit.text
	return ""

func _on_remote_copy_http_pressed() -> void:
	var text: String = MCPClientConfig.remote_http_config(_remote_base_url(), _current_auth_token())
	DisplayServer.clipboard_set(text)
	_flash_button(_remote_copy_http_button, "ui.remote_copy_http")

func _on_remote_copy_bridge_pressed() -> void:
	var text: String = MCPClientConfig.remote_stdio_bridge_config(_remote_base_url(), _current_auth_token())
	DisplayServer.clipboard_set(text)
	_flash_button(_remote_copy_bridge_button, "ui.remote_copy_bridge")

func _on_remote_copy_tunnel_pressed() -> void:
	DisplayServer.clipboard_set(MCPClientConfig.cloudflared_command(_current_port()))
	_flash_button(_remote_copy_tunnel_button, "ui.remote_copy_tunnel")

func _set_tunnel_status(key: String) -> void:
	if _tunnel_status_label:
		_tunnel_status_label.text = _tr(key)

func _override_binary_path() -> String:
	if _tunnel_binary_edit:
		return _tunnel_binary_edit.text.strip_edges()
	return ""

func _on_tunnel_binary_changed(_text: String) -> void:
	_debounce_save()

func _on_tunnel_start_pressed() -> void:
	if _tunnel_manager == null:
		_tunnel_manager = MCPTunnelManager.new()
	if _tunnel_manager.is_running():
		_set_tunnel_status("ui.tunnel_already")
		return

	# Manual override (shown only on unsupported platforms): launch directly.
	var override: String = _override_binary_path()
	if not override.is_empty():
		if not FileAccess.file_exists(override):
			_set_tunnel_status("ui.tunnel_start_failed")
			return
		_launch_tunnel(override)
		return

	_tunnel_platform_key = MCPCloudflaredProvider.detect_platform_key()
	if _tunnel_platform_key.is_empty():
		_set_tunnel_status("ui.tunnel_unsupported")
		return

	if MCPCloudflaredProvider.is_installed(_tunnel_platform_key):
		var bin: String = ProjectSettings.globalize_path(MCPCloudflaredProvider.binary_path(_tunnel_platform_key))
		_launch_tunnel(bin)
		return

	_download_cloudflared(_tunnel_platform_key)

func _download_cloudflared(key: String) -> void:
	_tunnel_download_urls = MCPCloudflaredProvider.download_urls(key)
	if _tunnel_download_urls.is_empty():
		_set_tunnel_status("ui.tunnel_unsupported")
		return
	_tunnel_download_index = 0
	DirAccess.make_dir_recursive_absolute(MCPCloudflaredProvider.INSTALL_DIR)
	if _tunnel_http == null or not is_instance_valid(_tunnel_http):
		_tunnel_http = HTTPRequest.new()
		add_child(_tunnel_http)
		_tunnel_http.request_completed.connect(_on_tunnel_download_completed)
	_tunnel_http.download_file = MCPCloudflaredProvider.download_target(key)
	if _tunnel_start_button:
		_tunnel_start_button.disabled = true
	_request_tunnel_download()

## Requests the current candidate URL (official first, then mirrors).
func _request_tunnel_download() -> void:
	_set_tunnel_status("ui.tunnel_downloading")
	var err: int = _tunnel_http.request(_tunnel_download_urls[_tunnel_download_index])
	if err != OK:
		_advance_or_fail_download("ui.tunnel_download_failed")

## Tries the next mirror; once candidates are exhausted, surfaces the last
## failure reason and re-enables the start button.
func _advance_or_fail_download(fail_status_key: String) -> void:
	_tunnel_download_index += 1
	if _tunnel_download_index < _tunnel_download_urls.size():
		_request_tunnel_download()
		return
	if _tunnel_start_button:
		_tunnel_start_button.disabled = false
	_set_tunnel_status(fail_status_key)

func _on_tunnel_download_completed(result: int, response_code: int, _headers: PackedStringArray, _body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS or response_code < 200 or response_code >= 300:
		_advance_or_fail_download("ui.tunnel_download_failed")
		return
	var key: String = _tunnel_platform_key
	var target: String = MCPCloudflaredProvider.download_target(key)
	if not MCPCloudflaredProvider.verify_checksum(target, key):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(target))
		_advance_or_fail_download("ui.tunnel_verify_failed")
		return
	if _tunnel_start_button:
		_tunnel_start_button.disabled = false
	var bin: String = _install_binary(key, target)
	if bin.is_empty():
		_set_tunnel_status("ui.tunnel_start_failed")
		return
	_launch_tunnel(bin)

## Moves/extracts the verified download into the runnable binary path and makes it
## executable. Returns the absolute binary path, or "" on failure.
func _install_binary(key: String, target: String) -> String:
	var bin_rel: String = MCPCloudflaredProvider.binary_path(key)
	var bin_abs: String = ProjectSettings.globalize_path(bin_rel)
	var target_abs: String = ProjectSettings.globalize_path(target)
	if MCPCloudflaredProvider.is_archive(key):
		var dir_abs: String = ProjectSettings.globalize_path(MCPCloudflaredProvider.INSTALL_DIR)
		var out: Array = []
		var code: int = OS.execute("tar", PackedStringArray(["-xzf", target_abs, "-C", dir_abs]), out, true)
		if code != 0 or not FileAccess.file_exists(bin_rel):
			return ""
	else:
		if FileAccess.file_exists(bin_rel):
			DirAccess.remove_absolute(bin_abs)
		var derr: int = DirAccess.rename_absolute(target_abs, bin_abs)
		if derr != OK:
			return ""
	if OS.get_name() != "Windows":
		OS.execute("chmod", PackedStringArray(["+x", bin_abs]), [], true)
	return bin_abs

func _launch_tunnel(binary_abs: String) -> void:
	if _tunnel_manager == null:
		_tunnel_manager = MCPTunnelManager.new()
	var err: int = _tunnel_manager.start(binary_abs, _current_port())
	if err == ERR_ALREADY_IN_USE:
		_set_tunnel_status("ui.tunnel_already")
		return
	if err != OK:
		_set_tunnel_status("ui.tunnel_start_failed")
		return
	_set_tunnel_status("ui.tunnel_starting")
	if _tunnel_stop_button:
		_tunnel_stop_button.disabled = false
	if _tunnel_start_button:
		_tunnel_start_button.disabled = true
	if _tunnel_poll_timer == null or not is_instance_valid(_tunnel_poll_timer):
		_tunnel_poll_timer = Timer.new()
		_tunnel_poll_timer.wait_time = 1.0
		_tunnel_poll_timer.timeout.connect(_on_tunnel_poll_timeout)
		add_child(_tunnel_poll_timer)
	_tunnel_poll_timer.start()

func _on_tunnel_poll_timeout() -> void:
	if _tunnel_manager == null:
		return
	if not _tunnel_manager.is_running():
		_tunnel_poll_timer.stop()
		_reset_tunnel_buttons()
		_clear_tunnel_url_if_owned(_tunnel_manager.get_public_url())
		_set_tunnel_status("ui.tunnel_exited")
		return
	var url: String = _tunnel_manager.poll()
	if not url.is_empty():
		if _remote_url_edit:
			_remote_url_edit.text = url
		_update_public_endpoint()
		_set_tunnel_status_live(url)

func _set_tunnel_status_live(url: String) -> void:
	if _tunnel_status_label:
		_tunnel_status_label.text = _trf("ui.tunnel_live", [url])

func _reset_tunnel_buttons() -> void:
	if _tunnel_start_button:
		_tunnel_start_button.disabled = false
	if _tunnel_stop_button:
		_tunnel_stop_button.disabled = true

func _on_tunnel_stop_pressed() -> void:
	if _tunnel_poll_timer and is_instance_valid(_tunnel_poll_timer):
		_tunnel_poll_timer.stop()
	var tunnel_url: String = ""
	if _tunnel_manager:
		tunnel_url = _tunnel_manager.get_public_url()
		_tunnel_manager.stop()
	_clear_tunnel_url_if_owned(tunnel_url)
	_reset_tunnel_buttons()
	_set_tunnel_status("ui.tunnel_stopped")

## Clears the remote URL field (and hides the public endpoint card) only when it
## still holds the now-dead tunnel-provided URL; manual entries are left intact.
func _clear_tunnel_url_if_owned(tunnel_url: String) -> void:
	if tunnel_url.strip_edges().is_empty():
		return
	if _remote_url_edit and _remote_url_edit.text.strip_edges() == tunnel_url.strip_edges():
		_remote_url_edit.text = ""
		_update_public_endpoint()

func _build_transport_card(content: VBoxContainer) -> void:
	_transport_title_label = Label.new()
	_transport_title_label.text = _tr("ui.transport_settings")
	var body: VBoxContainer = _settings_card(content, _transport_title_label)

	_transport_mode_label = Label.new()
	_transport_mode_label.text = _tr("ui.transport_mode")
	_transport_mode_option = OptionButton.new()
	_transport_mode_option.add_item("http", 1)
	_transport_mode_option.item_selected.connect(_on_transport_mode_selected)
	_settings_row(body, _transport_mode_label, _transport_mode_option, false)

	_http_config_container = VBoxContainer.new()
	_http_config_container.add_theme_constant_override("separation", 6)
	body.add_child(_http_config_container)

	_http_port_label = Label.new()
	_http_port_label.text = _tr("ui.http_port")
	_http_port_spin = SpinBox.new()
	_http_port_spin.min_value = 1024
	_http_port_spin.max_value = 65535
	_http_port_spin.value = 9080
	_http_port_spin.step = 1
	_http_port_spin.value_changed.connect(_on_http_port_changed)
	_settings_row(_http_config_container, _http_port_label, _http_port_spin, false)

	var auth_hbox: HBoxContainer = HBoxContainer.new()
	auth_hbox.add_theme_constant_override("separation", 8)
	_http_config_container.add_child(auth_hbox)
	_auth_enabled_check = CheckBox.new()
	_auth_enabled_check.text = _tr("ui.enable_auth")
	_auth_enabled_check.toggled.connect(_on_auth_enabled_toggled)
	auth_hbox.add_child(_auth_enabled_check)
	_auth_token_label = Label.new()
	_auth_token_label.text = _tr("ui.auth_token")
	auth_hbox.add_child(_auth_token_label)
	_auth_token_edit = LineEdit.new()
	_auth_token_edit.secret = true
	_auth_token_edit.placeholder_text = _tr("ui.token_placeholder")
	_auth_token_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_auth_token_edit.text_changed.connect(_on_auth_token_changed)
	auth_hbox.add_child(_auth_token_edit)

	_sse_enabled_check = CheckBox.new()
	_sse_enabled_check.text = _tr("ui.enable_sse")
	_sse_enabled_check.toggled.connect(_on_sse_enabled_toggled)
	_http_config_container.add_child(_sse_enabled_check)

	_allow_remote_check = CheckBox.new()
	_allow_remote_check.text = _tr("ui.allow_remote")
	_allow_remote_check.toggled.connect(_on_allow_remote_toggled)
	_http_config_container.add_child(_allow_remote_check)

	_cors_origin_label = Label.new()
	_cors_origin_label.text = _tr("ui.cors_origin")
	_cors_origin_edit = LineEdit.new()
	_cors_origin_edit.text = "*"
	_cors_origin_edit.text_changed.connect(_on_cors_origin_changed)
	_settings_row(_http_config_container, _cors_origin_label, _cors_origin_edit, true)

	_http_config_container.visible = false

func _build_behavior_card(content: VBoxContainer) -> void:
	var title: Label = Label.new()
	title.text = _tr("ui.section_behavior")
	var body: VBoxContainer = _settings_card(content, title)
	_register_section_title(title, "ui.section_behavior")

	_auto_start_check = CheckBox.new()
	_auto_start_check.text = _tr("ui.auto_start")
	_auto_start_check.toggled.connect(_on_auto_start_toggled)
	body.add_child(_auto_start_check)

	_vibe_coding_mode_check = CheckBox.new()
	_vibe_coding_mode_check.text = _tr("ui.vibe_coding_mode")
	_vibe_coding_mode_check.toggled.connect(_on_vibe_coding_mode_toggled)
	body.add_child(_vibe_coding_mode_check)

	_rate_limit_label = Label.new()
	_rate_limit_label.text = _tr("ui.rate_limit")
	_rate_limit_spin = SpinBox.new()
	_rate_limit_spin.min_value = 10
	_rate_limit_spin.max_value = 2000
	_rate_limit_spin.step = 10
	_rate_limit_spin.value = 1000
	_rate_limit_spin.value_changed.connect(_on_rate_limit_changed)
	_settings_row(body, _rate_limit_label, _rate_limit_spin, false)

func _build_security_card(content: VBoxContainer) -> void:
	var title: Label = Label.new()
	title.text = _tr("ui.section_security")
	var body: VBoxContainer = _settings_card(content, title)
	_register_section_title(title, "ui.section_security")

	_security_label = Label.new()
	_security_label.text = _tr("ui.security")
	_security_level_option = OptionButton.new()
	_security_level_option.add_item("PERMISSIVE", 0)
	_security_level_option.add_item("STRICT", 1)
	_security_level_option.item_selected.connect(_on_security_level_selected)
	_settings_row(body, _security_label, _security_level_option, false)

	_log_level_label = Label.new()
	_log_level_label.text = _tr("ui.log_level")
	_log_level_option = OptionButton.new()
	_log_level_option.add_item("ERROR", 0)
	_log_level_option.add_item("WARN", 1)
	_log_level_option.add_item("INFO", 2)
	_log_level_option.add_item("DEBUG", 3)
	_log_level_option.item_selected.connect(_on_log_level_selected)
	_settings_row(body, _log_level_label, _log_level_option, false)

	var buttons: HBoxContainer = HBoxContainer.new()
	buttons.add_theme_constant_override("separation", 8)
	body.add_child(buttons)
	_open_log_button = Button.new()
	_open_log_button.text = _tr("ui.open_log")
	_open_log_button.pressed.connect(_open_log_file)
	buttons.add_child(_open_log_button)
	_clear_log_button = Button.new()
	_clear_log_button.text = _tr("ui.clear_log")
	_clear_log_button.pressed.connect(clear_log)
	buttons.add_child(_clear_log_button)

## Asset generation provider config: pick a built-in external provider preset and
## name the OS env var that holds the API key (the key value is never stored).
func _build_asset_provider_card(content: VBoxContainer) -> void:
	var title: Label = Label.new()
	title.text = _tr("ui.section_asset_provider")
	var body: VBoxContainer = _settings_card(content, title)
	_register_section_title(title, "ui.section_asset_provider")

	var hint: Label = Label.new()
	hint.text = _tr("ui.asset_provider_hint")
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD
	hint.add_theme_color_override("font_color", Color(0.72, 0.72, 0.76))
	body.add_child(hint)

	_asset_provider_label = Label.new()
	_asset_provider_label.text = _tr("ui.asset_provider")
	_asset_provider_option = OptionButton.new()
	_asset_provider_option.add_item(_tr("ui.asset_provider_none"), 0)
	for preset_id in AssetProviderPresets.preset_ids():
		_asset_provider_option.add_item(AssetProviderPresets.label_for(preset_id))
	_asset_provider_option.item_selected.connect(_on_asset_provider_selected)
	_settings_row(body, _asset_provider_label, _asset_provider_option, false)

	_asset_key_env_label = Label.new()
	_asset_key_env_label.text = _tr("ui.asset_key_env")
	_asset_key_env_edit = LineEdit.new()
	_asset_key_env_edit.placeholder_text = _tr("ui.asset_key_env_placeholder")
	_asset_key_env_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_asset_key_env_edit.text_changed.connect(_on_asset_key_env_changed)
	_settings_row(body, _asset_key_env_label, _asset_key_env_edit, true)

	_asset_endpoint_label = Label.new()
	_asset_endpoint_label.text = _tr("ui.asset_endpoint")
	_asset_endpoint_edit = LineEdit.new()
	_asset_endpoint_edit.placeholder_text = _tr("ui.asset_endpoint_placeholder")
	_asset_endpoint_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_asset_endpoint_edit.text_changed.connect(_on_asset_endpoint_changed)
	_settings_row(body, _asset_endpoint_label, _asset_endpoint_edit, true)

func _on_asset_provider_selected(_index: int) -> void:
	_debounce_save()

func _on_asset_key_env_changed(_text: String) -> void:
	_debounce_save()

func _on_asset_endpoint_changed(_text: String) -> void:
	_debounce_save()

## Returns the configured preset id ("" when "none" is selected). Index 0 is the
## "none" entry; subsequent indices map 1:1 to AssetProviderPresets.preset_ids().
func _selected_asset_preset_id() -> String:
	if not _asset_provider_option:
		return ""
	var idx: int = _asset_provider_option.selected
	if idx <= 0:
		return ""
	var ids: Array = AssetProviderPresets.preset_ids()
	if idx - 1 < ids.size():
		return str(ids[idx - 1])
	return ""

func _build_general_card(content: VBoxContainer) -> void:
	var title: Label = Label.new()
	title.text = _tr("ui.section_general")
	var body: VBoxContainer = _settings_card(content, title)
	_register_section_title(title, "ui.section_general")

	_language_label = Label.new()
	_language_label.text = _tr("ui.language")
	_language_option = OptionButton.new()
	_language_option.add_item(_tr("ui.english"), 0)
	_language_option.add_item(_tr("ui.chinese"), 1)
	_language_option.item_selected.connect(_on_language_selected)
	_settings_row(body, _language_label, _language_option, false)

func _register_section_title(label: Label, key: String) -> void:
	_section_titles.append({"label": label, "key": key})

func _settings_card(content: VBoxContainer, title: Label) -> VBoxContainer:
	var card: PanelContainer = PanelContainer.new()
	card.add_theme_stylebox_override("panel", _panel_card_style())
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.add_child(card)

	var box: VBoxContainer = VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	card.add_child(box)

	title.add_theme_font_size_override("font_size", 13)
	title.add_theme_color_override("font_color", Color(0.62, 0.74, 1.0))
	box.add_child(title)
	return box

func _settings_row(parent: VBoxContainer, label: Label, control: Control, expand: bool) -> void:
	var row: HBoxContainer = HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	parent.add_child(row)

	label.custom_minimum_size = Vector2(120, 0)
	label.add_theme_color_override("font_color", Color(0.78, 0.78, 0.82))
	row.add_child(label)

	if expand:
		control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	else:
		control.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	row.add_child(control)

func _panel_card_style() -> StyleBoxFlat:
	var style: StyleBoxFlat = StyleBoxFlat.new()
	style.bg_color = Color(1, 1, 1, 0.025)
	style.border_color = Color(1, 1, 1, 0.06)
	style.set_border_width_all(1)
	style.set_corner_radius_all(6)
	style.content_margin_left = 14
	style.content_margin_right = 14
	style.content_margin_top = 12
	style.content_margin_bottom = 12
	return style

func _build_preset_row(content: VBoxContainer) -> void:
	var row: HBoxContainer = HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	content.add_child(row)

	_preset_label = Label.new()
	_preset_label.text = _tr("ui.preset_label")
	_preset_label.add_theme_color_override("font_color", Color(0.78, 0.78, 0.82))
	row.add_child(_preset_label)

	_preset_option = OptionButton.new()
	if _preset_manager:
		for preset_id in _preset_manager.get_preset_ids():
			_preset_option.add_item(_tr("ui.preset_" + preset_id))
	row.add_child(_preset_option)

	_apply_preset_button = Button.new()
	_apply_preset_button.text = _tr("ui.preset_apply")
	_apply_preset_button.pressed.connect(_on_apply_preset_pressed)
	row.add_child(_apply_preset_button)

	var spacer: Control = Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(spacer)

	_export_preset_button = Button.new()
	_export_preset_button.text = _tr("ui.preset_export")
	_export_preset_button.flat = true
	_export_preset_button.pressed.connect(_on_export_preset_pressed)
	row.add_child(_export_preset_button)

	_import_preset_button = Button.new()
	_import_preset_button.text = _tr("ui.preset_import")
	_import_preset_button.flat = true
	_import_preset_button.pressed.connect(_on_import_preset_pressed)
	row.add_child(_import_preset_button)

func _registered_tool_names() -> Array:
	var names: Array = []
	if _server_core and _server_core.has_method("get_registered_tools"):
		for info in _server_core.get_registered_tools():
			names.append(info.get("name", ""))
	return names

func _apply_states(states: Dictionary) -> void:
	if _server_core == null or not _server_core.has_method("set_tool_enabled"):
		return
	for tool_name in states:
		_server_core.set_tool_enabled(tool_name, states[tool_name])
	_refresh_tools_list()
	_update_nav_counts()
	_update_tools_count()
	_update_detail_count()
	_debounce_save()

func _on_apply_preset_pressed() -> void:
	if _preset_manager == null or _preset_option == null:
		return
	var ids: Array = _preset_manager.get_preset_ids()
	var idx: int = _preset_option.selected
	if idx < 0 or idx >= ids.size():
		return
	var states: Dictionary = _preset_manager.resolve_preset_states(ids[idx], _registered_tool_names())
	_apply_states(states)

func _ensure_preset_file_dialog() -> void:
	if _preset_file_dialog and is_instance_valid(_preset_file_dialog):
		return
	_preset_file_dialog = FileDialog.new()
	_preset_file_dialog.access = FileDialog.ACCESS_FILESYSTEM
	_preset_file_dialog.use_native_dialog = true
	_preset_file_dialog.add_filter("*.json", "JSON")
	_preset_file_dialog.file_selected.connect(_on_preset_file_selected)
	add_child(_preset_file_dialog)

func _on_export_preset_pressed() -> void:
	_ensure_preset_file_dialog()
	_preset_dialog_save = true
	_preset_file_dialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE
	_preset_file_dialog.title = _tr("ui.preset_export_title")
	_preset_file_dialog.current_file = "godot_mcp_tools.json"
	_preset_file_dialog.popup_centered(Vector2i(760, 520))

func _on_import_preset_pressed() -> void:
	_ensure_preset_file_dialog()
	_preset_dialog_save = false
	_preset_file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	_preset_file_dialog.title = _tr("ui.preset_import_title")
	_preset_file_dialog.popup_centered(Vector2i(760, 520))

func _on_preset_file_selected(path: String) -> void:
	if _preset_dialog_save:
		var states: Dictionary = {}
		if _server_core and _server_core.has_method("get_registered_tools"):
			for info in _server_core.get_registered_tools():
				states[info.get("name", "")] = info.get("enabled", true)
		MCPToolPresetManager.export_states_to_file(states, path)
	else:
		var result: Dictionary = MCPToolPresetManager.import_states_from_file(path, _registered_tool_names())
		if result.get("ok", false):
			_apply_states(result["states"])

func _create_tools_tab() -> VBoxContainer:
	var tab: VBoxContainer = VBoxContainer.new()
	tab.size_flags_vertical = Control.SIZE_EXPAND_FILL
	tab.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tab.add_theme_constant_override("separation", 4)

	var margin: MarginContainer = MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 12)
	margin.add_theme_constant_override("margin_right", 12)
	margin.add_theme_constant_override("margin_top", 8)
	margin.add_theme_constant_override("margin_bottom", 8)
	margin.size_flags_vertical = Control.SIZE_EXPAND_FILL
	margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tab.add_child(margin)

	var content: VBoxContainer = VBoxContainer.new()
	content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	margin.add_child(content)

	var toolbar: HBoxContainer = HBoxContainer.new()
	content.add_child(toolbar)

	_refresh_tools_button = Button.new()
	_refresh_tools_button.text = _tr("ui.refresh_tools")
	_refresh_tools_button.pressed.connect(_refresh_tools_list)
	toolbar.add_child(_refresh_tools_button)

	_tools_count_label = Label.new()
	_tools_count_label.text = _tr("ui.tools_init")
	_tools_count_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_tools_count_label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.62))
	toolbar.add_child(_tools_count_label)

	_build_preset_row(content)

	var search_row: HBoxContainer = HBoxContainer.new()
	search_row.add_theme_constant_override("separation", 8)
	content.add_child(search_row)

	_tools_search_edit = LineEdit.new()
	_tools_search_edit.placeholder_text = _tr("ui.search_placeholder")
	_tools_search_edit.clear_button_enabled = true
	_tools_search_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_tools_search_edit.text_changed.connect(_on_tools_search_changed)
	search_row.add_child(_tools_search_edit)

	_build_scope_chips(search_row)

	var split: HSplitContainer = HSplitContainer.new()
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	split.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	split.split_offset = 210
	content.add_child(split)

	var nav_scroll: ScrollContainer = ScrollContainer.new()
	nav_scroll.custom_minimum_size = Vector2(190, 0)
	nav_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	nav_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	split.add_child(nav_scroll)

	_category_nav_container = VBoxContainer.new()
	_category_nav_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_category_nav_container.add_theme_constant_override("separation", 2)
	nav_scroll.add_child(_category_nav_container)

	var middle_split: HSplitContainer = HSplitContainer.new()
	middle_split.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	middle_split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	middle_split.split_offset = 360
	split.add_child(middle_split)

	var detail: VBoxContainer = VBoxContainer.new()
	detail.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	detail.size_flags_vertical = Control.SIZE_EXPAND_FILL
	detail.add_theme_constant_override("separation", 4)
	middle_split.add_child(detail)

	var header_margin: MarginContainer = MarginContainer.new()
	header_margin.add_theme_constant_override("margin_left", 10)
	detail.add_child(header_margin)

	var header_box: VBoxContainer = VBoxContainer.new()
	header_box.add_theme_constant_override("separation", 2)
	header_margin.add_child(header_box)

	_detail_title = Label.new()
	_detail_title.add_theme_font_size_override("font_size", 18)
	_detail_title.add_theme_color_override("font_color", Color(0.95, 0.95, 0.98))
	header_box.add_child(_detail_title)

	_detail_desc = Label.new()
	_detail_desc.autowrap_mode = TextServer.AUTOWRAP_WORD
	_detail_desc.add_theme_font_size_override("font_size", 12)
	_detail_desc.add_theme_color_override("font_color", Color(0.6, 0.6, 0.64))
	header_box.add_child(_detail_desc)

	var action_row: HBoxContainer = HBoxContainer.new()
	action_row.add_theme_constant_override("separation", 6)
	header_box.add_child(action_row)

	_enable_all_button = Button.new()
	_enable_all_button.text = _tr("ui.enable_all")
	_enable_all_button.pressed.connect(_on_enable_all_pressed)
	action_row.add_child(_enable_all_button)

	_disable_all_button = Button.new()
	_disable_all_button.text = _tr("ui.disable_all")
	_disable_all_button.pressed.connect(_on_disable_all_pressed)
	action_row.add_child(_disable_all_button)

	var action_spacer: Control = Control.new()
	action_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	action_row.add_child(action_spacer)

	_detail_count = Label.new()
	_detail_count.add_theme_font_size_override("font_size", 11)
	_detail_count.add_theme_color_override("font_color", Color(0.6, 0.6, 0.62))
	action_row.add_child(_detail_count)

	var header_sep: HSeparator = HSeparator.new()
	detail.add_child(header_sep)

	var scroll: ScrollContainer = ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	detail.add_child(scroll)

	_tools_list_container = VBoxContainer.new()
	_tools_list_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_tools_list_container.add_theme_constant_override("separation", 6)
	scroll.add_child(_tools_list_container)

	_tool_detail_panel = MCPToolDetailPanel.new()
	_tool_detail_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tool_detail_panel.setup(_translation_manager)
	middle_split.add_child(_tool_detail_panel)

	return tab

func _update_ui_state() -> void:
	if not _status_label:
		return

	var is_running: bool = false
	if _server_core and _server_core.has_method("is_running"):
		is_running = _server_core.is_running()

	if is_running:
		_status_label.text = _tr("ui.status_running")
		_status_label.add_theme_color_override("font_color", Color(0.36, 0.78, 0.42))
		if _status_dot:
			_status_dot.add_theme_stylebox_override("panel", _dot_style(Color(0.36, 0.78, 0.42)))
	else:
		_status_label.text = _tr("ui.status_stopped")
		_status_label.add_theme_color_override("font_color", Color(0.82, 0.42, 0.42))
		if _status_dot:
			_status_dot.add_theme_stylebox_override("panel", _dot_style(Color(0.55, 0.55, 0.6)))

	if _start_button:
		_start_button.disabled = is_running
	if _stop_button:
		_stop_button.disabled = not is_running
	_update_local_endpoint()

	if _plugin:
		if _auto_start_check:
			_auto_start_check.button_pressed = _plugin.auto_start

		if _vibe_coding_mode_check:
			_vibe_coding_mode_check.button_pressed = _plugin.vibe_coding_mode if _plugin.get("vibe_coding_mode") != null else true

		if _log_level_option:
			_log_level_option.select(_plugin.log_level)

		if _security_level_option:
			_security_level_option.select(_plugin.security_level)

		if _transport_mode_option:
			var mode: String = _plugin.transport_mode if _plugin.get("transport_mode") != null else "stdio"
			_transport_mode_option.selected = 0 if mode == "stdio" else 1
			_http_config_container.visible = (mode == "http")

		if _http_port_spin:
			_http_port_spin.value = _plugin.http_port if _plugin.get("http_port") != null else 9080

		if _auth_enabled_check:
			_auth_enabled_check.button_pressed = _plugin.auth_enabled if _plugin.get("auth_enabled") != null else false

		if _auth_token_edit:
			_auth_token_edit.text = _plugin.auth_token if _plugin.get("auth_token") != null else ""

		if _sse_enabled_check:
			_sse_enabled_check.button_pressed = _plugin.sse_enabled if _plugin.get("sse_enabled") != null else true

		if _allow_remote_check:
			_allow_remote_check.button_pressed = _plugin.allow_remote if _plugin.get("allow_remote") != null else false

		if _cors_origin_edit:
			_cors_origin_edit.text = _plugin.cors_origin if _plugin.get("cors_origin") != null else "*"

		if _rate_limit_spin:
			_rate_limit_spin.value = _plugin.rate_limit if _plugin.get("rate_limit") != null else 1000

	if _transport_mode_option:
		_transport_mode_option.disabled = is_running

	if _http_config_container:
		_set_controls_disabled(_http_config_container, is_running)

	if _auth_token_edit:
		var auth_on: bool = _auth_enabled_check.button_pressed if _auth_enabled_check else false
		_auth_token_edit.editable = auth_on and not is_running

	if _connection_info_label:
		var mode: String = "stdio"
		if _plugin and _plugin.get("transport_mode") != null:
			mode = _plugin.transport_mode
		if mode == "http" and is_running:
			var port: int = 9080
			if _plugin and _plugin.get("http_port") != null:
				port = _plugin.http_port
			_connection_info_label.text = _trf("ui.connection_url", [port])
		elif mode == "stdio" and is_running:
			_connection_info_label.text = _tr("ui.connection_stdio")
		else:
			_connection_info_label.text = ""

func _set_controls_disabled(container: Container, disabled: bool) -> void:
	for child in container.get_children():
		if child is SpinBox or child is LineEdit:
			child.editable = not disabled
		elif child is CheckBox or child is OptionButton or child is Button:
			child.disabled = disabled
		elif child is Container:
			_set_controls_disabled(child, disabled)

func _on_start_pressed() -> void:
	if not _plugin:
		return
	_plugin.start_server()
	await get_tree().process_frame
	_update_ui_state()

func _on_stop_pressed() -> void:
	if not _plugin:
		return
	_plugin.stop_server()
	await get_tree().process_frame
	_update_ui_state()

func _on_auto_start_toggled(button_pressed: bool) -> void:
	if _plugin:
		_plugin.auto_start = button_pressed
	_debounce_save()

func _on_vibe_coding_mode_toggled(button_pressed: bool) -> void:
	if _plugin:
		_plugin.vibe_coding_mode = button_pressed
	_debounce_save()

func _on_log_level_selected(index: int) -> void:
	if _plugin:
		_plugin.log_level = index
	_debounce_save()

func _on_security_level_selected(index: int) -> void:
	if _plugin:
		_plugin.security_level = index
	_debounce_save()

func _on_transport_mode_selected(index: int) -> void:
	var mode: String = _transport_mode_option.get_item_text(index)
	if _plugin:
		_plugin.transport_mode = mode
	_http_config_container.visible = (mode == "http")
	_update_ui_state()
	_debounce_save()

func _on_http_port_changed(value: float) -> void:
	if _plugin:
		_plugin.http_port = int(value)
	_update_local_endpoint()
	_debounce_save()

func _on_auth_enabled_toggled(enabled: bool) -> void:
	if _plugin:
		_plugin.auth_enabled = enabled
	if _auth_token_edit:
		_auth_token_edit.editable = enabled
	_debounce_save()

func _on_auth_token_changed(text: String) -> void:
	if _plugin:
		_plugin.auth_token = text
	_debounce_save()

func _on_sse_enabled_toggled(enabled: bool) -> void:
	if _plugin:
		_plugin.sse_enabled = enabled
	_debounce_save()

func _on_allow_remote_toggled(enabled: bool) -> void:
	if _plugin:
		_plugin.allow_remote = enabled
	_debounce_save()

func _on_cors_origin_changed(text: String) -> void:
	if _plugin:
		_plugin.cors_origin = text
	_debounce_save()

func _on_rate_limit_changed(value: float) -> void:
	if _plugin:
		_plugin.rate_limit = int(value)
	_debounce_save()

func _open_log_file() -> void:
	# Flush pending writes before opening so the file has the latest data
	_flush_log_to_file()
	var path: String = ProjectSettings.globalize_path(_log_file_path)
	# Build a proper file:// URI that works on Windows, macOS, and Linux.
	# globalize_path returns e.g. "C:/Users/..." (Windows) or "/Users/..." (macOS/Linux).
	# file:// expects exactly one slash before the absolute path: file:///C:/... or file:///home/...
	if not path.begins_with("/"):
		path = "/" + path
	OS.shell_open("file://" + path)

func clear_log() -> void:
	_log_pending_write.clear()
	var file: FileAccess = FileAccess.open(_log_file_path, FileAccess.WRITE)
	if file:
		file.store_string("")
		file.close()

func _refresh_tools_list() -> void:
	if not _tools_list_container:
		return

	for child in _tools_list_container.get_children():
		child.queue_free()
	_group_widgets.clear()
	_core_group_names = []
	_supp_group_names = []

	var tools: Array = []
	if _server_core and _server_core.has_method("get_registered_tools"):
		tools = _server_core.get_registered_tools()

	var classifier = null
	if _server_core and _server_core.has_method("get_classifier"):
		classifier = _server_core.get_classifier()

	var tools_by_group: Dictionary = {}
	for tool_info in tools:
		var group: String = tool_info.get("group", "")
		if not tools_by_group.has(group):
			tools_by_group[group] = []
		tools_by_group[group].append(tool_info)

	var all_groups: Array = []
	if classifier and classifier.has_method("get_all_groups"):
		all_groups = classifier.get_all_groups()

	for group_name in all_groups:
		if tools_by_group.has(group_name):
			var sample: Dictionary = tools_by_group[group_name][0]
			var cat: String = sample.get("category", "core")
			if cat == "supplementary":
				_supp_group_names.append(group_name)
			else:
				_core_group_names.append(group_name)

	for group_name in _core_group_names:
		_create_group_widget(group_name, tools_by_group[group_name])
	for group_name in _supp_group_names:
		_create_group_widget(group_name, tools_by_group[group_name])

	_build_category_nav()
	_update_tools_count()

	if not _nav_items.has(_selected_category):
		_selected_category = "__recommended__"
	_select_category(_selected_category)

func _create_group_widget(group_name: String, group_tools: Array) -> void:
	var widget: MCPToolGroupItem = MCPToolGroupItem.new()
	widget.setup(group_name, group_tools, _translation_manager)
	widget.group_toggled.connect(_on_group_toggled)
	widget.item_toggled.connect(_on_tool_toggled)
	widget.tool_selected.connect(_on_tool_selected)
	_tools_list_container.add_child(widget)
	_group_widgets[group_name] = widget

# --- Category navigator (master-detail) ---

func _build_category_nav() -> void:
	if not _category_nav_container:
		return
	for child in _category_nav_container.get_children():
		child.queue_free()
	_nav_items.clear()
	_nav_group = ButtonGroup.new()

	_add_nav_item("__recommended__", _tr("ui.recommended"), "Favorites")
	_add_nav_item("__supplementary__", _tr("ui.extended_tools"), "Tools")
	_add_nav_item("__all__", _tr("ui.all_tools"), "GuiTreeArrowDown")

	if _core_group_names.size() > 0:
		_add_nav_section(_tr("ui.core_tools"))
		for group_name in _core_group_names:
			_add_nav_item(group_name, _group_display_name(group_name), _group_icon_name(group_name))
	if _supp_group_names.size() > 0:
		_add_nav_section(_tr("ui.supplementary_tools"))
		for group_name in _supp_group_names:
			_add_nav_item(group_name, _group_display_name(group_name), _group_icon_name(group_name))

	_update_nav_counts()

func _add_nav_section(title: String) -> void:
	var label: Label = Label.new()
	label.text = title
	label.add_theme_font_size_override("font_size", 10)
	label.add_theme_color_override("font_color", Color(0.5, 0.5, 0.54))
	label.add_theme_constant_override("margin_top", 8)
	_category_nav_container.add_child(label)

func _add_nav_item(key: String, label: String, icon_name: String) -> void:
	var icon_tex: Texture2D = null
	if icon_name != "" and has_theme_icon(icon_name, "EditorIcons"):
		icon_tex = get_theme_icon(icon_name, "EditorIcons")
	var item: MCPCategoryNavItem = MCPCategoryNavItem.new()
	item.setup(key, label, icon_tex, _nav_group)
	item.category_selected.connect(_select_category)
	_category_nav_container.add_child(item)
	_nav_items[key] = item

func _group_icon_name(group_name: String) -> String:
	var by_prefix: Dictionary = {
		"Node": "Node",
		"Script": "Script",
		"Scene": "PackedScene",
		"Editor": "Tools",
		"Debug": "Debug",
		"Project": "ProjectSettings",
	}
	for prefix in by_prefix:
		if group_name.begins_with(prefix):
			return by_prefix[prefix]
	return ""

func _group_icon_texture(group_name: String) -> Texture2D:
	var icon_name: String = _group_icon_name(group_name)
	if icon_name != "" and has_theme_icon(icon_name, "EditorIcons"):
		return get_theme_icon(icon_name, "EditorIcons")
	return null

func _group_display_name(group_name: String) -> String:
	var key: String = "group." + group_name
	var translated: String = _tr(key)
	return group_name if translated == key else translated

func _group_description(group_name: String) -> String:
	var key: String = "groupdesc." + group_name
	var translated: String = _tr(key)
	return "" if translated == key else translated

func _groups_for_selection() -> Array:
	match _selected_category:
		"__recommended__":
			return _core_group_names.duplicate()
		"__supplementary__":
			return _supp_group_names.duplicate()
		"__all__":
			return _core_group_names + _supp_group_names
		_:
			return [_selected_category]

func _select_category(key: String) -> void:
	_selected_category = key
	if _tools_search_edit and not _tools_search_edit.text.is_empty():
		_tools_search_edit.set_block_signals(true)
		_tools_search_edit.text = ""
		_tools_search_edit.set_block_signals(false)
	if _nav_items.has(key):
		_nav_items[key].set_selected(true)
	_sync_scope_chips()
	_apply_view()

func _build_scope_chips(parent: HBoxContainer) -> void:
	_scope_chips.clear()
	_scope_chip_group = ButtonGroup.new()
	var defs: Array = [
		["__all__", _tr("ui.scope_all")],
		["__recommended__", _tr("ui.scope_core")],
		["__supplementary__", _tr("ui.scope_extended")],
	]
	for entry in defs:
		var chip: MCPCategoryNavItem = MCPCategoryNavItem.new()
		parent.add_child(chip)
		chip.setup(entry[0], entry[1], null, _scope_chip_group)
		chip.category_selected.connect(_select_category)
		_scope_chips[entry[0]] = chip

func _sync_scope_chips() -> void:
	for key in _scope_chips:
		_scope_chips[key].set_selected(_selected_category == key)

func _on_tools_search_changed(_new_text: String) -> void:
	_apply_view()

func _apply_view() -> void:
	var query: String = ""
	if _tools_search_edit:
		query = _tools_search_edit.text.strip_edges().to_lower()
	if query.is_empty():
		_apply_category_view()
	else:
		_apply_search_view(query)
	_update_detail_count()
	_ensure_tool_selection()

func _apply_category_view() -> void:
	var scope: Array = _groups_for_selection()
	for group_name in _group_widgets:
		var widget: MCPToolGroupItem = _group_widgets[group_name]
		if widget == null:
			continue
		widget.apply_filter("")
		widget.visible = scope.has(group_name)
	_set_bulk_buttons_enabled(true)
	match _selected_category:
		"__recommended__":
			_detail_title.text = _tr("ui.recommended")
			_detail_desc.text = _tr("ui.recommended_desc")
		"__supplementary__":
			_detail_title.text = _tr("ui.extended_tools")
			_detail_desc.text = _tr("ui.extended_desc")
		"__all__":
			_detail_title.text = _tr("ui.all_tools")
			_detail_desc.text = _tr("ui.all_tools_desc")
		_:
			_detail_title.text = _group_display_name(_selected_category)
			_detail_desc.text = _group_description(_selected_category)

func _apply_search_view(query: String) -> void:
	var total_matches: int = 0
	for group_name in _group_widgets:
		var widget: MCPToolGroupItem = _group_widgets[group_name]
		if widget == null:
			continue
		var count: int = widget.apply_filter(query)
		widget.visible = count > 0
		total_matches += count
	_set_bulk_buttons_enabled(false)
	_detail_title.text = _tr("ui.search_results")
	_detail_desc.text = _tr("ui.no_results") if total_matches == 0 else ""

func _set_bulk_buttons_enabled(value: bool) -> void:
	if _enable_all_button:
		_enable_all_button.disabled = not value
	if _disable_all_button:
		_disable_all_button.disabled = not value

func _on_enable_all_pressed() -> void:
	_set_scope_enabled(true)

func _on_disable_all_pressed() -> void:
	_set_scope_enabled(false)

func _set_scope_enabled(value: bool) -> void:
	for group_name in _groups_for_selection():
		var widget: MCPToolGroupItem = _group_widgets.get(group_name)
		if widget:
			widget.set_group_enabled(value)
	_update_nav_counts()
	_update_tools_count()
	_update_detail_count()
	_debounce_save()

func _compute_group_counts() -> Dictionary:
	var out: Dictionary = {}
	var tools: Array = []
	if _server_core and _server_core.has_method("get_registered_tools"):
		tools = _server_core.get_registered_tools()
	for tool_info in tools:
		var group: String = tool_info.get("group", "")
		if not out.has(group):
			out[group] = {"enabled": 0, "total": 0}
		out[group]["total"] += 1
		if tool_info.get("enabled", true):
			out[group]["enabled"] += 1
	return out

func _update_nav_counts() -> void:
	var counts: Dictionary = _compute_group_counts()
	var core_enabled: int = 0
	var core_total: int = 0
	var supp_enabled: int = 0
	var supp_total: int = 0
	for group_name in _core_group_names:
		var c: Dictionary = counts.get(group_name, {"enabled": 0, "total": 0})
		core_enabled += c["enabled"]
		core_total += c["total"]
		if _nav_items.has(group_name):
			_nav_items[group_name].set_count(c["enabled"], c["total"])
	for group_name in _supp_group_names:
		var c2: Dictionary = counts.get(group_name, {"enabled": 0, "total": 0})
		supp_enabled += c2["enabled"]
		supp_total += c2["total"]
		if _nav_items.has(group_name):
			_nav_items[group_name].set_count(c2["enabled"], c2["total"])
	if _nav_items.has("__recommended__"):
		_nav_items["__recommended__"].set_count(core_enabled, core_total)
	if _nav_items.has("__supplementary__"):
		_nav_items["__supplementary__"].set_count(supp_enabled, supp_total)
	if _nav_items.has("__all__"):
		_nav_items["__all__"].set_count(core_enabled + supp_enabled, core_total + supp_total)
	if _scope_chips.has("__recommended__"):
		_scope_chips["__recommended__"].set_count(core_enabled, core_total)
	if _scope_chips.has("__supplementary__"):
		_scope_chips["__supplementary__"].set_count(supp_enabled, supp_total)
	if _scope_chips.has("__all__"):
		_scope_chips["__all__"].set_count(core_enabled + supp_enabled, core_total + supp_total)

func _update_detail_count() -> void:
	if not _detail_count:
		return
	if _tools_search_edit and not _tools_search_edit.text.strip_edges().is_empty():
		_detail_count.text = ""
		return
	var counts: Dictionary = _compute_group_counts()
	var enabled: int = 0
	var total: int = 0
	for group_name in _groups_for_selection():
		var c: Dictionary = counts.get(group_name, {"enabled": 0, "total": 0})
		enabled += c["enabled"]
		total += c["total"]
	_detail_count.text = _trf("ui.enabled_format", [enabled, total])

func _on_tool_toggled(tool_name: String, enabled: bool) -> void:
	if _server_core and _server_core.has_method("set_tool_enabled"):
		_server_core.set_tool_enabled(tool_name, enabled)
	_update_tools_count()
	_update_nav_counts()
	_update_detail_count()
	if tool_name == _selected_tool_name:
		_populate_detail(tool_name)
	_debounce_save()

func _on_group_toggled(group_name: String, enabled: bool) -> void:
	if _server_core and _server_core.has_method("set_group_enabled"):
		_server_core.set_group_enabled(group_name, enabled)
	_update_tools_count()
	_update_nav_counts()
	_update_detail_count()
	if not _selected_tool_name.is_empty():
		_populate_detail(_selected_tool_name)
	_debounce_save()

# --- Tool detail pane (right column) ---

func _ordered_group_names() -> Array:
	return _core_group_names + _supp_group_names

func _find_tool_item(tool_name: String) -> MCPToolItem:
	if tool_name.is_empty():
		return null
	for group_name in _group_widgets:
		var widget: MCPToolGroupItem = _group_widgets[group_name]
		if widget == null:
			continue
		for item in widget.get_tool_items():
			if item.get_tool_name() == tool_name:
				return item
	return null

func _on_tool_selected(tool_name: String) -> void:
	if _selected_tool_name != tool_name:
		var prev: MCPToolItem = _find_tool_item(_selected_tool_name)
		if prev:
			prev.set_selected(false)
	_selected_tool_name = tool_name
	var current: MCPToolItem = _find_tool_item(tool_name)
	if current:
		current.set_selected(true)
	_populate_detail(tool_name)

func _clear_tool_selection() -> void:
	var prev: MCPToolItem = _find_tool_item(_selected_tool_name)
	if prev:
		prev.set_selected(false)
	_selected_tool_name = ""
	if _tool_detail_panel:
		_tool_detail_panel.show_empty()

func _ensure_tool_selection() -> void:
	var first_name: String = ""
	var still_visible: bool = false
	for group_name in _ordered_group_names():
		var widget: MCPToolGroupItem = _group_widgets.get(group_name)
		if widget == null or not widget.visible:
			continue
		for item in widget.get_tool_items():
			if not item.visible:
				continue
			if first_name.is_empty():
				first_name = item.get_tool_name()
			if item.get_tool_name() == _selected_tool_name:
				still_visible = true
	if still_visible:
		_on_tool_selected(_selected_tool_name)
	elif not first_name.is_empty():
		_on_tool_selected(first_name)
	else:
		_clear_tool_selection()

func _populate_detail(tool_name: String) -> void:
	if not _tool_detail_panel:
		return
	if _server_core == null or not _server_core.has_method("get_tool"):
		return
	var tool: MCPTypes.MCPTool = _server_core.get_tool(tool_name)
	if tool == null:
		_tool_detail_panel.show_empty()
		return
	var description: String = tool.description
	var translated: String = _tr(tool_name)
	if translated != tool_name:
		description = translated
	_tool_detail_panel.show_tool({
		"name": tool.name,
		"description": description,
		"category": tool.category,
		"group": tool.group,
		"group_display": _group_display_name(tool.group),
		"enabled": tool.enabled,
		"input_schema": tool.input_schema,
		"output_schema": tool.output_schema,
		"annotations": tool.annotations,
		"icon": _group_icon_texture(tool.group),
	})

func _update_tools_count() -> void:
	if not _tools_count_label:
		return
	var tools: Array = []
	if _server_core and _server_core.has_method("get_registered_tools"):
		tools = _server_core.get_registered_tools()
	var core_total: int = 0
	var core_enabled: int = 0
	var supp_total: int = 0
	var supp_enabled: int = 0
	for tool_info in tools:
		var cat: String = tool_info.get("category", "core")
		var en: bool = tool_info.get("enabled", true)
		if cat == "supplementary":
			supp_total += 1
			if en:
				supp_enabled += 1
		else:
			core_total += 1
			if en:
				core_enabled += 1
	_tools_count_label.text = _trf("ui.tools_count", [
		core_enabled, core_total, supp_enabled, supp_total,
		core_enabled + supp_enabled, core_total + supp_total
	])

func _refresh_translations() -> void:
	if _tab_container:
		_tab_container.set_tab_title(0, _tr("ui.settings"))
		_tab_container.set_tab_title(1, _tr("ui.tool_manager"))
	if _start_button:
		_start_button.text = _tr("ui.start_server")
	if _stop_button:
		_stop_button.text = _tr("ui.stop_server")
	if _auth_enabled_check:
		_auth_enabled_check.text = _tr("ui.enable_auth")
	if _sse_enabled_check:
		_sse_enabled_check.text = _tr("ui.enable_sse")
	if _allow_remote_check:
		_allow_remote_check.text = _tr("ui.allow_remote")
	if _auto_start_check:
		_auto_start_check.text = _tr("ui.auto_start")
	if _vibe_coding_mode_check:
		_vibe_coding_mode_check.text = _tr("ui.vibe_coding_mode")
	if _auth_token_edit:
		_auth_token_edit.placeholder_text = _tr("ui.token_placeholder")
	if _transport_title_label:
		_transport_title_label.text = _tr("ui.transport_settings")
	if _transport_mode_label:
		_transport_mode_label.text = _tr("ui.transport_mode")
	if _http_port_label:
		_http_port_label.text = _tr("ui.http_port")
	if _auth_token_label:
		_auth_token_label.text = _tr("ui.auth_token")
	if _cors_origin_label:
		_cors_origin_label.text = _tr("ui.cors_origin")
	if _log_level_label:
		_log_level_label.text = _tr("ui.log_level")
	if _security_label:
		_security_label.text = _tr("ui.security")
	if _rate_limit_label:
		_rate_limit_label.text = _tr("ui.rate_limit")
	if _language_label:
		_language_label.text = _tr("ui.language")
	if _refresh_tools_button:
		_refresh_tools_button.text = _tr("ui.refresh_tools")
	if _tools_search_edit:
		_tools_search_edit.placeholder_text = _tr("ui.search_placeholder")
	if _enable_all_button:
		_enable_all_button.text = _tr("ui.enable_all")
	if _disable_all_button:
		_disable_all_button.text = _tr("ui.disable_all")
	if _open_log_button:
		_open_log_button.text = _tr("ui.open_log")
	if _clear_log_button:
		_clear_log_button.text = _tr("ui.clear_log")
	if _connection_hint_label:
		_connection_hint_label.text = _tr("ui.connection_hint")
	if _local_endpoint_label:
		_local_endpoint_label.text = _tr("ui.local_endpoint")
	if _local_endpoint_copy_button:
		_local_endpoint_copy_button.text = _tr("ui.copy")
	if _client_config_label:
		_client_config_label.text = _tr("ui.client_config")
	if _copy_config_button:
		_copy_config_button.text = _tr("ui.copy_config")
		var config_popup: PopupMenu = _copy_config_button.get_popup()
		if config_popup.item_count >= 2:
			config_popup.set_item_text(0, _tr("ui.copy_config_http"))
			config_popup.set_item_text(1, _tr("ui.copy_config_stdio"))
	if _public_endpoint_title_label:
		_public_endpoint_title_label.text = _tr("ui.public_endpoint")
	if _public_endpoint_hint_label:
		_public_endpoint_hint_label.text = _tr("ui.public_endpoint_hint")
	if _public_endpoint_copy_button:
		_public_endpoint_copy_button.text = _tr("ui.copy")
	if _self_check_button:
		_self_check_button.text = _tr("ui.self_check")
	if _remote_title_label:
		_remote_title_label.text = _tr("ui.section_remote")
	if _remote_hint_label:
		_remote_hint_label.text = _tr("ui.remote_hint")
	if _remote_url_label:
		_remote_url_label.text = _tr("ui.remote_url")
	if _remote_url_edit:
		_remote_url_edit.placeholder_text = _tr("ui.remote_url_placeholder")
	if _remote_copy_http_button:
		_remote_copy_http_button.text = _tr("ui.remote_copy_http")
	if _remote_copy_bridge_button:
		_remote_copy_bridge_button.text = _tr("ui.remote_copy_bridge")
	if _remote_copy_tunnel_button:
		_remote_copy_tunnel_button.text = _tr("ui.remote_copy_tunnel")
	if _tunnel_start_button:
		_tunnel_start_button.text = _tr("ui.tunnel_start")
	if _tunnel_stop_button:
		_tunnel_stop_button.text = _tr("ui.tunnel_stop")
	if _tunnel_binary_label:
		_tunnel_binary_label.text = _tr("ui.tunnel_binary")
	if _tunnel_binary_edit:
		_tunnel_binary_edit.placeholder_text = _tr("ui.tunnel_binary_placeholder")
	if _preset_label:
		_preset_label.text = _tr("ui.preset_label")
	if _apply_preset_button:
		_apply_preset_button.text = _tr("ui.preset_apply")
	if _export_preset_button:
		_export_preset_button.text = _tr("ui.preset_export")
	if _import_preset_button:
		_import_preset_button.text = _tr("ui.preset_import")
	if _preset_option and _preset_manager:
		var preset_ids: Array = _preset_manager.get_preset_ids()
		for i in range(preset_ids.size()):
			if i < _preset_option.item_count:
				_preset_option.set_item_text(i, _tr("ui.preset_" + preset_ids[i]))
	for entry in _section_titles:
		var label: Label = entry["label"]
		if is_instance_valid(label):
			label.text = _tr(entry["key"])
	if _language_option:
		var current_locale: String = _translation_manager.get_locale() if _translation_manager else "en"
		var locales: Array = _translation_manager.get_available_locales() if _translation_manager else ["en", "zh"]
		_language_option.set_block_signals(true)
		_language_option.clear()
		_language_option.add_item(_tr("ui.english"), 0)
		_language_option.add_item(_tr("ui.chinese"), 1)
		var idx: int = locales.find(current_locale)
		if idx >= 0:
			_language_option.select(idx)
		_language_option.set_block_signals(false)
	if _tools_count_label:
		_tools_count_label.text = _tr("ui.tools_init")
	if _scope_chips.has("__all__"):
		_scope_chips["__all__"].set_label(_tr("ui.scope_all"))
	if _scope_chips.has("__recommended__"):
		_scope_chips["__recommended__"].set_label(_tr("ui.scope_core"))
	if _scope_chips.has("__supplementary__"):
		_scope_chips["__supplementary__"].set_label(_tr("ui.scope_extended"))
	_update_ui_state()
	_update_connection_info()
	_refresh_tools_list()

func _update_connection_info() -> void:
	if not _connection_info_label:
		return
	var is_running: bool = false
	if _server_core and _server_core.has_method("is_running"):
		is_running = _server_core.is_running()
	var mode: String = "stdio"
	if _plugin and _plugin.get("transport_mode") != null:
		mode = _plugin.transport_mode
	if mode == "http" and is_running:
		var port: int = 9080
		if _plugin and _plugin.get("http_port") != null:
			port = _plugin.http_port
		_connection_info_label.text = _tr("ui.connection_url") % [port]
	elif mode == "stdio" and is_running:
		_connection_info_label.text = _tr("ui.connection_stdio")
	else:
		_connection_info_label.text = ""

func _load_settings() -> void:
	if not _settings_manager:
		return
	var s: Dictionary = _settings_manager.load_settings()
	_transport_mode_option.select(0 if s.transport_mode == "http" else 1)
	_http_port_spin.value = s.http_port
	_auth_enabled_check.button_pressed = s.auth_enabled
	_auth_token_edit.text = s.auth_token
	_sse_enabled_check.button_pressed = s.sse_enabled
	_allow_remote_check.button_pressed = s.allow_remote
	_cors_origin_edit.text = s.cors_origin
	_auto_start_check.button_pressed = s.auto_start
	_log_level_option.select(s.log_level)
	_security_level_option.select(s.security_level)
	_rate_limit_spin.value = s.rate_limit
	if _tunnel_binary_edit:
		_tunnel_binary_edit.text = s.cloudflared_path
	if _asset_provider_option:
		var preset_ids: Array = AssetProviderPresets.preset_ids()
		var preset_idx: int = preset_ids.find(s.get("asset_provider_preset", ""))
		_asset_provider_option.set_block_signals(true)
		_asset_provider_option.select(preset_idx + 1 if preset_idx >= 0 else 0)
		_asset_provider_option.set_block_signals(false)
	if _asset_key_env_edit:
		_asset_key_env_edit.text = s.get("asset_provider_api_key_env", "")
	if _asset_endpoint_edit:
		_asset_endpoint_edit.text = s.get("asset_provider_endpoint", "")
	if _translation_manager and s.language != _translation_manager.get_locale():
		_translation_manager.set_locale(s.language)
		_refresh_translations()
	if _language_option:
		var locales: Array = _translation_manager.get_available_locales() if _translation_manager else ["en", "zh"]
		var idx: int = locales.find(s.language)
		if idx >= 0:
			_language_option.set_block_signals(true)
			_language_option.select(idx)
			_language_option.set_block_signals(false)

func _save_settings() -> void:
	if not _settings_manager:
		return
	var settings: Dictionary = {
		"transport_mode": _transport_mode_option.get_item_text(_transport_mode_option.selected) if _transport_mode_option else "http",
		"http_port": int(_http_port_spin.value) if _http_port_spin else 9080,
		"auth_enabled": _auth_enabled_check.button_pressed if _auth_enabled_check else false,
		"auth_token": _auth_token_edit.text if _auth_token_edit else "",
		"sse_enabled": _sse_enabled_check.button_pressed if _sse_enabled_check else true,
		"allow_remote": _allow_remote_check.button_pressed if _allow_remote_check else false,
		"cors_origin": _cors_origin_edit.text if _cors_origin_edit else "*",
		"auto_start": _auto_start_check.button_pressed if _auto_start_check else false,
		"log_level": _log_level_option.selected if _log_level_option else 2,
		"security_level": _security_level_option.selected if _security_level_option else 1,
		"rate_limit": int(_rate_limit_spin.value) if _rate_limit_spin else 1000,
		"language": _translation_manager.get_locale() if _translation_manager else "en",
		"cloudflared_path": _tunnel_binary_edit.text if _tunnel_binary_edit else "",
		"asset_provider_preset": _selected_asset_preset_id(),
		"asset_provider_api_key_env": _asset_key_env_edit.text if _asset_key_env_edit else "",
		"asset_provider_endpoint": _asset_endpoint_edit.text if _asset_endpoint_edit else ""
	}
	_settings_manager.save_settings(settings)

func _on_language_selected(index: int) -> void:
	var locales: Array = _translation_manager.get_available_locales() if _translation_manager else ["en", "zh"]
	if index >= 0 and index < locales.size():
		_translation_manager.set_locale(locales[index])
		_refresh_translations()
	_debounce_save()

func _debounce_save() -> void:
	if _debounce_timer:
		_debounce_timer.start(0.5)

func _on_debounce_timeout() -> void:
	if _server_core and _server_core.has_method("save_tool_states"):
		_server_core.save_tool_states()
	if _server_core and _server_core.has_method("notify_tool_list_changed"):
		_server_core.notify_tool_list_changed()
	_save_settings()

func update_log(message: String) -> void:
	if Thread.is_main_thread():
		_append_log(message)
	else:
		call_deferred("_append_log", message)

func _append_log(message: String) -> void:
	_log_pending_write.append(message)
	if _log_pending_write.size() >= _log_file_flush_count:
		_flush_log_to_file()

func _flush_log_to_file() -> void:
	if _log_pending_write.is_empty():
		return
	if not _log_file_initialized:
		if FileAccess.file_exists(_log_file_path):
			var existing: FileAccess = FileAccess.open(_log_file_path, FileAccess.READ)
			if existing:
				var size: int = existing.get_length()
				existing.close()
				if size > _max_log_file_size:
					# File too large: keep only the tail (~half max size),
					# discarding older entries from the front.
					var f: FileAccess = FileAccess.open(_log_file_path, FileAccess.READ)
					if f:
						var tail_size: int = _max_log_file_size / 2
						f.seek_end(-tail_size)
						# Skip to the start of a line to avoid truncation mid-line
						f.get_line()  # discard partial first line
						var tail: String = f.get_as_text()
						f.close()
						f = FileAccess.open(_log_file_path, FileAccess.WRITE)
						if f:
							f.store_string("[MCP] Log trimmed (exceeded max size)\n")
							f.store_string(tail)
							f.close()
		var file: FileAccess = FileAccess.open(_log_file_path, FileAccess.WRITE)
		if file:
			file.close()
		_log_file_initialized = true
	var file: FileAccess = FileAccess.open(_log_file_path, FileAccess.READ_WRITE)
	if file:
		file.seek_end()
		for line in _log_pending_write:
			file.store_line(line)
		file.close()
	_log_pending_write.clear()


func refresh() -> void:
	if Thread.is_main_thread():
		_update_ui_state()
		_refresh_tools_list()
	else:
		call_deferred("_update_ui_state")
		call_deferred("_refresh_tools_list")
