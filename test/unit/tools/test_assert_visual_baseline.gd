extends "res://addons/gut/test.gd"

# Unit tests for the assert_visual_baseline regression gate and the shared
# _diff_images helper in project_tools_native.gd. Uses real in-memory images
# written to a temp dir under user:// so it runs headless (no game required).

var _tools: RefCounted = null
var _tmp_dir: String = "user://.tmp_visual_baseline_test"

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

func _make_image(width: int, height: int, color: Color) -> Image:
	var image: Image = Image.create(width, height, false, Image.FORMAT_RGBA8)
	image.fill(color)
	return image

func _save(image: Image, name: String) -> String:
	var path: String = _tmp_dir + "/" + name
	image.save_png(ProjectSettings.globalize_path(path))
	return path

# ---- _diff_images ---------------------------------------------------------

func test_diff_images_identical():
	var a: Image = _make_image(4, 4, Color(0.2, 0.4, 0.6, 1.0))
	var b: Image = _make_image(4, 4, Color(0.2, 0.4, 0.6, 1.0))
	var diff: Dictionary = _tools._diff_images(a, b, 0.00001)
	assert_eq(int(diff["diff_pixel_count"]), 0, "Identical images have no differing pixels")
	assert_almost_eq(float(diff["rmse"]), 0.0, 0.0001, "Identical images have zero RMSE")
	assert_eq(int(diff["width"]), 4)
	assert_eq(int(diff["height"]), 4)

func test_diff_images_counts_changed_pixels():
	var a: Image = _make_image(2, 2, Color(0, 0, 0, 1))
	var b: Image = _make_image(2, 2, Color(0, 0, 0, 1))
	b.set_pixel(0, 0, Color(1, 1, 1, 1))
	var diff: Dictionary = _tools._diff_images(a, b, 0.00001)
	assert_eq(int(diff["diff_pixel_count"]), 1, "One pixel changed")
	assert_almost_eq(float(diff["diff_ratio"]), 0.25, 0.0001, "1 of 4 pixels => 0.25")
	assert_almost_eq(float(diff["max_channel_delta"]), 1.0, 0.0001)

func test_diff_images_per_pixel_threshold_ignores_small_delta():
	var a: Image = _make_image(2, 2, Color(0.5, 0.5, 0.5, 1))
	var b: Image = _make_image(2, 2, Color(0.5, 0.5, 0.5, 1))
	b.set_pixel(0, 0, Color(0.51, 0.5, 0.5, 1))
	var strict: Dictionary = _tools._diff_images(a, b, 0.00001)
	assert_eq(int(strict["diff_pixel_count"]), 1, "Strict threshold counts tiny delta")
	var lenient: Dictionary = _tools._diff_images(a, b, 0.05)
	assert_eq(int(lenient["diff_pixel_count"]), 0, "Lenient threshold ignores tiny delta")

# ---- assert_visual_baseline: baseline bootstrap ---------------------------

func test_creates_baseline_when_missing():
	var candidate_path: String = _save(_make_image(8, 8, Color(0.1, 0.2, 0.3, 1)), "candidate.png")
	var baseline_path: String = _tmp_dir + "/baseline.png"
	var result: Dictionary = _tools._tool_assert_visual_baseline({
		"candidate_path": candidate_path,
		"baseline_path": baseline_path
	})
	assert_true(bool(result["passed"]), "Missing baseline bootstraps and passes")
	assert_true(bool(result["baseline_created"]), "baseline_created should be true")
	assert_false(bool(result["baseline_updated"]), "baseline_updated should be false on first create")
	assert_true(FileAccess.file_exists(ProjectSettings.globalize_path(baseline_path)), "Baseline file written")

func test_update_baseline_overwrites_and_passes():
	var baseline_path: String = _save(_make_image(8, 8, Color(0, 0, 0, 1)), "baseline.png")
	var candidate_path: String = _save(_make_image(8, 8, Color(1, 1, 1, 1)), "candidate.png")
	var result: Dictionary = _tools._tool_assert_visual_baseline({
		"candidate_path": candidate_path,
		"baseline_path": baseline_path,
		"update_baseline": true
	})
	assert_true(bool(result["passed"]), "update_baseline always passes")
	assert_true(bool(result["baseline_updated"]), "baseline_updated should be true")
	assert_false(bool(result["baseline_created"]), "baseline_created should be false when it existed")

# ---- assert_visual_baseline: comparison ----------------------------------

func test_passes_when_within_tolerance():
	var img: Image = _make_image(8, 8, Color(0.3, 0.3, 0.3, 1))
	var baseline_path: String = _save(img, "baseline.png")
	var candidate_path: String = _save(img, "candidate.png")
	var result: Dictionary = _tools._tool_assert_visual_baseline({
		"candidate_path": candidate_path,
		"baseline_path": baseline_path
	})
	assert_true(bool(result["passed"]), "Identical images pass")
	assert_eq(int(result["diff_pixel_count"]), 0)

func test_fails_when_pixels_exceed_max_diff_pixels():
	var baseline: Image = _make_image(4, 4, Color(0, 0, 0, 1))
	var candidate: Image = _make_image(4, 4, Color(0, 0, 0, 1))
	candidate.set_pixel(0, 0, Color(1, 1, 1, 1))
	candidate.set_pixel(1, 1, Color(1, 1, 1, 1))
	var baseline_path: String = _save(baseline, "baseline.png")
	var candidate_path: String = _save(candidate, "candidate.png")
	var result: Dictionary = _tools._tool_assert_visual_baseline({
		"candidate_path": candidate_path,
		"baseline_path": baseline_path,
		"max_diff_pixels": 1
	})
	assert_false(bool(result["passed"]), "2 diff pixels > max_diff_pixels=1 fails")
	assert_eq(int(result["diff_pixel_count"]), 2)

func test_passes_within_max_diff_ratio():
	var baseline: Image = _make_image(10, 10, Color(0, 0, 0, 1))
	var candidate: Image = _make_image(10, 10, Color(0, 0, 0, 1))
	candidate.set_pixel(0, 0, Color(1, 1, 1, 1))
	var baseline_path: String = _save(baseline, "baseline.png")
	var candidate_path: String = _save(candidate, "candidate.png")
	var result: Dictionary = _tools._tool_assert_visual_baseline({
		"candidate_path": candidate_path,
		"baseline_path": baseline_path,
		"max_diff_ratio": 0.05
	})
	assert_true(bool(result["passed"]), "1/100 = 0.01 <= max_diff_ratio 0.05 passes")

func test_fails_on_dimension_mismatch():
	var baseline_path: String = _save(_make_image(4, 4, Color(0, 0, 0, 1)), "baseline.png")
	var candidate_path: String = _save(_make_image(8, 8, Color(0, 0, 0, 1)), "candidate.png")
	var result: Dictionary = _tools._tool_assert_visual_baseline({
		"candidate_path": candidate_path,
		"baseline_path": baseline_path
	})
	assert_false(bool(result["passed"]), "Dimension mismatch fails the gate")
	assert_true(result.has("error"), "Reports dimension error")

func test_writes_diff_image():
	var baseline: Image = _make_image(4, 4, Color(0, 0, 0, 1))
	var candidate: Image = _make_image(4, 4, Color(0, 0, 0, 1))
	candidate.set_pixel(0, 0, Color(1, 1, 1, 1))
	var baseline_path: String = _save(baseline, "baseline.png")
	var candidate_path: String = _save(candidate, "candidate.png")
	var diff_path: String = _tmp_dir + "/diff.png"
	var result: Dictionary = _tools._tool_assert_visual_baseline({
		"candidate_path": candidate_path,
		"baseline_path": baseline_path,
		"diff_output_path": diff_path
	})
	assert_eq(str(result.get("diff_output_path", "")), diff_path, "diff_output_path returned")
	assert_true(FileAccess.file_exists(ProjectSettings.globalize_path(diff_path)), "Diff heatmap written")

# ---- assert_visual_baseline: validation ----------------------------------

func test_missing_candidate_path_errors():
	var result: Dictionary = _tools._tool_assert_visual_baseline({"baseline_path": _tmp_dir + "/baseline.png"})
	assert_true(result.has("error"), "Missing candidate_path errors")

func test_missing_baseline_path_errors():
	var result: Dictionary = _tools._tool_assert_visual_baseline({"candidate_path": _tmp_dir + "/candidate.png"})
	assert_true(result.has("error"), "Missing baseline_path errors")
