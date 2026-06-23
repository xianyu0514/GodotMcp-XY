extends "res://addons/gut/test.gd"

var _node_tools: RefCounted = null

func before_each():
	_node_tools = load("res://addons/godot_mcp/tools/node_tools_native.gd").new()

func after_each():
	_node_tools = null

func test_convert_node_path_from_string():
	var node: Node = Node.new()
	add_child_autofree(node)
	var result: Variant = _node_tools._convert_value_for_property(node, "name", "TestName")
	assert_eq(result, "TestName", "name property returns string")

func test_convert_resource_type_from_res_path():
	var node: MeshInstance3D = MeshInstance3D.new()
	add_child_autofree(node)
	var result: Variant = _node_tools._convert_value_for_property(node, "material_override", "res://nonexistent.tres")
	assert_eq(result, null, "Invalid resource path returns null from load")

func test_convert_resource_type_from_class_name():
	var node: MeshInstance3D = MeshInstance3D.new()
	add_child_autofree(node)
	var result: Variant = _node_tools._convert_value_for_property(node, "material_override", "StandardMaterial3D")
	assert_true(result is Material, "Class name string creates Material instance")
	if result is RefCounted:
		pass
	elif result:
		result.free()

func test_convert_node_path_type():
	var node: PathFollow3D = PathFollow3D.new()
	add_child_autofree(node)
	var result: Variant = _node_tools._convert_value_for_property(node, "progress_ratio", 0.5)
	assert_eq(result, 0.5, "Float property works correctly")
