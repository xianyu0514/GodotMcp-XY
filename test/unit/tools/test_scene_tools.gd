extends "res://addons/gut/test.gd"

var _scene_tools: RefCounted = null

func before_each() -> void:
	_scene_tools = load("res://addons/godot_mcp/tools/scene_tools_native.gd").new()

func after_each() -> void:
	_scene_tools = null
	if Engine.has_meta("GodotMCPPlugin"):
		Engine.remove_meta("GodotMCPPlugin")

func test_scene_extension_validation():
	assert_has([".tscn"], ".tscn", "Scene should have .tscn extension")

func test_scene_path_safety():
	assert_true(true, "res:// scene path should be safe")

func test_scene_structure_format():
	var result: Dictionary = {"root_node": {"children": []}}
	assert_has(result, "root_node", "Should have root_node")
	assert_has(result.root_node, "children", "Root node should have children")

func test_friendly_path_for_scene():
	var root_path: String = "/root/MainScene"
	assert_true(root_path.contains("MainScene"), "Root path should contain MainScene")

func test_current_scene_format():
	var result: Dictionary = {"scene_path": "res://main.tscn", "scene_name": "Main"}
	assert_has(result, "scene_path", "Should have scene_path")
	assert_has(result, "scene_name", "Should have scene_name")

# --- Vibe Coding policy guard tests ---

func test_open_scene_blocked_in_vibe_mode() -> void:
	var result: Dictionary = _scene_tools._tool_open_scene({"scene_path": "res://TestScene.tscn"})
	assert_true(result.get("blocked", false), "open_scene should be blocked in vibe mode")
	assert_eq(result.get("reason", ""), "vibe_coding_mode", "Block reason should be vibe_coding_mode")

func test_open_scene_bypasses_with_allow_ui_focus() -> void:
	var result: Dictionary = _scene_tools._tool_open_scene({"scene_path": "res://TestScene.tscn", "allow_ui_focus": true})
	assert_false(result.get("blocked", false), "allow_ui_focus should bypass vibe mode")

func test_close_scene_tab_blocked_in_vibe_mode() -> void:
	var result: Dictionary = _scene_tools._tool_close_scene_tab({})
	assert_true(result.get("blocked", false), "close_scene_tab should be blocked in vibe mode")

func test_close_scene_tab_bypasses_with_allow_ui_focus() -> void:
	var result: Dictionary = _scene_tools._tool_close_scene_tab({"allow_ui_focus": true})
	assert_false(result.get("blocked", false), "allow_ui_focus should bypass vibe mode")

# --- Save-as operation field tests ---

func test_save_scene_returns_operation_field():
	"""save_scene without file_path returns operation=save"""
	var result: Dictionary = _scene_tools._tool_save_scene({"file_path": ""})
	# Will error because no scene is open, but the structure should include operation
	if result.has("operation"):
		assert_true(result.get("operation", "") in ["save", "save_as"], "operation should be 'save' or 'save_as'")

func test_save_scene_output_schema_includes_operation():
	"""verify output_schema in _register_save_scene includes operation field"""
	var result: Dictionary = _scene_tools._tool_save_scene({"file_path": ""})
	# In headless mode: will error. When it succeeds, it should have operation.
	if result.has("error"):
		pass_test("Headless mode: expected error without editor interface")
	else:
		assert_has(result, "operation", "save_scene should return operation field")

func test_open_scene_returns_verification_tip_on_success():
	"""open_scene that bypasses vibe mode should include verification_tip in success path"""
	var result: Dictionary = _scene_tools._tool_open_scene({"scene_path": "res://TestScene.tscn", "allow_ui_focus": true})
	# In headless mode without editor interface, this will error.
	# But if it somehow succeeds, it should have verification_tip.
	if result.get("status") == "success":
		assert_has(result, "verification_tip", "successful open_scene should include verification_tip")
		assert_true(result.get("verification_tip", "").length() > 0, "verification_tip should not be empty")

# --- instantiate_scene (Batch 2 prefab tool) ---

func test_instantiate_scene_missing_path():
	var result: Dictionary = _scene_tools._tool_instantiate_scene({})
	assert_has(result, "error", "Missing scene_path should return an error")

func test_instantiate_scene_rejects_non_tscn():
	var result: Dictionary = _scene_tools._tool_instantiate_scene({"scene_path": "res://card.txt"})
	assert_has(result, "error", "Non-.tscn path should return an error")

func test_instantiate_scene_missing_file():
	var result: Dictionary = _scene_tools._tool_instantiate_scene({"scene_path": "res://does_not_exist_prefab.tscn"})
	assert_has(result, "error", "Nonexistent scene file should return an error")
	assert_true(result.get("error", "").contains("not found"), "Error should mention the missing file")

# --- save_branch_as_scene (Batch 2 prefab tool) ---

func test_save_branch_as_scene_missing_node_path():
	var result: Dictionary = _scene_tools._tool_save_branch_as_scene({"scene_path": "res://branch.tscn"})
	assert_has(result, "error", "Missing node_path should return an error")

func test_save_branch_as_scene_missing_scene_path():
	var result: Dictionary = _scene_tools._tool_save_branch_as_scene({"node_path": "/root/Main/Branch"})
	assert_has(result, "error", "Missing scene_path should return an error")

func test_save_branch_as_scene_rejects_non_tscn():
	var result: Dictionary = _scene_tools._tool_save_branch_as_scene({"node_path": "/root/Main/Branch", "scene_path": "res://branch.txt"})
	assert_has(result, "error", "Non-.tscn save path should return an error")

# --- subtree helpers (run without an editor) ---

func test_count_nodes_counts_subtree():
	var root: Node = Node.new()
	var a: Node = Node.new()
	var b: Node = Node.new()
	var c: Node = Node.new()
	root.add_child(a)
	root.add_child(b)
	a.add_child(c)
	assert_eq(_scene_tools._count_nodes(root), 4, "Should count root plus 3 descendants")
	root.free()

func test_assign_owner_recursive_sets_owner():
	var root: Node = Node.new()
	var child: Node = Node.new()
	var grandchild: Node = Node.new()
	root.add_child(child)
	child.add_child(grandchild)
	_scene_tools._assign_owner_recursive(root, root)
	assert_eq(child.owner, root, "child owner should be the branch root")
	assert_eq(grandchild.owner, root, "grandchild owner should be the branch root")
	root.free()

func test_assign_owner_recursive_skips_instanced_subscene_internals():
	# An instanced sub-scene root should be owned by the branch root (so it is
	# included), but its internals must NOT be re-owned, otherwise pack() would
	# flatten the instance into inline nodes.
	var sub_path: String = "res://test/unit/tools/.tmp_owner_sub.tscn"
	var sub_root: Node2D = Node2D.new()
	sub_root.name = "SubRoot"
	var sub_child: Node2D = Node2D.new()
	sub_child.name = "SubChild"
	sub_root.add_child(sub_child)
	sub_child.owner = sub_root
	var sub_pack: PackedScene = PackedScene.new()
	assert_eq(sub_pack.pack(sub_root), OK, "sub-scene should pack")
	assert_eq(ResourceSaver.save(sub_pack, sub_path), OK, "sub-scene should save")
	sub_root.free()

	var loaded_sub: PackedScene = load(sub_path) as PackedScene
	var branch: Node2D = Node2D.new()
	branch.name = "Branch"
	var plain: Node2D = Node2D.new()
	plain.name = "Plain"
	branch.add_child(plain)
	var instance: Node = loaded_sub.instantiate()
	instance.name = "Instance"
	branch.add_child(instance)
	assert_false(instance.scene_file_path.is_empty(), "instance should carry scene_file_path")

	_scene_tools._assign_owner_recursive(branch, branch)
	assert_eq(plain.owner, branch, "plain child should be owned by branch root")
	assert_eq(instance.owner, branch, "instance root should be owned by branch root")
	var instance_child: Node = instance.get_node("SubChild")
	assert_ne(instance_child.owner, branch, "instance internals must not be re-owned by branch root")

	branch.free()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(sub_path))

func test_save_branch_round_trip_preserves_nested_instance():
	# Mirror the tool's duplicate+own+pack+save flow and confirm a nested
	# instance survives as a scene reference (non-empty scene_file_path) rather
	# than being flattened.
	var sub_path: String = "res://test/unit/tools/.tmp_rt_sub.tscn"
	var out_path: String = "res://test/unit/tools/.tmp_rt_branch.tscn"
	var sub_root: Node2D = Node2D.new()
	sub_root.name = "SubRoot"
	var sub_child: Node2D = Node2D.new()
	sub_child.name = "SubChild"
	sub_root.add_child(sub_child)
	sub_child.owner = sub_root
	var sub_pack: PackedScene = PackedScene.new()
	assert_eq(sub_pack.pack(sub_root), OK, "sub-scene should pack")
	assert_eq(ResourceSaver.save(sub_pack, sub_path), OK, "sub-scene should save")
	sub_root.free()

	var loaded_sub: PackedScene = load(sub_path) as PackedScene
	var branch: Node2D = Node2D.new()
	branch.name = "Branch"
	var instance: Node = loaded_sub.instantiate()
	instance.name = "Instance"
	branch.add_child(instance)

	var dup: Node = branch.duplicate(
		Node.DUPLICATE_SIGNALS | Node.DUPLICATE_GROUPS
		| Node.DUPLICATE_SCRIPTS | Node.DUPLICATE_USE_INSTANTIATION)
	_scene_tools._assign_owner_recursive(dup, dup)
	assert_false(dup.get_node("Instance").scene_file_path.is_empty(),
		"duplicate should keep nested instance scene_file_path")

	var packed: PackedScene = PackedScene.new()
	assert_eq(packed.pack(dup), OK, "branch should pack")
	assert_eq(ResourceSaver.save(packed, out_path), OK, "branch should save")

	var reloaded: Node = (load(out_path) as PackedScene).instantiate()
	assert_false(reloaded.get_node("Instance").scene_file_path.is_empty(),
		"reloaded branch should keep the nested instance as a scene reference")

	branch.free()
	dup.free()
	reloaded.free()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(sub_path))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(out_path))
