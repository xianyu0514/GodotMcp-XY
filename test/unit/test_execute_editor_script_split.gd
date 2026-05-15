extends "res://addons/gut/test.gd"

var _debug_tools: RefCounted = null

func before_each():
	_debug_tools = load("res://addons/godot_mcp/tools/debug_tools_native.gd").new()

func after_each():
	_debug_tools = null

func test_count_indent_4_spaces():
	assert_eq(_debug_tools._count_indent("    hello"), 4, "4 spaces")

func test_count_indent_1_tab():
	assert_eq(_debug_tools._count_indent("\thello"), 4, "1 tab = 4")

func test_count_indent_mixed():
	assert_eq(_debug_tools._count_indent("\t  hello"), 6, "tab+2spaces")

func test_count_indent_none():
	assert_eq(_debug_tools._count_indent("hello"), 0, "no indent")

func test_count_indent_empty():
	assert_eq(_debug_tools._count_indent(""), 0, "empty")

func test_count_indent_8_spaces():
	assert_eq(_debug_tools._count_indent("        hello"), 8, "8 spaces")

func test_count_indent_2_tabs():
	assert_eq(_debug_tools._count_indent("\t\thello"), 8, "2 tabs")

func test_spaces_to_tabs_simple():
	var result: String = _debug_tools._spaces_to_tabs("    var x = 1")
	assert_eq(result, "\tvar x = 1", "4 spaces to 1 tab")

func test_spaces_to_tabs_nested():
	var result: String = _debug_tools._spaces_to_tabs("        var x = 1")
	assert_eq(result, "\t\tvar x = 1", "8 spaces to 2 tabs")

func test_spaces_to_tabs_no_indent():
	var result: String = _debug_tools._spaces_to_tabs("var x = 1")
	assert_eq(result, "var x = 1", "no change for no indent")

func test_spaces_to_tabs_mixed_line():
	var result: String = _debug_tools._spaces_to_tabs("    if true:\n        print()")
	assert_eq(result, "\tif true:\n\t\tprint()", "multi-line indent")

func test_spaces_to_tabs_already_tab():
	var result: String = _debug_tools._spaces_to_tabs("\tvar x = 1")
	assert_eq(result, "\tvar x = 1", "already tab no change")

func test_spaces_to_tabs_2_spaces():
	var result: String = _debug_tools._spaces_to_tabs("  var x = 1")
	assert_eq(result, "  var x = 1", "2 spaces not converted")

func test_spaces_to_tabs_empty_line():
	var result: String = _debug_tools._spaces_to_tabs("")
	assert_eq(result, "", "empty line unchanged")

func test_code_split_simple_func():
	var code = "func my_helper():\n    return 42\n_custom_print(str(my_helper()))"
	var class_lines: PackedStringArray = []
	var body_lines: PackedStringArray = []
	var in_block: bool = false
	var block_indent: int = -1
	for line in code.split("\n"):
		var stripped: String = line.strip_edges()
		if stripped.is_empty():
			if in_block:
				class_lines.append(line)
			else:
				body_lines.append(line)
			continue
		var indent: int = _debug_tools._count_indent(line)
		if in_block:
			if indent > block_indent or (indent == block_indent and (stripped.begins_with("@") or stripped.begins_with("pass"))):
				class_lines.append(line)
				continue
			else:
				in_block = false
		if stripped.begins_with("func ") or stripped.begins_with("class ") or stripped.begins_with("enum "):
			in_block = true
			block_indent = indent
			class_lines.append(line)
		else:
			body_lines.append(line)
	assert_eq(class_lines.size(), 2, "func header + body in class level")
	assert_eq(body_lines.size(), 1, "call in body")
	assert_true(class_lines[0].strip_edges().begins_with("func "), "first class line is func")

func test_code_split_class_with_body():
	var code = "class MyVec:\n    var x = 0\n    var y = 0\n_custom_print(\"done\")"
	var class_lines: PackedStringArray = []
	var body_lines: PackedStringArray = []
	var in_block: bool = false
	var block_indent: int = -1
	for line in code.split("\n"):
		var stripped: String = line.strip_edges()
		if stripped.is_empty():
			if in_block:
				class_lines.append(line)
			else:
				body_lines.append(line)
			continue
		var indent: int = _debug_tools._count_indent(line)
		if in_block:
			if indent > block_indent or (indent == block_indent and (stripped.begins_with("@") or stripped.begins_with("pass"))):
				class_lines.append(line)
				continue
			else:
				in_block = false
		if stripped.begins_with("func ") or stripped.begins_with("class ") or stripped.begins_with("enum "):
			in_block = true
			block_indent = indent
			class_lines.append(line)
		else:
			body_lines.append(line)
	assert_eq(class_lines.size(), 3, "class header + 2 member vars")
	assert_eq(body_lines.size(), 1, "call in body")

func test_code_split_enum():
	var code = "enum Dir {NORTH, SOUTH, EAST, WEST}\n_custom_print(str(Dir.EAST))"
	var class_lines: PackedStringArray = []
	var body_lines: PackedStringArray = []
	var in_block: bool = false
	var block_indent: int = -1
	for line in code.split("\n"):
		var stripped: String = line.strip_edges()
		if stripped.is_empty():
			if in_block:
				class_lines.append(line)
			else:
				body_lines.append(line)
			continue
		var indent: int = _debug_tools._count_indent(line)
		if in_block:
			if indent > block_indent or (indent == block_indent and (stripped.begins_with("@") or stripped.begins_with("pass"))):
				class_lines.append(line)
				continue
			else:
				in_block = false
		if stripped.begins_with("func ") or stripped.begins_with("class ") or stripped.begins_with("enum "):
			in_block = true
			block_indent = indent
			class_lines.append(line)
		else:
			body_lines.append(line)
	assert_eq(class_lines.size(), 1, "enum in class level")
	assert_eq(body_lines.size(), 1, "call in body")

func test_code_split_no_declarations():
	var code = "var x = 1\n_custom_print(str(x))"
	var class_lines: PackedStringArray = []
	var body_lines: PackedStringArray = []
	var in_block: bool = false
	var block_indent: int = -1
	for line in code.split("\n"):
		var stripped: String = line.strip_edges()
		if stripped.is_empty():
			if in_block:
				class_lines.append(line)
			else:
				body_lines.append(line)
			continue
		var indent: int = _debug_tools._count_indent(line)
		if in_block:
			if indent > block_indent or (indent == block_indent and (stripped.begins_with("@") or stripped.begins_with("pass"))):
				class_lines.append(line)
				continue
			else:
				in_block = false
		if stripped.begins_with("func ") or stripped.begins_with("class ") or stripped.begins_with("enum "):
			in_block = true
			block_indent = indent
			class_lines.append(line)
		else:
			body_lines.append(line)
	assert_eq(class_lines.size(), 0, "no class-level declarations")
	assert_eq(body_lines.size(), 2, "all lines in body")

func test_normalize_indentation_leading():
	var code = "    var x = 1\n    if x > 0:\n        _custom_print(\"pos\")"
	var result: String = _debug_tools._normalize_indentation(code)
	assert_eq(result, "var x = 1\nif x > 0:\n    _custom_print(\"pos\")", "leading indent stripped")
