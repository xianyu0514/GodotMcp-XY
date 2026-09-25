extends "res://addons/gut/test.gd"

## 父路径自愈建议（2D 矩阵首跑实测坑的修复）：create_node 只写名字找不到
## 孙节点时，错误信息应直接给出根相对全路径候选与写法教学。

const ToolsScript = preload("res://addons/godot_mcp/tools/node_tools_native.gd")

var _root: Node

func before_each() -> void:
	_root = Node.new()
	_root.name = "parallax"
	var bg := Node.new()
	bg.name = "BG"
	_root.add_child(bg)
	var far := Node.new()
	far.name = "Far"
	bg.add_child(far)
	var near := Node.new()
	near.name = "Near"
	bg.add_child(near)
	var player := Node.new()
	player.name = "Player"
	_root.add_child(player)

func after_each() -> void:
	_root.free()

func test_unique_name_match_suggests_the_full_path() -> void:
	var hint: String = ToolsScript._suggest_parent_path(_root, "Far")
	assert_true(hint.contains("did you mean 'BG/Far'"), "unique match suggests the exact full path: %s" % hint)
	assert_true(hint.contains("root-relative"), "the error also teaches the path form")

func test_ambiguous_name_lists_candidates() -> void:
	var duplicate := Node.new()
	duplicate.name = "Far"
	(_root.get_node("Player") as Node).add_child(duplicate)
	var hint: String = ToolsScript._suggest_parent_path(_root, "Far")
	assert_true(hint.contains("BG/Far") and hint.contains("Player/Far"),
		"multiple matches list every candidate: %s" % hint)

func test_no_match_still_teaches_the_form() -> void:
	var hint: String = ToolsScript._suggest_parent_path(_root, "Nonexistent")
	assert_true(hint.contains("root-relative") and hint.contains("Parent/Child"),
		"no candidates => the path-form lesson is still appended: %s" % hint)

func test_null_root_or_empty_path_is_silent() -> void:
	assert_eq(ToolsScript._suggest_parent_path(null, "Far"), "", "no scene root => no suggestion")
	assert_eq(ToolsScript._suggest_parent_path(_root, ""), "", "no path => no suggestion")

func test_exact_path_hit_is_not_a_candidate() -> void:
	# BG/Far 本身可解析时不应出现在候选里（这是"路径写对了"的情况，
	# 不会走到错误分支——防御性断言候选收集不会自匹配）。
	var candidates: Array = []
	ToolsScript._collect_path_matches(_root, "", "BG/Far", "Far", candidates)
	assert_false(candidates.has("BG/Far"), "the resolvable path itself is not suggested")
	assert_true(candidates.is_empty(), "no other node is named Far: %s" % str(candidates))
