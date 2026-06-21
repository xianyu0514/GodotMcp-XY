@tool
class_name MCPCategoryNavItem
extends Button

signal category_selected(category_key: String)

var category_key: String = ""
var _base_label: String = ""
var _enabled: int = 0
var _total: int = 0

func setup(key: String, label: String, icon_tex: Texture2D, group: ButtonGroup) -> void:
	category_key = key
	_base_label = label
	toggle_mode = true
	flat = true
	focus_mode = Control.FOCUS_NONE
	alignment = HORIZONTAL_ALIGNMENT_LEFT
	clip_text = true
	button_group = group
	custom_minimum_size = Vector2(0, 30)
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
	style.set_corner_radius_all(4)
	style.content_margin_left = 8
	style.content_margin_right = 8
	style.content_margin_top = 4
	style.content_margin_bottom = 4
	if accent:
		style.border_width_left = 2
		style.border_color = Color(0.40, 0.62, 1.0, 0.95)
	return style

func _on_toggled(pressed: bool) -> void:
	if pressed:
		category_selected.emit(category_key)
