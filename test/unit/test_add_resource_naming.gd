extends "res://addons/gut/test.gd"

var _node_tools: RefCounted = null

func before_each():
	_node_tools = load("res://addons/godot_mcp/tools/node_tools_native.gd").new()

func after_each():
	_node_tools = null

func test_add_resource_default_name():
	var parent: Node = Node.new()
	parent.name = "Parent"
	add_child_autofree(parent)
	var child: CollisionShape3D = CollisionShape3D.new()
	child.name = "CollisionShape3D"
	parent.add_child(child)
	var existing_count: int = parent.get_child_count()
	assert_true(parent.has_node("CollisionShape3D"), "Child exists with type name")

func test_add_resource_name_conflict_resolution():
	var parent: Node = Node.new()
	parent.name = "Parent"
	add_child_autofree(parent)
	var child1: CollisionShape3D = CollisionShape3D.new()
	child1.name = "CollisionShape3D"
	parent.add_child(child1)
	assert_true(parent.has_node("CollisionShape3D"), "First child with type name")
	var child2: CollisionShape3D = CollisionShape3D.new()
	if parent.has_node("CollisionShape3D"):
		var suffix: int = 2
		while parent.has_node("CollisionShape3D" + str(suffix)):
			suffix += 1
		child2.name = "CollisionShape3D" + str(suffix)
	else:
		child2.name = "CollisionShape3D"
	parent.add_child(child2)
	assert_true(parent.has_node("CollisionShape3D2"), "Second child gets suffixed name")
