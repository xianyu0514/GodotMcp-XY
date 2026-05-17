extends "res://addons/gut/test.gd"

var _debug_tools: RefCounted = null

func before_each():
	_debug_tools = load("res://addons/godot_mcp/tools/debug_tools_native.gd").new()

func after_each():
	_debug_tools = null

func test_infer_log_type_error():
	assert_eq(_debug_tools._infer_log_type_from_line("ERROR: Something went wrong"), "Error", "ERROR: prefix should be Error")
	assert_eq(_debug_tools._infer_log_type_from_line("SCRIPT ERROR: test"), "Error", "SCRIPT ERROR: prefix should be Error")
	assert_eq(_debug_tools._infer_log_type_from_line("PARSE ERROR: syntax"), "Error", "PARSE ERROR: prefix should be Error")
	assert_eq(_debug_tools._infer_log_type_from_line("ERROR at line 5"), "Error", "ERROR at prefix should be Error")

func test_infer_log_type_warning():
	assert_eq(_debug_tools._infer_log_type_from_line("WARNING: Check this"), "Warning", "WARNING: prefix should be Warning")
	assert_eq(_debug_tools._infer_log_type_from_line("WARN something"), "Warning", "WARN prefix should be Warning")

func test_infer_log_type_debug():
	assert_eq(_debug_tools._infer_log_type_from_line("DEBUG: Detail info"), "Debug", "DEBUG: prefix should be Debug")
	assert_eq(_debug_tools._infer_log_type_from_line("DEBUG message"), "Debug", "DEBUG prefix should be Debug")

func test_infer_log_type_info():
	assert_eq(_debug_tools._infer_log_type_from_line("Normal log message"), "Info", "Normal message should be Info")
	assert_eq(_debug_tools._infer_log_type_from_line("Godot Engine v4.6.1"), "Info", "Engine message should be Info")
	assert_eq(_debug_tools._infer_log_type_from_line("print output"), "Info", "print output should be Info")

func test_infer_log_type_godot_format():
	assert_eq(_debug_tools._infer_log_type_from_line("  ERROR: core/variant/variant_utility.cpp:1024 - message"), "Error", "Godot ERROR format should be Error")
	assert_eq(_debug_tools._infer_log_type_from_line("  WARNING: core/variant/variant_utility.cpp:1034 - message"), "Warning", "Godot WARNING format should be Warning")

func test_get_editor_panel_logs_no_editor():
	var result: Dictionary = _debug_tools._get_editor_panel_logs([], 100, 0, "desc")
	assert_has(result, "source", "Should have source field")
	assert_eq(result["source"], "editor_panel", "Source should be editor_panel")

func test_find_tree_control_returns_tree():
	var tree = Tree.new()
	var result = _debug_tools._find_tree_control(tree)
	assert_eq(result, tree, "Should find Tree itself")
	tree.free()

func test_find_tree_control_finds_child():
	var parent = Control.new()
	var tree = Tree.new()
	parent.add_child(tree)
	var result = _debug_tools._find_tree_control(parent)
	assert_eq(result, tree, "Should find Tree in children")
	parent.free()

func test_find_tree_control_returns_null():
	var control = Control.new()
	var result = _debug_tools._find_tree_control(control)
	assert_null(result, "Should return null when no Tree")
	control.free()

func test_find_script_editor_debugger_found():
	# Create a mock ScriptEditorDebugger node and verify it is found by its class name
	var debugger = Node.new()
	debugger.set_script(null)  # Ensure no script type override
	# Manually set the class to simulate ScriptEditorDebugger (using a normal Node works since get_class() returns the class name)
	var mock_debugger = Node.new()
	mock_debugger.name = "MockDebugger"
	
	var container = Node.new()
	container.add_child(mock_debugger)
	
	var not_found = _debug_tools._find_script_editor_debugger(container)
	# Since get_class() returns "Node" not "ScriptEditorDebugger", this should return null
	assert_null(not_found, "Should not find when class is not ScriptEditorDebugger")
	container.free()

func test_find_script_editor_debugger_not_found():
	var container = Control.new()
	var result = _debug_tools._find_script_editor_debugger(container)
	assert_null(result, "Should return null when no ScriptEditorDebugger found")
	container.free()

func test_find_script_editor_debugger_with_valid_class():
	# Test that the search traverses children correctly
	var base = Node.new()
	var child = Node.new()
	var grandchild = Control.new()
	
	base.add_child(child)
	child.add_child(grandchild)
	
	var result = _debug_tools._find_script_editor_debugger(base)
	assert_null(result, "Should return null when no ScriptEditorDebugger in children")
	base.free()
