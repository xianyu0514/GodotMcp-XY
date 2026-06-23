extends "res://addons/gut/test.gd"

# Unit tests for slice_sprite_sheet plus its pure helpers
# (_compute_sprite_frame_layout / _resolve_sprite_animations) in
# project_tools_native.gd. Uses real images written to a temp dir under user://
# so the whole tool runs headless (no game / editor import required).

var _tools: RefCounted = null
var _tmp_dir: String = "user://.tmp_slice_sprite_test"

func before_each() -> void:
	_tools = load("res://addons/godot_mcp/tools/project_tools_native.gd").new()
	var dir: DirAccess = DirAccess.open("user://")
	if dir and not dir.dir_exists(_tmp_dir):
		dir.make_dir_recursive(_tmp_dir)
	_clear_tmp()

func after_each() -> void:
	_clear_tmp()
	_tools = null

func _clear_tmp() -> void:
	var dir: DirAccess = DirAccess.open(_tmp_dir)
	if not dir:
		return
	dir.list_dir_begin()
	var file_name: String = dir.get_next()
	while file_name != "":
		if not dir.current_is_dir():
			dir.remove(file_name)
		file_name = dir.get_next()
	dir.list_dir_end()

func _save_sheet(width: int, height: int) -> String:
	var image: Image = Image.create(width, height, false, Image.FORMAT_RGBA8)
	image.fill(Color(0.2, 0.4, 0.6, 1.0))
	var path: String = _tmp_dir + "/sheet.png"
	image.save_png(ProjectSettings.globalize_path(path))
	return path

# ---- _compute_sprite_frame_layout ----------------------------------------

func test_layout_h_v_frames():
	var layout: Dictionary = _tools._compute_sprite_frame_layout(64, 32, {"h_frames": 4, "v_frames": 2})
	assert_false(layout.has("error"), "Valid grid should not error")
	assert_eq(int(layout["columns"]), 4, "4 columns")
	assert_eq(int(layout["rows"]), 2, "2 rows")
	assert_eq(int(layout["cell_width"]), 16, "cell width 64/4")
	assert_eq(int(layout["cell_height"]), 16, "cell height 32/2")
	assert_eq(int(layout["frame_count"]), 8, "8 frames total")
	var regions: Array = layout["regions"]
	assert_eq(regions[0], Rect2(0, 0, 16, 16), "first frame top-left")
	assert_eq(regions[4], Rect2(0, 16, 16, 16), "row-major: frame 4 starts second row")

func test_layout_cell_size():
	var layout: Dictionary = _tools._compute_sprite_frame_layout(64, 32, {"cell_width": 16, "cell_height": 16})
	assert_eq(int(layout["columns"]), 4, "64/16 = 4 columns")
	assert_eq(int(layout["rows"]), 2, "32/16 = 2 rows")
	assert_eq(int(layout["frame_count"]), 8, "8 frames")

func test_layout_margin_and_spacing():
	var layout: Dictionary = _tools._compute_sprite_frame_layout(38, 20, {"cell_width": 16, "cell_height": 16, "margin": 2, "spacing": 2})
	assert_eq(int(layout["columns"]), 2, "two 16px cells fit with 2px margin+spacing in 38px")
	assert_eq(int(layout["rows"]), 1, "one row fits in 20px")
	var regions: Array = layout["regions"]
	assert_eq(regions[0], Rect2(2, 2, 16, 16), "first cell offset by margin")
	assert_eq(regions[1], Rect2(20, 2, 16, 16), "second cell offset by margin+cell+spacing")

func test_layout_requires_a_grid():
	var layout: Dictionary = _tools._compute_sprite_frame_layout(64, 32, {})
	assert_true(layout.has("error"), "No grid spec should error")

func test_layout_empty_grid_errors():
	var layout: Dictionary = _tools._compute_sprite_frame_layout(8, 8, {"cell_width": 16, "cell_height": 16})
	assert_true(layout.has("error"), "Cell bigger than sheet yields empty grid error")

# ---- _resolve_sprite_animations ------------------------------------------

func test_resolve_default_animation():
	var resolved: Dictionary = _tools._resolve_sprite_animations(null, 6)
	var anims: Array = resolved["animations"]
	assert_eq(anims.size(), 1, "Single default animation")
	assert_eq(str(anims[0]["name"]), "default", "named default")
	assert_eq((anims[0]["frames"] as Array).size(), 6, "spans all frames")
	assert_true(bool(anims[0]["loop"]), "loops by default")

func test_resolve_explicit_frames_and_range():
	var resolved: Dictionary = _tools._resolve_sprite_animations([
		{"name": "idle", "frames": [0, 1], "fps": 8.0, "loop": true},
		{"name": "run", "start_frame": 2, "end_frame": 5, "fps": 12.0, "loop": false}
	], 6)
	var anims: Array = resolved["animations"]
	assert_eq(anims.size(), 2, "two animations")
	assert_eq((anims[1]["frames"] as Array).size(), 4, "run spans frames 2..5 inclusive")
	assert_eq(float(anims[1]["fps"]), 12.0, "run fps preserved")
	assert_false(bool(anims[1]["loop"]), "run does not loop")

func test_resolve_rejects_out_of_range_frame():
	var resolved: Dictionary = _tools._resolve_sprite_animations([{"name": "x", "frames": [9]}], 4)
	assert_true(resolved.has("error"), "frame index >= frame_count errors")

func test_resolve_rejects_duplicate_name():
	var resolved: Dictionary = _tools._resolve_sprite_animations([
		{"name": "a", "frames": [0]}, {"name": "a", "frames": [1]}
	], 4)
	assert_true(resolved.has("error"), "duplicate animation name errors")

func test_resolve_rejects_missing_frame_spec():
	var resolved: Dictionary = _tools._resolve_sprite_animations([{"name": "a"}], 4)
	assert_true(resolved.has("error"), "animation without frames/start+end errors")

# ---- _tool_slice_sprite_sheet --------------------------------------------

func test_slice_missing_params():
	assert_true(_tools._tool_slice_sprite_sheet({}).has("error"), "missing texture_path errors")
	assert_true(_tools._tool_slice_sprite_sheet({"texture_path": "res://a.png"}).has("error"), "missing output_path errors")

func test_slice_nonexistent_texture():
	var result: Dictionary = _tools._tool_slice_sprite_sheet({
		"texture_path": _tmp_dir + "/missing.png",
		"output_path": _tmp_dir + "/frames.tres",
		"h_frames": 2, "v_frames": 1
	})
	assert_true(result.has("error"), "missing texture file errors")

func test_slice_creates_sprite_frames():
	var sheet: String = _save_sheet(64, 32)
	var out_path: String = _tmp_dir + "/frames.tres"
	var result: Dictionary = _tools._tool_slice_sprite_sheet({
		"texture_path": sheet,
		"output_path": out_path,
		"h_frames": 4, "v_frames": 2,
		"animations": [{"name": "walk", "start_frame": 0, "end_frame": 3, "fps": 10.0, "loop": true}]
	})
	assert_eq(str(result.get("status", "")), "success", "slice succeeds")
	assert_eq(int(result["frame_count"]), 8, "8 frames sliced")
	assert_true(FileAccess.file_exists(ProjectSettings.globalize_path(out_path)), "SpriteFrames file written")
	var sf: SpriteFrames = ResourceLoader.load(out_path)
	assert_true(sf is SpriteFrames, "saved resource loads as SpriteFrames")
	assert_true(sf.has_animation("walk"), "named animation present")
	assert_false(sf.has_animation("default"), "stray default animation removed")
	assert_eq(sf.get_frame_count("walk"), 4, "walk has 4 frames")
	assert_almost_eq(sf.get_animation_speed("walk"), 10.0, 0.001, "fps applied")

func test_slice_create_scene():
	var sheet: String = _save_sheet(32, 32)
	var out_path: String = _tmp_dir + "/frames.tres"
	var scene_path: String = _tmp_dir + "/anim.tscn"
	var result: Dictionary = _tools._tool_slice_sprite_sheet({
		"texture_path": sheet,
		"output_path": out_path,
		"h_frames": 2, "v_frames": 2,
		"create_scene": true,
		"scene_output_path": scene_path
	})
	assert_eq(str(result.get("scene_output_path", "")), scene_path, "scene path returned")
	assert_true(FileAccess.file_exists(ProjectSettings.globalize_path(scene_path)), "scene file written")
	var packed: PackedScene = ResourceLoader.load(scene_path)
	assert_true(packed is PackedScene, "scene loads as PackedScene")
	var node: Node = packed.instantiate()
	assert_true(node is AnimatedSprite2D, "root is AnimatedSprite2D")
	assert_eq(str((node as AnimatedSprite2D).animation), "default", "first animation selected")
	node.free()

func test_slice_create_scene_requires_scene_path():
	var sheet: String = _save_sheet(32, 32)
	var result: Dictionary = _tools._tool_slice_sprite_sheet({
		"texture_path": sheet,
		"output_path": _tmp_dir + "/frames.tres",
		"h_frames": 2, "v_frames": 2,
		"create_scene": true
	})
	assert_true(result.has("scene_error"), "create_scene without scene_output_path reports scene_error")
