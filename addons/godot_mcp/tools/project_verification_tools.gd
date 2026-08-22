# project_verification_tools.gd - Project verification-domain tools (split from project_tools_native.gd)
# Visual regression gate / screenshot comparison: compare_render_screenshots, assert_visual_baseline.

@tool
class_name ProjectVerificationTools
extends RefCounted

var _editor_interface: EditorInterface = null
var _server_core: RefCounted = null

func initialize(editor_interface: EditorInterface) -> void:
	_editor_interface = editor_interface

# ============================================================================
# Tool registration
# ============================================================================

func register_tools(server_core: RefCounted) -> void:
	_server_core = server_core
	_register_compare_render_screenshots(server_core)
	_register_assert_visual_baseline(server_core)

# ============================================================================
# compare_render_screenshots - 比较渲染截图
# ============================================================================

func _register_compare_render_screenshots(server_core: RefCounted) -> void:
	var tool_name: String = "compare_render_screenshots"
	var description: String = "Compare two screenshot images and report pixel differences, RMSE, and threshold-based match status."

	var input_schema: Dictionary = {
		"type": "object",
		"properties": {
			"baseline_path": {
				"type": "string",
				"description": "Baseline screenshot image path."
			},
			"candidate_path": {
				"type": "string",
				"description": "Candidate screenshot image path."
			},
			"max_diff_pixels": {
				"type": "integer",
				"description": "Maximum differing pixels allowed for a passing match. Default is 0.",
				"default": 0
			}
		},
		"required": ["baseline_path", "candidate_path"]
	}

	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"baseline_path": {"type": "string"},
			"candidate_path": {"type": "string"},
			"width": {"type": "integer"},
			"height": {"type": "integer"},
			"diff_pixel_count": {"type": "integer"},
			"diff_ratio": {"type": "number"},
			"rmse": {"type": "number"},
			"max_channel_delta": {"type": "number"},
			"matches": {"type": "boolean"}
		}
	}

	var annotations: Dictionary = {
		"readOnlyHint": true,
		"destructiveHint": false,
		"idempotentHint": true,
		"openWorldHint": false
	}

	server_core.register_tool(tool_name, description, input_schema,
						  Callable(self, "_tool_compare_render_screenshots"),
						  output_schema, annotations,
						  "supplementary", "Project-Advanced")

func _tool_compare_render_screenshots(params: Dictionary) -> Dictionary:
	var baseline_path: String = str(params.get("baseline_path", "")).strip_edges()
	var candidate_path: String = str(params.get("candidate_path", "")).strip_edges()
	if baseline_path.is_empty():
		return {"error": "Missing required parameter: baseline_path"}
	if candidate_path.is_empty():
		return {"error": "Missing required parameter: candidate_path"}

	var baseline_validation: Dictionary = PathValidator.validate_file_path(baseline_path, [".png", ".jpg", ".jpeg", ".webp", ".bmp"])
	if not baseline_validation.get("valid", false):
		return {"error": baseline_validation.get("error", "Invalid baseline_path")}
	baseline_path = str(baseline_validation.get("sanitized", baseline_path))

	var candidate_validation: Dictionary = PathValidator.validate_file_path(candidate_path, [".png", ".jpg", ".jpeg", ".webp", ".bmp"])
	if not candidate_validation.get("valid", false):
		return {"error": candidate_validation.get("error", "Invalid candidate_path")}
	candidate_path = str(candidate_validation.get("sanitized", candidate_path))

	var baseline_image: Image = Image.load_from_file(ProjectSettings.globalize_path(baseline_path))
	var candidate_image: Image = Image.load_from_file(ProjectSettings.globalize_path(candidate_path))
	if baseline_image == null or baseline_image.is_empty():
		return {"error": "Failed to load baseline image: " + baseline_path}
	if candidate_image == null or candidate_image.is_empty():
		return {"error": "Failed to load candidate image: " + candidate_path}

	if baseline_image.get_width() != candidate_image.get_width() or baseline_image.get_height() != candidate_image.get_height():
		return {
			"baseline_path": baseline_path,
			"candidate_path": candidate_path,
			"width": baseline_image.get_width(),
			"height": baseline_image.get_height(),
			"candidate_width": candidate_image.get_width(),
			"candidate_height": candidate_image.get_height(),
			"matches": false,
			"error": "Image dimensions do not match"
		}

	var diff: Dictionary = _diff_images(baseline_image, candidate_image, 0.00001)
	var max_diff_pixels: int = max(0, int(params.get("max_diff_pixels", 0)))

	return {
		"baseline_path": baseline_path,
		"candidate_path": candidate_path,
		"width": int(diff["width"]),
		"height": int(diff["height"]),
		"diff_pixel_count": int(diff["diff_pixel_count"]),
		"diff_ratio": float(diff["diff_ratio"]),
		"rmse": float(diff["rmse"]),
		"max_channel_delta": float(diff["max_channel_delta"]),
		"matches": int(diff["diff_pixel_count"]) <= max_diff_pixels
	}


# ============================================================================
# 共享图像差异计算 + 视觉基线门禁辅助
# ============================================================================

func _diff_images(baseline_image: Image, candidate_image: Image, per_pixel_threshold: float) -> Dictionary:
	var width: int = baseline_image.get_width()
	var height: int = baseline_image.get_height()
	var diff_pixel_count: int = 0
	var max_channel_delta: float = 0.0
	var squared_error_sum: float = 0.0

	for y in range(height):
		for x in range(width):
			var baseline_color: Color = baseline_image.get_pixel(x, y)
			var candidate_color: Color = candidate_image.get_pixel(x, y)
			var dr: float = absf(baseline_color.r - candidate_color.r)
			var dg: float = absf(baseline_color.g - candidate_color.g)
			var db: float = absf(baseline_color.b - candidate_color.b)
			var da: float = absf(baseline_color.a - candidate_color.a)
			var pixel_delta: float = maxf(maxf(dr, dg), maxf(db, da))
			if pixel_delta > per_pixel_threshold:
				diff_pixel_count += 1
			max_channel_delta = maxf(max_channel_delta, pixel_delta)
			squared_error_sum += dr * dr + dg * dg + db * db + da * da

	var total_pixels: int = width * height
	var total_channels: int = total_pixels * 4
	var rmse: float = sqrt(squared_error_sum / float(total_channels)) if total_channels > 0 else 0.0
	var diff_ratio: float = float(diff_pixel_count) / float(total_pixels) if total_pixels > 0 else 0.0

	return {
		"width": width,
		"height": height,
		"diff_pixel_count": diff_pixel_count,
		"diff_ratio": diff_ratio,
		"rmse": rmse,
		"max_channel_delta": max_channel_delta
	}

func _save_image_to_path(image: Image, absolute_path: String) -> Dictionary:
	var dir: String = absolute_path.get_base_dir()
	if not dir.is_empty() and not DirAccess.dir_exists_absolute(dir):
		var make_err: int = DirAccess.make_dir_recursive_absolute(dir)
		if make_err != OK:
			return {"error": "Failed to create directory: " + dir}
	var ext: String = absolute_path.get_extension().to_lower()
	var save_err: int = OK
	match ext:
		"jpg", "jpeg":
			save_err = image.save_jpg(absolute_path)
		"webp":
			save_err = image.save_webp(absolute_path)
		_:
			save_err = image.save_png(absolute_path)
	if save_err != OK:
		return {"error": "Failed to save image to: " + absolute_path}
	return {"saved": true}

func _build_diff_image(baseline_image: Image, candidate_image: Image, per_pixel_threshold: float) -> Image:
	var width: int = baseline_image.get_width()
	var height: int = baseline_image.get_height()
	var diff_image: Image = Image.create(width, height, false, Image.FORMAT_RGBA8)
	for y in range(height):
		for x in range(width):
			var b: Color = baseline_image.get_pixel(x, y)
			var c: Color = candidate_image.get_pixel(x, y)
			var delta: float = maxf(maxf(absf(b.r - c.r), absf(b.g - c.g)), maxf(absf(b.b - c.b), absf(b.a - c.a)))
			if delta > per_pixel_threshold:
				diff_image.set_pixel(x, y, Color(1.0, 0.0, 0.0, 1.0))
			else:
				var gray: float = b.get_luminance() * 0.25
				diff_image.set_pixel(x, y, Color(gray, gray, gray, 1.0))
	return diff_image


func _register_assert_visual_baseline(server_core: RefCounted) -> void:
	var tool_name: String = "assert_visual_baseline"
	var description: String = "Visual regression gate: compare a candidate screenshot against a stored baseline (golden) image and return pass/fail against tolerances (max_diff_pixels / max_diff_ratio / rmse_threshold). Missing baseline (or update_baseline=true) saves the candidate as the new baseline and passes. Optionally writes a diff heatmap PNG. Dimension mismatches fail."

	var input_schema: Dictionary = {
		"type": "object",
		"properties": {
			"candidate_path": {"type": "string", "description": "Candidate screenshot path."},
			"baseline_path": {"type": "string", "description": "Baseline (golden) image path."},
			"max_diff_pixels": {"type": "integer", "description": "Max differing pixels for pass.", "default": 0},
			"max_diff_ratio": {"type": "number", "description": "Max fraction (0..1) of differing pixels; 0 disables.", "default": 0.0},
			"rmse_threshold": {"type": "number", "description": "Max RMSE; 0 disables.", "default": 0.0},
			"per_pixel_threshold": {"type": "number", "description": "Per-channel delta marking a pixel different.", "default": 0.00001},
			"update_baseline": {"type": "boolean", "description": "Overwrite baseline and pass.", "default": false},
			"diff_output_path": {"type": "string", "description": "Diff heatmap PNG path (optional)."}
		},
		"required": ["candidate_path", "baseline_path"]
	}

	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"passed": {"type": "boolean"},
			"baseline_created": {"type": "boolean"},
			"baseline_updated": {"type": "boolean"},
			"baseline_path": {"type": "string"},
			"candidate_path": {"type": "string"},
			"width": {"type": "integer"},
			"height": {"type": "integer"},
			"diff_pixel_count": {"type": "integer"},
			"diff_ratio": {"type": "number"},
			"rmse": {"type": "number"},
			"max_channel_delta": {"type": "number"},
			"diff_output_path": {"type": "string"}
		}
	}

	var annotations: Dictionary = {
		"readOnlyHint": false,
		"destructiveHint": false,
		"idempotentHint": false,
		"openWorldHint": false
	}

	server_core.register_tool(tool_name, description, input_schema,
						  Callable(self, "_tool_assert_visual_baseline"),
						  output_schema, annotations,
						  "supplementary", "Project-Advanced")

func _tool_assert_visual_baseline(params: Dictionary) -> Dictionary:
	var candidate_path_raw: String = str(params.get("candidate_path", "")).strip_edges()
	var baseline_path_raw: String = str(params.get("baseline_path", "")).strip_edges()
	if candidate_path_raw.is_empty():
		return {"error": "Missing required parameter: candidate_path"}
	if baseline_path_raw.is_empty():
		return {"error": "Missing required parameter: baseline_path"}

	var exts: Array = [".png", ".jpg", ".jpeg", ".webp", ".bmp"]
	var candidate_validation: Dictionary = PathValidator.validate_file_path(candidate_path_raw, exts)
	if not candidate_validation.get("valid", false):
		return {"error": candidate_validation.get("error", "Invalid candidate_path")}
	var candidate_path: String = str(candidate_validation.get("sanitized", candidate_path_raw))

	var baseline_validation: Dictionary = PathValidator.validate_file_path(baseline_path_raw, exts)
	if not baseline_validation.get("valid", false):
		return {"error": baseline_validation.get("error", "Invalid baseline_path")}
	var baseline_path: String = str(baseline_validation.get("sanitized", baseline_path_raw))

	var candidate_abs: String = ProjectSettings.globalize_path(candidate_path)
	var baseline_abs: String = ProjectSettings.globalize_path(baseline_path)

	var candidate_image: Image = Image.load_from_file(candidate_abs)
	if candidate_image == null or candidate_image.is_empty():
		return {"error": "Failed to load candidate image: " + candidate_path}

	var update_baseline: bool = bool(params.get("update_baseline", false))
	var baseline_exists: bool = FileAccess.file_exists(baseline_abs)

	if update_baseline or not baseline_exists:
		var save_result: Dictionary = _save_image_to_path(candidate_image, baseline_abs)
		if save_result.has("error"):
			return save_result
		return {
			"baseline_path": baseline_path,
			"candidate_path": candidate_path,
			"passed": true,
			"baseline_created": not baseline_exists,
			"baseline_updated": baseline_exists and update_baseline,
			"diff_pixel_count": 0,
			"diff_ratio": 0.0,
			"rmse": 0.0,
			"max_channel_delta": 0.0,
			"width": candidate_image.get_width(),
			"height": candidate_image.get_height()
		}

	var baseline_image: Image = Image.load_from_file(baseline_abs)
	if baseline_image == null or baseline_image.is_empty():
		return {"error": "Failed to load baseline image: " + baseline_path}

	if baseline_image.get_width() != candidate_image.get_width() or baseline_image.get_height() != candidate_image.get_height():
		return {
			"baseline_path": baseline_path,
			"candidate_path": candidate_path,
			"passed": false,
			"baseline_created": false,
			"baseline_updated": false,
			"width": baseline_image.get_width(),
			"height": baseline_image.get_height(),
			"candidate_width": candidate_image.get_width(),
			"candidate_height": candidate_image.get_height(),
			"error": "Image dimensions do not match"
		}

	var per_pixel_threshold: float = maxf(float(params.get("per_pixel_threshold", 0.00001)), 0.0)
	var diff: Dictionary = _diff_images(baseline_image, candidate_image, per_pixel_threshold)

	var max_diff_pixels: int = max(0, int(params.get("max_diff_pixels", 0)))
	var max_diff_ratio: float = float(params.get("max_diff_ratio", 0.0))
	var rmse_threshold: float = float(params.get("rmse_threshold", 0.0))

	var diff_pixel_count: int = int(diff["diff_pixel_count"])
	var diff_ratio: float = float(diff["diff_ratio"])
	var rmse: float = float(diff["rmse"])

	var enforce_pixel_limit: bool = params.has("max_diff_pixels") or (max_diff_ratio <= 0.0 and rmse_threshold <= 0.0)
	var passed: bool = true
	if enforce_pixel_limit:
		passed = passed and diff_pixel_count <= max_diff_pixels
	if max_diff_ratio > 0.0:
		passed = passed and diff_ratio <= max_diff_ratio
	if rmse_threshold > 0.0:
		passed = passed and rmse <= rmse_threshold

	var result: Dictionary = {
		"baseline_path": baseline_path,
		"candidate_path": candidate_path,
		"passed": passed,
		"baseline_created": false,
		"baseline_updated": false,
		"width": int(diff["width"]),
		"height": int(diff["height"]),
		"diff_pixel_count": diff_pixel_count,
		"diff_ratio": diff_ratio,
		"rmse": rmse,
		"max_channel_delta": float(diff["max_channel_delta"]),
		"max_diff_pixels": max_diff_pixels,
		"max_diff_ratio": max_diff_ratio,
		"rmse_threshold": rmse_threshold
	}

	var diff_output_raw: String = str(params.get("diff_output_path", "")).strip_edges()
	if not diff_output_raw.is_empty():
		var diff_validation: Dictionary = PathValidator.validate_file_path(diff_output_raw, [".png"])
		if not diff_validation.get("valid", false):
			result["diff_output_error"] = diff_validation.get("error", "Invalid diff_output_path")
		else:
			var diff_path: String = str(diff_validation.get("sanitized", diff_output_raw))
			var diff_image: Image = _build_diff_image(baseline_image, candidate_image, per_pixel_threshold)
			var save_diff: Dictionary = _save_image_to_path(diff_image, ProjectSettings.globalize_path(diff_path))
			if save_diff.has("error"):
				result["diff_output_error"] = save_diff["error"]
			else:
				result["diff_output_path"] = diff_path

	return result

