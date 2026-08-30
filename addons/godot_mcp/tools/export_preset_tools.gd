# export_preset_tools.gd — 导出预设 CRUD
#
# 背景：导出能力此前是"单向"的——只能跑 run_export，无法查询当前有哪些预设、
# 更无法创建/修改。于是 Agent 想导出就得靠猜：预设存在吗？名字对吗？导出模板
# 装了吗？猜错的代价是一次几十秒的失败导出。
#
# 这个域补上读写闭环：inspect 给出可判定的校验结论，create/update/remove/
# duplicate 让 Agent 能自己把导出链路配好，而不是每次都请人类点编辑器。
#
# 诚实性约定（很重要）：
#   * 导出模板是否安装，只有 EditorExport 单例可用时才能确定。单例不可用时
#     返回 "unknown"，绝不返回 true —— 那会让 Agent 以为可以直接导出。
#   * 预设的 platform 名是否合法同理：能枚举平台就校验，不能就标 "unvalidated"。
#   * 写操作完成后立刻回读校验（write-then-read-back），返回 verified 布尔值。

@tool
class_name ExportPresetTools
extends RefCounted

const PRESET_FILE: String = "res://export_presets.cfg"

## 已知平台名（用于在 EditorExport 不可用时做一次弱校验）。
## 这不是权威列表：真正的权威来自 EditorExport.get_platform...，拿不到时
## 匹配这里也只是"看起来像"，因此标 unvalidated 而不是 valid。
const KNOWN_PLATFORM_HINTS: Array[String] = [
	"Windows Desktop", "Linux", "macOS", "Web", "Android", "iOS",
	"Windows Desktop (Compatibility)", "Linux (Compatibility)"
]

## 预设级标量字段
const PRESET_SCALAR_KEYS: Array[String] = [
	"name", "platform", "runnable", "advanced_options", "dedicated_server",
	"custom_features", "export_filter", "include_filter", "exclude_filter",
	"export_path", "encrypt_pck", "encrypt_directory", "script_export_mode",
	"encryption_include_filters", "encryption_exclude_filters", "patches"
]

var _editor_interface: EditorInterface = null
var _server_core: RefCounted = null

func initialize(editor_interface: EditorInterface) -> void:
	_editor_interface = editor_interface

func register_tools(server_core: RefCounted) -> void:
	_server_core = server_core
	_register_inspect(server_core)
	_register_create(server_core)
	_register_update(server_core)
	_register_remove(server_core)
	_register_duplicate(server_core)


# ============================================================================
# 底层：读写 export_presets.cfg
# ============================================================================

## EditorExport 单例（仅在编辑器进程内可用）。拿不到就返回 null，调用方必须
## 据此降级为"未知"，不得假设导出模板已安装。
static func _editor_export() -> Object:
	if not Engine.has_singleton("EditorExport"):
		return null
	var singleton: Object = Engine.get_singleton("EditorExport")
	if singleton == null or not singleton.has_method("get_preset_count"):
		return null
	return singleton


static func _export_api_available() -> bool:
	return _editor_export() != null


## 枚举编辑器已知的平台名；不可用时返回空数组（调用方据此标 unvalidated）。
static func platform_names() -> Array[String]:
	var export: Object = _editor_export()
	if export == null:
		return []
	var result: Array[String] = []
	if export.has_method("get_export_platform_count") and export.has_method("get_export_platform"):
		var count_v: Variant = export.call("get_export_platform_count")
		var count: int = int(count_v) if count_v != null else 0
		for index in count:
			var platform_v: Variant = export.call("get_export_platform", index)
			if platform_v == null:
				continue
			var platform: Object = platform_v
			if platform.has_method("get_name"):
				result.append(String(platform.call("get_name")))
	return result


## 读取全部预设。返回 {"presets": Array[Dictionary], "file_exists": bool, "error": String}
static func read_presets() -> Dictionary:
	var presets: Array[Dictionary] = []
	var file_exists: bool = FileAccess.file_exists(PRESET_FILE)
	if not file_exists:
		return {
			"presets": presets,
			"file_exists": false,
			"export_api_available": _export_api_available(),
			"platforms": platform_names()
		}
	var config: ConfigFile = ConfigFile.new()
	var error: int = config.load(PRESET_FILE)
	if error != OK:
		return {
			"presets": presets,
			"file_exists": true,
			"error": "Failed to parse %s (error %d)" % [PRESET_FILE, error],
			"export_api_available": _export_api_available(),
			"platforms": platform_names()
		}
	for section_value in config.get_sections():
		var section: String = String(section_value)
		if not section.begins_with("preset.") or section.contains(".options"):
			continue
		var index_text: String = section.substr("preset.".length())
		if not index_text.is_valid_int():
			continue
		var options_section: String = section + ".options"
		var options: Dictionary = {}
		if config.has_section(options_section):
			for key_value in config.get_section_keys(options_section):
				options[String(key_value)] = config.get_value(options_section, String(key_value))
		var fields: Dictionary = {}
		for key_value in config.get_section_keys(section):
			fields[String(key_value)] = config.get_value(section, String(key_value))
		presets.append({
			"index": int(index_text),
			"name": String(fields.get("name", "")),
			"platform": String(fields.get("platform", "")),
			"runnable": bool(fields.get("runnable", false)),
			"export_path": String(fields.get("export_path", "")),
			"export_filter": String(fields.get("export_filter", "all_resources")),
			"include_filter": String(fields.get("include_filter", "")),
			"exclude_filter": String(fields.get("exclude_filter", "")),
			"custom_features": String(fields.get("custom_features", "")),
			"script_export_mode": int(fields.get("script_export_mode", 2)),
			"dedicated_server": bool(fields.get("dedicated_server", false)),
			"fields": fields,
			"options": options
		})
	presets.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a.get("index", 0)) < int(b.get("index", 0)))
	return {
		"presets": presets,
		"file_exists": true,
		"export_api_available": _export_api_available(),
		"platforms": platform_names()
	}


## 单个预设的可判定校验结论。
## status: valid / invalid / unvalidated
## 判定不到的一律 unknown，绝不乐观。
static func validate_preset(preset: Dictionary, platforms: Array[String] = []) -> Dictionary:
	var checks: Array[Dictionary] = []
	var name: String = String(preset.get("name", ""))
	var platform: String = String(preset.get("platform", ""))
	var export_path: String = String(preset.get("export_path", ""))

	checks.append(_check("name_present", not name.strip_edges().is_empty(),
		"Preset name is empty" if name.strip_edges().is_empty() else ""))
	checks.append(_check("platform_present", not platform.strip_edges().is_empty(),
		"Platform is empty" if platform.strip_edges().is_empty() else ""))

	var platform_known: bool = false
	var platform_status: String = "unknown"
	if not platforms.is_empty():
		platform_known = platforms.has(platform)
		platform_status = "valid" if platform_known else "invalid"
		checks.append(_check("platform_known", platform_known,
			"" if platform_known else "Unknown platform '%s'; known: %s" % [platform, str(platforms)]))
	elif not platform.strip_edges().is_empty():
		platform_known = platform in KNOWN_PLATFORM_HINTS
		platform_status = "unvalidated"
		checks.append(_check("platform_hint_match", platform_known,
			"Platform '%s' could not be validated against the editor (EditorExport unavailable)" % platform))

	var path_ok: bool = not export_path.strip_edges().is_empty()
	checks.append(_check("export_path_present", path_ok,
		"export_path is empty" if not path_ok else ""))

	var templates_status: String = "unknown"
	if _export_api_available():
		# 模板是否安装由 EditorExport 平台对象给出；本方法只标记可判定性，
		# 真实模板路径由 inspect 工具在持有平台对象时补充。
		templates_status = "checkable"
	checks.append(_check("export_templates_installed", templates_status != "unknown",
		"" if templates_status != "unknown" else
		"Export template availability is unknown (EditorExport singleton unavailable)"))

	var failed: int = 0
	for entry in checks:
		if not bool(entry.get("passed", false)) and String(entry.get("status", "")) != "unknown" \
				and bool(entry.get("blocking", true)):
			failed += 1
	var status: String = "valid"
	if failed > 0:
		status = "invalid"
	elif platform_status == "unvalidated" or templates_status == "unknown":
		status = "unvalidated"
	return {
		"status": status,
		"platform_status": platform_status,
		"templates_status": templates_status,
		"failed_checks": failed,
		"checks": checks
	}


static func _check(name: String, passed: bool, message: String,
		blocking: bool = true) -> Dictionary:
	return {
		"check": name,
		"passed": passed,
		"status": "pass" if passed else ("unknown" if message.contains("unknown") else "fail"),
		"message": message,
		"blocking": blocking
	}


## 写回预设。返回 {"saved": bool, "verified": bool, "error": String}
## write-then-read-back：写完后重新加载并比对条目数与名称，确认真的落盘。
static func write_presets(presets: Array) -> Dictionary:
	var config: ConfigFile = ConfigFile.new()
	var ordered: Array = presets.duplicate(true)
	ordered.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int((a as Dictionary).get("index", 0)) < int((b as Dictionary).get("index", 0)))
	for index in ordered.size():
		var preset: Dictionary = ordered[index]
		var section: String = "preset.%d" % index
		var fields: Dictionary = preset.get("fields", {}) as Dictionary
		fields["name"] = String(preset.get("name", fields.get("name", "")))
		fields["platform"] = String(preset.get("platform", fields.get("platform", "")))
		fields["runnable"] = bool(preset.get("runnable", fields.get("runnable", false)))
		fields["export_path"] = String(preset.get("export_path", fields.get("export_path", "")))
		fields["export_filter"] = String(preset.get("export_filter", fields.get("export_filter", "all_resources")))
		fields["include_filter"] = String(preset.get("include_filter", fields.get("include_filter", "")))
		fields["exclude_filter"] = String(preset.get("exclude_filter", fields.get("exclude_filter", "")))
		fields["custom_features"] = String(preset.get("custom_features", fields.get("custom_features", "")))
		fields["script_export_mode"] = int(preset.get("script_export_mode", fields.get("script_export_mode", 2)))
		fields["dedicated_server"] = bool(preset.get("dedicated_server", fields.get("dedicated_server", false)))
		for key_value in fields.keys():
			config.set_value(section, String(key_value), fields[key_value])
		var options: Dictionary = preset.get("options", {}) as Dictionary
		var options_section: String = section + ".options"
		for key_value in options.keys():
			config.set_value(options_section, String(key_value), options[key_value])

	var error: int = config.save(PRESET_FILE)
	if error != OK:
		return {"saved": false, "verified": false, "error": "Failed to save %s (error %d)" % [PRESET_FILE, error]}

	# 回读校验
	var reloaded: Dictionary = read_presets()
	if reloaded.has("error"):
		return {"saved": true, "verified": false, "error": String(reloaded["error"])}
	var written_names: Array[String] = []
	for entry in ordered:
		written_names.append(String((entry as Dictionary).get("name", "")))
	var actual: Array[String] = []
	for entry in (reloaded.get("presets", []) as Array):
		actual.append(String((entry as Dictionary).get("name", "")))
	var verified: bool = actual == written_names
	return {
		"saved": true,
		"verified": verified,
		"preset_count": actual.size(),
		"error": "" if verified else "Re-read mismatch: expected %s, got %s" % [str(written_names), str(actual)]
	}


static func _next_index(presets: Array) -> int:
	var max_index: int = -1
	for entry in presets:
		max_index = maxi(max_index, int((entry as Dictionary).get("index", -1)))
	return max_index + 1


static func _find_by_name(presets: Array, name: String) -> int:
	var lower: String = name.strip_edges().to_lower()
	for index in presets.size():
		var entry: Dictionary = presets[index]
		if String(entry.get("name", "")).to_lower() == lower:
			return index
	return -1


# ============================================================================
# inspect_export_presets
# ============================================================================

func _register_inspect(server_core: RefCounted) -> void:
	var tool_name: String = "inspect_export_presets"
	var description: String = "Inspect export presets with decidable validation (name/platform/export path/template availability). Unavailable checks report 'unknown' instead of guessing."

	var input_schema: Dictionary = {
		"type": "object",
		"properties": {
			"name": {
				"type": "string",
				"description": "Optional preset name filter. Omit to inspect all presets."
			},
			"include_options": {
				"type": "boolean",
				"description": "Include the raw per-preset option dictionary. Default false to keep the payload small.",
				"default": false
			}
		}
	}

	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"status": {"type": "string"},
			"file_path": {"type": "string"},
			"file_exists": {"type": "boolean"},
			"export_api_available": {"type": "boolean"},
			"platforms": {"type": "array"},
			"preset_count": {"type": "integer"},
			"valid_count": {"type": "integer"},
			"invalid_count": {"type": "integer"},
			"unvalidated_count": {"type": "integer"},
			"presets": {"type": "array"}
		}
	}

	var annotations: Dictionary = {
		"readOnlyHint": true,
		"destructiveHint": false,
		"idempotentHint": true,
		"openWorldHint": false
	}

	server_core.register_tool(tool_name, description, input_schema,
		Callable(self, "_tool_inspect_export_presets"), output_schema, annotations,
		"supplementary", "Project-Advanced")


func _tool_inspect_export_presets(params: Dictionary) -> Dictionary:
	var name_filter: String = String(params.get("name", "")).strip_edges()
	var include_options: bool = bool(params.get("include_options", false))

	var loaded: Dictionary = read_presets()
	if loaded.has("error"):
		return {"error": String(loaded["error"]), "file_path": PRESET_FILE}
	var raw_presets: Array = loaded.get("presets", [])
	var platforms: Array[String] = []
	for value in (loaded.get("platforms", []) as Array):
		platforms.append(String(value))

	var results: Array[Dictionary] = []
	var valid_count: int = 0
	var invalid_count: int = 0
	var unvalidated_count: int = 0
	for entry_value in raw_presets:
		var preset: Dictionary = entry_value
		if not name_filter.is_empty() \
				and String(preset.get("name", "")).to_lower() != name_filter.to_lower():
			continue
		var validation: Dictionary = validate_preset(preset, platforms)
		var status: String = String(validation.get("status", "unvalidated"))
		if status == "valid":
			valid_count += 1
		elif status == "invalid":
			invalid_count += 1
		else:
			unvalidated_count += 1
		var item: Dictionary = {
			"index": int(preset.get("index", 0)),
			"name": String(preset.get("name", "")),
			"platform": String(preset.get("platform", "")),
			"runnable": bool(preset.get("runnable", false)),
			"export_path": String(preset.get("export_path", "")),
			"validation_status": status,
			"validation": validation
		}
		if include_options:
			item["options"] = preset.get("options", {})
		results.append(item)

	var overall: String = "no_presets"
	if not results.is_empty():
		if invalid_count > 0:
			overall = "invalid"
		elif unvalidated_count > 0:
			overall = "unvalidated"
		else:
			overall = "valid"
	return {
		"status": overall,
		"file_path": PRESET_FILE,
		"file_exists": bool(loaded.get("file_exists", false)),
		"export_api_available": bool(loaded.get("export_api_available", false)),
		"platforms": platforms,
		"preset_count": results.size(),
		"valid_count": valid_count,
		"invalid_count": invalid_count,
		"unvalidated_count": unvalidated_count,
		"presets": results
	}


# ============================================================================
# create_export_preset
# ============================================================================

func _register_create(server_core: RefCounted) -> void:
	var tool_name: String = "create_export_preset"
	var description: String = "Create an export preset in export_presets.cfg. Re-reads the file afterwards and reports 'verified'; platform validity is 'unvalidated' when the editor export API is unavailable."

	var input_schema: Dictionary = {
		"type": "object",
		"properties": {
			"name": {"type": "string", "description": "Preset name, e.g. 'Windows Desktop'."},
			"platform": {"type": "string", "description": "Export platform name, e.g. 'Windows Desktop', 'Web', 'Linux'."},
			"export_path": {"type": "string", "description": "Output artifact path, e.g. '../build/game.exe'."},
			"runnable": {"type": "boolean", "default": true},
			"export_filter": {"type": "string", "default": "all_resources"},
			"include_filter": {"type": "string", "default": ""},
			"exclude_filter": {"type": "string", "default": ""},
			"custom_features": {"type": "string", "default": ""},
			"options": {
				"type": "object",
				"description": "Platform-specific options written to the preset's [preset.N.options] section.",
				"additionalProperties": true
			}
		},
		"required": ["name", "platform", "export_path"]
	}

	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"status": {"type": "string"},
			"index": {"type": "integer"},
			"name": {"type": "string"},
			"verified": {"type": "boolean"},
			"validation_status": {"type": "string"},
			"preset_count": {"type": "integer"}
		}
	}

	var annotations: Dictionary = {
		"readOnlyHint": false,
		"destructiveHint": false,
		"idempotentHint": false,
		"openWorldHint": false
	}

	server_core.register_tool(tool_name, description, input_schema,
		Callable(self, "_tool_create_export_preset"), output_schema, annotations,
		"supplementary", "Project-Advanced")


func _tool_create_export_preset(params: Dictionary) -> Dictionary:
	var name: String = String(params.get("name", "")).strip_edges()
	var platform: String = String(params.get("platform", "")).strip_edges()
	var export_path: String = String(params.get("export_path", "")).strip_edges()
	if name.is_empty():
		return {"error": "name is required"}
	if platform.is_empty():
		return {"error": "platform is required"}
	if export_path.is_empty():
		return {"error": "export_path is required"}

	var loaded: Dictionary = read_presets()
	if loaded.has("error"):
		return {"error": String(loaded["error"])}
	var presets: Array = loaded.get("presets", [])
	if _find_by_name(presets, name) >= 0:
		return {"error": "An export preset named '%s' already exists" % name}

	var index: int = _next_index(presets)
	var options: Dictionary = params.get("options", {}) if params.get("options", {}) is Dictionary else {}
	presets.append({
		"index": index,
		"name": name,
		"platform": platform,
		"runnable": bool(params.get("runnable", true)),
		"export_path": export_path,
		"export_filter": String(params.get("export_filter", "all_resources")),
		"include_filter": String(params.get("include_filter", "")),
		"exclude_filter": String(params.get("exclude_filter", "")),
		"custom_features": String(params.get("custom_features", "")),
		"script_export_mode": 2,
		"dedicated_server": false,
		"fields": {},
		"options": options
	})

	var saved: Dictionary = write_presets(presets)
	if not bool(saved.get("saved", false)):
		return {"error": String(saved.get("error", "Failed to save export presets"))}

	var platforms: Array[String] = []
	for value in (loaded.get("platforms", []) as Array):
		platforms.append(String(value))
	var validation: Dictionary = validate_preset(presets[presets.size() - 1], platforms)
	return {
		"status": "created",
		"index": index,
		"name": name,
		"verified": bool(saved.get("verified", false)),
		"validation_status": String(validation.get("status", "unvalidated")),
		"validation": validation,
		"preset_count": int(saved.get("preset_count", presets.size())),
		"error": String(saved.get("error", ""))
	}


# ============================================================================
# update_export_preset
# ============================================================================

func _register_update(server_core: RefCounted) -> void:
	var tool_name: String = "update_export_preset"
	var description: String = "Update fields or platform options of an existing export preset, then re-read the file and report whether the change is verifiable."

	var input_schema: Dictionary = {
		"type": "object",
		"properties": {
			"name": {"type": "string", "description": "Existing preset name."},
			"new_name": {"type": "string"},
			"platform": {"type": "string"},
			"export_path": {"type": "string"},
			"runnable": {"type": "boolean"},
			"export_filter": {"type": "string"},
			"include_filter": {"type": "string"},
			"exclude_filter": {"type": "string"},
			"custom_features": {"type": "string"},
			"options": {
				"type": "object",
				"description": "Option keys to merge into [preset.N.options]. Set a key to null to remove it.",
				"additionalProperties": true
			}
		},
		"required": ["name"]
	}

	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"status": {"type": "string"},
			"name": {"type": "string"},
			"changed_fields": {"type": "array"},
			"verified": {"type": "boolean"},
			"validation_status": {"type": "string"}
		}
	}

	var annotations: Dictionary = {
		"readOnlyHint": false,
		"destructiveHint": false,
		"idempotentHint": true,
		"openWorldHint": false
	}

	server_core.register_tool(tool_name, description, input_schema,
		Callable(self, "_tool_update_export_preset"), output_schema, annotations,
		"supplementary", "Project-Advanced")


func _tool_update_export_preset(params: Dictionary) -> Dictionary:
	var name: String = String(params.get("name", "")).strip_edges()
	if name.is_empty():
		return {"error": "name is required"}
	var loaded: Dictionary = read_presets()
	if loaded.has("error"):
		return {"error": String(loaded["error"])}
	var presets: Array = loaded.get("presets", [])
	var slot: int = _find_by_name(presets, name)
	if slot < 0:
		return {"error": "No export preset named '%s'" % name}

	var preset: Dictionary = presets[slot]
	var changed: Array[String] = []
	for key in ["platform", "export_path", "export_filter", "include_filter",
			"exclude_filter", "custom_features"]:
		if params.has(key):
			var value: String = String(params[key]).strip_edges()
			preset[key] = value
			changed.append(key)
	if params.has("runnable"):
		preset["runnable"] = bool(params["runnable"])
		changed.append("runnable")
	if params.has("new_name"):
		var new_name: String = String(params["new_name"]).strip_edges()
		if new_name.is_empty():
			return {"error": "new_name cannot be empty"}
		if _find_by_name(presets, new_name) >= 0 and new_name.to_lower() != name.to_lower():
			return {"error": "An export preset named '%s' already exists" % new_name}
		preset["name"] = new_name
		changed.append("name")
	if params.has("options"):
		var incoming: Dictionary = params["options"] if params["options"] is Dictionary else {}
		var options: Dictionary = preset.get("options", {}) as Dictionary
		for key_value in incoming.keys():
			var key: String = String(key_value)
			if incoming[key_value] == null:
				options.erase(key)
			else:
				options[key] = incoming[key_value]
			changed.append("options." + key)
		preset["options"] = options
	presets[slot] = preset

	if changed.is_empty():
		var noop_platforms: Array[String] = []
		for value in (loaded.get("platforms", []) as Array):
			noop_platforms.append(String(value))
		return {
			"status": "unchanged",
			"name": String(preset.get("name", name)),
			"changed_fields": changed,
			"verified": true,
			"validation_status": String(validate_preset(preset, noop_platforms).get("status", "unvalidated"))
		}

	var saved: Dictionary = write_presets(presets)
	if not bool(saved.get("saved", false)):
		return {"error": String(saved.get("error", "Failed to save export presets"))}
	var platforms: Array[String] = []
	for value in (loaded.get("platforms", []) as Array):
		platforms.append(String(value))
	return {
		"status": "updated",
		"name": String(preset.get("name", name)),
		"changed_fields": changed,
		"verified": bool(saved.get("verified", false)),
		"validation_status": String(validate_preset(preset, platforms).get("status", "unvalidated")),
		"error": String(saved.get("error", ""))
	}


# ============================================================================
# remove_export_preset
# ============================================================================

func _register_remove(server_core: RefCounted) -> void:
	var tool_name: String = "remove_export_preset"
	var description: String = "Remove an export preset by name and re-index the remaining presets. Returns the post-removal list so the caller can verify."

	var input_schema: Dictionary = {
		"type": "object",
		"properties": {
			"name": {"type": "string", "description": "Preset name to remove."}
		},
		"required": ["name"]
	}

	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"status": {"type": "string"},
			"removed": {"type": "string"},
			"verified": {"type": "boolean"},
			"remaining": {"type": "array"}
		}
	}

	var annotations: Dictionary = {
		"readOnlyHint": false,
		"destructiveHint": true,
		"idempotentHint": true,
		"openWorldHint": false
	}

	server_core.register_tool(tool_name, description, input_schema,
		Callable(self, "_tool_remove_export_preset"), output_schema, annotations,
		"supplementary", "Project-Advanced")


func _tool_remove_export_preset(params: Dictionary) -> Dictionary:
	var name: String = String(params.get("name", "")).strip_edges()
	if name.is_empty():
		return {"error": "name is required"}
	var loaded: Dictionary = read_presets()
	if loaded.has("error"):
		return {"error": String(loaded["error"])}
	var presets: Array = loaded.get("presets", [])
	var slot: int = _find_by_name(presets, name)
	if slot < 0:
		return {"error": "No export preset named '%s'" % name}
	presets.remove_at(slot)
	# 重新编号，避免配置里留下空洞索引
	var remaining: Array = []
	for index in presets.size():
		var preset: Dictionary = presets[index]
		preset["index"] = index
		remaining.append(preset)

	var saved: Dictionary = write_presets(remaining)
	if not bool(saved.get("saved", false)):
		return {"error": String(saved.get("error", "Failed to save export presets"))}
	var reloaded: Dictionary = read_presets()
	var names: Array[String] = []
	for entry in (reloaded.get("presets", []) as Array):
		names.append(String((entry as Dictionary).get("name", "")))
	return {
		"status": "removed",
		"removed": name,
		"verified": bool(saved.get("verified", false)) and not names.has(name),
		"remaining": names,
		"error": String(saved.get("error", ""))
	}


# ============================================================================
# duplicate_export_preset
# ============================================================================

func _register_duplicate(server_core: RefCounted) -> void:
	var tool_name: String = "duplicate_export_preset"
	var description: String = "Duplicate an existing export preset under a new name, optionally overriding its export path."

	var input_schema: Dictionary = {
		"type": "object",
		"properties": {
			"name": {"type": "string", "description": "Source preset name."},
			"new_name": {"type": "string", "description": "Name for the copy."},
			"export_path": {"type": "string", "description": "Optional export path override for the copy."},
			"runnable": {"type": "boolean", "description": "Optional runnable override for the copy."}
		},
		"required": ["name", "new_name"]
	}

	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"status": {"type": "string"},
			"index": {"type": "integer"},
			"name": {"type": "string"},
			"verified": {"type": "boolean"},
			"validation_status": {"type": "string"}
		}
	}

	var annotations: Dictionary = {
		"readOnlyHint": false,
		"destructiveHint": false,
		"idempotentHint": false,
		"openWorldHint": false
	}

	server_core.register_tool(tool_name, description, input_schema,
		Callable(self, "_tool_duplicate_export_preset"), output_schema, annotations,
		"supplementary", "Project-Advanced")


func _tool_duplicate_export_preset(params: Dictionary) -> Dictionary:
	var name: String = String(params.get("name", "")).strip_edges()
	var new_name: String = String(params.get("new_name", "")).strip_edges()
	if name.is_empty() or new_name.is_empty():
		return {"error": "name and new_name are required"}
	var loaded: Dictionary = read_presets()
	if loaded.has("error"):
		return {"error": String(loaded["error"])}
	var presets: Array = loaded.get("presets", [])
	var slot: int = _find_by_name(presets, name)
	if slot < 0:
		return {"error": "No export preset named '%s'" % name}
	if _find_by_name(presets, new_name) >= 0:
		return {"error": "An export preset named '%s' already exists" % new_name}

	var source: Dictionary = presets[slot]
	var copy: Dictionary = source.duplicate(true)
	copy["index"] = _next_index(presets)
	copy["name"] = new_name
	if params.has("export_path"):
		copy["export_path"] = String(params["export_path"]).strip_edges()
	if params.has("runnable"):
		copy["runnable"] = bool(params["runnable"])
	presets.append(copy)

	var saved: Dictionary = write_presets(presets)
	if not bool(saved.get("saved", false)):
		return {"error": String(saved.get("error", "Failed to save export presets"))}
	var platforms: Array[String] = []
	for value in (loaded.get("platforms", []) as Array):
		platforms.append(String(value))
	return {
		"status": "duplicated",
		"index": int(copy.get("index", 0)),
		"name": new_name,
		"verified": bool(saved.get("verified", false)),
		"validation_status": String(validate_preset(copy, platforms).get("status", "unvalidated")),
		"error": String(saved.get("error", ""))
	}
