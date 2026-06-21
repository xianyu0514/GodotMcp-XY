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

var _tab_container: TabContainer = null
var _debounce_timer: Timer = null
var _group_widgets: Dictionary = {}
var _tools_search_edit: LineEdit = null
var _core_group_names: Array = []
var _supp_group_names: Array = []
var _category_nav_container: VBoxContainer = null
var _nav_group: ButtonGroup = null
var _nav_items: Dictionary = {}
var _selected_category: String = "__recommended__"
var _detail_title: Label = null
var _detail_desc: Label = null
var _detail_count: Label = null
var _enable_all_button: Button = null
var _disable_all_button: Button = null
var _tool_detail_panel: MCPToolDetailPanel = null
var _selected_tool_name: String = ""
var _language_option: OptionButton = null

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
	_create_ui()
	_debounce_timer = Timer.new()
	_debounce_timer.one_shot = true
	_debounce_timer.timeout.connect(_on_debounce_timeout)
	add_child(_debounce_timer)

func _exit_tree() -> void:
	_flush_log_to_file()
	if _debounce_timer:
		_debounce_timer.stop()

func set_plugin(plugin: EditorPlugin) -> void:
	_plugin = plugin
	if _translation_manager == null:
		_translation_manager = MCPTranslationManager.new()
		_translation_manager.load_all()
	if _settings_manager == null:
		_settings_manager = MCPSettingsManager.new()
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

func _create_status_bar() -> HBoxContainer:
	var bar: HBoxContainer = HBoxContainer.new()
	bar.add_theme_constant_override("separation", 8)

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

	_start_button = Button.new()
	_start_button.text = _tr("ui.start_server")
	_start_button.pressed.connect(_on_start_pressed)
	bar.add_child(_start_button)

	_stop_button = Button.new()
	_stop_button.text = _tr("ui.stop_server")
	_stop_button.pressed.connect(_on_stop_pressed)
	bar.add_child(_stop_button)

	return bar

func _create_settings_tab() -> VBoxContainer:
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
	content.add_theme_constant_override("separation", 6)
	margin.add_child(content)

	_transport_title_label = Label.new()
	_transport_title_label.text = _tr("ui.transport_settings")
	_transport_title_label.add_theme_font_size_override("font_size", 13)
	content.add_child(_transport_title_label)

	var transport_hbox: HBoxContainer = HBoxContainer.new()
	content.add_child(transport_hbox)

	_transport_mode_label = Label.new()
	_transport_mode_label.text = _tr("ui.transport_mode")
	transport_hbox.add_child(_transport_mode_label)

	_transport_mode_option = OptionButton.new()
	_transport_mode_option.add_item("http", 1)
	_transport_mode_option.item_selected.connect(_on_transport_mode_selected)
	transport_hbox.add_child(_transport_mode_option)

	_http_config_container = VBoxContainer.new()
	_http_config_container.add_theme_constant_override("separation", 4)
	content.add_child(_http_config_container)

	var port_hbox: HBoxContainer = HBoxContainer.new()
	_http_config_container.add_child(port_hbox)

	_http_port_label = Label.new()
	_http_port_label.text = _tr("ui.http_port")
	port_hbox.add_child(_http_port_label)

	_http_port_spin = SpinBox.new()
	_http_port_spin.min_value = 1024
	_http_port_spin.max_value = 65535
	_http_port_spin.value = 9080
	_http_port_spin.step = 1
	_http_port_spin.value_changed.connect(_on_http_port_changed)
	port_hbox.add_child(_http_port_spin)

	var auth_hbox: HBoxContainer = HBoxContainer.new()
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

	var cors_hbox: HBoxContainer = HBoxContainer.new()
	_http_config_container.add_child(cors_hbox)

	_cors_origin_label = Label.new()
	_cors_origin_label.text = _tr("ui.cors_origin")
	cors_hbox.add_child(_cors_origin_label)

	_cors_origin_edit = LineEdit.new()
	_cors_origin_edit.text = "*"
	_cors_origin_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_cors_origin_edit.text_changed.connect(_on_cors_origin_changed)
	cors_hbox.add_child(_cors_origin_edit)

	_http_config_container.visible = false

	content.add_child(HSeparator.new())

	_auto_start_check = CheckBox.new()
	_auto_start_check.text = _tr("ui.auto_start")
	_auto_start_check.toggled.connect(_on_auto_start_toggled)
	content.add_child(_auto_start_check)

	_vibe_coding_mode_check = CheckBox.new()
	_vibe_coding_mode_check.text = _tr("ui.vibe_coding_mode")
	_vibe_coding_mode_check.toggled.connect(_on_vibe_coding_mode_toggled)
	content.add_child(_vibe_coding_mode_check)

	var log_hbox: HBoxContainer = HBoxContainer.new()
	content.add_child(log_hbox)

	_log_level_label = Label.new()
	_log_level_label.text = _tr("ui.log_level")
	log_hbox.add_child(_log_level_label)

	_log_level_option = OptionButton.new()
	_log_level_option.add_item("ERROR", 0)
	_log_level_option.add_item("WARN", 1)
	_log_level_option.add_item("INFO", 2)
	_log_level_option.add_item("DEBUG", 3)
	_log_level_option.item_selected.connect(_on_log_level_selected)
	log_hbox.add_child(_log_level_option)

	var security_hbox: HBoxContainer = HBoxContainer.new()
	content.add_child(security_hbox)

	_security_label = Label.new()
	_security_label.text = _tr("ui.security")
	security_hbox.add_child(_security_label)

	_security_level_option = OptionButton.new()
	_security_level_option.add_item("PERMISSIVE", 0)
	_security_level_option.add_item("STRICT", 1)
	_security_level_option.item_selected.connect(_on_security_level_selected)
	security_hbox.add_child(_security_level_option)

	var rate_hbox: HBoxContainer = HBoxContainer.new()
	content.add_child(rate_hbox)

	_rate_limit_label = Label.new()
	_rate_limit_label.text = _tr("ui.rate_limit")
	rate_hbox.add_child(_rate_limit_label)

	_rate_limit_spin = SpinBox.new()
	_rate_limit_spin.min_value = 10
	_rate_limit_spin.max_value = 2000
	_rate_limit_spin.step = 10
	_rate_limit_spin.value = 1000
	_rate_limit_spin.value_changed.connect(_on_rate_limit_changed)
	rate_hbox.add_child(_rate_limit_spin)

	content.add_child(HSeparator.new())

	var lang_hbox: HBoxContainer = HBoxContainer.new()
	content.add_child(lang_hbox)

	_language_label = Label.new()
	_language_label.text = _tr("ui.language")
	lang_hbox.add_child(_language_label)

	_language_option = OptionButton.new()
	_language_option.add_item(_tr("ui.english"), 0)
	_language_option.add_item(_tr("ui.chinese"), 1)
	_language_option.item_selected.connect(_on_language_selected)
	lang_hbox.add_child(_language_option)

	content.add_child(HSeparator.new())

	_open_log_button = Button.new()
	_open_log_button.text = _tr("ui.open_log")
	_open_log_button.pressed.connect(_open_log_file)
	_open_log_button.size_flags_horizontal = Control.SIZE_SHRINK_END
	content.add_child(_open_log_button)

	return tab

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

	_tools_search_edit = LineEdit.new()
	_tools_search_edit.placeholder_text = _tr("ui.search_placeholder")
	_tools_search_edit.clear_button_enabled = true
	_tools_search_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_tools_search_edit.text_changed.connect(_on_tools_search_changed)
	content.add_child(_tools_search_edit)

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
		_status_label.add_theme_color_override("font_color", Color.GREEN)
	else:
		_status_label.text = _tr("ui.status_stopped")
		_status_label.add_theme_color_override("font_color", Color.RED)

	if _start_button:
		_start_button.disabled = is_running
	if _stop_button:
		_stop_button.disabled = not is_running

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
	_apply_view()

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
	if _nav_items.has("__all__"):
		_nav_items["__all__"].set_count(core_enabled + supp_enabled, core_total + supp_total)

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
		"language": _translation_manager.get_locale() if _translation_manager else "en"
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
