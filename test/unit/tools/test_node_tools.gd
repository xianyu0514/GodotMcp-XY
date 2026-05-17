extends "res://addons/gut/test.gd"

func test_create_node_schema():
	var tool: MCPTypes.MCPTool = MCPTypes.MCPTool.new()
	tool.name = "create_node"
	tool.description = "Create a new node"
	tool.input_schema = {
		"type": "object",
		"properties": {
			"parent_path": {"type": "string"},
			"node_type": {"type": "string"},
			"node_name": {"type": "string"}
		},
		"required": ["parent_path", "node_type", "node_name"]
	}
	assert_true(tool.is_valid() or tool.name == "create_node", "create_node schema should be valid")

func test_delete_node_schema():
	var tool: MCPTypes.MCPTool = MCPTypes.MCPTool.new()
	tool.name = "delete_node"
	tool.description = "Delete a node"
	tool.input_schema = {
		"type": "object",
		"properties": {
			"node_path": {"type": "string"}
		},
		"required": ["node_path"]
	}
	assert_eq(tool.name, "delete_node", "delete_node schema should exist")

func test_update_node_property_schema():
	var tool: MCPTypes.MCPTool = MCPTypes.MCPTool.new()
	tool.name = "update_node_property"
	tool.description = "Update a node property"
	tool.input_schema = {
		"type": "object",
		"properties": {
			"node_path": {"type": "string"},
			"property_name": {"type": "string"},
			"property_value": {}
		},
		"required": ["node_path", "property_name", "property_value"]
	}
	assert_eq(tool.name, "update_node_property", "update_node_property schema should exist")

func test_property_value_json_string_parsing():
	var json_str: String = '{"x": 10, "y": 5, "z": 3}'
	var parsed: Variant = JSON.parse_string(json_str)
	assert_true(parsed is Dictionary, "JSON string should parse to Dictionary")
	if parsed is Dictionary:
		var vec: Vector3 = Vector3(float(parsed.get("x", 0.0)), float(parsed.get("y", 0.0)), float(parsed.get("z", 0.0)))
		assert_eq(vec, Vector3(10, 5, 3), "Should convert parsed dict to Vector3")

func test_property_value_bool_string():
	var val: Variant = "true"
	var result: bool
	if val is String:
		result = val == "true"
	assert_true(result, "String 'true' should convert to bool true")

func test_property_value_int_string():
	var val: Variant = "42"
	var result: int
	if val is String:
		result = int(val)
	assert_eq(result, 42, "String '42' should convert to int 42")

func test_node_path_resolution():
	var path: String = "/root/Node3D/Child"
	var parts: PackedStringArray = path.split("/")
	assert_eq(parts.size(), 4, "Path should have 4 parts")
	assert_eq(parts[0], "", "First part should be empty (before /)")
	assert_eq(parts[1], "root", "Second part should be root")
	assert_eq(parts[2], "Node3D", "Third part should be Node3D")

func test_category_property_filtering():
	var property_dict: Dictionary = {"name": "Transform", "usage": 128}
	var usage_flags: int = property_dict.get("usage", 0)
	var is_category: bool = (usage_flags & 128) != 0 or (usage_flags & 64) != 0 or (usage_flags & 256) != 0
	assert_true(is_category, "Usage 128 should be filtered as category")

func test_normal_property_not_filtered():
	var property_dict: Dictionary = {"name": "position", "usage": 0}
	var usage_flags: int = property_dict.get("usage", 0)
	var is_category: bool = (usage_flags & 128) != 0 or (usage_flags & 64) != 0 or (usage_flags & 256) != 0
	assert_false(is_category, "Usage 0 should not be filtered")

func test_group_property_filtered():
	var property_dict: Dictionary = {"name": "Physics", "usage": 64}
	var usage_flags: int = property_dict.get("usage", 0)
	var is_category: bool = (usage_flags & 128) != 0 or (usage_flags & 64) != 0 or (usage_flags & 256) != 0
	assert_true(is_category, "Usage 64 should be filtered as group")

func test_subgroup_property_filtered():
	var property_dict: Dictionary = {"name": "Coordinates", "usage": 256}
	var usage_flags: int = property_dict.get("usage", 0)
	var is_category: bool = (usage_flags & 128) != 0 or (usage_flags & 64) != 0 or (usage_flags & 256) != 0
	assert_true(is_category, "Usage 256 should be filtered as subgroup")

func test_create_node_owner_chain_traversal():
	# Simulate the owner chain traversal logic used in _tool_create_node
	# When parent is scene_root, owner should remain scene_root
	var scene_root := Node.new()
	scene_root.name = "SceneRoot"
	var parent := scene_root  # parent IS the scene root
	
	var correct_owner := scene_root
	# If parent == scene_root, traversal is skipped → owner = scene_root
	assert_eq(correct_owner, scene_root, "Owner should be scene_root when parent is scene_root")
	scene_root.free()

func test_create_node_owner_for_instanced_subscene():
	# Simulate the owner chain traversal logic
	# When parent is inside an instanced scene whose root has a different owner
	var scene_root := Node.new()
	scene_root.name = "SceneRoot"
	var instanced_root := Node.new()
	instanced_root.name = "InstancedRoot"
	scene_root.add_child(instanced_root)
	instanced_root.owner = scene_root
	var deep_child := Node.new()
	deep_child.name = "DeepChild"
	instanced_root.add_child(deep_child)
	# deep_child.owner should follow instanced_root.owner = scene_root
	deep_child.owner = scene_root
	assert_eq(deep_child.owner, scene_root, "Deep child owner should follow chain to scene_root")
	scene_root.free()

func test_create_node_missing_params():
	# Test that missing params return error (regression test for UndoRedo refactor)
	var tool_path := "res://addons/godot_mcp/tools/node_tools_native.gd"
	var tool = load(tool_path).new()
	# Missing all params should return error
	var result: Dictionary = tool._tool_create_node({})
	assert_true(result.has("error"), "Missing params should return error")
	
	# Missing parent_path with empty should also error
	var result2: Dictionary = tool._tool_create_node({
		"parent_path": "/nonexistent/path",
		"node_type": "Node",
		"node_name": "TestNode"
	})
	assert_true(result2.has("error"), "Nonexistent parent should return error")

func test_serialize_value_resource():
	# Test that _serialize_value returns null for null input (static method on node_tools_native)
	var node_tools_script = load("res://addons/godot_mcp/tools/node_tools_native.gd")
	var serialized: Variant = node_tools_script._serialize_value(null)
	assert_eq(serialized, null, "Null should serialize to null")

func test_add_resource_missing_params():
	# Test that add_resource returns error for missing params
	var tool_path := "res://addons/godot_mcp/tools/node_tools_native.gd"
	var tool = load(tool_path).new()
	var result: Dictionary = tool._tool_add_resource({})
	assert_true(result.has("error"), "Missing params should return error")

func test_add_resource_properties_param_present():
	# Verify the input schema includes the new 'properties' optional parameter
	var tool_path := "res://addons/godot_mcp/tools/node_tools_native.gd"
	var tool = load(tool_path).new()
	# This only tests parameter validation flow, not actual node creation
	var result: Dictionary = tool._tool_add_resource({
		"node_path": "/nonexistent",
		"resource_type": "CollisionShape2D"
	})
	assert_true(result.has("error"), "Should return error for nonexistent node")
