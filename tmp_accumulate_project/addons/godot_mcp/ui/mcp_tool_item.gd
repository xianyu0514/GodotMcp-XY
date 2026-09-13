@tool
class_name MCPToolItem
extends HBoxContainer

signal tool_toggled(tool_name: String, enabled: bool)
signal tool_selected(tool_name: String)

var _tool_name: String = ""
var _tool_category: String = ""
var _tool_group: String = ""
var _description: String = ""
var _check: CheckBox = null
var _selected: bool = false
var _hover: bool = false
var _body_font_size: int = 15
var _ui_scale: float = 1.0

func setup(
	name: String,
	description: String,
	enabled: bool,
	category: String,
	group: String,
	body_font_size: int = 15,
	ui_scale: float = 1.0
) -> void:
	_tool_name = name
	_tool_category = category
	_tool_group = group
	_description = description
	_body_font_size = maxi(body_font_size, 15)
	_ui_scale = maxf(ui_scale, 0.75)

	custom_minimum_size = Vector2(0, _s(52))
	add_theme_constant_override("separation", int(_s(10)))
	mouse_filter = Control.MOUSE_FILTER_STOP
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	mouse_entered.connect(_on_mouse_entered)
	mouse_exited.connect(_on_mouse_exited)

	_check = CheckBox.new()
	_check.button_pressed = enabled
	_check.custom_minimum_size.x = _s(26)
	_check.toggled.connect(_on_check_toggled)
	add_child(_check)

	var name_label: Label = Label.new()
	name_label.text = name
	name_label.tooltip_text = name
	name_label.custom_minimum_size = Vector2(_s(220), 0)
	name_label.clip_text = true
	name_label.mouse_filter = Control.MOUSE_FILTER_PASS
	name_label.add_theme_font_size_override("font_size", _body_font_size)
	name_label.add_theme_color_override("font_color", Color(0.91, 0.91, 0.94))
	add_child(name_label)

	var badge: Label = Label.new()
	badge.text = _get_badge_text()
	badge.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	badge.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	badge.custom_minimum_size = Vector2(_s(52), 0)
	badge.mouse_filter = Control.MOUSE_FILTER_PASS
	badge.add_theme_font_size_override("font_size", maxi(_body_font_size - 2, 13))
	if category == "supplementary":
		badge.add_theme_color_override("font_color", Color(0.78, 0.66, 0.32))
	else:
		badge.add_theme_color_override("font_color", Color(0.36, 0.72, 0.72))
	add_child(badge)

	var desc_label: Label = Label.new()
	desc_label.text = description
	desc_label.tooltip_text = description
	desc_label.autowrap_mode = TextServer.AUTOWRAP_WORD
	desc_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	desc_label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	desc_label.mouse_filter = Control.MOUSE_FILTER_PASS
	desc_label.add_theme_font_size_override("font_size", maxi(_body_font_size - 1, 14))
	desc_label.add_theme_color_override("font_color", Color(0.75, 0.75, 0.80))
	add_child(desc_label)

func get_tool_name() -> String:
	return _tool_name

func matches_filter(query: String) -> bool:
	if query.is_empty():
		return true
	return _tool_name.to_lower().contains(query) or _description.to_lower().contains(query)

func is_enabled() -> bool:
	return _check.button_pressed if _check else true

func set_enabled(enabled: bool) -> void:
	if _check:
		_check.button_pressed = enabled

func set_selected(value: bool) -> void:
	if _selected == value:
		return
	_selected = value
	queue_redraw()

func is_selected() -> bool:
	return _selected

func _on_check_toggled(button_pressed: bool) -> void:
	tool_toggled.emit(_tool_name, button_pressed)

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb: InputEventMouseButton = event
		if mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
			tool_selected.emit(_tool_name)

func _on_mouse_entered() -> void:
	_hover = true
	queue_redraw()

func _on_mouse_exited() -> void:
	_hover = false
	queue_redraw()

func _draw() -> void:
	var color: Color = Color(0, 0, 0, 0)
	if _selected:
		color = Color(0.30, 0.50, 0.95, 0.16)
	elif _hover:
		color = Color(1, 1, 1, 0.045)
	if color.a > 0.0:
		var style: StyleBoxFlat = StyleBoxFlat.new()
		style.bg_color = color
		style.set_corner_radius_all(int(_s(5)))
		if _selected:
			style.border_width_left = int(_s(3))
			style.border_color = Color(0.42, 0.64, 1.0, 0.95)
		draw_style_box(style, Rect2(Vector2.ZERO, size))

func _s(value: float) -> float:
	return roundf(value * _ui_scale)

func _get_badge_text() -> String:
	if _tool_category == "supplementary":
		return "SUPP"
	return "CORE"
