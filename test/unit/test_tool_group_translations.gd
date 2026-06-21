extends "res://addons/gut/test.gd"

const PANEL_CSV: String = "res://addons/godot_mcp/translations/mcp_panel.csv"
const TOOL_DESC_CSV: String = "res://addons/godot_mcp/translations/tool_descriptions.csv"

var _classifier = null
var _rows: Dictionary = {}

func before_all():
	_classifier = load("res://addons/godot_mcp/native_mcp/mcp_tool_classifier.gd").new()
	_rows = _load_panel_csv()

func after_all():
	_classifier = null
	_rows.clear()

func _tokenize(line: String) -> PackedStringArray:
	var result: PackedStringArray = []
	var current: String = ""
	var in_quotes: bool = false
	for i in range(line.length()):
		var c: String = line[i]
		if c == "\"":
			in_quotes = not in_quotes
		elif c == "," and not in_quotes:
			result.append(current)
			current = ""
		else:
			current += c
	result.append(current)
	return result

func _load_panel_csv() -> Dictionary:
	var data: Dictionary = {}
	var file: FileAccess = FileAccess.open(PANEL_CSV, FileAccess.READ)
	if not file:
		return data
	var header: PackedStringArray = file.get_line().split(",")
	var key_idx: int = header.find("key")
	var en_idx: int = header.find("en")
	var zh_idx: int = header.find("zh")
	while not file.eof_reached():
		var line: String = file.get_line()
		if line.strip_edges().is_empty():
			continue
		var fields: PackedStringArray = _tokenize(line)
		if fields.size() <= zh_idx or fields.size() <= en_idx or fields.size() <= key_idx:
			continue
		var key: String = fields[key_idx].strip_edges()
		if key.is_empty():
			continue
		data[key] = {"en": fields[en_idx].strip_edges(), "zh": fields[zh_idx].strip_edges()}
	file.close()
	return data

func test_panel_csv_loads():
	assert_gt(_rows.size(), 0, "mcp_panel.csv should parse at least one row")

func test_every_group_has_display_name_translation():
	var groups: Array = _classifier.get_all_groups()
	assert_gt(groups.size(), 0, "Classifier should expose at least one group")
	for group_name in groups:
		var key: String = "group." + group_name
		assert_true(_rows.has(key), "Missing display-name key for group: " + group_name)
		if _rows.has(key):
			assert_false(_rows[key]["en"].is_empty(), "Empty en display name for: " + group_name)
			assert_false(_rows[key]["zh"].is_empty(), "Empty zh display name for: " + group_name)
			assert_ne(_rows[key]["zh"], group_name, "zh name equals raw key: " + group_name)

func test_every_group_has_description_translation():
	var groups: Array = _classifier.get_all_groups()
	for group_name in groups:
		var key: String = "groupdesc." + group_name
		assert_true(_rows.has(key), "Missing description key for group: " + group_name)
		if _rows.has(key):
			assert_false(_rows[key]["en"].is_empty(), "Empty en description for: " + group_name)
			assert_false(_rows[key]["zh"].is_empty(), "Empty zh description for: " + group_name)

func test_tool_descriptions_rows_have_four_columns():
	# Guards against unquoted commas in en/zh shifting the columns so the
	# translation parser reads the wrong field (zh showed English fragments).
	var file: FileAccess = FileAccess.open(TOOL_DESC_CSV, FileAccess.READ)
	assert_ne(file, null, "tool_descriptions.csv should open")
	if file == null:
		return
	var header: PackedStringArray = file.get_line().split(",")
	var expected: int = header.size()
	assert_eq(expected, 4, "Header should have 4 columns: key,source,en,zh")
	var line_no: int = 1
	while not file.eof_reached():
		var line: String = file.get_line()
		line_no += 1
		if line.strip_edges().is_empty():
			continue
		var fields: PackedStringArray = _tokenize(line)
		assert_eq(fields.size(), expected, "Row %d must parse to %d fields" % [line_no, expected])
	file.close()
