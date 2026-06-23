extends "res://addons/gut/test.gd"

var _project_tools: RefCounted = null

func before_each():
	_project_tools = load("res://addons/godot_mcp/tools/project_tools_native.gd").new()

func after_each():
	_project_tools = null

func test_convert_value_for_resource_vector3():
	var res: BoxShape3D = BoxShape3D.new()
	var result: Variant = _project_tools._convert_value_for_resource(res, "size", {"x": 2.5, "y": 2.0, "z": 6.0})
	assert_eq(result, Vector3(2.5, 2.0, 6.0), "Dict to Vector3 for resource")
	res.free()

func test_convert_value_for_resource_vector3_from_string():
	var res: BoxShape3D = BoxShape3D.new()
	var result: Variant = _project_tools._convert_value_for_resource(res, "size", "Vector3(2.5, 2.0, 6.0)")
	assert_eq(result, Vector3(2.5, 2.0, 6.0), "String to Vector3 for resource")
	res.free()

func test_convert_value_for_resource_color_from_dict():
	var res: StandardMaterial3D = StandardMaterial3D.new()
	var result: Variant = _project_tools._convert_value_for_resource(res, "albedo_color", {"r": 1.0, "g": 0.0, "b": 0.0, "a": 1.0})
	assert_eq(result, Color(1, 0, 0, 1), "Dict to Color for resource")
	res.free()

func test_convert_value_for_resource_float():
	var res: StandardMaterial3D = StandardMaterial3D.new()
	var result: Variant = _project_tools._convert_value_for_resource(res, "roughness", "0.5")
	assert_eq(result, 0.5, "String to float for resource")
	res.free()

func test_convert_value_for_resource_bool():
	var res: StandardMaterial3D = StandardMaterial3D.new()
	var result: Variant = _project_tools._convert_value_for_resource(res, "vertex_color_use_as_albedo", "true")
	assert_eq(result, true, "String to bool for resource")
	res.free()

func test_convert_value_for_resource_null():
	var res: BoxShape3D = BoxShape3D.new()
	var result: Variant = _project_tools._convert_value_for_resource(res, "size", null)
	assert_eq(result, null, "Null returns null")
	res.free()

func test_convert_value_for_resource_invalid_prop():
	var res: BoxShape3D = BoxShape3D.new()
	var result: Variant = _project_tools._convert_value_for_resource(res, "nonexistent_prop", 42)
	assert_eq(result, 42, "Invalid property returns original value")
	res.free()

func test_parse_key_value_string_vector3():
	var result: Dictionary = _project_tools._parse_key_value_string("{x:2.5,y:2,z:6}")
	assert_eq(result.get("x"), "2.5", "x parsed")
	assert_eq(result.get("y"), "2", "y parsed")
	assert_eq(result.get("z"), "6", "z parsed")

func test_parse_key_value_string_vector2():
	var result: Dictionary = _project_tools._parse_key_value_string("{x:3,y:4}")
	assert_eq(result.get("x"), "3", "x parsed")
	assert_eq(result.get("y"), "4", "y parsed")

func test_parse_key_value_string_not_braces():
	var result: Dictionary = _project_tools._parse_key_value_string("1,2,3")
	assert_eq(result.is_empty(), true, "Non-brace string returns empty dict")

func test_parse_key_value_string_empty():
	var result: Dictionary = _project_tools._parse_key_value_string("{}")
	assert_eq(result.is_empty(), true, "Empty braces returns empty dict")

func test_convert_value_for_resource_vector3_key_value_string():
	var res: BoxShape3D = BoxShape3D.new()
	var result: Variant = _project_tools._convert_value_for_resource(res, "size", "{x:2.5,y:2,z:6}")
	assert_eq(result, Vector3(2.5, 2.0, 6.0), "{x:y:z:} string to Vector3 for resource")
	res.free()

func test_convert_value_for_resource_vector2_key_value_string():
	var res: PlaceholderTexture2D = PlaceholderTexture2D.new()
	var result: Variant = _project_tools._convert_value_for_resource(res, "size", "{x:1,y:2}")
	assert_eq(result, Vector2(1.0, 2.0), "{x:y:} string to Vector2 for resource")
	res.free()

func test_parse_key_value_string_with_spaces():
	var result: Dictionary = _project_tools._parse_key_value_string("{x: 1, y: 2, z: 3}")
	assert_eq(result.get("x"), "1", "x parsed with spaces")
	assert_eq(result.get("y"), "2", "y parsed with spaces")
	assert_eq(result.get("z"), "3", "z parsed with spaces")

func test_parse_key_value_string_single_value():
	var result: Dictionary = _project_tools._parse_key_value_string("{x:42}")
	assert_eq(result.get("x"), "42", "single value parsed")

func test_parse_key_value_string_negative():
	var result: Dictionary = _project_tools._parse_key_value_string("{x:-1,y:-2}")
	assert_eq(result.get("x"), "-1", "negative x parsed")
	assert_eq(result.get("y"), "-2", "negative y parsed")

func test_convert_value_for_resource_vector3_csv_string():
	var res: BoxShape3D = BoxShape3D.new()
	var result: Variant = _project_tools._convert_value_for_resource(res, "size", "2.5,2,6")
	assert_eq(result, Vector3(2.5, 2.0, 6.0), "CSV string to Vector3 for resource")
	res.free()

func test_convert_value_for_resource_vector3_dict():
	var res: BoxShape3D = BoxShape3D.new()
	var result: Variant = _project_tools._convert_value_for_resource(res, "size", {"x": 3.0, "y": 4.0, "z": 5.0})
	assert_eq(result, Vector3(3.0, 4.0, 5.0), "Dict to Vector3 for resource")
	res.free()

func test_convert_value_for_resource_int_from_string():
	var res: StandardMaterial3D = StandardMaterial3D.new()
	var result: Variant = _project_tools._convert_value_for_resource(res, "transparency", "1")
	assert_eq(result, 1, "String to int for resource")
	res.free()
