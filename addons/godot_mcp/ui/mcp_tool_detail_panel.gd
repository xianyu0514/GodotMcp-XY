@tool
class_name MCPToolDetailPanel
extends PanelContainer

# Right-hand detail pane for the Tool Manager. Shows the selected tool's
# category, type/status, description, parameters, return value, an example
# call and a ready-to-paste AI prompt.

const ACCENT: Color = Color(0.40, 0.62, 1.0)
const DIM: Color = Color(0.6, 0.6, 0.64)
const FAINT: Color = Color(0.52, 0.52, 0.56)

var _translation_manager: MCPTranslationManager = null
var _content: VBoxContainer = null

func setup(translation_manager: MCPTranslationManager = null) -> void:
	_translation_manager = translation_manager
	custom_minimum_size = Vector2(300, 0)
	add_theme_stylebox_override("panel", _panel_style())

	var scroll: ScrollContainer = ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	add_child(scroll)

	_content = VBoxContainer.new()
	_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_content.add_theme_constant_override("separation", 10)
	scroll.add_child(_content)

	show_empty()

func show_empty() -> void:
	_clear()
	var hint: Label = Label.new()
	hint.text = _tr("ui.detail_select_hint")
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.add_theme_color_override("font_color", FAINT)
	hint.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_content.add_child(hint)

func show_tool(info: Dictionary) -> void:
	_clear()
	_build_header(info)
	_build_meta(info)
	_build_description(info)
	_build_behavior(info.get("annotations", {}))
	_build_params(info.get("input_schema", {}))
	_build_returns(info.get("output_schema", {}))
	_build_example(info)
	_build_ai_prompt(info)

func _clear() -> void:
	if not _content:
		return
	for child in _content.get_children():
		child.queue_free()

# --- sections ---

func _build_header(info: Dictionary) -> void:
	var row: HBoxContainer = HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	_content.add_child(row)

	var icon_tex: Texture2D = info.get("icon", null)
	if icon_tex:
		var icon_rect: TextureRect = TextureRect.new()
		icon_rect.texture = icon_tex
		icon_rect.custom_minimum_size = Vector2(28, 28)
		icon_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		row.add_child(icon_rect)

	var title: Label = Label.new()
	title.text = info.get("name", "")
	title.add_theme_font_size_override("font_size", 18)
	title.add_theme_color_override("font_color", Color(0.95, 0.95, 0.98))
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.clip_text = true
	row.add_child(title)

func _build_meta(info: Dictionary) -> void:
	var grid: GridContainer = GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 10)
	grid.add_theme_constant_override("v_separation", 4)
	_content.add_child(grid)

	_meta_row(grid, _tr("ui.detail_category"), info.get("group_display", ""), DIM)

	var is_core: bool = info.get("category", "core") != "supplementary"
	var type_text: String = "CORE" if is_core else "SUPP"
	var type_color: Color = ACCENT if is_core else Color(0.78, 0.66, 0.32)
	_meta_row(grid, _tr("ui.detail_type"), type_text, type_color)

	var enabled: bool = info.get("enabled", true)
	var status_text: String = _tr("ui.detail_enabled") if enabled else _tr("ui.detail_disabled")
	var status_color: Color = Color(0.36, 0.78, 0.42) if enabled else Color(0.78, 0.42, 0.42)
	_meta_row(grid, _tr("ui.detail_status"), status_text, status_color)

func _meta_row(grid: GridContainer, key: String, value: String, value_color: Color) -> void:
	var key_label: Label = Label.new()
	key_label.text = key
	key_label.add_theme_font_size_override("font_size", 11)
	key_label.add_theme_color_override("font_color", FAINT)
	grid.add_child(key_label)

	var value_label: Label = Label.new()
	value_label.text = value
	value_label.add_theme_font_size_override("font_size", 12)
	value_label.add_theme_color_override("font_color", value_color)
	grid.add_child(value_label)

func _build_description(info: Dictionary) -> void:
	var body: VBoxContainer = _section(_tr("ui.detail_description"))
	var label: Label = Label.new()
	label.text = info.get("description", "")
	label.autowrap_mode = TextServer.AUTOWRAP_WORD
	label.add_theme_font_size_override("font_size", 12)
	label.add_theme_color_override("font_color", Color(0.78, 0.78, 0.82))
	body.add_child(label)

func _build_behavior(annotations: Dictionary) -> void:
	var chips: Array = []
	if annotations.get("readOnlyHint", false):
		chips.append(_tr("ui.detail_readonly"))
	if annotations.get("destructiveHint", false):
		chips.append(_tr("ui.detail_destructive"))
	if chips.is_empty():
		return
	var body: VBoxContainer = _section(_tr("ui.detail_behavior"))
	var row: HBoxContainer = HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	body.add_child(row)
	for chip in chips:
		row.add_child(_make_chip(chip))

func _build_params(schema: Dictionary) -> void:
	var body: VBoxContainer = _section(_tr("ui.detail_params"))
	var props: Dictionary = schema.get("properties", {})
	if props.is_empty():
		var none: Label = Label.new()
		none.text = _tr("ui.detail_no_params")
		none.add_theme_font_size_override("font_size", 12)
		none.add_theme_color_override("font_color", FAINT)
		body.add_child(none)
		return
	var required: Array = schema.get("required", [])
	for pname in props:
		body.add_child(_make_param_card(pname, props[pname], required.has(pname)))

func _make_param_card(pname: String, prop: Dictionary, is_required: bool) -> PanelContainer:
	var card: PanelContainer = PanelContainer.new()
	card.add_theme_stylebox_override("panel", _row_style())
	var inner: VBoxContainer = VBoxContainer.new()
	inner.add_theme_constant_override("separation", 2)
	card.add_child(inner)

	var head: HBoxContainer = HBoxContainer.new()
	head.add_theme_constant_override("separation", 6)
	inner.add_child(head)

	var name_label: Label = Label.new()
	name_label.text = pname
	name_label.add_theme_color_override("font_color", Color(0.88, 0.88, 0.92))
	head.add_child(name_label)

	var type_label: Label = Label.new()
	type_label.text = str(prop.get("type", "any"))
	type_label.add_theme_font_size_override("font_size", 10)
	type_label.add_theme_color_override("font_color", ACCENT)
	head.add_child(type_label)

	var spacer: Control = Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(spacer)

	var badge_text: String = _tr("ui.detail_required") if is_required else _tr("ui.detail_optional")
	var badge_color: Color = Color(0.82, 0.46, 0.42) if is_required else FAINT
	var badge: Label = Label.new()
	badge.text = badge_text
	badge.add_theme_font_size_override("font_size", 10)
	badge.add_theme_color_override("font_color", badge_color)
	head.add_child(badge)

	var desc: String = str(prop.get("description", ""))
	if not desc.is_empty():
		var desc_label: Label = Label.new()
		desc_label.text = desc
		desc_label.autowrap_mode = TextServer.AUTOWRAP_WORD
		desc_label.add_theme_font_size_override("font_size", 11)
		desc_label.add_theme_color_override("font_color", DIM)
		inner.add_child(desc_label)

	var hint: String = _enum_or_default_hint(prop)
	if not hint.is_empty():
		var hint_label: Label = Label.new()
		hint_label.text = hint
		hint_label.add_theme_font_size_override("font_size", 10)
		hint_label.add_theme_color_override("font_color", FAINT)
		inner.add_child(hint_label)
	return card

func _enum_or_default_hint(prop: Dictionary) -> String:
	var parts: Array = []
	if prop.has("enum") and prop["enum"] is Array and not (prop["enum"] as Array).is_empty():
		parts.append("enum: " + ", ".join((prop["enum"] as Array).map(func(v): return str(v))))
	if prop.has("default"):
		parts.append("default: " + str(prop["default"]))
	return "   ".join(parts)

func _build_returns(schema: Dictionary) -> void:
	var body: VBoxContainer = _section(_tr("ui.detail_returns"))
	var props: Dictionary = schema.get("properties", {})
	if props.is_empty():
		var none: Label = Label.new()
		none.text = _tr("ui.detail_no_returns")
		none.add_theme_font_size_override("font_size", 12)
		none.add_theme_color_override("font_color", FAINT)
		body.add_child(none)
		return
	for rname in props:
		var row: HBoxContainer = HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)
		var key_label: Label = Label.new()
		key_label.text = rname
		key_label.add_theme_font_size_override("font_size", 11)
		key_label.add_theme_color_override("font_color", Color(0.82, 0.82, 0.86))
		row.add_child(key_label)
		var type_label: Label = Label.new()
		type_label.text = str((props[rname] as Dictionary).get("type", "any"))
		type_label.add_theme_font_size_override("font_size", 10)
		type_label.add_theme_color_override("font_color", FAINT)
		row.add_child(type_label)
		body.add_child(row)

func _build_example(info: Dictionary) -> void:
	var body: VBoxContainer = _section(_tr("ui.detail_example"))
	var call_dict: Dictionary = {
		"name": info.get("name", ""),
		"arguments": _example_args(info.get("input_schema", {})),
	}
	var json_text: String = JSON.stringify(call_dict, "  ")
	body.add_child(_make_code_block(json_text))

func _build_ai_prompt(info: Dictionary) -> void:
	var body: VBoxContainer = _section(_tr("ui.detail_ai_prompt"))
	var prompt: String = _compose_ai_prompt(info)
	body.add_child(_make_code_block(prompt))

func _compose_ai_prompt(info: Dictionary) -> String:
	var lines: Array = []
	lines.append("%s `%s`: %s" % [
		_tr("ui.ai_prompt_use"), info.get("name", ""), info.get("description", "")
	])
	var schema: Dictionary = info.get("input_schema", {})
	var props: Dictionary = schema.get("properties", {})
	var required: Array = schema.get("required", [])
	var req_names: Array = []
	var opt_names: Array = []
	for pname in props:
		if required.has(pname):
			req_names.append(pname)
		else:
			opt_names.append(pname)
	if not req_names.is_empty():
		lines.append("%s: %s" % [_tr("ui.ai_prompt_required"), ", ".join(req_names)])
	if not opt_names.is_empty():
		lines.append("%s: %s" % [_tr("ui.ai_prompt_optional"), ", ".join(opt_names)])
	return "\n".join(lines)

func _example_args(schema: Dictionary) -> Dictionary:
	var args: Dictionary = {}
	var props: Dictionary = schema.get("properties", {})
	for pname in props:
		args[pname] = _example_value(props[pname])
	return args

func _example_value(prop: Dictionary) -> Variant:
	if prop.has("default"):
		return prop["default"]
	if prop.has("enum") and prop["enum"] is Array and not (prop["enum"] as Array).is_empty():
		return (prop["enum"] as Array)[0]
	var by_type: Dictionary = {
		"string": "...",
		"integer": 0,
		"number": 0,
		"boolean": false,
		"array": [],
		"object": {},
	}
	return by_type.get(str(prop.get("type", "")), null)

# --- shared widgets ---

func _section(title: String) -> VBoxContainer:
	var box: VBoxContainer = VBoxContainer.new()
	box.add_theme_constant_override("separation", 4)
	_content.add_child(box)
	var label: Label = Label.new()
	label.text = title
	label.add_theme_font_size_override("font_size", 11)
	label.add_theme_color_override("font_color", ACCENT)
	box.add_child(label)
	return box

func _make_chip(text: String) -> PanelContainer:
	var chip: PanelContainer = PanelContainer.new()
	chip.add_theme_stylebox_override("panel", _row_style())
	var label: Label = Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", 10)
	label.add_theme_color_override("font_color", Color(0.82, 0.78, 0.7))
	chip.add_child(label)
	return chip

func _make_code_block(text: String) -> Control:
	var wrap: VBoxContainer = VBoxContainer.new()
	wrap.add_theme_constant_override("separation", 4)

	var code: TextEdit = TextEdit.new()
	code.text = text
	code.editable = false
	code.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	code.scroll_fit_content_height = true
	code.add_theme_font_size_override("font_size", 11)
	code.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	code.custom_minimum_size = Vector2(0, 40)
	wrap.add_child(code)

	var copy_button: Button = Button.new()
	copy_button.text = _tr("ui.detail_copy")
	copy_button.size_flags_horizontal = Control.SIZE_SHRINK_END
	copy_button.pressed.connect(_on_copy_pressed.bind(text, copy_button))
	wrap.add_child(copy_button)
	return wrap

func _on_copy_pressed(text: String, button: Button) -> void:
	DisplayServer.clipboard_set(text)
	button.text = _tr("ui.detail_copied")
	await get_tree().create_timer(1.2).timeout
	if is_instance_valid(button):
		button.text = _tr("ui.detail_copy")

func _panel_style() -> StyleBoxFlat:
	var style: StyleBoxFlat = StyleBoxFlat.new()
	style.bg_color = Color(1, 1, 1, 0.02)
	style.border_color = Color(1, 1, 1, 0.06)
	style.set_border_width_all(1)
	style.set_corner_radius_all(5)
	style.content_margin_left = 12
	style.content_margin_right = 12
	style.content_margin_top = 12
	style.content_margin_bottom = 12
	return style

func _row_style() -> StyleBoxFlat:
	var style: StyleBoxFlat = StyleBoxFlat.new()
	style.bg_color = Color(1, 1, 1, 0.03)
	style.set_corner_radius_all(4)
	style.content_margin_left = 8
	style.content_margin_right = 8
	style.content_margin_top = 5
	style.content_margin_bottom = 5
	return style

func _tr(key: String) -> String:
	if _translation_manager:
		return _translation_manager.get_text(key)
	return key
