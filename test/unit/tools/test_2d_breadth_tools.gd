extends "res://addons/gut/test.gd"

## 2D 完胜三件套单测：动画预设的 Animation 资源正确性（纯引擎可验）、
## 材质参数值宽容转换、参数校验与无编辑器的诚实报错。

const ToolsScript = preload("res://addons/godot_mcp/tools/project_workflow_tools.gd")

const TMP: String = "res://.tmp_2d_breadth"

var _tools: RefCounted

func before_each() -> void:
	DirAccess.make_dir_recursive_absolute(TMP)
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

func _preset_anim(params: Dictionary) -> Animation:
	var result: Dictionary = _tools._tool_apply_animation_preset(params)
	assert_false(result.has("error"), str(result))
	var loaded: Resource = load(String(result.get("save_path", "")))
	assert_not_null(loaded)
	return loaded as Animation

func test_fade_preset_two_keys_modulate() -> void:
	var anim := _preset_anim({"save_path": TMP + "/fade.tres", "preset": "fade",
		"duration": 0.5, "from": 1.0, "to": 0.0})
	assert_eq(anim.get_track_count(), 1)
	assert_eq(String(anim.track_get_path(0)), ".:modulate")
	var a0: Color = anim.track_get_key_value(0, 0)
	var a1: Color = anim.track_get_key_value(0, 1)
	assert_eq(a0.a, 1.0)
	assert_eq(a1.a, 0.0)
	assert_eq(anim.length, 0.5)

func test_slide_and_pulse_round_trip() -> void:
	var slide := _preset_anim({"save_path": TMP + "/slide.tres", "preset": "slide",
		"node_label": "Sprite2D", "magnitude": 24.0})
	assert_eq(String(slide.track_get_path(0)), "Sprite2D:position")
	assert_eq(slide.track_get_key_value(0, 0), Vector2.ZERO)
	assert_eq(slide.track_get_key_value(0, 1), Vector2(24, 0))
	assert_eq(slide.track_get_key_value(0, 2), Vector2.ZERO)
	var pulse := _preset_anim({"save_path": TMP + "/pulse.tres", "preset": "pulse",
		"magnitude": 20.0})
	assert_eq(String(pulse.track_get_path(0)), ".:scale")
	assert_eq(pulse.track_get_key_value(0, 1), Vector2(1.2, 1.2))

func test_shake_preset_decay_discrete() -> void:
	var anim := _preset_anim({"save_path": TMP + "/shake.tres", "preset": "shake",
		"magnitude": 10.0, "oscillations": 3})
	assert_eq(anim.get_track_count(), 1)
	assert_eq(anim.track_get_key_count(0), 7, "3 oscillations = 7 discrete keys")
	var first: Vector2 = anim.track_get_key_value(0, 0)
	var last: Vector2 = anim.track_get_key_value(0, 6)
	assert_eq(first.x, 10.0, "starts at full magnitude")
	assert_lt(abs(last.x), 10.0, "decays toward zero")

func test_preset_overwrite_skip_error_semantics() -> void:
	var first: Dictionary = _tools._tool_apply_animation_preset({
		"save_path": TMP + "/once.tres", "preset": "fade"})
	assert_eq(String(first.get("status", "")), "success")
	var skipped: Dictionary = _tools._tool_apply_animation_preset({
		"save_path": TMP + "/once.tres", "preset": "pulse", "on_exists": "skip"})
	assert_eq(String(skipped.get("status", "")), "exists", "skip leaves the file alone")
	var errored: Dictionary = _tools._tool_apply_animation_preset({
		"save_path": TMP + "/once.tres", "preset": "pulse", "on_exists": "error"})
	assert_true(errored.has("error"))
	var overwrote: Dictionary = _tools._tool_apply_animation_preset({
		"save_path": TMP + "/once.tres", "preset": "pulse"})
	assert_eq(String(overwrote.get("status", "")), "success", "overwrite default")

func test_material_value_coercion() -> void:
	assert_eq(ToolsScript._coerce_material_value([0.5, 2.0]), Vector2(0.5, 2.0))
	var color: Color = ToolsScript._coerce_material_value([1.0, 0.0, 0.0])
	assert_eq(color, Color(1, 0, 0, 1))
	var color4: Color = ToolsScript._coerce_material_value([1.0, 0.0, 0.0, 0.5])
	assert_eq(color4.a, 0.5)
	assert_eq(ToolsScript._coerce_material_value({"x": 3.0, "y": 4.0}), Vector2(3, 4))
	assert_eq(ToolsScript._coerce_material_value(0.75), 0.75)

func test_material_param_requires_editor_scene() -> void:
	var result: Dictionary = _tools._tool_set_material_parameter({
		"node_path": "Player/Visual", "parameter": "flash_amount", "value": 0.5})
	assert_true(result.has("error"), "headless: honest error, no fake success")
	var audio: Dictionary = _tools._tool_create_audio_player({"node_name": "SFX"})
	assert_true(audio.has("error"), "audio player also requires an edited scene")

func test_parameter_validation() -> void:
	var cases: Array = [
		{"preset": "bogus"},
		{"save_path": TMP + "/x.tres"},
	]
	for params in cases:
		params["save_path"] = params.get("save_path", TMP + "/x.tres")
		var result: Dictionary = _tools._tool_apply_animation_preset(params)
		assert_true(result.has("error") or String(result.get("status", "")) == "exists",
			"must reject: %s" % str(params))
	var mat: Dictionary = _tools._tool_set_material_parameter({
		"node_path": "X", "parameter": "not an id", "value": 1})
	assert_true(mat.has("error"))
