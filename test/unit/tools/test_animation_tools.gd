extends "res://addons/gut/test.gd"

# Unit tests for the Batch 5 animation tools in project_workflow_tools.gd:
# create_animation, insert_animation_keys.

const TOOL_SCRIPT: String = "res://addons/godot_mcp/tools/project_workflow_tools.gd"
const TMP_DIR: String = "res://.test_tmp_anim"

var _tools: RefCounted = null

func before_each():
	_tools = load(TOOL_SCRIPT).new()
	_cleanup_tmp_dir()

func after_each():
	_cleanup_tmp_dir()
	_tools = null

func _cleanup_tmp_dir():
	if not DirAccess.dir_exists_absolute(TMP_DIR):
		return
	var dir: DirAccess = DirAccess.open(TMP_DIR)
	if dir == null:
		return
	dir.list_dir_begin()
	var entry: String = dir.get_next()
	while entry != "":
		if not dir.current_is_dir():
			dir.remove(entry)
		entry = dir.get_next()
	dir.list_dir_end()
	DirAccess.remove_absolute(TMP_DIR)

func _tmp_path(file_name: String) -> String:
	return TMP_DIR.path_join(file_name)

# --- create_animation -------------------------------------------------------

func test_create_animation_missing_path():
	var result: Dictionary = _tools._tool_create_animation({})
	assert_has(result, "error", "Missing animation_path should return an error")

func test_create_animation_rejects_bad_extension():
	var result: Dictionary = _tools._tool_create_animation({"animation_path": _tmp_path("nope.txt")})
	assert_has(result, "error", "Non-animation extension should return an error")

func test_create_animation_invalid_loop_mode():
	var result: Dictionary = _tools._tool_create_animation({
		"animation_path": _tmp_path("bad_loop.tres"),
		"loop_mode": "bogus"
	})
	assert_has(result, "error", "Invalid loop_mode should return an error")

func test_create_animation_creates_file():
	var path: String = _tmp_path("card_draw.tres")
	var result: Dictionary = _tools._tool_create_animation({
		"animation_path": path,
		"length": 0.75,
		"loop_mode": "pingpong",
		"step": 0.05
	})
	assert_eq(result.get("status"), "success", "Should create the animation")
	assert_eq(result.get("loop_mode"), "pingpong", "loop_mode name should round-trip in result")
	assert_true(ResourceLoader.exists(path), "Animation file should exist on disk")
	var loaded: Animation = ResourceLoader.load(path) as Animation
	assert_ne(loaded, null, "Saved file should load as an Animation")
	assert_almost_eq(loaded.length, 0.75, 0.001, "length should round-trip")
	assert_eq(loaded.loop_mode, Animation.LOOP_PINGPONG, "loop_mode should round-trip")
	assert_almost_eq(loaded.step, 0.05, 0.001, "step should round-trip")

# --- insert_animation_keys --------------------------------------------------

func test_insert_keys_missing_params():
	var result: Dictionary = _tools._tool_insert_animation_keys({"animation_path": _tmp_path("x.tres")})
	assert_has(result, "error", "Missing track_path/keys should return an error")

func test_insert_keys_empty_keys_array():
	var path: String = _tmp_path("empty.tres")
	_tools._tool_create_animation({"animation_path": path})
	var result: Dictionary = _tools._tool_insert_animation_keys({
		"animation_path": path,
		"track_path": ".:modulate",
		"keys": []
	})
	assert_has(result, "error", "Empty keys array should return an error")

func test_insert_keys_missing_animation_file():
	var result: Dictionary = _tools._tool_insert_animation_keys({
		"animation_path": _tmp_path("ghost.tres"),
		"track_path": ".:modulate",
		"keys": [{"time": 0.0, "value": "#ffffff"}]
	})
	assert_has(result, "error", "Nonexistent animation should return an error")

func test_insert_keys_invalid_track_type():
	var path: String = _tmp_path("badtype.tres")
	_tools._tool_create_animation({"animation_path": path})
	var result: Dictionary = _tools._tool_insert_animation_keys({
		"animation_path": path,
		"track_path": ".:modulate",
		"track_type": "bezier",
		"keys": [{"time": 0.0, "value": 1.0}]
	})
	assert_has(result, "error", "Unsupported track_type should return an error")

func test_insert_keys_key_missing_time():
	var path: String = _tmp_path("notime.tres")
	_tools._tool_create_animation({"animation_path": path})
	var result: Dictionary = _tools._tool_insert_animation_keys({
		"animation_path": path,
		"track_path": ".:modulate",
		"keys": [{"value": 1.0}]
	})
	assert_has(result, "error", "Key without 'time' should return an error")

func test_insert_value_keys_creates_track():
	var path: String = _tmp_path("modulate.tres")
	_tools._tool_create_animation({"animation_path": path})
	var result: Dictionary = _tools._tool_insert_animation_keys({
		"animation_path": path,
		"track_path": ".:modulate",
		"track_type": "value",
		"value_type": "color",
		"keys": [
			{"time": 0.0, "value": "#ffffff"},
			{"time": 0.5, "value": {"r": 1.0, "g": 0.0, "b": 0.0, "a": 1.0}},
			{"time": 1.5, "value": "#000000"}
		]
	})
	assert_eq(result.get("status"), "success", "Should insert value keys")
	assert_true(result.get("created_track"), "First insert should create the track")
	assert_eq(result.get("keys_inserted"), 3, "Should insert three keys")
	var loaded: Animation = ResourceLoader.load(path) as Animation
	assert_eq(loaded.get_track_count(), 1, "Animation should have one track")
	var track: int = result.get("track_index")
	assert_eq(loaded.track_get_type(track), Animation.TYPE_VALUE, "Track should be a value track")
	assert_eq(loaded.track_get_key_count(track), 3, "Track should have three keys")
	assert_eq(loaded.track_get_key_value(track, 1), Color(1, 0, 0, 1), "Second key color should round-trip")
	assert_almost_eq(loaded.length, 1.5, 0.001, "Length should grow to fit the last key beyond default 1.0")

func test_insert_keys_reuses_existing_track():
	var path: String = _tmp_path("reuse.tres")
	_tools._tool_create_animation({"animation_path": path})
	var first: Dictionary = _tools._tool_insert_animation_keys({
		"animation_path": path,
		"track_path": "Sprite2D:position",
		"value_type": "vector2",
		"keys": [{"time": 0.0, "value": [0, 0]}]
	})
	var second: Dictionary = _tools._tool_insert_animation_keys({
		"animation_path": path,
		"track_path": "Sprite2D:position",
		"value_type": "vector2",
		"reuse_track": true,
		"keys": [{"time": 0.25, "value": [100, 50]}]
	})
	assert_eq(second.get("status"), "success", "Second insert should succeed")
	assert_false(second.get("created_track"), "Second insert should reuse the track")
	assert_eq(first.get("track_index"), second.get("track_index"), "Track index should be stable on reuse")
	var loaded: Animation = ResourceLoader.load(path) as Animation
	assert_eq(loaded.get_track_count(), 1, "Reuse should not add a second track")
	assert_eq(loaded.track_get_key_count(0), 2, "Both keys should be on the same track")

func test_insert_position_3d_keys():
	var path: String = _tmp_path("pos3d.tres")
	_tools._tool_create_animation({"animation_path": path})
	var result: Dictionary = _tools._tool_insert_animation_keys({
		"animation_path": path,
		"track_path": "Pivot",
		"track_type": "position_3d",
		"keys": [{"time": 0.0, "value": [0, 0, 0]}, {"time": 1.0, "value": [0, 2, 0]}]
	})
	assert_eq(result.get("status"), "success", "Should insert position_3d keys")
	var loaded: Animation = ResourceLoader.load(path) as Animation
	assert_eq(loaded.track_get_type(0), Animation.TYPE_POSITION_3D, "Track should be a position_3d track")
	assert_eq(loaded.track_get_key_count(0), 2, "Track should have two keys")

func test_insert_position_3d_rejects_non_vector():
	var path: String = _tmp_path("pos3d_bad.tres")
	_tools._tool_create_animation({"animation_path": path})
	var result: Dictionary = _tools._tool_insert_animation_keys({
		"animation_path": path,
		"track_path": "Pivot",
		"track_type": "position_3d",
		"keys": [{"time": 0.0, "value": 5}]
	})
	assert_has(result, "error", "Scalar value for a position_3d track should return an error")
