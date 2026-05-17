extends "res://addons/gut/test.gd"

var _script_tools: RefCounted = null

func before_each():
	_script_tools = load("res://addons/godot_mcp/tools/script_tools_native.gd").new()

func after_each():
	_script_tools = null

func test_validate_valid_script():
	var result = _script_tools._tool_validate_script({"content": "extends Node\n\nfunc _ready():\n\tpass"})
	assert_true(result.get("valid", false), "Should be valid")

func test_validate_syntax_error():
	var result = _script_tools._tool_validate_script({"content": "extends Node\n\nfunc _ready()\n\tpass"})
	assert_false(result.get("valid", true), "Should be invalid")

func test_validate_autoload_aware_field_present():
	var result = _script_tools._tool_validate_script({"content": "extends Node\n\nfunc _ready():\n\tpass"})
	assert_has(result, "autoload_aware", "Should have autoload_aware field")

func test_validate_real_syntax_error_not_rescued():
	var result = _script_tools._tool_validate_script({"content": "func _ready(\n\tpass"})
	assert_false(result.get("valid", true), "Real syntax error should not be rescued")
	assert_false(result.get("autoload_aware", true), "Real syntax error should not set autoload_aware")

func test_build_autoload_declarations_returns_string():
	var decls = _script_tools._build_autoload_declarations()
	assert_true(decls is String, "Should return string")

func test_build_autoload_declarations_includes_project_autoloads():
	var decls = _script_tools._build_autoload_declarations()
	if ProjectSettings.has_setting("autoload/MCPDebuggerBridge"):
		assert_true(decls.find("MCPDebuggerBridge") >= 0, "Should include MCPDebuggerBridge autoload")

func test_validate_missing_params():
	var result = _script_tools._tool_validate_script({})
	assert_has(result, "error", "Should return error for missing params")

func test_validate_content_only():
	var result = _script_tools._tool_validate_script({"content": "extends RefCounted"})
	assert_true(result.get("valid", false), "Content-only validation should work")

func test_strip_class_names():
	var stripped = _script_tools._strip_class_names("class_name MyClass\nextends Node")
	assert_false(stripped.contains("class_name"), "Should strip class_name")
	assert_true(stripped.contains("extends Node"), "Should keep extends")
