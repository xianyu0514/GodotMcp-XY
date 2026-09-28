extends "res://addons/gut/test.gd"

# get_scene_structure 只读巡检回归（2026-09-27 体检 P1-6）：
# 此前只能读"当前编辑器场景"，巡检其余场景必须侵入式 open_scene；
# max_depth 截断时 total_nodes 与实际展示的树对不上且无量化说明。

const SceneToolsScript = preload("res://addons/godot_mcp/tools/scene_tools_native.gd")

var _fixture_path: String = ""

func before_each() -> void:
	_fixture_path = "res://tmp_scene_structure_fixture_%d.tscn" % Time.get_ticks_usec()

func after_each() -> void:
	if not _fixture_path.is_empty() and FileAccess.file_exists(_fixture_path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(_fixture_path))
	_fixture_path = ""

## 构造 4 节点场景：TestRoot(Node2D) → Leaf(Sprite2D) + Branch(Node) → Leaf2(Label)
func _write_fixture_scene() -> String:
	var root: Node2D = Node2D.new()
	root.name = "TestRoot"
	var leaf: Sprite2D = Sprite2D.new()
	leaf.name = "Leaf"
	root.add_child(leaf)
	var branch: Node = Node.new()
	branch.name = "Branch"
	root.add_child(branch)
	var grandchild: Label = Label.new()
	grandchild.name = "Leaf2"
	branch.add_child(grandchild)
	leaf.owner = root
	branch.owner = root
	grandchild.owner = root
	var packed: PackedScene = PackedScene.new()
	var pack_err: int = packed.pack(root)
	root.free()
	assert_eq(pack_err, OK, "fixture 场景 pack 应成功")
	var save_err: int = ResourceSaver.save(packed, _fixture_path)
	assert_eq(save_err, OK, "fixture 场景保存应成功")
	return _fixture_path

func test_scene_path_inspects_without_opening() -> void:
	var tools: RefCounted = SceneToolsScript.new()
	var fixture: String = _write_fixture_scene()
	var result: Dictionary = tools._tool_get_scene_structure({"scene_path": fixture})
	assert_false(result.has("error"), str(result))
	assert_eq(String(result["scene_name"]), "TestRoot")
	assert_eq(String(result["scene_path"]), fixture, "文件巡检必须回显 scene_path")
	var children: Array = (result["root_node"] as Dictionary).get("children", [])
	assert_eq(children.size(), 2, "根下应有 2 个直接子节点")

func test_truncation_reports_hidden_descendants() -> void:
	var tools: RefCounted = SceneToolsScript.new()
	var fixture: String = _write_fixture_scene()
	var result: Dictionary = tools._tool_get_scene_structure({"scene_path": fixture, "max_depth": 1})
	assert_false(result.has("error"), str(result))
	# 全量 4 节点，max_depth=1 可见 3 个（根 + 2 子），隐藏 1 个（Leaf2）
	assert_eq(int(result["total_nodes"]), 4)
	assert_eq(int(result["hidden_descendants"]), 1, "场景级必须量化被隐藏的后代数")
	var children: Array = (result["root_node"] as Dictionary).get("children", [])
	for child in children:
		var info: Dictionary = child
		if String(info.get("name", "")) == "Branch":
			assert_true(bool(info.get("children_truncated", false)))
			assert_eq(int(info.get("hidden_descendants", -1)), 1, "截断点节点应报告自身隐藏的后代数")

func test_no_truncation_reports_zero_hidden() -> void:
	var tools: RefCounted = SceneToolsScript.new()
	var fixture: String = _write_fixture_scene()
	var result: Dictionary = tools._tool_get_scene_structure({"scene_path": fixture, "max_depth": 8})
	assert_false(result.has("error"), str(result))
	assert_eq(int(result["hidden_descendants"]), 0, "无截断时隐藏数为 0")

func test_missing_scene_file_error_is_actionable() -> void:
	var tools: RefCounted = SceneToolsScript.new()
	var result: Dictionary = tools._tool_get_scene_structure({"scene_path": "res://no_such_scene_%d.tscn" % Time.get_ticks_usec()})
	assert_true(result.has("error"))
	assert_true(str(result["error"]).contains("list_project_scenes"), "错误应指路场景清单工具")

func test_non_res_path_rejected() -> void:
	var tools: RefCounted = SceneToolsScript.new()
	var result: Dictionary = tools._tool_get_scene_structure({"scene_path": "C:/elsewhere/scene.tscn"})
	assert_true(result.has("error"))
	assert_true(str(result["error"]).contains("res://"))

func test_no_open_scene_error_mentions_scene_path_hint() -> void:
	var tools: RefCounted = SceneToolsScript.new()
	var result: Dictionary = tools._tool_get_scene_structure({})
	# headless GUT 通常无编辑器界面或无已打开场景；两者都是合法环境 outcomes。
	if result.has("error"):
		var message: String = str(result["error"])
		if message.contains("No scene is currently open"):
			assert_true(message.contains("scene_path"), "无场景报错应提示 scene_path 替代方案")
		else:
			assert_true(message.contains("Editor interface"), "headless 环境应返回已知的界面缺失文案: " + message)
	else:
		assert_true(result.has("root_node"))
