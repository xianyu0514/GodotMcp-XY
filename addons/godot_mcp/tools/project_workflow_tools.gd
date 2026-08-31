# project_workflow_tools.gd - Project workflow-domain tools (split from project_tools_native.gd)
# bump_version / UI theme / animation resources / manage_task_plan / manage_localization.

@tool
class_name ProjectWorkflowTools
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
	_register_bump_version(server_core)
	_register_create_theme(server_core)
	_register_set_theme_item(server_core)
	_register_set_default_theme(server_core)
	_register_create_animation(server_core)
	_register_insert_animation_keys(server_core)
	_register_manage_task_plan(server_core)
	_register_manage_localization(server_core)

# ============================================================================
# bump_version - 语义化版本号自增 + changelog 自动追加（出货闭环 ⑦）
# ============================================================================

# 纯函数：对 MAJOR.MINOR.PATCH 做语义化自增，便于单测覆盖。
static func _bump_semver(version: String, part: String) -> Dictionary:
	var core: String = version.strip_edges()
	var suffix: String = ""
	for sep in ["-", "+"]:
		var idx: int = core.find(sep)
		if idx >= 0:
			suffix = core.substr(idx)
			core = core.substr(0, idx)
			break
	var bits: PackedStringArray = core.split(".")
	while bits.size() < 3:
		bits.append("0")
	if bits.size() > 3:
		return {"error": "Unsupported version format (expected MAJOR.MINOR.PATCH): " + version}
	var nums: Array[int] = []
	for b in bits:
		if not b.is_valid_int():
			return {"error": "Non-numeric version component in: " + version}
		nums.append(int(b))
	match part:
		"major":
			nums[0] += 1; nums[1] = 0; nums[2] = 0
		"minor":
			nums[1] += 1; nums[2] = 0
		"patch":
			nums[2] += 1
		_:
			return {"error": "Invalid bump part '%s' (expected major/minor/patch)" % part}
	return {"version": "%d.%d.%d%s" % [nums[0], nums[1], nums[2], suffix]}

# 纯函数：把新版本条目插入到 changelog 顶部（标题之后），返回完整新文本。
static func _compose_changelog(existing: String, version: String, date: String, entry: String) -> String:
	var bullet: String = entry.strip_edges()
	if bullet.is_empty():
		bullet = "Release %s" % version
	var block: String = "## %s - %s\n\n- %s\n" % [version, date, bullet]
	var text: String = existing
	if text.strip_edges().is_empty():
		return "# Changelog\n\n" + block
	var lines: PackedStringArray = text.split("\n")
	# 在首个一级标题（# ...）之后插入；找不到则置于顶部。
	var insert_at: int = 0
	for i in range(lines.size()):
		if lines[i].strip_edges().begins_with("# "):
			insert_at = i + 1
			break
	var head: PackedStringArray = lines.slice(0, insert_at)
	var tail: PackedStringArray = lines.slice(insert_at)
	var out: String = "\n".join(head)
	out += "\n\n" + block + "\n" + "\n".join(tail)
	return out

func _register_bump_version(server_core: RefCounted) -> void:
	var tool_name: String = "bump_version"
	var description: String = "Automate version + changelog for the ship loop. Reads the current version from application/config/version, computes the next one (semantic 'bump' major/minor/patch, or an explicit 'version'), and — unless dry_run — writes it back to project.godot via ProjectSettings.save(). When 'changelog_path' is given (default res://CHANGELOG.md unless update_changelog=false), prepends a dated entry built from 'entry'. Returns previous_version, new_version, changelog_path and whether files were written, giving objective, reviewable release bookkeeping."

	var input_schema: Dictionary = {
		"type": "object",
		"properties": {
			"bump": {"type": "string", "enum": ["major", "minor", "patch"], "description": "Semantic version part to increment. Ignored when 'version' is set.", "default": "patch"},
			"version": {"type": "string", "description": "Explicit new version (overrides 'bump')."},
			"entry": {"type": "string", "description": "Changelog bullet text for this release."},
			"update_changelog": {"type": "boolean", "description": "Prepend a changelog entry. Default true.", "default": true},
			"changelog_path": {"type": "string", "description": "Changelog file path. Default res://CHANGELOG.md.", "default": "res://CHANGELOG.md"},
			"dry_run": {"type": "boolean", "description": "Compute the new version and changelog text without writing any file. Default false.", "default": false}
		}
	}

	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"success": {"type": "boolean"},
			"previous_version": {"type": "string"},
			"new_version": {"type": "string"},
			"version_written": {"type": "boolean"},
			"changelog_path": {"type": "string"},
			"changelog_written": {"type": "boolean"},
			"dry_run": {"type": "boolean"}
		}
	}

	var annotations: Dictionary = {
		"readOnlyHint": false,
		"destructiveHint": false,
		"idempotentHint": false,
		"openWorldHint": false
	}

	server_core.register_tool(tool_name, description, input_schema,
											  Callable(self, "_tool_bump_version"),
											  output_schema, annotations,
											  "supplementary", "Project-Advanced")

func _tool_bump_version(params: Dictionary) -> Dictionary:
	var previous_version: String = str(ProjectSettings.get_setting("application/config/version", "")).strip_edges()
	if previous_version.is_empty():
		previous_version = "0.0.0"

	var new_version: String = str(params.get("version", "")).strip_edges()
	if new_version.is_empty():
		var bump_res: Dictionary = _bump_semver(previous_version, str(params.get("bump", "patch")))
		if bump_res.has("error"):
			return bump_res
		new_version = str(bump_res["version"])

	var dry_run: bool = bool(params.get("dry_run", false))
	var version_written: bool = false
	var changelog_written: bool = false
	var update_changelog: bool = bool(params.get("update_changelog", true))
	var changelog_path: String = str(params.get("changelog_path", "res://CHANGELOG.md")).strip_edges()

	if not dry_run:
		ProjectSettings.set_setting("application/config/version", new_version)
		var save_err: Error = ProjectSettings.save()
		if save_err != OK:
			return {"error": "Failed to write project.godot: " + error_string(save_err)}
		version_written = true

	if update_changelog and not changelog_path.is_empty():
		var date: String = Time.get_date_string_from_system()
		var existing: String = ""
		if FileAccess.file_exists(changelog_path):
			var rf: FileAccess = FileAccess.open(changelog_path, FileAccess.READ)
			if rf:
				existing = rf.get_as_text()
				rf.close()
		var new_text: String = _compose_changelog(existing, new_version, date, str(params.get("entry", "")))
		if not dry_run:
			var wf: FileAccess = FileAccess.open(changelog_path, FileAccess.WRITE)
			if wf == null:
				return {"error": "Failed to open changelog for writing: " + changelog_path}
			wf.store_string(new_text)
			wf.close()
			changelog_written = true

	return {
		"success": true,
		"previous_version": previous_version,
		"new_version": new_version,
		"version_written": version_written,
		"changelog_path": changelog_path if update_changelog else "",
		"changelog_written": changelog_written,
		"dry_run": dry_run
	}


# ============================================================================
# create_theme - create and save an empty Theme resource (.tres/.theme)
# ============================================================================

func _register_create_theme(server_core: RefCounted) -> void:
	var tool_name: String = "create_theme"
	var description: String = "Create and save a Theme resource (.tres or .theme) for styling Control-based UI such as card and HUD scenes. Optionally set default base scale, default font size, and a default font resource. Use set_theme_item afterwards to populate per-control colors, constants, fonts, icons, and styleboxes."

	var input_schema: Dictionary = {
		"type": "object",
		"properties": {
			"theme_path": {"type": "string", "description": "Save path for the theme (.tres or .theme), e.g. res://ui/card_theme.tres."},
			"default_base_scale": {"type": "number", "description": "Optional Theme.default_base_scale (UI scaling factor). Must be > 0 to apply."},
			"default_font_size": {"type": "integer", "description": "Optional Theme.default_font_size in pixels. Must be > 0 to apply."},
			"default_font_path": {"type": "string", "description": "Optional path to a Font resource to use as Theme.default_font."}
		},
		"required": ["theme_path"]
	}

	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"status": {"type": "string"},
			"theme_path": {"type": "string"},
			"default_base_scale": {"type": "number"},
			"default_font_size": {"type": "integer"}
		}
	}

	var annotations: Dictionary = {
		"readOnlyHint": false,
		"destructiveHint": false,
		"idempotentHint": false,
		"openWorldHint": false
	}

	server_core.register_tool(tool_name, description, input_schema,
						  Callable(self, "_tool_create_theme"),
						  output_schema, annotations,
						  "supplementary", "Project-Advanced")

func _tool_create_theme(params: Dictionary) -> Dictionary:
	var theme_path: String = str(params.get("theme_path", "")).strip_edges()
	if theme_path.is_empty():
		return {"error": "Missing required parameter: theme_path"}

	var validation: Dictionary = PathValidator.validate_file_path(theme_path, [".tres", ".theme", ".res"])
	if not validation["valid"]:
		return {"error": "Invalid path: " + validation["error"]}
	theme_path = validation["sanitized"]

	var theme: Theme = Theme.new()

	var base_scale: float = float(params.get("default_base_scale", 0.0))
	if base_scale > 0.0:
		theme.default_base_scale = base_scale

	var font_size: int = int(params.get("default_font_size", 0))
	if font_size > 0:
		theme.default_font_size = font_size

	var font_path: String = str(params.get("default_font_path", "")).strip_edges()
	if not font_path.is_empty():
		if not ResourceLoader.exists(font_path):
			return {"error": "Font resource not found: " + font_path}
		var font_res: Resource = ResourceLoader.load(font_path)
		if not (font_res is Font):
			return {"error": "Resource is not a Font: " + font_path}
		theme.default_font = font_res

	var dir_path: String = theme_path.get_base_dir()
	if not dir_path.is_empty() and not DirAccess.dir_exists_absolute(dir_path):
		var mk: Error = DirAccess.make_dir_recursive_absolute(dir_path)
		if mk != OK:
			return {"error": "Failed to create directory: " + dir_path}

	var error: Error = ResourceSaver.save(theme, theme_path)
	if error != OK:
		return {"error": "Failed to save theme: " + error_string(error)}

	return {
		"status": "success",
		"theme_path": theme_path,
		"default_base_scale": theme.default_base_scale,
		"default_font_size": theme.default_font_size
	}


# ============================================================================
# set_theme_item - set a single item on an existing Theme resource
# ============================================================================

func _register_set_theme_item(server_core: RefCounted) -> void:
	var tool_name: String = "set_theme_item"
	var description: String = "Load an existing Theme resource, set one item, and re-save it. Supports item_type of color, constant, font_size (value provided directly) and font, icon, stylebox (value is a path to a Font/Texture2D/StyleBox resource). theme_type is the Control class the item applies to (e.g. Button, Label, Panel). Use to style card and HUD UI without editing the theme by hand."

	var input_schema: Dictionary = {
		"type": "object",
		"properties": {
			"theme_path": {"type": "string", "description": "Path to an existing theme file (.tres/.theme/.res)."},
			"item_type": {"type": "string", "description": "One of: color, constant, font_size, font, icon, stylebox."},
			"item_name": {"type": "string", "description": "Theme item name, e.g. 'font_color', 'h_separation', 'panel'."},
			"theme_type": {"type": "string", "description": "Control type the item applies to, e.g. 'Button', 'Label', 'Panel'."},
			"value": {"type": ["string", "number", "integer", "object", "array"], "description": "For color: a color string/array/object. For constant/font_size: an integer. For font/icon/stylebox: a res:// path to the resource."}
		},
		"required": ["theme_path", "item_type", "item_name", "theme_type", "value"]
	}

	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"status": {"type": "string"},
			"theme_path": {"type": "string"},
			"item_type": {"type": "string"},
			"item_name": {"type": "string"},
			"theme_type": {"type": "string"}
		}
	}

	var annotations: Dictionary = {
		"readOnlyHint": false,
		"destructiveHint": false,
		"idempotentHint": true,
		"openWorldHint": false
	}

	server_core.register_tool(tool_name, description, input_schema,
						  Callable(self, "_tool_set_theme_item"),
						  output_schema, annotations,
						  "supplementary", "Project-Advanced")

func _tool_set_theme_item(params: Dictionary) -> Dictionary:
	var theme_path: String = str(params.get("theme_path", "")).strip_edges()
	var item_type: String = str(params.get("item_type", "")).strip_edges().to_lower()
	var item_name: String = str(params.get("item_name", "")).strip_edges()
	var theme_type: String = str(params.get("theme_type", "")).strip_edges()

	if theme_path.is_empty():
		return {"error": "Missing required parameter: theme_path"}
	if item_type.is_empty():
		return {"error": "Missing required parameter: item_type"}
	if item_name.is_empty():
		return {"error": "Missing required parameter: item_name"}
	if theme_type.is_empty():
		return {"error": "Missing required parameter: theme_type"}
	if not params.has("value"):
		return {"error": "Missing required parameter: value"}

	var supported: Array = ["color", "constant", "font_size", "font", "icon", "stylebox"]
	if not supported.has(item_type):
		return {"error": "Invalid item_type '%s'. Expected one of: color, constant, font_size, font, icon, stylebox." % item_type}

	var validation: Dictionary = PathValidator.validate_file_path(theme_path, [".tres", ".theme", ".res"])
	if not validation["valid"]:
		return {"error": "Invalid path: " + validation["error"]}
	theme_path = validation["sanitized"]

	if not ResourceLoader.exists(theme_path):
		return {"error": "Theme not found: " + theme_path}
	var theme: Theme = ResourceLoader.load(theme_path) as Theme
	if not theme:
		return {"error": "Resource is not a Theme: " + theme_path}

	var value: Variant = params["value"]

	match item_type:
		"color":
			theme.set_color(item_name, theme_type, ProjectToolsNative._parse_color(value))
		"constant":
			theme.set_constant(item_name, theme_type, int(value))
		"font_size":
			theme.set_font_size(item_name, theme_type, int(value))
		"font", "icon", "stylebox":
			var res_path: String = str(value).strip_edges()
			if res_path.is_empty():
				return {"error": "For item_type '%s', value must be a resource path." % item_type}
			if not ResourceLoader.exists(res_path):
				return {"error": "Resource not found: " + res_path}
			var res: Resource = ResourceLoader.load(res_path)
			if item_type == "font":
				if not (res is Font):
					return {"error": "Resource is not a Font: " + res_path}
				theme.set_font(item_name, theme_type, res)
			elif item_type == "icon":
				if not (res is Texture2D):
					return {"error": "Resource is not a Texture2D: " + res_path}
				theme.set_icon(item_name, theme_type, res)
			else:
				if not (res is StyleBox):
					return {"error": "Resource is not a StyleBox: " + res_path}
				theme.set_stylebox(item_name, theme_type, res)

	var error: Error = ResourceSaver.save(theme, theme_path)
	if error != OK:
		return {"error": "Failed to save theme: " + error_string(error)}

	return {
		"status": "success",
		"theme_path": theme_path,
		"item_type": item_type,
		"item_name": item_name,
		"theme_type": theme_type
	}

# ============================================================================

# set_default_theme - set/clear the project-wide default GUI theme
# ============================================================================

func _register_set_default_theme(server_core: RefCounted) -> void:
	var tool_name: String = "set_default_theme"
	var description: String = "Set or clear the project-wide default GUI theme (the 'gui/theme/custom' project setting) and persist it to project.godot. Pass clear=true to remove the custom theme and fall back to the engine default. Use to apply a card-game theme across every Control without assigning it per scene."

	var input_schema: Dictionary = {
		"type": "object",
		"properties": {
			"theme_path": {"type": "string", "description": "Path to a theme resource (.tres/.theme/.res) to set as the project default."},
			"clear": {"type": "boolean", "description": "When true, clear the custom default theme instead of setting one.", "default": false}
		}
	}

	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"status": {"type": "string"},
			"setting": {"type": "string"},
			"theme_path": {"type": "string"},
			"cleared": {"type": "boolean"}
		}
	}

	var annotations: Dictionary = {
		"readOnlyHint": false,
		"destructiveHint": false,
		"idempotentHint": true,
		"openWorldHint": false
	}

	server_core.register_tool(tool_name, description, input_schema,
						  Callable(self, "_tool_set_default_theme"),
						  output_schema, annotations,
						  "supplementary", "Project-Advanced")

func _tool_set_default_theme(params: Dictionary) -> Dictionary:
	var setting_key: String = "gui/theme/custom"
	var clear: bool = bool(params.get("clear", false))

	if clear:
		if ProjectSettings.has_setting(setting_key):
			ProjectSettings.set_setting(setting_key, "")
		var clear_error: Error = ProjectSettings.save()
		if clear_error != OK:
			return {"error": "Failed to save project settings: " + error_string(clear_error)}
		return {
			"status": "success",
			"setting": setting_key,
			"theme_path": "",
			"cleared": true
		}

	var theme_path: String = str(params.get("theme_path", "")).strip_edges()
	if theme_path.is_empty():
		return {"error": "Missing required parameter: theme_path (or pass clear=true)"}

	var validation: Dictionary = PathValidator.validate_file_path(theme_path, [".tres", ".theme", ".res"])
	if not validation["valid"]:
		return {"error": "Invalid path: " + validation["error"]}
	theme_path = validation["sanitized"]

	if not ResourceLoader.exists(theme_path):
		return {"error": "Theme not found: " + theme_path}
	var theme: Theme = ResourceLoader.load(theme_path) as Theme
	if not theme:
		return {"error": "Resource is not a Theme: " + theme_path}

	ProjectSettings.set_setting(setting_key, theme_path)
	var error: Error = ProjectSettings.save()
	if error != OK:
		return {"error": "Failed to save project settings: " + error_string(error)}

	return {
		"status": "success",
		"setting": setting_key,
		"theme_path": theme_path,
		"cleared": false
	}

# ============================================================================

# ============================================================================
# create_animation - Create and save an Animation resource for editor-phase
# authoring of card/UI/FX motion (used by AnimationPlayer at runtime).
# ============================================================================

const _ANIMATION_LOOP_MODES: Dictionary = {
	"none": Animation.LOOP_NONE,
	"linear": Animation.LOOP_LINEAR,
	"pingpong": Animation.LOOP_PINGPONG
}

func _register_create_animation(server_core: RefCounted) -> void:
	var tool_name: String = "create_animation"
	var description: String = "Create and save an Animation resource (.tres/.res/.anim) for editor-phase authoring of card, UI, and FX motion that an AnimationPlayer plays at runtime. Set length (seconds), loop_mode (none/linear/pingpong), and step (keyframe snap in seconds). Use insert_animation_keys afterwards to add tracks and keyframes."

	var input_schema: Dictionary = {
		"type": "object",
		"properties": {
			"animation_path": {"type": "string", "description": "Save path for the animation (.tres/.res/.anim), e.g. res://anim/card_draw.tres."},
			"length": {"type": "number", "description": "Optional animation length in seconds. Must be > 0 to apply."},
			"loop_mode": {"type": "string", "description": "Optional loop mode.", "enum": ["none", "linear", "pingpong"]},
			"step": {"type": "number", "description": "Optional keyframe snap step in seconds. Must be > 0 to apply."}
		},
		"required": ["animation_path"]
	}

	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"status": {"type": "string"},
			"animation_path": {"type": "string"},
			"length": {"type": "number"},
			"loop_mode": {"type": "string"},
			"step": {"type": "number"}
		}
	}

	var annotations: Dictionary = {
		"readOnlyHint": false,
		"destructiveHint": false,
		"idempotentHint": false,
		"openWorldHint": false
	}

	server_core.register_tool(tool_name, description, input_schema,
						  Callable(self, "_tool_create_animation"),
						  output_schema, annotations,
						  "supplementary", "Project-Advanced")

func _tool_create_animation(params: Dictionary) -> Dictionary:
	var animation_path: String = str(params.get("animation_path", "")).strip_edges()
	if animation_path.is_empty():
		return {"error": "Missing required parameter: animation_path"}

	var validation: Dictionary = PathValidator.validate_file_path(animation_path, [".tres", ".res", ".anim"])
	if not validation["valid"]:
		return {"error": "Invalid path: " + validation["error"]}
	animation_path = validation["sanitized"]

	var animation: Animation = Animation.new()

	var length: float = float(params.get("length", 0.0))
	if length > 0.0:
		animation.length = length

	if params.has("loop_mode"):
		var loop_key: String = str(params.get("loop_mode", "")).strip_edges().to_lower()
		if not _ANIMATION_LOOP_MODES.has(loop_key):
			return {"error": "Invalid loop_mode '%s'. Expected one of: none, linear, pingpong." % loop_key}
		animation.loop_mode = _ANIMATION_LOOP_MODES[loop_key]

	var step: float = float(params.get("step", 0.0))
	if step > 0.0:
		animation.step = step

	var dir_path: String = animation_path.get_base_dir()
	if not dir_path.is_empty() and not DirAccess.dir_exists_absolute(dir_path):
		var mk: Error = DirAccess.make_dir_recursive_absolute(dir_path)
		if mk != OK:
			return {"error": "Failed to create directory: " + dir_path}

	var error: Error = ResourceSaver.save(animation, animation_path)
	if error != OK:
		return {"error": "Failed to save animation: " + error_string(error)}

	return {
		"status": "success",
		"animation_path": animation_path,
		"length": animation.length,
		"loop_mode": _animation_loop_mode_name(animation.loop_mode),
		"step": animation.step
	}

func _animation_loop_mode_name(mode: int) -> String:
	for key in _ANIMATION_LOOP_MODES:
		if _ANIMATION_LOOP_MODES[key] == mode:
			return key
	return "none"


# ============================================================================
# insert_animation_keys - Add a track (if missing) on an existing Animation
# and insert keyframes, then re-save. Supports value and 3D transform tracks.
# ============================================================================

const _ANIMATION_TRACK_TYPES: Dictionary = {
	"value": Animation.TYPE_VALUE,
	"position_3d": Animation.TYPE_POSITION_3D,
	"rotation_3d": Animation.TYPE_ROTATION_3D,
	"scale_3d": Animation.TYPE_SCALE_3D
}

func _register_insert_animation_keys(server_core: RefCounted) -> void:
	var tool_name: String = "insert_animation_keys"
	var description: String = "Load an existing Animation resource, ensure a track for the given path exists, insert keyframes, and re-save. track_type 'value' targets a 'Node:property' path (e.g. 'Sprite2D:modulate', '.:position'); 'position_3d'/'rotation_3d'/'scale_3d' target a node path. For value tracks pass value_type to coerce key values (int/float/bool/string/vector2/vector3/color). Use to author card/UI/FX motion driven by an AnimationPlayer."

	var input_schema: Dictionary = {
		"type": "object",
		"properties": {
			"animation_path": {"type": "string", "description": "Path to an existing animation file (.tres/.res/.anim)."},
			"track_path": {"type": "string", "description": "For value tracks, a 'Node:property' path; for transform tracks, a node path."},
			"track_type": {"type": "string", "description": "Track type. Default 'value'.", "enum": ["value", "position_3d", "rotation_3d", "scale_3d"], "default": "value"},
			"value_type": {"type": "string", "description": "Optional coercion for value-track key values.", "enum": ["int", "float", "bool", "string", "vector2", "vector3", "color"]},
			"keys": {"type": "array", "description": "Keyframes as objects {time: number, value: <any>}.", "items": {"type": "object"}},
			"reuse_track": {"type": "boolean", "description": "Reuse a matching existing track instead of adding one. Default true.", "default": true},
			"attach_player_node": {"type": "string", "description": "AnimationPlayer node path in the edited scene; the animation is added to its default library."},
			"animation_name": {"type": "string", "description": "Library name for attach_player_node. Defaults to the resource name."}
		},
		"required": ["animation_path", "track_path", "keys"]
	}

	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"status": {"type": "string"},
			"animation_path": {"type": "string"},
			"track_path": {"type": "string"},
			"track_type": {"type": "string"},
			"track_index": {"type": "integer"},
			"keys_inserted": {"type": "integer"},
			"created_track": {"type": "boolean"}
		}
	}

	var annotations: Dictionary = {
		"readOnlyHint": false,
		"destructiveHint": false,
		"idempotentHint": false,
		"openWorldHint": false
	}

	server_core.register_tool(tool_name, description, input_schema,
						  Callable(self, "_tool_insert_animation_keys"),
						  output_schema, annotations,
						  "supplementary", "Project-Advanced")

func _workflow_editor_interface() -> EditorInterface:
	if _editor_interface:
		return _editor_interface
	if Engine.has_meta("GodotMCPPlugin"):
		var plugin = Engine.get_meta("GodotMCPPlugin")
		if plugin and plugin.has_method("get_editor_interface"):
			return plugin.get_editor_interface()
	return null

func _workflow_resolve_node(editor_interface: EditorInterface, node_path: String) -> Node:
	var scene_root: Node = editor_interface.get_edited_scene_root()
	if scene_root == null:
		return null
	if node_path == "/root" or node_path.is_empty():
		return scene_root
	var relative: String = node_path.trim_prefix("/root/")
	var parts: PackedStringArray = relative.split("/")
	if parts.size() > 0 and parts[0] == scene_root.name:
		if parts.size() == 1:
			return scene_root
		return scene_root.get_node_or_null("/".join(parts.slice(1)))
	return scene_root.get_node_or_null(relative)

func _tool_insert_animation_keys(params: Dictionary) -> Dictionary:
	var animation_path: String = str(params.get("animation_path", "")).strip_edges()
	var track_path: String = str(params.get("track_path", "")).strip_edges()
	if animation_path.is_empty():
		return {"error": "Missing required parameter: animation_path"}
	if track_path.is_empty():
		return {"error": "Missing required parameter: track_path"}
	if not params.has("keys"):
		return {"error": "Missing required parameter: keys"}

	var keys: Variant = params["keys"]
	if not (keys is Array) or (keys as Array).is_empty():
		return {"error": "Parameter 'keys' must be a non-empty array of {time, value} objects"}

	var track_type_name: String = str(params.get("track_type", "value")).strip_edges().to_lower()
	if track_type_name.is_empty():
		track_type_name = "value"
	if not _ANIMATION_TRACK_TYPES.has(track_type_name):
		return {"error": "Invalid track_type '%s'. Expected one of: value, position_3d, rotation_3d, scale_3d." % track_type_name}
	var track_type: int = _ANIMATION_TRACK_TYPES[track_type_name]

	var validation: Dictionary = PathValidator.validate_file_path(animation_path, [".tres", ".res", ".anim"])
	if not validation["valid"]:
		return {"error": "Invalid path: " + validation["error"]}
	animation_path = validation["sanitized"]

	if not ResourceLoader.exists(animation_path):
		return {"error": "Animation not found: " + animation_path}
	var animation: Animation = ResourceLoader.load(animation_path) as Animation
	if not animation:
		return {"error": "Resource is not an Animation: " + animation_path}

	var node_path: NodePath = NodePath(track_path)
	var created_track: bool = false
	var track_index: int = -1
	if bool(params.get("reuse_track", true)):
		track_index = animation.find_track(node_path, track_type)
	if track_index < 0:
		track_index = animation.add_track(track_type)
		animation.track_set_path(track_index, node_path)
		created_track = true

	var value_type: String = str(params.get("value_type", "")).strip_edges().to_lower()
	var keys_inserted: int = 0
	for entry in (keys as Array):
		if not (entry is Dictionary):
			return {"error": "Each key must be an object with 'time' and 'value'"}
		var key_dict: Dictionary = entry
		if not key_dict.has("time"):
			return {"error": "Each key must include 'time'"}
		if not key_dict.has("value"):
			return {"error": "Each key must include 'value'"}
		var time: float = float(key_dict["time"])
		if time < 0.0:
			return {"error": "Key 'time' must be >= 0"}
		var insert_result: Dictionary = _insert_animation_key(animation, track_index, track_type, track_type_name, time, key_dict["value"], value_type)
		if insert_result.has("error"):
			return insert_result
		keys_inserted += 1

	# Grow the animation length to fit inserted keys when needed.
	var track_end: float = animation.track_get_key_time(track_index, animation.track_get_key_count(track_index) - 1)
	if track_end > animation.length:
		animation.length = track_end

	var error: Error = ResourceSaver.save(animation, animation_path)
	if error != OK:
		return {"error": "Failed to save animation: " + error_string(error)}

	# 可选接线：把动画挂进当前编辑场景里的 AnimationPlayer（默认库名 ""、
	# 动画名 "anim"），供运行时 list/play 链使用。
	var attach_player: String = str(params.get("attach_player_node", "")).strip_edges()
	var attached_to: String = ""
	if not attach_player.is_empty():
		var editor_interface: EditorInterface = _workflow_editor_interface()
		if editor_interface == null:
			return {"error": "attach_player_node requires a live editor interface"}
		var player_node: Node = _workflow_resolve_node(editor_interface, attach_player)
		if player_node == null:
			return {"error": "AnimationPlayer node not found: " + attach_player}
		if not (player_node is AnimationPlayer):
			return {"error": "attach target is not an AnimationPlayer: " + attach_player}
		var player: AnimationPlayer = player_node as AnimationPlayer
		var anim_name: String = str(params.get("animation_name", "anim")).strip_edges()
		if anim_name.is_empty():
			anim_name = "anim"
		if player.has_animation_library(""):
			player.get_animation_library("").add_animation(anim_name, animation)
		else:
			var library := AnimationLibrary.new()
			library.add_animation(anim_name, animation)
			player.add_animation_library("", library)
		attached_to = attach_player
		editor_interface.mark_scene_as_unsaved()

	return {
		"status": "success",
		"animation_path": animation_path,
		"track_path": track_path,
		"track_type": track_type_name,
		"track_index": track_index,
		"keys_inserted": keys_inserted,
		"created_track": created_track,
		"attached_to": attached_to
	}

func _insert_animation_key(animation: Animation, track_index: int, track_type: int, track_type_name: String, time: float, raw_value: Variant, value_type: String) -> Dictionary:
	match track_type:
		Animation.TYPE_VALUE:
			var coerced: Dictionary = ProjectToolsNative._coerce_setting_value(raw_value, value_type)
			if coerced.has("error"):
				return coerced
			animation.track_insert_key(track_index, time, coerced["value"])
		Animation.TYPE_POSITION_3D, Animation.TYPE_SCALE_3D:
			var vec: Variant = ProjectToolsNative._parse_vector3(raw_value)
			if vec == null:
				return {"error": "Key value for %s must be a Vector3 ([x, y, z] or {x, y, z})" % track_type_name}
			if track_type == Animation.TYPE_POSITION_3D:
				animation.position_track_insert_key(track_index, time, vec)
			else:
				animation.scale_track_insert_key(track_index, time, vec)
		Animation.TYPE_ROTATION_3D:
			var quat: Variant = _parse_quaternion(raw_value)
			if quat == null:
				return {"error": "Key value for rotation_3d must be a quaternion ([x, y, z, w]) or euler angles ([x, y, z])"}
			animation.rotation_track_insert_key(track_index, time, quat)
		_:
			return {"error": "Unsupported track type"}
	return {}

static func _parse_quaternion(value: Variant) -> Variant:
	if value is Quaternion:
		return value
	if value is Dictionary:
		if value.has("w"):
			return Quaternion(float(value.get("x", 0.0)), float(value.get("y", 0.0)), float(value.get("z", 0.0)), float(value.get("w", 1.0)))
		return Quaternion.from_euler(Vector3(float(value.get("x", 0.0)), float(value.get("y", 0.0)), float(value.get("z", 0.0))))
	if value is Array:
		if value.size() >= 4:
			return Quaternion(float(value[0]), float(value[1]), float(value[2]), float(value[3]))
		if value.size() >= 3:
			return Quaternion.from_euler(Vector3(float(value[0]), float(value[1]), float(value[2])))
	return null


# ============================================================================
# manage_task_plan - durable task graph + Definition-of-Done store
# ============================================================================
#
# Persists the AI production loop's state (plan -> execute -> run -> verify ->
# fix) to a versioned JSON file (default res://.mcp/task_plan.json) so an agent
# can resume across sessions instead of re-deriving the plan from chat. All
# graph logic lives in TaskPlanStore (unit-tested); this handler only validates
# parameters, loads the plan, dispatches the action and saves the result.

const _TASK_PLAN_DEFAULT_PATH: String = "res://.mcp/task_plan.json"
const _TASK_PLAN_ACTIONS: Array = ["init", "add_task", "update_task", "set_status", "set_dod", "get", "next", "remove_task"]

func _register_manage_task_plan(server_core: RefCounted) -> void:
	var tool_name: String = "manage_task_plan"
	var description: String = "Persistent task graph + Definition-of-Done (DoD) in JSON (default res://.mcp/task_plan.json). Actions: init, add_task, update_task, set_status (done needs DoD unless force), set_dod, get, next, remove_task."

	var input_schema: Dictionary = {
		"type": "object",
		"properties": {
			"action": {"type": "string", "enum": _TASK_PLAN_ACTIONS, "description": "Operation."},
			"plan_path": {"type": "string", "description": "Plan path.", "default": _TASK_PLAN_DEFAULT_PATH},
			"goal": {"type": "string", "description": "Init goal."},
			"reset": {"type": "boolean", "description": "Init: reset.", "default": false},
			"id": {"type": "string", "description": "Task id."},
			"title": {"type": "string", "description": "Title."},
			"description": {"type": "string", "description": "Details."},
			"status": {"type": "string", "enum": TaskPlanStore.VALID_STATUSES, "description": "Status."},
			"depends_on": {"type": "array", "items": {"type": "string"}, "description": "Deps (cycle-checked)."},
			"dod": {"type": "array", "description": "DoD criteria."},
			"tags": {"type": "array", "items": {"type": "string"}, "description": "Tags."},
			"journal": {"type": "string", "description": "Journal."},
			"force": {"type": "boolean", "description": "Force done.", "default": false},
			"index": {"type": "integer", "description": "set_dod index."},
			"criterion": {"type": "string", "description": "set_dod text."},
			"met": {"type": "boolean", "description": "set_dod met."},
			"evidence": {"type": "string", "description": "set_dod evidence."},
			"gate": {"type": "object", "description": "set_dod gate."},
			"observed": {"type": "object", "description": "Metrics -> met."}
		},
		"required": ["action"]
	}

	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"status": {"type": "string"},
			"action": {"type": "string"},
			"plan_path": {"type": "string"},
			"plan": {"type": "object"},
			"task": {"type": "object"},
			"tasks": {"type": "array"},
			"ready": {"type": "array"},
			"blocked": {"type": "array"},
			"progress": {"type": "object"},
			"removed": {"type": "string"}
		}
	}

	var annotations: Dictionary = {
		"readOnlyHint": false,
		"destructiveHint": false,
		"idempotentHint": false,
		"openWorldHint": false
	}

	server_core.register_tool(tool_name, description, input_schema,
						  Callable(self, "_tool_manage_task_plan"),
						  output_schema, annotations,
						  "supplementary", "Project-Advanced")

func _tool_manage_task_plan(params: Dictionary) -> Dictionary:
	var action: String = str(params.get("action", "")).strip_edges()
	if action.is_empty():
		return {"error": "action is required"}
	if not (action in _TASK_PLAN_ACTIONS):
		return {"error": "Invalid action '%s'. Expected one of: %s" % [action, ", ".join(_TASK_PLAN_ACTIONS)]}

	var plan_path: String = str(params.get("plan_path", _TASK_PLAN_DEFAULT_PATH)).strip_edges()
	if plan_path.is_empty():
		plan_path = _TASK_PLAN_DEFAULT_PATH
	if not (plan_path.begins_with("res://") or plan_path.begins_with("user://")):
		return {"error": "plan_path must be a res:// or user:// path"}

	if action == "init":
		var store: TaskPlanStore = TaskPlanStore.new()
		if not bool(params.get("reset", false)) and TaskPlanStore.plan_exists(plan_path):
			var existing = TaskPlanStore.load_plan(plan_path)
			if existing is Dictionary and existing.has("error"):
				# Surface the load failure instead of overwriting a corrupted plan
				# with an empty one. Use reset=true to deliberately discard it.
				return existing
			if existing is Dictionary:
				store = TaskPlanStore.new(existing)
		store.init_plan(str(params.get("goal", "")), bool(params.get("reset", false)))
		var save_init: Dictionary = TaskPlanStore.save_plan(store.plan, plan_path)
		if save_init.has("error"):
			return save_init
		return {"status": "ok", "action": action, "plan_path": plan_path, "plan": store.plan, "progress": store.progress()}

	# All other actions require an existing plan.
	var loaded = TaskPlanStore.load_plan(plan_path)
	if not (loaded is Dictionary) or loaded.has("error"):
		return loaded if loaded is Dictionary else {"error": "could not load task plan"}
	var plan_store: TaskPlanStore = TaskPlanStore.new(loaded)

	var result: Dictionary = {}
	var mutated: bool = true
	match action:
		"add_task":
			result = plan_store.add_task(params)
		"update_task":
			var uid: String = str(params.get("id", "")).strip_edges()
			if uid.is_empty():
				return {"error": "id is required for update_task"}
			result = plan_store.update_task(uid, params)
		"set_status":
			var sid: String = str(params.get("id", "")).strip_edges()
			if sid.is_empty():
				return {"error": "id is required for set_status"}
			if not params.has("status"):
				return {"error": "status is required for set_status"}
			result = plan_store.set_status(sid, str(params["status"]).strip_edges(), bool(params.get("force", false)), str(params.get("journal", "")))
		"set_dod":
			var did: String = str(params.get("id", "")).strip_edges()
			if did.is_empty():
				return {"error": "id is required for set_dod"}
			result = plan_store.set_dod(did, params)
		"get":
			mutated = false
			var gid: String = str(params.get("id", "")).strip_edges()
			if gid.is_empty():
				result = {"status": "ok", "plan": plan_store.plan, "progress": plan_store.progress()}
			else:
				if not plan_store.has_task(gid):
					return {"error": "task '%s' not found" % gid}
				result = {"status": "ok", "task": plan_store.get_task(gid), "progress": plan_store.progress()}
		"next":
			mutated = false
			result = plan_store.next_actionable()
			result["status"] = "ok"
		"remove_task":
			var rid: String = str(params.get("id", "")).strip_edges()
			if rid.is_empty():
				return {"error": "id is required for remove_task"}
			result = plan_store.remove_task(rid)

	if result.has("error"):
		return result

	if mutated:
		var save_result: Dictionary = TaskPlanStore.save_plan(plan_store.plan, plan_path)
		if save_result.has("error"):
			return save_result
		result["progress"] = plan_store.progress()

	result["action"] = action
	result["plan_path"] = plan_path
	return result


# ============================================================================
# manage_localization - 本地化全流程（提取/导入/导出/列表）
# ============================================================================
# Godot 4.7 没有可在无头环境直接驱动的翻译流水线工具，AI 生成中文标题/角色描述
# 后无法把这些文本纳入翻译表。本工具用单个 action 入口覆盖完整本地化闭环：
#   - extract: 扫描场景(.tscn)的可翻译属性与脚本(.gd)中的 tr("...") → 提取唯一键，
#              写入/合并标准 CSV（保留已有译文，仅补新键）
#   - import:  读取 CSV → 每个 locale 生成 .translation → 注册到 ProjectSettings
#   - export:  把已注册（或显式指定）的 .translation 回读成 CSV（round-trip/巡检）
#   - list:    只读，列出已注册的 locale 与键数
# CSV 采用 Godot 标准格式（首列 keys，其余列为各 locale），与编辑器导入器互通。

const _I18N_DEFAULT_CSV: String = "res://localization/translations.csv"
const _I18N_TRANSLATIONS_SETTING: String = "internationalization/locale/translations"
# 与 Godot POT 提取一致的常见可翻译 Control/Window 属性。
const _I18N_TRANSLATABLE_PROPERTIES: Array = [
	"text", "tooltip_text", "placeholder_text", "title", "hint_tooltip"
]

func _register_manage_localization(server_core: RefCounted) -> void:
	var tool_name: String = "manage_localization"
	var description: String = "Localization workflow: 'extract' scans .tscn translatable properties (text/tooltip_text/placeholder_text/title/hint_tooltip) and .gd tr()/atr() calls, merging new keys into a standard CSV (first column keys, one per locale) while preserving existing translations; 'import' builds one .translation per locale from the CSV and registers it in ProjectSettings; 'export' writes registered .translations back to CSV; 'list' shows registered locales. Write actions support dry_run."

	var input_schema: Dictionary = {
		"type": "object",
		"properties": {
			"action": {"type": "string", "enum": ["list", "extract", "import", "export"], "description": "Operation: list/extract/import/export."},
			"csv_path": {"type": "string", "description": "CSV path.", "default": _I18N_DEFAULT_CSV},
			"scan_dir": {"type": "string", "description": "extract: scan root (recursive).", "default": "res://"},
			"include_scripts": {"type": "boolean", "description": "extract: also scan .gd scripts.", "default": true},
			"out_dir": {"type": "string", "description": "import: output dir for .translation files."},
			"register": {"type": "boolean", "description": "import: register in ProjectSettings.", "default": true},
			"translations_paths": {"type": "array", "items": {"type": "string"}, "description": "export: explicit .translation paths."},
			"dry_run": {"type": "boolean", "description": "Compute without writing.", "default": false}
		},
		"required": ["action"]
	}

	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"success": {"type": "boolean"},
			"action": {"type": "string"},
			"csv_path": {"type": "string"},
			"locales": {"type": "array"},
			"key_count": {"type": "integer"},
			"found_count": {"type": "integer"},
			"new_count": {"type": "integer"},
			"new_keys": {"type": "array"},
			"written": {"type": "array"},
			"registered": {"type": "boolean"},
			"translations": {"type": "array"},
			"count": {"type": "integer"},
			"dry_run": {"type": "boolean"}
		}
	}

	var annotations: Dictionary = {
		"readOnlyHint": false,
		"destructiveHint": false,
		"idempotentHint": false,
		"openWorldHint": false
	}

	server_core.register_tool(tool_name, description, input_schema,
											  Callable(self, "_tool_manage_localization"),
											  output_schema, annotations,
											  "supplementary", "Project-Advanced")

func _tool_manage_localization(params: Dictionary) -> Dictionary:
	var action: String = str(params.get("action", "")).strip_edges()
	if action.is_empty():
		return {"error": "action is required (list|extract|import|export)"}
	match action:
		"list":
			return _i18n_list(params)
		"extract":
			return _i18n_extract(params)
		"import":
			return _i18n_import(params)
		"export":
			return _i18n_export(params)
		_:
			return {"error": "unknown action '%s' (expected list|extract|import|export)" % action}

func _i18n_registered_paths() -> PackedStringArray:
	var raw: Variant = ProjectSettings.get_setting(_I18N_TRANSLATIONS_SETTING, PackedStringArray())
	var out: PackedStringArray = PackedStringArray()
	if raw is PackedStringArray:
		out = raw
	elif raw is Array:
		for item in raw:
			out.append(str(item))
	return out

func _i18n_list(_params: Dictionary) -> Dictionary:
	var paths: PackedStringArray = _i18n_registered_paths()
	var entries: Array = []
	for p in paths:
		var entry: Dictionary = {"path": p, "locale": "", "key_count": 0, "loaded": false}
		if ResourceLoader.exists(p):
			var res: Resource = ResourceLoader.load(p)
			if res is Translation:
				entry["locale"] = res.locale
				entry["key_count"] = res.get_message_list().size()
				entry["loaded"] = true
		entries.append(entry)
	return {
		"success": true,
		"action": "list",
		"translations": entries,
		"count": entries.size()
	}

func _i18n_collect_files(root: String, extensions: PackedStringArray) -> PackedStringArray:
	var results: PackedStringArray = PackedStringArray()
	var stack: Array = [root]
	while not stack.is_empty():
		var current: String = str(stack.pop_back())
		var dir: DirAccess = DirAccess.open(current)
		if dir == null:
			continue
		dir.list_dir_begin()
		var name: String = dir.get_next()
		while name != "":
			if name.begins_with("."):
				name = dir.get_next()
				continue
			var full: String = current.path_join(name)
			if dir.current_is_dir():
				stack.append(full)
			else:
				for ext in extensions:
					if name.to_lower().ends_with(ext):
						results.append(full)
						break
			name = dir.get_next()
		dir.list_dir_end()
	return results

func _i18n_unescape(value: String) -> String:
	# .tscn / GDScript 字符串字面量的常见转义还原。
	# 单遍扫描：遇到反斜杠时按下一个字符决定替换，避免多遍 replace 把
	# `\\n`（转义反斜杠 + 字母 n）误判成换行。
	var out: String = ""
	var i: int = 0
	var n: int = value.length()
	while i < n:
		var c: String = value[i]
		if c == "\\" and i + 1 < n:
			var nxt: String = value[i + 1]
			match nxt:
				"n":
					out += "\n"
				"t":
					out += "\t"
				"\"":
					out += "\""
				"'":
					out += "'"
				"\\":
					out += "\\"
				_:
					out += c + nxt
			i += 2
		else:
			out += c
			i += 1
	return out

func _i18n_extract(params: Dictionary) -> Dictionary:
	var scan_dir: String = str(params.get("scan_dir", "res://")).strip_edges()
	if scan_dir.is_empty():
		scan_dir = "res://"
	if not DirAccess.dir_exists_absolute(scan_dir):
		return {"error": "scan_dir does not exist: " + scan_dir}

	var csv_path: String = str(params.get("csv_path", _I18N_DEFAULT_CSV)).strip_edges()
	if csv_path.is_empty():
		csv_path = _I18N_DEFAULT_CSV
	var include_scripts: bool = bool(params.get("include_scripts", true))
	var dry_run: bool = bool(params.get("dry_run", false))

	var found: Dictionary = {}  # key -> true，用作有序唯一集合

	var prop_re: RegEx = RegEx.new()
	# 匹配 .tscn 中形如  text = "..."  的可翻译属性赋值。
	prop_re.compile("^\\s*(%s)\\s*=\\s*\"((?:[^\"\\\\]|\\\\.)*)\"" % "|".join(PackedStringArray(_I18N_TRANSLATABLE_PROPERTIES)))
	var scenes: PackedStringArray = _i18n_collect_files(scan_dir, PackedStringArray([".tscn"]))
	for scene_path in scenes:
		var f: FileAccess = FileAccess.open(scene_path, FileAccess.READ)
		if f == null:
			continue
		while not f.eof_reached():
			var line: String = f.get_line()
			var m: RegExMatch = prop_re.search(line)
			if m:
				var val: String = _i18n_unescape(m.get_string(2))
				if not val.strip_edges().is_empty():
					found[val] = true
		f.close()

	if include_scripts:
		var tr_re: RegEx = RegEx.new()
		# 匹配 tr("...") / atr("...")（含转义引号）。
		tr_re.compile("\\b(?:tr|atr)\\(\\s*\"((?:[^\"\\\\]|\\\\.)*)\"")
		var scripts: PackedStringArray = _i18n_collect_files(scan_dir, PackedStringArray([".gd"]))
		for script_path in scripts:
			var sf: FileAccess = FileAccess.open(script_path, FileAccess.READ)
			if sf == null:
				continue
			var text: String = sf.get_as_text()
			sf.close()
			for tm in tr_re.search_all(text):
				var key: String = _i18n_unescape(tm.get_string(1))
				if not key.strip_edges().is_empty():
					found[key] = true

	# 读取已有 CSV，保留译文与已有键。
	var header: PackedStringArray = PackedStringArray(["keys"])
	var existing_rows: Array = []  # 每行是 PackedStringArray
	var existing_keys: Dictionary = {}
	if FileAccess.file_exists(csv_path):
		var ef: FileAccess = FileAccess.open(csv_path, FileAccess.READ)
		if ef:
			var first: bool = true
			while not ef.eof_reached():
				var cols: PackedStringArray = ef.get_csv_line()
				if cols.size() == 1 and cols[0] == "":
					continue
				if first:
					if cols.size() >= 1 and cols[0] == "keys":
						header = cols
					first = false
					continue
				if cols.size() >= 1 and not cols[0].is_empty():
					existing_rows.append(cols)
					existing_keys[cols[0]] = true
			ef.close()

	var locale_cols: int = max(header.size() - 1, 0)
	if locale_cols == 0:
		# 无语言列的表无法被 import 接受（表头必须 keys,<locale>,...）：
		# 默认补 "en"，保证 extract → import 链在空项目上也能走通。
		header.append("en")
		locale_cols = 1
	var new_keys: Array = []
	for key in found.keys():
		if not existing_keys.has(key):
			new_keys.append(key)

	var found_count: int = found.size()
	var new_count: int = new_keys.size()
	var total_count: int = existing_rows.size() + new_count

	if not dry_run:
		var base_dir: String = csv_path.get_base_dir()
		if not base_dir.is_empty() and not DirAccess.dir_exists_absolute(base_dir):
			DirAccess.make_dir_recursive_absolute(base_dir)
		var wf: FileAccess = FileAccess.open(csv_path, FileAccess.WRITE)
		if wf == null:
			return {"error": "Failed to open CSV for writing: " + csv_path}
		wf.store_csv_line(header)
		for row in existing_rows:
			wf.store_csv_line(row)
		for key in new_keys:
			var row: PackedStringArray = PackedStringArray([str(key)])
			for i in range(locale_cols):
				row.append("")
			wf.store_csv_line(row)
		wf.close()

	return {
		"success": true,
		"action": "extract",
		"csv_path": csv_path,
		"found_count": found_count,
		"new_count": new_count,
		"key_count": total_count,
		"new_keys": new_keys,
		"dry_run": dry_run
	}

func _i18n_import(params: Dictionary) -> Dictionary:
	var csv_path: String = str(params.get("csv_path", _I18N_DEFAULT_CSV)).strip_edges()
	if csv_path.is_empty():
		csv_path = _I18N_DEFAULT_CSV
	if not FileAccess.file_exists(csv_path):
		return {"error": "CSV not found: " + csv_path}

	var dry_run: bool = bool(params.get("dry_run", false))
	var do_register: bool = bool(params.get("register", true))
	var out_dir: String = str(params.get("out_dir", "")).strip_edges()
	if out_dir.is_empty():
		out_dir = csv_path.get_base_dir()
	if out_dir.is_empty():
		out_dir = "res://"

	var f: FileAccess = FileAccess.open(csv_path, FileAccess.READ)
	if f == null:
		return {"error": "Failed to open CSV: " + csv_path}

	var header: PackedStringArray = PackedStringArray()
	var rows: Array = []
	var first: bool = true
	while not f.eof_reached():
		var cols: PackedStringArray = f.get_csv_line()
		if cols.size() == 1 and cols[0] == "":
			continue
		if first:
			header = cols
			first = false
			continue
		if cols.size() >= 1 and not cols[0].is_empty():
			rows.append(cols)
	f.close()

	if header.size() < 2:
		return {"error": "CSV header must be 'keys,<locale>,...'; found " + str(header.size()) + " column(s)"}
	if str(header[0]) != "keys":
		return {"error": "CSV first column must be 'keys', got '" + str(header[0]) + "'"}

	var locales: Array = []
	for i in range(1, header.size()):
		locales.append(str(header[i]))

	var written: Array = []
	var translation_paths: PackedStringArray = PackedStringArray()
	var key_count: int = rows.size()

	if not dry_run:
		if not DirAccess.dir_exists_absolute(out_dir):
			DirAccess.make_dir_recursive_absolute(out_dir)

	for col_index in range(1, header.size()):
		var locale: String = str(header[col_index])
		var translation: Translation = Translation.new()
		translation.locale = locale
		for row in rows:
			var key: String = str(row[0])
			var value: String = str(row[col_index]) if col_index < row.size() else ""
			translation.add_message(key, value)
		var tpath: String = out_dir.path_join(locale + ".translation")
		translation_paths.append(tpath)
		if not dry_run:
			var save_err: Error = ResourceSaver.save(translation, tpath)
			if save_err != OK:
				return {"error": "Failed to save translation for locale '%s': %s" % [locale, error_string(save_err)]}
			written.append(tpath)

	var registered: bool = false
	if do_register and not dry_run:
		var existing: PackedStringArray = _i18n_registered_paths()
		for tp in translation_paths:
			if not existing.has(tp):
				existing.append(tp)
		ProjectSettings.set_setting(_I18N_TRANSLATIONS_SETTING, existing)
		var ps_err: Error = ProjectSettings.save()
		if ps_err != OK:
			return {"error": "Failed to save project.godot: " + error_string(ps_err)}
		registered = true

	return {
		"success": true,
		"action": "import",
		"csv_path": csv_path,
		"locales": locales,
		"key_count": key_count,
		"written": written,
		"registered": registered,
		"dry_run": dry_run
	}

func _i18n_export(params: Dictionary) -> Dictionary:
	var csv_path: String = str(params.get("csv_path", _I18N_DEFAULT_CSV)).strip_edges()
	if csv_path.is_empty():
		csv_path = _I18N_DEFAULT_CSV
	var dry_run: bool = bool(params.get("dry_run", false))

	var paths: PackedStringArray = PackedStringArray()
	if params.has("translations_paths") and params["translations_paths"] is Array:
		for item in params["translations_paths"]:
			paths.append(str(item))
	else:
		paths = _i18n_registered_paths()

	if paths.is_empty():
		return {"error": "no .translation paths to export (none registered and none provided)"}

	var locales: Array = []
	var messages: Dictionary = {}  # locale -> {key: value}
	var key_order: Array = []
	var key_seen: Dictionary = {}
	for p in paths:
		if not ResourceLoader.exists(p):
			return {"error": "translation file not found: " + p}
		var res: Resource = ResourceLoader.load(p)
		if not (res is Translation):
			return {"error": "not a Translation resource: " + p}
		var locale: String = res.locale
		if locale.is_empty():
			locale = p.get_file().get_basename()
		if not locales.has(locale):
			locales.append(locale)
			messages[locale] = {}
		for key in res.get_message_list():
			var ks: String = str(key)
			messages[locale][ks] = res.get_message(key)
			if not key_seen.has(ks):
				key_seen[ks] = true
				key_order.append(ks)

	if not dry_run:
		var base_dir: String = csv_path.get_base_dir()
		if not base_dir.is_empty() and not DirAccess.dir_exists_absolute(base_dir):
			DirAccess.make_dir_recursive_absolute(base_dir)
		var wf: FileAccess = FileAccess.open(csv_path, FileAccess.WRITE)
		if wf == null:
			return {"error": "Failed to open CSV for writing: " + csv_path}
		var header: PackedStringArray = PackedStringArray(["keys"])
		for locale in locales:
			header.append(str(locale))
		wf.store_csv_line(header)
		for key in key_order:
			var row: PackedStringArray = PackedStringArray([str(key)])
			for locale in locales:
				row.append(str(messages[locale].get(key, "")))
			wf.store_csv_line(row)
		wf.close()

	return {
		"success": true,
		"action": "export",
		"csv_path": csv_path,
		"locales": locales,
		"key_count": key_order.size(),
		"dry_run": dry_run
	}
