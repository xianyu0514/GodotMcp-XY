@tool
class_name MCPCategoryNavItem
extends Button

signal category_selected(category_key: String)

var category_key: String = ""
var _base_label: String = ""
var _enabled: int = 0
var _total: int = 0
var _body_font_size: int = 15
var _ui_scale: float = 1.0
var _compact: bool = false

func setup(
	key: String,
	label: String,
	icon_tex: Texture2D,
	group: ButtonGroup,
	body_font_size: int = 15,
	ui_scale: float = 1.0,
	compact: bool = false
) -> void:
	category_key = key
	_base_label = label
	_body_font_size = maxi(body_font_size, 15)
	_ui_scale = maxf(ui_scale, 0.75)
	_compact = compact
	toggle_mode = true
	flat = true
	focus_mode = Control.FOCUS_NONE
	alignment = HORIZONTAL_ALIGNMENT_LEFT
	clip_text = true
	button_group = group
	custom_minimum_size = Vector2(0, _s(36 if _compact else 44))
	add_theme_font_size_override("font_size", maxi(_body_font_size - 1, 14) if _compact else _body_font_size)
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	if icon_tex:
		icon = icon_tex
	add_theme_stylebox_override("normal", _style(Color(1, 1, 1, 0.0), false))
	add_theme_stylebox_override("hover", _style(Color(1, 1, 1, 0.06), false))
	add_theme_stylebox_override("pressed", _style(Color(0.30, 0.50, 0.95, 0.28), true))
	add_theme_stylebox_override("hover_pressed", _style(Color(0.30, 0.50, 0.95, 0.28), true))
	add_theme_stylebox_override("focus", _style(Color(1, 1, 1, 0.0), false))
	_render()
	toggled.connect(_on_toggled)

func set_count(enabled: int, total: int) -> void:
	_enabled = enabled
	_total = total
	_render()

func set_label(label: String) -> void:
	_base_label = label
	_render()

func set_selected(value: bool) -> void:
	set_block_signals(true)
	button_pressed = value
	set_block_signals(false)

func _render() -> void:
	if _total > 0:
		text = "%s   %d/%d" % [_base_label, _enabled, _total]
	else:
		text = _base_label

func _style(bg: Color, accent: bool) -> StyleBoxFlat:
	var style: StyleBoxFlat = StyleBoxFlat.new()
	style.bg_color = bg
	style.set_corner_radius_all(int(_s(5)))
	style.content_margin_left = _s(9 if _compact else 10)
	style.content_margin_right = _s(9 if _compact else 10)
	style.content_margin_top = _s(5 if _compact else 8)
	style.content_margin_bottom = _s(5 if _compact else 8)
	if accent:
		style.border_width_left = int(_s(3))
		style.border_color = Color(0.40, 0.62, 1.0, 0.95)
	return style

func _on_toggled(pressed: bool) -> void:
	if pressed:
		category_selected.emit(category_key)

func _s(value: float) -> float:
	return roundf(value * _ui_scale)
