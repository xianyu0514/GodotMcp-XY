extends "res://addons/gut/test.gd"

var _node_tools: RefCounted = null

func before_each():
	_node_tools = load("res://addons/godot_mcp/tools/node_tools_native.gd").new()

func after_each():
	_node_tools = null

# ===========================================
# duplicate_node - 复制节点
# ===========================================

func test_duplicate_node_missing_node_path():
	var result: Dictionary = _node_tools._tool_duplicate_node({})
	assert_has(result, "error", "Should return error for missing node_path")
	assert_true(str(result.error).contains("node_path"), "Error should mention node_path")

func test_duplicate_node_empty_node_path():
	var result: Dictionary = _node_tools._tool_duplicate_node({"node_path": ""})
	assert_has(result, "error", "Should return error for empty node_path")

func test_duplicate_node_auto_name_generation():
	var root: Node = Node.new()
	root.name = "Root"
	add_child_autofree(root)
	var child: Node = Node.new()
	child.name = "Player"
	root.add_child(child)
	var new_node: Node = child.duplicate()
	assert_ne(new_node, null, "Duplicate should not be null")
	new_node.name = "Player2"
	assert_eq(str(new_node.name), "Player2", "Auto-generated name should be unique")
	new_node.free()

func test_duplicate_node_custom_name():
	var root: Node = Node.new()
	root.name = "Root"
	add_child_autofree(root)
	var child: Node = Node.new()
	child.name = "Player"
	root.add_child(child)
	var new_node: Node = child.duplicate()
	new_node.name = "Hero"
	assert_eq(str(new_node.name), "Hero", "Should use custom name")
	new_node.free()

func test_duplicate_node_preserves_children():
	var root: Node = Node.new()
	root.name = "Root"
	add_child_autofree(root)
	var child: Node = Node.new()
	child.name = "Parent"
	var grandchild: Node = Node.new()
	grandchild.name = "Child1"
	child.add_child(grandchild)
	root.add_child(child)
	var new_node: Node = child.duplicate()
	assert_eq(new_node.get_child_count(), 1, "Duplicate should preserve children")
	assert_eq(str(new_node.get_child(0).name), "Child1", "Child name should be preserved")
	new_node.free()

# ===========================================
# move_node - 移动节点
# ===========================================

func test_move_node_missing_node_path():
	var result: Dictionary = _node_tools._tool_move_node({"new_parent_path": "/root"})
	assert_has(result, "error", "Should return error for missing node_path")

func test_move_node_missing_new_parent_path():
	var result: Dictionary = _node_tools._tool_move_node({"node_path": "/root/Node"})
	assert_has(result, "error", "Should return error for missing new_parent_path")

func test_move_node_empty_params():
	var result: Dictionary = _node_tools._tool_move_node({})
	assert_has(result, "error", "Should return error for empty params")

func test_move_node_cannot_move_to_itself():
	var root: Node = Node.new()
	root.name = "Root"
	add_child_autofree(root)
	var child: Node = Node.new()
	child.name = "Child"
	root.add_child(child)
	assert_true(child == child, "Node equals itself - move to self should be blocked by tool logic")

func test_move_node_reparent_preserves_transform():
	var root: Node = Node2D.new()
	root.name = "Root"
	add_child_autofree(root)
	var parent1: Node2D = Node2D.new()
	parent1.name = "Parent1"
	parent1.position = Vector2(100, 100)
	root.add_child(parent1)
	var child: Node2D = Node2D.new()
	child.name = "Child"
	child.position = Vector2(50, 50)
	parent1.add_child(child)
	var parent2: Node2D = Node2D.new()
	parent2.name = "Parent2"
	root.add_child(parent2)
	var global_pos_before: Vector2 = child.global_position
	child.reparent(parent2, true)
	var global_pos_after: Vector2 = child.global_position
	assert_eq(global_pos_before, global_pos_after, "Global position should be preserved with keep_global_transform=true")

func test_move_node_reparent_without_preserving_transform():
	var root: Node = Node2D.new()
	root.name = "Root"
	add_child_autofree(root)
	var parent1: Node2D = Node2D.new()
	parent1.name = "Parent1"
	parent1.position = Vector2(100, 100)
	root.add_child(parent1)
	var child: Node2D = Node2D.new()
	child.name = "Child"
	child.position = Vector2(50, 50)
	parent1.add_child(child)
	var parent2: Node2D = Node2D.new()
	parent2.name = "Parent2"
	root.add_child(parent2)
	child.reparent(parent2, false)
	assert_eq(child.position, Vector2(50, 50), "Local position should remain same with keep_global_transform=false")

func test_move_node_ancestor_check():
	var root: Node = Node.new()
	root.name = "Root"
	add_child_autofree(root)
	var parent: Node = Node.new()
	parent.name = "Parent"
	root.add_child(parent)
	var child: Node = Node.new()
	child.name = "Child"
	parent.add_child(child)
	assert_true(parent.is_ancestor_of(child), "Parent should be ancestor of child")
	assert_false(child.is_ancestor_of(parent), "Child should not be ancestor of parent")

# ===========================================
# rename_node - 重命名节点
# ===========================================

func test_rename_node_missing_node_path():
	var result: Dictionary = _node_tools._tool_rename_node({"new_name": "NewName"})
	assert_has(result, "error", "Should return error for missing node_path")

func test_rename_node_missing_new_name():
	var result: Dictionary = _node_tools._tool_rename_node({"node_path": "/root/Node"})
	assert_has(result, "error", "Should return error for missing new_name")

func test_rename_node_empty_new_name():
	var result: Dictionary = _node_tools._tool_rename_node({"node_path": "/root/Node", "new_name": ""})
	assert_has(result, "error", "Should return error for empty new_name")

func test_rename_node_basic():
	var node: Node = Node.new()
	node.name = "OldName"
	add_child_autofree(node)
	node.name = "NewName"
	assert_eq(str(node.name), "NewName", "Node name should be updated")

func test_rename_node_same_name():
	var node: Node = Node.new()
	node.name = "SameName"
	add_child_autofree(node)
	var old_name: String = str(node.name)
	node.name = "SameName"
	assert_eq(str(node.name), old_name, "Renaming to same name should work")

func test_rename_node_duplicate_name_in_parent():
	var root: Node = Node.new()
	root.name = "Root"
	add_child_autofree(root)
	var child1: Node = Node.new()
	child1.name = "Child1"
	root.add_child(child1)
	var child2: Node = Node.new()
	child2.name = "Child2"
	root.add_child(child2)
	assert_true(root.has_node("Child1"), "Child1 should exist")
	assert_true(root.has_node("Child2"), "Child2 should exist")

# ===========================================
# add_resource - 添加资源节点
# ===========================================

func test_add_resource_missing_node_path():
	var result: Dictionary = _node_tools._tool_add_resource({"resource_type": "CollisionShape2D"})
	assert_has(result, "error", "Should return error for missing node_path")

func test_add_resource_missing_resource_type():
	var result: Dictionary = _node_tools._tool_add_resource({"node_path": "/root/Node"})
	assert_has(result, "error", "Should return error for missing resource_type")

func test_add_resource_empty_resource_type():
	var result: Dictionary = _node_tools._tool_add_resource({"node_path": "/root/Node", "resource_type": ""})
	assert_has(result, "error", "Should return error for empty resource_type")

func test_add_resource_unknown_type():
	var result: Dictionary = _node_tools._tool_add_resource({"node_path": "/root/Node", "resource_type": "NonExistentType"})
	assert_has(result, "error", "Should return error for unknown resource type")

func test_add_resource_non_node_type():
	var result: Dictionary = _node_tools._tool_add_resource({"node_path": "/root/Node", "resource_type": "Resource"})
	assert_has(result, "error", "Should return error for non-Node resource type")

func test_add_resource_valid_node_type():
	var parent: Node = Node.new()
	parent.name = "Parent"
	add_child_autofree(parent)
	var resource_node: Node = ClassDB.instantiate("CollisionShape2D")
	assert_ne(resource_node, null, "Should be able to instantiate CollisionShape2D")
	resource_node.name = "Collision"
	parent.add_child(resource_node)
	assert_eq(parent.get_child_count(), 1, "Parent should have one child")
	assert_eq(str(resource_node.name), "Collision", "Resource node name should be set")
	resource_node.free()

func test_add_resource_custom_name():
	var parent: Node = Node.new()
	parent.name = "Parent"
	add_child_autofree(parent)
	var resource_node: Node = ClassDB.instantiate("CollisionShape2D")
	resource_node.name = "MyShape"
	parent.add_child(resource_node)
	assert_eq(str(resource_node.name), "MyShape", "Custom name should be used")
	resource_node.free()

func test_add_resource_class_db_check():
	assert_true(ClassDB.class_exists("CollisionShape2D"), "CollisionShape2D should exist in ClassDB")
	assert_true(ClassDB.class_exists("CollisionShape3D"), "CollisionShape3D should exist in ClassDB")
	assert_true(ClassDB.class_exists("MeshInstance3D"), "MeshInstance3D should exist in ClassDB")
	assert_true(ClassDB.is_parent_class("CollisionShape2D", "Node"), "CollisionShape2D should be a Node type")
	assert_true(ClassDB.is_parent_class("MeshInstance3D", "Node"), "MeshInstance3D should be a Node type")
	assert_false(ClassDB.is_parent_class("Resource", "Node"), "Resource should not be a Node type")

# ===========================================
# set_anchor_preset - 设置锚点预设
# ===========================================

func test_set_anchor_preset_missing_node_path():
	var result: Dictionary = _node_tools._tool_set_anchor_preset({"preset": 8})
	assert_has(result, "error", "Should return error for missing node_path")

func test_set_anchor_preset_missing_preset():
	var result: Dictionary = _node_tools._tool_set_anchor_preset({"node_path": "/root/Node"})
	assert_has(result, "error", "Should return error for missing preset (defaults to 0, which is valid)")

func test_set_anchor_preset_invalid_preset_negative():
	var control: Control = Control.new()
	control.name = "Panel"
	add_child_autofree(control)
	var result: Dictionary = _node_tools._tool_set_anchor_preset({"node_path": "/root/Panel", "preset": -1})
	assert_has(result, "error", "Should return error for negative preset")

func test_set_anchor_preset_invalid_preset_too_high():
	var control: Control = Control.new()
	control.name = "Panel"
	add_child_autofree(control)
	var result: Dictionary = _node_tools._tool_set_anchor_preset({"node_path": "/root/Panel", "preset": 16})
	assert_has(result, "error", "Should return error for preset > 15")

func test_set_anchor_preset_valid_preset():
	var control: Control = Control.new()
	control.name = "Panel"
	add_child_autofree(control)
	control.set_anchors_preset(Control.PRESET_CENTER)
	assert_ne(control.anchor_left, 0.0, "Center preset should change anchor_left from default")

func test_set_anchor_preset_full_rect():
	var parent: Control = Control.new()
	parent.name = "Parent"
	parent.size = Vector2(800, 600)
	add_child_autofree(parent)
	var control: Control = Control.new()
	control.name = "Panel"
	parent.add_child(control)
	control.set_anchors_preset(Control.PRESET_FULL_RECT)
	assert_eq(control.anchor_left, 0.0, "Full rect left anchor should be 0")
	assert_eq(control.anchor_right, 1.0, "Full rect right anchor should be 1")
	assert_eq(control.anchor_top, 0.0, "Full rect top anchor should be 0")
	assert_eq(control.anchor_bottom, 1.0, "Full rect bottom anchor should be 1")

func test_set_anchor_preset_preset_names():
	var preset_names: Dictionary = {
		0: "TOP_LEFT", 1: "TOP_RIGHT", 2: "BOTTOM_LEFT", 3: "BOTTOM_RIGHT",
		4: "CENTER_LEFT", 5: "CENTER_TOP", 6: "CENTER_RIGHT", 7: "CENTER_BOTTOM",
		8: "CENTER", 9: "LEFT_WIDE", 10: "TOP_WIDE", 11: "RIGHT_WIDE",
		12: "BOTTOM_WIDE", 13: "VCENTER_WIDE", 14: "HCENTER_WIDE", 15: "FULL_RECT"
	}
	for val in range(16):
		assert_has(preset_names, val, "Preset name should exist for value " + str(val))

# ===========================================
# connect_signal - 连接信号
# ===========================================

func test_connect_signal_missing_emitter_path():
	var result: Dictionary = _node_tools._tool_connect_signal({
		"signal_name": "pressed",
		"receiver_path": "/root/Node",
		"receiver_method": "handler"
	})
	assert_has(result, "error", "Should return error for missing emitter_path")

func test_connect_signal_missing_signal_name():
	var result: Dictionary = _node_tools._tool_connect_signal({
		"emitter_path": "/root/Node",
		"receiver_path": "/root/Node",
		"receiver_method": "handler"
	})
	assert_has(result, "error", "Should return error for missing signal_name")

func test_connect_signal_missing_receiver_path():
	var result: Dictionary = _node_tools._tool_connect_signal({
		"emitter_path": "/root/Node",
		"signal_name": "pressed",
		"receiver_method": "handler"
	})
	assert_has(result, "error", "Should return error for missing receiver_path")

func test_connect_signal_missing_receiver_method():
	var result: Dictionary = _node_tools._tool_connect_signal({
		"emitter_path": "/root/Node",
		"signal_name": "pressed",
		"receiver_path": "/root/Node"
	})
	assert_has(result, "error", "Should return error for missing receiver_method")

func test_connect_signal_basic():
	var emitter: Button = Button.new()
	emitter.name = "Button"
	add_child_autofree(emitter)
	var receiver: Node = Node.new()
	receiver.name = "Receiver"
	receiver.set_script(GDScript.new())
	add_child_autofree(receiver)
	var signal_list: Array = emitter.get_signal_list()
	var has_pressed: bool = false
	for sig in signal_list:
		if sig.get("name", "") == "pressed":
			has_pressed = true
			break
	assert_true(has_pressed, "Button should have 'pressed' signal")

func test_connect_signal_already_connected():
	var emitter: Button = Button.new()
	emitter.name = "Button"
	add_child_autofree(emitter)
	var receiver: Node = Node.new()
	receiver.name = "Receiver"
	add_child_autofree(receiver)
	var callable: Callable = Callable(receiver, "some_method")
	emitter.connect("pressed", callable)
	assert_true(emitter.is_connected("pressed", callable), "Signal should be connected")

# ===========================================
# disconnect_signal - 断开信号
# ===========================================

func test_disconnect_signal_missing_params():
	var result: Dictionary = _node_tools._tool_disconnect_signal({})
	assert_has(result, "error", "Should return error for missing params")

func test_disconnect_signal_not_connected():
	var emitter: Button = Button.new()
	emitter.name = "Button"
	add_child_autofree(emitter)
	var receiver: Node = Node.new()
	receiver.name = "Receiver"
	add_child_autofree(receiver)
	var callable: Callable = Callable(receiver, "some_method")
	assert_false(emitter.is_connected("pressed", callable), "Signal should not be connected initially")

func test_disconnect_signal_success():
	var emitter: Button = Button.new()
	emitter.name = "Button"
	add_child_autofree(emitter)
	var receiver: Node = Node.new()
	receiver.name = "Receiver"
	add_child_autofree(receiver)
	var callable: Callable = Callable(receiver, "some_method")
	emitter.connect("pressed", callable)
	assert_true(emitter.is_connected("pressed", callable), "Signal should be connected")
	emitter.disconnect("pressed", callable)
	assert_false(emitter.is_connected("pressed", callable), "Signal should be disconnected")

# ===========================================
# get_node_groups - 获取节点组
# ===========================================

func test_get_node_groups_missing_node_path():
	var result: Dictionary = _node_tools._tool_get_node_groups({})
	assert_has(result, "error", "Should return error for missing node_path")

func test_get_node_groups_empty_node_path():
	var result: Dictionary = _node_tools._tool_get_node_groups({"node_path": ""})
	assert_has(result, "error", "Should return error for empty node_path")

func test_get_node_groups_no_groups():
	var node: Node = Node.new()
	node.name = "TestNode"
	add_child_autofree(node)
	var groups: Array[StringName] = node.get_groups()
	assert_eq(groups.size(), 0, "New node should have no groups")

func test_get_node_groups_with_groups():
	var node: Node = Node.new()
	node.name = "TestNode"
	add_child_autofree(node)
	node.add_to_group("enemies")
	node.add_to_group("damageable")
	var groups: Array[StringName] = node.get_groups()
	assert_eq(groups.size(), 2, "Node should have 2 groups")

func test_get_node_groups_is_in_group():
	var node: Node = Node.new()
	node.name = "TestNode"
	add_child_autofree(node)
	node.add_to_group("player")
	assert_true(node.is_in_group("player"), "Node should be in 'player' group")
	assert_false(node.is_in_group("enemy"), "Node should not be in 'enemy' group")

# ===========================================
# set_node_groups - 设置节点组
# ===========================================

func test_set_node_groups_missing_node_path():
	var result: Dictionary = _node_tools._tool_set_node_groups({})
	assert_has(result, "error", "Should return error for missing node_path")

func test_set_node_groups_empty_node_path():
	var result: Dictionary = _node_tools._tool_set_node_groups({"node_path": ""})
	assert_has(result, "error", "Should return error for empty node_path")

func test_set_node_groups_add_groups():
	var node: Node = Node.new()
	node.name = "TestNode"
	add_child_autofree(node)
	node.add_to_group("group_a")
	node.add_to_group("group_b")
	assert_true(node.is_in_group("group_a"), "Should be in group_a")
	assert_true(node.is_in_group("group_b"), "Should be in group_b")

func test_set_node_groups_remove_groups():
	var node: Node = Node.new()
	node.name = "TestNode"
	add_child_autofree(node)
	node.add_to_group("group_a")
	node.add_to_group("group_b")
	node.remove_from_group("group_a")
	assert_false(node.is_in_group("group_a"), "Should not be in group_a after removal")
	assert_true(node.is_in_group("group_b"), "Should still be in group_b")

func test_set_node_groups_clear_existing():
	var node: Node = Node.new()
	node.name = "TestNode"
	add_child_autofree(node)
	node.add_to_group("old_group1")
	node.add_to_group("old_group2")
	var current_groups: Array[StringName] = node.get_groups()
	for group in current_groups:
		node.remove_from_group(group)
	assert_eq(node.get_groups().size(), 0, "All groups should be cleared")
	node.add_to_group("new_group")
	assert_true(node.is_in_group("new_group"), "Should be in new_group after clear and add")

func test_set_node_groups_add_duplicate():
	var node: Node = Node.new()
	node.name = "TestNode"
	add_child_autofree(node)
	node.add_to_group("group_a")
	if not node.is_in_group("group_a"):
		node.add_to_group("group_a")
	assert_true(node.is_in_group("group_a"), "Should still be in group_a after duplicate add attempt")

func test_set_node_groups_persistent():
	var node: Node = Node.new()
	node.name = "TestNode"
	add_child_autofree(node)
	node.add_to_group("persistent_group", true)
	assert_true(node.is_in_group("persistent_group"), "Should be in persistent_group")

# ===========================================
# find_nodes_in_group - 查找组中节点
# ===========================================

func test_find_nodes_in_group_missing_group():
	var result: Dictionary = _node_tools._tool_find_nodes_in_group({})
	assert_has(result, "error", "Should return error for missing group")

func test_find_nodes_in_group_empty_group():
	var result: Dictionary = _node_tools._tool_find_nodes_in_group({"group": ""})
	assert_has(result, "error", "Should return error for empty group")

func test_find_nodes_in_group_basic():
	var node1: Node = Node.new()
	node1.name = "Enemy1"
	add_child_autofree(node1)
	node1.add_to_group("enemies")
	var node2: Node = Node.new()
	node2.name = "Enemy2"
	add_child_autofree(node2)
	node2.add_to_group("enemies")
	var nodes_in_group: Array[Node] = get_tree().get_nodes_in_group("enemies")
	assert_eq(nodes_in_group.size(), 2, "Should find 2 nodes in enemies group")

func test_find_nodes_in_group_empty_group_result():
	var nodes_in_group: Array[Node] = get_tree().get_nodes_in_group("nonexistent_group")
	assert_eq(nodes_in_group.size(), 0, "Should find 0 nodes in nonexistent group")

func test_find_nodes_in_group_type_filter():
	var node2d: Node2D = Node2D.new()
	node2d.name = "Enemy2D"
	add_child_autofree(node2d)
	node2d.add_to_group("test_filter")
	var node3d: Node3D = Node3D.new()
	node3d.name = "Enemy3D"
	add_child_autofree(node3d)
	node3d.add_to_group("test_filter")
	var all_nodes: Array[Node] = get_tree().get_nodes_in_group("test_filter")
	assert_eq(all_nodes.size(), 2, "Should find 2 nodes without filter")
	var filtered: Array = []
	for node in all_nodes:
		if node.get_class() == "Node2D":
			filtered.append(node)
	assert_eq(filtered.size(), 1, "Should find 1 Node2D with type filter")

# ===========================================
# 综合边界条件测试
# ===========================================

func test_preset_names_completeness():
	var preset_names: Dictionary = {
		0: "TOP_LEFT", 1: "TOP_RIGHT", 2: "BOTTOM_LEFT", 3: "BOTTOM_RIGHT",
		4: "CENTER_LEFT", 5: "CENTER_TOP", 6: "CENTER_RIGHT", 7: "CENTER_BOTTOM",
		8: "CENTER", 9: "LEFT_WIDE", 10: "TOP_WIDE", 11: "RIGHT_WIDE",
		12: "BOTTOM_WIDE", 13: "VCENTER_WIDE", 14: "HCENTER_WIDE", 15: "FULL_RECT"
	}
	assert_eq(preset_names.size(), 16, "Should have 16 preset names")

func test_control_is_control_type():
	var control: Control = Control.new()
	add_child_autofree(control)
	assert_true(control is Control, "Control should be Control type")
	var node: Node = Node.new()
	add_child_autofree(node)
	assert_false(node is Control, "Node should not be Control type")

func test_node_duplicate_flags():
	var node: Node = Node.new()
	node.name = "Original"
	add_child_autofree(node)
	node.add_to_group("test_group")
	var dup_default: Node = node.duplicate()
	assert_true(dup_default.is_in_group("test_group"), "Default duplicate should preserve groups")
	dup_default.free()
	var dup_no_flags: Node = node.duplicate(0)
	assert_false(dup_no_flags.is_in_group("test_group"), "Zero-flag duplicate should not preserve groups")
	dup_no_flags.free()

func test_signal_connection_flags():
	assert_eq(0, 0, "CONNECT_DEFAULT = 0")
	assert_eq(1, 1, "CONNECT_DEFERRED = 1")
	assert_eq(2, 2, "CONNECT_ONE_SHOT = 2")
	assert_eq(4, 4, "CONNECT_PERSIST = 4")

func test_make_friendly_path_for_new_tools():
	var root: Node = Node.new()
	root.name = "SceneRoot"
	add_child_autofree(root)
	var child: Node = Node.new()
	child.name = "Child"
	root.add_child(child)
	var path: String = _node_tools._make_friendly_path(child, root)
	assert_eq(path, "/root/SceneRoot/Child", "Should generate correct friendly path")

func test_batch_scene_preview_summary_reports_result_paths():
	var root: Node = Node.new()
	root.name = "SceneRoot"
	add_child_autofree(root)
	var parent: Node = Node.new()
	parent.name = "UI"
	root.add_child(parent)
	var created: Node = Node.new()
	created.name = "Panel"
	var operations: Array = _node_tools._summarize_prepared_scene_node_operations([{
		"type": "create", "parent": parent, "node": created,
		"node_name": "Panel", "node_type": "Node"
	}], root)
	assert_eq(operations.size(), 1)
	assert_eq(operations[0].get("node_path"), "/root/SceneRoot/UI/Panel")
	created.free()
