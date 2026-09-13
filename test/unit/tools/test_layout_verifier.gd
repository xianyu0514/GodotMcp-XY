extends "res://addons/gut/test.gd"

## E3 离线布局求解器测试：锚点解算、越界、兄弟重叠、三尺寸。

const LayoutVerifier = preload("res://addons/godot_mcp/tools/layout_verifier.gd")

const TEMP_DIR: String = "res://.tmp_layout_verifier"
const SIZES: Array = [Vector2i(854, 480), Vector2i(1280, 720), Vector2i(1920, 1080)]

func before_each() -> void:
	DirAccess.make_dir_recursive_absolute(TEMP_DIR)

func after_each() -> void:
	for file_name: String in DirAccess.get_files_at(TEMP_DIR):
		DirAccess.remove_absolute(TEMP_DIR.path_join(file_name))
	DirAccess.remove_absolute(TEMP_DIR)

func _write_scene(name: String, body: String) -> String:
	var path: String = TEMP_DIR + "/" + name
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	file.store_string('[gd_scene format=3]\n\n[node name="UI" type="Control"]\n' + body)
	file.close()
	return path

func test_well_anchored_layout_passes_all_sizes() -> void:
	var path: String = _write_scene("good.tscn", """
[node name="Start" type="Button" parent="."]
anchors_preset = 8
anchor_left = 0.4
anchor_right = 0.6
anchor_top = 0.4
anchor_bottom = 0.5

[node name="Quit" type="Button" parent="."]
anchors_preset = 4
anchor_left = 0.4
anchor_right = 0.6
anchor_top = 0.6
anchor_bottom = 0.7
""")
	var result: Dictionary = LayoutVerifier.verify_scene_layout(path, SIZES)
	assert_eq((result.get("violations", []) as Array).size(), 0, str(result.get("violations", [])))
	assert_eq(int(result.get("checked", 0)), 2)

func test_fixed_offset_button_exits_small_viewport() -> void:
	# 左锚固定像素宽按钮：1920x1080 在界内，854x480 越界——正是 E3 要抓的
	var path: String = _write_scene("overflow.tscn", """
[node name="Settings" type="Button" parent="."]
anchor_left = 0.0
anchor_right = 0.0
anchor_top = 0.9
anchor_bottom = 0.9
offset_left = 100.0
offset_right = 900.0
offset_top = -40.0
offset_bottom = 0.0
""")
	var result: Dictionary = LayoutVerifier.verify_scene_layout(path, SIZES)
	var violations: Array = result.get("violations", [])
	assert_gt(violations.size(), 0, "must flag at least the smallest viewport")
	var sizes_flagged: Array = []
	for violation in violations:
		sizes_flagged.append(String((violation as Dictionary).get("size", "")))
	assert_has(sizes_flagged, "854x480", "the small viewport flags the overflow")
	assert_false(sizes_flagged.has("1920x1080"), "the large viewport fits")

func test_sibling_buttons_overlapping_is_flagged() -> void:
	var path: String = _write_scene("overlap.tscn", """
[node name="A" type="Button" parent="."]
anchor_left = 0.4
anchor_right = 0.6
anchor_top = 0.4
anchor_bottom = 0.6

[node name="B" type="Button" parent="."]
anchor_left = 0.5
anchor_right = 0.7
anchor_top = 0.5
anchor_bottom = 0.7
""")
	var result: Dictionary = LayoutVerifier.verify_scene_layout(path, SIZES)
	var violations: Array = result.get("violations", [])
	assert_gt(violations.size(), 0, "overlap must be flagged")
	assert_true(String(JSON.stringify(violations)).contains("overlap"), str(violations))

func test_full_rect_preset_alone_is_understood() -> void:
	var path: String = _write_scene("preset.tscn", """
[node name="Back" type="Panel" parent="."]
anchors_preset = 15

[node name="Centered" type="Button" parent="."]
anchors_preset = 8
anchor_left = 0.45
anchor_right = 0.55
anchor_top = 0.45
anchor_bottom = 0.55
""")
	var result: Dictionary = LayoutVerifier.verify_scene_layout(path, SIZES)
	assert_eq((result.get("violations", []) as Array).size(), 0,
		"full-rect preset alone fills the viewport without violations")
