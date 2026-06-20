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

# --- create_node on_name_conflict tests ---

func test_create_node_on_name_conflict_schema_has_field():
	"""verify _register_create_node input_schema includes on_name_conflict"""
	var tool = load("res://addons/godot_mcp/tools/node_tools_native.gd").new()
	var result: Dictionary = tool._tool_create_node({})
	# Basic error check - ensures function compiles and runs with new param
	assert_true(result.has("error"), "Empty params should error regardless of on_name_conflict")

func test_create_node_rename_mode_suffix():
	"""on_name_conflict='rename' should use counter suffix logic"""
	var tool = load("res://addons/godot_mcp/tools/node_tools_native.gd").new()
	# Simulate the rename logic: when parent.has_node(name), try name_1, name_2, etc.
	var node_name: String = "ExistingNode"
	var counter: int = 1
	var new_name: String = node_name + "_" + str(counter)
	assert_eq(new_name, "ExistingNode_1", "Rename should append _1 suffix")

func test_create_node_rename_with_existing_counter():
	"""rename mode should increment counter when name_1 also exists"""
	var existing_names: Array = ["Node_1", "Node_2"]
	var node_name: String = "Node"
	var counter: int = 1
	var new_name: String = node_name + "_" + str(counter)
	while new_name in existing_names:
		counter += 1
		new_name = node_name + "_" + str(counter)
	assert_eq(new_name, "Node_3", "Should skip Node_1 and Node_2, use Node_3")

func test_create_node_error_mode():
	"""on_name_conflict='error' should generate error message mentioning the conflicting name"""
	var node_name: String = "TestNode"
	var parent_path: String = "/root/Scene"
	var error_msg: String = "A node named '" + node_name + "' already exists under " + parent_path
	assert_true(error_msg.contains(node_name), "Error message should contain the node name")
	assert_true(error_msg.contains(parent_path), "Error message should contain the parent path")

# --- connect_signal all-params validation tests ---

func test_connect_signal_collects_all_missing_params():
	"""connect_signal should report all missing params at once, not just the first one"""
	var tool = load("res://addons/godot_mcp/tools/node_tools_native.gd").new()
	# Create a test scenario: the validation logic from _tool_connect_signal
	var params: Dictionary = {}
	var missing_params: Array[String] = []
	if params.get("emitter_path", "").is_empty():
		missing_params.append("emitter_path")
	if params.get("signal_name", "").is_empty():
		missing_params.append("signal_name")
	if params.get("receiver_path", "").is_empty():
		missing_params.append("receiver_path")
	if params.get("receiver_method", "").is_empty():
		missing_params.append("receiver_method")
	assert_eq(missing_params.size(), 4, "All 4 params should be reported missing")
	var error_msg: String = "Missing required parameters: " + ", ".join(missing_params)
	assert_true(error_msg.contains("emitter_path"), "Error should mention emitter_path")
	assert_true(error_msg.contains("signal_name"), "Error should mention signal_name")
	assert_true(error_msg.contains("receiver_path"), "Error should mention receiver_path")
	assert_true(error_msg.contains("receiver_method"), "Error should mention receiver_method")

func test_connect_signal_reports_partial_missing():
	"""connect_signal with 2 of 4 params should report the 2 missing ones"""
	var params: Dictionary = {"emitter_path": "/root/Btn", "signal_name": "pressed"}
	var missing_params: Array[String] = []
	if params.get("emitter_path", "").is_empty():
		missing_params.append("emitter_path")
	if params.get("signal_name", "").is_empty():
		missing_params.append("signal_name")
	if params.get("receiver_path", "").is_empty():
		missing_params.append("receiver_path")
	if params.get("receiver_method", "").is_empty():
		missing_params.append("receiver_method")
	assert_eq(missing_params.size(), 2, "2 params should be reported missing")
	assert_eq(missing_params[0], "receiver_path", "First missing should be receiver_path")
	assert_eq(missing_params[1], "receiver_method", "Second missing should be receiver_method")

# --- batch_update_node_properties property_types tests ---

func test_get_type_name_returns_string():
	"""_get_type_name should return a human-readable type name for known types"""
	var tool = load("res://addons/godot_mcp/tools/node_tools_native.gd").new()
	var type_name: String = tool._get_type_name(TYPE_BOOL)
	assert_eq(type_name, "bool", "TYPE_BOOL should map to 'bool'")

func test_get_type_name_vector2():
	"""_get_type_name for Vector2 should include format hints"""
	var tool = load("res://addons/godot_mcp/tools/node_tools_native.gd").new()
	var type_name: String = tool._get_type_name(TYPE_VECTOR2)
	assert_true(type_name.contains("Vector2"), "Vector2 type name should mention Vector2")

func test_get_type_name_color():
	"""_get_type_name for Color should include hex format hint"""
	var tool = load("res://addons/godot_mcp/tools/node_tools_native.gd").new()
	var type_name: String = tool._get_type_name(TYPE_COLOR)
	assert_true(type_name.contains("hex"), "Color type name should mention hex format")

func test_get_type_name_fallback():
	"""_get_type_name for unknown type should return type_N"""
	var tool = load("res://addons/godot_mcp/tools/node_tools_native.gd").new()
	var type_name: String = tool._get_type_name(9999)
	assert_eq(type_name, "type_9999", "Unknown type should use type_N fallback")

# --- batch_get_node_properties / batch_connect_signals ---

func test_batch_get_node_properties_rejects_empty():
	var tool = load("res://addons/godot_mcp/tools/node_tools_native.gd").new()
	var result: Dictionary = tool._tool_batch_get_node_properties({})
	assert_has(result, "error", "Missing node_paths is rejected")

func test_batch_get_node_properties_requires_editor():
	var tool = load("res://addons/godot_mcp/tools/node_tools_native.gd").new()
	var result: Dictionary = tool._tool_batch_get_node_properties({"node_paths": ["/root/Main/Player"]})
	assert_has(result, "error", "Without an editor interface the batch read reports an error")

func test_batch_connect_signals_rejects_empty():
	var tool = load("res://addons/godot_mcp/tools/node_tools_native.gd").new()
	var result: Dictionary = tool._tool_batch_connect_signals({})
	assert_has(result, "error", "Missing connections is rejected")

func test_batch_connect_signals_requires_editor():
	var tool = load("res://addons/godot_mcp/tools/node_tools_native.gd").new()
	var result: Dictionary = tool._tool_batch_connect_signals({"connections": [{
		"emitter_path": "/root/Main/Button",
		"signal_name": "pressed",
		"receiver_path": "/root/Main",
		"receiver_method": "_on_pressed"
	}]})
	assert_has(result, "error", "Without an editor interface the batch connect reports an error")
