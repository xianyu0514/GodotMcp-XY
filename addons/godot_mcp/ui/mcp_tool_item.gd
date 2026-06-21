@tool
class_name MCPToolItem
extends HBoxContainer

var _tool_name: String = ""
var _tool_category: String = ""
var _tool_group: String = ""
var _description: String = ""

signal tool_toggled(tool_name: String, enabled: bool)

func setup(name: String, description: String, enabled: bool, category: String, group: String) -> void:
	_tool_name = name
	_tool_category = category
	_tool_group = group
	_description = description

	add_theme_constant_override("separation", 8)

	var check: CheckBox = CheckBox.new()
	check.text = name
	check.button_pressed = enabled
	check.custom_minimum_size = Vector2(210, 0)
	check.toggled.connect(_on_check_toggled)
	add_child(check)

	var badge: Label = Label.new()
	badge.text = _get_badge_text()
	badge.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	badge.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	badge.custom_minimum_size = Vector2(46, 0)
	badge.add_theme_font_size_override("font_size", 9)
	if category == "supplementary":
		badge.add_theme_color_override("font_color", Color(0.78, 0.66, 0.32))
	else:
		badge.add_theme_color_override("font_color", Color(0.36, 0.72, 0.72))
	add_child(badge)

	var desc_label: Label = Label.new()
	desc_label.text = description
	desc_label.autowrap_mode = TextServer.AUTOWRAP_WORD
	desc_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	desc_label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	desc_label.mouse_filter = Control.MOUSE_FILTER_PASS
	desc_label.add_theme_font_size_override("font_size", 11)
	desc_label.add_theme_color_override("font_color", Color(0.62, 0.62, 0.66))
	add_child(desc_label)

func get_tool_name() -> String:
	return _tool_name

func matches_filter(query: String) -> bool:
	if query.is_empty():
		return true
	return _tool_name.to_lower().contains(query) or _description.to_lower().contains(query)

func is_enabled() -> bool:
	var check: CheckBox = get_child(0) as CheckBox
	return check.button_pressed if check else true

func set_enabled(enabled: bool) -> void:
	var check: CheckBox = get_child(0) as CheckBox
	if check:
		check.button_pressed = enabled

func _on_check_toggled(button_pressed: bool) -> void:
	tool_toggled.emit(_tool_name, button_pressed)

func _get_badge_text() -> String:
	if _tool_category == "supplementary":
		return "SUPP"
	return "CORE"
