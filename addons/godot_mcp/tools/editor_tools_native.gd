# editor_tools_native.gd - Editor Tools原生实现
# 根据godot-dev-guide添加完整的类型提示

@tool
class_name EditorToolsNative
extends RefCounted

const VIBE_CODING_POLICY = preload("res://addons/godot_mcp/utils/vibe_coding_policy.gd")

var _editor_interface: EditorInterface = null
var _editor_operation_in_progress: bool = false

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

func _get_debugger_bridge() -> RefCounted:
	if Engine.has_meta("GodotMCPPlugin"):
		var plugin = Engine.get_meta("GodotMCPPlugin")
		if plugin and plugin.has_method("get_debugger_bridge"):
			return plugin.get_debugger_bridge()
	return null

# True once a played game child has connected back to the editor's debug server.
# The editor only reports an active session when the play actually spawned and
# connected a child process — a missing/failed scene leaves it inactive.
func _has_active_debugger_session() -> bool:
	var bridge: RefCounted = _get_debugger_bridge()
	if not bridge:
		return false
	for session in bridge.get_sessions_info():
		if bool(session.get("active", false)):
			return true
	return false

func _get_export_templates_root() -> String:
	var editor_interface: EditorInterface = _get_editor_interface()
	if editor_interface:
		var editor_paths: EditorPaths = editor_interface.get_editor_paths()
		if editor_paths:
			return editor_paths.get_export_templates_dir()
	var os_name: String = OS.get_name()
	if os_name == "Windows":
		var appdata: String = OS.get_environment("APPDATA")
		if not appdata.is_empty():
			return appdata.path_join("Godot").path_join("export_templates")
	elif os_name == "Linux" or os_name == "FreeBSD":
		var home: String = OS.get_environment("HOME")
		if not home.is_empty():
			return home.path_join(".local/share/godot/export_templates")
	elif os_name == "macOS":
		var home: String = OS.get_environment("HOME")
		if not home.is_empty():
			return home.path_join("Library/Application Support/Godot/export_templates")
	return ""

func _is_vibe_coding_mode() -> bool:
	if Engine.has_meta("GodotMCPPlugin"):
		var plugin = Engine.get_meta("GodotMCPPlugin")
		if plugin and plugin.get("vibe_coding_mode") != null:
			return bool(plugin.vibe_coding_mode)
	return true

func _get_user_scene_root() -> Node:
	var editor_interface: EditorInterface = _get_editor_interface()
	if not editor_interface:
		return null
	
	var scene_root: Node = editor_interface.get_edited_scene_root()
	if scene_root and not scene_root.name.begins_with("@") and scene_root.get_class() != "PanelContainer":
		return scene_root
	
	var open_scene_roots: Array = editor_interface.get_open_scene_roots()
	for root in open_scene_roots:
		var node_root: Node = root
		if node_root and not node_root.name.begins_with("@") and node_root.get_class() != "PanelContainer":
			return node_root
	
	return scene_root

static func _make_friendly_path(node: Node, scene_root: Node) -> String:
	if not scene_root:
		return str(node.get_path())
	if node == scene_root:
		return "/root/" + scene_root.name
	var node_path: String = str(node.get_path())
	var root_path: String = str(scene_root.get_path())
	if node_path.begins_with(root_path + "/"):
		return "/root/" + scene_root.name + node_path.substr(root_path.length())
	return node_path

# ============================================================================
# 工具注册
# ============================================================================

func register_tools(server_core: RefCounted) -> void:
	_register_get_editor_state(server_core)
	_register_run_project(server_core)
	_register_stop_project(server_core)
	_register_get_selected_nodes(server_core)
	_register_select_node(server_core)
	_register_select_file(server_core)
	_register_get_inspector_properties(server_core)
	_register_set_editor_setting(server_core)
	_register_get_editor_screenshot(server_core)
	_register_get_signals(server_core)
	_register_reload_project(server_core)
	_register_list_export_presets(server_core)
	_register_inspect_export_templates(server_core)
	_register_validate_export_preset(server_core)
	_register_run_export(server_core)
	_register_smoke_test_export(server_core)
	_register_manage_export_templates(server_core)
	_register_configure_android_export(server_core)
	_register_get_unsaved_changes(server_core)
	_register_save_all_scripts(server_core)
	_register_reload_open_scripts(server_core)
	_register_close_script_tab(server_core)
	_register_get_import_status(server_core)

# ============================================================================
# get_editor_state - 获取编辑器状态
# ============================================================================

func _register_get_editor_state(server_core: RefCounted) -> void:
	var tool_name: String = "get_editor_state"
	var description: String = "Get the current state of the Godot editor, including active scene and selection info."
	
	# inputSchema
	var input_schema: Dictionary = {
		"type": "object",
		"properties": {}
	}
	
	# outputSchema
	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"active_scene": {"type": "string"},
			"selected_nodes": {
				"type": "array",
				"items": {"type": "object"}
			},
			"editor_mode": {"type": "string"},
			"selected_count": {"type": "integer"}
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
						  Callable(self, "_tool_get_editor_state"),
						  output_schema, annotations,
						  "core", "Editor")

func _tool_get_editor_state(params: Dictionary) -> Dictionary:
	var editor_interface: EditorInterface = _get_editor_interface()
	if not editor_interface:
		return {"error": "Editor interface not available"}
	
	var scene_root: Node = _get_user_scene_root()
	var active_scene: String = scene_root.name if scene_root else ""
	
	var selected_nodes: Array = []
	var selection: EditorSelection = editor_interface.get_selection()
	if selection:
		var selected: Array[Node] = selection.get_selected_nodes()
		for node in selected:
			var node_info: Dictionary = {
				"path": _make_friendly_path(node, scene_root),
				"type": node.get_class()
			}
			var node_script: Variant = node.get_script()
			if node_script and node_script is Script:
				node_info["script_path"] = node_script.resource_path
			selected_nodes.append(node_info)
	
	var editor_mode: String = "editor"
	if editor_interface.is_playing_scene():
		editor_mode = "playing"
	
	return {
		"active_scene": active_scene,
		"selected_nodes": selected_nodes,
		"editor_mode": editor_mode,
		"selected_count": selected_nodes.size()
	}

# ============================================================================
# run_project - 运行项目
# ============================================================================

func _register_run_project(server_core: RefCounted) -> void:
	var tool_name: String = "run_project"
	var description: String = "Run the current project or a specific scene. Launches the game in play mode."
	
	# inputSchema
	var input_schema: Dictionary = {
		"type": "object",
		"properties": {
			"scene_path": {
				"type": "string",
				"description": "Optional path to a specific scene to run. If not provided, runs the main scene."
			},
			"allow_window": {
				"type": "boolean",
				"description": "Allow this call to open or control the runtime window when Vibe Coding mode is enabled.",
				"default": false
			}
		}
	}
	
	# outputSchema
	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"status": {"type": "string"},
			"mode": {"type": "string"},
			"scene": {"type": "string"},
			"session_active": {"type": "boolean"},
			"probe_ready": {"type": "boolean"}
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
						  Callable(self, "_tool_run_project"),
						  output_schema, annotations,
						  "core", "Editor")

func _tool_run_project(params: Dictionary) -> Dictionary:
	var policy_result: Dictionary = VIBE_CODING_POLICY.evaluate_runtime_window(_is_vibe_coding_mode(), params)
	if policy_result.get("blocked", false):
		return policy_result

	var editor_interface: EditorInterface = _get_editor_interface()
	if not editor_interface:
		return {"error": "Editor interface not available"}

	if editor_interface.is_playing_scene():
		return {"error": "Project is already running. Stop it first with stop_project."}

	var scene_path: String = params.get("scene_path", "")
	var played_scene: String = ""

	if not scene_path.is_empty():
		if not FileAccess.file_exists(scene_path):
			return {"error": "Scene file not found: " + scene_path}
		played_scene = scene_path
		editor_interface.play_custom_scene(scene_path)
	else:
		var scene_root: Node = _get_user_scene_root()
		if scene_root:
			played_scene = scene_root.scene_file_path
			editor_interface.play_current_scene()
		else:
			played_scene = String(ProjectSettings.get_setting("application/run/main_scene", ""))
			editor_interface.play_main_scene()

	# Verify the play actually launched a debuggable child. Without this guard a
	# failed play (e.g. application/run/main_scene pointing at a missing file)
	# reports a fake success and leaves callers stuck retrying runtime tools (#172).
	var tree: SceneTree = Engine.get_main_loop() as SceneTree
	var connected: bool = false
	var connect_deadline: int = Time.get_ticks_msec() + 5000
	while Time.get_ticks_msec() < connect_deadline:
		if _has_active_debugger_session():
			connected = true
			break
		if tree:
			await tree.process_frame
		else:
			break
	if not connected:
		return {
			"status": "error",
			"error": "Play was requested but no debugger session became active within the timeout. The scene likely failed to load — check ProjectSettings application/run/main_scene.",
			"scene": played_scene
		}

	# Give the runtime probe a brief window to signal ready so callers can use
	# runtime tools (scene tree, screenshot, expression eval) right away.
	var bridge: RefCounted = _get_debugger_bridge()
	var probe_ready: bool = bridge.is_probe_ready() if bridge else false
	var probe_deadline: int = Time.get_ticks_msec() + 2000
	while not probe_ready and tree and Time.get_ticks_msec() < probe_deadline:
		await tree.process_frame
		probe_ready = bridge.is_probe_ready() if bridge else false

	return {
		"status": "success",
		"mode": "playing",
		"scene": played_scene,
		"session_active": true,
		"probe_ready": probe_ready
	}

# ============================================================================
# stop_project - 停止运行
# ============================================================================

func _register_stop_project(server_core: RefCounted) -> void:
	var tool_name: String = "stop_project"
	var description: String = "Stop the currently running project and return to editor mode."
	
	# inputSchema
	var input_schema: Dictionary = {
		"type": "object",
		"properties": {
			"allow_window": {
				"type": "boolean",
				"description": "Allow this call to control the runtime window when Vibe Coding mode is enabled.",
				"default": false
			}
		}
	}
	# outputSchema
	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"status": {"type": "string"},
			"mode": {"type": "string"},
			"stopped_after_ms": {"type": "integer"}
		}
	}
	
	# annotations
	var annotations: Dictionary = {
		"readOnlyHint": false,
		"destructiveHint": false,
		"idempotentHint": true,
		"openWorldHint": false
	}
	
	# register tool
	server_core.register_tool(tool_name, description, input_schema,
						  Callable(self, "_tool_stop_project"),
						  output_schema, annotations,
						  "core", "Editor")

func _tool_stop_project(params: Dictionary) -> Dictionary:
	var policy_result: Dictionary = VIBE_CODING_POLICY.evaluate_runtime_window(_is_vibe_coding_mode(), params)
	if policy_result.get("blocked", false):
		return policy_result

	var editor_interface: EditorInterface = _get_editor_interface()
	if not editor_interface:
		return {"error": "Editor interface not available"}

	if not editor_interface.is_playing_scene():
		return {"error": "Project is not currently running."}

	editor_interface.stop_playing_scene()

	# Wait for the process to fully exit (up to 5s)
	var max_wait_ms: int = 5000
	var wait_interval_ms: int = 200
	var waited_ms: int = 0
	while editor_interface.is_playing_scene() and waited_ms < max_wait_ms:
		OS.delay_msec(wait_interval_ms)
		waited_ms += wait_interval_ms

	return {
		"status": "success",
		"mode": "editor",
		"stopped_after_ms": waited_ms
	}

# ============================================================================
# get_selected_nodes - 获取选中的节点
# ============================================================================

func _register_get_selected_nodes(server_core: RefCounted) -> void:
	var tool_name: String = "get_selected_nodes"
	var description: String = "Get the list of currently selected nodes in the editor."
	
	# inputSchema
	var input_schema: Dictionary = {
		"type": "object",
		"properties": {}
	}
	
	# outputSchema
	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"selected_nodes": {
				"type": "array",
				"items": {"type": "object"}
			},
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
						  Callable(self, "_tool_get_selected_nodes"),
						  output_schema, annotations,
						  "supplementary", "Editor-Advanced")

func _tool_get_selected_nodes(params: Dictionary) -> Dictionary:
	var editor_interface: EditorInterface = _get_editor_interface()
	if not editor_interface:
		return {"error": "Editor interface not available"}
	
	var selected_nodes: Array = []
	var selection: EditorSelection = editor_interface.get_selection()
	var scene_root: Node = _get_user_scene_root()
	
	if selection:
		var selected: Array[Node] = selection.get_selected_nodes()
		for node in selected:
			var node_info: Dictionary = {
				"path": _make_friendly_path(node, scene_root),
				"type": node.get_class()
			}
			var node_script: Variant = node.get_script()
			if node_script and node_script is Script:
				node_info["script_path"] = node_script.resource_path
			selected_nodes.append(node_info)
	
	if selected_nodes.is_empty():
		var edited_scene: Node = editor_interface.get_edited_scene_root()
		if edited_scene:
			selected_nodes.append({
				"path": _make_friendly_path(edited_scene, scene_root),
				"type": edited_scene.get_class()
			})
	
	return {
		"selected_nodes": selected_nodes,
		"count": selected_nodes.size()
	}

# ============================================================================
# select_node - 选择并在 Inspector 中编辑节点
# ============================================================================

func _register_select_node(server_core: RefCounted) -> void:
	var tool_name: String = "select_node"
	var description: String = "Select a node in the current edited scene and focus it in the Inspector."

	var input_schema: Dictionary = {
		"type": "object",
		"properties": {
			"node_path": {
				"type": "string",
				"description": "Node path such as '/root/MainScene/Player'."
			},
			"clear_existing": {
				"type": "boolean",
				"description": "Whether to clear the existing editor selection before selecting the node. Default is true.",
				"default": true
			},
			"allow_ui_focus": {
				"type": "boolean",
				"description": "Allow this call to change editor selection/focus when Vibe Coding mode is enabled.",
				"default": false
			}
		},
		"required": ["node_path"]
	}

	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"status": {"type": "string"},
			"node_path": {"type": "string"},
			"node_type": {"type": "string"},
			"selected_count": {"type": "integer"}
		}
	}

	var annotations: Dictionary = {
		"readOnlyHint": false,
		"destructiveHint": false,
		"idempotentHint": true,
		"openWorldHint": false
	}

	server_core.register_tool(tool_name, description, input_schema,
						  Callable(self, "_tool_select_node"),
						  output_schema, annotations,
						  "supplementary", "Editor-Advanced")

func _tool_select_node(params: Dictionary) -> Dictionary:
	var policy_result: Dictionary = VIBE_CODING_POLICY.evaluate_editor_focus(_is_vibe_coding_mode(), params)
	if policy_result.get("blocked", false):
		return policy_result

	var node_path: String = str(params.get("node_path", "")).strip_edges()
	if node_path.is_empty():
		return {"error": "Missing required parameter: node_path"}

	var clear_existing: bool = params.get("clear_existing", true)
	var editor_interface: EditorInterface = _get_editor_interface()
	if not editor_interface:
		return {"error": "Editor interface not available"}

	var target_node: Node = _resolve_node_path(editor_interface, node_path)
	if not target_node:
		return {"error": "Node not found: " + node_path}

	var selection: EditorSelection = editor_interface.get_selection()
	if selection:
		if clear_existing:
			selection.clear()
		selection.add_node(target_node)

	editor_interface.edit_node(target_node)

	var selected_count: int = 1
	if selection:
		selected_count = selection.get_selected_nodes().size()

	return {
		"status": "success",
		"node_path": _make_friendly_path(target_node, _get_user_scene_root()),
		"node_type": target_node.get_class(),
		"selected_count": selected_count
	}

# ============================================================================
# select_file - 在 FileSystem dock 中选择文件
# ============================================================================

func _register_select_file(server_core: RefCounted) -> void:
	var tool_name: String = "select_file"
	var description: String = "Select a project file in the Godot FileSystem dock."

	var input_schema: Dictionary = {
		"type": "object",
		"properties": {
			"file_path": {
				"type": "string",
				"description": "Project file path such as 'res://scenes/Main.tscn'."
			},
			"allow_ui_focus": {
				"type": "boolean",
				"description": "Allow this call to change the editor FileSystem selection when Vibe Coding mode is enabled.",
				"default": false
			}
		},
		"required": ["file_path"]
	}

	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"status": {"type": "string"},
			"file_path": {"type": "string"}
		}
	}

	var annotations: Dictionary = {
		"readOnlyHint": false,
		"destructiveHint": false,
		"idempotentHint": true,
		"openWorldHint": false
	}

	server_core.register_tool(tool_name, description, input_schema,
						  Callable(self, "_tool_select_file"),
						  output_schema, annotations,
						  "supplementary", "Editor-Advanced")

func _tool_select_file(params: Dictionary) -> Dictionary:
	var policy_result: Dictionary = VIBE_CODING_POLICY.evaluate_editor_focus(_is_vibe_coding_mode(), params)
	if policy_result.get("blocked", false):
		return policy_result

	var file_path: String = str(params.get("file_path", "")).strip_edges()
	if file_path.is_empty():
		return {"error": "Missing required parameter: file_path"}

	var validation: Dictionary = PathValidator.validate_path(file_path)
	if not validation["valid"]:
		return {"error": "Invalid path: " + validation["error"]}
	file_path = validation["sanitized"]

	if not FileAccess.file_exists(file_path):
		return {"error": "File not found: " + file_path}

	var editor_interface: EditorInterface = _get_editor_interface()
	if not editor_interface:
		return {"error": "Editor interface not available"}

	editor_interface.select_file(file_path)
	return {
		"status": "success",
		"file_path": file_path
	}

# ============================================================================
# get_inspector_properties - 获取 Inspector 风格的属性元数据
# ============================================================================

func _register_get_inspector_properties(server_core: RefCounted) -> void:
	var tool_name: String = "get_inspector_properties"
	var description: String = "Inspect a node or resource and return property metadata and serialized values similar to the Inspector."

	var input_schema: Dictionary = {
		"type": "object",
		"properties": {
			"node_path": {
				"type": "string",
				"description": "Optional node path to inspect."
			},
			"resource_path": {
				"type": "string",
				"description": "Optional resource path to inspect."
			},
			"property_filter": {
				"type": "string",
				"description": "Optional substring filter for property names."
			},
			"include_values": {
				"type": "boolean",
				"description": "Whether to include current property values. Default is true.",
				"default": true
			}
		}
	}

	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"target_kind": {"type": "string"},
			"target_path": {"type": "string"},
			"class_name": {"type": "string"},
			"property_count": {"type": "integer"},
			"properties": {"type": "array"}
		}
	}

	var annotations: Dictionary = {
		"readOnlyHint": true,
		"destructiveHint": false,
		"idempotentHint": true,
		"openWorldHint": false
	}

	server_core.register_tool(tool_name, description, input_schema,
						  Callable(self, "_tool_get_inspector_properties"),
						  output_schema, annotations,
						  "supplementary", "Editor-Advanced")

func _tool_get_inspector_properties(params: Dictionary) -> Dictionary:
	var node_path: String = str(params.get("node_path", "")).strip_edges()
	var resource_path: String = str(params.get("resource_path", "")).strip_edges()
	var property_filter: String = str(params.get("property_filter", "")).strip_edges().to_lower()
	var include_values: bool = params.get("include_values", true)

	if node_path.is_empty() and resource_path.is_empty():
		return {"error": "Provide node_path or resource_path"}

	var editor_interface: EditorInterface = _get_editor_interface()
	if not editor_interface:
		return {"error": "Editor interface not available"}

	var target_object: Object = null
	var target_kind: String = ""
	var target_path: String = ""

	if not node_path.is_empty():
		var target_node: Node = _resolve_node_path(editor_interface, node_path)
		if not target_node:
			return {"error": "Node not found: " + node_path}
		editor_interface.edit_node(target_node)
		editor_interface.inspect_object(target_node)
		target_object = target_node
		target_kind = "node"
		target_path = _make_friendly_path(target_node, _get_user_scene_root())
	else:
		var validation: Dictionary = PathValidator.validate_path(resource_path)
		if not validation["valid"]:
			return {"error": "Invalid path: " + validation["error"]}
		resource_path = validation["sanitized"]
		if not FileAccess.file_exists(resource_path):
			return {"error": "File not found: " + resource_path}
		var resource: Resource = load(resource_path)
		if not resource:
			return {"error": "Failed to load resource: " + resource_path}
		editor_interface.inspect_object(resource)
		target_object = resource
		target_kind = "resource"
		target_path = resource_path

	var properties: Array = []
	for property_info_variant in target_object.get_property_list():
		var property_info: Dictionary = property_info_variant
		var property_name: String = str(property_info.get("name", ""))
		if property_name.is_empty():
			continue
		if not property_filter.is_empty() and not property_name.to_lower().contains(property_filter):
			continue

		var serialized: Dictionary = {
			"name": property_name,
			"type": int(property_info.get("type", TYPE_NIL)),
			"usage": int(property_info.get("usage", 0)),
			"hint": int(property_info.get("hint", PROPERTY_HINT_NONE)),
			"hint_string": str(property_info.get("hint_string", "")),
			"class_name": str(property_info.get("class_name", ""))
		}
		if include_values:
			serialized["value"] = _serialize_editor_value(target_object.get(property_name))
		properties.append(serialized)

	return {
		"target_kind": target_kind,
		"target_path": target_path,
		"class_name": target_object.get_class(),
		"property_count": properties.size(),
		"properties": properties
	}

# ============================================================================
# list_export_presets - 列出导出预设
# ============================================================================

func _register_list_export_presets(server_core: RefCounted) -> void:
	var tool_name: String = "list_export_presets"
	var description: String = "List export presets from export_presets.cfg."

	var input_schema: Dictionary = {
		"type": "object",
		"properties": {}
	}

	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"config_path": {"type": "string"},
			"count": {"type": "integer"},
			"presets": {
				"type": "array",
				"items": {"type": "object"}
			}
		}
	}

	var annotations: Dictionary = {
		"readOnlyHint": true,
		"destructiveHint": false,
		"idempotentHint": true,
		"openWorldHint": false
	}

	server_core.register_tool(tool_name, description, input_schema,
						  Callable(self, "_tool_list_export_presets"),
						  output_schema, annotations,
						  "supplementary", "Editor-Advanced")

func _tool_list_export_presets(params: Dictionary) -> Dictionary:
	var preset_data: Dictionary = _load_export_presets()
	if preset_data.has("error"):
		return preset_data
	return {
		"config_path": preset_data["config_path"],
		"count": preset_data["presets"].size(),
		"presets": preset_data["presets"]
	}

# ============================================================================
# inspect_export_templates - 检查本机导出模板
# ============================================================================

func _register_inspect_export_templates(server_core: RefCounted) -> void:
	var tool_name: String = "inspect_export_templates"
	var description: String = "Inspect locally installed Godot export templates for the current editor version."

	var input_schema: Dictionary = {
		"type": "object",
		"properties": {}
	}

	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"templates_root": {"type": "string"},
			"current_version": {"type": "string"},
			"matching_version_installed": {"type": "boolean"},
			"installed_versions": {"type": "array"},
			"detected_files": {"type": "array"}
		}
	}

	var annotations: Dictionary = {
		"readOnlyHint": true,
		"destructiveHint": false,
		"idempotentHint": true,
		"openWorldHint": false
	}

	server_core.register_tool(tool_name, description, input_schema,
						  Callable(self, "_tool_inspect_export_templates"),
						  output_schema, annotations,
						  "supplementary", "Editor-Advanced")

func _tool_inspect_export_templates(params: Dictionary) -> Dictionary:
	return _inspect_export_templates()

# ============================================================================
# validate_export_preset - 校验导出预设
# ============================================================================

func _register_validate_export_preset(server_core: RefCounted) -> void:
	var tool_name: String = "validate_export_preset"
	var description: String = "Validate an export preset against export_presets.cfg and local template availability."

	var input_schema: Dictionary = {
		"type": "object",
		"properties": {
			"preset": {
				"type": "string",
				"description": "Preset name or section, e.g. 'Windows Desktop' or 'preset.0'."
			}
		},
		"required": ["preset"]
	}

	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"valid": {"type": "boolean"},
			"preset": {"type": "object"},
			"errors": {"type": "array"},
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
						  Callable(self, "_tool_validate_export_preset"),
						  output_schema, annotations,
						  "supplementary", "Editor-Advanced")

func _tool_validate_export_preset(params: Dictionary) -> Dictionary:
	var preset_name: String = str(params.get("preset", "")).strip_edges()
	if preset_name.is_empty():
		return {"error": "Missing required parameter: preset"}

	var preset_data: Dictionary = _load_export_presets()
	if preset_data.has("error"):
		return preset_data

	var preset: Dictionary = _find_export_preset(preset_data["presets"], preset_name)
	if preset.is_empty():
		return {
			"valid": false,
			"errors": ["Export preset not found: " + preset_name],
			"warnings": [],
			"preset": {}
		}

	var errors: Array[String] = []
	var warnings: Array[String] = []
	if str(preset.get("platform", "")).is_empty():
		errors.append("Preset is missing platform")
	if str(preset.get("name", "")).is_empty():
		errors.append("Preset is missing name")
	if str(preset.get("export_path", "")).is_empty():
		warnings.append("Preset does not define export_path; run_export must receive output_path")

	var template_info: Dictionary = _inspect_export_templates()
	if not bool(template_info.get("matching_version_installed", false)):
		warnings.append("Matching export templates are not installed for current Godot version")

	return {
		"valid": errors.is_empty(),
		"preset": preset,
		"errors": errors,
		"warnings": warnings,
		"template_info": template_info
	}

# ============================================================================
# run_export - 执行导出
# ============================================================================

func _register_run_export(server_core: RefCounted) -> void:
	var tool_name: String = "run_export"
	var description: String = "Run a Godot CLI export for a configured preset."

	var input_schema: Dictionary = {
		"type": "object",
		"properties": {
			"preset": {
				"type": "string",
				"description": "Preset name or section."
			},
			"output_path": {
				"type": "string",
				"description": "Optional absolute or res:// output path override."
			},
			"mode": {
				"type": "string",
				"enum": ["release", "debug", "pack", "patch"],
				"default": "release"
			}
		},
		"required": ["preset"]
	}

	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"success": {"type": "boolean"},
			"exit_code": {"type": "integer"},
			"command": {"type": "array"},
			"output_path": {"type": "string"},
			"logs": {"type": "array"},
			"errors": {"type": "array"}
		}
	}

	var annotations: Dictionary = {
		"readOnlyHint": false,
		"destructiveHint": false,
		"idempotentHint": false,
		"openWorldHint": false
	}

	server_core.register_tool(tool_name, description, input_schema,
						  Callable(self, "_tool_run_export"),
						  output_schema, annotations,
						  "supplementary", "Editor-Advanced")

func _tool_run_export(params: Dictionary) -> Dictionary:
	var preset_name: String = str(params.get("preset", "")).strip_edges()
	if preset_name.is_empty():
		return {"error": "Missing required parameter: preset"}

	var mode: String = str(params.get("mode", "release")).strip_edges().to_lower()
	var mode_to_flag: Dictionary = {
		"release": "--export-release",
		"debug": "--export-debug",
		"pack": "--export-pack",
		"patch": "--export-patch"
	}
	if not mode_to_flag.has(mode):
		return {"error": "Invalid mode: " + mode}

	var preset_data: Dictionary = _load_export_presets()
	if preset_data.has("error"):
		return preset_data

	var preset: Dictionary = _find_export_preset(preset_data["presets"], preset_name)
	if preset.is_empty():
		return {"error": "Export preset not found: " + preset_name}

	var output_path: String = str(params.get("output_path", "")).strip_edges()
	if output_path.is_empty():
		output_path = str(preset.get("export_path", "")).strip_edges()
	if output_path.is_empty():
		return {"error": "Export preset has no export_path and output_path was not provided"}

	if output_path.begins_with("res://"):
		output_path = ProjectSettings.globalize_path(output_path)

	var output_dir: String = output_path.get_base_dir()
	if not output_dir.is_empty():
		DirAccess.make_dir_recursive_absolute(output_dir)

	var executable_path: String = OS.get_executable_path()
	var project_path: String = ProjectSettings.globalize_path("res://")
	var args: Array[String] = [
		"--headless",
		"--path", project_path,
		str(mode_to_flag[mode]),
		str(preset.get("name", "")),
		output_path
	]

	var logs: Array = []
	var exit_code: int = OS.execute(executable_path, args, logs, true)
	var sanitized_logs: Array[String] = []
	for line in logs:
		sanitized_logs.append(_sanitize_cli_output(str(line)))
	var error_lines: Array[String] = []
	for text_line in sanitized_logs:
		if text_line.contains("ERROR:") or text_line.contains("Export failed") or text_line.contains("No export template"):
			error_lines.append(text_line)

	return {
		"success": exit_code == OK,
		"exit_code": exit_code,
		"command": [executable_path] + args,
		"output_path": output_path,
		"preset": preset,
		"logs": sanitized_logs,
		"errors": error_lines
	}

func _register_smoke_test_export(server_core: RefCounted) -> void:
	var tool_name: String = "smoke_test_export"
	var description: String = "Post-export smoke test: verify an exported product exists and (optionally) launches cleanly. Resolves the artifact from 'artifact_path' or the preset's export_path; when run_export=true it exports first via the same CLI as run_export. Asserts the artifact file exists and, when launch=true, runs it with 'launch_args' (default ['--quit-after','120']) capturing the exit code and comparing it to 'expected_exit_code' (default 0). Returns an objective pass/fail with reasons — the ship-loop gate that proves a build is actually runnable, not just produced."

	var input_schema: Dictionary = {
		"type": "object",
		"properties": {
			"preset": {"type": "string", "description": "Export preset name (used to resolve export_path and to export when run_export=true)."},
			"artifact_path": {"type": "string", "description": "Absolute or res:// path to the exported product. Overrides the preset export_path."},
			"run_export": {"type": "boolean", "description": "Export the preset before smoke-testing (requires 'preset'). Default false.", "default": false},
			"mode": {"type": "string", "enum": ["release", "debug", "pack", "patch"], "default": "release"},
			"launch": {"type": "boolean", "description": "Launch the exported product and capture its exit code. Default true.", "default": true},
			"launch_args": {"type": "array", "description": "CLI args passed to the launched product. Default ['--quit-after','120'] so the build self-exits.", "items": {"type": "string"}},
			"expected_exit_code": {"type": "integer", "description": "Exit code that counts as success. Default 0.", "default": 0}
		}
	}

	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"success": {"type": "boolean"},
			"artifact_path": {"type": "string"},
			"artifact_exists": {"type": "boolean"},
			"launched": {"type": "boolean"},
			"exit_code": {"type": "integer"},
			"expected_exit_code": {"type": "integer"},
			"reasons": {"type": "array"},
			"export": {"type": "object"},
			"logs": {"type": "array"}
		}
	}

	var annotations: Dictionary = {
		"readOnlyHint": false,
		"destructiveHint": false,
		"idempotentHint": false,
		"openWorldHint": false
	}

	server_core.register_tool(tool_name, description, input_schema,
											  Callable(self, "_tool_smoke_test_export"),
											  output_schema, annotations,
											  "supplementary", "Editor-Advanced")

# 纯函数：根据冒烟检查的事实给出客观通过/失败结论，便于单测覆盖。
static func _evaluate_smoke_result(artifact_exists: bool, launched: bool, exit_code: int, expected_exit_code: int) -> Dictionary:
	var reasons: Array[String] = []
	if not artifact_exists:
		reasons.append("Exported artifact not found")
	if launched and exit_code != expected_exit_code:
		reasons.append("Product exited with %d (expected %d)" % [exit_code, expected_exit_code])
	return {"success": reasons.is_empty(), "reasons": reasons}

func _tool_smoke_test_export(params: Dictionary) -> Dictionary:
	var preset_name: String = str(params.get("preset", "")).strip_edges()
	var artifact_path: String = str(params.get("artifact_path", "")).strip_edges()
	var do_export: bool = bool(params.get("run_export", false))
	var do_launch: bool = bool(params.get("launch", true))
	var expected_exit_code: int = int(params.get("expected_exit_code", 0))

	var export_result: Dictionary = {}
	if do_export:
		if preset_name.is_empty():
			return {"error": "run_export=true requires a 'preset'"}
		export_result = _tool_run_export({"preset": preset_name, "mode": params.get("mode", "release"), "output_path": artifact_path})
		if export_result.has("error"):
			return {"error": "Export step failed: " + str(export_result["error"]), "export": export_result}
		if not bool(export_result.get("success", false)):
			return {
				"success": false,
				"artifact_path": str(export_result.get("output_path", "")),
				"artifact_exists": false,
				"launched": false,
				"exit_code": int(export_result.get("exit_code", -1)),
				"expected_exit_code": expected_exit_code,
				"reasons": ["Export step returned a non-zero exit code"],
				"export": export_result,
				"logs": export_result.get("logs", [])
			}
		if artifact_path.is_empty():
			artifact_path = str(export_result.get("output_path", ""))

	# 未导出时，从 preset 解析产物路径。
	if artifact_path.is_empty() and not preset_name.is_empty():
		var preset_data: Dictionary = _load_export_presets()
		if preset_data.has("error"):
			return preset_data
		var preset: Dictionary = _find_export_preset(preset_data["presets"], preset_name)
		if preset.is_empty():
			return {"error": "Export preset not found: " + preset_name}
		artifact_path = str(preset.get("export_path", "")).strip_edges()

	if artifact_path.is_empty():
		return {"error": "No artifact_path provided and could not resolve one from a preset"}
	if artifact_path.begins_with("res://"):
		artifact_path = ProjectSettings.globalize_path(artifact_path)

	var artifact_exists: bool = FileAccess.file_exists(artifact_path)
	var launched: bool = false
	var exit_code: int = -1
	var logs: Array[String] = []

	if do_launch and artifact_exists:
		var launch_args: Array[String] = []
		var raw_args: Variant = params.get("launch_args", ["--quit-after", "120"])
		if raw_args is Array:
			for a in (raw_args as Array):
				launch_args.append(str(a))
		var raw_logs: Array = []
		exit_code = OS.execute(artifact_path, launch_args, raw_logs, true)
		launched = true
		for line in raw_logs:
			logs.append(_sanitize_cli_output(str(line)))

	var verdict: Dictionary = _evaluate_smoke_result(artifact_exists, launched, exit_code, expected_exit_code)
	var result: Dictionary = {
		"success": verdict["success"],
		"artifact_path": artifact_path,
		"artifact_exists": artifact_exists,
		"launched": launched,
		"exit_code": exit_code,
		"expected_exit_code": expected_exit_code,
		"reasons": verdict["reasons"],
		"logs": logs
	}
	if not export_result.is_empty():
		result["export"] = export_result
	return result

func _load_export_presets() -> Dictionary:
	var config_path: String = "res://export_presets.cfg"
	if not FileAccess.file_exists(config_path):
		return {
			"config_path": config_path,
			"presets": []
		}

	var config: ConfigFile = ConfigFile.new()
	var load_error: Error = config.load(config_path)
	if load_error != OK:
		return {"error": "Failed to load export_presets.cfg: " + error_string(load_error)}

	var presets: Array = []
	for raw_section in config.get_sections():
		var section_name: String = str(raw_section)
		if not section_name.begins_with("preset.") or section_name.ends_with(".options"):
			continue

		var preset: Dictionary = {
			"section": section_name,
			"name": str(config.get_value(section_name, "name", "")),
			"platform": str(config.get_value(section_name, "platform", "")),
			"export_path": str(config.get_value(section_name, "export_path", "")),
			"runnable": bool(config.get_value(section_name, "runnable", false))
		}
		presets.append(preset)

	return {
		"config_path": config_path,
		"presets": presets
	}

func _inspect_export_templates() -> Dictionary:
	var version_info: Dictionary = Engine.get_version_info()
	var version_variants: Array[String] = []
	var base_version: String = "%d.%d.%d.%s" % [
		int(version_info.get("major", 0)),
		int(version_info.get("minor", 0)),
		int(version_info.get("patch", 0)),
		str(version_info.get("status", "stable"))
	]
	version_variants.append(base_version)
	version_variants.append(base_version + ".mono")

	var templates_root: String = _get_export_templates_root()
	var installed_versions: Array[String] = []
	var detected_files: Array[String] = []
	var matching_version_installed: bool = false

	var root_dir: DirAccess = DirAccess.open(templates_root)
	if root_dir:
		root_dir.list_dir_begin()
		var entry: String = root_dir.get_next()
		while entry != "":
			if root_dir.current_is_dir() and not entry.begins_with("."):
				installed_versions.append(entry)
				if version_variants.has(entry):
					matching_version_installed = true
					var version_dir_path: String = templates_root.path_join(entry)
					var version_dir: DirAccess = DirAccess.open(version_dir_path)
					if version_dir:
						version_dir.list_dir_begin()
						var file_name: String = version_dir.get_next()
						while file_name != "":
							if not version_dir.current_is_dir():
								detected_files.append(version_dir_path.path_join(file_name))
							file_name = version_dir.get_next()
						version_dir.list_dir_end()
			entry = root_dir.get_next()
		root_dir.list_dir_end()

	installed_versions.sort()
	detected_files.sort()

	return {
		"templates_root": templates_root,
		"current_version": base_version,
		"matching_version_installed": matching_version_installed,
		"expected_versions": version_variants,
		"installed_versions": installed_versions,
		"detected_files": detected_files
	}

func _find_export_preset(presets: Array, preset_name: String) -> Dictionary:
	for preset_value in presets:
		var preset: Dictionary = preset_value
		if str(preset.get("section", "")) == preset_name:
			return preset
		if str(preset.get("name", "")) == preset_name:
			return preset
	return {}

func _sanitize_cli_output(text: String) -> String:
	var sanitized: String = ""
	for i in range(text.length()):
		var codepoint: int = text.unicode_at(i)
		var keep_char: bool = codepoint >= 32 and codepoint != 127
		if codepoint == 9 or codepoint == 10 or codepoint == 13:
			keep_char = true
		if codepoint >= 0xE000 and codepoint <= 0xF8FF:
			keep_char = false
		if keep_char:
			sanitized += String.chr(codepoint)
	return sanitized

# ============================================================================
# set_editor_setting - 设置编辑器属性
# ============================================================================

func _register_set_editor_setting(server_core: RefCounted) -> void:
	var tool_name: String = "set_editor_setting"
	var description: String = "Set an editor setting value. Requires editor restart for some settings to take effect."
	
	# inputSchema
	var input_schema: Dictionary = {
		"type": "object",
		"properties": {
			"setting_name": {
				"type": "string",
				"description": "Name of the setting (e.g. 'interface/theme/accent_color')"
			},
			"setting_value": {
				"description": "New value for the setting"
			}
		},
		"required": ["setting_name", "setting_value"]
	}
	
	# outputSchema
	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"status": {"type": "string"},
			"setting_name": {"type": "string"},
			"old_value": {"type": "string"},
			"new_value": {"type": "string"}
		}
	}
	
	# annotations
	var annotations: Dictionary = {
		"readOnlyHint": false,
		"destructiveHint": false,
		"idempotentHint": true,
		"openWorldHint": false
	}
	
	# 注册工具
	server_core.register_tool(tool_name, description, input_schema,
						  Callable(self, "_tool_set_editor_setting"),
						  output_schema, annotations,
						  "supplementary", "Editor-Advanced")

func _tool_set_editor_setting(params: Dictionary) -> Dictionary:
	var setting_name: String = params.get("setting_name", "")
	var setting_value: Variant = params.get("setting_value", null)
	
	if setting_name.is_empty():
		return {"error": "Missing required parameter: setting_name"}
	if setting_value == null:
		return {"error": "Missing required parameter: setting_value"}
	
	var editor_interface: EditorInterface = _get_editor_interface()
	if not editor_interface:
		return {"error": "Editor interface not available"}
	
	var editor_settings: EditorSettings = editor_interface.get_editor_settings()
	if not editor_settings:
		return {"error": "Failed to get EditorSettings"}
	
	var old_value: Variant = null
	if editor_settings.has_setting(setting_name):
		old_value = editor_settings.get_setting(setting_name)
	editor_settings.set_setting(setting_name, setting_value)
	if editor_settings.has_method("save"):
		editor_settings.save()
	
	return {
		"status": "success",
		"setting_name": setting_name,
		"old_value": str(old_value) if old_value != null else "null",
		"new_value": str(setting_value)
	}

# ============================================================================
# get_editor_screenshot - 截取编辑器视口
# ============================================================================

func _register_get_editor_screenshot(server_core: RefCounted) -> void:
	var tool_name: String = "get_editor_screenshot"
	var description: String = "Capture a screenshot of the editor viewport and save it to a file."

	var input_schema: Dictionary = {
		"type": "object",
		"properties": {
			"viewport_type": {
				"type": "string",
				"description": "Viewport type: '3d' or '2d'. Default is '3d'.",
				"enum": ["3d", "2d"]
			},
			"viewport_index": {
				"type": "integer",
				"description": "3D viewport index (0-3). Default is 0."
			},
			"save_path": {
				"type": "string",
				"description": "Path to save the screenshot (e.g. 'res://screenshots/editor.png')."
			},
			"format": {
				"type": "string",
				"description": "Image format: 'png' or 'jpg'. Default is 'jpg'.",
				"enum": ["png", "jpg"]
			}
		}
	}

	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"status": {"type": "string"},
			"save_path": {"type": "string"},
			"size": {"type": "string"}
		}
	}

	var annotations: Dictionary = {
		"readOnlyHint": true,
		"destructiveHint": false,
		"idempotentHint": false,
		"openWorldHint": false
	}

	server_core.register_tool(tool_name, description, input_schema,
		Callable(self, "_tool_get_editor_screenshot"),
		output_schema, annotations,
		"supplementary", "Editor-Advanced")

func _tool_get_editor_screenshot(params: Dictionary) -> Dictionary:
	var viewport_type: String = params.get("viewport_type", "3d")
	var viewport_index: int = params.get("viewport_index", 0)
	var save_path: String = params.get("save_path", "res://screenshot_editor.png")
	var format: String = params.get("format", "jpg")

	var editor_interface: EditorInterface = _get_editor_interface()
	if not editor_interface:
		return {"error": "Editor interface not available"}

	var path_validation: Dictionary = PathValidator.validate_path(save_path)
	if not path_validation["valid"]:
		return {"error": "Invalid save path: " + path_validation["error"]}
	save_path = path_validation["sanitized"]

	# Switch the main screen editor to the target viewport type so the
	# SubViewport is visible and actively rendering. Without this, the
	# viewport may show stale content when the editor is in the background.
	editor_interface.set_main_screen_editor(viewport_type.to_upper())

	var viewport: SubViewport = null
	if viewport_type == "3d":
		viewport = editor_interface.get_editor_viewport_3d(viewport_index)
	else:
		viewport = editor_interface.get_editor_viewport_2d()

	if not viewport:
		return {"error": "Failed to get editor viewport"}

	# Temporarily force the viewport to always update so it renders even
	# when the editor window is in the background or minimized.
	var original_update_mode: int = viewport.render_target_update_mode
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	# Wait one frame for the SubViewport to render, then force a flush.
	var tree: SceneTree = Engine.get_main_loop() as SceneTree
	if tree:
		await tree.process_frame
	RenderingServer.force_draw()

	var texture: ViewportTexture = viewport.get_texture()
	# Restore the original update mode after capturing.
	viewport.render_target_update_mode = original_update_mode
	if not texture:
		return {"error": "Failed to get viewport texture"}

	var image: Image = texture.get_image()
	if not image:
		return {"error": "Failed to capture viewport image"}

	var save_dir: String = save_path.get_base_dir()
	if not save_dir.is_empty() and not DirAccess.dir_exists_absolute(save_dir):
		DirAccess.make_dir_recursive_absolute(save_dir)

	var err: Error = OK
	if format == "jpg":
		err = image.save_jpg(save_path, 0.9)
	else:
		err = image.save_png(save_path)

	if err != OK:
		return {"error": "Failed to save screenshot: error " + str(err)}

	return {
		"status": "success",
		"save_path": save_path,
		"size": str(image.get_width()) + "x" + str(image.get_height())
	}

# ============================================================================
# get_signals - 获取节点的所有信号及连接
# ============================================================================

func _register_get_signals(server_core: RefCounted) -> void:
	var tool_name: String = "get_signals"
	var description: String = "Get all signals and their connections for a node."

	var input_schema: Dictionary = {
		"type": "object",
		"properties": {
			"node_path": {
				"type": "string",
				"description": "Path to the node (e.g. '/root/MainScene/Player')"
			},
			"include_connections": {
				"type": "boolean",
				"description": "Whether to include connection details. Default is true."
			}
		},
		"required": ["node_path"]
	}

	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"node_path": {"type": "string"},
			"signals": {"type": "array"},
			"signal_count": {"type": "integer"},
			"connection_count": {"type": "integer"}
		}
	}

	var annotations: Dictionary = {
		"readOnlyHint": true,
		"destructiveHint": false,
		"idempotentHint": true,
		"openWorldHint": false
	}

	server_core.register_tool(tool_name, description, input_schema,
		Callable(self, "_tool_get_signals"),
		output_schema, annotations,
		"supplementary", "Editor-Advanced")

func _tool_get_signals(params: Dictionary) -> Dictionary:
	var node_path: String = params.get("node_path", "")
	var include_connections: bool = params.get("include_connections", true)

	if node_path.is_empty():
		return {"error": "Missing required parameter: node_path"}

	var editor_interface: EditorInterface = _get_editor_interface()
	if not editor_interface:
		return {"error": "Editor interface not available"}

	var target_node: Node = _resolve_node_path(editor_interface, node_path)
	if not target_node:
		return {"error": "Node not found: " + node_path}

	var signal_list: Array = target_node.get_signal_list()
	var signals: Array = []
	var total_connections: int = 0

	for sig in signal_list:
		var signal_info: Dictionary = {
			"name": sig.get("name", ""),
			"arguments": sig.get("args", []).size()
		}

		if include_connections:
			var connections: Array = target_node.get_signal_connection_list(sig.get("name", ""))
			var connection_list: Array = []
			for conn in connections:
				connection_list.append({
					"callable": str(conn.get("callable", "")),
					"flags": conn.get("flags", 0)
				})
				total_connections += 1
			signal_info["connections"] = connection_list
			signal_info["connection_count"] = connection_list.size()

		signals.append(signal_info)

	return {
		"node_path": node_path,
		"signals": signals,
		"signal_count": signals.size(),
		"connection_count": total_connections
	}

func _resolve_node_path(editor_interface: EditorInterface, path: String) -> Node:
	var edited_scene: Node = editor_interface.get_edited_scene_root()
	if not edited_scene:
		return null
	if path == str(edited_scene.get_path()) or path == "/root/" + edited_scene.name:
		return edited_scene
	if path.begins_with("/root/" + edited_scene.name + "/"):
		var relative: String = path.substr(("/root/" + edited_scene.name + "/").length())
		return edited_scene.get_node_or_null(relative)
	return edited_scene.get_node_or_null(path)

func _serialize_editor_value(value: Variant) -> Variant:
	if value == null:
		return null
	match typeof(value):
		TYPE_BOOL, TYPE_INT, TYPE_FLOAT, TYPE_STRING:
			return value
		TYPE_VECTOR2:
			return {"x": value.x, "y": value.y}
		TYPE_VECTOR3:
			return {"x": value.x, "y": value.y, "z": value.z}
		TYPE_VECTOR4:
			return {"x": value.x, "y": value.y, "z": value.z, "w": value.w}
		TYPE_COLOR:
			return {"r": value.r, "g": value.g, "b": value.b, "a": value.a}
		TYPE_ARRAY:
			var array_result: Array = []
			for item in value:
				array_result.append(_serialize_editor_value(item))
			return array_result
		TYPE_DICTIONARY:
			var dict_result: Dictionary = {}
			for key in value:
				dict_result[str(key)] = _serialize_editor_value(value[key])
			return dict_result
		_:
			return str(value)

# ============================================================================
# reload_project - 重新扫描文件系统并重新加载脚本
# ============================================================================

func _register_reload_project(server_core: RefCounted) -> void:
	var tool_name: String = "reload_project"
	var description: String = "Rescan the project filesystem and reload scripts. Useful after external file changes."

	var input_schema: Dictionary = {
		"type": "object",
		"properties": {
			"full_scan": {
				"type": "boolean",
				"description": "Whether to perform a full scan (true) or source-only scan (false). Default is false."
			}
		}
	}

	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"status": {"type": "string"},
			"scan_type": {"type": "string"}
		}
	}

	var annotations: Dictionary = {
		"readOnlyHint": false,
		"destructiveHint": false,
		"idempotentHint": false,
		"openWorldHint": false
	}

	server_core.register_tool(tool_name, description, input_schema,
		Callable(self, "_tool_reload_project"),
		output_schema, annotations,
		"supplementary", "Editor-Advanced")

func _tool_reload_project(params: Dictionary) -> Dictionary:
	var full_scan: bool = params.get("full_scan", false)

	var editor_interface: EditorInterface = _get_editor_interface()
	if not editor_interface:
		return {"error": "Editor interface not available"}

	var fs: EditorFileSystem = editor_interface.get_resource_filesystem()
	if not fs:
		return {"error": "Failed to get EditorFileSystem"}

	if fs.is_scanning():
		return {
			"status": "already_scanning",
			"progress": fs.get_scanning_progress(),
			"message": "Filesystem scan is already in progress"
		}

	if full_scan:
		fs.scan()
		return {"status": "success", "scan_type": "full"}
	else:
		fs.scan_sources()
		return {"status": "success", "scan_type": "sources_only"}

# ============================================================================
# Editor buffer sync (Godot 4.7 APIs with graceful 4.6 degradation)
# ============================================================================

func _first_supported_method(obj: Object, candidates: Array) -> String:
	if obj == null:
		return ""
	for candidate in candidates:
		if obj.has_method(candidate):
			return candidate
	return ""

func _engine_version_string() -> String:
	return str(Engine.get_version_info().get("string", ""))

# ============================================================================
# get_unsaved_changes - List unsaved scenes and scripts in the editor
# ============================================================================

func _register_get_unsaved_changes(server_core: RefCounted) -> void:
	var tool_name: String = "get_unsaved_changes"
	var description: String = "List scenes and scripts that have unsaved edits in the editor buffers, so a caller can avoid overwriting in-editor work before writing files. Uses Godot 4.7 APIs (EditorInterface.get_unsaved_scenes / ScriptEditor.get_unsaved_files); on older versions the corresponding *_supported flag is false."

	var input_schema: Dictionary = {
		"type": "object",
		"properties": {}
	}

	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"status": {"type": "string"},
			"unsaved_scenes": {"type": "array", "items": {"type": "string"}},
			"unsaved_scripts": {"type": "array", "items": {"type": "string"}},
			"unsaved_scene_count": {"type": "integer"},
			"unsaved_script_count": {"type": "integer"},
			"has_unsaved_changes": {"type": "boolean"},
			"scenes_supported": {"type": "boolean"},
			"scripts_supported": {"type": "boolean"}
		}
	}

	var annotations: Dictionary = {
		"readOnlyHint": true,
		"destructiveHint": false,
		"idempotentHint": true,
		"openWorldHint": false
	}

	server_core.register_tool(tool_name, description, input_schema,
		Callable(self, "_tool_get_unsaved_changes"),
		output_schema, annotations,
		"supplementary", "Editor-Advanced")

func _tool_get_unsaved_changes(_params: Dictionary) -> Dictionary:
	var editor_interface: EditorInterface = _get_editor_interface()
	if not editor_interface:
		return {"error": "Editor interface not available"}

	var unsaved_scenes: Array = []
	var unsaved_scripts: Array = []
	var scenes_supported: bool = false
	var scripts_supported: bool = false

	var scenes_method: String = _first_supported_method(editor_interface, ["get_unsaved_scenes"])
	if scenes_method != "":
		scenes_supported = true
		for scene_path in editor_interface.call(scenes_method):
			unsaved_scenes.append(str(scene_path))

	var script_editor: ScriptEditor = editor_interface.get_script_editor()
	if script_editor:
		var scripts_method: String = _first_supported_method(script_editor, ["get_unsaved_files", "get_unsaved_scripts"])
		if scripts_method != "":
			scripts_supported = true
			for script_path in script_editor.call(scripts_method):
				unsaved_scripts.append(str(script_path))

	return {
		"status": "success",
		"unsaved_scenes": unsaved_scenes,
		"unsaved_scripts": unsaved_scripts,
		"unsaved_scene_count": unsaved_scenes.size(),
		"unsaved_script_count": unsaved_scripts.size(),
		"has_unsaved_changes": unsaved_scenes.size() > 0 or unsaved_scripts.size() > 0,
		"scenes_supported": scenes_supported,
		"scripts_supported": scripts_supported
	}

# ============================================================================
# save_all_scripts - Save all open script buffers
# ============================================================================

func _register_save_all_scripts(server_core: RefCounted) -> void:
	var tool_name: String = "save_all_scripts"
	var description: String = "Save every script currently open in the editor's script editor (Godot 4.7 ScriptEditor.save_all_scripts). Returns status 'unsupported' on Godot versions that do not expose the API."

	var input_schema: Dictionary = {
		"type": "object",
		"properties": {}
	}

	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"status": {"type": "string"},
			"message": {"type": "string"},
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
		Callable(self, "_tool_save_all_scripts"),
		output_schema, annotations,
		"supplementary", "Editor-Advanced")

func _tool_save_all_scripts(_params: Dictionary) -> Dictionary:
	var editor_interface: EditorInterface = _get_editor_interface()
	if not editor_interface:
		return {"error": "Editor interface not available"}

	var script_editor: ScriptEditor = editor_interface.get_script_editor()
	if not script_editor:
		return {"error": "Script editor not available"}

	var method_name: String = _first_supported_method(script_editor, ["save_all_scripts"])
	if method_name == "":
		return {
			"status": "unsupported",
			"message": "ScriptEditor.save_all_scripts() requires Godot 4.7 or newer.",
			"godot_version": _engine_version_string()
		}

	script_editor.call(method_name)
	return {"status": "success", "message": "Saved all open scripts."}

# ============================================================================
# reload_open_scripts - Reload open script buffers from disk
# ============================================================================

func _register_reload_open_scripts(server_core: RefCounted) -> void:
	var tool_name: String = "reload_open_scripts"
	var description: String = "Reload the editor's open script buffers from disk (Godot 4.7 ScriptEditor.reload_scripts). Call this after the MCP server rewrites a .gd/.cs file so the editor does not later overwrite those changes with a stale buffer. Returns status 'unsupported' on older Godot versions."

	var input_schema: Dictionary = {
		"type": "object",
		"properties": {}
	}

	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"status": {"type": "string"},
			"message": {"type": "string"},
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
		Callable(self, "_tool_reload_open_scripts"),
		output_schema, annotations,
		"supplementary", "Editor-Advanced")

func _tool_reload_open_scripts(_params: Dictionary) -> Dictionary:
	var editor_interface: EditorInterface = _get_editor_interface()
	if not editor_interface:
		return {"error": "Editor interface not available"}

	var script_editor: ScriptEditor = editor_interface.get_script_editor()
	if not script_editor:
		return {"error": "Script editor not available"}

	var method_name: String = _first_supported_method(script_editor, ["reload_scripts", "reload_open_files"])
	if method_name == "":
		return {
			"status": "unsupported",
			"message": "ScriptEditor script-reload API requires Godot 4.7 or newer.",
			"godot_version": _engine_version_string()
		}

	script_editor.call(method_name)
	return {"status": "success", "message": "Reloaded open scripts from disk."}

# ============================================================================
# close_script_tab - Close a script tab in the script editor
# ============================================================================

func _register_close_script_tab(server_core: RefCounted) -> void:
	var tool_name: String = "close_script_tab"
	var description: String = "Close a script tab in the editor's script editor (Godot 4.7 ScriptEditor.close_file). With no script_path it closes the currently focused script; with script_path it focuses that script first, then closes it. Returns status 'unsupported' on older Godot versions."

	var input_schema: Dictionary = {
		"type": "object",
		"properties": {
			"script_path": {
				"type": "string",
				"description": "Optional path to the script to close (e.g. 'res://scripts/player.gd'). Defaults to the currently focused script."
			}
		}
	}

	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"status": {"type": "string"},
			"closed_script": {"type": "string"},
			"message": {"type": "string"},
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
		Callable(self, "_tool_close_script_tab"),
		output_schema, annotations,
		"supplementary", "Editor-Advanced")

func _tool_close_script_tab(params: Dictionary) -> Dictionary:
	var editor_interface: EditorInterface = _get_editor_interface()
	if not editor_interface:
		return {"error": "Editor interface not available"}

	var script_editor: ScriptEditor = editor_interface.get_script_editor()
	if not script_editor:
		return {"error": "Script editor not available"}

	var script_path: String = str(params.get("script_path", "")).strip_edges()
	var script_resource: Script = null
	if not script_path.is_empty():
		var validation: Dictionary = PathValidator.validate_file_path(script_path, [".gd", ".cs"])
		if not validation["valid"]:
			return {"error": "Invalid path: " + validation["error"]}
		script_path = validation["sanitized"]
		if not FileAccess.file_exists(script_path):
			return {"error": "Script file not found: " + script_path}
		script_resource = load(script_path)
		if not script_resource:
			return {"error": "Failed to load script: " + script_path}

	var method_name: String = _first_supported_method(script_editor, ["close_file"])
	if method_name == "":
		return {
			"status": "unsupported",
			"message": "ScriptEditor.close_file() requires Godot 4.7 or newer.",
			"godot_version": _engine_version_string()
		}

	var closed_script: String = script_path
	if script_resource:
		editor_interface.edit_script(script_resource, 0, 0, false)
	else:
		var current_script: Script = script_editor.get_current_script()
		if current_script:
			closed_script = current_script.resource_path

	script_editor.call(method_name)
	return {"status": "success", "closed_script": closed_script}

# ============================================================================
# get_import_status - Query resource import/scan status
# ============================================================================

func _register_get_import_status(server_core: RefCounted) -> void:
	var tool_name: String = "get_import_status"
	var description: String = "Report whether the EditorFileSystem is currently scanning or importing assets, so a caller can wait for a stable state before running the project or tests. The 'importing' field uses Godot 4.7 EditorFileSystem.is_importing; on older versions importing_supported is false and importing is null."

	var input_schema: Dictionary = {
		"type": "object",
		"properties": {}
	}

	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"status": {"type": "string"},
			"scanning": {"type": "boolean"},
			"scanning_progress": {"type": "number"},
			"importing": {"type": ["boolean", "null"]},
			"importing_supported": {"type": "boolean"},
			"busy": {"type": "boolean"}
		}
	}

	var annotations: Dictionary = {
		"readOnlyHint": true,
		"destructiveHint": false,
		"idempotentHint": true,
		"openWorldHint": false
	}

	server_core.register_tool(tool_name, description, input_schema,
		Callable(self, "_tool_get_import_status"),
		output_schema, annotations,
		"supplementary", "Editor-Advanced")

func _tool_get_import_status(_params: Dictionary) -> Dictionary:
	var editor_interface: EditorInterface = _get_editor_interface()
	if not editor_interface:
		return {"error": "Editor interface not available"}

	var fs: EditorFileSystem = editor_interface.get_resource_filesystem()
	if not fs:
		return {"error": "Failed to get EditorFileSystem"}

	var scanning: bool = fs.is_scanning()
	var importing_supported: bool = false
	var importing: Variant = null
	var importing_method: String = _first_supported_method(fs, ["is_importing"])
	if importing_method != "":
		importing_supported = true
		importing = bool(fs.call(importing_method))

	return {
		"status": "success",
		"scanning": scanning,
		"scanning_progress": fs.get_scanning_progress(),
		"importing": importing,
		"importing_supported": importing_supported,
		"busy": scanning or importing == true
	}

# ============================================================================
# manage_export_templates - status / install .tpz / remove installed version
# ============================================================================

const _ANDROID_ARCHITECTURES: PackedStringArray = ["arm64-v8a", "armeabi-v7a", "x86", "x86_64"]

func _register_manage_export_templates(server_core: RefCounted) -> void:
	var tool_name: String = "manage_export_templates"
	var description: String = "Manage locally installed Godot export templates. action='status' reports the templates directory, the current editor version, which versions are installed, and the official download URL + .tpz filename for the current version; action='install' extracts an export-templates .tpz/.zip into the templates directory; action='remove' deletes an installed version directory. Works on Godot 4.6+."

	var input_schema: Dictionary = {
		"type": "object",
		"properties": {
			"action": {
				"type": "string",
				"enum": ["status", "install", "remove"],
				"description": "Operation to perform. Default 'status'.",
				"default": "status"
			},
			"tpz_path": {
				"type": "string",
				"description": "For action='install': absolute or res:// path to an export-templates .tpz (or .zip) archive."
			},
			"version": {
				"type": "string",
				"description": "For action='remove': the installed version directory name to delete (e.g. '4.7.0.stable')."
			},
			"templates_root": {
				"type": "string",
				"description": "Optional override for the export templates directory. Defaults to the editor's templates directory for the current platform."
			}
		},
		"required": []
	}

	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"action": {"type": "string"},
			"templates_root": {"type": "string"},
			"current_version": {"type": "string"},
			"version_tag": {"type": "string"},
			"download_url": {"type": "string"},
			"tpz_filename": {"type": "string"},
			"matching_version_installed": {"type": "boolean"},
			"installed_versions": {"type": "array"},
			"installed_version": {"type": "string"},
			"dest_dir": {"type": "string"},
			"extracted_count": {"type": "integer"},
			"removed_count": {"type": "integer"},
			"files": {"type": "array"},
			"godot_version": {"type": "string"}
		}
	}

	var annotations: Dictionary = {
		"readOnlyHint": false,
		"destructiveHint": true,
		"idempotentHint": false,
		"openWorldHint": false
	}

	server_core.register_tool(tool_name, description, input_schema,
						  Callable(self, "_tool_manage_export_templates"),
						  output_schema, annotations,
						  "supplementary", "Editor-Advanced")

func _version_tag_and_tpz() -> Dictionary:
	var info: Dictionary = Engine.get_version_info()
	var major: int = int(info.get("major", 0))
	var minor: int = int(info.get("minor", 0))
	var patch: int = int(info.get("patch", 0))
	var status: String = str(info.get("status", "stable"))
	var short_version: String = "%d.%d" % [major, minor]
	if patch > 0:
		short_version += ".%d" % patch
	var tag: String = "%s-%s" % [short_version, status]
	var tpz_filename: String = "Godot_v%s_export_templates.tpz" % tag
	var download_url: String = "https://github.com/godotengine/godot/releases/download/%s/%s" % [tag, tpz_filename]
	return {
		"version_tag": tag,
		"tpz_filename": tpz_filename,
		"download_url": download_url
	}

func _scan_template_versions(templates_root: String) -> Array:
	var versions: Array[String] = []
	if templates_root.is_empty():
		return versions
	var root_dir: DirAccess = DirAccess.open(templates_root)
	if root_dir == null:
		return versions
	root_dir.list_dir_begin()
	var entry: String = root_dir.get_next()
	while entry != "":
		if root_dir.current_is_dir() and not entry.begins_with("."):
			versions.append(entry)
		entry = root_dir.get_next()
	root_dir.list_dir_end()
	versions.sort()
	return versions

func _tool_manage_export_templates(params: Dictionary) -> Dictionary:
	var action: String = str(params.get("action", "status")).strip_edges().to_lower()
	if action.is_empty():
		action = "status"
	if not (action in ["status", "install", "remove"]):
		return {"error": "Invalid action '%s'. Expected one of: status, install, remove." % action}

	var templates_root: String = str(params.get("templates_root", "")).strip_edges()
	if templates_root.is_empty():
		templates_root = _get_export_templates_root()
	elif templates_root.begins_with("res://") or templates_root.begins_with("user://"):
		templates_root = ProjectSettings.globalize_path(templates_root)
	if templates_root.is_empty():
		return {"error": "Could not determine export templates directory; provide templates_root."}

	var version_meta: Dictionary = _version_tag_and_tpz()
	var godot_version: String = str(Engine.get_version_info().get("string", ""))

	if action == "status":
		var info: Dictionary = Engine.get_version_info()
		var base_version: String = "%d.%d.%d.%s" % [
			int(info.get("major", 0)),
			int(info.get("minor", 0)),
			int(info.get("patch", 0)),
			str(info.get("status", "stable"))
		]
		var installed: Array = _scan_template_versions(templates_root)
		return {
			"action": "status",
			"templates_root": templates_root,
			"current_version": base_version,
			"version_tag": version_meta["version_tag"],
			"download_url": version_meta["download_url"],
			"tpz_filename": version_meta["tpz_filename"],
			"matching_version_installed": installed.has(base_version) or installed.has(base_version + ".mono"),
			"installed_versions": installed,
			"godot_version": godot_version
		}

	if action == "install":
		var tpz_path: String = str(params.get("tpz_path", "")).strip_edges()
		if tpz_path.is_empty():
			return {"error": "action='install' requires tpz_path"}
		if tpz_path.begins_with("res://") or tpz_path.begins_with("user://"):
			tpz_path = ProjectSettings.globalize_path(tpz_path)
		if not FileAccess.file_exists(tpz_path):
			return {"error": "Template archive not found: " + tpz_path}

		var reader: ZIPReader = ZIPReader.new()
		var open_error: Error = reader.open(tpz_path)
		if open_error != OK:
			return {"error": "Failed to open archive: " + error_string(open_error)}

		var archive_files: PackedStringArray = reader.get_files()
		# Determine the installed version: prefer templates/version.txt inside the archive.
		var installed_version: String = version_meta["version_tag"]
		for f in archive_files:
			if f.get_file() == "version.txt":
				var raw: PackedByteArray = reader.read_file(f)
				var txt: String = raw.get_string_from_utf8().strip_edges()
				if not txt.is_empty():
					installed_version = txt
				break

		var dest_dir: String = templates_root.path_join(installed_version)
		var mkdir_error: Error = DirAccess.make_dir_recursive_absolute(dest_dir)
		if mkdir_error != OK and not DirAccess.dir_exists_absolute(dest_dir):
			reader.close()
			return {"error": "Failed to create destination dir: " + error_string(mkdir_error)}

		var extracted: Array[String] = []
		for entry in archive_files:
			if entry.ends_with("/"):
				continue
			# Strip a leading "templates/" prefix as shipped inside official .tpz files.
			var rel: String = entry
			if rel.begins_with("templates/"):
				rel = rel.substr("templates/".length())
			if rel.is_empty():
				continue
			var data: PackedByteArray = reader.read_file(entry)
			var out_path: String = dest_dir.path_join(rel)
			var out_base: String = out_path.get_base_dir()
			if not out_base.is_empty():
				DirAccess.make_dir_recursive_absolute(out_base)
			var out_file: FileAccess = FileAccess.open(out_path, FileAccess.WRITE)
			if out_file == null:
				continue
			out_file.store_buffer(data)
			out_file.close()
			extracted.append(rel)
		reader.close()
		extracted.sort()

		if extracted.is_empty():
			return {"error": "Archive contained no extractable files: " + tpz_path}

		return {
			"action": "install",
			"templates_root": templates_root,
			"installed_version": installed_version,
			"dest_dir": dest_dir,
			"extracted_count": extracted.size(),
			"files": extracted,
			"godot_version": godot_version
		}

	# action == "remove"
	var version: String = str(params.get("version", "")).strip_edges()
	if version.is_empty():
		return {"error": "action='remove' requires version"}
	if version.contains("/") or version.contains("\\") or version == ".." or version.contains(".."):
		return {"error": "Invalid version directory name: " + version}
	var target_dir: String = templates_root.path_join(version)
	if not DirAccess.dir_exists_absolute(target_dir):
		return {"error": "Installed version not found: " + target_dir}

	var removed: int = _remove_dir_recursive(target_dir)
	return {
		"action": "remove",
		"templates_root": templates_root,
		"installed_version": version,
		"dest_dir": target_dir,
		"removed_count": removed,
		"godot_version": godot_version
	}

func _remove_dir_recursive(path: String) -> int:
	var count: int = 0
	var dir: DirAccess = DirAccess.open(path)
	if dir == null:
		return 0
	dir.list_dir_begin()
	var entry: String = dir.get_next()
	while entry != "":
		if entry == "." or entry == "..":
			entry = dir.get_next()
			continue
		var child: String = path.path_join(entry)
		if dir.current_is_dir():
			count += _remove_dir_recursive(child)
		else:
			if DirAccess.remove_absolute(child) == OK:
				count += 1
		entry = dir.get_next()
	dir.list_dir_end()
	DirAccess.remove_absolute(path)
	return count

# ============================================================================
# configure_android_export - set Android-specific export preset options
# ============================================================================

func _register_configure_android_export(server_core: RefCounted) -> void:
	var tool_name: String = "configure_android_export"
	var description: String = "Configure Android-specific options on an existing Android export preset in export_presets.cfg (e.g. package name, app name, version code/name, Gradle build, APK/AAB format, min/target SDK, target architectures, keystore file paths). Only sets the fields you provide; the preset's platform must be 'Android'. Keystore passwords are intentionally NOT written here — set them via the GODOT_ANDROID_KEYSTORE_* environment variables. Works on Godot 4.6+."

	var input_schema: Dictionary = {
		"type": "object",
		"properties": {
			"preset": {"type": "string", "description": "Preset name or section (e.g. 'Android' or 'preset.0')."},
			"config_path": {"type": "string", "description": "Path to export_presets.cfg. Default 'res://export_presets.cfg'.", "default": "res://export_presets.cfg"},
			"package_name": {"type": "string", "description": "Reverse-DNS application id -> package/unique_name (e.g. 'com.example.game')."},
			"app_name": {"type": "string", "description": "Display name -> package/name."},
			"version_code": {"type": "integer", "description": "Integer version code -> version/code."},
			"version_name": {"type": "string", "description": "Human version string -> version/name."},
			"use_gradle_build": {"type": "boolean", "description": "Toggle gradle_build/use_gradle_build."},
			"export_format": {"type": "string", "enum": ["apk", "aab"], "description": "gradle_build/export_format (apk=0, aab=1)."},
			"min_sdk": {"type": "string", "description": "gradle_build/min_sdk."},
			"target_sdk": {"type": "string", "description": "gradle_build/target_sdk."},
			"architectures": {"type": "array", "description": "Subset of ['arm64-v8a','armeabi-v7a','x86','x86_64']; listed archs are enabled, the rest disabled."},
			"keystore_release": {"type": "string", "description": "Path to release keystore -> keystore/release (path only, no password)."},
			"keystore_debug": {"type": "string", "description": "Path to debug keystore -> keystore/debug (path only, no password)."}
		},
		"required": ["preset"]
	}

	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"status": {"type": "string"},
			"config_path": {"type": "string"},
			"preset": {"type": "object"},
			"changes": {"type": "array"},
			"change_count": {"type": "integer"},
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
						  Callable(self, "_tool_configure_android_export"),
						  output_schema, annotations,
						  "supplementary", "Editor-Advanced")

func _tool_configure_android_export(params: Dictionary) -> Dictionary:
	var preset_name: String = str(params.get("preset", "")).strip_edges()
	if preset_name.is_empty():
		return {"error": "Missing required parameter: preset"}

	var config_path: String = str(params.get("config_path", "res://export_presets.cfg")).strip_edges()
	if config_path.is_empty():
		config_path = "res://export_presets.cfg"
	if not config_path.to_lower().ends_with(".cfg"):
		return {"error": "config_path must point to a .cfg file"}
	if not FileAccess.file_exists(config_path):
		return {"error": "Export config not found: " + config_path}

	var config: ConfigFile = ConfigFile.new()
	var load_error: Error = config.load(config_path)
	if load_error != OK:
		return {"error": "Failed to load export config: " + error_string(load_error)}

	# Locate the preset section by name or section id.
	var section: String = ""
	for raw_section in config.get_sections():
		var sname: String = str(raw_section)
		if not sname.begins_with("preset.") or sname.ends_with(".options"):
			continue
		if sname == preset_name or str(config.get_value(sname, "name", "")) == preset_name:
			section = sname
			break
	if section.is_empty():
		return {"error": "Export preset not found: " + preset_name}

	var platform: String = str(config.get_value(section, "platform", ""))
	if platform != "Android":
		return {"error": "Preset '%s' has platform '%s'; configure_android_export only supports Android presets." % [preset_name, platform]}

	var options_section: String = section + ".options"
	var changes: Array = []

	if params.has("package_name"):
		var v: String = str(params["package_name"]).strip_edges()
		config.set_value(options_section, "package/unique_name", v)
		changes.append({"key": "package/unique_name", "value": v})
	if params.has("app_name"):
		var v2: String = str(params["app_name"])
		config.set_value(options_section, "package/name", v2)
		changes.append({"key": "package/name", "value": v2})
	if params.has("version_code"):
		var vc: int = int(params["version_code"])
		config.set_value(options_section, "version/code", vc)
		changes.append({"key": "version/code", "value": vc})
	if params.has("version_name"):
		var vn: String = str(params["version_name"])
		config.set_value(options_section, "version/name", vn)
		changes.append({"key": "version/name", "value": vn})
	if params.has("use_gradle_build"):
		var ug: bool = bool(params["use_gradle_build"])
		config.set_value(options_section, "gradle_build/use_gradle_build", ug)
		changes.append({"key": "gradle_build/use_gradle_build", "value": ug})
	if params.has("export_format"):
		var fmt: String = str(params["export_format"]).strip_edges().to_lower()
		if not (fmt in ["apk", "aab"]):
			return {"error": "Invalid export_format '%s'. Expected 'apk' or 'aab'." % fmt}
		var fmt_value: int = 1 if fmt == "aab" else 0
		config.set_value(options_section, "gradle_build/export_format", fmt_value)
		changes.append({"key": "gradle_build/export_format", "value": fmt_value})
	if params.has("min_sdk"):
		var ms: String = str(params["min_sdk"]).strip_edges()
		config.set_value(options_section, "gradle_build/min_sdk", ms)
		changes.append({"key": "gradle_build/min_sdk", "value": ms})
	if params.has("target_sdk"):
		var ts: String = str(params["target_sdk"]).strip_edges()
		config.set_value(options_section, "gradle_build/target_sdk", ts)
		changes.append({"key": "gradle_build/target_sdk", "value": ts})
	if params.has("architectures"):
		var arch_param = params["architectures"]
		if not (arch_param is Array):
			return {"error": "architectures must be an array of strings"}
		var requested: Array[String] = []
		for a in arch_param:
			var an: String = str(a).strip_edges()
			if not (an in _ANDROID_ARCHITECTURES):
				return {"error": "Invalid architecture '%s'. Expected subset of: %s" % [an, ", ".join(_ANDROID_ARCHITECTURES)]}
			requested.append(an)
		for arch in _ANDROID_ARCHITECTURES:
			var enabled: bool = requested.has(arch)
			config.set_value(options_section, "architectures/" + arch, enabled)
			changes.append({"key": "architectures/" + arch, "value": enabled})
	if params.has("keystore_release"):
		var kr: String = str(params["keystore_release"]).strip_edges()
		config.set_value(options_section, "keystore/release", kr)
		changes.append({"key": "keystore/release", "value": kr})
	if params.has("keystore_debug"):
		var kd: String = str(params["keystore_debug"]).strip_edges()
		config.set_value(options_section, "keystore/debug", kd)
		changes.append({"key": "keystore/debug", "value": kd})

	if changes.is_empty():
		return {"error": "No Android options provided; nothing to configure."}

	var save_error: Error = config.save(config_path)
	if save_error != OK:
		return {"error": "Failed to save export config: " + error_string(save_error)}

	return {
		"status": "success",
		"config_path": config_path,
		"preset": {
			"section": section,
			"name": str(config.get_value(section, "name", "")),
			"platform": platform
		},
		"changes": changes,
		"change_count": changes.size(),
		"godot_version": str(Engine.get_version_info().get("string", ""))
	}
