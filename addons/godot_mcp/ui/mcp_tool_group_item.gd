@tool
class_name MCPToolGroupItem
extends VBoxContainer

signal group_toggled(group_name: String, enabled: bool)
signal item_toggled(tool_name: String, enabled: bool)
signal tool_selected(tool_name: String)

var _group_name: String = ""
var _is_collapsed: bool = false
var _group_check: CheckBox = null
var _translation_manager: MCPTranslationManager = null
var _collapse_button: Button = null
var _count_label: Label = null
var _desc_label: Label = null
var _tool_container: VBoxContainer = null

func setup(group_name: String, items: Array, translation_manager = null) -> void:
	_group_name = group_name
	_translation_manager = translation_manager
	add_theme_constant_override("separation", 0)

	var card: PanelContainer = PanelContainer.new()
	card.add_theme_stylebox_override("panel", _make_card_style())
	add_child(card)

	var inner: VBoxContainer = VBoxContainer.new()
	inner.add_theme_constant_override("separation", 4)
	card.add_child(inner)

	var header: HBoxContainer = HBoxContainer.new()
	header.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_theme_constant_override("separation", 6)
	inner.add_child(header)

	_collapse_button = Button.new()
	_collapse_button.text = "▼"
	_collapse_button.flat = true
	_collapse_button.focus_mode = Control.FOCUS_NONE
	_collapse_button.tooltip_text = "Collapse/Expand"
	_collapse_button.pressed.connect(_toggle_collapse)
	header.add_child(_collapse_button)

	_group_check = CheckBox.new()
	_group_check.text = _get_group_display_name()
	_group_check.add_theme_font_size_override("font_size", 14)
	_group_check.add_theme_color_override("font_color", Color(0.92, 0.92, 0.95))
	var group_desc: String = _get_group_description()
	if not group_desc.is_empty():
		_group_check.tooltip_text = group_desc
	_group_check.toggled.connect(_on_group_toggled)
	header.add_child(_group_check)

	var spacer: Control = Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(spacer)

	_count_label = Label.new()
	_count_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_count_label.add_theme_font_size_override("font_size", 11)
	_count_label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.62))
	header.add_child(_count_label)

	if not group_desc.is_empty():
		_desc_label = Label.new()
		_desc_label.text = group_desc
		_desc_label.autowrap_mode = TextServer.AUTOWRAP_WORD
		_desc_label.add_theme_font_size_override("font_size", 11)
		_desc_label.add_theme_color_override("font_color", Color(0.58, 0.58, 0.62))
		inner.add_child(_desc_label)

	_tool_container = VBoxContainer.new()
	_tool_container.name = "ToolContainer"
	_tool_container.add_theme_constant_override("separation", 2)
	inner.add_child(_tool_container)

	for item in items:
		var tool_name: String = item.get("name", "")
		var description: String = item.get("description", "")
		var enabled: bool = item.get("enabled", true)
		var category: String = item.get("category", "core")

		var translated_desc: String = _tr(tool_name)
		if translated_desc != tool_name:
			description = translated_desc

		var tool_item: MCPToolItem = MCPToolItem.new()
		tool_item.setup(tool_name, description, enabled, category, _group_name)
		tool_item.tool_toggled.connect(_on_tool_item_toggled)
		tool_item.tool_selected.connect(_on_tool_item_selected)
		_tool_container.add_child(tool_item)

	_update_count()

func _make_card_style() -> StyleBoxFlat:
	var style: StyleBoxFlat = StyleBoxFlat.new()
	style.bg_color = Color(1, 1, 1, 0.035)
	style.border_color = Color(1, 1, 1, 0.06)
	style.set_border_width_all(1)
	style.set_corner_radius_all(5)
	style.content_margin_left = 10
	style.content_margin_right = 10
	style.content_margin_top = 8
	style.content_margin_bottom = 8
	return style

func get_group_name() -> String:
	return _group_name

func get_all_tools_enabled() -> bool:
	var container: VBoxContainer = get_tool_container()
	if container == null:
		return true
	for child in container.get_children():
		var tool_item: MCPToolItem = child as MCPToolItem
		if tool_item and not tool_item.is_enabled():
			return false
	return true

func set_group_enabled(enabled: bool) -> void:
	var container: VBoxContainer = get_tool_container()
	if container == null:
		return
	for child in container.get_children():
		var tool_item: MCPToolItem = child as MCPToolItem
		if tool_item:
			tool_item.set_enabled(enabled)

func get_tool_container() -> VBoxContainer:
	return _tool_container

func get_tool_items() -> Array:
	var items: Array = []
	if _tool_container:
		for child in _tool_container.get_children():
			var tool_item: MCPToolItem = child as MCPToolItem
			if tool_item:
				items.append(tool_item)
	return items

func _get_desc_label() -> Label:
	return _desc_label

# Show or hide everything below the header row (description + tool list).
func _set_body_visible(body_visible: bool) -> void:
	if _tool_container:
		_tool_container.visible = body_visible
	if _desc_label:
		_desc_label.visible = body_visible
	_update_collapse_glyph(body_visible)

func _tr(key: String) -> String:
	if _translation_manager:
		return _translation_manager.get_text(key)
	return key

func _get_group_display_name() -> String:
	var key: String = "group." + _group_name
	var translated: String = _tr(key)
	if translated == key:
		return _group_name
	return translated

func _get_group_description() -> String:
	var key: String = "groupdesc." + _group_name
	var translated: String = _tr(key)
	if translated == key:
		return ""
	return translated

func _toggle_collapse() -> void:
	_is_collapsed = not _is_collapsed
	_set_body_visible(not _is_collapsed)

func _update_collapse_glyph(expanded: bool) -> void:
	if _collapse_button:
		_collapse_button.text = "▼" if expanded else "▶"

# Filter tools by a lowercase query. A match on the group name reveals all of
# its tools. Returns how many tool items remain visible.
func apply_filter(query: String) -> int:
	var container: VBoxContainer = get_tool_container()
	if container == null:
		return 0
	var group_matches: bool = (not query.is_empty()) and (
		_group_name.to_lower().contains(query)
		or _get_group_display_name().to_lower().contains(query)
		or _get_group_description().to_lower().contains(query)
	)
	var visible_count: int = 0
	for child in container.get_children():
		var tool_item: MCPToolItem = child as MCPToolItem
		if tool_item == null:
			continue
		var is_match: bool = query.is_empty() or group_matches or tool_item.matches_filter(query)
		tool_item.visible = is_match
		if is_match:
			visible_count += 1
	if query.is_empty():
		_set_body_visible(not _is_collapsed)
	else:
		_set_body_visible(visible_count > 0)
	return visible_count

func _on_group_toggled(button_pressed: bool) -> void:
	set_group_enabled(button_pressed)
	group_toggled.emit(_group_name, button_pressed)
	_update_count()

func _on_tool_item_toggled(tool_name: String, enabled: bool) -> void:
	_update_count()
	item_toggled.emit(tool_name, enabled)

func _on_tool_item_selected(tool_name: String) -> void:
	tool_selected.emit(tool_name)

func _update_count() -> void:
	var container: VBoxContainer = get_tool_container()
	if container == null:
		return
	var total: int = 0
	var enabled: int = 0
	for child in container.get_children():
		var tool_item: MCPToolItem = child as MCPToolItem
		if tool_item:
			total += 1
			if tool_item.is_enabled():
				enabled += 1

	if _count_label:
		_count_label.text = _tr("ui.enabled_format") % [enabled, total]

	if _group_check:
		_group_check.set_block_signals(true)
		_group_check.button_pressed = (enabled == total and total > 0)
		_group_check.set_block_signals(false)
