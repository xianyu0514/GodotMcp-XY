extends "res://addons/gut/test.gd"

## create_scene_variant（M3 变体与规模）单测：继承结构正确性、覆盖段
## 语义（parent 相对根）、幂等 skip、参数校验，以及用 verify_change_effect
## 的实体解析器回读变体（自产自销闭环）。

const ToolsScript = preload("res://addons/godot_mcp/tools/scene_tools_native.gd")
const VerifyToolsScript = preload("res://addons/godot_mcp/tools/debug_verify_tools.gd")

const TMP: String = "res://.tmp_variant"

const BASE_SCENE: String = """[gd_scene load_steps=2 format=3 uid="uid://b4se123"]

[ext_resource type="Script" path="res://scripts/combat/melee_brain.gd" id="1_brain"]

[node name="Enemy" type="CharacterBody2D"]
script = ExtResource("1_brain")

[node name="Brain" type="Node" parent="."]
detect_range = 100.0
chase_speed = 200

[node name="Mid" type="Node2D" parent="."]

[node name="Leaf" type="Node2D" parent="Mid"]
power = 1
"""

var _tools: RefCounted

func before_each() -> void:
	DirAccess.make_dir_recursive_absolute(TMP)
	_write(TMP + "/enemy.tscn", BASE_SCENE)
	_tools = ToolsScript.new()

func after_each() -> void:
	_tools = null
	var dir: DirAccess = DirAccess.open(TMP)
	if dir:
		for entry in dir.get_files():
			dir.remove(entry)
	var root: DirAccess = DirAccess.open("res://")
	if root and root.dir_exists(TMP.trim_prefix("res://")):
		root.remove(TMP.trim_prefix("res://"))

func _write(path: String, content: String) -> void:
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	file.store_string(content)
	file.close()

func _read(path: String) -> String:
	return ToolsScript._variant_read_text(path)

func test_variant_inherits_base_with_uid_passthrough() -> void:
	var result: Dictionary = _tools._tool_create_scene_variant({
		"scene_path": TMP + "/boss.tscn",
		"base_scene": TMP + "/enemy.tscn",
		"overrides": [{"node": "Brain", "property": "detect_range", "value": 300.0}]})
	assert_false(result.has("error"), str(result))
	assert_eq(String(result.get("status", "")), "success")
	assert_eq(String(result.get("root_name", "")), "Enemy")
	var text: String = _read(TMP + "/boss.tscn")
	assert_true(text.contains("instance=ExtResource"), "root instantiates the base")
	assert_true(text.contains('uid="uid://b4se123"'), "base uid passed through to ext_resource")
	assert_true(text.contains("path=\"%s\"" % (TMP + "/enemy.tscn")))

func test_root_and_child_and_deep_overrides_written() -> void:
	var result: Dictionary = _tools._tool_create_scene_variant({
		"scene_path": TMP + "/elite.tscn",
		"base_scene": TMP + "/enemy.tscn",
		"overrides": [
			{"node": ".", "property": "modulate_color", "value": "red"},
			{"node": "Brain", "property": "detect_range", "value": 300.0},
			{"node": "Mid/Leaf", "property": "power", "value": 5},
		]})
	assert_eq(int(result.get("overrides_applied", 0)), 3)
	var text: String = _read(TMP + "/elite.tscn")
	# 根覆盖直接在根段体
	assert_true(text.contains("modulate_color = \"red\""), "root override on the root section")
	# 子覆盖：parent="."（相对根）
	assert_true(text.contains("[node name=\"Brain\" parent=\".\"]"), "child override section parent='.'")
	assert_true(text.contains("detect_range = 300.0"))
	# 深层覆盖：parent="Mid"（不含根名——与仓库解析语义一致）
	assert_true(text.contains("[node name=\"Leaf\" parent=\"Mid\"]"), "deep override parent excludes the root name")
	assert_true(text.contains("power = 5"), "int value type-followed (no .0)")

func test_variant_readable_back_by_entity_resolver() -> void:
	# 自产自销闭环：verify_change_effect 的实体解析器能读回变体的覆盖值。
	_tools._tool_create_scene_variant({
		"scene_path": TMP + "/boss.tscn",
		"base_scene": TMP + "/enemy.tscn",
		"overrides": [{"node": "Brain", "property": "detect_range", "value": 300.0}]})
	var entity: Dictionary = VerifyToolsScript._resolve_scene_entity(
		_read(TMP + "/boss.tscn"), "Enemy/Brain", "detect_range")
	assert_true(bool(entity.get("found", false)), "variant node path resolves")
	assert_true(bool(entity.get("has_property", false)), "override value serialized in the section")

func test_existing_variant_skipped_by_default() -> void:
	_write(TMP + "/boss.tscn", "[gd_scene format=3]\n")
	var result: Dictionary = _tools._tool_create_scene_variant({
		"scene_path": TMP + "/boss.tscn",
		"base_scene": TMP + "/enemy.tscn"})
	assert_eq(String(result.get("status", "")), "exists", "idempotent skip")
	assert_true(_read(TMP + "/boss.tscn").contains("[gd_scene format=3]"), "existing file untouched")
	var error_case: Dictionary = _tools._tool_create_scene_variant({
		"scene_path": TMP + "/boss.tscn",
		"base_scene": TMP + "/enemy.tscn", "on_exists": "error"})
	assert_true(error_case.has("error"), "on_exists=error refuses")

func test_parameter_validation_rejects_bad_input() -> void:
	var cases: Array = [
		{"base_scene": TMP + "/enemy.tscn"},
		{"scene_path": TMP + "/x.tscn"},
		{"scene_path": TMP + "/x.tscn", "base_scene": TMP + "/missing.tscn"},
		{"scene_path": TMP + "/x.tscn", "base_scene": TMP + "/enemy.tscn",
			"overrides": [{"node": "Brain", "property": "not an id", "value": 1}]},
		{"scene_path": TMP + "/x.tscn", "base_scene": TMP + "/enemy.tscn",
			"overrides": [{"node": "Brain", "property": "ok", }]},
	]
	for params in cases:
		var result: Dictionary = _tools._tool_create_scene_variant(params)
		assert_true(result.has("error") or String(result.get("status", "")) == "exists",
			"must reject or skip: %s -> %s" % [str(params), str(result)])
	assert_false(FileAccess.file_exists(TMP + "/x.tscn"), "nothing created by invalid calls")

func test_self_inheritance_refused() -> void:
	var result: Dictionary = _tools._tool_create_scene_variant({
		"scene_path": TMP + "/enemy.tscn",
		"base_scene": TMP + "/enemy.tscn"})
	assert_true(result.has("error"), "a scene cannot inherit itself")
