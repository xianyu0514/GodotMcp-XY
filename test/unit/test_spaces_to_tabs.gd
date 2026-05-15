extends "res://addons/gut/test.gd"

var _debug_tools: RefCounted = null
var _script_tools: RefCounted = null

func before_each():
	_debug_tools = load("res://addons/godot_mcp/tools/debug_tools_native.gd").new()
	_script_tools = load("res://addons/godot_mcp/tools/script_tools_native.gd").new()

func after_each():
	_debug_tools = null
	_script_tools = null

func test_spaces_to_tabs_no_indent():
	var result: String = _debug_tools._spaces_to_tabs("print('hello')")
	assert_eq(result, "print('hello')", "No change for no indent")

func test_spaces_to_tabs_single_level():
	var result: String = _debug_tools._spaces_to_tabs("    print('hello')")
	assert_eq(result, "\tprint('hello')", "4 spaces to 1 tab")

func test_spaces_to_tabs_two_levels():
	var result: String = _debug_tools._spaces_to_tabs("        print('hello')")
	assert_eq(result, "\t\tprint('hello')", "8 spaces to 2 tabs")

func test_spaces_to_tabs_mixed_lines():
	var code: String = "if true:\n    print('a')\n    if true:\n        print('b')\nprint('c')"
	var result: String = _debug_tools._spaces_to_tabs(code)
	var expected: String = "if true:\n\tprint('a')\n\tif true:\n\t\tprint('b')\nprint('c')"
	assert_eq(result, expected, "Mixed indent levels")

func test_spaces_to_tabs_empty_line():
	var code: String = "if true:\n\n    print('hello')"
	var result: String = _debug_tools._spaces_to_tabs(code)
	assert_eq(result, "if true:\n\n\tprint('hello')", "Empty lines preserved")

func test_spaces_to_tabs_already_tab():
	var code: String = "if true:\n\tprint('hello')"
	var result: String = _debug_tools._spaces_to_tabs(code)
	assert_eq(result, code, "Already tabbed code unchanged")

func test_spaces_to_tabs_non_multiple_of_4():
	var result: String = _debug_tools._spaces_to_tabs("   print('hello')")
	assert_eq(result, "   print('hello')", "3 spaces kept as spaces")

func test_spaces_to_tabs_multiline_block():
	var code: String = "for i in range(10):\n    if i > 5:\n        print(i)\n    else:\n        continue"
	var result: String = _debug_tools._spaces_to_tabs(code)
	var expected: String = "for i in range(10):\n\tif i > 5:\n\t\tprint(i)\n\telse:\n\t\tcontinue"
	assert_eq(result, expected, "Full block with if/else")

func test_script_tools_spaces_to_tabs():
	var result: String = _script_tools._spaces_to_tabs("    var x = 1")
	assert_eq(result, "\tvar x = 1", "script_tools _spaces_to_tabs works")
