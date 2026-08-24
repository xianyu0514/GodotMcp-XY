# project_tools_native.gd - Project Tools原生实现

@tool
class_name ProjectToolsNative
extends RefCounted

const MAX_CONCURRENT_TEST_JOBS: int = 4

var _editor_interface: EditorInterface = null
# 统一异步 job 框架（AsyncJobManager，基于 WorkerThreadPool）：单测与批次测试
# 各用一个 manager 实例，共享同一个 MAX_CONCURRENT_TEST_JOBS 预算；文生3D 生成
# 独立管理。AsyncJobManager 兼容 AsyncJobRunner 的 start/poll/has_job/
# active_count/elapsed_ms/flush API，因此旧的调用方无需改动。
var _test_runner: AsyncJobManager = AsyncJobManager.new()
var _batch_test_runner: AsyncJobManager = AsyncJobManager.new()
var _gen_job_manager: AsyncJobManager = AsyncJobManager.new()
# Reference to the owning MCPServerCore, captured at registration, so long-running
# tools can emit progress notifications and observe client cancellation.
var _server_core: RefCounted = null

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

# ============================================================================
# Tool registration
# ============================================================================

func register_tools(server_core: RefCounted) -> void:
	_server_core = server_core
	_register_get_project_info(server_core)
	_register_get_project_settings(server_core)
	_register_list_project_input_actions(server_core)
	_register_upsert_project_input_action(server_core)
	_register_remove_project_input_action(server_core)
	_register_list_project_autoloads(server_core)
	_register_list_project_global_classes(server_core)
	_register_get_class_api_metadata(server_core)
	_register_list_project_tests(server_core)
	_register_run_project_test(server_core)
	_register_run_project_tests(server_core)
	_register_inspect_csharp_project_support(server_core)
	_register_get_project_structure(server_core)
	_register_set_project_setting(server_core)
	_register_add_project_autoload(server_core)
	_register_remove_project_autoload(server_core)

# ============================================================================
# Progress / 取消支持辅助（配合 mcp_server_core 的 progress 与 cancelled 支持）
# ============================================================================

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
# Shared helpers（跨域共享：资源/资产/工作流等域经 ProjectToolsNative.<helper>() 静态访问）
# ============================================================================

# 辅助函数：递归收集资源文件
static func _collect_resources(directory_path: String, extensions: Array[String], result: Array[String]) -> void:
	var dir: DirAccess = DirAccess.open(directory_path)
	
	if not dir:
		return
	
	# 列出所有文件和目录
	dir.list_dir_begin()
	var file_name: String = dir.get_next()
	
	while not file_name.is_empty():
		# 跳过特殊目录
		if file_name != "." and file_name != "..":
			var full_path: String = directory_path
			if not full_path.ends_with("/"):
				full_path += "/"
			full_path += file_name
			
			if dir.current_is_dir():
				# 递归处理子目录
				_collect_resources(full_path, extensions, result)
			else:
				# 检查文件扩展名
				for ext in extensions:
					if file_name.ends_with(ext):
						result.append(full_path)
						break
		
		file_name = dir.get_next()
	
	dir.list_dir_end()

static func _find_project_global_class_entry(target_class_name: String) -> Dictionary:
	if not ProjectSettings.has_method("get_global_class_list"):
		return {}
	for entry in ProjectSettings.get_global_class_list():
		if not (entry is Dictionary):
			continue
		if str(entry.get("class", "")) == target_class_name:
			return entry
	return {}

static func _parse_color(value: Variant) -> Color:
	if value is Color:
		return value
	if value is String:
		return Color.from_string(value, Color.WHITE)
	if value is Dictionary:
		return Color(float(value.get("r", 0.0)), float(value.get("g", 0.0)), float(value.get("b", 0.0)), float(value.get("a", 1.0)))
	if value is Array and value.size() >= 3:
		var a: float = float(value[3]) if value.size() >= 4 else 1.0
		return Color(float(value[0]), float(value[1]), float(value[2]), a)
	return Color.WHITE

static func _coerce_setting_value(value: Variant, value_type: String) -> Dictionary:
	match value_type:
		"", "any":
			return {"value": value}
		"string":
			return {"value": str(value)}
		"int":
			return {"value": int(value)}
		"float":
			return {"value": float(value)}
		"bool":
			if value is String:
				var s: String = str(value).strip_edges().to_lower()
				return {"value": s == "true" or s == "1" or s == "yes"}
			return {"value": bool(value)}
		"color":
			return {"value": _parse_color(value)}
		"vector2":
			var v2: Variant = _parse_vector2(value)
			if v2 == null:
				return {"error": "Cannot parse vector2 from value (use [x, y] or {x, y})"}
			return {"value": v2}
		"vector3":
			var v3: Variant = _parse_vector3(value)
			if v3 == null:
				return {"error": "Cannot parse vector3 from value (use [x, y, z] or {x, y, z})"}
			return {"value": v3}
		_:
			return {"error": "Unknown value_type: " + value_type}

static func _parse_vector2(value: Variant) -> Variant:
	if value is Vector2:
		return value
	if value is Dictionary:
		return Vector2(float(value.get("x", 0.0)), float(value.get("y", 0.0)))
	if value is Array and value.size() >= 2:
		return Vector2(float(value[0]), float(value[1]))
	return null

static func _parse_vector3(value: Variant) -> Variant:
	if value is Vector3:
		return value
	if value is Dictionary:
		return Vector3(float(value.get("x", 0.0)), float(value.get("y", 0.0)), float(value.get("z", 0.0)))
	if value is Array and value.size() >= 3:
		return Vector3(float(value[0]), float(value[1]), float(value[2]))
	return null

# ============================================================================
# get_project_info - 获取项目信息
# ============================================================================

func _register_get_project_info(server_core: RefCounted) -> void:
	var tool_name: String = "get_project_info"
	var description: String = "Get general information about the Godot project, including name, version, and description."
	
	# inputSchema
	var input_schema: Dictionary = {
		"type": "object",
		"properties": {}
	}
	
	# outputSchema
	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"project_name": {"type": "string"},
			"project_version": {"type": "string"},
			"project_description": {"type": "string"},
			"main_scene": {"type": "string"},
			"project_path": {"type": "string"},
			"godot_version": {"type": "string"}
		}
	}
	
	# annotations - readOnlyHint = true
	var annotations: Dictionary = {
		"readOnlyHint": true,
		"destructiveHint": false,
		"idempotentHint": true,
		"openWorldHint": false
	}
	
	# 注册工具
	server_core.register_tool(tool_name, description, input_schema,
						  Callable(self, "_tool_get_project_info"),
						  output_schema, annotations,
						  "core", "Project")

func _tool_get_project_info(params: Dictionary) -> Dictionary:
	var project_name: String = ProjectSettings.get_setting("application/config/name", "")
	var project_version: String = ProjectSettings.get_setting("application/config/version", "")
	var project_description: String = ProjectSettings.get_setting("application/config/description", "")
	var main_scene_uid: String = ProjectSettings.get_setting("application/run/main_scene", "")
	
	var main_scene: String = main_scene_uid
	if main_scene_uid.begins_with("uid://"):
		if ClassDB.class_exists("ResourceUID"):
			main_scene = ResourceUID.uid_to_path(main_scene_uid)
	
	var project_path: String = ProjectSettings.globalize_path("res://")
	var godot_version: Dictionary = Engine.get_version_info()
	var version_str: String = "%d.%d.%s" % [godot_version.get("major", 0), godot_version.get("minor", 0), godot_version.get("status", "")]
	
	return {
		"project_name": project_name,
		"project_version": project_version,
		"project_description": project_description,
		"main_scene": main_scene,
		"project_path": project_path,
		"godot_version": version_str
	}


# ============================================================================
# get_project_settings - 获取项目设置
# ============================================================================

func _register_get_project_settings(server_core: RefCounted) -> void:
	var tool_name: String = "get_project_settings"
	var description: String = "Get project settings. Optionally filter by a prefix."
	
	# inputSchema
	var input_schema: Dictionary = {
		"type": "object",
		"properties": {
			"filter": {
				"type": "string",
				"description": "Optional prefix to filter settings (e.g. 'display/', 'input/'). Returns all if not provided."
			}
		}
	}
	
	# outputSchema
	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"settings": {"type": "object"},
			"count": {"type": "integer"}
		}
	}
	
	# annotations - readOnlyHint = true
	var annotations: Dictionary = {
		"readOnlyHint": true,
		"destructiveHint": false,
		"idempotentHint": true,
		"openWorldHint": false
	}
	
	# 注册工具
	server_core.register_tool(tool_name, description, input_schema,
						  Callable(self, "_tool_get_project_settings"),
						  output_schema, annotations,
						  "core", "Project")

func _tool_get_project_settings(params: Dictionary) -> Dictionary:
	var filter: String = params.get("filter", "")
	
	var settings: Dictionary = {}
	var setting_count: int = 0
	
	var all_properties: Array = ProjectSettings.get_property_list()
	
	for property_info in all_properties:
		var setting_name: String = property_info.get("name", "")
		
		if not filter.is_empty() and not setting_name.begins_with(filter):
			continue
		
		var value: Variant = ProjectSettings.get_setting(setting_name)
		settings[setting_name] = str(value)
		setting_count += 1
	
	return {
		"settings": settings,
		"count": setting_count
	}


# ============================================================================
# project input actions - 项目级 InputMap
# ============================================================================

func _register_list_project_input_actions(server_core: RefCounted) -> void:
	var tool_name: String = "list_project_input_actions"
	var description: String = "List project InputMap actions stored in ProjectSettings, including serialized input events."

	var input_schema: Dictionary = {
		"type": "object",
		"properties": {
			"action_name": {
				"type": "string",
				"description": "Optional exact action name filter."
			}
		}
	}

	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"actions": {"type": "array"},
			"count": {"type": "integer"},
			"filter": {"type": "string"}
		}
	}

	var annotations: Dictionary = {
		"readOnlyHint": true,
		"destructiveHint": false,
		"idempotentHint": true,
		"openWorldHint": false
	}

	server_core.register_tool(tool_name, description, input_schema,
						  Callable(self, "_tool_list_project_input_actions"),
						  output_schema, annotations,
						  "supplementary", "Project-Advanced")

func _tool_list_project_input_actions(params: Dictionary) -> Dictionary:
	var action_name: String = str(params.get("action_name", "")).strip_edges()
	var actions: Array = _collect_project_input_actions(action_name)
	return {
		"actions": actions,
		"count": actions.size(),
		"filter": action_name
	}

func _register_upsert_project_input_action(server_core: RefCounted) -> void:
	var tool_name: String = "upsert_project_input_action"
	var description: String = "Create or update a project InputMap action in ProjectSettings and save project.godot."

	var input_schema: Dictionary = {
		"type": "object",
		"properties": {
			"action_name": {"type": "string"},
			"deadzone": {"type": "number", "default": 0.5},
			"erase_existing": {"type": "boolean", "default": false},
			"events": {"type": "array", "items": {"type": "object"}, "description": "Optional structured input event payloads to store on the action."}
		},
		"required": ["action_name"]
	}

	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"action_name": {"type": "string"},
			"existed_before": {"type": "boolean"},
			"deadzone": {"type": "number"},
			"event_count": {"type": "integer"},
			"events": {"type": "array", "items": {"type": "object"}},
			"added_events": {"type": "array", "items": {"type": "object"}}
		}
	}

	var annotations: Dictionary = {
		"readOnlyHint": false,
		"destructiveHint": false,
		"idempotentHint": false,
		"openWorldHint": false
	}

	server_core.register_tool(tool_name, description, input_schema,
						  Callable(self, "_tool_upsert_project_input_action"),
						  output_schema, annotations,
						  "supplementary", "Project-Advanced")

func _tool_upsert_project_input_action(params: Dictionary) -> Dictionary:
	var action_name: String = str(params.get("action_name", "")).strip_edges()
	if action_name.is_empty():
		return {"error": "Missing required parameter: action_name"}

	var deadzone: float = float(params.get("deadzone", 0.5))
	var erase_existing: bool = bool(params.get("erase_existing", false))
	var raw_events: Array = params.get("events", [])
	var setting_name: String = "input/" + action_name
	var existed_before: bool = ProjectSettings.has_setting(setting_name)

	var stored_events: Array = []
	var added_events: Array = []
	if existed_before and not erase_existing:
		var existing_value: Variant = ProjectSettings.get_setting(setting_name, {})
		if existing_value is Dictionary:
			stored_events = (existing_value.get("events", []) as Array).duplicate()
	for raw_event in raw_events:
		if not (raw_event is Dictionary):
			return {"error": "Each event entry must be an object"}
		var built_event: InputEvent = _build_project_input_event(raw_event)
		if built_event == null:
			return {"error": "Unsupported input event payload: " + JSON.stringify(raw_event)}
		stored_events.append(built_event)
		added_events.append(_serialize_project_input_event(built_event))

	ProjectSettings.set_setting(setting_name, {
		"deadzone": deadzone,
		"events": stored_events
	})
	var save_error: Error = ProjectSettings.save()
	if save_error != OK:
		return {"error": "Failed to save project settings: " + str(save_error)}
	InputMap.load_from_project_settings()

	var listed_actions: Array = _collect_project_input_actions(action_name)
	var action_entry: Dictionary = listed_actions[0] if not listed_actions.is_empty() else {}
	action_entry["added_events"] = added_events
	action_entry["existed_before"] = existed_before
	return action_entry

func _register_remove_project_input_action(server_core: RefCounted) -> void:
	var tool_name: String = "remove_project_input_action"
	var description: String = "Remove a project InputMap action from ProjectSettings and save project.godot."

	var input_schema: Dictionary = {
		"type": "object",
		"properties": {
			"action_name": {"type": "string"}
		},
		"required": ["action_name"]
	}

	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"action_name": {"type": "string"},
			"removed": {"type": "boolean"},
			"event_count": {"type": "integer"}
		}
	}

	var annotations: Dictionary = {
		"readOnlyHint": false,
		"destructiveHint": true,
		"idempotentHint": false,
		"openWorldHint": false
	}

	server_core.register_tool(tool_name, description, input_schema,
						  Callable(self, "_tool_remove_project_input_action"),
						  output_schema, annotations,
						  "supplementary", "Project-Advanced")

func _tool_remove_project_input_action(params: Dictionary) -> Dictionary:
	var action_name: String = str(params.get("action_name", "")).strip_edges()
	if action_name.is_empty():
		return {"error": "Missing required parameter: action_name"}

	var setting_name: String = "input/" + action_name
	if not ProjectSettings.has_setting(setting_name):
		return {
			"action_name": action_name,
			"removed": false,
			"event_count": 0
		}

	var existing_value: Variant = ProjectSettings.get_setting(setting_name, {})
	var event_count: int = 0
	if existing_value is Dictionary:
		event_count = (existing_value.get("events", []) as Array).size()

	ProjectSettings.clear(setting_name)
	var save_error: Error = ProjectSettings.save()
	if save_error != OK:
		return {"error": "Failed to save project settings: " + str(save_error)}
	InputMap.load_from_project_settings()

	return {
		"action_name": action_name,
		"removed": true,
		"event_count": event_count
	}


# ============================================================================
# list_project_autoloads - 列出项目 Autoload
# ============================================================================

func _register_list_project_autoloads(server_core: RefCounted) -> void:
	var tool_name: String = "list_project_autoloads"
	var description: String = "List project autoload entries with resolved path, singleton flag, and project setting order."

	var input_schema: Dictionary = {
		"type": "object",
		"properties": {
			"filter": {
				"type": "string",
				"description": "Optional case-insensitive filter that matches autoload name or path."
			}
		}
	}

	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"autoloads": {"type": "array", "items": {"type": "object"}},
			"count": {"type": "integer"}
		}
	}

	var annotations: Dictionary = {
		"readOnlyHint": true,
		"destructiveHint": false,
		"idempotentHint": true,
		"openWorldHint": false
	}

	server_core.register_tool(tool_name, description, input_schema,
						  Callable(self, "_tool_list_project_autoloads"),
						  output_schema, annotations,
						  "supplementary", "Project-Advanced")

func _tool_list_project_autoloads(params: Dictionary) -> Dictionary:
	var filter: String = str(params.get("filter", "")).strip_edges().to_lower()
	var values_by_name: Dictionary = {}
	var orders_by_name: Dictionary = {}
	for property_info in ProjectSettings.get_property_list():
		var property_name: String = str(property_info.get("name", ""))
		if not property_name.begins_with("autoload/"):
			continue
		values_by_name[property_name] = ProjectSettings.get_setting(property_name)
		orders_by_name[property_name] = ProjectSettings.get_order(property_name)

	var autoloads: Array = _collect_project_autoloads_from_properties(ProjectSettings.get_property_list(), values_by_name, orders_by_name)
	if not filter.is_empty():
		var filtered_autoloads: Array = []
		for entry in autoloads:
			var entry_name: String = str(entry.get("name", "")).to_lower()
			var entry_path: String = str(entry.get("path", "")).to_lower()
			if entry_name.contains(filter) or entry_path.contains(filter):
				filtered_autoloads.append(entry)
		autoloads = filtered_autoloads

	return {
		"autoloads": autoloads,
		"count": autoloads.size()
	}


# ============================================================================
# list_project_global_classes - 列出项目全局脚本类
# ============================================================================

func _register_list_project_global_classes(server_core: RefCounted) -> void:
	var tool_name: String = "list_project_global_classes"
	var description: String = "List project global script classes registered through class_name metadata."

	var input_schema: Dictionary = {
		"type": "object",
		"properties": {
			"filter": {
				"type": "string",
				"description": "Optional case-insensitive filter that matches class name, base type, or script path."
			}
		}
	}

	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"classes": {"type": "array", "items": {"type": "object"}},
			"count": {"type": "integer"}
		}
	}

	var annotations: Dictionary = {
		"readOnlyHint": true,
		"destructiveHint": false,
		"idempotentHint": true,
		"openWorldHint": false
	}

	server_core.register_tool(tool_name, description, input_schema,
						  Callable(self, "_tool_list_project_global_classes"),
						  output_schema, annotations,
						  "supplementary", "Project-Advanced")

func _tool_list_project_global_classes(params: Dictionary) -> Dictionary:
	var filter: String = str(params.get("filter", "")).strip_edges().to_lower()
	var class_entries: Array = []
	if ProjectSettings.has_method("get_global_class_list"):
		class_entries = _normalize_global_class_entries(ProjectSettings.get_global_class_list())
	if not filter.is_empty():
		var filtered_entries: Array = []
		for entry in class_entries:
			var entry_name: String = str(entry.get("name", "")).to_lower()
			var base_name: String = str(entry.get("base", "")).to_lower()
			var path: String = str(entry.get("path", "")).to_lower()
			if entry_name.contains(filter) or base_name.contains(filter) or path.contains(filter):
				filtered_entries.append(entry)
		class_entries = filtered_entries
	return {
		"classes": class_entries,
		"count": class_entries.size()
	}


# ============================================================================
# get_class_api_metadata - 获取类型化 API 元数据
# ============================================================================

func _register_get_class_api_metadata(server_core: RefCounted) -> void:
	var tool_name: String = "get_class_api_metadata"
	var description: String = "Get typed API metadata for an engine ClassDB class or a project global script class."

	var input_schema: Dictionary = {
		"type": "object",
		"properties": {
			"class_name": {
				"type": "string",
				"description": "Class name to inspect, such as 'Node' or a project global class_name."
			},
			"filter": {
				"type": "string",
				"description": "Optional case-insensitive filter applied to method/property/signal/constant names."
			},
			"include_base_api": {
				"type": "boolean",
				"description": "For project global classes, whether to include base ClassDB metadata. Default is true.",
				"default": true
			}
		},
		"required": ["class_name"]
	}

	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"class_name": {"type": "string"},
			"source": {"type": "string"},
			"base_class": {"type": "string"},
			"methods": {"type": "array"},
			"properties": {"type": "array"},
			"signals": {"type": "array"},
			"constants": {"type": "array"}
		}
	}

	var annotations: Dictionary = {
		"readOnlyHint": true,
		"destructiveHint": false,
		"idempotentHint": true,
		"openWorldHint": false
	}

	server_core.register_tool(tool_name, description, input_schema,
						  Callable(self, "_tool_get_class_api_metadata"),
						  output_schema, annotations,
						  "supplementary", "Project-Advanced")

func _tool_get_class_api_metadata(params: Dictionary) -> Dictionary:
	var target_class_name: String = str(params.get("class_name", "")).strip_edges()
	if target_class_name.is_empty():
		return {"error": "Missing required parameter: class_name"}
	var filter: String = str(params.get("filter", "")).strip_edges().to_lower()
	var include_base_api: bool = params.get("include_base_api", true)

	if ClassDB.class_exists(target_class_name):
		return _build_classdb_api_metadata(target_class_name, filter)

	var global_class: Dictionary = _find_project_global_class_entry(target_class_name)
	if global_class.is_empty():
		return {"error": "Class not found: " + target_class_name}

	var script_path: String = str(global_class.get("path", ""))
	var script: Script = load(script_path)
	if not script:
		return {"error": "Failed to load global class script: " + script_path}

	var result: Dictionary = {
		"class_name": target_class_name,
		"source": "global_class",
		"base_class": str(global_class.get("base", "")),
		"script_path": script_path,
		"language": str(global_class.get("language", "")),
		"is_tool": bool(global_class.get("is_tool", false)),
		"is_abstract": bool(global_class.get("is_abstract", false)),
		"methods": _normalize_method_entries(script.get_script_method_list(), filter),
		"properties": _normalize_property_entries(script.get_script_property_list(), filter),
		"signals": _normalize_signal_entries(script.get_script_signal_list(), filter),
		"constants": []
	}

	if include_base_api:
		var base_class: String = str(global_class.get("base", ""))
		if not base_class.is_empty() and ClassDB.class_exists(base_class):
			result["base_api"] = _build_classdb_api_metadata(base_class, filter)

	return result


# ============================================================================
# list_project_tests - 发现项目测试
# ============================================================================

func _register_list_project_tests(server_core: RefCounted) -> void:
	server_core.register_tool(
		"list_project_tests",
		"Discover runnable project tests under the Godot project's test directories. Reports Python integration tests and GUT unit tests, including whether each test is currently runnable.",
		{
			"type": "object",
			"properties": {
				"search_path": {"type": "string", "description": "Optional res:// path to limit discovery."},
				"framework": {"type": "string", "description": "Optional framework filter: python or gut."}
			}
		},
		Callable(self, "_tool_list_project_tests"),
		{
			"type": "object",
			"properties": {
				"count": {"type": "integer"},
				"search_path": {"type": "string"},
				"tests": {"type": "array"}
			}
		},
		{"readOnlyHint": true, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false},
		"supplementary", "Project-Advanced"
	)

func _tool_list_project_tests(params: Dictionary) -> Dictionary:
	var search_path: String = str(params.get("search_path", "res://test")).strip_edges()
	if search_path.is_empty():
		search_path = "res://test"
	var framework_filter: String = str(params.get("framework", "")).strip_edges().to_lower()

	var validation: Dictionary = _validate_test_path(search_path, true)
	if validation.has("error"):
		return validation
	search_path = String(validation["sanitized"])

	var absolute_root: String = ProjectSettings.globalize_path(search_path)
	var dir: DirAccess = DirAccess.open(absolute_root)
	if dir == null:
		return {"error": "Test directory not found: " + search_path}

	var gut_available: bool = FileAccess.file_exists("res://addons/gut/gut_cmdln.gd")
	var tests: Array = []
	_collect_project_tests_recursive(search_path, absolute_root, framework_filter, gut_available, tests)
	tests.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return String(a.get("test_path", "")) < String(b.get("test_path", ""))
	)

	return {
		"count": tests.size(),
		"search_path": search_path,
		"tests": tests
	}


# ============================================================================
# run_project_test - 运行项目测试
# ============================================================================

func _register_run_project_test(server_core: RefCounted) -> void:
	server_core.register_tool(
		"run_project_test",
		"Run a single project test script without blocking the editor. The first call starts the run on a background thread and returns status 'pending'; call again with the same test_path to poll for the finished result. Python integration tests are executed with python. GUT unit tests are executed through Godot headless when addons/gut is available.",
		{
			"type": "object",
			"properties": {
				"test_path": {"type": "string", "description": "res:// path to a project test file under test/."},
				"timeout_ms": {"type": "integer", "description": "Reserved timeout hint for the caller."}
			},
			"required": ["test_path"]
		},
		Callable(self, "_tool_run_project_test"),
		{
			"type": "object",
			"properties": {
				"status": {"type": "string", "description": "'pending' while running, then 'passed' or 'failed'."},
				"framework": {"type": "string"},
				"test_path": {"type": "string"},
				"exit_code": {"type": "integer"},
				"elapsed_ms": {"type": "integer", "description": "Time elapsed so far while status is 'pending'."},
				"command": {"type": "array"},
				"output": {"type": "array"}
			}
		},
		{"readOnlyHint": false, "destructiveHint": false, "idempotentHint": false, "openWorldHint": false},
		"supplementary", "Project-Advanced"
	)

func _tool_run_project_test(params: Dictionary) -> Dictionary:
	var test_path: String = str(params.get("test_path", "")).strip_edges()
	if test_path.is_empty():
		return {"error": "Missing required parameter: test_path"}

	var validation: Dictionary = _validate_test_path(test_path, false)
	if validation.has("error"):
		return validation
	test_path = String(validation["sanitized"])

	var extension: String = test_path.get_extension().to_lower()
	if extension != "py" and extension != "gd":
		return {"error": "Unsupported project test type: " + extension}
	if not FileAccess.file_exists(test_path):
		return {"error": "Test file not found: " + test_path}

	# Optional client progress token (arguments._meta.progressToken). Absent ->
	# progress notifications are silently skipped.
	var progress_token: Variant = null
	if params.has("_meta") and params["_meta"] is Dictionary:
		progress_token = (params["_meta"] as Dictionary).get("progressToken", null)

	# 客户端取消检查：pending→poll 模式的每一轮调用都检查一次。取消时同时
	# 标记底层 job，让后台 worker 尽快中止（协作式取消）。
	if _tool_cancelled():
		if _test_runner.has_job(test_path):
			_test_runner.cancel_job(test_path)
		return {"status": "cancelled", "test_path": test_path, "error": "cancelled by client"}

	# A test run spawns a full subprocess (python, or a headless Godot for GUT)
	# that can take seconds to minutes. Run it on a worker thread so the editor
	# stays responsive: the first call starts the run and returns "pending";
	# calling again with the same test_path polls for the result.
	if _test_runner.has_job(test_path):
		var polled: Dictionary = _test_runner.poll_job(test_path)
		var poll_status: String = str(polled.get("status", ""))
		if poll_status == "pending":
			# Report elapsed seconds as progress on each poll round.
			_send_tool_progress(progress_token, int(polled.get("elapsed_ms", 0) / 1000), 0, "polling")
			return {
				"status": "pending",
				"job_id": test_path,
				"test_path": test_path,
				"elapsed_ms": polled.get("elapsed_ms", 0),
				"message": "Test is still running; call run_project_test again with the same test_path to poll for the result."
			}
		if poll_status != "missing":
			# "done"/"cancelled"：worker 结果原样返回（含 error / cancelled 标记）。
			return polled.get("result", {})
		# status == "missing"：另一个并发请求已经 poll 完成并取走了 job，
		# 当作全新任务继续往下走。

	if _active_test_job_count() >= MAX_CONCURRENT_TEST_JOBS:
		return {"error": "Too many test runs in progress; poll the pending runs before starting another."}

	_test_runner.start_job(test_path, Callable(self, "_execute_project_test_blocking").bind(test_path))
	return {
		"status": "pending",
		"job_id": test_path,
		"test_path": test_path,
		"message": "Test started on a background thread; call run_project_test again with the same test_path to poll for the result."
	}

# Single and batch test runs share one concurrency budget so the total number of
# live test subprocesses stays bounded by MAX_CONCURRENT_TEST_JOBS across both
# run_project_test and run_project_tests.
func _active_test_job_count() -> int:
	return _test_runner.active_count() + _batch_test_runner.active_count()

# Blocking execution of a single test. Used by the background worker thread for
# run_project_test and directly (synchronously) by the batch runner.
func _execute_project_test_blocking(test_path: String) -> Dictionary:
	var validation: Dictionary = _validate_test_path(test_path, false)
	if validation.has("error"):
		return validation
	var sanitized_path: String = String(validation["sanitized"])

	var extension: String = sanitized_path.get_extension().to_lower()
	var absolute_test_path: String = ProjectSettings.globalize_path(sanitized_path)
	if not FileAccess.file_exists(sanitized_path):
		return {"error": "Test file not found: " + sanitized_path}

	match extension:
		"py":
			return _run_python_project_test(sanitized_path, absolute_test_path)
		"gd":
			return _run_gut_project_test(sanitized_path)
		_:
			return {"error": "Unsupported project test type: " + extension}

func _register_run_project_tests(server_core: RefCounted) -> void:
	server_core.register_tool(
		"run_project_tests",
		"Discover and run multiple project tests from a directory without blocking the editor. The first call starts the batch on a background thread and returns status 'pending'; call again with the same arguments to poll for the aggregated result. Reuses the same framework filters as list_project_tests and aggregates pass/fail counts.",
		{
			"type": "object",
			"properties": {
				"search_path": {"type": "string", "description": "Optional res:// path to limit discovery. Default is res://test."},
				"framework": {"type": "string", "description": "Optional framework filter: python or gut."},
				"only_runnable": {"type": "boolean", "description": "Whether to skip discovered tests that are not currently runnable. Default is true."}
			}
		},
		Callable(self, "_tool_run_project_tests"),
		{
			"type": "object",
			"properties": {
				"status": {"type": "string", "description": "'pending' while running, then 'passed', 'failed' or 'skipped'."},
				"search_path": {"type": "string"},
				"framework": {"type": "string"},
				"elapsed_ms": {"type": "integer", "description": "Time elapsed so far while status is 'pending'."},
				"total_count": {"type": "integer"},
				"passed_count": {"type": "integer"},
				"failed_count": {"type": "integer"},
				"skipped_count": {"type": "integer"},
				"results": {"type": "array"}
			}
		},
		{"readOnlyHint": false, "destructiveHint": false, "idempotentHint": false, "openWorldHint": false},
		"supplementary", "Project-Advanced"
	)

func _tool_run_project_tests(params: Dictionary) -> Dictionary:
	var search_path: String = str(params.get("search_path", "res://test")).strip_edges()
	if search_path.is_empty():
		search_path = "res://test"
	var framework: String = str(params.get("framework", "")).strip_edges().to_lower()
	var only_runnable: bool = bool(params.get("only_runnable", true))

	# Optional client progress token (arguments._meta.progressToken).
	var progress_token: Variant = null
	if params.has("_meta") and params["_meta"] is Dictionary:
		progress_token = (params["_meta"] as Dictionary).get("progressToken", null)

	# A batch can spawn many test subprocesses back to back and take minutes.
	# Run the whole batch on a worker thread so the editor stays responsive:
	# the first call starts the batch and returns "pending"; calling again with
	# the same arguments polls for the aggregated result.
	var job_key: String = search_path + "|" + framework + "|" + str(only_runnable)

	# 客户端取消检查：pending→poll 模式的每一轮调用都检查一次。取消时同时
	# 标记底层 job，让批次 worker 在两次测试之间尽早中止。
	if _tool_cancelled():
		if _batch_test_runner.has_job(job_key):
			_batch_test_runner.cancel_job(job_key)
		return {"status": "cancelled", "search_path": search_path, "error": "cancelled by client"}

	if _batch_test_runner.has_job(job_key):
		var polled: Dictionary = _batch_test_runner.poll_job(job_key)
		var poll_status: String = str(polled.get("status", ""))
		if poll_status == "pending":
			# Report elapsed seconds as progress on each poll round.
			_send_tool_progress(progress_token, int(polled.get("elapsed_ms", 0) / 1000), 0, "polling")
			return {
				"status": "pending",
				"job_id": job_key,
				"search_path": search_path,
				"framework": framework,
				"elapsed_ms": polled.get("elapsed_ms", 0),
				"message": "Test batch is still running; call run_project_tests again with the same arguments to poll for the result."
			}
		if poll_status != "missing":
			# "done"/"cancelled"：聚合结果（或 cancelled 标记）原样返回。
			return polled.get("result", {})
		# status == "missing"：并发请求已取走 job，当作全新任务继续往下走。

	if _active_test_job_count() >= MAX_CONCURRENT_TEST_JOBS:
		return {"error": "Too many test batches in progress; poll the pending runs before starting another."}

	var work_params: Dictionary = {
		"search_path": search_path,
		"framework": framework,
		"only_runnable": only_runnable
	}
	_batch_test_runner.start_job(job_key, Callable(self, "_execute_project_tests_blocking").bind(job_key, work_params))
	return {
		"status": "pending",
		"job_id": job_key,
		"search_path": search_path,
		"framework": framework,
		"message": "Test batch started on a background thread; call run_project_tests again with the same arguments to poll for the result."
	}

# Blocking execution of a test batch. Used by the background worker thread for
# run_project_tests. Discovers tests and runs each one synchronously. Checks
# the manager's cooperative cancellation flag between tests so a cancelled
# batch aborts early and reports a "cancelled" status instead of draining the
# remaining tests.
func _execute_project_tests_blocking(job_id: String, params: Dictionary) -> Dictionary:
	var list_result: Dictionary = _tool_list_project_tests({
		"search_path": params.get("search_path", "res://test"),
		"framework": params.get("framework", "")
	})
	if list_result.has("error"):
		return list_result

	var only_runnable: bool = bool(params.get("only_runnable", true))
	var discovered_tests: Array = list_result.get("tests", [])
	var results: Array = []
	var passed_count: int = 0
	var failed_count: int = 0
	var skipped_count: int = 0

	var index: int = 0
	for entry in discovered_tests:
		# 协作式取消：批次在两条测试之间检查取消标记，尽早中止整批。
		if _batch_test_runner.is_cancelled(job_id):
			return {
				"status": "cancelled",
				"cancelled": true,
				"error": "cancelled by client",
				"search_path": str(params.get("search_path", "")),
				"framework": str(params.get("framework", "")).strip_edges().to_lower(),
				"total_count": results.size(),
				"passed_count": passed_count,
				"failed_count": failed_count,
				"skipped_count": skipped_count,
				"results": results
			}
		if not (entry is Dictionary):
			index += 1
			continue
		var test_entry: Dictionary = entry
		if only_runnable and not bool(test_entry.get("runnable", false)):
			skipped_count += 1
			results.append({
				"status": "skipped",
				"test_path": String(test_entry.get("test_path", "")),
				"framework": String(test_entry.get("framework", "")),
				"reason": "No available runner"
			})
			index += 1
			continue
		var test_result: Dictionary = _execute_project_test_blocking(String(test_entry.get("test_path", "")))
		results.append(test_result)
		if test_result.get("status", "") == "passed":
			passed_count += 1
		else:
			failed_count += 1
		index += 1
		# 上报进度：已完成测试数 / 发现总数，主线程 poll 时转发给 MCP。
		_batch_test_runner.update_progress(job_id, index, discovered_tests.size())

	var aggregate_status: String = "passed"
	if failed_count > 0:
		aggregate_status = "failed"
	elif passed_count == 0 and skipped_count > 0:
		aggregate_status = "skipped"

	return {
		"status": aggregate_status,
		"search_path": list_result.get("search_path", ""),
		"framework": str(params.get("framework", "")).strip_edges().to_lower(),
		"total_count": results.size(),
		"passed_count": passed_count,
		"failed_count": failed_count,
		"skipped_count": skipped_count,
		"results": results
	}

func _validate_test_path(path: String, expect_directory: bool) -> Dictionary:
	if path.is_empty():
		return {"error": "Test path cannot be empty"}
	if not path.begins_with("res://"):
		return {"error": "Test path must start with res://"}
	if not (path.begins_with("res://test/") or path.begins_with("res://.tmp_") or path.contains("/.tmp_")):
		return {"error": "Test path must stay under res://test/ or a temporary test directory"}
	var validation: Dictionary = PathValidator.validate_directory_path(path) if expect_directory else PathValidator.validate_path(path)
	if not validation.get("valid", false):
		return {"error": "Invalid path: " + str(validation.get("error", "unknown"))}
	return {"sanitized": String(validation.get("sanitized", path))}

func _collect_project_tests_recursive(search_path: String, absolute_root: String, framework_filter: String, gut_available: bool, tests: Array) -> void:
	var dir: DirAccess = DirAccess.open(absolute_root)
	if dir == null:
		return
	dir.list_dir_begin()
	while true:
		var entry_name: String = dir.get_next()
		if entry_name.is_empty():
			break
		if entry_name == "." or entry_name == "..":
			continue
		var child_res_path: String = search_path.path_join(entry_name)
		var child_abs_path: String = absolute_root.path_join(entry_name)
		if dir.current_is_dir():
			_collect_project_tests_recursive(child_res_path, child_abs_path, framework_filter, gut_available, tests)
			continue
		var extension: String = entry_name.get_extension().to_lower()
		var framework: String = ""
		var kind: String = ""
		var runnable: bool = false
		match extension:
			"py":
				framework = "python"
				kind = "integration"
				runnable = true
			"gd":
				framework = "gut"
				kind = "unit"
				runnable = gut_available
			_:
				continue
		if not framework_filter.is_empty() and framework != framework_filter:
			continue
		tests.append({
			"test_path": child_res_path,
			"framework": framework,
			"kind": kind,
			"runnable": runnable,
			"available_runner": runnable,
			"name": entry_name
		})
	dir.list_dir_end()

func _run_python_project_test(test_path: String, absolute_test_path: String) -> Dictionary:
	var logs: Array = []
	var started_at_ms: int = Time.get_ticks_msec()
	var python_cmd: String = _find_python_executable()
	var exit_code: int = OS.execute(python_cmd, [absolute_test_path], logs, true)
	var duration_ms: int = Time.get_ticks_msec() - started_at_ms
	var output: Array = []
	for line in logs:
		output.append(_sanitize_cli_output(str(line)))
	return {
		"status": "passed" if exit_code == OK else "failed",
		"framework": "python",
		"kind": "integration",
		"test_path": test_path,
		"exit_code": exit_code,
		"duration_ms": duration_ms,
		"command": [python_cmd, absolute_test_path],
		"output": output
	}

# Sanitize CLI output: remove control characters and ANSI escape sequences (ESC[...m etc.)
# that would break JSON.stringify() in Godot 4.x (which does not escape ESC/U+001B).
# Defense-in-depth: even if the subprocess doesn't use colors, this protects
# against any other control character in stdout.
func _sanitize_cli_output(text: String) -> String:
	var sanitized: String = ""
	var in_escape: bool = false
	var i: int = 0
	while i < text.length():
		var codepoint: int = text.unicode_at(i)
		
		# --- Handle ANSI escape sequences ---
		# ESC (27) starts an ANSI sequence: ESC[X... or ESC[X...letter
		if codepoint == 27:
			in_escape = true
			i += 1
			continue
		
		# Inside an escape sequence: skip everything until a letter (A-Z/a-z) ends it
		if in_escape:
			var is_letter: bool = (codepoint >= 65 and codepoint <= 90) or (codepoint >= 97 and codepoint <= 122)
			if is_letter:
				in_escape = false
			# For BEL (7) or ESC (27) inside an OSC sequence, also terminate
			if codepoint == 7 or codepoint == 27:
				in_escape = false
				if codepoint == 27:
					continue  # Re-process this potential start
			i += 1
			continue
		
		# --- Filter control characters ---
		var keep_char: bool = codepoint >= 32 and codepoint != 127
		if codepoint == 9 or codepoint == 10 or codepoint == 13:
			keep_char = true
		# Unicode Private Use Area (some terminals map glyphs here)
		if codepoint >= 0xE000 and codepoint <= 0xF8FF:
			keep_char = false
		# Unicode Replacement Character U+FFFD (65533) — keep, not a control char
		if keep_char:
			sanitized += String.chr(codepoint)
		i += 1
	
	# Second pass: clean up any residual CSI fragments like "[31m" or "[0m"
	# that remain if an ESC was consumed by another layer before reaching us.
	# CSI pattern: '[' followed by one or more params (digits/semicolons), then a letter.
	# Uses lookahead to avoid false positives (e.g. "Array[0]" or "[Passed]").
	var cleaned: String = ""
	var j: int = 0
	while j < sanitized.length():
		var c: int = sanitized.unicode_at(j)
		if c == 91:  # '['
			# Look ahead to validate full CSI sequence before consuming
			var scan_pos: int = j + 1
			var has_param: bool = false
			while scan_pos < sanitized.length():
				var sc: int = sanitized.unicode_at(scan_pos)
				var is_sc_param: bool = (sc >= 48 and sc <= 59)  # 0-9 or ;
				var is_sc_letter: bool = (sc >= 65 and sc <= 90) or (sc >= 97 and sc <= 122)  # A-Z a-z
				if is_sc_param:
					has_param = true
					scan_pos += 1
				elif is_sc_letter and has_param:
					# Valid CSI: '[' + params + letter — skip it all
					j = scan_pos + 1
					break
				else:
					# Not a CSI sequence — keep the '['
					cleaned += String.chr(91)
					j += 1
					break
			if scan_pos >= sanitized.length():
				# Reached end without completing a CSI sequence
				cleaned += String.chr(91)
				j += 1
			continue
		cleaned += String.chr(c)
		j += 1
	
	return cleaned

func _find_python_executable() -> String:
	var test_output: Array = []
	if OS.execute("python3", ["--version"], test_output, true) == OK:
		return "python3"
	test_output.clear()
	if OS.execute("python", ["--version"], test_output, true) == OK:
		return "python"
	return "python3"

func _run_gut_project_test(test_path: String) -> Dictionary:
	var gut_cmdln_path: String = "res://addons/gut/gut_cmdln.gd"
	if not FileAccess.file_exists(gut_cmdln_path):
		return {"error": "GUT is not installed at res://addons/gut/gut_cmdln.gd"}
	var executable_path: String = OS.get_executable_path()
	var project_path: String = ProjectSettings.globalize_path("res://")
	var args: Array[String] = [
		"--headless",
		"--path", project_path,
		"-s", gut_cmdln_path,
		"-gtest=" + test_path,
		"-gexit",
		"-gdisable_colors"
	]
	var logs: Array = []
	var started_at_ms: int = Time.get_ticks_msec()
	var exit_code: int = OS.execute(executable_path, args, logs, true)
	var duration_ms: int = Time.get_ticks_msec() - started_at_ms
	var output: Array = []
	for line in logs:
		output.append(_sanitize_cli_output(str(line)))
	return {
		"status": "passed" if exit_code == OK else "failed",
		"framework": "gut",
		"kind": "unit",
		"test_path": test_path,
		"exit_code": exit_code,
		"duration_ms": duration_ms,
		"command": [executable_path] + args,
		"output": output
	}


# ============================================================================
# inspect_csharp_project_support - 检查 C# / Mono 项目支持元数据
# ============================================================================

func _register_inspect_csharp_project_support(server_core: RefCounted) -> void:
	var tool_name: String = "inspect_csharp_project_support"
	var description: String = "Inspect C# / Mono project support files such as .csproj and .sln, including target frameworks, assembly metadata, and references."

	var input_schema: Dictionary = {
		"type": "object",
		"properties": {
			"search_path": {
				"type": "string",
				"description": "Directory to scan. Default is res://.",
				"default": "res://"
			}
		}
	}

	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"search_path": {"type": "string"},
			"project_count": {"type": "integer"},
			"solution_count": {"type": "integer"},
			"projects": {"type": "array"},
			"solutions": {"type": "array"}
		}
	}

	var annotations: Dictionary = {
		"readOnlyHint": true,
		"destructiveHint": false,
		"idempotentHint": true,
		"openWorldHint": false
	}

	server_core.register_tool(tool_name, description, input_schema,
						  Callable(self, "_tool_inspect_csharp_project_support"),
						  output_schema, annotations,
						  "supplementary", "Project-Advanced")

func _tool_inspect_csharp_project_support(params: Dictionary) -> Dictionary:
	var search_path: String = str(params.get("search_path", "res://")).strip_edges()
	var validation: Dictionary = PathValidator.validate_directory_path(search_path)
	if not validation["valid"]:
		return {"error": "Invalid path: " + validation["error"]}
	search_path = validation["sanitized"]

	var project_paths: Array[String] = []
	var solution_paths: Array[String] = []
	_collect_resources(search_path, [".csproj"], project_paths)
	_collect_resources(search_path, [".sln"], solution_paths)
	project_paths.sort()
	solution_paths.sort()

	var projects: Array = []
	for project_path in project_paths:
		projects.append(_inspect_csproj_file(project_path))

	var solutions: Array = []
	for solution_path in solution_paths:
		solutions.append(_inspect_solution_file(solution_path))

	return {
		"search_path": search_path,
		"project_count": projects.size(),
		"solution_count": solutions.size(),
		"projects": projects,
		"solutions": solutions
	}


# ============================================================================
# get_project_structure - 获取项目目录结构
# ============================================================================

func _register_get_project_structure(server_core: RefCounted) -> void:
	var tool_name: String = "get_project_structure"
	var description: String = "Get the project directory structure with file counts by extension. Returns directories and file type statistics."

	var input_schema: Dictionary = {
		"type": "object",
		"properties": {
			"max_depth": {
				"type": "integer",
				"description": "Maximum directory depth to traverse. Default is 3.",
				"default": 3
			}
		}
	}

	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"directories": {"type": "array", "items": {"type": "string"}},
			"file_counts": {"type": "object"},
			"total_files": {"type": "integer"},
			"total_directories": {"type": "integer"}
		}
	}

	var annotations: Dictionary = {
		"readOnlyHint": true,
		"destructiveHint": false,
		"idempotentHint": true,
		"openWorldHint": false
	}

	server_core.register_tool(tool_name, description, input_schema,
						  Callable(self, "_tool_get_project_structure"),
						  output_schema, annotations,
						  "supplementary", "Project-Advanced")

func _tool_get_project_structure(params: Dictionary) -> Dictionary:
	var max_depth: int = params.get("max_depth", 3)
	var directories: Array = []
	var file_counts: Dictionary = {}

	_scan_directory("res://", directories, file_counts, 0, max_depth)

	var total_files: int = 0
	for ext in file_counts:
		total_files += file_counts[ext]

	return {
		"directories": directories,
		"file_counts": file_counts,
		"total_files": total_files,
		"total_directories": directories.size()
	}

func _scan_directory(path: String, directories: Array, file_counts: Dictionary, current_depth: int, max_depth: int) -> void:
	if current_depth > max_depth:
		return

	var dir: DirAccess = DirAccess.open(path)
	if not dir:
		return

	directories.append(path)

	dir.list_dir_begin()
	var file_name: String = dir.get_next()
	while file_name != "":
		var full_path: String = path + file_name
		if dir.current_is_dir():
			if not file_name.begins_with("."):
				_scan_directory(full_path + "/", directories, file_counts, current_depth + 1, max_depth)
		else:
			var ext: String = file_name.get_extension().to_lower()
			if not ext.is_empty() and ext != "import" and ext != "uid":
				if not file_counts.has(ext):
					file_counts[ext] = 0
				file_counts[ext] += 1
		file_name = dir.get_next()
	dir.list_dir_end()


func _collect_project_autoloads_from_properties(properties: Array, values_by_name: Dictionary, orders_by_name: Dictionary) -> Array:
	var autoloads: Array = []
	for property_info in properties:
		var property_name: String = str(property_info.get("name", ""))
		if not property_name.begins_with("autoload/"):
			continue
		var raw_value: String = str(values_by_name.get(property_name, ""))
		var is_singleton: bool = raw_value.begins_with("*")
		var resolved_path: String = raw_value.substr(1) if is_singleton else raw_value
		autoloads.append({
			"name": property_name.get_slice("/", 1),
			"path": resolved_path.simplify_path(),
			"is_singleton": is_singleton,
			"order": int(orders_by_name.get(property_name, 0)),
			"setting_name": property_name,
			"raw_value": raw_value
		})
	autoloads.sort_custom(Callable(self, "_compare_autoload_entries"))
	return autoloads

func _normalize_global_class_entries(entries: Array) -> Array:
	var classes: Array = []
	for entry in entries:
		if not (entry is Dictionary):
			continue
		classes.append({
			"name": str(entry.get("class", "")),
			"path": str(entry.get("path", "")),
			"base": str(entry.get("base", "")),
			"language": str(entry.get("language", "")),
			"is_tool": bool(entry.get("is_tool", false)),
			"is_abstract": bool(entry.get("is_abstract", false)),
			"icon": str(entry.get("icon", ""))
		})
	classes.sort_custom(Callable(self, "_compare_global_class_entries"))
	return classes

func _build_classdb_api_metadata(target_class_name: String, filter: String = "") -> Dictionary:
	return {
		"class_name": target_class_name,
		"source": "classdb",
		"base_class": ClassDB.get_parent_class(target_class_name),
		"api_type": ClassDB.class_get_api_type(target_class_name),
		"methods": _normalize_method_entries(ClassDB.class_get_method_list(target_class_name), filter),
		"properties": _normalize_property_entries(ClassDB.class_get_property_list(target_class_name), filter),
		"signals": _normalize_signal_entries(ClassDB.class_get_signal_list(target_class_name), filter),
		"constants": _normalize_constant_entries(target_class_name, filter)
	}

func _normalize_method_entries(entries: Array, filter: String = "") -> Array:
	var methods: Array = []
	for entry in entries:
		if not (entry is Dictionary):
			continue
		var method_name: String = str(entry.get("name", ""))
		if method_name.is_empty():
			continue
		if not filter.is_empty() and not method_name.to_lower().contains(filter):
			continue
		methods.append({
			"name": method_name,
			"flags": int(entry.get("flags", 0)),
			"id": int(entry.get("id", 0)),
			"return": _normalize_typed_value_info(entry.get("return", {})),
			"arguments": _normalize_typed_value_info_array(entry.get("args", [])),
			"default_argument_count": entry.get("default_args", []).size()
		})
	methods.sort_custom(Callable(self, "_compare_named_entries"))
	return methods

func _normalize_property_entries(entries: Array, filter: String = "") -> Array:
	var properties: Array = []
	for entry in entries:
		if not (entry is Dictionary):
			continue
		var property_name: String = str(entry.get("name", ""))
		if property_name.is_empty():
			continue
		if not filter.is_empty() and not property_name.to_lower().contains(filter):
			continue
		properties.append({
			"name": property_name,
			"type": int(entry.get("type", TYPE_NIL)),
			"class_name": str(entry.get("class_name", "")),
			"hint": int(entry.get("hint", PROPERTY_HINT_NONE)),
			"hint_string": str(entry.get("hint_string", "")),
			"usage": int(entry.get("usage", 0)),
			"setter": str(entry.get("setter", "")),
			"getter": str(entry.get("getter", ""))
		})
	properties.sort_custom(Callable(self, "_compare_named_entries"))
	return properties

func _normalize_signal_entries(entries: Array, filter: String = "") -> Array:
	var signals: Array = []
	for entry in entries:
		if not (entry is Dictionary):
			continue
		var signal_name: String = str(entry.get("name", ""))
		if signal_name.is_empty():
			continue
		if not filter.is_empty() and not signal_name.to_lower().contains(filter):
			continue
		signals.append({
			"name": signal_name,
			"flags": int(entry.get("flags", 0)),
			"id": int(entry.get("id", 0)),
			"arguments": _normalize_typed_value_info_array(entry.get("args", []))
		})
	signals.sort_custom(Callable(self, "_compare_named_entries"))
	return signals

func _normalize_constant_entries(target_class_name: String, filter: String = "") -> Array:
	var constants: Array = []
	for constant_name in ClassDB.class_get_integer_constant_list(target_class_name):
		var constant_name_text: String = str(constant_name)
		if not filter.is_empty() and not constant_name_text.to_lower().contains(filter):
			continue
		constants.append({
			"name": constant_name_text,
			"value": ClassDB.class_get_integer_constant(target_class_name, constant_name_text),
			"enum": str(ClassDB.class_get_integer_constant_enum(target_class_name, constant_name_text))
		})
	constants.sort_custom(Callable(self, "_compare_named_entries"))
	return constants

func _normalize_typed_value_info_array(entries: Array) -> Array:
	var normalized: Array = []
	for entry in entries:
		normalized.append(_normalize_typed_value_info(entry))
	return normalized

func _normalize_typed_value_info(entry: Variant) -> Dictionary:
	if not (entry is Dictionary):
		return {}
	return {
		"name": str(entry.get("name", "")),
		"type": int(entry.get("type", TYPE_NIL)),
		"class_name": str(entry.get("class_name", "")),
		"hint": int(entry.get("hint", PROPERTY_HINT_NONE)),
		"hint_string": str(entry.get("hint_string", "")),
		"usage": int(entry.get("usage", 0))
	}

func _collect_project_input_actions(action_name_filter: String = "") -> Array:
	var actions: Array = []
	for property_info in ProjectSettings.get_property_list():
		var property_name: String = str(property_info.get("name", ""))
		if not property_name.begins_with("input/"):
			continue
		var action_name: String = property_name.get_slice("/", 1)
		if not action_name_filter.is_empty() and action_name != action_name_filter:
			continue
		var raw_value: Variant = ProjectSettings.get_setting(property_name, {})
		if not (raw_value is Dictionary):
			continue
		var stored_events: Array = raw_value.get("events", [])
		var events: Array = []
		for stored_event in stored_events:
			if stored_event is InputEvent:
				events.append(_serialize_project_input_event(stored_event))
		actions.append({
			"action_name": action_name,
			"deadzone": float(raw_value.get("deadzone", 0.5)),
			"events": events,
			"event_count": events.size(),
			"setting_name": property_name
		})
	actions.sort_custom(Callable(self, "_sort_project_input_actions"))
	return actions

func _build_project_input_event(payload: Dictionary) -> InputEvent:
	var event_type: String = str(payload.get("type", "")).to_lower()
	match event_type:
		"action":
			var action_name: String = str(payload.get("action_name", ""))
			if action_name.is_empty():
				return null
			var action_event := InputEventAction.new()
			action_event.action = StringName(action_name)
			action_event.pressed = bool(payload.get("pressed", true))
			action_event.strength = float(payload.get("strength", 1.0 if action_event.pressed else 0.0))
			return action_event
		"key":
			var keycode: int = int(payload.get("keycode", 0))
			if keycode == 0:
				return null
			var key_event := InputEventKey.new()
			key_event.keycode = keycode
			key_event.physical_keycode = int(payload.get("physical_keycode", 0))
			key_event.unicode = int(payload.get("unicode", 0))
			key_event.pressed = bool(payload.get("pressed", true))
			key_event.echo = bool(payload.get("echo", false))
			_apply_project_input_modifiers(key_event, payload)
			return key_event
		"mouse_button":
			var button_index: int = int(payload.get("button_index", 0))
			if button_index == 0:
				return null
			var mouse_button_event := InputEventMouseButton.new()
			mouse_button_event.button_index = button_index
			mouse_button_event.pressed = bool(payload.get("pressed", true))
			mouse_button_event.double_click = bool(payload.get("double_click", false))
			mouse_button_event.factor = float(payload.get("factor", 1.0))
			mouse_button_event.button_mask = int(payload.get("button_mask", 0))
			mouse_button_event.position = _dict_to_project_vector2(payload.get("position", {}))
			mouse_button_event.global_position = _dict_to_project_vector2(payload.get("global_position", payload.get("position", {})))
			_apply_project_input_modifiers(mouse_button_event, payload)
			return mouse_button_event
		"mouse_motion":
			var mouse_motion_event := InputEventMouseMotion.new()
			mouse_motion_event.position = _dict_to_project_vector2(payload.get("position", {}))
			mouse_motion_event.global_position = _dict_to_project_vector2(payload.get("global_position", payload.get("position", {})))
			mouse_motion_event.relative = _dict_to_project_vector2(payload.get("relative", {}))
			mouse_motion_event.velocity = _dict_to_project_vector2(payload.get("velocity", {}))
			mouse_motion_event.button_mask = int(payload.get("button_mask", 0))
			mouse_motion_event.pressure = float(payload.get("pressure", 0.0))
			mouse_motion_event.pen_inverted = bool(payload.get("pen_inverted", false))
			_apply_project_input_modifiers(mouse_motion_event, payload)
			return mouse_motion_event
		_:
			return null

func _apply_project_input_modifiers(event: InputEventWithModifiers, payload: Dictionary) -> void:
	event.alt_pressed = bool(payload.get("alt_pressed", false))
	event.shift_pressed = bool(payload.get("shift_pressed", false))
	event.ctrl_pressed = bool(payload.get("ctrl_pressed", false))
	event.meta_pressed = bool(payload.get("meta_pressed", false))
	event.command_or_control_autoremap = bool(payload.get("command_or_control_autoremap", false))

func _dict_to_project_vector2(value: Variant) -> Vector2:
	if value is Dictionary:
		return Vector2(float(value.get("x", 0.0)), float(value.get("y", 0.0)))
	return Vector2.ZERO

func _serialize_project_input_event(event: InputEvent) -> Dictionary:
	if event is InputEventAction:
		return {
			"type": "action",
			"action_name": String(event.action),
			"pressed": event.pressed,
			"strength": event.strength
		}
	if event is InputEventKey:
		return {
			"type": "key",
			"keycode": event.keycode,
			"physical_keycode": event.physical_keycode,
			"unicode": event.unicode,
			"pressed": event.pressed,
			"echo": event.echo
		}
	if event is InputEventMouseButton:
		return {
			"type": "mouse_button",
			"button_index": event.button_index,
			"pressed": event.pressed,
			"double_click": event.double_click,
			"position": {"x": event.position.x, "y": event.position.y}
		}
	if event is InputEventMouseMotion:
		return {
			"type": "mouse_motion",
			"position": {"x": event.position.x, "y": event.position.y},
			"relative": {"x": event.relative.x, "y": event.relative.y},
			"velocity": {"x": event.velocity.x, "y": event.velocity.y}
		}
	return {"type": "unknown", "class": event.get_class()}

func _inspect_csproj_file(project_path: String) -> Dictionary:
	var parser := XMLParser.new()
	var open_error: Error = parser.open(project_path)
	if open_error != OK:
		return {"path": project_path, "error": "Failed to open csproj: " + str(open_error)}

	var result: Dictionary = {
		"path": project_path,
		"sdk": "",
		"target_frameworks": [],
		"assembly_name": "",
		"root_namespace": "",
		"nullable": "",
		"lang_version": "",
		"package_references": [],
		"project_references": []
	}
	var current_text_field: String = ""

	while true:
		var read_error: Error = parser.read()
		if read_error == ERR_FILE_EOF:
			break
		if read_error != OK:
			result["error"] = "Failed to parse csproj: " + str(read_error)
			break

		match parser.get_node_type():
			XMLParser.NODE_ELEMENT:
				var node_name: String = parser.get_node_name()
				match node_name:
					"Project":
						result["sdk"] = parser.get_named_attribute_value_safe("Sdk")
					"TargetFramework", "TargetFrameworks", "AssemblyName", "RootNamespace", "Nullable", "LangVersion":
						current_text_field = node_name
					"PackageReference":
						result["package_references"].append({
							"include": parser.get_named_attribute_value_safe("Include"),
							"version": parser.get_named_attribute_value_safe("Version"),
							"condition": parser.get_named_attribute_value_safe("Condition")
						})
					"ProjectReference":
						result["project_references"].append({
							"include": parser.get_named_attribute_value_safe("Include"),
							"name": parser.get_named_attribute_value_safe("Name")
						})
			XMLParser.NODE_TEXT:
				if current_text_field.is_empty():
					continue
				var text_value: String = parser.get_node_data().strip_edges()
				if text_value.is_empty():
					continue
				match current_text_field:
					"TargetFramework":
						result["target_frameworks"] = [text_value]
					"TargetFrameworks":
						result["target_frameworks"] = _split_semicolon_values(text_value)
					"AssemblyName":
						result["assembly_name"] = text_value
					"RootNamespace":
						result["root_namespace"] = text_value
					"Nullable":
						result["nullable"] = text_value
					"LangVersion":
						result["lang_version"] = text_value
			XMLParser.NODE_ELEMENT_END:
				current_text_field = ""

	return result

func _inspect_solution_file(solution_path: String) -> Dictionary:
	var file: FileAccess = FileAccess.open(solution_path, FileAccess.READ)
	if not file:
		return {"path": solution_path, "error": "Failed to open solution file"}

	var entries: Array = []
	while not file.eof_reached():
		var raw_line: String = file.get_line()
		var line: String = raw_line.strip_edges()
		if not line.begins_with("Project("):
			continue
		var marker_index: int = line.find(" = ")
		if marker_index == -1:
			continue
		var tail: String = line.substr(marker_index + 3)
		var segments: PackedStringArray = tail.split(",")
		if segments.size() < 2:
			continue
		entries.append({
			"name": segments[0].strip_edges().trim_prefix("\"").trim_suffix("\""),
			"path": segments[1].strip_edges().trim_prefix("\"").trim_suffix("\"")
		})
	file.close()

	return {
		"path": solution_path,
		"project_count": entries.size(),
		"projects": entries
	}

func _split_semicolon_values(value: String) -> Array:
	var values: Array = []
	for segment in value.split(";"):
		var trimmed: String = segment.strip_edges()
		if not trimmed.is_empty():
			values.append(trimmed)
	return values


func _compare_autoload_entries(left: Dictionary, right: Dictionary) -> bool:
	var left_order: int = int(left.get("order", 0))
	var right_order: int = int(right.get("order", 0))
	if left_order == right_order:
		return str(left.get("name", "")) < str(right.get("name", ""))
	return left_order < right_order

func _compare_global_class_entries(left: Dictionary, right: Dictionary) -> bool:
	return str(left.get("name", "")) < str(right.get("name", ""))

func _compare_named_entries(left: Dictionary, right: Dictionary) -> bool:
	return str(left.get("name", "")) < str(right.get("name", ""))

func _sort_project_input_actions(left: Dictionary, right: Dictionary) -> bool:
	return str(left.get("action_name", "")) < str(right.get("action_name", ""))


# ============================================================================
# set_project_setting - Set an arbitrary ProjectSettings key and persist it
# ============================================================================

func _register_set_project_setting(server_core: RefCounted) -> void:
	var tool_name: String = "set_project_setting"
	var description: String = "Set a project setting (ProjectSettings) and optionally persist it to project.godot. Use for window size, rendering, physics layers, application config, input device settings, etc. Pass value_type to coerce the value to int/float/bool/string/vector2/vector3/color; otherwise the value is stored as provided."

	var input_schema: Dictionary = {
		"type": "object",
		"properties": {
			"setting": {"type": "string", "description": "Setting key, e.g. 'display/window/size/viewport_width'."},
			"value": {"description": "New value. JSON scalars map directly; use value_type to coerce vectors/colors."},
			"value_type": {"type": "string", "description": "Optional coercion of value.", "enum": ["int", "float", "bool", "string", "vector2", "vector3", "color"]},
			"require_existing": {"type": "boolean", "description": "When true, fail if the setting does not already exist (guards against typos creating junk keys). Default false.", "default": false},
			"persist": {"type": "boolean", "description": "Persist to project.godot via ProjectSettings.save(). Default true.", "default": true}
		},
		"required": ["setting", "value"]
	}

	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"status": {"type": "string"},
			"setting": {"type": "string"},
			"previous": {},
			"new": {},
			"existed": {"type": "boolean"},
			"persisted": {"type": "boolean"}
		}
	}

	var annotations: Dictionary = {
		"readOnlyHint": false,
		"destructiveHint": false,
		"idempotentHint": true,
		"openWorldHint": false
	}

	server_core.register_tool(tool_name, description, input_schema,
						  Callable(self, "_tool_set_project_setting"),
						  output_schema, annotations,
						  "supplementary", "Project-Advanced")

func _tool_set_project_setting(params: Dictionary) -> Dictionary:
	var setting: String = str(params.get("setting", "")).strip_edges()
	if setting.is_empty():
		return {"error": "Missing required parameter: setting"}
	if not params.has("value"):
		return {"error": "Missing required parameter: value"}

	var existed: bool = ProjectSettings.has_setting(setting)
	if bool(params.get("require_existing", false)) and not existed:
		return {"error": "Project setting does not exist: " + setting}

	var value_type: String = str(params.get("value_type", "")).strip_edges().to_lower()
	var coerced: Dictionary = _coerce_setting_value(params["value"], value_type)
	if coerced.has("error"):
		return {"error": coerced["error"]}
	var new_value: Variant = coerced["value"]

	var previous: Variant = ProjectSettings.get_setting(setting) if existed else null
	ProjectSettings.set_setting(setting, new_value)

	var persisted: bool = false
	if bool(params.get("persist", true)):
		var save_error: Error = ProjectSettings.save()
		if save_error != OK:
			return {"error": "Failed to save project settings: " + error_string(save_error)}
		persisted = true

	return {
		"status": "success",
		"setting": setting,
		"previous": previous,
		"new": new_value,
		"existed": existed,
		"persisted": persisted
	}

# Coerce a raw parameter value to the requested type for ProjectSettings.

# Validate that a string is a legal GDScript/autoload identifier.
func _is_valid_identifier(text: String) -> bool:
	if text.is_empty():
		return false
	var regex: RegEx = RegEx.new()
	regex.compile("^[A-Za-z_][A-Za-z0-9_]*$")
	return regex.search(text) != null


# ============================================================================
# add_project_autoload - Register an autoload singleton in project.godot
# ============================================================================

func _register_add_project_autoload(server_core: RefCounted) -> void:
	var tool_name: String = "add_project_autoload"
	var description: String = "Register a project autoload singleton (e.g. a GameState/RNG/SaveManager script) and persist it to project.godot. The path must point to an existing .gd/.tscn/.scn/.cs resource. Set enabled=false to register the autoload without the singleton '*' prefix; pass overwrite=true to replace an existing entry of the same name."

	var input_schema: Dictionary = {
		"type": "object",
		"properties": {
			"name": {"type": "string", "description": "Autoload name; must be a valid identifier, e.g. 'GameState'."},
			"path": {"type": "string", "description": "res:// path to the autoload script or scene (.gd/.tscn/.scn/.cs)."},
			"enabled": {"type": "boolean", "description": "Register as an enabled singleton ('*' prefix). Default true.", "default": true},
			"overwrite": {"type": "boolean", "description": "Overwrite an existing autoload with the same name. Default false.", "default": false},
			"persist": {"type": "boolean", "description": "Persist to project.godot via ProjectSettings.save(). Default true.", "default": true}
		},
		"required": ["name", "path"]
	}

	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"status": {"type": "string"},
			"name": {"type": "string"},
			"path": {"type": "string"},
			"setting": {"type": "string"},
			"enabled": {"type": "boolean"},
			"replaced": {"type": "boolean"},
			"persisted": {"type": "boolean"}
		}
	}

	var annotations: Dictionary = {
		"readOnlyHint": false,
		"destructiveHint": false,
		"idempotentHint": false,
		"openWorldHint": false
	}

	server_core.register_tool(tool_name, description, input_schema,
						  Callable(self, "_tool_add_project_autoload"),
						  output_schema, annotations,
						  "supplementary", "Project-Advanced")

func _tool_add_project_autoload(params: Dictionary) -> Dictionary:
	var autoload_name: String = str(params.get("name", "")).strip_edges()
	var path: String = str(params.get("path", "")).strip_edges()
	if autoload_name.is_empty():
		return {"error": "Missing required parameter: name"}
	if path.is_empty():
		return {"error": "Missing required parameter: path"}
	if not _is_valid_identifier(autoload_name):
		return {"error": "Invalid autoload name: must be a valid identifier (letters, digits, underscore; not starting with a digit)"}

	var validation: Dictionary = PathValidator.validate_file_path(path, [".gd", ".tscn", ".scn", ".cs"])
	if not validation["valid"]:
		return {"error": "Invalid path: " + validation["error"]}
	path = validation["sanitized"]
	if not FileAccess.file_exists(path):
		return {"error": "Autoload path not found: " + path}

	var setting_key: String = "autoload/" + autoload_name
	var existed: bool = ProjectSettings.has_setting(setting_key)
	if existed and not bool(params.get("overwrite", false)):
		return {"error": "Autoload already exists: " + autoload_name + " (pass overwrite=true to replace)"}

	var enabled: bool = bool(params.get("enabled", true))
	var prefix: String = "*" if enabled else ""
	ProjectSettings.set_setting(setting_key, prefix + path)

	var persisted: bool = false
	if bool(params.get("persist", true)):
		var save_error: Error = ProjectSettings.save()
		if save_error != OK:
			return {"error": "Failed to save project settings: " + error_string(save_error)}
		persisted = true

	return {
		"status": "success",
		"name": autoload_name,
		"path": path,
		"setting": setting_key,
		"enabled": enabled,
		"replaced": existed,
		"persisted": persisted
	}

# ============================================================================
# remove_project_autoload - Remove an autoload singleton from project.godot
# ============================================================================

func _register_remove_project_autoload(server_core: RefCounted) -> void:
	var tool_name: String = "remove_project_autoload"
	var description: String = "Remove a project autoload singleton by name and persist the change to project.godot. Returns an error if no autoload with that name exists."

	var input_schema: Dictionary = {
		"type": "object",
		"properties": {
			"name": {"type": "string", "description": "Name of the autoload to remove, e.g. 'GameState'."},
			"persist": {"type": "boolean", "description": "Persist to project.godot via ProjectSettings.save(). Default true.", "default": true}
		},
		"required": ["name"]
	}

	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"status": {"type": "string"},
			"name": {"type": "string"},
			"setting": {"type": "string"},
			"removed_value": {"type": "string"},
			"persisted": {"type": "boolean"}
		}
	}

	var annotations: Dictionary = {
		"readOnlyHint": false,
		"destructiveHint": true,
		"idempotentHint": false,
		"openWorldHint": false
	}

	server_core.register_tool(tool_name, description, input_schema,
						  Callable(self, "_tool_remove_project_autoload"),
						  output_schema, annotations,
						  "supplementary", "Project-Advanced")

func _tool_remove_project_autoload(params: Dictionary) -> Dictionary:
	var autoload_name: String = str(params.get("name", "")).strip_edges()
	if autoload_name.is_empty():
		return {"error": "Missing required parameter: name"}

	var setting_key: String = "autoload/" + autoload_name
	if not ProjectSettings.has_setting(setting_key):
		return {"error": "Autoload not found: " + autoload_name}

	var removed_value: String = str(ProjectSettings.get_setting(setting_key))
	ProjectSettings.set_setting(setting_key, null)

	var persisted: bool = false
	if bool(params.get("persist", true)):
		var save_error: Error = ProjectSettings.save()
		if save_error != OK:
			return {"error": "Failed to save project settings: " + error_string(save_error)}
		persisted = true

	return {
		"status": "success",
		"name": autoload_name,
		"setting": setting_key,
		"removed_value": removed_value,
		"persisted": persisted
	}

