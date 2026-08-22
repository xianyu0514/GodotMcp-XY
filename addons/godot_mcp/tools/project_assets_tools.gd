# project_assets_tools.gd - Project asset-generation-domain tools (split from project_tools_native.gd)
# generate_asset / generate_3d_asset / placeholder asset gen / sprite-sheet slicing /
# glTF validation / gradient & drawable textures / PCK packing / render output.

@tool
class_name ProjectAssetsTools
extends RefCounted

var _editor_interface: EditorInterface = null
var _server_core: RefCounted = null
# Dedicated async job manager for text-to-3D generation (WorkerThreadPool based).
var _gen_job_manager: AsyncJobManager = AsyncJobManager.new()

func initialize(editor_interface: EditorInterface) -> void:
	_editor_interface = editor_interface

func _get_editor_interface() -> EditorInterface:
	if _editor_interface:
		return _editor_interface
	if Engine.has_meta("GodotMCPPlugin"):
		var plugin = Engine.get_meta("GodotMCPPlugin")
		if plugin and plugin.has_method("get_editor_interface"):
			return plugin.get_editor_interface()
	return null

## True when the client cancelled the currently executing tool call. Long-running
## tools poll this inside their loops and abort early when it flips.
func _tool_cancelled() -> bool:
	return _server_core != null and _server_core.has_method("is_current_tool_cancelled") and bool(_server_core.is_current_tool_cancelled())

## Best-effort progress notification; silently skipped when the client supplied
## no progress token or no transport is connected.
func _send_tool_progress(progress_token: Variant, progress: int, total: int = 0, message: String = "") -> void:
	if _server_core != null and _server_core.has_method("send_progress_notification"):
		_server_core.send_progress_notification(progress_token, progress, total, message)

# ============================================================================
# Tool registration
# ============================================================================

func register_tools(server_core: RefCounted) -> void:
	_server_core = server_core
	_register_create_gradient_texture(server_core)
	_register_pack_pck(server_core)
	_register_configure_render_output(server_core)
	_register_create_drawable_texture(server_core)
	_register_draw_on_texture(server_core)
	_register_generate_asset(server_core)
	_register_slice_sprite_sheet(server_core)
	_register_inspect_gltf_asset(server_core)
	_register_generate_3d_asset(server_core)

# ============================================================================
# create_gradient_texture - build a GradientTexture2D (incl. Godot 4.7 conic)
# ============================================================================

const _GRADIENT_FILL_MODES: Dictionary = {
	"linear": 0,
	"radial": 1,
	"square": 2,
	"conic": 3
}


func _gradient_fill_supported(mode_value: int) -> bool:
	if mode_value != 3:
		return true
	return "FILL_CONIC" in ClassDB.class_get_integer_constant_list("GradientTexture2D", false)

func _register_create_gradient_texture(server_core: RefCounted) -> void:
	var tool_name: String = "create_gradient_texture"
	var description: String = "Create and save a GradientTexture2D (.tres) with a configurable color gradient and fill mode (linear, radial, square, or conic). The conic fill mode requires Godot 4.7; requesting it on older versions returns status 'unsupported'."

	var input_schema: Dictionary = {
		"type": "object",
		"properties": {
			"resource_path": {"type": "string", "description": "Path to save the texture (e.g. 'res://textures/grad.tres')."},
			"fill": {"type": "string", "description": "Fill mode: linear, radial, square, or conic. Default linear.", "enum": ["linear", "radial", "square", "conic"], "default": "linear"},
			"colors": {"type": "array", "description": "Gradient stops. Each item is a color string/array, or {offset, color}. Defaults to black->white when omitted."},
			"fill_from": {"type": "object", "description": "Fill-from point as {x, y} in 0..1 ratio. Default {x:0, y:0}."},
			"fill_to": {"type": "object", "description": "Fill-to point as {x, y} in 0..1 ratio. Default {x:1, y:0}."},
			"width": {"type": "integer", "description": "Texture width in pixels. Default 64.", "default": 64},
			"height": {"type": "integer", "description": "Texture height in pixels. Default 64.", "default": 64}
		},
		"required": ["resource_path"]
	}

	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"status": {"type": "string"},
			"resource_path": {"type": "string"},
			"fill": {"type": "string"},
			"fill_mode_value": {"type": "integer"},
			"stop_count": {"type": "integer"},
			"godot_version": {"type": "string"}
		}
	}

	var annotations: Dictionary = {
		"readOnlyHint": false,
		"destructiveHint": false,
		"idempotentHint": false,
		"openWorldHint": false
	}

	server_core.register_tool(tool_name, description, input_schema,
						  Callable(self, "_tool_create_gradient_texture"),
						  output_schema, annotations,
						  "supplementary", "Project-Advanced")

func _tool_create_gradient_texture(params: Dictionary) -> Dictionary:
	var resource_path: String = str(params.get("resource_path", "")).strip_edges()
	if resource_path.is_empty():
		return {"error": "Missing required parameter: resource_path"}

	var validation: Dictionary = PathValidator.validate_file_path(resource_path, [".tres", ".res"])
	if not validation["valid"]:
		return {"error": "Invalid path: " + validation["error"]}
	resource_path = validation["sanitized"]

	var fill_name: String = str(params.get("fill", "linear")).strip_edges().to_lower()
	if not _GRADIENT_FILL_MODES.has(fill_name):
		return {"error": "Invalid fill mode '%s'. Expected one of: linear, radial, square, conic." % fill_name}
	var fill_mode: int = int(_GRADIENT_FILL_MODES[fill_name])

	if not _gradient_fill_supported(fill_mode):
		return {
			"status": "unsupported",
			"message": "Conic fill mode (GradientTexture2D.FILL_CONIC) requires Godot 4.7 or newer",
			"godot_version": str(Engine.get_version_info().get("string", ""))
		}

	var offsets: PackedFloat32Array = PackedFloat32Array()
	var colors: PackedColorArray = PackedColorArray()
	var color_stops: Array = params.get("colors", [])
	if color_stops is Array and color_stops.size() > 0:
		var auto_index: int = 0
		var auto_total: int = max(color_stops.size() - 1, 1)
		for stop in color_stops:
			if stop is Dictionary and stop.has("color"):
				offsets.append(clampf(float(stop.get("offset", float(auto_index) / float(auto_total))), 0.0, 1.0))
				colors.append(ProjectToolsNative._parse_color(stop.get("color")))
			else:
				offsets.append(clampf(float(auto_index) / float(auto_total), 0.0, 1.0))
				colors.append(ProjectToolsNative._parse_color(stop))
			auto_index += 1
	else:
		offsets = PackedFloat32Array([0.0, 1.0])
		colors = PackedColorArray([Color.BLACK, Color.WHITE])

	var gradient: Gradient = Gradient.new()
	gradient.offsets = offsets
	gradient.colors = colors

	var texture: GradientTexture2D = GradientTexture2D.new()
	texture.gradient = gradient
	texture.fill = fill_mode
	texture.width = max(1, int(params.get("width", 64)))
	texture.height = max(1, int(params.get("height", 64)))
	if params.has("fill_from"):
		texture.fill_from = _to_vector2(params["fill_from"])
	if params.has("fill_to"):
		texture.fill_to = _to_vector2(params["fill_to"])

	var error: Error = ResourceSaver.save(texture, resource_path)
	if error != OK:
		return {"error": "Failed to save texture: " + error_string(error)}

	return {
		"status": "success",
		"resource_path": resource_path,
		"fill": fill_name,
		"fill_mode_value": fill_mode,
		"stop_count": colors.size(),
		"godot_version": str(Engine.get_version_info().get("string", ""))
	}

static func _to_vector2(value: Variant) -> Vector2:
	if value is Vector2:
		return value
	if value is Dictionary:
		return Vector2(float(value.get("x", 0.0)), float(value.get("y", 0.0)))
	if value is Array and value.size() >= 2:
		return Vector2(float(value[0]), float(value[1]))
	return Vector2.ZERO


# ============================================================================
# pack_pck - bundle project files into a .pck archive via PCKPacker
# ============================================================================

func _register_pack_pck(server_core: RefCounted) -> void:
	var tool_name: String = "pack_pck"
	var description: String = "Bundle a set of files into a Godot .pck archive using PCKPacker. Each entry maps a virtual target_path (res://...) to an existing source_path on disk. Useful for building DLC/mod packs that can be loaded with ProjectSettings.load_resource_pack."

	var input_schema: Dictionary = {
		"type": "object",
		"properties": {
			"pck_path": {"type": "string", "description": "Output archive path (e.g. 'res://packs/dlc.pck' or 'user://dlc.pck')."},
			"files": {"type": "array", "description": "Files to pack. Each item is either a source path string (packed at the same res:// path) or {target_path, source_path}."},
			"alignment": {"type": "integer", "description": "Byte alignment for packed files. Default 32.", "default": 32}
		},
		"required": ["pck_path", "files"]
	}

	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"status": {"type": "string"},
			"pck_path": {"type": "string"},
			"packed_count": {"type": "integer"},
			"size_bytes": {"type": "integer"},
			"skipped": {"type": "array"}
		}
	}

	var annotations: Dictionary = {
		"readOnlyHint": false,
		"destructiveHint": false,
		"idempotentHint": false,
		"openWorldHint": false
	}

	server_core.register_tool(tool_name, description, input_schema,
						  Callable(self, "_tool_pack_pck"),
						  output_schema, annotations,
						  "supplementary", "Project-Advanced")

func _tool_pack_pck(params: Dictionary) -> Dictionary:
	var pck_path: String = str(params.get("pck_path", "")).strip_edges()
	if pck_path.is_empty():
		return {"error": "Missing required parameter: pck_path"}

	var validation: Dictionary = PathValidator.validate_file_path(pck_path, [".pck", ".zip"])
	if not validation["valid"]:
		return {"error": "Invalid path: " + validation["error"]}
	pck_path = validation["sanitized"]

	var files: Array = params.get("files", [])
	if not (files is Array) or files.is_empty():
		return {"error": "Parameter 'files' must be a non-empty array"}

	var packer: PCKPacker = PCKPacker.new()
	var alignment: int = max(1, int(params.get("alignment", 32)))
	if packer.pck_start(pck_path, alignment) != OK:
		return {"error": "Failed to start PCK at: " + pck_path}

	var packed_count: int = 0
	var skipped: Array = []
	for entry in files:
		var target_path: String = ""
		var source_path: String = ""
		if entry is String:
			target_path = entry
			source_path = entry
		elif entry is Dictionary:
			source_path = str(entry.get("source_path", ""))
			target_path = str(entry.get("target_path", source_path))
		if source_path.is_empty():
			skipped.append({"entry": entry, "reason": "missing source_path"})
			continue
		if not FileAccess.file_exists(source_path):
			skipped.append({"target_path": target_path, "source_path": source_path, "reason": "source not found"})
			continue
		if packer.add_file(target_path, source_path) != OK:
			skipped.append({"target_path": target_path, "source_path": source_path, "reason": "add_file failed"})
			continue
		packed_count += 1

	if packed_count == 0:
		return {"error": "No files were packed", "skipped": skipped}

	if packer.flush() != OK:
		return {"error": "Failed to flush PCK archive"}

	var size_bytes: int = 0
	if FileAccess.file_exists(pck_path):
		var f: FileAccess = FileAccess.open(pck_path, FileAccess.READ)
		if f:
			size_bytes = f.get_length()
			f.close()

	return {
		"status": "success",
		"pck_path": pck_path,
		"packed_count": packed_count,
		"size_bytes": size_bytes,
		"skipped": skipped
	}


# ============================================================================
# configure_render_output - HDR 2D output and related render project settings
# ============================================================================

func _register_configure_render_output(server_core: RefCounted) -> void:
	var tool_name: String = "configure_render_output"
	var description: String = "Configure project-level render output settings, including the Godot 4.7 HDR 2D output (rendering/viewport/hdr_2d) and transparent background. Only provided settings are changed; each is guarded with ProjectSettings.has_setting so unavailable keys are reported as unsupported instead of being created."

	var input_schema: Dictionary = {
		"type": "object",
		"properties": {
			"hdr_2d": {"type": "boolean", "description": "Enable HDR 2D output (Godot 4.7 'rendering/viewport/hdr_2d')."},
			"transparent_background": {"type": "boolean", "description": "Set 'rendering/viewport/transparent_background'."},
			"persist": {"type": "boolean", "description": "Persist changes to project.godot via ProjectSettings.save(). Default true.", "default": true}
		}
	}

	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"status": {"type": "string"},
			"persisted": {"type": "boolean"},
			"changes": {"type": "array"},
			"godot_version": {"type": "string"}
		}
	}

	var annotations: Dictionary = {
		"readOnlyHint": false,
		"destructiveHint": false,
		"idempotentHint": true,
		"openWorldHint": false
	}

	server_core.register_tool(tool_name, description, input_schema,
						  Callable(self, "_tool_configure_render_output"),
						  output_schema, annotations,
						  "supplementary", "Project-Advanced")

func _tool_configure_render_output(params: Dictionary) -> Dictionary:
	var setting_keys: Dictionary = {
		"hdr_2d": "rendering/viewport/hdr_2d",
		"transparent_background": "rendering/viewport/transparent_background"
	}

	var changes: Array = []
	var any_persistable: bool = false
	for param_name in setting_keys:
		if not params.has(param_name):
			continue
		var setting_key: String = setting_keys[param_name]
		var new_value: bool = bool(params[param_name])
		if not ProjectSettings.has_setting(setting_key):
			changes.append({"setting": setting_key, "status": "unsupported", "requested": new_value})
			continue
		var previous: Variant = ProjectSettings.get_setting(setting_key)
		ProjectSettings.set_setting(setting_key, new_value)
		any_persistable = true
		changes.append({"setting": setting_key, "status": "updated", "previous": previous, "new": new_value})

	if changes.is_empty():
		return {"error": "No render output settings provided. Supported: hdr_2d, transparent_background."}

	var persisted: bool = false
	var persist: bool = bool(params.get("persist", true))
	if persist and any_persistable:
		if ProjectSettings.save() == OK:
			persisted = true

	return {
		"status": "success",
		"persisted": persisted,
		"changes": changes,
		"godot_version": str(Engine.get_version_info().get("string", ""))
	}


# ============================================================================
# create_drawable_texture / draw_on_texture - Godot 4.7 DrawableTexture2D
# ============================================================================

const _DRAWABLE_FORMATS: Dictionary = {
	"rgba8": 0,
	"rgba8_srgb": 1,
	"rgbah": 2,
	"rgbaf": 3
}

func _drawable_texture_supported() -> bool:
	return ClassDB.class_exists("DrawableTexture2D")

static func _to_rect2i(value: Variant, source: Object = null) -> Rect2i:
	if value is Dictionary and (value.has("w") or value.has("width") or value.has("h") or value.has("height")):
		var x: int = int(value.get("x", 0))
		var y: int = int(value.get("y", 0))
		var w: int = int(value.get("w", value.get("width", 0)))
		var h: int = int(value.get("h", value.get("height", 0)))
		return Rect2i(x, y, w, h)
	if source != null and source.has_method("get_width"):
		return Rect2i(0, 0, int(source.get_width()), int(source.get_height()))
	return Rect2i()

func _register_create_drawable_texture(server_core: RefCounted) -> void:
	var tool_name: String = "create_drawable_texture"
	var description: String = "Create and save a Godot 4.7 DrawableTexture2D (.tres), a GPU-backed texture you can draw onto at runtime. Initializes it via setup(width, height, format, fill_color, use_mipmaps). DrawableTexture2D requires Godot 4.7; returns status 'unsupported' on older versions."

	var input_schema: Dictionary = {
		"type": "object",
		"properties": {
			"resource_path": {"type": "string", "description": "Path to save the texture (e.g. 'res://textures/canvas.tres')."},
			"width": {"type": "integer", "description": "Texture width in pixels. Default 64.", "default": 64},
			"height": {"type": "integer", "description": "Texture height in pixels. Default 64.", "default": 64},
			"format": {"type": "string", "description": "Pixel format.", "enum": ["rgba8", "rgba8_srgb", "rgbah", "rgbaf"], "default": "rgba8"},
			"color": {"type": "object", "description": "Initial fill color as {r, g, b, a}. Default opaque black."},
			"use_mipmaps": {"type": "boolean", "description": "Whether to allocate mipmaps. Default false.", "default": false}
		},
		"required": ["resource_path"]
	}

	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"status": {"type": "string"},
			"resource_path": {"type": "string"},
			"width": {"type": "integer"},
			"height": {"type": "integer"},
			"format": {"type": "string"},
			"format_value": {"type": "integer"},
			"use_mipmaps": {"type": "boolean"},
			"godot_version": {"type": "string"}
		}
	}

	var annotations: Dictionary = {
		"readOnlyHint": false,
		"destructiveHint": false,
		"idempotentHint": false,
		"openWorldHint": false
	}

	server_core.register_tool(tool_name, description, input_schema,
						  Callable(self, "_tool_create_drawable_texture"),
						  output_schema, annotations,
						  "supplementary", "Project-Advanced")

func _tool_create_drawable_texture(params: Dictionary) -> Dictionary:
	var resource_path: String = str(params.get("resource_path", "")).strip_edges()
	if resource_path.is_empty():
		return {"error": "Missing required parameter: resource_path"}

	var validation: Dictionary = PathValidator.validate_file_path(resource_path, [".tres", ".res"])
	if not validation["valid"]:
		return {"error": "Invalid path: " + validation["error"]}
	resource_path = validation["sanitized"]

	if not _drawable_texture_supported():
		return {
			"status": "unsupported",
			"message": "DrawableTexture2D requires Godot 4.7 or newer",
			"godot_version": str(Engine.get_version_info().get("string", ""))
		}

	var format_name: String = str(params.get("format", "rgba8")).strip_edges().to_lower()
	if not _DRAWABLE_FORMATS.has(format_name):
		return {"error": "Invalid format '%s'. Expected one of: rgba8, rgba8_srgb, rgbah, rgbaf." % format_name}
	var format_value: int = int(_DRAWABLE_FORMATS[format_name])

	var width: int = max(1, int(params.get("width", 64)))
	var height: int = max(1, int(params.get("height", 64)))
	var use_mipmaps: bool = bool(params.get("use_mipmaps", false))
	var fill_color: Color = Color(0.0, 0.0, 0.0, 1.0)
	if params.has("color"):
		fill_color = ProjectToolsNative._parse_color(params["color"])

	var texture = ClassDB.instantiate("DrawableTexture2D")
	if texture == null:
		return {"error": "Failed to instantiate DrawableTexture2D"}
	texture.setup(width, height, format_value, fill_color, use_mipmaps)

	var error: Error = ResourceSaver.save(texture, resource_path)
	if error != OK:
		return {"error": "Failed to save texture: " + error_string(error)}

	return {
		"status": "success",
		"resource_path": resource_path,
		"width": width,
		"height": height,
		"format": format_name,
		"format_value": format_value,
		"use_mipmaps": use_mipmaps,
		"godot_version": str(Engine.get_version_info().get("string", ""))
	}

func _register_draw_on_texture(server_core: RefCounted) -> void:
	var tool_name: String = "draw_on_texture"
	var description: String = "Draw onto an existing Godot 4.7 DrawableTexture2D resource by blitting source textures onto target rectangles (DrawableTexture2D.blit_rect). Each operation maps a source Texture2D onto a target rect with an optional modulate color. DrawableTexture2D requires Godot 4.7; returns status 'unsupported' on older versions."

	var input_schema: Dictionary = {
		"type": "object",
		"properties": {
			"resource_path": {"type": "string", "description": "Path to an existing DrawableTexture2D (.tres/.res)."},
			"operations": {"type": "array", "description": "Blit operations. Each item is {source_path, rect:{x,y,w,h}, modulate:{r,g,b,a}, mipmap}. When rect is omitted the source is blitted at origin using its own size."},
			"generate_mipmaps": {"type": "boolean", "description": "Call generate_mipmaps() after drawing. Default false.", "default": false}
		},
		"required": ["resource_path", "operations"]
	}

	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"status": {"type": "string"},
			"resource_path": {"type": "string"},
			"applied_count": {"type": "integer"},
			"skipped": {"type": "array"},
			"godot_version": {"type": "string"}
		}
	}

	var annotations: Dictionary = {
		"readOnlyHint": false,
		"destructiveHint": false,
		"idempotentHint": false,
		"openWorldHint": false
	}

	server_core.register_tool(tool_name, description, input_schema,
						  Callable(self, "_tool_draw_on_texture"),
						  output_schema, annotations,
						  "supplementary", "Project-Advanced")

func _tool_draw_on_texture(params: Dictionary) -> Dictionary:
	var resource_path: String = str(params.get("resource_path", "")).strip_edges()
	if resource_path.is_empty():
		return {"error": "Missing required parameter: resource_path"}

	var validation: Dictionary = PathValidator.validate_file_path(resource_path, [".tres", ".res"])
	if not validation["valid"]:
		return {"error": "Invalid path: " + validation["error"]}
	resource_path = validation["sanitized"]

	if not _drawable_texture_supported():
		return {
			"status": "unsupported",
			"message": "DrawableTexture2D requires Godot 4.7 or newer",
			"godot_version": str(Engine.get_version_info().get("string", ""))
		}

	if not ResourceLoader.exists(resource_path):
		return {"error": "Resource not found: " + resource_path}
	var texture = ResourceLoader.load(resource_path, "", ResourceLoader.CACHE_MODE_IGNORE)
	if texture == null or texture.get_class() != "DrawableTexture2D":
		return {"error": "Resource is not a DrawableTexture2D: " + resource_path}

	var operations: Array = params.get("operations", [])
	if not (operations is Array) or operations.is_empty():
		return {"error": "Parameter 'operations' must be a non-empty array"}

	var applied: int = 0
	var skipped: Array = []
	for op in operations:
		if not (op is Dictionary):
			skipped.append({"op": op, "reason": "operation is not an object"})
			continue
		var source_path: String = str(op.get("source_path", ""))
		if source_path.is_empty():
			skipped.append({"op": op, "reason": "missing source_path"})
			continue
		if not ResourceLoader.exists(source_path):
			skipped.append({"source_path": source_path, "reason": "source not found"})
			continue
		var source = ResourceLoader.load(source_path)
		if source == null or not (source is Texture2D):
			skipped.append({"source_path": source_path, "reason": "source is not a Texture2D"})
			continue
		var rect: Rect2i = _to_rect2i(op.get("rect", {}), source)
		var modulate: Color = Color.WHITE
		if op.has("modulate"):
			modulate = ProjectToolsNative._parse_color(op["modulate"])
		var mipmap: int = int(op.get("mipmap", 0))
		texture.blit_rect(rect, source, modulate, mipmap, null)
		applied += 1

	if applied == 0:
		return {"error": "No draw operations applied", "skipped": skipped}

	if bool(params.get("generate_mipmaps", false)):
		texture.generate_mipmaps()

	var error: Error = ResourceSaver.save(texture, resource_path)
	if error != OK:
		return {"error": "Failed to save texture: " + error_string(error)}

	return {
		"status": "success",
		"resource_path": resource_path,
		"applied_count": applied,
		"skipped": skipped,
		"godot_version": str(Engine.get_version_info().get("string", ""))
	}


# ============================================================================
# generate_asset - asset generation adapter (placeholder-first + external API)
# ============================================================================
#
# Closes the asset-generation loop for AI-driven game production:
#   - provider "placeholder" (default, offline, deterministic): synthesizes a
#     procedural sprite/texture (Image -> PNG) or sound effect
#     (AudioStreamWAV -> .tres/.wav) from the prompt, so a prototype never
#     blocks on missing art. Generation parameters are derived from a stable
#     hash of the prompt, so the same prompt yields the same asset.
#   - provider "external": calls an external image/audio/TTS HTTP API, validates
#     the returned bytes, then lands them into res:// (and reimports). When no
#     endpoint is configured it returns status "unconfigured" with guidance
#     instead of failing, so callers can gracefully fall back to placeholders.
# Either way the result is dropped into res:// and (best effort) reimported so
# the engine sees a real Texture2D / AudioStream.

const _ASSET_IMAGE_TYPES: Array = ["texture", "sprite", "icon"]
const _ASSET_AUDIO_TYPES: Array = ["audio", "sfx", "tone"]
const _ASSET_PATTERNS: Array = ["solid", "gradient", "checker", "circle", "frame", "noise"]
const _ASSET_WAVEFORMS: Array = ["sine", "square", "saw", "triangle", "noise"]

func _asset_category(asset_type: String) -> String:
	if asset_type in _ASSET_IMAGE_TYPES:
		return "image"
	if asset_type in _ASSET_AUDIO_TYPES:
		return "audio"
	return ""

static func _asset_seed(prompt: String) -> int:
	# Stable, non-negative seed so the same prompt is reproducible.
	return int(abs(prompt.hash()))

static func _asset_seed_color(seed: int, salt: int) -> Color:
	var hue: float = float((seed + salt * 2654435761) % 1000) / 1000.0
	var sat: float = 0.45 + float((seed >> 3) % 45) / 100.0
	var val: float = 0.60 + float((seed >> 7) % 35) / 100.0
	return Color.from_hsv(hue, sat, val, 1.0)

func _register_generate_asset(server_core: RefCounted) -> void:
	var tool_name: String = "generate_asset"
	var description: String = "Generate a game asset (sprite/texture or sound effect) from a text prompt and land it into res://. provider 'placeholder' (default) synthesizes a deterministic procedural Image (PNG) or AudioStreamWAV (.tres/.wav) offline so prototypes never block on missing art; provider 'external' calls an external image/audio/TTS HTTP API, validates the bytes (image: PNG/JPEG/WEBP; audio: WAV/OGG/MP3), and saves them. With provider 'external' pass a 'preset' (openai_image, stability_image, elevenlabs_tts, local_sd_webui) to fill the endpoint/headers/body from a built-in template — the API key is read from an OS env var, never logged — or set endpoint/headers manually; use body_format 'multipart' for APIs that require multipart/form-data (e.g. Stability v2beta). A default preset and key env var can also be configured in the MCP panel. Returns status 'unconfigured' when no endpoint/preset is set so callers can fall back to placeholders. The result is reimported when an editor interface is available."

	var input_schema: Dictionary = {
		"type": "object",
		"properties": {
			"type": {"type": "string", "description": "Asset type. Image: texture, sprite, icon. Audio: audio, sfx, tone.", "enum": ["texture", "sprite", "icon", "audio", "sfx", "tone"]},
			"prompt": {"type": "string", "description": "Text prompt describing the asset. Seeds deterministic placeholder generation and is sent to external providers."},
			"resource_path": {"type": "string", "description": "Where to save (res:// or user://). Image: .png/.jpg/.webp. Audio: .tres/.wav (placeholder); external audio also .ogg/.mp3."},
			"provider": {"type": "string", "description": "Generation provider. Default 'placeholder' (offline procedural). 'external' calls an HTTP API.", "enum": ["placeholder", "external"], "default": "placeholder"},
			"preset": {"type": "string", "description": "External provider preset (provider=external). Fills endpoint/headers/body/response_field from a built-in template; the API key is read from the preset's env var. Explicit endpoint/headers/etc. override the preset. When omitted, the default preset configured in the MCP panel is used.", "enum": ["openai_image", "stability_image", "elevenlabs_tts", "local_sd_webui"]},
			"width": {"type": "integer", "description": "Image width in pixels. Default 64.", "default": 64},
			"height": {"type": "integer", "description": "Image height in pixels. Default 64.", "default": 64},
			"pattern": {"type": "string", "description": "Image pattern. Default 'auto' (derived from prompt).", "enum": ["auto", "solid", "gradient", "checker", "circle", "frame", "noise"], "default": "auto"},
			"colors": {"type": "array", "description": "Foreground colors (color string/array/{r,g,b,a}). Defaults derived from prompt."},
			"background": {"description": "Background color. Defaults derived from prompt."},
			"duration": {"type": "number", "description": "Audio duration in seconds. Default 0.5.", "default": 0.5},
			"frequency": {"type": "number", "description": "Audio base frequency in Hz. Default 0 (auto from prompt).", "default": 0.0},
			"waveform": {"type": "string", "description": "Audio waveform. Default 'auto'.", "enum": ["auto", "sine", "square", "saw", "triangle", "noise"], "default": "auto"},
			"sample_rate": {"type": "integer", "description": "Audio sample rate in Hz. Default 22050.", "default": 22050},
			"amplitude": {"type": "number", "description": "Audio amplitude 0..1. Default 0.6.", "default": 0.6},
			"endpoint": {"type": "string", "description": "External provider URL (provider=external)."},
			"api_key_env": {"type": "string", "description": "Name of an OS environment variable holding the API key for the external provider. The key value is never logged."},
			"http_method": {"type": "string", "description": "External HTTP method. Default POST.", "enum": ["GET", "POST"], "default": "POST"},
			"headers": {"type": "object", "description": "Extra HTTP headers for the external request."},
			"request_body": {"description": "External request body. Object/array is sent as JSON; string is sent verbatim."},
			"body_format": {"type": "string", "description": "How an object/array request_body is encoded for the external request. 'json' (default) or 'multipart' (multipart/form-data, e.g. Stability v2beta).", "enum": ["json", "multipart"], "default": "json"},
			"response_field": {"type": "string", "description": "Dot path to a base64-encoded payload inside a JSON response (e.g. 'data.0.b64_json'). When omitted the raw response body is treated as the asset bytes."},
			"timeout_sec": {"type": "number", "description": "External request timeout in seconds. Default 30.", "default": 30.0},
			"record_prompt": {"type": "boolean", "description": "Write a '<resource_path>.gen.json' manifest with prompt + parameters for traceability. Default true.", "default": true},
			"reimport": {"type": "boolean", "description": "Reimport the saved file via EditorFileSystem when available. Default true.", "default": true}
		},
		"required": ["type", "prompt", "resource_path"]
	}

	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"status": {"type": "string"},
			"resource_path": {"type": "string"},
			"type": {"type": "string"},
			"category": {"type": "string"},
			"provider": {"type": "string"},
			"prompt": {"type": "string"},
			"generator": {"type": "object"},
			"size_bytes": {"type": "integer"},
			"manifest_path": {"type": "string"},
			"reimported": {"type": "boolean"},
			"reimport_skipped_reason": {"type": "string"}
		}
	}

	var annotations: Dictionary = {
		"readOnlyHint": false,
		"destructiveHint": false,
		"idempotentHint": false,
		"openWorldHint": true
	}

	server_core.register_tool(tool_name, description, input_schema,
						  Callable(self, "_tool_generate_asset"),
						  output_schema, annotations,
						  "supplementary", "Project-Advanced")

func _tool_generate_asset(params: Dictionary) -> Dictionary:
	var asset_type: String = str(params.get("type", "")).strip_edges().to_lower()
	if asset_type.is_empty():
		return {"error": "Missing required parameter: type"}
	var category: String = _asset_category(asset_type)
	if category.is_empty():
		return {"error": "Invalid type '%s'. Image: texture, sprite, icon. Audio: audio, sfx, tone." % asset_type}

	var prompt: String = str(params.get("prompt", "")).strip_edges()
	if prompt.is_empty():
		return {"error": "Missing required parameter: prompt"}

	var resource_path: String = str(params.get("resource_path", "")).strip_edges()
	if resource_path.is_empty():
		return {"error": "Missing required parameter: resource_path"}

	var allowed_ext: Array = [".png", ".jpg", ".jpeg", ".webp"] if category == "image" else [".tres", ".res", ".wav", ".ogg", ".mp3"]
	var validation: Dictionary = PathValidator.validate_file_path(resource_path, allowed_ext)
	if not validation["valid"]:
		return {"error": "Invalid path: " + validation["error"]}
	resource_path = validation["sanitized"]

	var dir_path: String = resource_path.get_base_dir()
	if not dir_path.is_empty() and not DirAccess.dir_exists_absolute(dir_path):
		if DirAccess.make_dir_recursive_absolute(dir_path) != OK:
			return {"error": "Failed to create directory: " + dir_path}

	var provider: String = str(params.get("provider", "placeholder")).strip_edges().to_lower()
	if provider != "placeholder" and provider != "external":
		return {"error": "Invalid provider '%s'. Expected 'placeholder' or 'external'." % provider}

	var seed: int = _asset_seed(prompt)
	var generator: Dictionary = {}
	var save_result: Dictionary = {}

	if provider == "external":
		var fetched: Dictionary = _generate_asset_external(params, category)
		if fetched.has("error"):
			return fetched
		if fetched.get("status", "") == "unconfigured":
			return fetched
		generator = fetched.get("generator", {})
		save_result = _land_asset_bytes(fetched.get("bytes", PackedByteArray()), resource_path, category)
	elif category == "image":
		var gen_image: Dictionary = _generate_placeholder_image(params, seed)
		generator = gen_image["generator"]
		save_result = _save_image_asset(gen_image["image"], resource_path)
	else:
		var gen_audio: Dictionary = _generate_placeholder_audio(params, seed)
		generator = gen_audio["generator"]
		save_result = _save_audio_asset(gen_audio["stream"], resource_path)

	if save_result.has("error"):
		return save_result

	var result: Dictionary = {
		"status": "success",
		"resource_path": resource_path,
		"type": asset_type,
		"category": category,
		"provider": provider,
		"prompt": prompt,
		"generator": generator,
		"size_bytes": int(save_result.get("size_bytes", 0))
	}

	if bool(params.get("record_prompt", true)):
		var manifest_path: String = resource_path + ".gen.json"
		var manifest: Dictionary = {
			"prompt": prompt,
			"type": asset_type,
			"category": category,
			"provider": provider,
			"generator": generator,
			"godot_version": str(Engine.get_version_info().get("string", ""))
		}
		var mf: FileAccess = FileAccess.open(manifest_path, FileAccess.WRITE)
		if mf:
			mf.store_string(JSON.stringify(manifest, "\t"))
			mf.close()
			result["manifest_path"] = manifest_path

	if bool(params.get("reimport", true)):
		var reimport: Dictionary = _reimport_asset(resource_path)
		result["reimported"] = bool(reimport.get("reimported", false))
		if reimport.has("reason"):
			result["reimport_skipped_reason"] = reimport["reason"]
	else:
		result["reimported"] = false
		result["reimport_skipped_reason"] = "reimport disabled by caller"

	return result

func _generate_placeholder_image(params: Dictionary, seed: int) -> Dictionary:
	var width: int = clampi(int(params.get("width", 64)), 1, 4096)
	var height: int = clampi(int(params.get("height", 64)), 1, 4096)

	var pattern: String = str(params.get("pattern", "auto")).strip_edges().to_lower()
	if pattern == "auto" or not (pattern in _ASSET_PATTERNS):
		pattern = _ASSET_PATTERNS[seed % _ASSET_PATTERNS.size()]

	var fg_colors: Array = []
	var raw_colors: Variant = params.get("colors", [])
	if raw_colors is Array and not (raw_colors as Array).is_empty():
		for c in raw_colors:
			fg_colors.append(ProjectToolsNative._parse_color(c))
	else:
		fg_colors = [_asset_seed_color(seed, 1), _asset_seed_color(seed, 7)]

	var background: Color = ProjectToolsNative._parse_color(params["background"]) if params.has("background") else _asset_seed_color(seed, 13).darkened(0.55)

	var image: Image = Image.create(width, height, false, Image.FORMAT_RGBA8)
	image.fill(background)
	var primary: Color = fg_colors[0]
	var secondary: Color = fg_colors[1] if fg_colors.size() > 1 else fg_colors[0]

	match pattern:
		"solid":
			image.fill(primary)
		"gradient":
			for y in range(height):
				var t: float = float(y) / float(max(1, height - 1))
				var row: Color = primary.lerp(secondary, t)
				for x in range(width):
					image.set_pixel(x, y, row)
		"checker":
			var cell: int = max(2, int(round(float(min(width, height)) / 8.0)))
			for y in range(height):
				for x in range(width):
					var on: bool = ((x / cell) + (y / cell)) % 2 == 0
					image.set_pixel(x, y, primary if on else secondary)
		"circle":
			var cx: float = float(width) / 2.0
			var cy: float = float(height) / 2.0
			var radius: float = float(min(width, height)) * 0.42
			for y in range(height):
				for x in range(width):
					if Vector2(float(x) + 0.5 - cx, float(y) + 0.5 - cy).length() <= radius:
						image.set_pixel(x, y, primary)
		"frame":
			var thickness: int = max(1, int(round(float(min(width, height)) / 16.0)))
			for y in range(height):
				for x in range(width):
					if x < thickness or y < thickness or x >= width - thickness or y >= height - thickness:
						image.set_pixel(x, y, primary)
		"noise":
			var rng: RandomNumberGenerator = RandomNumberGenerator.new()
			rng.seed = seed
			for y in range(height):
				for x in range(width):
					image.set_pixel(x, y, primary.lerp(secondary, rng.randf()))

	var generator: Dictionary = {
		"mode": "procedural_image",
		"pattern": pattern,
		"width": width,
		"height": height,
		"seed": seed
	}
	return {"image": image, "generator": generator}

func _save_image_asset(image: Image, resource_path: String) -> Dictionary:
	var ext: String = resource_path.get_extension().to_lower()
	var error: Error = OK
	match ext:
		"png":
			error = image.save_png(resource_path)
		"jpg", "jpeg":
			error = image.save_jpg(resource_path)
		"webp":
			error = image.save_webp(resource_path)
		_:
			return {"error": "Unsupported image extension '%s'. Use .png, .jpg or .webp." % ext}
	if error != OK:
		return {"error": "Failed to save image: " + error_string(error)}
	return {"size_bytes": _file_size(resource_path)}

func _generate_placeholder_audio(params: Dictionary, seed: int) -> Dictionary:
	var sample_rate: int = clampi(int(params.get("sample_rate", 22050)), 8000, 48000)
	var duration: float = clampf(float(params.get("duration", 0.5)), 0.01, 30.0)

	var frequency: float = float(params.get("frequency", 0.0))
	if frequency <= 0.0:
		frequency = 220.0 + float(seed % 660)

	var waveform: String = str(params.get("waveform", "auto")).strip_edges().to_lower()
	if waveform == "auto" or not (waveform in _ASSET_WAVEFORMS):
		waveform = _ASSET_WAVEFORMS[seed % _ASSET_WAVEFORMS.size()]

	var amplitude: float = clampf(float(params.get("amplitude", 0.6)), 0.0, 1.0)

	var sample_count: int = max(1, int(round(duration * float(sample_rate))))
	var fade_samples: int = max(1, int(float(sample_count) * 0.1))
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = seed

	var bytes: PackedByteArray = PackedByteArray()
	bytes.resize(sample_count * 2)
	for i in range(sample_count):
		var t: float = float(i) / float(sample_rate)
		var phase: float = fposmod(t * frequency, 1.0)
		var value: float = 0.0
		match waveform:
			"sine":
				value = sin(TAU * phase)
			"square":
				value = 1.0 if phase < 0.5 else -1.0
			"saw":
				value = 2.0 * phase - 1.0
			"triangle":
				value = 2.0 * abs(2.0 * phase - 1.0) - 1.0
			"noise":
				value = rng.randf_range(-1.0, 1.0)
		# Linear fade-out tail to avoid an end-of-sample click.
		var remaining: int = sample_count - i
		if remaining < fade_samples:
			value *= float(remaining) / float(fade_samples)
		var sample16: int = int(clampf(value * amplitude, -1.0, 1.0) * 32767.0)
		bytes.encode_s16(i * 2, sample16)

	var stream: AudioStreamWAV = AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = sample_rate
	stream.stereo = false
	stream.data = bytes

	var generator: Dictionary = {
		"mode": "procedural_audio",
		"waveform": waveform,
		"frequency": frequency,
		"duration": duration,
		"sample_rate": sample_rate,
		"sample_count": sample_count,
		"seed": seed
	}
	return {"stream": stream, "generator": generator}

func _save_audio_asset(stream: AudioStreamWAV, resource_path: String) -> Dictionary:
	var ext: String = resource_path.get_extension().to_lower()
	if ext == "mp3" or ext == "ogg":
		return {"error": "Placeholder audio only supports .wav or .tres/.res; use provider 'external' (e.g. the elevenlabs_tts preset) to land .mp3/.ogg."}
	if ext == "wav":
		var werr: Error = stream.save_to_wav(resource_path)
		if werr != OK:
			return {"error": "Failed to save WAV: " + error_string(werr)}
	else:
		var serr: Error = ResourceSaver.save(stream, resource_path)
		if serr != OK:
			return {"error": "Failed to save audio resource: " + error_string(serr)}
	return {"size_bytes": _file_size(resource_path)}

# Validate then write external/raw asset bytes to res://.
func _land_asset_bytes(bytes: PackedByteArray, resource_path: String, category: String) -> Dictionary:
	if bytes.is_empty():
		return {"error": "External provider returned no data"}
	if not _validate_asset_bytes(bytes, category):
		return {"error": "External payload failed validation: bytes do not look like a valid %s asset" % category}
	var dir_path: String = resource_path.get_base_dir()
	if not dir_path.is_empty() and not DirAccess.dir_exists_absolute(dir_path):
		if DirAccess.make_dir_recursive_absolute(dir_path) != OK:
			return {"error": "Failed to create directory: " + dir_path}
	var f: FileAccess = FileAccess.open(resource_path, FileAccess.WRITE)
	if not f:
		return {"error": "Failed to open file for write: " + resource_path}
	f.store_buffer(bytes)
	f.close()
	return {"size_bytes": bytes.size()}

# Magic-byte sniffing so we never land a JSON error body as if it were art.
static func _validate_asset_bytes(bytes: PackedByteArray, category: String) -> bool:
	if bytes.size() < 4:
		return false
	if category == "image":
		# PNG
		if bytes[0] == 0x89 and bytes[1] == 0x50 and bytes[2] == 0x4E and bytes[3] == 0x47:
			return true
		# JPEG
		if bytes[0] == 0xFF and bytes[1] == 0xD8 and bytes[2] == 0xFF:
			return true
		# WEBP (RIFF....WEBP)
		if bytes.size() >= 12 and bytes[0] == 0x52 and bytes[1] == 0x49 and bytes[2] == 0x46 and bytes[3] == 0x46 and bytes[8] == 0x57 and bytes[9] == 0x45 and bytes[10] == 0x42 and bytes[11] == 0x50:
			return true
		return false
	if category == "audio":
		# RIFF (WAV)
		if bytes[0] == 0x52 and bytes[1] == 0x49 and bytes[2] == 0x46 and bytes[3] == 0x46:
			return true
		# OGG
		if bytes[0] == 0x4F and bytes[1] == 0x67 and bytes[2] == 0x67 and bytes[3] == 0x53:
			return true
		# MP3: ID3v2 tag ("ID3") or a raw MPEG audio frame sync (0xFF Ex/Fx).
		# ElevenLabs and many TTS APIs return MP3 (Accept: audio/mpeg).
		if bytes[0] == 0x49 and bytes[1] == 0x44 and bytes[2] == 0x33:
			return true
		if bytes[0] == 0xFF and (bytes[1] & 0xE0) == 0xE0:
			return true
		return false
	return false

func _generate_asset_external(params: Dictionary, category: String) -> Dictionary:
	var cfg: Dictionary = _resolve_external_config(params, category)
	if cfg.has("error"):
		return cfg

	var endpoint: String = str(cfg["endpoint"]).strip_edges()
	if endpoint.is_empty():
		return {
			"status": "unconfigured",
			"message": "provider 'external' requires an 'endpoint' or a 'preset'. Pick a preset (e.g. %s), set an 'endpoint' (and 'api_key_env' naming an OS env var), or configure a default in the MCP panel. Use provider 'placeholder' for offline procedural assets." % ", ".join(PackedStringArray(AssetProviderPresets.preset_ids())),
			"category": category
		}

	var budget_block: Dictionary = _enforce_generation_budget("generate_asset (%s)" % category)
	if budget_block.has("error"):
		return budget_block

	# S6: endpoint 白名单（https + 已知 provider 主机，或内置本地 preset），
	# 防止把密钥/请求发往任意内网或外部地址（SSRF）。
	if not _is_allowed_gen_endpoint(endpoint):
		return {
			"error": "Endpoint not in allowlist: %s. Only https:// endpoints on known provider hosts are allowed (%s); the built-in local_sd_webui preset (http://127.0.0.1:7860) is the only http exception." % [_url_host(endpoint), ", ".join(PackedStringArray(_allowed_gen_hosts()))],
			"status": "endpoint_blocked"
		}

	var api_key: String = ""
	var api_key_env: String = str(cfg["api_key_env"]).strip_edges()
	if not api_key_env.is_empty():
		# S6: 仅允许读取已知的密钥环境变量名，防止读取任意环境变量并外发。
		if not _is_allowed_api_key_env(api_key_env):
			return {"error": "Environment variable name '%s' is not in the allowlist. Allowed names: %s" % [api_key_env, ", ".join(PackedStringArray(_allowed_api_key_env_names()))]}
		api_key = OS.get_environment(api_key_env)
		if api_key.is_empty():
			return {"error": "Environment variable '%s' is not set or empty" % api_key_env}

	var headers: PackedStringArray = PackedStringArray()
	var auth_header: String = str(cfg["auth_header"]).strip_edges()
	if not api_key.is_empty() and not auth_header.is_empty():
		headers.append("%s: %s%s" % [auth_header, str(cfg["auth_prefix"]), api_key])
	var extra_headers: Variant = cfg["headers"]
	if extra_headers is Dictionary:
		for key in extra_headers:
			headers.append("%s: %s" % [str(key), str(extra_headers[key])])

	var method: int = HTTPClient.METHOD_POST if str(cfg["http_method"]).to_upper() == "POST" else HTTPClient.METHOD_GET
	var body_format: String = str(cfg.get("body_format", "json")).to_lower()
	var body: String = ""
	if cfg["request_body"] != null:
		var raw_body: Variant = cfg["request_body"]
		if raw_body is String:
			body = raw_body
		elif body_format == "multipart" and raw_body is Dictionary:
			# Some APIs (e.g. Stability v2beta stable-image) require multipart/form-data.
			var encoded: Dictionary = _encode_multipart_form(raw_body)
			body = encoded["body"]
			headers.append("Content-Type: " + str(encoded["content_type"]))
		else:
			body = JSON.stringify(raw_body)
			var has_content_type: bool = false
			for h in headers:
				if (h as String).to_lower().begins_with("content-type:"):
					has_content_type = true
					break
			if not has_content_type:
				headers.append("Content-Type: application/json")

	var timeout_sec: float = clampf(float(params.get("timeout_sec", 30.0)), 1.0, 120.0)
	var fetched: Dictionary = _http_blocking_request(endpoint, method, headers, body, timeout_sec, _gen_endpoint_allows_http(endpoint))
	if fetched.has("error"):
		return fetched

	var response_bytes: PackedByteArray = fetched["bytes"]
	var response_field: String = str(cfg["response_field"]).strip_edges()
	if not response_field.is_empty():
		var decoded: Dictionary = _extract_base64_field(response_bytes, response_field)
		if decoded.has("error"):
			return decoded
		response_bytes = decoded["bytes"]

	return {
		"bytes": response_bytes,
		"generator": {
			"mode": "external_http",
			"preset": str(cfg["preset"]),
			"endpoint": endpoint,
			"http_status": int(fetched.get("http_status", 0)),
			"response_field": response_field
		}
	}

# Resolve the effective external request config by layering, in priority order:
# explicit params > selected preset template > persisted MCP panel defaults.
# Performs {prompt}/{width}/{height} substitution. Never reads the API key here
# (only its env-var name), so nothing secret is logged or returned.
func _resolve_external_config(params: Dictionary, category: String) -> Dictionary:
	var settings: Dictionary = _load_asset_provider_settings()
	var preset_id: String = str(params.get("preset", "")).strip_edges()
	if preset_id.is_empty():
		preset_id = str(settings.get("asset_provider_preset", "")).strip_edges()

	var cfg: Dictionary = {
		"endpoint": "", "http_method": "POST", "headers": {}, "request_body": null,
		"response_field": "", "api_key_env": "", "body_format": "json",
		"auth_header": "Authorization", "auth_prefix": "Bearer ", "preset": ""
	}

	if not preset_id.is_empty():
		if not AssetProviderPresets.has_preset(preset_id):
			return {"error": "Unknown preset '%s'. Available: %s" % [preset_id, ", ".join(PackedStringArray(AssetProviderPresets.preset_ids()))]}
		var preset: Dictionary = AssetProviderPresets.get_preset(preset_id)
		var preset_category: String = str(preset.get("category", ""))
		if preset_category != category:
			return {"error": "Preset '%s' generates '%s' assets but the requested type is '%s'." % [preset_id, preset_category, category]}
		cfg["endpoint"] = str(preset.get("endpoint", ""))
		cfg["http_method"] = str(preset.get("http_method", "POST"))
		cfg["headers"] = (preset.get("headers", {}) as Dictionary).duplicate(true)
		cfg["request_body"] = preset.get("request_body", null)
		cfg["response_field"] = str(preset.get("response_field", ""))
		cfg["api_key_env"] = str(preset.get("api_key_env", ""))
		cfg["auth_header"] = str(preset.get("auth_header", "Authorization"))
		cfg["auth_prefix"] = str(preset.get("auth_prefix", "Bearer "))
		cfg["body_format"] = str(preset.get("body_format", "json"))
		cfg["preset"] = preset_id

	if params.has("endpoint") and not str(params["endpoint"]).strip_edges().is_empty():
		cfg["endpoint"] = str(params["endpoint"]).strip_edges()
	if params.has("http_method"):
		cfg["http_method"] = str(params["http_method"])
	if params.has("headers") and params["headers"] is Dictionary:
		for k in (params["headers"] as Dictionary):
			(cfg["headers"] as Dictionary)[k] = params["headers"][k]
	if params.has("request_body"):
		cfg["request_body"] = params["request_body"]
	if params.has("response_field"):
		cfg["response_field"] = str(params["response_field"]).strip_edges()
	if params.has("body_format"):
		cfg["body_format"] = str(params["body_format"]).strip_edges().to_lower()
	# An explicit api_key_env="" lets a caller opt out of auth even on a preset.
	var explicit_no_key: bool = params.has("api_key_env") and str(params["api_key_env"]).strip_edges().is_empty()
	if params.has("api_key_env") and not str(params["api_key_env"]).strip_edges().is_empty():
		cfg["api_key_env"] = str(params["api_key_env"]).strip_edges()
	elif explicit_no_key:
		cfg["api_key_env"] = ""

	if str(cfg["endpoint"]).is_empty():
		cfg["endpoint"] = str(settings.get("asset_provider_endpoint", "")).strip_edges()
	# Only borrow the panel-level key env var when no preset and no explicit opt-out
	# dictated the auth scheme. A preset may intentionally set api_key_env="" (e.g.
	# local_sd_webui needs no auth); don't inject an unrelated global key there.
	if str(cfg["api_key_env"]).is_empty() and preset_id.is_empty() and not explicit_no_key:
		cfg["api_key_env"] = str(settings.get("asset_provider_api_key_env", "")).strip_edges()

	var prompt: String = str(params.get("prompt", ""))
	var width: int = clampi(int(params.get("width", 64)), 1, 4096)
	var height: int = clampi(int(params.get("height", 64)), 1, 4096)
	cfg["endpoint"] = _subst_placeholders(cfg["endpoint"], prompt, width, height)
	cfg["headers"] = _subst_placeholders(cfg["headers"], prompt, width, height)
	if cfg["request_body"] != null:
		cfg["request_body"] = _subst_placeholders(cfg["request_body"], prompt, width, height)
	return cfg

# Recursively substitute {prompt}/{width}/{height} in strings within a template
# (string/dictionary/array). A value that is exactly "{width}"/"{height}" becomes
# an int so numeric API fields stay numeric. {width}/{height} are substituted
# before {prompt} so a user prompt that itself contains "{width}"/"{height}"
# (e.g. "a {width}px grid") is injected verbatim and not re-substituted.
func _subst_placeholders(value: Variant, prompt: String, width: int, height: int) -> Variant:
	if value is String:
		var s: String = value
		if s == "{width}":
			return width
		if s == "{height}":
			return height
		return s.replace("{width}", str(width)).replace("{height}", str(height)).replace("{prompt}", prompt)
	if value is Dictionary:
		var out: Dictionary = {}
		for k in (value as Dictionary):
			out[k] = _subst_placeholders(value[k], prompt, width, height)
		return out
	if value is Array:
		var arr: Array = []
		for e in (value as Array):
			arr.append(_subst_placeholders(e, prompt, width, height))
		return arr
	return value

# Encode a flat field dictionary as a multipart/form-data request body. Used by
# providers (e.g. Stability v2beta) that reject application/json. Values are
# stringified text fields; returns {"body": String, "content_type": String}.
func _encode_multipart_form(fields: Dictionary) -> Dictionary:
	var boundary: String = "----GodotMCPBoundary%x%x" % [Time.get_ticks_usec(), randi()]
	var parts: PackedStringArray = PackedStringArray()
	for key in fields:
		parts.append("--%s\r\nContent-Disposition: form-data; name=\"%s\"\r\n\r\n%s\r\n" % [boundary, str(key), str(fields[key])])
	parts.append("--%s--\r\n" % boundary)
	return {"body": "".join(parts), "content_type": "multipart/form-data; boundary=" + boundary}

func _load_asset_provider_settings() -> Dictionary:
	var mgr: MCPSettingsManager = MCPSettingsManager.new()
	return mgr.load_settings()

# 外部生成预算护栏：在真正发起付费外部调用前调用。
# 从设置读取上限/窗口并配置滑动窗口计数器，超限时返回带 "error" 的字典（调用方应原样返回）。
# 返回空字典表示放行。max_calls<=0（默认）时不限制，向后兼容。
func _enforce_generation_budget(label: String) -> Dictionary:
	var settings: Dictionary = _load_asset_provider_settings()
	var max_calls: int = int(settings.get("external_gen_budget", 0))
	var window_sec: int = int(settings.get("external_gen_budget_window_sec", 3600))
	if max_calls <= 0:
		return {}
	MCPGenerationBudget.configure(max_calls, window_sec)
	var verdict: Dictionary = MCPGenerationBudget.try_consume()
	if not verdict.get("allowed", true):
		return {
			"error": "External generation budget exceeded for %s: limit %d call(s) per %ds. Retry in ~%ds, raise 'external_gen_budget' in the MCP panel, or use provider 'placeholder'." % [
				label, int(verdict.get("max_calls", max_calls)), int(verdict.get("window_sec", window_sec)), int(verdict.get("reset_in_sec", 0))
			],
			"status": "budget_exceeded",
			"budget": MCPGenerationBudget.snapshot(),
		}
	return {}

# ============================================================================
# 资产生成 SSRF / 密钥外泄防护 (S6)
# ============================================================================

# 外部资产生成允许的主机名单（与 asset_provider_presets 内置预设一致）。
# 除内置 local_sd_webui 预设（用户本机服务，http）外，一律要求 https。
const ALLOWED_GEN_ENDPOINTS: Array[String] = [
	"https://api.openai.com",
	"https://api.stability.ai",
	"https://api.elevenlabs.io",
	"https://api.meshy.ai",
	"https://api.tripo3d.ai",
]
# local_sd_webui 预设是唯一允许的 http 端点：指向用户自己的本地服务。
const ALLOWED_GEN_HTTP_LOCAL_HOST: String = "127.0.0.1"
const ALLOWED_GEN_HTTP_LOCAL_PORT: int = 7860
# 允许读取的密钥环境变量名：GODOT_MCP_API_KEY + 各预设声明的 key_env。
const ALLOWED_GEN_KEY_ENVS: Array[String] = ["GODOT_MCP_API_KEY"]

# 从内置预设收集允许的主机名（endpoint / submit_endpoint / status_endpoint），
# 与显式名单取并集，避免未来新增预设时忘记同步安全名单。
static func _allowed_gen_hosts() -> Array[String]:
	var hosts: Array[String] = []
	for entry in ALLOWED_GEN_ENDPOINTS:
		var host: String = _url_hostname(entry)
		if not host.is_empty() and not hosts.has(host):
			hosts.append(host)
	for preset_id in AssetProviderPresets.PRESETS:
		var preset: Dictionary = AssetProviderPresets.PRESETS[preset_id] as Dictionary
		for key in ["endpoint", "submit_endpoint", "status_endpoint"]:
			var ep: String = str(preset.get(key, "")).strip_edges()
			if ep.is_empty():
				continue
			var host: String = _url_hostname(ep)
			if not host.is_empty() and not hosts.has(host):
				hosts.append(host)
	return hosts

# 取 URL 的主机名（去掉 scheme、端口、路径；小写）。
static func _url_hostname(url: String) -> String:
	var host_port: String = _url_host(url)
	var colon: int = host_port.rfind(":")
	if colon != -1 and not host_port.begins_with("["):
		host_port = host_port.substr(0, colon)
	return host_port.to_lower()

# endpoint 白名单校验：https + 主机名在允许列表内；唯一的 http 例外是内置
# local_sd_webui 预设（http://127.0.0.1:7860，用户本机服务）。
static func _is_allowed_gen_endpoint(url: String) -> bool:
	var scheme_end: int = url.find("://")
	if scheme_end == -1:
		return false
	var scheme: String = url.substr(0, scheme_end).to_lower()
	if scheme != "https" and scheme != "http":
		return false
	var host_port: String = _url_host(url)
	var host: String = host_port
	var port: int = -1
	var colon: int = host_port.rfind(":")
	if colon != -1 and not host_port.begins_with("["):
		host = host_port.substr(0, colon)
		port = int(host_port.substr(colon + 1))
	host = host.to_lower()
	if scheme == "http":
		# 唯一的 http 例外：内置本地 Stable Diffusion 预设。
		return host == ALLOWED_GEN_HTTP_LOCAL_HOST and port == ALLOWED_GEN_HTTP_LOCAL_PORT
	return _allowed_gen_hosts().has(host)

# 该端点是否允许走 http（仅内置 local_sd_webui 预设命中）。调用方据此把
# allow_http 传给 _http_blocking_request；白名单校验会先行拦截其余 http 地址。
static func _gen_endpoint_allows_http(url: String) -> bool:
	var host_port: String = _url_host(url)
	var colon: int = host_port.rfind(":")
	if colon == -1:
		return false
	var host: String = host_port.substr(0, colon).to_lower()
	var port: int = int(host_port.substr(colon + 1))
	return host == ALLOWED_GEN_HTTP_LOCAL_HOST and port == ALLOWED_GEN_HTTP_LOCAL_PORT

# 允许读取的密钥环境变量名（含内置预设声明的 key_env）。空串表示调用方显式
# 选择不带认证，视为允许。防止通过 api_key_env 读取任意环境变量并外发。
static func _allowed_api_key_env_names() -> Array[String]:
	var names: Array[String] = []
	for n in ALLOWED_GEN_KEY_ENVS:
		names.append(n)
	for preset_id in AssetProviderPresets.PRESETS:
		var key_env: String = str((AssetProviderPresets.PRESETS[preset_id] as Dictionary).get("api_key_env", "")).strip_edges()
		if not key_env.is_empty() and not names.has(key_env):
			names.append(key_env)
	return names

static func _is_allowed_api_key_env(name: String) -> bool:
	var env_name: String = name.strip_edges()
	if env_name.is_empty():
		return true
	return _allowed_api_key_env_names().has(env_name)

# Blocking HTTPClient request usable from a RefCounted tool (no SceneTree node).
# 默认仅允许 https；allow_http 仅供通过白名单校验的内置本地预设使用。
func _http_blocking_request(url: String, method: int, headers: PackedStringArray, body: String, timeout_sec: float, allow_http: bool = false) -> Dictionary:
	var scheme_end: int = url.find("://")
	if scheme_end == -1:
		return {"error": "Invalid endpoint URL (missing scheme): " + url}
	var scheme: String = url.substr(0, scheme_end).to_lower()
	if scheme != "https" and scheme != "http":
		return {"error": "Unsupported URL scheme '%s://' (only https is allowed)" % scheme}
	if scheme != "https" and not allow_http:
		return {"error": "Only https:// URLs are allowed; refusing http:// request to %s. Use an https endpoint or the built-in local_sd_webui preset (http://127.0.0.1:7860)." % _url_host(url)}
	var use_ssl: bool = scheme == "https"
	var rest: String = url.substr(scheme_end + 3)
	var slash: int = rest.find("/")
	var host_port: String = rest if slash == -1 else rest.substr(0, slash)
	var path: String = "/" if slash == -1 else rest.substr(slash)
	var host: String = host_port
	var port: int = 443 if use_ssl else 80
	var colon: int = host_port.rfind(":")
	if colon != -1:
		host = host_port.substr(0, colon)
		port = int(host_port.substr(colon + 1))

	var http: HTTPClient = HTTPClient.new()
	if http.connect_to_host(host, port, TLSOptions.client() if use_ssl else null) != OK:
		return {"error": "Failed to connect to host: " + host}

	var deadline: int = Time.get_ticks_msec() + int(timeout_sec * 1000.0)
	while http.get_status() == HTTPClient.STATUS_CONNECTING or http.get_status() == HTTPClient.STATUS_RESOLVING:
		http.poll()
		if Time.get_ticks_msec() > deadline:
			return {"error": "Timed out connecting to " + host}
		OS.delay_msec(20)
	if http.get_status() != HTTPClient.STATUS_CONNECTED:
		return {"error": "Could not connect to host (status %d)" % http.get_status()}

	if http.request(method, path, headers, body) != OK:
		return {"error": "Failed to issue HTTP request"}

	while http.get_status() == HTTPClient.STATUS_REQUESTING:
		http.poll()
		if Time.get_ticks_msec() > deadline:
			return {"error": "Timed out waiting for response from " + host}
		OS.delay_msec(20)

	if not (http.get_status() == HTTPClient.STATUS_BODY or http.get_status() == HTTPClient.STATUS_CONNECTED):
		return {"error": "Unexpected HTTP status after request: %d" % http.get_status()}

	var http_status: int = http.get_response_code()
	var response: PackedByteArray = PackedByteArray()
	while http.get_status() == HTTPClient.STATUS_BODY:
		http.poll()
		var chunk: PackedByteArray = http.read_response_body_chunk()
		if chunk.size() > 0:
			response.append_array(chunk)
		elif Time.get_ticks_msec() > deadline:
			return {"error": "Timed out reading response body from " + host}
		else:
			OS.delay_msec(10)
	http.close()

	if http_status < 200 or http_status >= 300:
		return {"error": "External provider returned HTTP %d" % http_status, "http_status": http_status}
	return {"bytes": response, "http_status": http_status}

func _extract_base64_field(response_bytes: PackedByteArray, field_path: String) -> Dictionary:
	var text: String = response_bytes.get_string_from_utf8()
	var parsed: Variant = JSON.parse_string(text)
	if parsed == null:
		return {"error": "response_field set but response is not valid JSON"}
	var node: Variant = parsed
	for part in field_path.split("."):
		if node is Dictionary and (node as Dictionary).has(part):
			node = (node as Dictionary)[part]
		elif node is Array and part.is_valid_int() and int(part) < (node as Array).size():
			node = (node as Array)[int(part)]
		else:
			return {"error": "response_field path '%s' not found in JSON response" % field_path}
	if not (node is String):
		return {"error": "response_field '%s' did not resolve to a base64 string" % field_path}
	var decoded: PackedByteArray = Marshalls.base64_to_raw(node)
	if decoded.is_empty():
		return {"error": "response_field '%s' is not valid base64" % field_path}
	return {"bytes": decoded}

func _reimport_asset(resource_path: String) -> Dictionary:
	var editor_interface: EditorInterface = _get_editor_interface()
	if not editor_interface:
		return {"reimported": false, "reason": "editor interface not available (e.g. headless/non-editor run)"}
	var fs: EditorFileSystem = editor_interface.get_resource_filesystem()
	if not fs:
		return {"reimported": false, "reason": "EditorFileSystem not available"}
	if fs.is_scanning():
		return {"reimported": false, "reason": "EditorFileSystem is scanning"}
	fs.update_file(resource_path)
	fs.reimport_files(PackedStringArray([resource_path]))
	return {"reimported": true}

static func _file_size(path: String) -> int:
	var f: FileAccess = FileAccess.open(path, FileAccess.READ)
	if not f:
		return 0
	var size: int = f.get_length()
	f.close()
	return size


# ============================================================================
# slice_sprite_sheet - Slice a sprite sheet texture into a SpriteFrames resource
# (and optionally an AnimatedSprite2D scene) so generated/imported sheets become
# animation-ready in one step. Closes the 2D asset loop.
# ============================================================================

# Pure helper: compute the per-frame atlas regions for a sheet of the given size.
# grid accepts either {h_frames, v_frames} or {cell_width, cell_height}, plus
# optional {margin, spacing}. Returns {error} or a layout dictionary.
func _compute_sprite_frame_layout(sheet_w: int, sheet_h: int, grid: Dictionary) -> Dictionary:
	if sheet_w <= 0 or sheet_h <= 0:
		return {"error": "Sprite sheet has invalid dimensions"}
	var margin: int = max(0, int(grid.get("margin", 0)))
	var spacing: int = max(0, int(grid.get("spacing", 0)))
	var columns: int = 0
	var rows: int = 0
	var cell_w: int = 0
	var cell_h: int = 0
	var has_cell: bool = int(grid.get("cell_width", 0)) > 0 and int(grid.get("cell_height", 0)) > 0
	var has_frames: bool = int(grid.get("h_frames", 0)) > 0 and int(grid.get("v_frames", 0)) > 0
	if has_cell:
		cell_w = int(grid["cell_width"])
		cell_h = int(grid["cell_height"])
		columns = (sheet_w - 2 * margin + spacing) / (cell_w + spacing)
		rows = (sheet_h - 2 * margin + spacing) / (cell_h + spacing)
	elif has_frames:
		columns = int(grid["h_frames"])
		rows = int(grid["v_frames"])
		cell_w = (sheet_w - 2 * margin - (columns - 1) * spacing) / columns
		cell_h = (sheet_h - 2 * margin - (rows - 1) * spacing) / rows
	else:
		return {"error": "Provide a grid as either {h_frames, v_frames} or {cell_width, cell_height}"}
	if columns <= 0 or rows <= 0 or cell_w <= 0 or cell_h <= 0:
		return {"error": "Computed grid is empty; check cell size / frame counts against the sheet size"}
	var regions: Array = []
	for row in range(rows):
		for col in range(columns):
			var x: int = margin + col * (cell_w + spacing)
			var y: int = margin + row * (cell_h + spacing)
			if x + cell_w > sheet_w or y + cell_h > sheet_h:
				return {"error": "Frame %d,%d exceeds sheet bounds; check margin/spacing/cell size" % [col, row]}
			regions.append(Rect2(x, y, cell_w, cell_h))
	return {"columns": columns, "rows": rows, "cell_width": cell_w, "cell_height": cell_h, "frame_count": regions.size(), "regions": regions}

# Pure helper: normalize the requested animations against the available frame
# count. Defaults to one looping "default" animation spanning every frame.
func _resolve_sprite_animations(animations_param: Variant, frame_count: int) -> Dictionary:
	var resolved: Array = []
	var seen: Dictionary = {}
	if animations_param == null or (animations_param is Array and (animations_param as Array).is_empty()):
		var all_frames: Array = []
		for i in range(frame_count):
			all_frames.append(i)
		resolved.append({"name": "default", "frames": all_frames, "fps": 10.0, "loop": true})
		return {"animations": resolved}
	if not (animations_param is Array):
		return {"error": "Parameter 'animations' must be an array"}
	for entry in (animations_param as Array):
		if not (entry is Dictionary):
			return {"error": "Each animation must be an object"}
		var anim: Dictionary = entry
		var clip_name: String = str(anim.get("name", "")).strip_edges()
		if clip_name.is_empty():
			return {"error": "Each animation requires a non-empty 'name'"}
		if seen.has(clip_name):
			return {"error": "Duplicate animation name: " + clip_name}
		seen[clip_name] = true
		var frames: Array = []
		if anim.has("frames") and anim["frames"] is Array:
			for f in (anim["frames"] as Array):
				frames.append(int(f))
		elif anim.has("start_frame") and anim.has("end_frame"):
			var start_frame: int = int(anim["start_frame"])
			var end_frame: int = int(anim["end_frame"])
			if end_frame < start_frame:
				return {"error": "Animation '%s' has end_frame < start_frame" % clip_name}
			for i in range(start_frame, end_frame + 1):
				frames.append(i)
		else:
			return {"error": "Animation '%s' needs either 'frames' or 'start_frame'+'end_frame'" % clip_name}
		if frames.is_empty():
			return {"error": "Animation '%s' has no frames" % clip_name}
		for idx in frames:
			if idx < 0 or idx >= frame_count:
				return {"error": "Animation '%s' references frame %d out of range (0..%d)" % [clip_name, idx, frame_count - 1]}
		var fps: float = float(anim.get("fps", 10.0))
		if fps <= 0.0:
			return {"error": "Animation '%s' fps must be > 0" % clip_name}
		var loop: bool = bool(anim.get("loop", true))
		resolved.append({"name": clip_name, "frames": frames, "fps": fps, "loop": loop})
	return {"animations": resolved}

func _register_slice_sprite_sheet(server_core: RefCounted) -> void:
	var tool_name: String = "slice_sprite_sheet"
	var description: String = "Slice a sprite sheet texture into a SpriteFrames resource (.tres) so a generated or imported sheet becomes animation-ready in one step. Provide a grid as either {h_frames, v_frames} or {cell_width, cell_height}, with optional margin (border) and spacing (gap between cells); frames are indexed row-major from 0. Pass 'animations' (array of {name, frames:[...] OR start_frame+end_frame, fps, loop}) to define named clips; when omitted a single looping 'default' clip spanning every frame is created. Set create_scene=true to also save an AnimatedSprite2D scene wired to the SpriteFrames with the first clip set to autoplay."

	var input_schema: Dictionary = {
		"type": "object",
		"properties": {
			"texture_path": {"type": "string", "description": "Sprite sheet image path (res:// .png/.jpg/.webp/.bmp)."},
			"output_path": {"type": "string", "description": "Save path for the SpriteFrames resource (.tres/.res)."},
			"h_frames": {"type": "integer", "description": "Number of columns. Use with v_frames."},
			"v_frames": {"type": "integer", "description": "Number of rows. Use with h_frames."},
			"cell_width": {"type": "integer", "description": "Frame width in pixels. Use with cell_height (alternative to h_frames/v_frames)."},
			"cell_height": {"type": "integer", "description": "Frame height in pixels. Use with cell_width."},
			"margin": {"type": "integer", "description": "Border (px) around the sheet before the first cell. Default 0.", "default": 0},
			"spacing": {"type": "integer", "description": "Gap (px) between adjacent cells. Default 0.", "default": 0},
			"animations": {"type": "array", "description": "Named clips: {name, frames:[...] OR start_frame+end_frame, fps, loop}. Omit for a single looping 'default' clip."},
			"create_scene": {"type": "boolean", "description": "Also save an AnimatedSprite2D scene wired to the SpriteFrames. Default false.", "default": false},
			"scene_output_path": {"type": "string", "description": "Save path for the AnimatedSprite2D scene (.tscn). Required when create_scene=true."}
		},
		"required": ["texture_path", "output_path"]
	}

	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"status": {"type": "string"},
			"output_path": {"type": "string"},
			"frame_count": {"type": "integer"},
			"columns": {"type": "integer"},
			"rows": {"type": "integer"},
			"cell_width": {"type": "integer"},
			"cell_height": {"type": "integer"},
			"animations": {"type": "array"},
			"scene_output_path": {"type": "string"}
		}
	}

	var annotations: Dictionary = {
		"readOnlyHint": false,
		"destructiveHint": false,
		"idempotentHint": false,
		"openWorldHint": false
	}

	server_core.register_tool(tool_name, description, input_schema,
						  Callable(self, "_tool_slice_sprite_sheet"),
						  output_schema, annotations,
						  "supplementary", "Project-Advanced")

func _tool_slice_sprite_sheet(params: Dictionary) -> Dictionary:
	var texture_path: String = str(params.get("texture_path", "")).strip_edges()
	if texture_path.is_empty():
		return {"error": "Missing required parameter: texture_path"}
	var output_path: String = str(params.get("output_path", "")).strip_edges()
	if output_path.is_empty():
		return {"error": "Missing required parameter: output_path"}

	var tex_validation: Dictionary = PathValidator.validate_file_path(texture_path, [".png", ".jpg", ".jpeg", ".webp", ".bmp"])
	if not tex_validation.get("valid", false):
		return {"error": "Invalid texture_path: " + str(tex_validation.get("error", ""))}
	texture_path = str(tex_validation.get("sanitized", texture_path))

	var out_validation: Dictionary = PathValidator.validate_file_path(output_path, [".tres", ".res"])
	if not out_validation.get("valid", false):
		return {"error": "Invalid output_path: " + str(out_validation.get("error", ""))}
	output_path = str(out_validation.get("sanitized", output_path))

	var texture_abs: String = ProjectSettings.globalize_path(texture_path)
	if not FileAccess.file_exists(texture_abs):
		return {"error": "Texture not found: " + texture_path}

	# Prefer the imported resource so the atlas reference round-trips cleanly;
	# fall back to loading the raw image (headless / unimported assets).
	var texture: Texture2D = null
	if ResourceLoader.exists(texture_path):
		var loaded: Resource = ResourceLoader.load(texture_path)
		if loaded is Texture2D:
			texture = loaded
	if texture == null:
		var image: Image = Image.load_from_file(texture_abs)
		if image == null or image.is_empty():
			return {"error": "Failed to load texture: " + texture_path}
		texture = ImageTexture.create_from_image(image)

	var grid: Dictionary = {
		"h_frames": int(params.get("h_frames", 0)),
		"v_frames": int(params.get("v_frames", 0)),
		"cell_width": int(params.get("cell_width", 0)),
		"cell_height": int(params.get("cell_height", 0)),
		"margin": int(params.get("margin", 0)),
		"spacing": int(params.get("spacing", 0))
	}
	var layout: Dictionary = _compute_sprite_frame_layout(texture.get_width(), texture.get_height(), grid)
	if layout.has("error"):
		return layout

	var resolved: Dictionary = _resolve_sprite_animations(params.get("animations", null), int(layout["frame_count"]))
	if resolved.has("error"):
		return resolved
	var animations: Array = resolved["animations"]

	var regions: Array = layout["regions"]
	var sprite_frames: SpriteFrames = SpriteFrames.new()
	var keep_default: bool = false
	for anim in animations:
		if str(anim["name"]) == "default":
			keep_default = true
	if not keep_default and sprite_frames.has_animation("default"):
		sprite_frames.remove_animation("default")

	var anim_summary: Array = []
	for anim in animations:
		var anim_name: String = str(anim["name"])
		if not sprite_frames.has_animation(anim_name):
			sprite_frames.add_animation(anim_name)
		sprite_frames.set_animation_speed(anim_name, float(anim["fps"]))
		sprite_frames.set_animation_loop(anim_name, bool(anim["loop"]))
		for frame_index in anim["frames"]:
			var atlas: AtlasTexture = AtlasTexture.new()
			atlas.atlas = texture
			atlas.region = regions[int(frame_index)]
			sprite_frames.add_frame(anim_name, atlas)
		anim_summary.append({"name": anim_name, "frame_count": (anim["frames"] as Array).size(), "fps": float(anim["fps"]), "loop": bool(anim["loop"])})

	var out_dir: String = output_path.get_base_dir()
	if not out_dir.is_empty() and not DirAccess.dir_exists_absolute(out_dir):
		if DirAccess.make_dir_recursive_absolute(out_dir) != OK:
			return {"error": "Failed to create directory: " + out_dir}
	var save_err: Error = ResourceSaver.save(sprite_frames, output_path)
	if save_err != OK:
		return {"error": "Failed to save SpriteFrames: " + error_string(save_err)}

	var result: Dictionary = {
		"status": "success",
		"output_path": output_path,
		"frame_count": int(layout["frame_count"]),
		"columns": int(layout["columns"]),
		"rows": int(layout["rows"]),
		"cell_width": int(layout["cell_width"]),
		"cell_height": int(layout["cell_height"]),
		"animations": anim_summary
	}

	if bool(params.get("create_scene", false)):
		var scene_path: String = str(params.get("scene_output_path", "")).strip_edges()
		if scene_path.is_empty():
			result["scene_error"] = "create_scene=true requires scene_output_path"
			return result
		var scene_validation: Dictionary = PathValidator.validate_file_path(scene_path, [".tscn", ".scn"])
		if not scene_validation.get("valid", false):
			result["scene_error"] = "Invalid scene_output_path: " + str(scene_validation.get("error", ""))
			return result
		scene_path = str(scene_validation.get("sanitized", scene_path))
		var sprite_frames_disk: Resource = ResourceLoader.load(output_path)
		var node: AnimatedSprite2D = AnimatedSprite2D.new()
		node.name = "AnimatedSprite2D"
		node.sprite_frames = sprite_frames_disk if sprite_frames_disk is SpriteFrames else sprite_frames
		var first_anim: String = str((animations[0] as Dictionary)["name"])
		node.animation = first_anim
		node.autoplay = first_anim
		var packed: PackedScene = PackedScene.new()
		var pack_err: Error = packed.pack(node)
		node.free()
		if pack_err != OK:
			result["scene_error"] = "Failed to pack scene: " + error_string(pack_err)
			return result
		var scene_dir: String = scene_path.get_base_dir()
		if not scene_dir.is_empty() and not DirAccess.dir_exists_absolute(scene_dir):
			if DirAccess.make_dir_recursive_absolute(scene_dir) != OK:
				result["scene_error"] = "Failed to create directory: " + scene_dir
				return result
		var scene_err: Error = ResourceSaver.save(packed, scene_path)
		if scene_err != OK:
			result["scene_error"] = "Failed to save scene: " + error_string(scene_err)
			return result
		result["scene_output_path"] = scene_path

	return result


# ============================================================================
# inspect_gltf_asset - Import a glTF/GLB file and report a structural summary
# plus validation warnings, so generated/downloaded 3D assets can be verified
# before use. Closes the 3D import side of the asset loop.
# ============================================================================

func _register_inspect_gltf_asset(server_core: RefCounted) -> void:
	var tool_name: String = "inspect_gltf_asset"
	var description: String = "Import a glTF/GLB file with GLTFDocument and report a structural summary (mesh, material, animation, skin, camera, light and node counts plus their names) together with validation warnings (no meshes, meshes without materials, no animations). Use to verify a generated or downloaded 3D asset is usable before wiring it into a scene. Read-only: it parses the file but does not modify the project."

	var input_schema: Dictionary = {
		"type": "object",
		"properties": {
			"path": {"type": "string", "description": "Path to a .gltf or .glb file (res:// or user://)."},
			"include_names": {"type": "boolean", "description": "Include the per-resource name lists (meshes/materials/animations). Default true.", "default": true}
		},
		"required": ["path"]
	}

	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"status": {"type": "string"},
			"path": {"type": "string"},
			"mesh_count": {"type": "integer"},
			"material_count": {"type": "integer"},
			"animation_count": {"type": "integer"},
			"skin_count": {"type": "integer"},
			"node_count": {"type": "integer"},
			"camera_count": {"type": "integer"},
			"light_count": {"type": "integer"},
			"meshes": {"type": "array"},
			"materials": {"type": "array"},
			"animations": {"type": "array"},
			"warnings": {"type": "array"}
		}
	}

	var annotations: Dictionary = {
		"readOnlyHint": true,
		"destructiveHint": false,
		"idempotentHint": true,
		"openWorldHint": false
	}

	server_core.register_tool(tool_name, description, input_schema,
						  Callable(self, "_tool_inspect_gltf_asset"),
						  output_schema, annotations,
						  "supplementary", "Project-Advanced")

func _tool_inspect_gltf_asset(params: Dictionary) -> Dictionary:
	var path: String = str(params.get("path", "")).strip_edges()
	if path.is_empty():
		return {"error": "Missing required parameter: path"}

	var validation: Dictionary = PathValidator.validate_file_path(path, [".gltf", ".glb"])
	if not validation.get("valid", false):
		return {"error": "Invalid path: " + str(validation.get("error", ""))}
	path = str(validation.get("sanitized", path))

	var abs_path: String = ProjectSettings.globalize_path(path)
	if not FileAccess.file_exists(abs_path):
		return {"error": "File not found: " + path}

	var doc: GLTFDocument = GLTFDocument.new()
	var state: GLTFState = GLTFState.new()
	var err: Error = doc.append_from_file(abs_path, state)
	if err != OK:
		return {"error": "Failed to parse glTF: " + error_string(err), "path": path}

	var include_names: bool = bool(params.get("include_names", true))
	var meshes: Array = state.get_meshes()
	var materials: Array = state.get_materials()
	var animations: Array = state.get_animations()
	var skins: Array = state.get_skins()
	var nodes: Array = state.get_nodes()
	var cameras: Array = state.get_cameras()
	var lights: Array = state.get_lights()

	var mesh_names: Array = []
	var meshes_without_material: int = 0
	for gltf_mesh in meshes:
		var mesh_name: String = ""
		var surface_count: int = 0
		var importer_mesh: ImporterMesh = null
		if gltf_mesh != null:
			importer_mesh = gltf_mesh.get_mesh()
		if importer_mesh != null:
			mesh_name = importer_mesh.resource_name
			surface_count = importer_mesh.get_surface_count()
		if include_names:
			mesh_names.append({"name": mesh_name, "surface_count": surface_count})

	var material_names: Array = []
	for mat in materials:
		if include_names:
			material_names.append(mat.resource_name if mat != null else "")

	var animation_names: Array = []
	for anim in animations:
		if include_names:
			animation_names.append(anim.get_original_name() if anim != null else "")

	if materials.is_empty() and not meshes.is_empty():
		meshes_without_material = meshes.size()

	var warnings: Array = []
	if meshes.is_empty():
		warnings.append("No meshes found in the glTF asset")
	if meshes_without_material > 0:
		warnings.append("glTF has meshes but no materials; surfaces may render untextured")
	if animations.is_empty():
		warnings.append("No animations found in the glTF asset")

	var result: Dictionary = {
		"status": "success",
		"path": path,
		"mesh_count": meshes.size(),
		"material_count": materials.size(),
		"animation_count": animations.size(),
		"skin_count": skins.size(),
		"node_count": nodes.size(),
		"camera_count": cameras.size(),
		"light_count": lights.size(),
		"warnings": warnings
	}
	if include_names:
		result["meshes"] = mesh_names
		result["materials"] = material_names
		result["animations"] = animation_names
	return result


# ============================================================================
# generate_3d_asset - Generate a 3D model (glTF/GLB) from a text prompt via an
# external text-to-3D provider (Meshy/Tripo) and land it into res://. The flow
# is asynchronous: submit a job, poll its status endpoint until success/failure,
# download the resulting glTF/GLB, validate the bytes, then optionally inspect.
# Bring-your-own-key: the API key is read from an OS env var named by the preset
# and never shipped, stored, or logged; the user pays their own provider quota.
# ============================================================================

func _register_generate_3d_asset(server_core: RefCounted) -> void:
	var tool_name: String = "generate_3d_asset"
	var description: String = "Generate a 3D model (glTF/GLB) from a text prompt via an external text-to-3D provider and land it into res://. Asynchronous flow: submits a job, polls the provider's status endpoint until it succeeds or fails, downloads the resulting glTF/GLB, validates the bytes, and (by default) inspects the asset structure (mesh/material/animation counts). Pick a 'preset' (meshy_text_to_3d, tripo_text_to_3d) to fill the submit/status endpoints, request body and status/model-url field paths from a built-in template, or set them manually. Bring-your-own-key: the API key is read from an OS env var named by the preset (e.g. MESHY_API_KEY / TRIPO_API_KEY), never logged or stored, and the user pays their own provider quota. Returns status 'unconfigured' when no preset/submit_endpoint is set so callers can skip or fall back. The result is reimported when an editor interface is available."

	var input_schema: Dictionary = {
		"type": "object",
		"properties": {
			"prompt": {"type": "string", "description": "Text prompt describing the 3D model to generate. Sent to the external provider."},
			"resource_path": {"type": "string", "description": "Where to save the model (res:// or user://): .glb (binary glTF) or .gltf."},
			"preset": {"type": "string", "description": "Text-to-3D provider preset. Fills submit/status endpoints, request body and field paths from a built-in template; the API key is read from the preset's env var. When omitted, a model3d default preset configured in the MCP panel is used.", "enum": ["meshy_text_to_3d", "tripo_text_to_3d"]},
			"api_key_env": {"type": "string", "description": "Name of an OS env var holding the provider API key. Overrides the preset's env var. The key value is never logged. Pass an empty string to send no auth header."},
			"request_body": {"description": "Override the submit request body (object sent as JSON, or string sent verbatim). {prompt} is substituted."},
			"headers": {"type": "object", "description": "Extra HTTP headers merged into both the submit and status requests."},
			"submit_endpoint": {"type": "string", "description": "Override the job-submit URL (use with a custom provider instead of a preset)."},
			"status_endpoint": {"type": "string", "description": "Override the status-poll URL template; must contain {task_id}."},
			"task_id_field": {"type": "string", "description": "Dot path to the job id in the submit response (e.g. 'result' or 'data.task_id')."},
			"status_field": {"type": "string", "description": "Dot path to the status string in the status response (e.g. 'status' or 'data.status')."},
			"model_url_field": {"type": "string", "description": "Dot path to the downloadable model URL in the status response (e.g. 'model_urls.glb')."},
			"poll_interval_sec": {"type": "number", "description": "Seconds between status polls. Default 5 (clamped 1..30).", "default": 5.0},
			"max_wait_sec": {"type": "number", "description": "Total seconds to wait for the job before timing out. Default 300 (clamped 5..1800).", "default": 300.0},
			"timeout_sec": {"type": "number", "description": "Per-request HTTP timeout in seconds. Default 30 (clamped 1..120).", "default": 30.0},
			"record_prompt": {"type": "boolean", "description": "Write a '<resource_path>.gen.json' manifest with prompt + parameters for traceability. Default true.", "default": true},
			"reimport": {"type": "boolean", "description": "Reimport the saved file via EditorFileSystem when available. Default true.", "default": true},
			"inspect": {"type": "boolean", "description": "Run inspect_gltf_asset on the downloaded model and attach the structural summary. Default true.", "default": true}
		},
		"required": ["prompt", "resource_path"]
	}

	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"status": {"type": "string"},
			"resource_path": {"type": "string"},
			"category": {"type": "string"},
			"provider": {"type": "string"},
			"prompt": {"type": "string"},
			"generator": {"type": "object"},
			"size_bytes": {"type": "integer"},
			"manifest_path": {"type": "string"},
			"reimported": {"type": "boolean"},
			"inspection": {"type": "object"},
			"message": {"type": "string"}
		}
	}

	var annotations: Dictionary = {
		"readOnlyHint": false,
		"destructiveHint": false,
		"idempotentHint": false,
		"openWorldHint": true
	}

	server_core.register_tool(tool_name, description, input_schema,
						  Callable(self, "_tool_generate_3d_asset"),
						  output_schema, annotations,
						  "supplementary", "Project-Advanced")

# Resolve the effective text-to-3D request config by layering, in priority
# order: explicit params > selected preset template > a model3d default preset
# from the MCP panel. Never reads the API key here (only its env-var name).
func _resolve_3d_config(params: Dictionary) -> Dictionary:
	var settings: Dictionary = _load_asset_provider_settings()
	var preset_id: String = str(params.get("preset", "")).strip_edges()
	if preset_id.is_empty():
		var panel_preset: String = str(settings.get("asset_provider_preset", "")).strip_edges()
		if not panel_preset.is_empty() and AssetProviderPresets.has_preset(panel_preset) and str(AssetProviderPresets.get_preset(panel_preset).get("category", "")) == "model3d":
			preset_id = panel_preset

	var cfg: Dictionary = {
		"submit_endpoint": "", "submit_method": "POST", "headers": {}, "request_body": null,
		"task_id_field": "", "status_endpoint": "", "status_method": "GET",
		"status_field": "status", "progress_field": "", "success_values": [], "failure_values": [],
		"model_url_fields": [], "api_key_env": "", "auth_header": "Authorization", "auth_prefix": "Bearer ",
		"preset": ""
	}

	if not preset_id.is_empty():
		if not AssetProviderPresets.has_preset(preset_id):
			return {"error": "Unknown preset '%s'. Available 3D presets: %s" % [preset_id, ", ".join(PackedStringArray(AssetProviderPresets.preset_ids_for_category("model3d")))]}
		var preset: Dictionary = AssetProviderPresets.get_preset(preset_id)
		if str(preset.get("category", "")) != "model3d":
			return {"error": "Preset '%s' is not a text-to-3D (model3d) preset." % preset_id}
		for k in ["submit_endpoint", "submit_method", "task_id_field", "status_endpoint", "status_method", "status_field", "progress_field", "api_key_env", "auth_header", "auth_prefix"]:
			if preset.has(k):
				cfg[k] = preset[k]
		cfg["headers"] = (preset.get("headers", {}) as Dictionary).duplicate(true)
		cfg["request_body"] = preset.get("request_body", null)
		cfg["success_values"] = (preset.get("success_values", []) as Array).duplicate()
		cfg["failure_values"] = (preset.get("failure_values", []) as Array).duplicate()
		cfg["model_url_fields"] = (preset.get("model_url_fields", []) as Array).duplicate()
		cfg["preset"] = preset_id

	if params.has("submit_endpoint") and not str(params["submit_endpoint"]).strip_edges().is_empty():
		cfg["submit_endpoint"] = str(params["submit_endpoint"]).strip_edges()
	if params.has("status_endpoint") and not str(params["status_endpoint"]).strip_edges().is_empty():
		cfg["status_endpoint"] = str(params["status_endpoint"]).strip_edges()
	if params.has("request_body"):
		cfg["request_body"] = params["request_body"]
	if params.has("headers") and params["headers"] is Dictionary:
		for k in (params["headers"] as Dictionary):
			(cfg["headers"] as Dictionary)[k] = params["headers"][k]
	if params.has("task_id_field") and not str(params["task_id_field"]).strip_edges().is_empty():
		cfg["task_id_field"] = str(params["task_id_field"]).strip_edges()
	if params.has("status_field") and not str(params["status_field"]).strip_edges().is_empty():
		cfg["status_field"] = str(params["status_field"]).strip_edges()
	if params.has("model_url_field") and not str(params["model_url_field"]).strip_edges().is_empty():
		cfg["model_url_fields"] = [str(params["model_url_field"]).strip_edges()]

	var explicit_no_key: bool = params.has("api_key_env") and str(params["api_key_env"]).strip_edges().is_empty()
	if params.has("api_key_env") and not str(params["api_key_env"]).strip_edges().is_empty():
		cfg["api_key_env"] = str(params["api_key_env"]).strip_edges()
	elif explicit_no_key:
		cfg["api_key_env"] = ""
	return cfg

# Resolve a dot-path value out of a parsed JSON Variant. Returns {value} or {error}.
func _json_path_value(root: Variant, field_path: String) -> Dictionary:
	if field_path.strip_edges().is_empty():
		return {"error": "empty field path"}
	var node: Variant = root
	for part in field_path.split("."):
		if node is Dictionary and (node as Dictionary).has(part):
			node = (node as Dictionary)[part]
		elif node is Array and part.is_valid_int() and int(part) >= 0 and int(part) < (node as Array).size():
			node = (node as Array)[int(part)]
		else:
			return {"error": "path '%s' not found in JSON" % field_path}
	return {"value": node}

# Case-insensitive membership test for a provider status string.
static func _status_matches(status: String, values: Array) -> bool:
	for v in values:
		if status.to_lower() == str(v).to_lower():
			return true
	return false

# Magic-byte sniffing so we never land a JSON error body as if it were a model.
# Accepts binary glTF (GLB magic "glTF") or a JSON .gltf document.
static func _validate_gltf_bytes(bytes: PackedByteArray) -> bool:
	if bytes.size() < 4:
		return false
	if bytes[0] == 0x67 and bytes[1] == 0x6C and bytes[2] == 0x54 and bytes[3] == 0x46:
		return true
	for b in bytes:
		if b == 0x20 or b == 0x09 or b == 0x0A or b == 0x0D or b == 0xEF or b == 0xBB or b == 0xBF:
			continue
		return b == 0x7B
	return false

static func _url_host(url: String) -> String:
	var scheme_end: int = url.find("://")
	if scheme_end == -1:
		return ""
	var rest: String = url.substr(scheme_end + 3)
	var slash: int = rest.find("/")
	return rest if slash == -1 else rest.substr(0, slash)

func _tool_generate_3d_asset(params: Dictionary) -> Dictionary:
	var prompt: String = str(params.get("prompt", "")).strip_edges()
	if prompt.is_empty():
		return {"error": "Missing required parameter: prompt"}
	var resource_path: String = str(params.get("resource_path", "")).strip_edges()
	if resource_path.is_empty():
		return {"error": "Missing required parameter: resource_path"}
	var validation: Dictionary = PathValidator.validate_file_path(resource_path, [".glb", ".gltf"])
	if not validation.get("valid", false):
		return {"error": "Invalid resource_path: " + str(validation.get("error", ""))}
	resource_path = str(validation.get("sanitized", resource_path))

	# Optional client progress token (arguments._meta.progressToken).
	var progress_token: Variant = null
	if params.has("_meta") and params["_meta"] is Dictionary:
		progress_token = (params["_meta"] as Dictionary).get("progressToken", null)

	# 以下校验全部同步完成：配置不合法（unconfigured / endpoint_blocked / 缺
	# 密钥 / 预算超限）在启动后台 job 之前就即时报错，保持工具的错误语义。
	var cfg: Dictionary = _resolve_3d_config(params)
	if cfg.has("error"):
		return cfg

	var submit_endpoint: String = str(cfg["submit_endpoint"]).strip_edges()
	if submit_endpoint.is_empty():
		return {
			"status": "unconfigured",
			"message": "generate_3d_asset requires a 'preset' (e.g. %s) or an explicit 'submit_endpoint'+'status_endpoint'. The API key is read from an OS env var named by the preset (e.g. MESHY_API_KEY); set it before calling. The plugin never ships or stores a key — you supply your own and pay your own provider quota." % ", ".join(PackedStringArray(AssetProviderPresets.preset_ids_for_category("model3d"))),
			"category": "model3d"
		}
	if str(cfg["status_endpoint"]).strip_edges().is_empty():
		return {"error": "No status_endpoint configured for polling the 3D job"}
	var task_id_field: String = str(cfg["task_id_field"]).strip_edges()
	if task_id_field.is_empty():
		return {"error": "No task_id_field configured to read the job id from the submit response"}

	var budget_block: Dictionary = _enforce_generation_budget("generate_3d_asset")
	if budget_block.has("error"):
		return budget_block

	# S6: submit/status endpoint 白名单（https + 已知 3D provider 主机），
	# 防止把密钥发往任意内网/外部地址（SSRF）。
	if not _is_allowed_gen_endpoint(submit_endpoint):
		return {
			"error": "submit_endpoint not in allowlist: %s. Only https:// endpoints on known provider hosts are allowed (%s)." % [_url_host(submit_endpoint), ", ".join(PackedStringArray(_allowed_gen_hosts()))],
			"status": "endpoint_blocked"
		}
	if not _is_allowed_gen_endpoint(str(cfg["status_endpoint"])):
		return {
			"error": "status_endpoint not in allowlist: %s. Only https:// endpoints on known provider hosts are allowed (%s)." % [_url_host(str(cfg["status_endpoint"])), ", ".join(PackedStringArray(_allowed_gen_hosts()))],
			"status": "endpoint_blocked"
		}

	var api_key: String = ""
	var api_key_env: String = str(cfg["api_key_env"]).strip_edges()
	if not api_key_env.is_empty():
		# S6: 仅允许读取已知的密钥环境变量名，防止读取任意环境变量并外发。
		if not _is_allowed_api_key_env(api_key_env):
			return {"error": "Environment variable name '%s' is not in the allowlist. Allowed names: %s" % [api_key_env, ", ".join(PackedStringArray(_allowed_api_key_env_names()))]}
		api_key = OS.get_environment(api_key_env)
		if api_key.is_empty():
			return {"error": "Environment variable '%s' is not set or empty" % api_key_env}

	var headers: PackedStringArray = PackedStringArray()
	var auth_header: String = str(cfg["auth_header"]).strip_edges()
	if not api_key.is_empty() and not auth_header.is_empty():
		headers.append("%s: %s%s" % [auth_header, str(cfg["auth_prefix"]), api_key])
	if cfg["headers"] is Dictionary:
		for k in (cfg["headers"] as Dictionary):
			headers.append("%s: %s" % [str(k), str((cfg["headers"] as Dictionary)[k])])

	var timeout_sec: float = clampf(float(params.get("timeout_sec", 30.0)), 1.0, 120.0)
	var poll_interval: float = clampf(float(params.get("poll_interval_sec", 5.0)), 1.0, 30.0)
	var max_wait: float = clampf(float(params.get("max_wait_sec", 300.0)), 5.0, 1800.0)

	# 异步 pending→poll：首次调用把 submit→轮询→下载→落盘整个流程放到
	# AsyncJobManager 的 worker 线程（HTTP 轮询可能长达数分钟，不能阻塞编辑器
	# 主线程）；再次以相同参数调用则轮询结果。job key 由请求参数稳定派生，
	# 保证相同参数的重复调用命中同一个后台 job。
	var job_key: String = _generate_3d_job_key(prompt, resource_path, cfg)

	# 客户端取消检查：pending→poll 模式的每一轮调用都检查一次；取消时同时
	# 标记底层 job，让 worker 在下一轮轮询循环中尽早中止（协作式取消）。
	if _tool_cancelled():
		if _gen_job_manager.has_job(job_key):
			_gen_job_manager.cancel_job(job_key)
		return {"status": "cancelled", "resource_path": resource_path, "prompt": prompt, "error": "cancelled by client"}

	if _gen_job_manager.has_job(job_key):
		var polled: Dictionary = _gen_job_manager.poll_job(job_key)
		var poll_status: String = str(polled.get("status", ""))
		if poll_status == "pending":
			# 把 worker 上报的进度转发为 MCP progress 通知（主线程发送）。
			_send_tool_progress(progress_token, int(polled.get("progress", 0)), int(polled.get("total", 0)), "polling 3D generation job")
			return {
				"status": "pending",
				"job_id": job_key,
				"resource_path": resource_path,
				"prompt": prompt,
				"elapsed_ms": polled.get("elapsed_ms", 0),
				"message": "3D generation is still running; call generate_3d_asset again with the same arguments to poll for the result."
			}
		if poll_status != "missing":
			# "done"/"cancelled"：worker 结果返回；下载成功的结果在主线程补做
			# reimport + inspect（依赖 EditorInterface / ResourceLoader）。
			return _finalize_generate_3d_asset(polled.get("result", {}), params)
		# status == "missing"：并发请求已取走 job，当作全新任务继续往下走。

	var context: Dictionary = {
		"cfg": cfg,
		"headers": headers,
		"timeout_sec": timeout_sec,
		"poll_interval": poll_interval,
		"max_wait": max_wait,
		"resource_path": resource_path,
		"prompt": prompt,
		"record_prompt": bool(params.get("record_prompt", true))
	}
	if not _gen_job_manager.start_job(job_key, Callable(self, "_execute_generate_3d_asset_blocking").bind(job_key, context)):
		return {"error": "Failed to start 3D generation job"}
	return {
		"status": "pending",
		"job_id": job_key,
		"resource_path": resource_path,
		"prompt": prompt,
		"message": "3D generation submitted on a background thread; call generate_3d_asset again with the same arguments to poll for the result."
	}

# 由生成参数稳定派生的 job key：相同参数（prompt / 输出路径 / 预设 / 端点）
# 的重复调用轮询同一个后台 job；参数变化则视为新任务。
func _generate_3d_job_key(prompt: String, resource_path: String, cfg: Dictionary) -> String:
	var key: String = "gen3d|" + resource_path + "|" + prompt
	for fld in ["preset", "submit_endpoint", "status_endpoint", "task_id_field", "status_field"]:
		key += "|" + str(cfg.get(fld, ""))
	return key

# Blocking text-to-3D flow run on a worker thread by AsyncJobManager. Only does
# HTTP + file I/O (thread-safe); it never touches the editor/scene tree.
# Editor-coupled finalization (reimport + inspect) is deferred to the main
# thread via the "_needs_finalize" marker (see _finalize_generate_3d_asset).
# Cancellation and progress go through the manager's job record.
func _execute_generate_3d_asset_blocking(job_id: String, context: Dictionary) -> Dictionary:
	var cfg: Dictionary = context.get("cfg", {})
	var headers: PackedStringArray = context.get("headers", PackedStringArray())
	var timeout_sec: float = float(context.get("timeout_sec", 30.0))
	var poll_interval: float = float(context.get("poll_interval", 5.0))
	var max_wait: float = float(context.get("max_wait", 300.0))
	var resource_path: String = str(context.get("resource_path", ""))
	var prompt: String = str(context.get("prompt", ""))
	var record_prompt: bool = bool(context.get("record_prompt", true))

	var submit_endpoint: String = str(cfg["submit_endpoint"]).strip_edges()
	var task_id_field: String = str(cfg["task_id_field"]).strip_edges()

	# 1) Submit the generation job.
	var submit_endpoint_final: String = _subst_placeholders(submit_endpoint, prompt, 0, 0)
	var submit_method: int = HTTPClient.METHOD_POST if str(cfg["submit_method"]).to_upper() == "POST" else HTTPClient.METHOD_GET
	var submit_headers: PackedStringArray = headers.duplicate()
	var submit_body: String = ""
	if cfg["request_body"] != null:
		var raw_body: Variant = _subst_placeholders(cfg["request_body"], prompt, 0, 0)
		if raw_body is String:
			submit_body = raw_body
		else:
			submit_body = JSON.stringify(raw_body)
			var has_ct: bool = false
			for h in submit_headers:
				if (h as String).to_lower().begins_with("content-type:"):
					has_ct = true
					break
			if not has_ct:
				submit_headers.append("Content-Type: application/json")
	var submit_res: Dictionary = _http_blocking_request(submit_endpoint_final, submit_method, submit_headers, submit_body, timeout_sec)
	if submit_res.has("error"):
		return submit_res
	var submit_json: Variant = JSON.parse_string((submit_res["bytes"] as PackedByteArray).get_string_from_utf8())
	if submit_json == null:
		return {"error": "Submit response was not valid JSON"}
	var task_id_res: Dictionary = _json_path_value(submit_json, task_id_field)
	if task_id_res.has("error"):
		return {"error": "Could not read task id (field '%s'): %s" % [task_id_field, task_id_res["error"]]}
	var task_id: String = str(task_id_res["value"]).strip_edges()
	if task_id.is_empty():
		return {"error": "Provider returned an empty task id"}

	# 2) Poll the status endpoint until success / failure / timeout.
	var status_field: String = str(cfg["status_field"]).strip_edges()
	var progress_field: String = str(cfg["progress_field"]).strip_edges()
	var success_values: Array = cfg["success_values"]
	var failure_values: Array = cfg["failure_values"]
	var status_endpoint: String = str(cfg["status_endpoint"]).strip_edges().replace("{task_id}", task_id)
	var status_method: int = HTTPClient.METHOD_GET if str(cfg["status_method"]).to_upper() == "GET" else HTTPClient.METHOD_POST
	var deadline: int = Time.get_ticks_msec() + int(max_wait * 1000.0)
	var last_status: String = ""
	var last_progress: int = -1
	var status_json: Variant = null
	var poll_count: int = 0
	while true:
		# 协作式取消：客户端取消（cancel_job）后，worker 在下一轮轮询前中止。
		if _gen_job_manager.is_cancelled(job_id):
			return {"error": "cancelled by client", "status": "cancelled", "cancelled": true, "task_id": task_id, "poll_count": poll_count}
		var st_res: Dictionary = _http_blocking_request(status_endpoint, status_method, headers, "", timeout_sec)
		if st_res.has("error"):
			return st_res
		poll_count += 1
		# 进度存进 job 记录（主线程 poll 时转发为 MCP progress 通知）。
		_gen_job_manager.update_progress(job_id, poll_count, 0)
		status_json = JSON.parse_string((st_res["bytes"] as PackedByteArray).get_string_from_utf8())
		if status_json == null:
			return {"error": "Status response was not valid JSON"}
		var sv: Dictionary = _json_path_value(status_json, status_field)
		if sv.has("error"):
			return {"error": "Could not read job status (field '%s'): %s" % [status_field, sv["error"]]}
		last_status = str(sv["value"])
		if not progress_field.is_empty():
			var pv: Dictionary = _json_path_value(status_json, progress_field)
			if not pv.has("error") and (pv["value"] is float or pv["value"] is int):
				last_progress = int(pv["value"])
		if _status_matches(last_status, success_values):
			break
		if _status_matches(last_status, failure_values):
			return {"error": "3D generation job %s failed (status '%s')" % [task_id, last_status], "status": "failed", "job_status": last_status, "task_id": task_id}
		if Time.get_ticks_msec() > deadline:
			return {"error": "Timed out after %.0fs waiting for 3D job %s (last status '%s', progress %d)" % [max_wait, task_id, last_status, last_progress], "status": "timeout", "task_id": task_id}
		OS.delay_msec(int(poll_interval * 1000.0))

	# 3) Resolve the model URL and download it.
	var model_url: String = ""
	for fld in (cfg["model_url_fields"] as Array):
		var mv: Dictionary = _json_path_value(status_json, str(fld))
		if not mv.has("error") and mv["value"] is String and not str(mv["value"]).strip_edges().is_empty():
			model_url = str(mv["value"]).strip_edges()
			break
	if model_url.is_empty():
		return {"error": "Job succeeded but no model URL found (tried: %s)" % ", ".join(PackedStringArray(cfg["model_url_fields"]))}
	# S6: 下载地址必须 https（provider 响应中的 http 内网地址一律拒绝，防 SSRF 下载内网文件）。
	if not model_url.begins_with("https://"):
		return {"error": "Model download URL must be https:// (provider returned %s). Refusing to download a non-https URL." % _url_host(model_url)}
	var dl: Dictionary = _http_blocking_request(model_url, HTTPClient.METHOD_GET, PackedStringArray(), "", clampf(timeout_sec * 2.0, 1.0, 120.0))
	if dl.has("error"):
		return dl
	var model_bytes: PackedByteArray = dl["bytes"]
	if model_bytes.is_empty():
		return {"error": "Downloaded model is empty"}
	if not _validate_gltf_bytes(model_bytes):
		return {"error": "Downloaded payload is not a valid glTF/GLB asset"}

	# 4) Land the bytes into res:// and write metadata (pure file I/O).
	var dir_path: String = resource_path.get_base_dir()
	if not dir_path.is_empty() and not DirAccess.dir_exists_absolute(dir_path):
		if DirAccess.make_dir_recursive_absolute(dir_path) != OK:
			return {"error": "Failed to create directory: " + dir_path}
	var f: FileAccess = FileAccess.open(resource_path, FileAccess.WRITE)
	if not f:
		return {"error": "Failed to open file for write: " + resource_path}
	f.store_buffer(model_bytes)
	f.close()

	var generator: Dictionary = {
		"mode": "external_text_to_3d",
		"preset": str(cfg["preset"]),
		"submit_endpoint": submit_endpoint,
		"task_id": task_id,
		"job_status": last_status,
		"polls": poll_count,
		"model_url_host": _url_host(model_url)
	}
	if last_progress >= 0:
		generator["progress"] = last_progress

	var result: Dictionary = {
		"status": "success",
		"resource_path": resource_path,
		"category": "model3d",
		"provider": "external",
		"prompt": prompt,
		"generator": generator,
		"size_bytes": model_bytes.size(),
		# reimport + inspect 依赖编辑器主线程，标记后由 poll 侧补做。
		"_needs_finalize": true
	}

	if record_prompt:
		var manifest_path: String = resource_path + ".gen.json"
		var manifest: Dictionary = {
			"prompt": prompt,
			"category": "model3d",
			"provider": "external",
			"generator": generator,
			"godot_version": str(Engine.get_version_info().get("string", ""))
		}
		var mf: FileAccess = FileAccess.open(manifest_path, FileAccess.WRITE)
		if mf:
			mf.store_string(JSON.stringify(manifest, "\t"))
			mf.close()
			result["manifest_path"] = manifest_path

	return result

# 主线程收尾：下载成功后的 reimport + inspect 只能在主线程执行（依赖
# EditorInterface / EditorFileSystem / ResourceLoader），因此从 worker 结果
# 中剥离，在轮询返回给客户端之前完成并合并进结果。
func _finalize_generate_3d_asset(result: Dictionary, params: Dictionary) -> Dictionary:
	if not bool(result.get("_needs_finalize", false)):
		return result
	result.erase("_needs_finalize")
	var resource_path: String = str(result.get("resource_path", ""))

	if bool(params.get("reimport", true)):
		var reimport: Dictionary = _reimport_asset(resource_path)
		result["reimported"] = bool(reimport.get("reimported", false))
		if reimport.has("reason"):
			result["reimport_skipped_reason"] = reimport["reason"]
	else:
		result["reimported"] = false
		result["reimport_skipped_reason"] = "reimport disabled by caller"

	if bool(params.get("inspect", true)):
		var inspection: Dictionary = _tool_inspect_gltf_asset({"path": resource_path, "include_names": true})
		if inspection.has("error"):
			result["inspect_error"] = inspection["error"]
		else:
			result["inspection"] = inspection

	return result

