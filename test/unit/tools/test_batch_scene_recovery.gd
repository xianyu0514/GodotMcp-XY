extends "res://addons/gut/test.gd"

class SceneTools:
	extends "res://addons/godot_mcp/tools/node_tools_native.gd"
	var scene_root: Node
	func _get_user_scene_root() -> Node:
		return scene_root

var tools: SceneTools
var scene_root: Node

func before_each() -> void:
	scene_root = Node.new()
	scene_root.name = "Scene"
	tools = SceneTools.new()
	tools.scene_root = scene_root
	_add_node(scene_root, "First")
	_add_node(scene_root, "Second")

func after_each() -> void:
	scene_root.free()
	tools = null

func _add_node(parent: Node, node_name: String) -> Node:
	var node: Node = Node.new()
	node.name = node_name
	parent.add_child(node)
	node.owner = scene_root
	return node

func _prepare(operations: Array) -> Dictionary:
	return tools._prepare_batch_scene_node_edits(operations, scene_root)

func test_invalid_batch_never_allocates_or_changes_nodes() -> void:
	var before: int = int(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT))
	var result: Dictionary = _prepare([
		{"type": "create", "parent_path": "/root", "node_name": "Prepared"},
		{"type": "delete", "node_path": "/root/Missing"}
	])
	assert_true(result.has("error"))
	assert_eq(scene_root.get_child_count(), 2)
	assert_eq(int(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT)), before,
		"An invalid batch must not leak prepared nodes")

func test_duplicate_delete_is_rejected_before_mutation() -> void:
	var result: Dictionary = _prepare([
		{"type": "delete", "node_path": "/root/First"},
		{"type": "delete", "node_path": "/root/First"}
	])
	assert_true(result.has("error"), "Deleting the same object twice cannot form a valid action")
	assert_eq(scene_root.get_child_count(), 2)

func test_create_name_collision_is_rejected() -> void:
	var result: Dictionary = _prepare([
		{"type": "create", "parent_path": "/root", "node_name": "First"}
	])
	assert_true(result.has("error"), "Godot auto-renaming would invalidate the returned path")

func test_scene_root_cannot_be_deleted_even_when_parented() -> void:
	var editor_parent: Node = Node.new()
	editor_parent.add_child(scene_root)
	var result: Dictionary = _prepare([{"type": "delete", "node_path": "/root"}])
	assert_true(result.has("error"))
	editor_parent.remove_child(scene_root)
	editor_parent.free()

func test_malformed_operations_are_rejected_before_editor_access() -> void:
	assert_has(tools._tool_batch_scene_node_edits({"operations": "wrong"}), "error")
	assert_has(tools._tool_batch_scene_node_edits({"operations": []}), "error")
	assert_has(_prepare([null]), "error")
	assert_has(_prepare([{"type": "unknown"}]), "error")

func test_invalid_node_type_is_rejected_without_allocations() -> void:
	for type_name in ["Resource", "MissingBatchNodeClass"]:
		var result: Dictionary = _prepare([{"type": "create", "parent_path": "/root", "node_type": type_name}])
		assert_has(result, "error")

func test_two_creates_cannot_reserve_the_same_name() -> void:
	assert_has(_prepare([
		{"type": "create", "parent_path": "/root", "node_name": "New"},
		{"type": "create", "parent_path": "/root", "node_name": "New"}
	]), "error")

func test_delete_then_recreate_name_and_rename_then_move_remain_supported() -> void:
	assert_false(_prepare([
		{"type": "delete", "node_path": "/root/First"},
		{"type": "create", "parent_path": "/root", "node_name": "First"}
	]).has("error"))
	assert_false(_prepare([
		{"type": "rename", "node_path": "/root/First", "new_name": "Renamed"},
		{"type": "move", "node_path": "/root/First", "new_parent_path": "/root/Second"}
	]).has("error"), "Operations resolve references against the initial scene")

func test_deleted_subtree_cannot_be_used_by_a_later_operation() -> void:
	_add_node(scene_root.get_node("First"), "Nested")
	for operation in [
		{"type": "rename", "node_path": "/root/First/Nested", "new_name": "Renamed"},
		{"type": "create", "parent_path": "/root/First", "node_name": "New"},
		{"type": "move", "node_path": "/root/Second", "new_parent_path": "/root/First"}
	]:
		assert_has(_prepare([{"type": "delete", "node_path": "/root/First"}, operation]), "error")
	assert_eq(scene_root.get_child_count(), 2)

func test_moves_cannot_create_a_cycle_in_the_simulated_hierarchy() -> void:
	assert_has(_prepare([
		{"type": "move", "node_path": "/root/First", "new_parent_path": "/root/Second"},
		{"type": "move", "node_path": "/root/Second", "new_parent_path": "/root/First"}
	]), "error")

func test_rename_collision_and_invalid_names_are_rejected() -> void:
	for new_name in ["Second", "a/b", ".", ".."]:
		assert_has(_prepare([{"type": "rename", "node_path": "/root/First", "new_name": new_name}]), "error")
