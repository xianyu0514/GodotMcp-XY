extends "res://addons/gut/test.gd"

## batch_update_scene_files（P1 场景变体与批量修改）单测：expect_current
## 守卫保留特殊配置、显式 preserve 清单、类型跟随序列化、dry_run 预览、
## missing 上报、参数校验与幂等重跑。纯文件级夹具，不依赖编辑器。

const ToolsScript = preload("res://addons/godot_mcp/tools/scene_tools_native.gd")

const TMP: String = "res://.tmp_batch_scenes"
const GRUNT: String = TMP + "/grunt.tscn"
const BOSS: String = TMP + "/boss.tscn"

const FIXTURE_GRUNT: String = """[gd_scene load_steps=2 format=3]

[ext_resource type="Script" path="res://scripts/combat/melee_brain.gd" id="1_brain"]

[node name="Enemy" type="CharacterBody2D"]
script = ExtResource("1_brain")

[node name="Brain" type="Node" parent="."]
detect_range = 100.0
chase_speed = 200
display_name = "Grunt"

[node name="Visual" type="Sprite2D" parent="."]
"""

const FIXTURE_BOSS: String = """[gd_scene load_steps=2 format=3]

[ext_resource type="Script" path="res://scripts/combat/melee_brain.gd" id="1_brain"]

[node name="Enemy" type="CharacterBody2D"]
script = ExtResource("1_brain")

[node name="Brain" type="Node" parent="."]
detect_range = 300.0
chase_speed = 200
display_name = "Boss"

[node name="Visual" type="Sprite2D" parent="."]
"""

var _tools: RefCounted

func before_each() -> void:
	DirAccess.make_dir_recursive_absolute(TMP)
	_write(GRUNT, FIXTURE_GRUNT)
	_write(BOSS, FIXTURE_BOSS)
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
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	var content: String = file.get_as_text()
	file.close()
	return content

func _report_for(result: Dictionary, scene: String) -> Dictionary:
	for entry in result.get("scenes", []):
		if String(entry.get("scene", "")) == scene:
			return entry
	return {}

func test_dry_run_is_default_and_writes_nothing() -> void:
	var result: Dictionary = _tools._tool_batch_update_scene_files({
		"scenes": [GRUNT],
		"edits": [{"node": "Enemy/Brain", "property": "detect_range", "value": 150.0}]})
	assert_false(result.has("error"), str(result))
	assert_true(bool(result.get("dry_run", false)), "dry_run must default to true")
	assert_false(bool(result.get("written", true)))
	assert_true(_read(GRUNT).contains("detect_range = 100.0"), "file untouched in dry run")
	var grunt: Dictionary = _report_for(result, GRUNT)
	assert_eq((grunt.get("changed", []) as Array).size(), 1, "preview reports the pending change")

func test_apply_changes_grunt_and_preserves_boss_special_config() -> void:
	var result: Dictionary = _tools._tool_batch_update_scene_files({
		"scenes": [GRUNT, BOSS],
		"edits": [{"node": "Enemy/Brain", "property": "detect_range",
			"value": 150.0, "expect_current": 100.0}],
		"dry_run": false})
	assert_true(bool(result.get("written", false)))
	assert_true(_read(GRUNT).contains("detect_range = 150.0"), "grunt rewritten")
	assert_true(_read(BOSS).contains("detect_range = 300.0"), "boss special value untouched")
	var grunt: Dictionary = _report_for(result, GRUNT)
	var boss: Dictionary = _report_for(result, BOSS)
	assert_eq((grunt.get("changed", []) as Array).size(), 1)
	var boss_preserved: Array = boss.get("preserved", [])
	assert_eq(boss_preserved.size(), 1, "boss reported preserved")
	assert_true(String(boss_preserved[0].get("reason", "")).contains("expect_current"),
		"preserve reason names the guard: %s" % str(boss_preserved))

func test_explicit_preserve_list_is_absolute() -> void:
	var result: Dictionary = _tools._tool_batch_update_scene_files({
		"scenes": [GRUNT],
		"edits": [{"node": "Enemy/Brain", "property": "detect_range", "value": 150.0}],
		"preserve": [{"scene": GRUNT, "node": "Enemy/Brain", "property": "detect_range"}],
		"dry_run": false})
	assert_true(_read(GRUNT).contains("detect_range = 100.0"), "explicit keep wins")
	var grunt: Dictionary = _report_for(result, GRUNT)
	assert_eq((grunt.get("preserved", []) as Array).size(), 1)
	assert_eq((grunt.get("changed", []) as Array).size(), 0)

func test_type_following_serialization_keeps_int_lines_int() -> void:
	var result: Dictionary = _tools._tool_batch_update_scene_files({
		"scenes": [GRUNT],
		"edits": [{"node": "Enemy/Brain", "property": "chase_speed", "value": 220.0}],
		"dry_run": false})
	assert_true(_read(GRUNT).contains("chase_speed = 220\n") or _read(GRUNT).contains("chase_speed = 220\r"),
		"int line stays int (no 220.0): %s" % _read(GRUNT))
	var grunt: Dictionary = _report_for(result, GRUNT)
	assert_eq(String((grunt.get("changed", []) as Array)[0].get("to", "")), "220")

func test_string_value_serializes_quoted() -> void:
	_tools._tool_batch_update_scene_files({
		"scenes": [GRUNT],
		"edits": [{"node": "Enemy/Brain", "property": "display_name", "value": "Elite Grunt"}],
		"dry_run": false})
	assert_true(_read(GRUNT).contains("display_name = \"Elite Grunt\""),
		"string serialized quoted: %s" % _read(GRUNT))

func test_unserialized_property_reported_missing_never_appended() -> void:
	var before: String = _read(GRUNT)
	var result: Dictionary = _tools._tool_batch_update_scene_files({
		"scenes": [GRUNT],
		"edits": [{"node": "Enemy/Brain", "property": "attack_range", "value": 40.0}],
		"dry_run": false})
	var grunt: Dictionary = _report_for(result, GRUNT)
	assert_eq((grunt.get("missing", []) as Array).size(), 1, "missing reported")
	assert_true(_read(GRUNT) == before, "file byte-identical when nothing changed")

func test_missing_node_reported_missing() -> void:
	var result: Dictionary = _tools._tool_batch_update_scene_files({
		"scenes": [GRUNT],
		"edits": [{"node": "Enemy/Archer", "property": "detect_range", "value": 10.0}],
		"dry_run": false})
	var grunt: Dictionary = _report_for(result, GRUNT)
	assert_eq((grunt.get("missing", []) as Array).size(), 1)
	assert_true(String((grunt.get("missing", []) as Array)[0].get("reason", "")).contains("node not present"))

func test_second_run_is_idempotent_unchanged() -> void:
	var edit: Dictionary = {"node": "Enemy/Brain", "property": "detect_range", "value": 150.0}
	var first: Dictionary = _tools._tool_batch_update_scene_files({
		"scenes": [GRUNT], "edits": [edit], "dry_run": false})
	assert_eq(((_report_for(first, GRUNT).get("changed", []) as Array)).size(), 1)
	var second: Dictionary = _tools._tool_batch_update_scene_files({
		"scenes": [GRUNT], "edits": [edit], "dry_run": false})
	var grunt: Dictionary = _report_for(second, GRUNT)
	assert_eq((grunt.get("changed", []) as Array).size(), 0, "nothing changes twice")
	assert_eq((grunt.get("unchanged", []) as Array).size(), 1, "reported as already at target")

func test_nonexistent_scene_reported_per_file_not_fatal() -> void:
	var result: Dictionary = _tools._tool_batch_update_scene_files({
		"scenes": [GRUNT, "res://.tmp_batch_scenes/nope.tscn"],
		"edits": [{"node": "Enemy/Brain", "property": "detect_range", "value": 150.0}],
		"dry_run": false})
	assert_false(result.has("error"), "one bad scene must not kill the batch")
	var nope: Dictionary = _report_for(result, "res://.tmp_batch_scenes/nope.tscn")
	assert_true(nope.has("error"))

func test_parameter_validation_rejects_bad_input() -> void:
	var cases: Array = [
		{"edits": [{"node": "N", "property": "p", "value": 1}]},
		{"scenes": [GRUNT]},
		{"scenes": [GRUNT], "edits": ["not an object"]},
		{"scenes": [GRUNT], "edits": [{"property": "p", "value": 1}]},
		{"scenes": [GRUNT], "edits": [{"node": "N", "value": 1}]},
		{"scenes": [GRUNT], "edits": [{"node": "N", "property": "not an id", "value": 1}]},
		{"scenes": [GRUNT], "edits": [{"node": "N", "property": "p"}]},
	]
	for params in cases:
		var result: Dictionary = _tools._tool_batch_update_scene_files(params)
		assert_true(result.has("error"), "must reject: %s" % str(params))

func test_deep_node_path_resolution_includes_root_name() -> void:
	# parent 语义钉死：Leaf 段写 parent="Mid"（不含根名），完整路径 Root/Mid/Leaf。
	DirAccess.make_dir_recursive_absolute(TMP)
	_write(TMP + "/deep.tscn", "[gd_scene format=3]

[node name=\"Root\" type=\"Node2D\"]

[node name=\"Mid\" type=\"Node2D\" parent=\".\"]

[node name=\"Leaf\" type=\"Node2D\" parent=\"Mid\"]
cooldown_seconds = 0.4
")
	var result: Dictionary = _tools._tool_batch_update_scene_files({
		"scenes": [TMP + "/deep.tscn"],
		"edits": [{"node": "Root/Mid/Leaf", "property": "cooldown_seconds",
			"value": 0.6, "expect_current": 0.4}],
		"dry_run": false})
	var deep: Dictionary = _report_for(result, TMP + "/deep.tscn")
	assert_eq((deep.get("changed", []) as Array).size(), 1,
		"depth-2 node resolves: %s" % str(deep.get("missing", [])))
	assert_true(_read(TMP + "/deep.tscn").contains("cooldown_seconds = 0.6"))

func test_other_lines_stay_byte_identical() -> void:
	var before: String = _read(BOSS)
	_tools._tool_batch_update_scene_files({
		"scenes": [BOSS],
		"edits": [{"node": "Enemy/Brain", "property": "chase_speed", "value": 260}],
		"dry_run": false})
	var after: String = _read(BOSS)
	var before_lines: PackedStringArray = before.split("\n")
	var after_lines: PackedStringArray = after.split("\n")
	assert_eq(before_lines.size(), after_lines.size(), "line count unchanged")
	var differing: int = 0
	for i in before_lines.size():
		if before_lines[i] != after_lines[i]:
			differing += 1
			assert_true(before_lines[i].contains("chase_speed"), "only the edited line differs: %s" % before_lines[i])
	assert_eq(differing, 1, "exactly one line rewritten")
