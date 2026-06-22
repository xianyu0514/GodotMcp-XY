# project_tools_native.gd - Project Tools原生实现

@tool
class_name ProjectToolsNative
extends RefCounted

const MAX_CONCURRENT_TEST_JOBS: int = 4

var _editor_interface: EditorInterface = null
var _test_runner: AsyncJobRunner = AsyncJobRunner.new()
var _batch_test_runner: AsyncJobRunner = AsyncJobRunner.new()

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
# 工具注册
# ============================================================================

func register_tools(server_core: RefCounted) -> void:
	_register_get_project_info(server_core)
	_register_get_project_settings(server_core)
	_register_list_project_tests(server_core)
	_register_run_project_test(server_core)
	_register_run_project_tests(server_core)
	_register_list_project_input_actions(server_core)
	_register_upsert_project_input_action(server_core)
	_register_remove_project_input_action(server_core)
	_register_list_project_autoloads(server_core)
	_register_list_project_global_classes(server_core)
	_register_get_class_api_metadata(server_core)
	_register_inspect_csharp_project_support(server_core)
	_register_compare_render_screenshots(server_core)
	_register_inspect_tileset_resource(server_core)
	_register_list_project_resources(server_core)
	_register_create_resource(server_core)
	_register_create_custom_resource(server_core)
	_register_batch_create_resources(server_core)
	_register_update_resource_properties(server_core)
	_register_read_resource_properties(server_core)
	_register_get_project_structure(server_core)
	_register_reimport_resources(server_core)
	_register_get_import_metadata(server_core)
	_register_get_resource_uid_info(server_core)
	_register_fix_resource_uid(server_core)
	_register_get_resource_dependencies(server_core)
	_register_scan_missing_resource_dependencies(server_core)
	_register_scan_cyclic_resource_dependencies(server_core)
	_register_detect_broken_scripts(server_core)
	_register_audit_project_health(server_core)
	_register_find_resource_usages(server_core)
	_register_list_unused_resources(server_core)
	_register_scan_migration_compatibility(server_core)
	_register_apply_migration_fixes(server_core)
	_register_find_deprecated_api_usage(server_core)
	_register_detect_gdextension_addons(server_core)
	_register_create_gradient_texture(server_core)
	_register_pack_pck(server_core)
	_register_configure_render_output(server_core)
	_register_create_drawable_texture(server_core)
	_register_draw_on_texture(server_core)
	_register_generate_asset(server_core)
	_register_create_theme(server_core)
	_register_set_theme_item(server_core)
	_register_set_default_theme(server_core)
	_register_set_project_setting(server_core)
	_register_add_project_autoload(server_core)
	_register_remove_project_autoload(server_core)
	_register_create_animation(server_core)
	_register_insert_animation_keys(server_core)
	_register_create_tileset(server_core)
	_register_configure_tileset_layers(server_core)
	_register_set_tile_collision_polygon(server_core)
	_register_set_tile_terrain(server_core)
	_register_manage_task_plan(server_core)

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

	# A test run spawns a full subprocess (python, or a headless Godot for GUT)
	# that can take seconds to minutes. Run it on a background thread so the
	# editor stays responsive: the first call starts the run and returns
	# "pending"; calling again with the same test_path polls for the result.
	if _test_runner.has_job(test_path):
		var polled: Dictionary = _test_runner.poll(test_path)
		if not bool(polled["finished"]):
			return {
				"status": "pending",
				"test_path": test_path,
				"elapsed_ms": _test_runner.elapsed_ms(test_path),
				"message": "Test is still running; call run_project_test again with the same test_path to poll for the result."
			}
		return polled["result"]

	if _active_test_job_count() >= MAX_CONCURRENT_TEST_JOBS:
		return {"error": "Too many test runs in progress; poll the pending runs before starting another."}

	_test_runner.start(test_path, Callable(self, "_execute_project_test_blocking").bind(test_path))
	return {
		"status": "pending",
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

	# A batch can spawn many test subprocesses back to back and take minutes.
	# Run the whole batch on a background thread so the editor stays responsive:
	# the first call starts the batch and returns "pending"; calling again with
	# the same arguments polls for the aggregated result.
	var job_key: String = search_path + "|" + framework + "|" + str(only_runnable)

	if _batch_test_runner.has_job(job_key):
		var polled: Dictionary = _batch_test_runner.poll(job_key)
		if not bool(polled["finished"]):
			return {
				"status": "pending",
				"search_path": search_path,
				"framework": framework,
				"elapsed_ms": _batch_test_runner.elapsed_ms(job_key),
				"message": "Test batch is still running; call run_project_tests again with the same arguments to poll for the result."
			}
		return polled["result"]

	if _active_test_job_count() >= MAX_CONCURRENT_TEST_JOBS:
		return {"error": "Too many test batches in progress; poll the pending runs before starting another."}

	var work_params: Dictionary = {
		"search_path": search_path,
		"framework": framework,
		"only_runnable": only_runnable
	}
	_batch_test_runner.start(job_key, Callable(self, "_execute_project_tests_blocking").bind(work_params))
	return {
		"status": "pending",
		"search_path": search_path,
		"framework": framework,
		"message": "Test batch started on a background thread; call run_project_tests again with the same arguments to poll for the result."
	}

# Blocking execution of a test batch. Used by the background worker thread for
# run_project_tests. Discovers tests and runs each one synchronously.
func _execute_project_tests_blocking(params: Dictionary) -> Dictionary:
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

	for entry in discovered_tests:
		if not (entry is Dictionary):
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
			continue
		var test_result: Dictionary = _execute_project_test_blocking(String(test_entry.get("test_path", "")))
		results.append(test_result)
		if test_result.get("status", "") == "passed":
			passed_count += 1
		else:
			failed_count += 1

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
			if pixel_delta > 0.00001:
				diff_pixel_count += 1
			max_channel_delta = maxf(max_channel_delta, pixel_delta)
			squared_error_sum += dr * dr + dg * dg + db * db + da * da

	var total_pixels: int = width * height
	var total_channels: int = total_pixels * 4
	var rmse: float = sqrt(squared_error_sum / float(total_channels)) if total_channels > 0 else 0.0
	var diff_ratio: float = float(diff_pixel_count) / float(total_pixels) if total_pixels > 0 else 0.0
	var max_diff_pixels: int = max(0, int(params.get("max_diff_pixels", 0)))

	return {
		"baseline_path": baseline_path,
		"candidate_path": candidate_path,
		"width": width,
		"height": height,
		"diff_pixel_count": diff_pixel_count,
		"diff_ratio": diff_ratio,
		"rmse": rmse,
		"max_channel_delta": max_channel_delta,
		"matches": diff_pixel_count <= max_diff_pixels
	}

# ============================================================================
# inspect_tileset_resource - 检查 TileSet 资源
# ============================================================================

func _register_inspect_tileset_resource(server_core: RefCounted) -> void:
	var tool_name: String = "inspect_tileset_resource"
	var description: String = "Inspect a TileSet resource and summarize its sources, atlas tiles, and scene tiles."

	var input_schema: Dictionary = {
		"type": "object",
		"properties": {
			"resource_path": {
				"type": "string",
				"description": "Path to a TileSet resource, such as 'res://tiles/terrain.tres'."
			},
			"include_tiles": {
				"type": "boolean",
				"description": "Whether to include per-tile entries for atlas and scene sources. Default is true."
			}
		},
		"required": ["resource_path"]
	}

	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"resource_path": {"type": "string"},
			"source_count": {"type": "integer"},
			"tile_size": {"type": "object"},
			"sources": {"type": "array"}
		}
	}

	var annotations: Dictionary = {
		"readOnlyHint": true,
		"destructiveHint": false,
		"idempotentHint": true,
		"openWorldHint": false
	}

	server_core.register_tool(tool_name, description, input_schema,
						  Callable(self, "_tool_inspect_tileset_resource"),
						  output_schema, annotations,
						  "supplementary", "Project-Advanced")

func _tool_inspect_tileset_resource(params: Dictionary) -> Dictionary:
	var resource_path: String = str(params.get("resource_path", "")).strip_edges()
	if resource_path.is_empty():
		return {"error": "Missing required parameter: resource_path"}

	var validation: Dictionary = PathValidator.validate_file_path(resource_path, [".tres", ".res"])
	if not validation.get("valid", false):
		return {"error": validation.get("error", "Invalid resource path")}
	resource_path = str(validation.get("sanitized", resource_path))

	if not FileAccess.file_exists(resource_path):
		return {"error": "File not found: " + resource_path}

	var resource: Resource = ResourceLoader.load(resource_path)
	if resource == null:
		return {"error": "Failed to load resource: " + resource_path}
	if not (resource is TileSet):
		return {"error": "Resource is not a TileSet: " + resource_path}

	var tile_set: TileSet = resource as TileSet
	var include_tiles: bool = bool(params.get("include_tiles", true))
	var sources: Array = []
	for index in range(tile_set.get_source_count()):
		var source_id: int = tile_set.get_source_id(index)
		var source: TileSetSource = tile_set.get_source(source_id)
		sources.append(_serialize_tileset_source(source_id, source, include_tiles))

	return {
		"resource_path": resource_path,
		"source_count": tile_set.get_source_count(),
		"tile_size": _serialize_vector2i(tile_set.tile_size),
		"sources": sources
	}

# ============================================================================
# list_project_resources - 列出项目资源
# ============================================================================

func _register_list_project_resources(server_core: RefCounted) -> void:
	var tool_name: String = "list_project_resources"
	var description: String = "List all resource files in the project (.tres, .res, .png, .ogg, etc.)."
	
	# inputSchema
	var input_schema: Dictionary = {
		"type": "object",
		"properties": {
			"search_path": {
				"type": "string",
				"description": "Optional subpath to search. Default is 'res://'.",
				"default": "res://"
			},
			"resource_types": {
				"type": "array",
				"items": {"type": "string"},
				"description": "Optional list of file extensions to filter (e.g. ['.tres', '.png']). Returns all if not provided."
			}
		}
	}
	
	# outputSchema
	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"resources": {
				"type": "array",
				"items": {"type": "string"}
			},
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
						  Callable(self, "_tool_list_project_resources"),
						  output_schema, annotations,
						  "core", "Project")

func _tool_list_project_resources(params: Dictionary) -> Dictionary:
	# 参数提取
	var search_path: String = params.get("search_path", "res://")
	var resource_types: Array = params.get("resource_types", [])
	
	# 使用PathValidator验证路径安全性
	var validation: Dictionary = PathValidator.validate_directory_path(search_path)
	if not validation["valid"]:
		return {"error": "Invalid path: " + validation["error"]}
	
	# 使用清理后的路径
	search_path = validation["sanitized"]
	
	# 常见资源扩展名
	var default_extensions: Array[String] = [
		".tres", ".res", ".otr", ".font", ".theme",
		".png", ".jpg", ".jpeg", ".webp", ".svg", ".bmp", ".hdr",
		".ogg", ".wav", ".mp3", ".oggstr",
		".obj", ".glb", ".gltf", ".mesh", ".fbx",
		".material", ".shader", ".gdshader",
		".tscn", ".gd", ".cfg", ".json",
		".ttf", ".otf", ".woff", ".woff2"
	]
	
	# 如果提供了resource_types，使用它；否则使用默认扩展名
	var extensions: Array[String] = []
	if resource_types.size() > 0:
		for ext in resource_types:
			var ext_str: String = str(ext)
			if not ext_str.begins_with("."):
				ext_str = "." + ext_str
			extensions.append(ext_str)
	else:
		extensions = default_extensions
	
	# 使用DirAccess递归查找资源文件
	var resources: Array[String] = []
	_collect_resources(search_path, extensions, resources)
	
	# 排序
	resources.sort()
	
	return {
		"resources": resources,
		"count": resources.size()
	}

# 辅助函数：递归收集资源文件
func _collect_resources(directory_path: String, extensions: Array[String], result: Array[String]) -> void:
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

# ============================================================================
# create_resource - 创建资源
# ============================================================================

func _register_create_resource(server_core: RefCounted) -> void:
	var tool_name: String = "create_resource"
	var description: String = "Create a new Godot resource file (.tres). Supports common resource types."
	
	# inputSchema
	var input_schema: Dictionary = {
		"type": "object",
		"properties": {
			"resource_path": {
				"type": "string",
				"description": "Path where the resource will be saved (e.g. 'res://resources/my_curve.tres')"
			},
			"resource_type": {
				"type": "string",
				"description": "Type of resource to create (e.g. 'Curve', 'Gradient', 'StyleBoxFlat', 'Animation')"
			},
			"properties": {
				"type": "object",
				"description": "Optional dictionary of property values to set on the resource"
			}
		},
		"required": ["resource_path", "resource_type"]
	}
	
	# outputSchema
	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"status": {"type": "string"},
			"resource_path": {"type": "string"},
			"resource_type": {"type": "string"}
		}
	}
	
	# annotations
	var annotations: Dictionary = {
		"readOnlyHint": false,
		"destructiveHint": false,
		"idempotentHint": false,
		"openWorldHint": false
	}
	
	# 注册工具
	server_core.register_tool(tool_name, description, input_schema,
						  Callable(self, "_tool_create_resource"),
						  output_schema, annotations,
						  "supplementary", "Project-Advanced")

func _tool_create_resource(params: Dictionary) -> Dictionary:
	# 参数提取
	var resource_path: String = params.get("resource_path", "")
	var resource_type: String = params.get("resource_type", "")
	var properties: Dictionary = params.get("properties", {})
	
	# 参数验证
	if resource_path.is_empty():
		return {"error": "Missing required parameter: resource_path"}
	if resource_type.is_empty():
		return {"error": "Missing required parameter: resource_type"}
	
	# 使用PathValidator验证路径安全性
	var validation: Dictionary = PathValidator.validate_file_path(resource_path, [".tres", ".res"])
	if not validation["valid"]:
		return {"error": "Invalid path: " + validation["error"]}
	
	# 使用清理后的路径
	resource_path = validation["sanitized"]
	
	# 验证资源类型
	if not ClassDB.class_exists(resource_type):
		return {"error": "Invalid resource type: " + resource_type}
	
	if not ClassDB.is_parent_class(resource_type, "Resource"):
		return {"error": "Type '%s' is not a Resource type" % resource_type}
	
	# 创建资源实例
	var resource: RefCounted = ClassDB.instantiate(resource_type)
	
	if not resource:
		return {"error": "Failed to create resource of type: " + resource_type}
	
	# 设置属性（如果有）
	for prop_name in properties:
		if prop_name in resource:
			var converted_val: Variant = _convert_value_for_resource(resource, prop_name, properties[prop_name])
			resource.set(prop_name, converted_val)
	
	# 保存资源
	var error: Error = ResourceSaver.save(resource, resource_path)
	
	if error != OK:
		return {"error": "Failed to save resource: " + error_string(error)}
	
	return {
		"status": "success",
		"resource_path": resource_path,
		"resource_type": resource_type
	}

func _convert_value_for_resource(resource: Resource, property_name: String, value: Variant) -> Variant:
	if value == null:
		return value
	var property_type: int = TYPE_NIL
	for prop in resource.get_property_list():
		if prop["name"] == property_name:
			property_type = prop["type"]
			break
	if property_type == TYPE_NIL:
		return value
	match property_type:
		TYPE_VECTOR2:
			if value is Dictionary:
				return Vector2(float(value.get("x", 0.0)), float(value.get("y", 0.0)))
			if value is String:
				var parsed: Dictionary = _parse_key_value_string(value)
				if not parsed.is_empty():
					return Vector2(float(parsed.get("x", 0.0)), float(parsed.get("y", 0.0)))
				var parts: PackedStringArray = value.replace("Vector2", "").replace("(", "").replace(")", "").replace(" ", "").split(",")
				if parts.size() >= 2:
					return Vector2(float(parts[0]), float(parts[1]))
		TYPE_VECTOR3:
			if value is Dictionary:
				return Vector3(float(value.get("x", 0.0)), float(value.get("y", 0.0)), float(value.get("z", 0.0)))
			if value is String:
				var parsed: Dictionary = _parse_key_value_string(value)
				if not parsed.is_empty():
					return Vector3(float(parsed.get("x", 0.0)), float(parsed.get("y", 0.0)), float(parsed.get("z", 0.0)))
				var parts: PackedStringArray = value.replace("Vector3", "").replace("(", "").replace(")", "").replace(" ", "").split(",")
				if parts.size() >= 3:
					return Vector3(float(parts[0]), float(parts[1]), float(parts[2]))
		TYPE_COLOR:
			if value is Dictionary:
				return Color(float(value.get("r", 0.0)), float(value.get("g", 0.0)), float(value.get("b", 0.0)), float(value.get("a", 1.0)))
			if value is String:
				if value.begins_with("#") or value.begins_with("Color"):
					return Color(value)
		TYPE_BOOL:
			if value is String:
				return value.to_lower() == "true"
			if value is int or value is float:
				return value != 0
		TYPE_INT:
			if value is String:
				return int(value)
			if value is float:
				return int(value)
		TYPE_FLOAT:
			if value is String:
				return float(value)
			if value is int:
				return float(value)
		TYPE_OBJECT:
			if value is String:
				if value.begins_with("res://"):
					var loaded_res: Resource = load(value)
					if loaded_res:
						return loaded_res
				if ClassDB.class_exists(value) and ClassDB.is_parent_class(value, "Resource"):
					return ClassDB.instantiate(value)
		TYPE_ARRAY:
			if value is Array:
				var result: Array = []
				for item in value:
					result.append(_convert_value_for_resource(resource, property_name, item))
				return result
		TYPE_DICTIONARY:
			if value is Dictionary:
				var result: Dictionary = {}
				for key in value:
					result[key] = _convert_value_for_resource(resource, property_name, value[key])
				return result
	return value

func _parse_key_value_string(value: String) -> Dictionary:
	if not (value.begins_with("{") and value.ends_with("}")):
		return {}
	var inner: String = value.substr(1, value.length() - 2).replace(" ", "")
	var result: Dictionary = {}
	var entries: PackedStringArray = inner.split(",")
	for entry in entries:
		var kv: PackedStringArray = entry.split(":")
		if kv.size() == 2:
			result[kv[0]] = kv[1]
	return result

# ============================================================================
# Shared helpers for data-driven resource tools
# ============================================================================

# Resolve a Resource instance from an explicit script path, a built-in ClassDB
# type, or a project global class_name. Returns {"resource": Resource} on
# success or {"error": String} on failure.
func _instantiate_resource_for_write(resource_type: String, script_path: String) -> Dictionary:
	if not script_path.is_empty():
		if not ResourceLoader.exists(script_path):
			return {"error": "Script not found: " + script_path}
		var script: Resource = load(script_path)
		if not (script is Script):
			return {"error": "Path is not a script: " + script_path}
		var instance: Variant = script.new()
		if not (instance is Resource):
			return {"error": "Script does not extend Resource: " + script_path}
		return {"resource": instance}

	if resource_type.is_empty():
		return {"error": "Provide resource_type (built-in type or class_name) or script_path"}

	if ClassDB.class_exists(resource_type):
		if not ClassDB.is_parent_class(resource_type, "Resource"):
			return {"error": "Type '%s' is not a Resource type" % resource_type}
		if not ClassDB.can_instantiate(resource_type):
			return {"error": "Cannot instantiate Resource class: " + resource_type}
		return {"resource": ClassDB.instantiate(resource_type)}

	var global_entry: Dictionary = _find_project_global_class_entry(resource_type)
	if global_entry.is_empty():
		return {"error": "Unknown resource type or class_name: " + resource_type}
	var global_script_path: String = str(global_entry.get("path", ""))
	var global_script: Resource = load(global_script_path)
	if not (global_script is Script):
		return {"error": "Failed to load class script: " + global_script_path}
	var global_instance: Variant = global_script.new()
	if not (global_instance is Resource):
		return {"error": "Class '%s' does not extend Resource" % resource_type}
	return {"resource": global_instance}

# Apply a properties dict onto a resource, converting each value to the target
# property's declared type. Records applied/skipped property names in place.
func _apply_properties_to_resource(resource: Resource, properties: Dictionary, applied: Array, skipped: Array) -> void:
	for prop_name in properties:
		if prop_name in resource:
			var converted_val: Variant = _convert_value_for_resource(resource, prop_name, properties[prop_name])
			resource.set(prop_name, converted_val)
			applied.append(prop_name)
		else:
			skipped.append(prop_name)

# Convert a resource property value into a JSON-friendly representation.
func _serialize_resource_value(value: Variant) -> Variant:
	match typeof(value):
		TYPE_NIL, TYPE_BOOL, TYPE_INT, TYPE_FLOAT, TYPE_STRING:
			return value
		TYPE_STRING_NAME:
			return str(value)
		TYPE_VECTOR2:
			return {"x": value.x, "y": value.y}
		TYPE_VECTOR3:
			return {"x": value.x, "y": value.y, "z": value.z}
		TYPE_COLOR:
			return {"r": value.r, "g": value.g, "b": value.b, "a": value.a}
		TYPE_ARRAY:
			var arr: Array = []
			for item in value:
				arr.append(_serialize_resource_value(item))
			return arr
		TYPE_DICTIONARY:
			var dict: Dictionary = {}
			for key in value:
				dict[str(key)] = _serialize_resource_value(value[key])
			return dict
		TYPE_OBJECT:
			if value is Resource:
				var res_path: String = value.resource_path
				if not res_path.is_empty():
					return res_path
				return "<SubResource:%s>" % value.get_class()
			return str(value)
		_:
			return str(value)

# ============================================================================
# create_custom_resource - create a custom/script-backed Resource instance
# ============================================================================

func _register_create_custom_resource(server_core: RefCounted) -> void:
	var tool_name: String = "create_custom_resource"
	var description: String = "Create a .tres/.res file for a custom class_name Resource (or a Resource script by path), setting exported properties. Unlike create_resource, this resolves project global classes (e.g. CardData) and explicit script paths, not just built-in engine types."

	var input_schema: Dictionary = {
		"type": "object",
		"properties": {
			"resource_path": {"type": "string", "description": "Save path (.tres or .res), e.g. res://data/cards/strike.tres."},
			"resource_type": {"type": "string", "description": "Built-in Resource type or a project class_name (e.g. CardData). Provide this or script_path."},
			"script_path": {"type": "string", "description": "Path to a Resource script to instantiate (e.g. res://data/card_data.gd). Takes precedence over resource_type."},
			"properties": {"type": "object", "description": "Exported properties to set on the new resource."}
		},
		"required": ["resource_path"]
	}

	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"status": {"type": "string"},
			"resource_path": {"type": "string"},
			"resource_type": {"type": "string"},
			"script_path": {"type": "string"},
			"applied_properties": {"type": "array", "items": {"type": "string"}},
			"skipped_properties": {"type": "array", "items": {"type": "string"}}
		}
	}

	var annotations: Dictionary = {
		"readOnlyHint": false,
		"destructiveHint": false,
		"idempotentHint": false,
		"openWorldHint": false
	}

	server_core.register_tool(tool_name, description, input_schema,
						  Callable(self, "_tool_create_custom_resource"),
						  output_schema, annotations,
						  "supplementary", "Project-Advanced")

func _tool_create_custom_resource(params: Dictionary) -> Dictionary:
	var resource_path: String = str(params.get("resource_path", "")).strip_edges()
	var resource_type: String = str(params.get("resource_type", "")).strip_edges()
	var script_path: String = str(params.get("script_path", "")).strip_edges()
	var properties: Dictionary = params.get("properties", {})

	if resource_path.is_empty():
		return {"error": "Missing required parameter: resource_path"}

	var validation: Dictionary = PathValidator.validate_file_path(resource_path, [".tres", ".res"])
	if not validation["valid"]:
		return {"error": "Invalid path: " + validation["error"]}
	resource_path = validation["sanitized"]

	var instantiated: Dictionary = _instantiate_resource_for_write(resource_type, script_path)
	if instantiated.has("error"):
		return {"error": instantiated["error"]}
	var resource: Resource = instantiated["resource"]

	var applied: Array = []
	var skipped: Array = []
	_apply_properties_to_resource(resource, properties, applied, skipped)

	var dir_path: String = resource_path.get_base_dir()
	if not dir_path.is_empty() and not DirAccess.dir_exists_absolute(dir_path):
		var mk: Error = DirAccess.make_dir_recursive_absolute(dir_path)
		if mk != OK:
			return {"error": "Failed to create directory: " + dir_path}

	var error: Error = ResourceSaver.save(resource, resource_path)
	if error != OK:
		return {"error": "Failed to save resource: " + error_string(error)}

	return {
		"status": "success",
		"resource_path": resource_path,
		"resource_type": resource_type,
		"script_path": script_path,
		"applied_properties": applied,
		"skipped_properties": skipped
	}

# ============================================================================
# batch_create_resources - create many resources from a list spec
# ============================================================================

func _register_batch_create_resources(server_core: RefCounted) -> void:
	var tool_name: String = "batch_create_resources"
	var description: String = "Create many resource files (.tres) in one call from a list spec. Shared resource_type/script_path/base_path/properties act as defaults that each item may override. Ideal for generating data-driven content such as card, relic, or enemy resource sets."

	var input_schema: Dictionary = {
		"type": "object",
		"properties": {
			"resources": {"type": "array", "description": "List of items. Each item: {resource_path|name, resource_type?, script_path?, properties?}.", "items": {"type": "object"}},
			"base_path": {"type": "string", "description": "Directory prefix combined with each item's name to build resource_path (e.g. res://data/cards/)."},
			"resource_type": {"type": "string", "description": "Default built-in type or class_name for items that omit it."},
			"script_path": {"type": "string", "description": "Default Resource script path for items that omit it."},
			"properties": {"type": "object", "description": "Default properties merged beneath each item's properties (item values win)."}
		},
		"required": ["resources"]
	}

	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"status": {"type": "string"},
			"created_count": {"type": "integer"},
			"failed_count": {"type": "integer"},
			"created": {"type": "array", "items": {"type": "string"}},
			"failed": {"type": "array", "items": {"type": "object"}}
		}
	}

	var annotations: Dictionary = {
		"readOnlyHint": false,
		"destructiveHint": false,
		"idempotentHint": false,
		"openWorldHint": false
	}

	server_core.register_tool(tool_name, description, input_schema,
						  Callable(self, "_tool_batch_create_resources"),
						  output_schema, annotations,
						  "supplementary", "Project-Advanced")

func _tool_batch_create_resources(params: Dictionary) -> Dictionary:
	var items: Array = params.get("resources", [])
	if items.is_empty():
		return {"error": "Missing required parameter: resources (non-empty array)"}

	var base_path: String = str(params.get("base_path", "")).strip_edges()
	var default_type: String = str(params.get("resource_type", "")).strip_edges()
	var default_script: String = str(params.get("script_path", "")).strip_edges()
	var default_props: Dictionary = params.get("properties", {})

	var created: Array = []
	var failed: Array = []

	for index in items.size():
		var item: Variant = items[index]
		if not (item is Dictionary):
			failed.append({"index": index, "error": "Item must be an object"})
			continue

		var resource_path: String = str(item.get("resource_path", "")).strip_edges()
		if resource_path.is_empty():
			var item_name: String = str(item.get("name", "")).strip_edges()
			if item_name.is_empty() or base_path.is_empty():
				failed.append({"index": index, "error": "Item needs resource_path, or name + base_path"})
				continue
			resource_path = base_path.path_join(item_name)
			if not (resource_path.ends_with(".tres") or resource_path.ends_with(".res")):
				resource_path += ".tres"

		var item_type: String = str(item.get("resource_type", default_type)).strip_edges()
		var item_script: String = str(item.get("script_path", default_script)).strip_edges()

		var merged_props: Dictionary = default_props.duplicate(true)
		var item_props: Dictionary = item.get("properties", {})
		for key in item_props:
			merged_props[key] = item_props[key]

		var single_params: Dictionary = {
			"resource_path": resource_path,
			"resource_type": item_type,
			"script_path": item_script,
			"properties": merged_props
		}
		var result: Dictionary = _tool_create_custom_resource(single_params)
		if result.has("error"):
			failed.append({"index": index, "resource_path": resource_path, "error": result["error"]})
		else:
			created.append(resource_path)

	return {
		"status": "success" if failed.is_empty() else "partial",
		"created_count": created.size(),
		"failed_count": failed.size(),
		"created": created,
		"failed": failed
	}

# ============================================================================
# update_resource_properties - edit an existing resource file in place
# ============================================================================

func _register_update_resource_properties(server_core: RefCounted) -> void:
	var tool_name: String = "update_resource_properties"
	var description: String = "Load an existing resource file (.tres/.res), set/merge exported properties, and re-save it. Use to tweak data such as card cost or enemy HP without rewriting the file by hand."

	var input_schema: Dictionary = {
		"type": "object",
		"properties": {
			"resource_path": {"type": "string", "description": "Path to an existing resource file."},
			"properties": {"type": "object", "description": "Properties to set on the resource."}
		},
		"required": ["resource_path", "properties"]
	}

	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"status": {"type": "string"},
			"resource_path": {"type": "string"},
			"updated_properties": {"type": "array", "items": {"type": "string"}},
			"skipped_properties": {"type": "array", "items": {"type": "string"}}
		}
	}

	var annotations: Dictionary = {
		"readOnlyHint": false,
		"destructiveHint": false,
		"idempotentHint": true,
		"openWorldHint": false
	}

	server_core.register_tool(tool_name, description, input_schema,
						  Callable(self, "_tool_update_resource_properties"),
						  output_schema, annotations,
						  "supplementary", "Project-Advanced")

func _tool_update_resource_properties(params: Dictionary) -> Dictionary:
	var resource_path: String = str(params.get("resource_path", "")).strip_edges()
	var properties: Dictionary = params.get("properties", {})

	if resource_path.is_empty():
		return {"error": "Missing required parameter: resource_path"}
	if properties.is_empty():
		return {"error": "Missing required parameter: properties (non-empty object)"}

	var validation: Dictionary = PathValidator.validate_file_path(resource_path, [".tres", ".res"])
	if not validation["valid"]:
		return {"error": "Invalid path: " + validation["error"]}
	resource_path = validation["sanitized"]

	if not ResourceLoader.exists(resource_path):
		return {"error": "Resource not found: " + resource_path}
	var resource: Resource = ResourceLoader.load(resource_path)
	if not resource:
		return {"error": "Failed to load resource: " + resource_path}

	var applied: Array = []
	var skipped: Array = []
	_apply_properties_to_resource(resource, properties, applied, skipped)

	var error: Error = ResourceSaver.save(resource, resource_path)
	if error != OK:
		return {"error": "Failed to save resource: " + error_string(error)}

	return {
		"status": "success",
		"resource_path": resource_path,
		"updated_properties": applied,
		"skipped_properties": skipped
	}

# ============================================================================
# read_resource_properties - dump a resource's exported properties as JSON
# ============================================================================

func _register_read_resource_properties(server_core: RefCounted) -> void:
	var tool_name: String = "read_resource_properties"
	var description: String = "Read a resource file (.tres/.res) and return its exported (script-declared) properties as JSON-friendly values. Optionally include built-in base Resource properties. Use to inspect or verify data-driven content."

	var input_schema: Dictionary = {
		"type": "object",
		"properties": {
			"resource_path": {"type": "string", "description": "Path to an existing resource file."},
			"include_built_in": {"type": "boolean", "description": "Include built-in base Resource storage properties (default false).", "default": false}
		},
		"required": ["resource_path"]
	}

	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"status": {"type": "string"},
			"resource_path": {"type": "string"},
			"resource_class": {"type": "string"},
			"script_path": {"type": "string"},
			"properties": {"type": "object"},
			"property_count": {"type": "integer"}
		}
	}

	var annotations: Dictionary = {
		"readOnlyHint": true,
		"destructiveHint": false,
		"idempotentHint": true,
		"openWorldHint": false
	}

	server_core.register_tool(tool_name, description, input_schema,
						  Callable(self, "_tool_read_resource_properties"),
						  output_schema, annotations,
						  "supplementary", "Project-Advanced")

func _tool_read_resource_properties(params: Dictionary) -> Dictionary:
	var resource_path: String = str(params.get("resource_path", "")).strip_edges()
	var include_built_in: bool = bool(params.get("include_built_in", false))

	if resource_path.is_empty():
		return {"error": "Missing required parameter: resource_path"}

	var validation: Dictionary = PathValidator.validate_file_path(resource_path, [".tres", ".res"])
	if not validation["valid"]:
		return {"error": "Invalid path: " + validation["error"]}
	resource_path = validation["sanitized"]

	if not ResourceLoader.exists(resource_path):
		return {"error": "Resource not found: " + resource_path}
	var resource: Resource = ResourceLoader.load(resource_path)
	if not resource:
		return {"error": "Failed to load resource: " + resource_path}

	var script_path: String = ""
	var script: Variant = resource.get_script()
	if script is Script:
		script_path = script.resource_path

	var properties: Dictionary = {}
	for prop in resource.get_property_list():
		var prop_name: String = str(prop.get("name", ""))
		var usage: int = int(prop.get("usage", 0))
		if prop_name.is_empty() or prop_name == "script":
			continue
		var is_script_var: bool = (usage & PROPERTY_USAGE_SCRIPT_VARIABLE) != 0
		var is_storage: bool = (usage & PROPERTY_USAGE_STORAGE) != 0
		if is_script_var:
			properties[prop_name] = _serialize_resource_value(resource.get(prop_name))
		elif include_built_in and is_storage:
			properties[prop_name] = _serialize_resource_value(resource.get(prop_name))

	return {
		"status": "success",
		"resource_path": resource_path,
		"resource_class": resource.get_class(),
		"script_path": script_path,
		"properties": properties,
		"property_count": properties.size()
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

# ============================================================================
# reimport_resources - 重新导入指定资源
# ============================================================================

func _register_reimport_resources(server_core: RefCounted) -> void:
	var tool_name: String = "reimport_resources"
	var description: String = "Reimport existing project resources using Godot's EditorFileSystem import pipeline."

	var input_schema: Dictionary = {
		"type": "object",
		"properties": {
			"resource_paths": {
				"type": "array",
				"items": {"type": "string"},
				"description": "Resource source file paths to reimport, e.g. ['res://icon.png']"
			},
			"refresh_metadata": {
				"type": "boolean",
				"description": "Whether to refresh EditorFileSystem metadata with update_file() before reimport. Default is true.",
				"default": true
			}
		},
		"required": ["resource_paths"]
	}

	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"status": {"type": "string"},
			"requested_count": {"type": "integer"},
			"reimported_count": {"type": "integer"},
			"resource_paths": {"type": "array"},
			"invalid_paths": {"type": "array"}
		}
	}

	var annotations: Dictionary = {
		"readOnlyHint": false,
		"destructiveHint": false,
		"idempotentHint": false,
		"openWorldHint": false
	}

	server_core.register_tool(tool_name, description, input_schema,
						  Callable(self, "_tool_reimport_resources"),
						  output_schema, annotations,
						  "supplementary", "Project-Advanced")

func _tool_reimport_resources(params: Dictionary) -> Dictionary:
	var raw_paths: Array = params.get("resource_paths", [])
	if raw_paths.is_empty():
		return {"error": "Missing required parameter: resource_paths"}

	var refresh_metadata: bool = params.get("refresh_metadata", true)
	var editor_interface: EditorInterface = _get_editor_interface()
	if not editor_interface:
		return {"error": "Editor interface not available"}

	var fs: EditorFileSystem = editor_interface.get_resource_filesystem()
	if not fs:
		return {"error": "Failed to get EditorFileSystem"}

	if fs.is_scanning():
		return {
			"status": "busy",
			"requested_count": raw_paths.size(),
			"reimported_count": 0,
			"resource_paths": [],
			"invalid_paths": [],
			"scan_progress": fs.get_scanning_progress()
		}

	var valid_paths: Array[String] = []
	var invalid_paths: Array[Dictionary] = []
	for raw_path in raw_paths:
		var resource_path: String = str(raw_path).strip_edges()
		var validation: Dictionary = PathValidator.validate_path(resource_path)
		if not validation["valid"]:
			invalid_paths.append({"path": resource_path, "error": validation["error"]})
			continue
		resource_path = validation["sanitized"]
		if not FileAccess.file_exists(resource_path):
			invalid_paths.append({"path": resource_path, "error": "File not found"})
			continue
		valid_paths.append(resource_path)

	if valid_paths.is_empty():
		return {
			"status": "no_valid_paths",
			"requested_count": raw_paths.size(),
			"reimported_count": 0,
			"resource_paths": [],
			"invalid_paths": invalid_paths
		}

	if refresh_metadata:
		for resource_path in valid_paths:
			fs.update_file(resource_path)

	var packed_paths: PackedStringArray = PackedStringArray()
	for resource_path in valid_paths:
		packed_paths.append(resource_path)
	fs.reimport_files(packed_paths)

	return {
		"status": "success",
		"requested_count": raw_paths.size(),
		"reimported_count": valid_paths.size(),
		"resource_paths": valid_paths,
		"invalid_paths": invalid_paths
	}

# ============================================================================
# get_import_metadata - 读取 .import 元数据
# ============================================================================

func _register_get_import_metadata(server_core: RefCounted) -> void:
	var tool_name: String = "get_import_metadata"
	var description: String = "Read Godot import metadata for a source asset, including importer settings and imported artifact paths."

	var input_schema: Dictionary = {
		"type": "object",
		"properties": {
			"resource_path": {
				"type": "string",
				"description": "Source asset path such as 'res://icon.png'"
			}
		},
		"required": ["resource_path"]
	}

	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"resource_path": {"type": "string"},
			"import_config_path": {"type": "string"},
			"exists": {"type": "boolean"},
			"importer": {"type": "string"},
			"resource_type": {"type": "string"},
			"uid": {"type": "string"},
			"imported_path": {"type": "string"},
			"sections": {"type": "object"}
		}
	}

	var annotations: Dictionary = {
		"readOnlyHint": true,
		"destructiveHint": false,
		"idempotentHint": true,
		"openWorldHint": false
	}

	server_core.register_tool(tool_name, description, input_schema,
						  Callable(self, "_tool_get_import_metadata"),
						  output_schema, annotations,
						  "supplementary", "Project-Advanced")

func _tool_get_import_metadata(params: Dictionary) -> Dictionary:
	var resource_path: String = str(params.get("resource_path", "")).strip_edges()
	if resource_path.is_empty():
		return {"error": "Missing required parameter: resource_path"}

	var validation: Dictionary = PathValidator.validate_path(resource_path)
	if not validation["valid"]:
		return {"error": "Invalid path: " + validation["error"]}
	resource_path = validation["sanitized"]

	var import_config_path: String = resource_path + ".import"
	if not FileAccess.file_exists(import_config_path):
		return {
			"resource_path": resource_path,
			"import_config_path": import_config_path,
			"exists": false
		}

	var config: ConfigFile = ConfigFile.new()
	var load_error: Error = config.load(import_config_path)
	if load_error != OK:
		return {"error": "Failed to load import metadata: " + error_string(load_error)}

	var sections: Dictionary = {}
	for raw_section in config.get_sections():
		var section_name: String = str(raw_section)
		var section_values: Dictionary = {}
		for raw_key in config.get_section_keys(section_name):
			var key_name: String = str(raw_key)
			section_values[key_name] = config.get_value(section_name, key_name)
		sections[section_name] = section_values

	var remap: Dictionary = sections.get("remap", {})
	var deps: Dictionary = sections.get("deps", {})
	var params_section: Dictionary = sections.get("params", {})

	return {
		"resource_path": resource_path,
		"import_config_path": import_config_path,
		"exists": true,
		"importer": str(remap.get("importer", "")),
		"resource_type": str(remap.get("type", "")),
		"uid": str(remap.get("uid", "")),
		"imported_path": str(remap.get("path", "")),
		"dependencies": deps,
		"params": params_section,
		"sections": sections
	}

# ============================================================================
# get_resource_uid_info - 读取资源 UID 信息
# ============================================================================

func _register_get_resource_uid_info(server_core: RefCounted) -> void:
	var tool_name: String = "get_resource_uid_info"
	var description: String = "Inspect Godot ResourceUID mappings for a resource path or uid:// identifier."

	var input_schema: Dictionary = {
		"type": "object",
		"properties": {
			"resource_path": {
				"type": "string",
				"description": "Resource path to inspect."
			},
			"uid": {
				"type": "string",
				"description": "Optional uid:// identifier to resolve."
			}
		}
	}

	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"resource_path": {"type": "string"},
			"uid": {"type": "string"},
			"uid_id": {"type": "string"},
			"editor_uid": {"type": "string"},
			"resolved_path": {"type": "string"},
			"exists": {"type": "boolean"},
			"has_uid_mapping": {"type": "boolean"}
		}
	}

	var annotations: Dictionary = {
		"readOnlyHint": true,
		"destructiveHint": false,
		"idempotentHint": true,
		"openWorldHint": false
	}

	server_core.register_tool(tool_name, description, input_schema,
						  Callable(self, "_tool_get_resource_uid_info"),
						  output_schema, annotations,
						  "supplementary", "Project-Advanced")

func _tool_get_resource_uid_info(params: Dictionary) -> Dictionary:
	var resource_path: String = str(params.get("resource_path", "")).strip_edges()
	var uid_text: String = str(params.get("uid", "")).strip_edges()
	if resource_path.is_empty() and uid_text.is_empty():
		return {"error": "Provide resource_path or uid"}

	if not resource_path.is_empty():
		var validation: Dictionary = PathValidator.validate_path(resource_path)
		if not validation["valid"]:
			return {"error": "Invalid path: " + validation["error"]}
		resource_path = validation["sanitized"]
		if uid_text.is_empty():
			var mapped_uid: String = ResourceUID.path_to_uid(resource_path)
			if mapped_uid.begins_with("uid://"):
				uid_text = mapped_uid

	if not uid_text.is_empty() and not uid_text.begins_with("uid://"):
		return {"error": "uid must start with uid://"}

	var resolved_path: String = ""
	if not uid_text.is_empty():
		resolved_path = ResourceUID.uid_to_path(uid_text)
		if resource_path.is_empty():
			resource_path = resolved_path

	if not resource_path.is_empty() and uid_text.is_empty():
		var remapped_uid: String = ResourceUID.path_to_uid(resource_path)
		if remapped_uid.begins_with("uid://"):
			uid_text = remapped_uid
			resolved_path = ResourceUID.uid_to_path(uid_text)

	var effective_path: String = resource_path if not resource_path.is_empty() else resolved_path
	var exists: bool = not effective_path.is_empty() and FileAccess.file_exists(effective_path)
	var has_uid_mapping: bool = uid_text.begins_with("uid://")

	return {
		"resource_path": resource_path,
		"uid": uid_text,
		"uid_id": "",
		"resolved_path": resolved_path,
		"exists": exists,
		"has_uid_mapping": has_uid_mapping,
		"editor_uid": ""
	}

# ============================================================================
# fix_resource_uid - 生成或修复资源 UID
# ============================================================================

func _register_fix_resource_uid(server_core: RefCounted) -> void:
	var tool_name: String = "fix_resource_uid"
	var description: String = "Ensure a resource file has a persisted UID and refresh the editor filesystem mapping."

	var input_schema: Dictionary = {
		"type": "object",
		"properties": {
			"resource_path": {
				"type": "string",
				"description": "Resource path to repair, e.g. 'res://resources/example.tres'"
			}
		},
		"required": ["resource_path"]
	}

	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"status": {"type": "string"},
			"resource_path": {"type": "string"},
			"previous_uid": {"type": "string"},
			"uid": {"type": "string"},
			"uid_id": {"type": "string"}
		}
	}

	var annotations: Dictionary = {
		"readOnlyHint": false,
		"destructiveHint": false,
		"idempotentHint": false,
		"openWorldHint": false
	}

	server_core.register_tool(tool_name, description, input_schema,
						  Callable(self, "_tool_fix_resource_uid"),
						  output_schema, annotations,
						  "supplementary", "Project-Advanced")

func _tool_fix_resource_uid(params: Dictionary) -> Dictionary:
	var resource_path: String = str(params.get("resource_path", "")).strip_edges()
	if resource_path.is_empty():
		return {"error": "Missing required parameter: resource_path"}

	var validation: Dictionary = PathValidator.validate_path(resource_path)
	if not validation["valid"]:
		return {"error": "Invalid path: " + validation["error"]}
	resource_path = validation["sanitized"]

	if not FileAccess.file_exists(resource_path):
		return {"error": "File not found: " + resource_path}

	var previous_uid: String = ResourceUID.path_to_uid(resource_path)
	if not previous_uid.begins_with("uid://"):
		previous_uid = ""

	var uid_id: int = ResourceSaver.get_resource_id_for_path(resource_path, true)
	if uid_id == ResourceUID.INVALID_ID:
		return {"error": "Failed to generate resource UID for: " + resource_path}

	var set_error: Error = ResourceSaver.set_uid(resource_path, uid_id)
	if set_error != OK:
		return {"error": "Failed to persist resource UID: " + error_string(set_error)}

	var editor_interface: EditorInterface = _get_editor_interface()
	if editor_interface:
		var fs: EditorFileSystem = editor_interface.get_resource_filesystem()
		if fs:
			fs.update_file(resource_path)

	var uid_text: String = ResourceUID.path_to_uid(resource_path)
	return {
		"status": "success",
		"resource_path": resource_path,
		"previous_uid": previous_uid,
		"uid": uid_text,
		"uid_id": str(uid_id)
	}

# ============================================================================
# get_resource_dependencies - 读取资源依赖
# ============================================================================

func _register_get_resource_dependencies(server_core: RefCounted) -> void:
	var tool_name: String = "get_resource_dependencies"
	var description: String = "List parsed resource dependencies using Godot's ResourceLoader dependency metadata."

	var input_schema: Dictionary = {
		"type": "object",
		"properties": {
			"resource_path": {
				"type": "string",
				"description": "Resource path to inspect."
			}
		},
		"required": ["resource_path"]
	}

	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"resource_path": {"type": "string"},
			"dependency_count": {"type": "integer"},
			"dependencies": {"type": "array"}
		}
	}

	var annotations: Dictionary = {
		"readOnlyHint": true,
		"destructiveHint": false,
		"idempotentHint": true,
		"openWorldHint": false
	}

	server_core.register_tool(tool_name, description, input_schema,
						  Callable(self, "_tool_get_resource_dependencies"),
						  output_schema, annotations,
						  "supplementary", "Project-Advanced")

func _tool_get_resource_dependencies(params: Dictionary) -> Dictionary:
	var resource_path: String = str(params.get("resource_path", "")).strip_edges()
	if resource_path.is_empty():
		return {"error": "Missing required parameter: resource_path"}

	var validation: Dictionary = PathValidator.validate_path(resource_path)
	if not validation["valid"]:
		return {"error": "Invalid path: " + validation["error"]}
	resource_path = validation["sanitized"]

	if not FileAccess.file_exists(resource_path):
		return {"error": "File not found: " + resource_path}

	var dependencies: Array = _parse_resource_dependencies(resource_path)
	return {
		"resource_path": resource_path,
		"dependency_count": dependencies.size(),
		"dependencies": dependencies
	}

# ============================================================================
# scan_missing_resource_dependencies - 扫描缺失依赖
# ============================================================================

func _register_scan_missing_resource_dependencies(server_core: RefCounted) -> void:
	var tool_name: String = "scan_missing_resource_dependencies"
	var description: String = "Scan project resources for broken or missing dependency references."

	var input_schema: Dictionary = {
		"type": "object",
		"properties": {
			"search_path": {
				"type": "string",
				"description": "Directory to scan. Default is res://.",
				"default": "res://"
			},
			"max_results": {
				"type": "integer",
				"description": "Maximum missing dependency issues to return. Default is 200.",
				"default": 200
			}
		}
	}

	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"search_path": {"type": "string"},
			"scanned_resources": {"type": "integer"},
			"issue_count": {"type": "integer"},
			"issues": {"type": "array"}
		}
	}

	var annotations: Dictionary = {
		"readOnlyHint": true,
		"destructiveHint": false,
		"idempotentHint": true,
		"openWorldHint": false
	}

	server_core.register_tool(tool_name, description, input_schema,
						  Callable(self, "_tool_scan_missing_resource_dependencies"),
						  output_schema, annotations,
						  "supplementary", "Project-Advanced")

func _tool_scan_missing_resource_dependencies(params: Dictionary) -> Dictionary:
	var search_path: String = str(params.get("search_path", "res://")).strip_edges()
	var max_results: int = max(1, int(params.get("max_results", 200)))

	var validation: Dictionary = PathValidator.validate_directory_path(search_path)
	if not validation["valid"]:
		return {"error": "Invalid path: " + validation["error"]}
	search_path = validation["sanitized"]

	var dependency_extensions: Array[String] = [
		".tscn", ".scn", ".tres", ".res", ".gd", ".cs", ".gdshader", ".material"
	]
	var resources: Array[String] = []
	_collect_resources(search_path, dependency_extensions, resources)
	resources.sort()

	var issues: Array = []
	for resource_path in resources:
		var dependencies: Array = _parse_resource_dependencies(resource_path)
		for dependency in dependencies:
			if bool(dependency.get("missing", false)):
				issues.append({
					"owner_path": resource_path,
					"dependency": dependency
				})
				if issues.size() >= max_results:
					return {
						"search_path": search_path,
						"scanned_resources": resources.size(),
						"issue_count": issues.size(),
						"issues": issues,
						"truncated": true
					}

	return {
		"search_path": search_path,
		"scanned_resources": resources.size(),
		"issue_count": issues.size(),
		"issues": issues,
		"truncated": false
	}

func _register_scan_cyclic_resource_dependencies(server_core: RefCounted) -> void:
	var tool_name: String = "scan_cyclic_resource_dependencies"
	var description: String = "Scan project resources for cyclic dependency chains based on parsed ResourceLoader dependency metadata."

	var input_schema: Dictionary = {
		"type": "object",
		"properties": {
			"search_path": {
				"type": "string",
				"description": "Directory to scan. Default is res://.",
				"default": "res://"
			},
			"max_results": {
				"type": "integer",
				"description": "Maximum cyclic dependency issues to return. Default is 100.",
				"default": 100
			}
		}
	}

	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"search_path": {"type": "string"},
			"scanned_resources": {"type": "integer"},
			"issue_count": {"type": "integer"},
			"issues": {"type": "array"},
			"truncated": {"type": "boolean"}
		}
	}

	var annotations: Dictionary = {
		"readOnlyHint": true,
		"destructiveHint": false,
		"idempotentHint": true,
		"openWorldHint": false
	}

	server_core.register_tool(tool_name, description, input_schema,
						  Callable(self, "_tool_scan_cyclic_resource_dependencies"),
						  output_schema, annotations,
						  "supplementary", "Project-Advanced")

func _tool_scan_cyclic_resource_dependencies(params: Dictionary) -> Dictionary:
	var search_path: String = str(params.get("search_path", "res://")).strip_edges()
	var max_results: int = max(1, int(params.get("max_results", 100)))

	var validation: Dictionary = PathValidator.validate_directory_path(search_path)
	if not validation["valid"]:
		return {"error": "Invalid path: " + validation["error"]}
	search_path = validation["sanitized"]

	var dependency_extensions: Array[String] = [
		".tscn", ".scn", ".tres", ".res", ".gd", ".cs", ".gdshader", ".material"
	]
	var resources: Array[String] = []
	_collect_resources(search_path, dependency_extensions, resources)
	resources.sort()

	var graph: Dictionary = {}
	for resource_path in resources:
		graph[resource_path] = _collect_existing_dependency_paths(resource_path)

	var issues: Array = []
	var seen_cycles: Dictionary = {}
	for resource_path in resources:
		var stack: Array = []
		var visiting: Dictionary = {}
		var cycle_paths: Array = []
		_find_cycles_from_resource(resource_path, graph, stack, visiting, seen_cycles, cycle_paths, max_results - issues.size())
		for cycle_path in cycle_paths:
			issues.append({
				"owner_path": resource_path,
				"cycle_path": cycle_path,
				"cycle_length": cycle_path.size() - 1
			})
			if issues.size() >= max_results:
				return {
					"search_path": search_path,
					"scanned_resources": resources.size(),
					"issue_count": issues.size(),
					"issues": issues,
					"truncated": true
				}

	return {
		"search_path": search_path,
		"scanned_resources": resources.size(),
		"issue_count": issues.size(),
		"issues": issues,
		"truncated": false
	}

func _parse_resource_dependencies(resource_path: String) -> Array:
	var dependencies: Array = []
	for raw_dependency in ResourceLoader.get_dependencies(resource_path):
		var raw_text: String = str(raw_dependency)
		var entry: Dictionary = {
			"raw": raw_text,
			"uid": "",
			"fallback_path": "",
			"resolved_path": "",
			"exists": false,
			"missing": false
		}

		if raw_text.contains("::"):
			entry["uid"] = raw_text.get_slice("::", 0)
			entry["fallback_path"] = raw_text.get_slice("::", 2)
			var resolved_path: String = ""
			if str(entry["uid"]).begins_with("uid://"):
				resolved_path = ResourceUID.uid_to_path(str(entry["uid"]))
			if resolved_path.is_empty():
				resolved_path = str(entry["fallback_path"])
			entry["resolved_path"] = resolved_path
		else:
			entry["fallback_path"] = raw_text
			entry["resolved_path"] = raw_text

		var resolved_exists: bool = false
		var resolved_path_str: String = str(entry["resolved_path"])
		var fallback_path_str: String = str(entry["fallback_path"])
		if not resolved_path_str.is_empty():
			resolved_exists = FileAccess.file_exists(resolved_path_str)
		if not resolved_exists and not fallback_path_str.is_empty():
			resolved_exists = FileAccess.file_exists(fallback_path_str)

		entry["exists"] = resolved_exists
		entry["missing"] = not resolved_exists
		dependencies.append(entry)

	return dependencies

func _collect_existing_dependency_paths(resource_path: String) -> Array:
	var paths: Array = []
	for dependency in _parse_resource_dependencies(resource_path):
		if bool(dependency.get("missing", false)):
			continue
		var resolved_path: String = str(dependency.get("resolved_path", ""))
		var fallback_path: String = str(dependency.get("fallback_path", ""))
		var effective_path: String = resolved_path if not resolved_path.is_empty() else fallback_path
		if effective_path.is_empty():
			continue
		if not paths.has(effective_path):
			paths.append(effective_path)
	return paths

func _find_cycles_from_resource(current_path: String, graph: Dictionary, stack: Array, visiting: Dictionary, seen_cycles: Dictionary, issues: Array, remaining_budget: int) -> void:
	if remaining_budget <= 0:
		return
	if bool(visiting.get(current_path, false)):
		var cycle_start: int = stack.find(current_path)
		if cycle_start >= 0:
			var cycle_path: Array = stack.slice(cycle_start)
			cycle_path.append(current_path)
			var cycle_key: String = _canonicalize_cycle_path(cycle_path)
			if not seen_cycles.has(cycle_key):
				seen_cycles[cycle_key] = true
				issues.append(cycle_path)
		return
	if stack.has(current_path):
		return

	visiting[current_path] = true
	stack.append(current_path)
	for dependency_path in graph.get(current_path, []):
		if not graph.has(dependency_path):
			continue
		_find_cycles_from_resource(dependency_path, graph, stack, visiting, seen_cycles, issues, remaining_budget - issues.size())
		if issues.size() >= remaining_budget:
			break
	stack.pop_back()
	visiting.erase(current_path)

func _canonicalize_cycle_path(cycle_path: Array) -> String:
	if cycle_path.size() <= 1:
		return JSON.stringify(cycle_path)
	var nodes: Array = cycle_path.slice(0, cycle_path.size() - 1)
	if nodes.is_empty():
		return JSON.stringify(cycle_path)
	var best_rotation: Array = []
	for start_index in range(nodes.size()):
		var rotated: Array = []
		for offset in range(nodes.size()):
			rotated.append(nodes[(start_index + offset) % nodes.size()])
		if best_rotation.is_empty() or JSON.stringify(rotated) < JSON.stringify(best_rotation):
			best_rotation = rotated
	best_rotation.append(best_rotation[0])
	return JSON.stringify(best_rotation)

# ============================================================================
# detect_broken_scripts - 批量检测脚本诊断
# ============================================================================

func _register_detect_broken_scripts(server_core: RefCounted) -> void:
	var tool_name: String = "detect_broken_scripts"
	var description: String = "Scan GDScript files for syntax errors and lightweight warnings."

	var input_schema: Dictionary = {
		"type": "object",
		"properties": {
			"search_path": {
				"type": "string",
				"description": "Directory to scan. Default is res://.",
				"default": "res://"
			},
			"include_warnings": {
				"type": "boolean",
				"description": "Whether to include lightweight warnings such as untyped var declarations. Default is true.",
				"default": true
			},
			"max_results": {
				"type": "integer",
				"description": "Maximum number of script issue entries to return. Default is 200.",
				"default": 200
			}
		}
	}

	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"search_path": {"type": "string"},
			"scanned_scripts": {"type": "integer"},
			"broken_count": {"type": "integer"},
			"warning_count": {"type": "integer"},
			"issues": {"type": "array"}
		}
	}

	var annotations: Dictionary = {
		"readOnlyHint": true,
		"destructiveHint": false,
		"idempotentHint": true,
		"openWorldHint": false
	}

	server_core.register_tool(tool_name, description, input_schema,
						  Callable(self, "_tool_detect_broken_scripts"),
						  output_schema, annotations,
						  "supplementary", "Project-Advanced")

func _tool_detect_broken_scripts(params: Dictionary) -> Dictionary:
	var search_path: String = str(params.get("search_path", "res://")).strip_edges()
	var include_warnings: bool = params.get("include_warnings", true)
	var max_results: int = max(1, int(params.get("max_results", 200)))

	var validation: Dictionary = PathValidator.validate_directory_path(search_path)
	if not validation["valid"]:
		return {"error": "Invalid path: " + validation["error"]}
	search_path = validation["sanitized"]

	var scripts: Array[String] = []
	_collect_resources(search_path, [".gd"], scripts)
	scripts.sort()

	var issues: Array = []
	var broken_count: int = 0
	var warning_count: int = 0

	for script_path in scripts:
		var diagnostics: Dictionary = _analyze_script_diagnostics(script_path, include_warnings)
		if diagnostics.has("error"):
			issues.append({
				"script_path": script_path,
				"severity": "error",
				"errors": [{"line": 0, "column": 0, "message": str(diagnostics["error"])}],
				"warnings": []
			})
			broken_count += 1
		else:
			var has_errors: bool = int(diagnostics.get("error_count", 0)) > 0
			var has_warnings: bool = int(diagnostics.get("warning_count", 0)) > 0
			var is_autoload_aware: bool = bool(diagnostics.get("autoload_aware", false))
			if is_autoload_aware and not has_errors:
				if has_warnings or include_warnings:
					issues.append({
						"script_path": script_path,
						"severity": "warning",
						"errors": diagnostics.get("errors", []),
						"warnings": diagnostics.get("warnings", [])
					})
					warning_count += 1
			elif has_errors or has_warnings:
				issues.append({
					"script_path": script_path,
					"severity": "error" if has_errors else "warning",
					"errors": diagnostics.get("errors", []),
					"warnings": diagnostics.get("warnings", [])
				})
				if has_errors:
					broken_count += 1
				if has_warnings:
					warning_count += 1

		if issues.size() >= max_results:
			break

	return {
		"search_path": search_path,
		"scanned_scripts": scripts.size(),
		"broken_count": broken_count,
		"warning_count": warning_count,
		"issues": issues,
		"truncated": issues.size() >= max_results and scripts.size() > issues.size()
	}

# ============================================================================
# audit_project_health - 汇总项目健康诊断
# ============================================================================

func _register_audit_project_health(server_core: RefCounted) -> void:
	var tool_name: String = "audit_project_health"
	var description: String = "Run a lightweight project health audit covering broken scripts and missing resource dependencies."

	var input_schema: Dictionary = {
		"type": "object",
		"properties": {
			"search_path": {
				"type": "string",
				"description": "Directory to scan. Default is res://.",
				"default": "res://"
			},
			"include_warnings": {
				"type": "boolean",
				"description": "Whether to include lightweight script warnings. Default is true.",
				"default": true
			},
			"max_results": {
				"type": "integer",
				"description": "Maximum issue entries per category. Default is 200.",
				"default": 200
			}
		}
	}

	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"status": {"type": "string"},
			"search_path": {"type": "string"},
			"summary": {"type": "object"},
			"broken_scripts": {"type": "array"},
			"missing_dependencies": {"type": "array"},
			"cyclic_dependencies": {"type": "array"}
		}
	}

	var annotations: Dictionary = {
		"readOnlyHint": true,
		"destructiveHint": false,
		"idempotentHint": true,
		"openWorldHint": false
	}

	server_core.register_tool(tool_name, description, input_schema,
						  Callable(self, "_tool_audit_project_health"),
						  output_schema, annotations,
						  "supplementary", "Project-Advanced")

func _tool_audit_project_health(params: Dictionary) -> Dictionary:
	var search_path: String = str(params.get("search_path", "res://")).strip_edges()
	var include_warnings: bool = params.get("include_warnings", true)
	var max_results: int = max(1, int(params.get("max_results", 200)))

	var broken_scripts_result: Dictionary = _tool_detect_broken_scripts({
		"search_path": search_path,
		"include_warnings": include_warnings,
		"max_results": max_results
	})
	if broken_scripts_result.has("error"):
		return broken_scripts_result

	var missing_dependencies_result: Dictionary = _tool_scan_missing_resource_dependencies({
		"search_path": search_path,
		"max_results": max_results
	})
	if missing_dependencies_result.has("error"):
		return missing_dependencies_result

	var cyclic_dependencies_result: Dictionary = _tool_scan_cyclic_resource_dependencies({
		"search_path": search_path,
		"max_results": max_results
	})
	if cyclic_dependencies_result.has("error"):
		return cyclic_dependencies_result

	var summary: Dictionary = {
		"scanned_scripts": int(broken_scripts_result.get("scanned_scripts", 0)),
		"broken_scripts": int(broken_scripts_result.get("broken_count", 0)),
		"script_warnings": int(broken_scripts_result.get("warning_count", 0)),
		"scanned_resources": int(missing_dependencies_result.get("scanned_resources", 0)),
		"missing_dependencies": int(missing_dependencies_result.get("issue_count", 0)),
		"cyclic_dependencies": int(cyclic_dependencies_result.get("issue_count", 0))
	}
	var hard_failures: int = summary["broken_scripts"] + summary["missing_dependencies"] + summary["cyclic_dependencies"]
	var status: String = "healthy"
	if hard_failures > 0:
		status = "failing"
	elif summary["script_warnings"] > 0:
		status = "warning"

	return {
		"status": status,
		"search_path": broken_scripts_result.get("search_path", search_path),
		"summary": summary,
		"broken_scripts": broken_scripts_result.get("issues", []),
		"missing_dependencies": missing_dependencies_result.get("issues", []),
		"cyclic_dependencies": cyclic_dependencies_result.get("issues", []),
		"truncated": bool(broken_scripts_result.get("truncated", false)) or bool(missing_dependencies_result.get("truncated", false)) or bool(cyclic_dependencies_result.get("truncated", false))
	}

# ============================================================================
# find_resource_usages - reverse dependency lookup: who references a resource
# ============================================================================

func _register_find_resource_usages(server_core: RefCounted) -> void:
	var tool_name: String = "find_resource_usages"
	var description: String = "Find which project resources reference a target resource (reverse dependency lookup)."

	var input_schema: Dictionary = {
		"type": "object",
		"properties": {
			"resource_path": {
				"type": "string",
				"description": "Target resource path to find usages of, e.g. 'res://art/player.png'."
			},
			"search_path": {
				"type": "string",
				"description": "Directory to scan for referencing resources. Default is res://.",
				"default": "res://"
			},
			"limit": {
				"type": "integer",
				"description": "Maximum number of referencing resources to return. Default is 1000.",
				"default": 1000
			}
		},
		"required": ["resource_path"]
	}

	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"resource_path": {"type": "string"},
			"search_path": {"type": "string"},
			"target_uid": {"type": "string"},
			"scanned_resources": {"type": "integer"},
			"usage_count": {"type": "integer"},
			"total_count": {"type": "integer"},
			"truncated": {"type": "boolean"},
			"usages": {"type": "array"}
		}
	}

	var annotations: Dictionary = {
		"readOnlyHint": true,
		"destructiveHint": false,
		"idempotentHint": true,
		"openWorldHint": false
	}

	server_core.register_tool(tool_name, description, input_schema,
						  Callable(self, "_tool_find_resource_usages"),
						  output_schema, annotations,
						  "supplementary", "Project-Advanced")

func _tool_find_resource_usages(params: Dictionary) -> Dictionary:
	var resource_path: String = str(params.get("resource_path", "")).strip_edges()
	if resource_path.is_empty():
		return {"error": "Missing required parameter: resource_path"}

	var validation: Dictionary = PathValidator.validate_path(resource_path)
	if not validation["valid"]:
		return {"error": "Invalid path: " + validation["error"]}
	resource_path = validation["sanitized"]

	if not FileAccess.file_exists(resource_path):
		return {"error": "File not found: " + resource_path}

	var search_path: String = str(params.get("search_path", "res://")).strip_edges()
	var search_validation: Dictionary = PathValidator.validate_directory_path(search_path)
	if not search_validation["valid"]:
		return {"error": "Invalid path: " + search_validation["error"]}
	search_path = search_validation["sanitized"]

	var limit: int = int(params.get("limit", 1000))

	var target_uid: String = ResourceUID.path_to_uid(resource_path)
	if not target_uid.begins_with("uid://"):
		target_uid = ""

	var owner_extensions: Array[String] = [
		".tscn", ".scn", ".tres", ".res", ".gd", ".cs", ".gdshader", ".material"
	]
	var owners: Array[String] = []
	_collect_resources(search_path, owner_extensions, owners)
	owners.sort()

	var usages: Array = []
	for owner_path in owners:
		if owner_path == resource_path:
			continue
		var references: Array = []
		for dependency in _parse_resource_dependencies(owner_path):
			var resolved_path: String = str(dependency.get("resolved_path", ""))
			var fallback_path: String = str(dependency.get("fallback_path", ""))
			var dependency_uid: String = str(dependency.get("uid", ""))
			var matched_via: String = ""
			if resolved_path == resource_path or fallback_path == resource_path:
				matched_via = "path"
			elif not target_uid.is_empty() and dependency_uid == target_uid:
				matched_via = "uid"
			if not matched_via.is_empty():
				var reference: Dictionary = dependency.duplicate()
				reference["matched_via"] = matched_via
				references.append(reference)
		if not references.is_empty():
			usages.append({
				"owner_path": owner_path,
				"reference_count": references.size(),
				"references": references
			})

	var bounded: Dictionary = PayloadUtils.truncate_list(usages, limit)
	return {
		"resource_path": resource_path,
		"search_path": search_path,
		"target_uid": target_uid,
		"scanned_resources": owners.size(),
		"usage_count": int(bounded["total_count"]),
		"total_count": int(bounded["total_count"]),
		"truncated": bool(bounded["truncated"]),
		"usages": bounded["items"]
	}

# ============================================================================
# list_unused_resources - list orphaned resources nothing references
# ============================================================================

func _register_list_unused_resources(server_core: RefCounted) -> void:
	var tool_name: String = "list_unused_resources"
	var description: String = "List resource files that no other resource references. Scripts referenced only via class_name are not tracked; entry points (main scene, autoloads) are always treated as used."

	var input_schema: Dictionary = {
		"type": "object",
		"properties": {
			"search_path": {
				"type": "string",
				"description": "Directory to scan for candidate resources. Default is res://.",
				"default": "res://"
			},
			"extensions": {
				"type": "array",
				"description": "Optional override of candidate file extensions (e.g. ['.tres', '.png']). Defaults to asset resources and excludes scripts."
			},
			"limit": {
				"type": "integer",
				"description": "Maximum number of unused resources to return. Default is 1000.",
				"default": 1000
			}
		}
	}

	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"search_path": {"type": "string"},
			"scanned_resources": {"type": "integer"},
			"unused_count": {"type": "integer"},
			"total_count": {"type": "integer"},
			"truncated": {"type": "boolean"},
			"unused_resources": {"type": "array"}
		}
	}

	var annotations: Dictionary = {
		"readOnlyHint": true,
		"destructiveHint": false,
		"idempotentHint": true,
		"openWorldHint": false
	}

	server_core.register_tool(tool_name, description, input_schema,
						  Callable(self, "_tool_list_unused_resources"),
						  output_schema, annotations,
						  "supplementary", "Project-Advanced")

func _tool_list_unused_resources(params: Dictionary) -> Dictionary:
	var search_path: String = str(params.get("search_path", "res://")).strip_edges()
	var validation: Dictionary = PathValidator.validate_directory_path(search_path)
	if not validation["valid"]:
		return {"error": "Invalid path: " + validation["error"]}
	search_path = validation["sanitized"]

	var limit: int = int(params.get("limit", 1000))

	var candidate_extensions: Array[String] = []
	var override_extensions = params.get("extensions", null)
	if override_extensions is Array and not (override_extensions as Array).is_empty():
		for ext in override_extensions:
			var ext_text: String = str(ext).strip_edges()
			if not ext_text.is_empty():
				if not ext_text.begins_with("."):
					ext_text = "." + ext_text
				candidate_extensions.append(ext_text)
	else:
		candidate_extensions = [
			".tres", ".res", ".tscn", ".scn", ".material", ".gdshader",
			".png", ".jpg", ".jpeg", ".webp", ".svg", ".bmp", ".tga",
			".ogg", ".wav", ".mp3",
			".ttf", ".otf",
			".glb", ".gltf", ".obj", ".fbx"
		]

	var candidates: Array[String] = []
	_collect_resources(search_path, candidate_extensions, candidates)
	candidates.sort()

	var owner_extensions: Array[String] = [
		".tscn", ".scn", ".tres", ".res", ".gd", ".cs", ".gdshader", ".material"
	]
	var owners: Array[String] = []
	_collect_resources("res://", owner_extensions, owners)

	var referenced: Dictionary = {}
	for owner_path in owners:
		for dependency in _parse_resource_dependencies(owner_path):
			var resolved_path: String = str(dependency.get("resolved_path", ""))
			var fallback_path: String = str(dependency.get("fallback_path", ""))
			if not resolved_path.is_empty():
				referenced[resolved_path] = true
			if not fallback_path.is_empty():
				referenced[fallback_path] = true

	for root_path in _collect_project_resource_roots():
		referenced[root_path] = true

	var unused: Array = []
	for candidate_path in candidates:
		if not referenced.has(candidate_path):
			unused.append(candidate_path)

	var bounded: Dictionary = PayloadUtils.truncate_list(unused, limit)
	return {
		"search_path": search_path,
		"scanned_resources": candidates.size(),
		"unused_count": int(bounded["total_count"]),
		"total_count": int(bounded["total_count"]),
		"truncated": bool(bounded["truncated"]),
		"unused_resources": bounded["items"]
	}

func _collect_project_resource_roots() -> Array:
	var roots: Array = []
	var main_scene: String = _resolve_resource_root_path(str(ProjectSettings.get_setting("application/run/main_scene", "")))
	if not main_scene.is_empty() and not roots.has(main_scene):
		roots.append(main_scene)
	for property in ProjectSettings.get_property_list():
		var property_name: String = str(property.get("name", ""))
		if not property_name.begins_with("autoload/"):
			continue
		var value: String = _resolve_resource_root_path(str(ProjectSettings.get_setting(property_name, "")))
		if not value.is_empty() and not roots.has(value):
			roots.append(value)
	return roots

# Normalize a project entry-point setting (main scene / autoload) to a res:// path.
# Strips the autoload "*" prefix and resolves uid:// values to their res:// path.
func _resolve_resource_root_path(raw_value: String) -> String:
	var value: String = raw_value.strip_edges()
	if value.begins_with("*"):
		value = value.substr(1)
	if value.begins_with("uid://"):
		value = ResourceUID.uid_to_path(value)
	if value.begins_with("res://"):
		return value
	return ""

func _analyze_script_diagnostics(script_path: String, include_warnings: bool) -> Dictionary:
	var file: FileAccess = FileAccess.open(script_path, FileAccess.READ)
	if not file:
		return {"error": "Failed to open file"}
	var content: String = file.get_as_text()
	file.close()

	var validation_content: String = _strip_class_names(content)
	var test_script: GDScript = GDScript.new()
	test_script.source_code = validation_content
	var reload_error: Error = test_script.reload()

	var errors: Array = []
	var warnings: Array = []
	var autoload_aware: bool = false

	if reload_error != OK:
		var autoload_decls: String = _build_autoload_declarations()
		if not autoload_decls.is_empty():
			var retry_content: String = autoload_decls + "\n" + validation_content
			var retry_script: GDScript = GDScript.new()
			retry_script.source_code = retry_content
			var retry_err: Error = retry_script.reload()
			if retry_err == OK:
				autoload_aware = true
				if include_warnings:
					warnings.append({
						"line": 0,
						"column": 0,
						"message": "Script validates successfully with Autoload/global class awareness"
					})
		if not autoload_aware:
			var source_lines: PackedStringArray = content.split("\n")
			for i in range(source_lines.size()):
				var line: String = source_lines[i].strip_edges()
				if line.is_empty():
					continue
				if _is_likely_script_error_line(line):
					errors.append({
						"line": i + 1,
						"column": 0,
						"message": "Syntax error near: " + line
					})
					break
			if errors.is_empty():
				errors.append({
					"line": 0,
					"column": 0,
					"message": "Script has syntax errors"
				})

	if include_warnings and reload_error == OK:
		var source_lines_for_warning: PackedStringArray = content.split("\n")
		for i in range(source_lines_for_warning.size()):
			var warning_line: String = source_lines_for_warning[i].strip_edges()
			if warning_line.begins_with("var ") and not ":" in warning_line and not "=" in warning_line:
				warnings.append({
					"line": i + 1,
					"column": 0,
					"message": "Variable lacks type hint"
				})

	return {
		"valid": errors.is_empty(),
		"errors": errors,
		"warnings": warnings,
		"error_count": errors.size(),
		"warning_count": warnings.size(),
		"autoload_aware": autoload_aware
	}

func _strip_class_names(source: String) -> String:
	var lines: PackedStringArray = source.split("\n")
	var result: PackedStringArray = []
	for line in lines:
		var stripped: String = line.strip_edges()
		if stripped.begins_with("class_name "):
			result.append("")
		else:
			result.append(line)
	return "\n".join(result)

func _build_autoload_declarations() -> String:
	var decls: PackedStringArray = []
	for property_info in ProjectSettings.get_property_list():
		var property_name: String = str(property_info.get("name", ""))
		if not property_name.begins_with("autoload/"):
			continue
		var autoload_name: String = property_name.trim_prefix("autoload/")
		decls.append("var %s" % autoload_name)
	var global_classes: PackedStringArray = ProjectSettings.get_global_class_list()
	for class_name_str in global_classes:
		if not class_name_str.is_empty():
			decls.append("var %s" % class_name_str)
	return "\n".join(decls)

func _is_likely_script_error_line(line: String) -> bool:
	var line_lower: String = line.to_lower()
	if line_lower.contains("unexpected") or line_lower.contains("expected") or line_lower.contains("indent"):
		return true
	if line.ends_with("(") or line.ends_with(",") or line.count("\"") % 2 == 1:
		return true
	return false

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

func _find_project_global_class_entry(target_class_name: String) -> Dictionary:
	if not ProjectSettings.has_method("get_global_class_list"):
		return {}
	for entry in ProjectSettings.get_global_class_list():
		if not (entry is Dictionary):
			continue
		if str(entry.get("class", "")) == target_class_name:
			return entry
	return {}

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

func _serialize_tileset_source(source_id: int, source: TileSetSource, include_tiles: bool) -> Dictionary:
	var source_entry: Dictionary = {
		"source_id": source_id,
		"class_name": source.get_class(),
		"tile_count": source.get_tiles_count()
	}

	if source is TileSetAtlasSource:
		var atlas_source: TileSetAtlasSource = source as TileSetAtlasSource
		var texture: Texture2D = atlas_source.texture
		source_entry["source_type"] = "atlas"
		source_entry["texture_path"] = texture.resource_path if texture else ""
		source_entry["texture_size"] = _serialize_vector2(texture.get_size()) if texture else {}
		source_entry["margins"] = _serialize_vector2i(atlas_source.margins)
		source_entry["separation"] = _serialize_vector2i(atlas_source.separation)
		source_entry["texture_region_size"] = _serialize_vector2i(atlas_source.texture_region_size)
		source_entry["atlas_grid_size"] = _serialize_vector2i(atlas_source.get_atlas_grid_size())
		source_entry["uses_texture_padding"] = atlas_source.use_texture_padding
		if include_tiles:
			var atlas_tiles: Array = []
			for tile_index in range(atlas_source.get_tiles_count()):
				var atlas_coords: Vector2i = atlas_source.get_tile_id(tile_index)
				var alternatives: Array = []
				for alt_index in range(atlas_source.get_alternative_tiles_count(atlas_coords)):
					alternatives.append(atlas_source.get_alternative_tile_id(atlas_coords, alt_index))
				atlas_tiles.append({
					"atlas_coords": _serialize_vector2i(atlas_coords),
					"size_in_atlas": _serialize_vector2i(atlas_source.get_tile_size_in_atlas(atlas_coords)),
					"texture_region": _serialize_rect2i(atlas_source.get_tile_texture_region(atlas_coords)),
					"alternative_ids": alternatives,
					"alternative_count": alternatives.size()
				})
			source_entry["tiles"] = atlas_tiles
	elif source is TileSetScenesCollectionSource:
		var scenes_source: TileSetScenesCollectionSource = source as TileSetScenesCollectionSource
		source_entry["source_type"] = "scenes_collection"
		source_entry["scene_tile_count"] = scenes_source.get_scene_tiles_count()
		if include_tiles:
			var scene_tiles: Array = []
			for tile_index in range(scenes_source.get_scene_tiles_count()):
				var scene_tile_id: int = scenes_source.get_scene_tile_id(tile_index)
				var packed_scene: PackedScene = scenes_source.get_scene_tile_scene(scene_tile_id)
				scene_tiles.append({
					"scene_tile_id": scene_tile_id,
					"scene_path": packed_scene.resource_path if packed_scene else ""
				})
			source_entry["scene_tiles"] = scene_tiles
	else:
		source_entry["source_type"] = "unknown"

	return source_entry

func _serialize_vector2i(value: Vector2i) -> Dictionary:
	return {"x": value.x, "y": value.y}

func _serialize_vector2(value: Vector2) -> Dictionary:
	return {"x": value.x, "y": value.y}

func _serialize_rect2i(value: Rect2i) -> Dictionary:
	return {
		"position": _serialize_vector2i(value.position),
		"size": _serialize_vector2i(value.size)
	}

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
# scan_migration_compatibility / apply_migration_fixes
# Engine-version migration assistant. Scans project source for usages of APIs
# changed by a target Godot release and (optionally) auto-applies the safe,
# mechanical rewrites. Rules below are derived from the official
# "Upgrading to Godot 4.7" migration guide.
# ============================================================================

func _migration_rules(target_version: String) -> Array:
	if target_version != "4.7":
		return []
	return [
		{
			"id": "rtl_image_update_mask_rename",
			"severity": "must_fix",
			"category": "GUI",
			"kind": "enum_rename",
			"languages": ["gd", "cs"],
			"behavior": false,
			"pattern": "\\bUPDATE_WIDTH_IN_PERCENT\\b",
			"replacement": "UPDATE_WIDTH_UNIT",
			"auto_fixable": true,
			"gh": "GH-112617",
			"message": "RichTextLabel.ImageUpdateMask.UPDATE_WIDTH_IN_PERCENT was renamed to UPDATE_WIDTH_UNIT in Godot 4.7."
		},
		{
			"id": "audio_spectrum_tap_back_pos_removed",
			"severity": "must_fix",
			"category": "Audio",
			"kind": "removed",
			"languages": ["gd", "cs"],
			"behavior": false,
			"pattern": "\\btap_back_pos\\b",
			"replacement": "",
			"auto_fixable": false,
			"gh": "GH-114355",
			"message": "AudioEffectSpectrumAnalyzer.tap_back_pos was removed in Godot 4.7."
		},
		{
			"id": "editor_scene_import_flags_enum",
			"severity": "must_fix",
			"category": "Editor",
			"kind": "enum_move",
			"languages": ["cs"],
			"behavior": false,
			"pattern": "\\bIMPORT_(ANIMATION|DISCARD_MESHES_AND_MATERIALS|FAIL_ON_MISSING_DEPENDENCIES|FORCE_DISABLE_MESH_COMPRESSION|GENERATE_TANGENT_ARRAYS|SCENE|USE_NAMED_SKIN_BINDS)\\b",
			"replacement": "",
			"auto_fixable": false,
			"gh": "GH-115788",
			"message": "EditorSceneFormatImporter.IMPORT_* constants moved into the ImportFlags enum in Godot 4.7 (C# source-incompatible)."
		},
		{
			"id": "rtl_add_image_unit_params",
			"severity": "review",
			"category": "GUI",
			"kind": "signature_change",
			"languages": ["gd", "cs"],
			"behavior": false,
			"pattern": "\\b(add_image|update_image)\\s*\\(",
			"replacement": "",
			"auto_fixable": false,
			"gh": "GH-112617",
			"message": "RichTextLabel.add_image/update_image: the width_in_percent/height_in_percent params changed from bool to RichTextLabel.ImageUnit (default false->0) in Godot 4.7. Review these call sites."
		},
		{
			"id": "input_device_id_zero",
			"severity": "review",
			"category": "Input",
			"kind": "behavior",
			"languages": ["gd", "cs"],
			"behavior": true,
			"pattern": "\\.device\\s*==\\s*0\\b",
			"replacement": "",
			"auto_fixable": false,
			"gh": "GH-116274",
			"message": "Mouse/keyboard device IDs changed from 0 to InputEvent.DEVICE_ID_MOUSE/DEVICE_ID_KEYBOARD in Godot 4.7. Compare InputEvent.device against those constants instead of 0."
		},
		{
			"id": "audio_stream_player_area_mask_default",
			"severity": "review",
			"category": "Audio",
			"kind": "behavior",
			"languages": ["gd", "cs"],
			"behavior": true,
			"pattern": "\\baudio_bus_override\\b",
			"replacement": "",
			"auto_fixable": false,
			"gh": "GH-107679",
			"message": "AudioStreamPlayer default area_mask changed from 1 to 0 in Godot 4.7. If you rely on audio_bus_override with the default mask, set area_mask to layer 1 explicitly."
		},
		{
			"id": "canvasitem_line_antialiasing",
			"severity": "review",
			"category": "2D",
			"kind": "behavior",
			"languages": ["gd", "cs"],
			"behavior": true,
			"pattern": "\\bdraw_(line|polyline|multiline)\\b",
			"replacement": "",
			"auto_fixable": false,
			"gh": "GH-105122",
			"message": "CanvasItem no longer adds an antialiasing feather to lines in Godot 4.7; lines may appear thinner. Increase line width if you relied on the old behavior."
		}
	]

func _migration_lang_for_path(path: String) -> String:
	if path.ends_with(".cs"):
		return "cs"
	return "gd"

func _compile_migration_rules(rules: Array) -> Array:
	var compiled: Array = []
	for rule in rules:
		var re: RegEx = RegEx.new()
		if re.compile(str(rule.get("pattern", ""))) != OK:
			continue
		compiled.append({"rule": rule, "re": re})
	return compiled

func _register_scan_migration_compatibility(server_core: RefCounted) -> void:
	var tool_name: String = "scan_migration_compatibility"
	var description: String = "Scan project source (.gd/.cs) for usages of APIs changed by a target Godot release and report migration issues with file/line, severity, and fix guidance. The plugin's own source under res://addons/godot_mcp/ is excluded so its rule-definition strings are not self-reported."

	var input_schema: Dictionary = {
		"type": "object",
		"properties": {
			"target_version": {
				"type": "string",
				"description": "Target Godot version to check migration against. Only '4.7' is currently supported.",
				"default": "4.7"
			},
			"search_path": {
				"type": "string",
				"description": "Directory to scan. Default is res://.",
				"default": "res://"
			},
			"include_behavior": {
				"type": "boolean",
				"description": "Include behavioral/default-value changes (compile-clean but runtime behavior differs). Default true.",
				"default": true
			},
			"limit": {
				"type": "integer",
				"description": "Maximum number of issues to return. Default is 1000.",
				"default": 1000
			}
		}
	}

	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"target_version": {"type": "string"},
			"search_path": {"type": "string"},
			"scanned_files": {"type": "integer"},
			"must_fix_count": {"type": "integer"},
			"review_count": {"type": "integer"},
			"total_count": {"type": "integer"},
			"truncated": {"type": "boolean"},
			"issues": {"type": "array"}
		}
	}

	var annotations: Dictionary = {
		"readOnlyHint": true,
		"destructiveHint": false,
		"idempotentHint": true,
		"openWorldHint": false
	}

	server_core.register_tool(tool_name, description, input_schema,
						  Callable(self, "_tool_scan_migration_compatibility"),
						  output_schema, annotations,
						  "supplementary", "Project-Advanced")

func _migration_plugin_root() -> String:
	var script: Script = get_script()
	if script == null:
		return "res://addons/godot_mcp/"
	var tools_dir: String = script.resource_path.get_base_dir()
	return tools_dir.get_base_dir() + "/"

func _migration_exclude_plugin_sources(files: Array[String]) -> Array[String]:
	var plugin_root: String = _migration_plugin_root()
	var kept: Array[String] = []
	for path in files:
		if path.begins_with(plugin_root):
			continue
		kept.append(path)
	return kept

func _tool_scan_migration_compatibility(params: Dictionary) -> Dictionary:
	var target_version: String = str(params.get("target_version", "4.7")).strip_edges()
	var rules: Array = _migration_rules(target_version)
	if rules.is_empty():
		return {"error": "Unsupported target_version: " + target_version + " (supported: 4.7)"}

	var search_path: String = str(params.get("search_path", "res://")).strip_edges()
	var search_validation: Dictionary = PathValidator.validate_directory_path(search_path)
	if not search_validation["valid"]:
		return {"error": "Invalid path: " + search_validation["error"]}
	search_path = search_validation["sanitized"]

	var include_behavior: bool = bool(params.get("include_behavior", true))
	var limit: int = int(params.get("limit", 1000))

	var files: Array[String] = []
	_collect_resources(search_path, [".gd", ".cs"], files)
	files = _migration_exclude_plugin_sources(files)
	files.sort()

	var active_rules: Array = []
	for rule in rules:
		if bool(rule.get("behavior", false)) and not include_behavior:
			continue
		active_rules.append(rule)
	var compiled: Array = _compile_migration_rules(active_rules)

	var issues: Array = []
	var must_fix_count: int = 0
	var review_count: int = 0
	for path in files:
		var lang: String = _migration_lang_for_path(path)
		var file: FileAccess = FileAccess.open(path, FileAccess.READ)
		if file == null:
			continue
		var line_no: int = 0
		while not file.eof_reached():
			line_no += 1
			var line: String = file.get_line()
			for entry in compiled:
				var rule: Dictionary = entry["rule"]
				if not (lang in rule["languages"]):
					continue
				var re: RegEx = entry["re"]
				for match_obj in re.search_all(line):
					var auto_fixable: bool = bool(rule.get("auto_fixable", false))
					var issue: Dictionary = {
						"file": path,
						"line": line_no,
						"column": match_obj.get_start() + 1,
						"rule_id": str(rule.get("id", "")),
						"severity": str(rule.get("severity", "review")),
						"category": str(rule.get("category", "")),
						"kind": str(rule.get("kind", "")),
						"language": lang,
						"matched_text": match_obj.get_string(),
						"message": str(rule.get("message", "")),
						"gh": str(rule.get("gh", "")),
						"auto_fixable": auto_fixable
					}
					if auto_fixable:
						issue["suggested_replacement"] = str(rule.get("replacement", ""))
					if issue["severity"] == "must_fix":
						must_fix_count += 1
					else:
						review_count += 1
					issues.append(issue)
		file.close()

	var bounded: Dictionary = PayloadUtils.truncate_list(issues, limit)
	return {
		"target_version": target_version,
		"search_path": search_path,
		"scanned_files": files.size(),
		"must_fix_count": must_fix_count,
		"review_count": review_count,
		"total_count": int(bounded["total_count"]),
		"truncated": bool(bounded["truncated"]),
		"issues": bounded["items"]
	}

func _register_apply_migration_fixes(server_core: RefCounted) -> void:
	var tool_name: String = "apply_migration_fixes"
	var description: String = "Apply the safe, mechanical migration rewrites (e.g. enum/identifier renames) for a target Godot release. Defaults to a dry run that previews diffs without writing files. The plugin's own source under res://addons/godot_mcp/ is excluded."

	var input_schema: Dictionary = {
		"type": "object",
		"properties": {
			"target_version": {
				"type": "string",
				"description": "Target Godot version. Only '4.7' is currently supported.",
				"default": "4.7"
			},
			"search_path": {
				"type": "string",
				"description": "Directory to scan and rewrite. Default is res://.",
				"default": "res://"
			},
			"rule_ids": {
				"type": "array",
				"description": "Optional list of rule ids to restrict the fixes to. Empty means all auto-fixable rules.",
				"items": {"type": "string"}
			},
			"dry_run": {
				"type": "boolean",
				"description": "When true (default), preview changes without writing files.",
				"default": true
			},
			"limit": {
				"type": "integer",
				"description": "Maximum number of changes to return. Default is 1000.",
				"default": 1000
			}
		}
	}

	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"target_version": {"type": "string"},
			"search_path": {"type": "string"},
			"dry_run": {"type": "boolean"},
			"scanned_files": {"type": "integer"},
			"files_changed": {"type": "array"},
			"change_count": {"type": "integer"},
			"total_count": {"type": "integer"},
			"truncated": {"type": "boolean"},
			"changes": {"type": "array"}
		}
	}

	var annotations: Dictionary = {
		"readOnlyHint": false,
		"destructiveHint": false,
		"idempotentHint": false,
		"openWorldHint": false
	}

	server_core.register_tool(tool_name, description, input_schema,
						  Callable(self, "_tool_apply_migration_fixes"),
						  output_schema, annotations,
						  "supplementary", "Project-Advanced")

func _tool_apply_migration_fixes(params: Dictionary) -> Dictionary:
	var target_version: String = str(params.get("target_version", "4.7")).strip_edges()
	var all_rules: Array = _migration_rules(target_version)
	if all_rules.is_empty():
		return {"error": "Unsupported target_version: " + target_version + " (supported: 4.7)"}

	var search_path: String = str(params.get("search_path", "res://")).strip_edges()
	var search_validation: Dictionary = PathValidator.validate_directory_path(search_path)
	if not search_validation["valid"]:
		return {"error": "Invalid path: " + search_validation["error"]}
	search_path = search_validation["sanitized"]

	var dry_run: bool = bool(params.get("dry_run", true))
	var limit: int = int(params.get("limit", 1000))

	var rule_id_filter: Array = []
	for rid in params.get("rule_ids", []):
		rule_id_filter.append(str(rid))

	var fix_rules: Array = []
	for rule in all_rules:
		if not bool(rule.get("auto_fixable", false)):
			continue
		if not rule_id_filter.is_empty() and not (str(rule.get("id", "")) in rule_id_filter):
			continue
		fix_rules.append(rule)
	if fix_rules.is_empty():
		return {"error": "No auto-fixable rules selected for target_version " + target_version}

	var compiled: Array = _compile_migration_rules(fix_rules)

	var files: Array[String] = []
	_collect_resources(search_path, [".gd", ".cs"], files)
	files = _migration_exclude_plugin_sources(files)
	files.sort()

	var changes: Array = []
	var files_changed: Array = []
	for path in files:
		var lang: String = _migration_lang_for_path(path)
		var applicable: Array = []
		for entry in compiled:
			if lang in entry["rule"]["languages"]:
				applicable.append(entry)
		if applicable.is_empty():
			continue

		var read_file: FileAccess = FileAccess.open(path, FileAccess.READ)
		if read_file == null:
			continue
		var content: String = read_file.get_as_text()
		read_file.close()

		var lines: PackedStringArray = content.split("\n")
		var file_changed: bool = false
		for i in range(lines.size()):
			var original_line: String = lines[i]
			var new_line: String = original_line
			for entry in applicable:
				var rule: Dictionary = entry["rule"]
				var re: RegEx = entry["re"]
				if re.search(new_line) == null:
					continue
				var replaced: String = re.sub(new_line, str(rule.get("replacement", "")), true)
				if replaced != new_line:
					changes.append({
						"file": path,
						"line": i + 1,
						"rule_id": str(rule.get("id", "")),
						"gh": str(rule.get("gh", "")),
						"before": new_line,
						"after": replaced
					})
					new_line = replaced
					file_changed = true
			if new_line != original_line:
				lines[i] = new_line

		if file_changed:
			files_changed.append(path)
			if not dry_run:
				var write_file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
				if write_file == null:
					return {"error": "Failed to open file for writing: " + path}
				write_file.store_string("\n".join(lines))
				write_file.close()

	var bounded: Dictionary = PayloadUtils.truncate_list(changes, limit)
	return {
		"target_version": target_version,
		"search_path": search_path,
		"dry_run": dry_run,
		"scanned_files": files.size(),
		"files_changed": files_changed,
		"change_count": changes.size(),
		"total_count": int(bounded["total_count"]),
		"truncated": bool(bounded["truncated"]),
		"changes": bounded["items"]
	}

# ============================================================================
# find_deprecated_api_usage - scan scripts for removed/deprecated Godot 4.x APIs
# ============================================================================

# Version-agnostic table of well-known removed/deprecated Godot 4.x symbols.
# Each rule is matched against source lines with a RegEx; `engine_class` /
# `replacement_class` (when present) are cross-checked against the running
# engine's ClassDB so the report reflects the actual editor, not just a guess.
func _deprecated_api_rules() -> Array:
	return [
		{"id": "pooled_arrays", "kind": "class", "status": "removed", "pattern": "\\bPool(String|Byte|Int|Real|Vector2|Vector3|Color)Array\\b", "replacement": "Packed*Array (e.g. PackedStringArray)", "engine_class": "PoolStringArray", "replacement_class": "PackedStringArray", "since": "4.0", "message": "Pool*Array types were renamed to Packed*Array in Godot 4.0."},
		{"id": "reference_class", "kind": "class", "status": "removed", "pattern": "\\bextends\\s+Reference\\b", "replacement": "RefCounted", "engine_class": "Reference", "replacement_class": "RefCounted", "since": "4.0", "message": "Reference was renamed to RefCounted in Godot 4.0."},
		{"id": "visual_server", "kind": "class", "status": "removed", "pattern": "\\bVisualServer\\b", "replacement": "RenderingServer", "engine_class": "VisualServer", "replacement_class": "RenderingServer", "since": "4.0", "message": "VisualServer was renamed to RenderingServer in Godot 4.0."},
		{"id": "file_class", "kind": "class", "status": "removed", "pattern": "\\bextends\\s+File\\b|\\bFile\\.new\\(\\)", "replacement": "FileAccess", "engine_class": "File", "replacement_class": "FileAccess", "since": "4.0", "message": "The File class was replaced by FileAccess in Godot 4.0."},
		{"id": "directory_class", "kind": "class", "status": "removed", "pattern": "\\bDirectory\\.new\\(\\)", "replacement": "DirAccess", "engine_class": "Directory", "replacement_class": "DirAccess", "since": "4.0", "message": "The Directory class was replaced by DirAccess in Godot 4.0."},
		{"id": "yield_keyword", "kind": "keyword", "status": "removed", "pattern": "\\byield\\s*\\(", "replacement": "await", "since": "4.0", "message": "The yield() coroutine function was replaced by the await keyword in Godot 4.0."},
		{"id": "export_old_syntax", "kind": "keyword", "status": "removed", "pattern": "(^|[^@\\w])export\\s*\\(", "replacement": "@export annotation", "since": "4.0", "message": "The export(...) hint syntax was replaced by the @export annotation in Godot 4.0."},
		{"id": "onready_old_syntax", "kind": "keyword", "status": "removed", "pattern": "(^|[^@\\w])onready\\s+var\\b", "replacement": "@onready", "since": "4.0", "message": "The onready keyword was replaced by the @onready annotation in Godot 4.0."},
		{"id": "setget_keyword", "kind": "keyword", "status": "removed", "pattern": "\\bsetget\\b", "replacement": "property setters/getters (set/get on var)", "since": "4.0", "message": "The setget keyword was removed in Godot 4.0; use inline set/get on the variable."},
		{"id": "editor_hint_property", "kind": "property", "status": "removed", "pattern": "\\bEngine\\.editor_hint\\b", "replacement": "Engine.is_editor_hint()", "since": "4.0", "message": "Engine.editor_hint was replaced by Engine.is_editor_hint() in Godot 4.0."},
		{"id": "empty_method", "kind": "method", "status": "removed", "pattern": "\\.empty\\(\\)", "replacement": ".is_empty()", "since": "4.0", "message": "Container .empty() was renamed to .is_empty() in Godot 4.0."},
		{"id": "instance_method", "kind": "method", "status": "removed", "pattern": "\\.instance\\(\\)", "replacement": ".instantiate()", "since": "4.0", "message": "PackedScene.instance() was renamed to instantiate() in Godot 4.0."}
	]

func _register_find_deprecated_api_usage(server_core: RefCounted) -> void:
	var tool_name: String = "find_deprecated_api_usage"
	var description: String = "Scan project scripts for usage of removed/deprecated Godot 4.x APIs (e.g. Pool*Array, yield, setget, .empty(), .instance(), VisualServer) and report file:line with the modern replacement. Class/property rules are cross-checked against the running engine's ClassDB."

	var input_schema: Dictionary = {
		"type": "object",
		"properties": {
			"search_path": {
				"type": "string",
				"description": "Directory to scan. Default is res://.",
				"default": "res://"
			},
			"languages": {
				"type": "array",
				"items": {"type": "string"},
				"description": "Script extensions to scan (without dot). Default is ['gd', 'cs'].",
				"default": ["gd", "cs"]
			},
			"limit": {
				"type": "integer",
				"description": "Maximum number of findings to return. Default is 1000.",
				"default": 1000
			}
		}
	}

	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"search_path": {"type": "string"},
			"scanned_files": {"type": "integer"},
			"rules_evaluated": {"type": "integer"},
			"finding_count": {"type": "integer"},
			"total_count": {"type": "integer"},
			"truncated": {"type": "boolean"},
			"findings": {"type": "array"}
		}
	}

	var annotations: Dictionary = {
		"readOnlyHint": true,
		"destructiveHint": false,
		"idempotentHint": true,
		"openWorldHint": false
	}

	server_core.register_tool(tool_name, description, input_schema,
						  Callable(self, "_tool_find_deprecated_api_usage"),
						  output_schema, annotations,
						  "supplementary", "Project-Advanced")

func _tool_find_deprecated_api_usage(params: Dictionary) -> Dictionary:
	var search_path: String = str(params.get("search_path", "res://")).strip_edges()
	var search_validation: Dictionary = PathValidator.validate_directory_path(search_path)
	if not search_validation["valid"]:
		return {"error": "Invalid path: " + search_validation["error"]}
	search_path = search_validation["sanitized"]

	var languages: Array = params.get("languages", ["gd", "cs"])
	var extensions: Array[String] = []
	for language in languages:
		var ext: String = str(language).strip_edges().to_lower()
		if ext.is_empty():
			continue
		if not ext.begins_with("."):
			ext = "." + ext
		extensions.append(ext)
	if extensions.is_empty():
		extensions = [".gd", ".cs"]

	var limit: int = int(params.get("limit", 1000))

	var rules: Array = _deprecated_api_rules()
	var compiled: Array = []
	for rule in rules:
		var regex: RegEx = RegEx.new()
		if regex.compile(str(rule.get("pattern", ""))) != OK:
			continue
		var enriched: Dictionary = rule.duplicate()
		var engine_class: String = str(rule.get("engine_class", ""))
		if not engine_class.is_empty():
			enriched["present_in_engine"] = ClassDB.class_exists(engine_class)
		var replacement_class: String = str(rule.get("replacement_class", ""))
		if not replacement_class.is_empty():
			enriched["replacement_available"] = ClassDB.class_exists(replacement_class)
		compiled.append({"rule": enriched, "regex": regex})

	var files: Array[String] = []
	_collect_resources(search_path, extensions, files)
	files.sort()

	var findings: Array = []
	for file_path in files:
		var file: FileAccess = FileAccess.open(file_path, FileAccess.READ)
		if not file:
			continue
		var line_number: int = 0
		while not file.eof_reached():
			var line: String = file.get_line()
			line_number += 1
			var stripped: String = line.strip_edges()
			if stripped.begins_with("#") or stripped.begins_with("//"):
				continue
			for entry in compiled:
				var regex: RegEx = entry["regex"]
				var rule: Dictionary = entry["rule"]
				for found in regex.search_all(line):
					var finding: Dictionary = {
						"file": file_path,
						"line": line_number,
						"column": found.get_start(),
						"rule_id": rule.get("id", ""),
						"kind": rule.get("kind", ""),
						"status": rule.get("status", ""),
						"symbol": found.get_string(),
						"replacement": rule.get("replacement", ""),
						"since": rule.get("since", ""),
						"message": rule.get("message", "")
					}
					if rule.has("present_in_engine"):
						finding["present_in_engine"] = rule["present_in_engine"]
					if rule.has("replacement_available"):
						finding["replacement_available"] = rule["replacement_available"]
					findings.append(finding)
		file.close()

	var bounded: Dictionary = PayloadUtils.truncate_list(findings, limit)
	return {
		"search_path": search_path,
		"scanned_files": files.size(),
		"rules_evaluated": compiled.size(),
		"finding_count": int(bounded["total_count"]),
		"total_count": int(bounded["total_count"]),
		"truncated": bool(bounded["truncated"]),
		"findings": bounded["items"]
	}

# ============================================================================
# detect_gdextension_addons - find native GDExtension addons (detect only)
# ============================================================================

func _register_detect_gdextension_addons(server_core: RefCounted) -> void:
	var tool_name: String = "detect_gdextension_addons"
	var description: String = "Detect native GDExtension addons by scanning for .gdextension files, report their entry symbol, compatibility_minimum and per-platform library paths (with a presence check for each .so/.dll/.dylib), and surface any SConstruct build files with suggested scons commands. Detection only; this tool never compiles anything."

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
			"has_native_extensions": {"type": "boolean"},
			"extension_count": {"type": "integer"},
			"extensions": {"type": "array"},
			"sconstruct_files": {"type": "array", "items": {"type": "string"}},
			"build_hint": {"type": "object"}
		}
	}

	var annotations: Dictionary = {
		"readOnlyHint": true,
		"destructiveHint": false,
		"idempotentHint": true,
		"openWorldHint": false
	}

	server_core.register_tool(tool_name, description, input_schema,
						  Callable(self, "_tool_detect_gdextension_addons"),
						  output_schema, annotations,
						  "supplementary", "Project-Advanced")

func _tool_detect_gdextension_addons(params: Dictionary) -> Dictionary:
	var search_path: String = str(params.get("search_path", "res://")).strip_edges()
	var search_validation: Dictionary = PathValidator.validate_directory_path(search_path)
	if not search_validation["valid"]:
		return {"error": "Invalid path: " + search_validation["error"]}
	search_path = search_validation["sanitized"]

	var extension_files: Array[String] = []
	_collect_resources(search_path, [".gdextension"], extension_files)
	extension_files.sort()

	var sconstruct_files: Array[String] = []
	_collect_resources(search_path, ["SConstruct"], sconstruct_files)
	sconstruct_files.sort()

	var extensions: Array = []
	for extension_path in extension_files:
		extensions.append(_describe_gdextension(extension_path))

	var has_native: bool = not extensions.is_empty()
	var build_hint: Dictionary = {
		"detected_sconstruct": not sconstruct_files.is_empty(),
		"note": "Detection only; this tool does not run any build. Compile manually with the godot-cpp toolchain.",
		"commands": [
			"scons platform=<platform> target=template_debug",
			"scons platform=<platform> target=template_release"
		],
		"docs": "https://docs.godotengine.org/en/latest/engine_details/development/compiling/"
	}

	return {
		"search_path": search_path,
		"has_native_extensions": has_native,
		"extension_count": extensions.size(),
		"extensions": extensions,
		"sconstruct_files": sconstruct_files,
		"build_hint": build_hint
	}

func _describe_gdextension(extension_path: String) -> Dictionary:
	var config: ConfigFile = ConfigFile.new()
	if config.load(extension_path) != OK:
		return {"path": extension_path, "error": "Failed to parse .gdextension file"}

	var libraries: Array = []
	var missing: int = 0
	if config.has_section("libraries"):
		var keys: PackedStringArray = config.get_section_keys("libraries")
		for tag in keys:
			var lib_path: String = str(config.get_value("libraries", tag, ""))
			var resolved: String = lib_path
			if resolved.begins_with("res://"):
				resolved = ProjectSettings.globalize_path(resolved)
			var exists: bool = FileAccess.file_exists(lib_path) or FileAccess.file_exists(resolved)
			if not exists:
				missing += 1
			libraries.append({"target": tag, "path": lib_path, "exists": exists})

	var dependencies: Array = []
	if config.has_section("dependencies"):
		for tag in config.get_section_keys("dependencies"):
			dependencies.append({"target": tag, "path": str(config.get_value("dependencies", tag, ""))})

	return {
		"path": extension_path,
		"entry_symbol": str(config.get_value("configuration", "entry_symbol", "")),
		"compatibility_minimum": str(config.get_value("configuration", "compatibility_minimum", "")),
		"reloadable": bool(config.get_value("configuration", "reloadable", false)),
		"libraries": libraries,
		"library_count": libraries.size(),
		"missing_library_count": missing,
		"all_libraries_present": libraries.size() > 0 and missing == 0,
		"dependencies": dependencies
	}

# ============================================================================
# create_gradient_texture - build a GradientTexture2D (incl. Godot 4.7 conic)
# ============================================================================

const _GRADIENT_FILL_MODES: Dictionary = {
	"linear": 0,
	"radial": 1,
	"square": 2,
	"conic": 3
}

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
				colors.append(_parse_color(stop.get("color")))
			else:
				offsets.append(clampf(float(auto_index) / float(auto_total), 0.0, 1.0))
				colors.append(_parse_color(stop))
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
		fill_color = _parse_color(params["color"])

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
			modulate = _parse_color(op["modulate"])
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
			fg_colors.append(_parse_color(c))
	else:
		fg_colors = [_asset_seed_color(seed, 1), _asset_seed_color(seed, 7)]

	var background: Color = _parse_color(params["background"]) if params.has("background") else _asset_seed_color(seed, 13).darkened(0.55)

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

	var api_key: String = ""
	var api_key_env: String = str(cfg["api_key_env"]).strip_edges()
	if not api_key_env.is_empty():
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
	var fetched: Dictionary = _http_blocking_request(endpoint, method, headers, body, timeout_sec)
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

# Blocking HTTPClient request usable from a RefCounted tool (no SceneTree node).
func _http_blocking_request(url: String, method: int, headers: PackedStringArray, body: String, timeout_sec: float) -> Dictionary:
	var scheme_end: int = url.find("://")
	if scheme_end == -1:
		return {"error": "Invalid endpoint URL (missing scheme): " + url}
	var scheme: String = url.substr(0, scheme_end).to_lower()
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
			theme.set_color(item_name, theme_type, _parse_color(value))
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
func _coerce_setting_value(value: Variant, value_type: String) -> Dictionary:
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
			"reuse_track": {"type": "boolean", "description": "Reuse an existing track that matches path and type instead of adding a new one. Default true.", "default": true}
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

	return {
		"status": "success",
		"animation_path": animation_path,
		"track_path": track_path,
		"track_type": track_type_name,
		"track_index": track_index,
		"keys_inserted": keys_inserted,
		"created_track": created_track
	}

func _insert_animation_key(animation: Animation, track_index: int, track_type: int, track_type_name: String, time: float, raw_value: Variant, value_type: String) -> Dictionary:
	match track_type:
		Animation.TYPE_VALUE:
			var coerced: Dictionary = _coerce_setting_value(raw_value, value_type)
			if coerced.has("error"):
				return coerced
			animation.track_insert_key(track_index, time, coerced["value"])
		Animation.TYPE_POSITION_3D, Animation.TYPE_SCALE_3D:
			var vec: Variant = _parse_vector3(raw_value)
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
# create_tileset - Create and save a TileSet (.tres/.res) for 2D tile maps.
# Optionally add a TileSetAtlasSource from a texture and auto-create the atlas
# tiles in the grid. Pairs with set_tilemap_layer_cells (4.7 TileMapLayer).
# ============================================================================

func _register_create_tileset(server_core: RefCounted) -> void:
	var tool_name: String = "create_tileset"
	var description: String = "Create and save a TileSet resource (.tres/.res) for 2D tile maps consumed by a TileMapLayer (Godot 4.x). Sets tile_size, and optionally adds a TileSetAtlasSource from a texture (texture_region_size defaults to tile_size). When create_tiles is true (default) every grid cell that fits in the texture is created as a tile. Returns the atlas source_id and how many tiles were created."

	var input_schema: Dictionary = {
		"type": "object",
		"properties": {
			"tileset_path": {"type": "string", "description": "Save path for the TileSet (.tres/.res), e.g. res://tilesets/ground.tres."},
			"tile_size": {"type": "array", "description": "Tile grid size in pixels as [w, h] (or {x, y}). Default [16, 16].", "items": {"type": "integer"}},
			"texture_path": {"type": "string", "description": "Optional res:// path to a Texture2D to add as a TileSetAtlasSource."},
			"texture_region_size": {"type": "array", "description": "Atlas tile region size in pixels as [w, h]. Defaults to tile_size.", "items": {"type": "integer"}},
			"create_tiles": {"type": "boolean", "description": "Auto-create every atlas grid tile that fits in the texture. Default true.", "default": true}
		},
		"required": ["tileset_path"]
	}

	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"status": {"type": "string"},
			"tileset_path": {"type": "string"},
			"tile_size": {"type": "array"},
			"source_id": {"type": "integer"},
			"tiles_created": {"type": "integer"}
		}
	}

	var annotations: Dictionary = {
		"readOnlyHint": false,
		"destructiveHint": false,
		"idempotentHint": false,
		"openWorldHint": false
	}

	server_core.register_tool(tool_name, description, input_schema,
						  Callable(self, "_tool_create_tileset"),
						  output_schema, annotations,
						  "supplementary", "Project-Advanced")

func _tool_create_tileset(params: Dictionary) -> Dictionary:
	var tileset_path: String = str(params.get("tileset_path", "")).strip_edges()
	if tileset_path.is_empty():
		return {"error": "Missing required parameter: tileset_path"}

	var validation: Dictionary = PathValidator.validate_file_path(tileset_path, [".tres", ".res"])
	if not validation["valid"]:
		return {"error": "Invalid path: " + validation["error"]}
	tileset_path = validation["sanitized"]

	var tile_size: Vector2i = Vector2i(16, 16)
	if params.has("tile_size"):
		var parsed_size: Variant = _parse_vector2i(params["tile_size"])
		if parsed_size == null:
			return {"error": "Parameter 'tile_size' must be [w, h] or {x, y}"}
		tile_size = parsed_size
	if tile_size.x <= 0 or tile_size.y <= 0:
		return {"error": "tile_size must be positive"}

	var tile_set: TileSet = TileSet.new()
	tile_set.tile_size = tile_size

	var source_id: int = -1
	var tiles_created: int = 0
	var texture_path: String = str(params.get("texture_path", "")).strip_edges()
	if not texture_path.is_empty():
		if not ResourceLoader.exists(texture_path):
			return {"error": "Texture not found: " + texture_path}
		var texture: Texture2D = ResourceLoader.load(texture_path) as Texture2D
		if not texture:
			return {"error": "Resource is not a Texture2D: " + texture_path}

		var region_size: Vector2i = tile_size
		if params.has("texture_region_size"):
			var parsed_region: Variant = _parse_vector2i(params["texture_region_size"])
			if parsed_region == null:
				return {"error": "Parameter 'texture_region_size' must be [w, h] or {x, y}"}
			region_size = parsed_region
		if region_size.x <= 0 or region_size.y <= 0:
			return {"error": "texture_region_size must be positive"}

		var atlas: TileSetAtlasSource = TileSetAtlasSource.new()
		atlas.texture = texture
		atlas.texture_region_size = region_size
		source_id = tile_set.add_source(atlas)

		if bool(params.get("create_tiles", true)):
			var columns: int = int(texture.get_width() / region_size.x)
			var rows: int = int(texture.get_height() / region_size.y)
			for ty in range(rows):
				for tx in range(columns):
					var coords: Vector2i = Vector2i(tx, ty)
					if not atlas.has_tile(coords):
						atlas.create_tile(coords)
						tiles_created += 1

	var dir_path: String = tileset_path.get_base_dir()
	if not dir_path.is_empty() and not DirAccess.dir_exists_absolute(dir_path):
		var mk: Error = DirAccess.make_dir_recursive_absolute(dir_path)
		if mk != OK:
			return {"error": "Failed to create directory: " + dir_path}

	var error: Error = ResourceSaver.save(tile_set, tileset_path)
	if error != OK:
		return {"error": "Failed to save tileset: " + error_string(error)}

	return {
		"status": "success",
		"tileset_path": tileset_path,
		"tile_size": [tile_set.tile_size.x, tile_set.tile_size.y],
		"source_id": source_id,
		"tiles_created": tiles_created
	}

static func _parse_vector2i(value: Variant) -> Variant:
	if value is Vector2i:
		return value
	if value is Vector2:
		return Vector2i(value)
	if value is Dictionary:
		return Vector2i(int(value.get("x", 0)), int(value.get("y", 0)))
	if value is Array and value.size() >= 2:
		return Vector2i(int(value[0]), int(value[1]))
	return null

# ============================================================================
# Batch 8 - TileSet physics / terrain / navigation / custom-data layers
# ============================================================================

const _TILESET_CELL_NEIGHBORS: Dictionary = {
	"right_side": TileSet.CELL_NEIGHBOR_RIGHT_SIDE,
	"bottom_right_corner": TileSet.CELL_NEIGHBOR_BOTTOM_RIGHT_CORNER,
	"bottom_side": TileSet.CELL_NEIGHBOR_BOTTOM_SIDE,
	"bottom_left_corner": TileSet.CELL_NEIGHBOR_BOTTOM_LEFT_CORNER,
	"left_side": TileSet.CELL_NEIGHBOR_LEFT_SIDE,
	"top_left_corner": TileSet.CELL_NEIGHBOR_TOP_LEFT_CORNER,
	"top_side": TileSet.CELL_NEIGHBOR_TOP_SIDE,
	"top_right_corner": TileSet.CELL_NEIGHBOR_TOP_RIGHT_CORNER
}

const _TILESET_TERRAIN_MODES: Dictionary = {
	"corners": TileSet.TERRAIN_MODE_MATCH_CORNERS,
	"sides": TileSet.TERRAIN_MODE_MATCH_SIDES,
	"corners_and_sides": TileSet.TERRAIN_MODE_MATCH_CORNERS_AND_SIDES
}

func _load_tileset_for_edit(tileset_path: String) -> Dictionary:
	var validation: Dictionary = PathValidator.validate_file_path(tileset_path, [".tres", ".res"])
	if not validation["valid"]:
		return {"error": "Invalid path: " + validation["error"]}
	var sanitized: String = validation["sanitized"]
	if not ResourceLoader.exists(sanitized):
		return {"error": "TileSet not found: " + sanitized}
	var tile_set: TileSet = ResourceLoader.load(sanitized) as TileSet
	if not tile_set:
		return {"error": "Resource is not a TileSet: " + sanitized}
	return {"tile_set": tile_set, "path": sanitized}

func _resolve_atlas_tile_data(tile_set: TileSet, source_id: int, coords: Vector2i, alternative_id: int) -> Dictionary:
	if not tile_set.has_source(source_id):
		return {"error": "TileSet has no source with id %d" % source_id}
	var atlas: TileSetAtlasSource = tile_set.get_source(source_id) as TileSetAtlasSource
	if not atlas:
		return {"error": "Source %d is not a TileSetAtlasSource" % source_id}
	if not atlas.has_tile(coords):
		return {"error": "Atlas source %d has no tile at coords (%d, %d)" % [source_id, coords.x, coords.y]}
	if not atlas.has_alternative_tile(coords, alternative_id):
		return {"error": "Tile (%d, %d) has no alternative with id %d" % [coords.x, coords.y, alternative_id]}
	var tile_data: TileData = atlas.get_tile_data(coords, alternative_id)
	if not tile_data:
		return {"error": "Failed to resolve TileData for tile (%d, %d)" % [coords.x, coords.y]}
	return {"tile_data": tile_data}

# --- configure_tileset_layers --------------------------------------------------

func _register_configure_tileset_layers(server_core: RefCounted) -> void:
	var tool_name: String = "configure_tileset_layers"
	var description: String = "Add and configure layers on an existing TileSet resource (.tres/.res): physics layers (collision_layer/mask bitmasks), navigation layers (layers bitmask), custom data layers (name + Variant type), and terrain sets with terrains (name, color, match mode). New layers are appended; existing layers are preserved. Saves the TileSet back to disk. Use after create_tileset so tiles can support collision, autotiling, navigation, and per-tile metadata."

	var input_schema: Dictionary = {
		"type": "object",
		"properties": {
			"tileset_path": {"type": "string", "description": "Path to an existing TileSet (.tres/.res)."},
			"physics_layers": {"type": "array", "description": "Physics layers to append. Each item is {collision_layer:int=1, collision_mask:int=1} (bitmasks)."},
			"navigation_layers": {"type": "array", "description": "Navigation layers to append. Each item is {layers:int=1} (navigation layers bitmask)."},
			"custom_data_layers": {"type": "array", "description": "Custom data layers to append. Each item is {name:string, type:int}. type is a Variant.Type value (e.g. 4=String, 2=int, 3=float, 1=bool, 5=Vector2, 20=Color). Defaults to 4 (String)."},
			"terrain_sets": {"type": "array", "description": "Terrain sets to append. Each item is {mode:string(corners|sides|corners_and_sides, default corners_and_sides), terrains:[{name:string, color:string|array|object}]}."}
		},
		"required": ["tileset_path"]
	}

	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"status": {"type": "string"},
			"tileset_path": {"type": "string"},
			"physics_layers_count": {"type": "integer"},
			"navigation_layers_count": {"type": "integer"},
			"custom_data_layers_count": {"type": "integer"},
			"terrain_sets_count": {"type": "integer"},
			"physics_layers_added": {"type": "integer"},
			"navigation_layers_added": {"type": "integer"},
			"custom_data_layers_added": {"type": "integer"},
			"terrain_sets_added": {"type": "integer"}
		}
	}

	var annotations: Dictionary = {
		"readOnlyHint": false,
		"destructiveHint": false,
		"idempotentHint": false,
		"openWorldHint": false
	}

	server_core.register_tool(tool_name, description, input_schema,
						  Callable(self, "_tool_configure_tileset_layers"),
						  output_schema, annotations,
						  "supplementary", "Project-Advanced")

func _tool_configure_tileset_layers(params: Dictionary) -> Dictionary:
	var tileset_path: String = str(params.get("tileset_path", "")).strip_edges()
	if tileset_path.is_empty():
		return {"error": "Missing required parameter: tileset_path"}

	var loaded: Dictionary = _load_tileset_for_edit(tileset_path)
	if loaded.has("error"):
		return loaded
	var tile_set: TileSet = loaded["tile_set"]
	var sanitized: String = loaded["path"]

	var physics_added: int = 0
	if params.has("physics_layers"):
		if not (params["physics_layers"] is Array):
			return {"error": "Parameter 'physics_layers' must be an array"}
		for entry in params["physics_layers"]:
			if not (entry is Dictionary):
				return {"error": "Each physics_layers item must be an object"}
			tile_set.add_physics_layer()
			var idx: int = tile_set.get_physics_layers_count() - 1
			tile_set.set_physics_layer_collision_layer(idx, int(entry.get("collision_layer", 1)))
			tile_set.set_physics_layer_collision_mask(idx, int(entry.get("collision_mask", 1)))
			physics_added += 1

	var navigation_added: int = 0
	if params.has("navigation_layers"):
		if not (params["navigation_layers"] is Array):
			return {"error": "Parameter 'navigation_layers' must be an array"}
		for entry in params["navigation_layers"]:
			if not (entry is Dictionary):
				return {"error": "Each navigation_layers item must be an object"}
			tile_set.add_navigation_layer()
			var idx: int = tile_set.get_navigation_layers_count() - 1
			tile_set.set_navigation_layer_layers(idx, int(entry.get("layers", 1)))
			navigation_added += 1

	var custom_added: int = 0
	if params.has("custom_data_layers"):
		if not (params["custom_data_layers"] is Array):
			return {"error": "Parameter 'custom_data_layers' must be an array"}
		for entry in params["custom_data_layers"]:
			if not (entry is Dictionary):
				return {"error": "Each custom_data_layers item must be an object"}
			var type_value: int = int(entry.get("type", TYPE_STRING))
			if type_value < 0 or type_value >= TYPE_MAX:
				return {"error": "custom_data_layers type must be a valid Variant.Type (0..%d)" % (TYPE_MAX - 1)}
			tile_set.add_custom_data_layer()
			var idx: int = tile_set.get_custom_data_layers_count() - 1
			var layer_name: String = str(entry.get("name", "")).strip_edges()
			if not layer_name.is_empty():
				tile_set.set_custom_data_layer_name(idx, layer_name)
			tile_set.set_custom_data_layer_type(idx, type_value)
			custom_added += 1

	var terrain_sets_added: int = 0
	if params.has("terrain_sets"):
		if not (params["terrain_sets"] is Array):
			return {"error": "Parameter 'terrain_sets' must be an array"}
		for entry in params["terrain_sets"]:
			if not (entry is Dictionary):
				return {"error": "Each terrain_sets item must be an object"}
			var mode_name: String = str(entry.get("mode", "corners_and_sides")).strip_edges().to_lower()
			if not _TILESET_TERRAIN_MODES.has(mode_name):
				return {"error": "Invalid terrain set mode '%s' (use corners, sides, or corners_and_sides)" % mode_name}
			tile_set.add_terrain_set()
			var set_idx: int = tile_set.get_terrain_sets_count() - 1
			tile_set.set_terrain_set_mode(set_idx, _TILESET_TERRAIN_MODES[mode_name])
			if entry.has("terrains"):
				if not (entry["terrains"] is Array):
					return {"error": "terrain_sets 'terrains' must be an array"}
				for terrain_entry in entry["terrains"]:
					if not (terrain_entry is Dictionary):
						return {"error": "Each terrains item must be an object"}
					tile_set.add_terrain(set_idx)
					var terrain_idx: int = tile_set.get_terrains_count(set_idx) - 1
					var terrain_name: String = str(terrain_entry.get("name", "")).strip_edges()
					if not terrain_name.is_empty():
						tile_set.set_terrain_name(set_idx, terrain_idx, terrain_name)
					if terrain_entry.has("color"):
						tile_set.set_terrain_color(set_idx, terrain_idx, _parse_color(terrain_entry["color"]))
			terrain_sets_added += 1

	var error: Error = ResourceSaver.save(tile_set, sanitized)
	if error != OK:
		return {"error": "Failed to save tileset: " + error_string(error)}

	return {
		"status": "success",
		"tileset_path": sanitized,
		"physics_layers_count": tile_set.get_physics_layers_count(),
		"navigation_layers_count": tile_set.get_navigation_layers_count(),
		"custom_data_layers_count": tile_set.get_custom_data_layers_count(),
		"terrain_sets_count": tile_set.get_terrain_sets_count(),
		"physics_layers_added": physics_added,
		"navigation_layers_added": navigation_added,
		"custom_data_layers_added": custom_added,
		"terrain_sets_added": terrain_sets_added
	}

# --- set_tile_collision_polygon -----------------------------------------------

func _register_set_tile_collision_polygon(server_core: RefCounted) -> void:
	var tool_name: String = "set_tile_collision_polygon"
	var description: String = "Set a collision polygon on a tile inside a TileSet atlas source, on a given physics layer. Provide explicit polygon 'points', or omit them to auto-generate a full-tile rectangle (centered on the tile, sized to the TileSet tile_size) so the tile becomes solid. Optionally mark the polygon one-way. The physics layer must already exist (add it with configure_tileset_layers). Saves the TileSet."

	var input_schema: Dictionary = {
		"type": "object",
		"properties": {
			"tileset_path": {"type": "string", "description": "Path to an existing TileSet (.tres/.res)."},
			"source_id": {"type": "integer", "description": "Atlas source id (returned by create_tileset)."},
			"tile_coords": {"type": "array", "description": "Atlas tile coordinates as [x, y] (or {x, y}).", "items": {"type": "integer"}},
			"alternative_id": {"type": "integer", "description": "Alternative tile id. Default 0 (the base tile).", "default": 0},
			"physics_layer": {"type": "integer", "description": "Physics layer index on the TileSet. Default 0.", "default": 0},
			"points": {"type": "array", "description": "Polygon vertices as a list of [x, y] (or {x, y}), in tile-local pixels centered on the tile origin. Omit to generate a full-tile rectangle."},
			"one_way": {"type": "boolean", "description": "Mark the polygon as one-way collision. Default false.", "default": false}
		},
		"required": ["tileset_path", "source_id", "tile_coords"]
	}

	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"status": {"type": "string"},
			"tileset_path": {"type": "string"},
			"source_id": {"type": "integer"},
			"tile_coords": {"type": "array"},
			"physics_layer": {"type": "integer"},
			"polygon_points": {"type": "array"},
			"one_way": {"type": "boolean"}
		}
	}

	var annotations: Dictionary = {
		"readOnlyHint": false,
		"destructiveHint": false,
		"idempotentHint": false,
		"openWorldHint": false
	}

	server_core.register_tool(tool_name, description, input_schema,
						  Callable(self, "_tool_set_tile_collision_polygon"),
						  output_schema, annotations,
						  "supplementary", "Project-Advanced")

func _tool_set_tile_collision_polygon(params: Dictionary) -> Dictionary:
	var tileset_path: String = str(params.get("tileset_path", "")).strip_edges()
	if tileset_path.is_empty():
		return {"error": "Missing required parameter: tileset_path"}
	if not params.has("source_id"):
		return {"error": "Missing required parameter: source_id"}
	if not params.has("tile_coords"):
		return {"error": "Missing required parameter: tile_coords"}

	var coords_parsed: Variant = _parse_vector2i(params["tile_coords"])
	if coords_parsed == null:
		return {"error": "Parameter 'tile_coords' must be [x, y] or {x, y}"}
	var coords: Vector2i = coords_parsed

	var loaded: Dictionary = _load_tileset_for_edit(tileset_path)
	if loaded.has("error"):
		return loaded
	var tile_set: TileSet = loaded["tile_set"]
	var sanitized: String = loaded["path"]

	var physics_layer: int = int(params.get("physics_layer", 0))
	if physics_layer < 0 or physics_layer >= tile_set.get_physics_layers_count():
		return {"error": "physics_layer %d out of range (TileSet has %d physics layers)" % [physics_layer, tile_set.get_physics_layers_count()]}

	var alternative_id: int = int(params.get("alternative_id", 0))
	var resolved: Dictionary = _resolve_atlas_tile_data(tile_set, int(params["source_id"]), coords, alternative_id)
	if resolved.has("error"):
		return resolved
	var tile_data: TileData = resolved["tile_data"]

	var polygon: PackedVector2Array = PackedVector2Array()
	if params.has("points"):
		if not (params["points"] is Array):
			return {"error": "Parameter 'points' must be an array of [x, y]"}
		for point in params["points"]:
			var pv: Variant = _parse_vector2(point)
			if pv == null:
				return {"error": "Each points item must be [x, y] or {x, y}"}
			polygon.append(pv)
		if polygon.size() < 3:
			return {"error": "A collision polygon needs at least 3 points"}
	else:
		var half: Vector2 = Vector2(tile_set.tile_size) * 0.5
		polygon.append(Vector2(-half.x, -half.y))
		polygon.append(Vector2(half.x, -half.y))
		polygon.append(Vector2(half.x, half.y))
		polygon.append(Vector2(-half.x, half.y))

	var one_way: bool = bool(params.get("one_way", false))
	tile_data.add_collision_polygon(physics_layer)
	var polygon_index: int = tile_data.get_collision_polygons_count(physics_layer) - 1
	tile_data.set_collision_polygon_points(physics_layer, polygon_index, polygon)
	tile_data.set_collision_polygon_one_way(physics_layer, polygon_index, one_way)

	var error: Error = ResourceSaver.save(tile_set, sanitized)
	if error != OK:
		return {"error": "Failed to save tileset: " + error_string(error)}

	var points_out: Array = []
	for p in polygon:
		points_out.append([p.x, p.y])

	return {
		"status": "success",
		"tileset_path": sanitized,
		"source_id": int(params["source_id"]),
		"tile_coords": [coords.x, coords.y],
		"physics_layer": physics_layer,
		"polygon_points": points_out,
		"one_way": one_way
	}

# --- set_tile_terrain ---------------------------------------------------------

func _register_set_tile_terrain(server_core: RefCounted) -> void:
	var tool_name: String = "set_tile_terrain"
	var description: String = "Assign a terrain set and terrain to a tile in a TileSet atlas source, and optionally set terrain peering bits for autotiling. The terrain set and terrain must already exist (create them with configure_tileset_layers). peering_bits maps neighbor names (right_side, bottom_right_corner, bottom_side, bottom_left_corner, left_side, top_left_corner, top_side, top_right_corner) to a terrain index; neighbors that are not valid for the terrain set's match mode and tile shape are rejected with an error. Saves the TileSet."

	var input_schema: Dictionary = {
		"type": "object",
		"properties": {
			"tileset_path": {"type": "string", "description": "Path to an existing TileSet (.tres/.res)."},
			"source_id": {"type": "integer", "description": "Atlas source id (returned by create_tileset)."},
			"tile_coords": {"type": "array", "description": "Atlas tile coordinates as [x, y] (or {x, y}).", "items": {"type": "integer"}},
			"alternative_id": {"type": "integer", "description": "Alternative tile id. Default 0 (the base tile).", "default": 0},
			"terrain_set": {"type": "integer", "description": "Terrain set index on the TileSet."},
			"terrain": {"type": "integer", "description": "Terrain index within the terrain set."},
			"peering_bits": {"type": "object", "description": "Optional map of neighbor name -> terrain index for autotiling, e.g. {\"top_side\": 0, \"left_side\": 0}."}
		},
		"required": ["tileset_path", "source_id", "tile_coords", "terrain_set", "terrain"]
	}

	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"status": {"type": "string"},
			"tileset_path": {"type": "string"},
			"source_id": {"type": "integer"},
			"tile_coords": {"type": "array"},
			"terrain_set": {"type": "integer"},
			"terrain": {"type": "integer"},
			"peering_bits_set": {"type": "array"}
		}
	}

	var annotations: Dictionary = {
		"readOnlyHint": false,
		"destructiveHint": false,
		"idempotentHint": false,
		"openWorldHint": false
	}

	server_core.register_tool(tool_name, description, input_schema,
						  Callable(self, "_tool_set_tile_terrain"),
						  output_schema, annotations,
						  "supplementary", "Project-Advanced")

func _tool_set_tile_terrain(params: Dictionary) -> Dictionary:
	var tileset_path: String = str(params.get("tileset_path", "")).strip_edges()
	if tileset_path.is_empty():
		return {"error": "Missing required parameter: tileset_path"}
	if not params.has("source_id"):
		return {"error": "Missing required parameter: source_id"}
	if not params.has("tile_coords"):
		return {"error": "Missing required parameter: tile_coords"}
	if not params.has("terrain_set"):
		return {"error": "Missing required parameter: terrain_set"}
	if not params.has("terrain"):
		return {"error": "Missing required parameter: terrain"}

	var coords_parsed: Variant = _parse_vector2i(params["tile_coords"])
	if coords_parsed == null:
		return {"error": "Parameter 'tile_coords' must be [x, y] or {x, y}"}
	var coords: Vector2i = coords_parsed

	var loaded: Dictionary = _load_tileset_for_edit(tileset_path)
	if loaded.has("error"):
		return loaded
	var tile_set: TileSet = loaded["tile_set"]
	var sanitized: String = loaded["path"]

	var terrain_set: int = int(params["terrain_set"])
	if terrain_set < 0 or terrain_set >= tile_set.get_terrain_sets_count():
		return {"error": "terrain_set %d out of range (TileSet has %d terrain sets)" % [terrain_set, tile_set.get_terrain_sets_count()]}
	var terrain: int = int(params["terrain"])
	if terrain < 0 or terrain >= tile_set.get_terrains_count(terrain_set):
		return {"error": "terrain %d out of range (terrain set %d has %d terrains)" % [terrain, terrain_set, tile_set.get_terrains_count(terrain_set)]}

	var alternative_id: int = int(params.get("alternative_id", 0))
	var resolved: Dictionary = _resolve_atlas_tile_data(tile_set, int(params["source_id"]), coords, alternative_id)
	if resolved.has("error"):
		return resolved
	var tile_data: TileData = resolved["tile_data"]

	var peering_set: Array = []
	if params.has("peering_bits"):
		if not (params["peering_bits"] is Dictionary):
			return {"error": "Parameter 'peering_bits' must be an object of neighbor -> terrain index"}
		for neighbor_name in params["peering_bits"]:
			var key: String = str(neighbor_name).strip_edges().to_lower()
			if not _TILESET_CELL_NEIGHBORS.has(key):
				return {"error": "Unknown peering neighbor '%s'" % str(neighbor_name)}
			if not tile_set.is_valid_terrain_peering_bit(terrain_set, _TILESET_CELL_NEIGHBORS[key]):
				return {"error": "peering neighbor '%s' is not valid for terrain set %d (check its match mode and tile shape)" % [key, terrain_set]}
			var peer_terrain: int = int(params["peering_bits"][neighbor_name])
			if peer_terrain < 0 or peer_terrain >= tile_set.get_terrains_count(terrain_set):
				return {"error": "peering_bits['%s'] terrain %d out of range" % [key, peer_terrain]}

	tile_data.set_terrain_set(terrain_set)
	tile_data.set_terrain(terrain)
	if params.has("peering_bits"):
		for neighbor_name in params["peering_bits"]:
			var key: String = str(neighbor_name).strip_edges().to_lower()
			tile_data.set_terrain_peering_bit(_TILESET_CELL_NEIGHBORS[key], int(params["peering_bits"][neighbor_name]))
			peering_set.append(key)

	var error: Error = ResourceSaver.save(tile_set, sanitized)
	if error != OK:
		return {"error": "Failed to save tileset: " + error_string(error)}

	return {
		"status": "success",
		"tileset_path": sanitized,
		"source_id": int(params["source_id"]),
		"tile_coords": [coords.x, coords.y],
		"terrain_set": terrain_set,
		"terrain": terrain,
		"peering_bits_set": peering_set
	}

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
	var description: String = "Persist and query a durable task graph with Definition-of-Done (DoD) for AI-driven game production, stored as versioned JSON (default res://.mcp/task_plan.json) so plan -> execute -> run -> verify -> fix survives across sessions. action='init' creates/resets the plan with a goal; 'add_task' appends a task (auto id, depends_on, dod criteria, tags) with cycle detection; 'update_task' edits fields; 'set_status' sets pending/in_progress/blocked/done (refuses 'done' unless every DoD criterion is met, unless force=true); 'set_dod' replaces the criteria list or updates one criterion's met/evidence; 'get' returns the whole graph (or one task) plus progress; 'next' returns dependency-ready tasks, blocked tasks and progress; 'remove_task' deletes a task and strips dangling dependency references."

	var input_schema: Dictionary = {
		"type": "object",
		"properties": {
			"action": {"type": "string", "enum": _TASK_PLAN_ACTIONS, "description": "Operation to perform."},
			"plan_path": {"type": "string", "description": "Where the plan JSON lives (res:// or user://). Default res://.mcp/task_plan.json.", "default": _TASK_PLAN_DEFAULT_PATH},
			"goal": {"type": "string", "description": "action='init': the overall goal/objective for this plan."},
			"reset": {"type": "boolean", "description": "action='init': discard any existing plan and start empty. Default false.", "default": false},
			"id": {"type": "string", "description": "Task id. For add_task it is optional (auto 't<N>' when omitted); required for update_task/set_status/set_dod/remove_task and optional for get."},
			"title": {"type": "string", "description": "Task title (required for add_task)."},
			"description": {"type": "string", "description": "Task description / the action to perform."},
			"status": {"type": "string", "enum": TaskPlanStore.VALID_STATUSES, "description": "Task status for add_task/update_task/set_status."},
			"depends_on": {"type": "array", "items": {"type": "string"}, "description": "Ids this task depends on. Validated for existence and cycles."},
			"dod": {"type": "array", "description": "Definition-of-Done criteria: strings, or objects {criterion, met, evidence}. For set_dod this replaces the whole list."},
			"tags": {"type": "array", "items": {"type": "string"}, "description": "Free-form tags."},
			"journal": {"type": "string", "description": "A note to append to the task's journal (update_task / set_status)."},
			"force": {"type": "boolean", "description": "action='set_status': allow marking 'done' even when DoD criteria are unmet. Default false.", "default": false},
			"index": {"type": "integer", "description": "action='set_dod': index of the criterion to update."},
			"criterion": {"type": "string", "description": "action='set_dod': criterion text to match (or add) when not using index."},
			"met": {"type": "boolean", "description": "action='set_dod': whether the targeted criterion is met."},
			"evidence": {"type": "string", "description": "action='set_dod': evidence string for the targeted criterion."}
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
			if existing is Dictionary and not existing.has("error"):
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
