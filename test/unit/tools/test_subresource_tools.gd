extends "res://addons/gut/test.gd"

# Unit tests for the Batch 7 sub-resource tools (node_tools_native.gd):
# set_node_subresource / get_node_subresource and their conversion helpers.
# Editor-dependent success paths (resolving a node in the edited scene and
# assigning the sub-resource via UndoRedo) are exercised live over HTTP;
# here we cover validation, error branches and the value coercion/serialization
# helpers that are headless-safe.

const NODE_TOOL_SCRIPT: String = "res://addons/godot_mcp/tools/node_tools_native.gd"

var _node_tools: RefCounted = null

func before_each():
	_node_tools = load(NODE_TOOL_SCRIPT).new()

func after_each():
	_node_tools = null
	if Engine.has_meta("GodotMCPPlugin"):
		Engine.remove_meta("GodotMCPPlugin")

# --- set_node_subresource validation ---------------------------------------

func test_set_subresource_missing_node_path():
	var result: Dictionary = _node_tools._tool_set_node_subresource({})
	assert_has(result, "error", "Missing node_path should return an error")

func test_set_subresource_missing_property_name():
	var result: Dictionary = _node_tools._tool_set_node_subresource({"node_path": "/root/Main"})
	assert_has(result, "error", "Missing property_name should return an error")

func test_set_subresource_missing_resource_type():
	var result: Dictionary = _node_tools._tool_set_node_subresource({
		"node_path": "/root/Main", "property_name": "shape"
	})
	assert_has(result, "error", "Missing resource_type should return an error")

func test_set_subresource_unknown_resource_type():
	var result: Dictionary = _node_tools._tool_set_node_subresource({
		"node_path": "/root/Main", "property_name": "shape", "resource_type": "NotARealClass"
	})
	assert_has(result, "error", "Unknown resource_type should return an error")

func test_set_subresource_rejects_non_resource_type():
	var result: Dictionary = _node_tools._tool_set_node_subresource({
		"node_path": "/root/Main", "property_name": "shape", "resource_type": "Node2D"
	})
	assert_has(result, "error", "Non-Resource type should return an error")
	assert_true(str(result["error"]).contains("Resource subclass"), "Error should mention Resource subclass")

func test_set_subresource_rejects_bad_properties_type():
	var result: Dictionary = _node_tools._tool_set_node_subresource({
		"node_path": "/root/Main", "property_name": "shape",
		"resource_type": "RectangleShape2D", "properties": "not_an_object"
	})
	assert_has(result, "error", "Non-object properties should return an error")

func test_set_subresource_valid_input_needs_editor():
	# Valid resource type but no editor interface registered -> must get past
	# validation and fail only at the editor-interface stage.
	var result: Dictionary = _node_tools._tool_set_node_subresource({
		"node_path": "/root/Main", "property_name": "shape",
		"resource_type": "RectangleShape2D", "properties": {"size": [64, 32]}
	})
	assert_has(result, "error", "Without editor interface it should error")
	assert_eq(result["error"], "Editor interface not available", "Should fail at editor stage, not validation")

# --- get_node_subresource validation ---------------------------------------

func test_get_subresource_missing_node_path():
	var result: Dictionary = _node_tools._tool_get_node_subresource({})
	assert_has(result, "error", "Missing node_path should return an error")

func test_get_subresource_missing_property_name():
	var result: Dictionary = _node_tools._tool_get_node_subresource({"node_path": "/root/Main"})
	assert_has(result, "error", "Missing property_name should return an error")

func test_get_subresource_rejects_bad_property_names_type():
	var result: Dictionary = _node_tools._tool_get_node_subresource({
		"node_path": "/root/Main", "property_name": "shape", "property_names": "nope"
	})
	assert_has(result, "error", "Non-array property_names should return an error")

# --- _coerce_object_property (real resources) -------------------------------

func test_coerce_rectangle_size_from_array():
	var rect: RectangleShape2D = RectangleShape2D.new()
	var coerced: Variant = _node_tools._coerce_object_property(rect, "size", [64, 32])
	assert_eq(coerced, Vector2(64, 32), "Array [w,h] should coerce to Vector2 size")

func test_coerce_rectangle_size_from_dict():
	var rect: RectangleShape2D = RectangleShape2D.new()
	var coerced: Variant = _node_tools._coerce_object_property(rect, "size", {"x": 10, "y": 20})
	assert_eq(coerced, Vector2(10, 20), "Dict {x,y} should coerce to Vector2 size")

func test_coerce_circle_radius_from_string():
	var circle: CircleShape2D = CircleShape2D.new()
	var coerced: Variant = _node_tools._coerce_object_property(circle, "radius", "16")
	assert_eq(coerced, 16.0, "String should coerce to float radius")

func test_coerce_circle_radius_from_int():
	var circle: CircleShape2D = CircleShape2D.new()
	var coerced: Variant = _node_tools._coerce_object_property(circle, "radius", 24)
	assert_eq(coerced, 24.0, "Int should coerce to float radius")

# --- _to_vector2 / _to_vector3 helpers --------------------------------------

func test_to_vector2_variants():
	assert_eq(_node_tools._subres_to_vector2([3, 4]), Vector2(3, 4), "Array -> Vector2")
	assert_eq(_node_tools._subres_to_vector2({"x": 5, "y": 6}), Vector2(5, 6), "Dict -> Vector2")
	assert_eq(_node_tools._subres_to_vector2(Vector2(7, 8)), Vector2(7, 8), "Vector2 passthrough")
	assert_eq(_node_tools._subres_to_vector2(Vector2i(9, 10)), Vector2(9, 10), "Vector2i -> Vector2")
	assert_eq(_node_tools._subres_to_vector2(42), null, "Invalid input -> null")

func test_to_vector3_variants():
	assert_eq(_node_tools._subres_to_vector3([1, 2, 3]), Vector3(1, 2, 3), "Array -> Vector3")
	assert_eq(_node_tools._subres_to_vector3({"x": 1, "y": 2, "z": 3}), Vector3(1, 2, 3), "Dict -> Vector3")
	assert_eq(_node_tools._subres_to_vector3("bad"), null, "Invalid input -> null")

# --- _serialize_resource_value ----------------------------------------------

func test_serialize_resource_value():
	assert_eq(_node_tools._serialize_resource_value(7), 7, "Int passthrough")
	assert_eq(_node_tools._serialize_resource_value(Vector2(1, 2)), [1.0, 2.0], "Vector2 -> [x,y]")
	assert_eq(_node_tools._serialize_resource_value(Vector3(1, 2, 3)), [1.0, 2.0, 3.0], "Vector3 -> [x,y,z]")
	assert_eq(_node_tools._serialize_resource_value(Color(1, 0, 0, 1)), "#" + Color(1, 0, 0, 1).to_html(), "Color -> #hex")

func test_serialize_resource_value_nested_resource():
	var rect: RectangleShape2D = RectangleShape2D.new()
	var serialized: Variant = _node_tools._serialize_resource_value(rect)
	assert_eq(serialized, "<RectangleShape2D>", "In-memory resource -> <ClassName>")
