# editor_tools_native.gd - Editor Tools原生实现
# 根据godot-dev-guide添加完整的类型提示

@tool
class_name EditorToolsNative
extends RefCounted

const VIBE_CODING_POLICY = preload("res://addons/godot_mcp/utils/vibe_coding_policy.gd")
# 系统代理检测复用隧道管理器的实现（静态方法，避免重复造轮子）。
const TUNNEL_MANAGER_SCRIPT = preload("res://addons/godot_mcp/native_mcp/mcp_tunnel_manager.gd")

var _editor_interface: EditorInterface = null
var _editor_operation_in_progress: bool = false
# Tracks the scene of the last successful play so run_project can reuse a
# matching live session instead of erroring on "already running".
var _last_played_scene: String = ""
# 导出模板下载状态机（工具自身的受信下载路径，不经过 execute_script 沙箱）。
var _template_download: Dictionary = {}

# 导出模板下载只允许官方分发主机；镜像 URL 由工具按版本推导，不接受任意 URL。
# api.github.com 仅用于获取官方资产字节数做完整性交叉验证。
const TEMPLATES_MIRROR_HOSTS: Array[String] = [
	"github.com",
	"api.github.com",
	"downloads.tuxfamily.org",
	"downloads.godotengine.org"
]
const TEMPLATES_DOWNLOAD_DIR: String = "user://mcp_export_templates"

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
		# get_editor_paths() 可能返回有效对象但目录为空串（部分编辑器上下文），
		# 必须穿透到平台回退而不是把空路径当结论。
		var from_paths: String = editor_paths.get_export_templates_dir() if editor_paths else ""
		if not from_paths.is_empty():
			return from_paths
	# EditorPaths 单例兜底：工具实例可能拿不到 EditorInterface，但单例仍可用。
	# 仅在编辑器上下文尝试——游戏/headless 模式下获取该单例会打印引擎错误。
	if Engine.is_editor_hint():
		var paths_singleton: Object = Engine.get_singleton("EditorPaths")
		if paths_singleton != null and paths_singleton.has_method("get_export_templates_dir"):
			var singleton_dir: String = String(paths_singleton.call("get_export_templates_dir"))
			if not singleton_dir.is_empty():
				return singleton_dir
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
	_register_undo(server_core)
	_register_redo(server_core)
	_register_get_undo_history(server_core)

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
		# Idempotent session reuse: re-running the live scene (or leaving the
		# scene unspecified) succeeds instead of stalling callers that already
		# started the game; a different scene switches sessions deterministically.
		var requested_scene: String = String(params.get("scene_path", "")).strip_edges()
		if requested_scene.is_empty() or requested_scene == _last_played_scene:
			return {
				"success": true,
				"already_running": true,
				"scene": _last_played_scene
			}
		editor_interface.stop_playing_scene()
		_last_played_scene = ""
		var settle_tree: SceneTree = Engine.get_main_loop() as SceneTree
		var settle_deadline: int = Time.get_ticks_msec() + 2000
		while editor_interface.is_playing_scene() and Time.get_ticks_msec() < settle_deadline:
			if settle_tree:
				await settle_tree.process_frame
			else:
				break

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
	_last_played_scene = played_scene

	# Give the runtime probe a brief window to signal ready so callers can use
	# runtime tools (scene tree, screenshot, expression eval) right away.
	var bridge: RefCounted = _get_debugger_bridge()
	var probe_ready: bool = bridge.is_probe_ready() if bridge else false
	var probe_deadline: int = Time.get_ticks_msec() + 2000
	while not probe_ready and tree and Time.get_ticks_msec() < probe_deadline:
		await tree.process_frame
		probe_ready = bridge.is_probe_ready() if bridge else false

	# Grace check: a parse error or early crash kills the debugger session within
	# the first moments. Reporting success there is a false positive — the engine
	# verdict must see "started_but_exited" so gates fail honestly.
	var grace_deadline: int = Time.get_ticks_msec() + 1200
	while tree and Time.get_ticks_msec() < grace_deadline:
		await tree.process_frame
		if not _has_active_debugger_session():
			_last_played_scene = ""
			return {
				"status": "started_but_exited",
				"error": "The game process exited shortly after launch (parse error or early crash). Check get_editor_logs / assert_no_runtime_errors evidence.",
				"scene": played_scene,
				"probe_ready": probe_ready
			}

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
	_last_played_scene = ""

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

## 在 MCP 直接写盘之后把变更同步进编辑器：更新 EditorFileSystem，并在
## 该脚本已打开时重载其缓冲区。没有这一步，编辑器会把 MCP 的写入识别为
## “外部程序修改了文件”并弹窗要求确认重载；有了它，MCP 的写入就是编辑
## 器内部操作。供 script_tools 的写工具在落盘成功后调用。
static func sync_script_buffer_after_write(editor_interface: EditorInterface,
		script_path: String) -> Dictionary:
	if editor_interface == null:
		return {"status": "skipped", "reason": "no_editor_interface"}
	var file_system: EditorFileSystem = editor_interface.get_resource_filesystem()
	if file_system != null:
		file_system.update_file(script_path)
	var script_editor: ScriptEditor = editor_interface.get_script_editor()
	if script_editor == null:
		return {"status": "ok", "reloaded": false}
	var is_open: bool = false
	for open_script_value in script_editor.get_open_scripts():
		var open_script: Script = open_script_value
		if open_script != null and String(open_script.resource_path) == script_path:
			is_open = true
			break
	if not is_open:
		return {"status": "ok", "reloaded": false}
	var reload_method: String = ""
	for candidate in ["reload_scripts", "reload_open_files"]:
		if script_editor.has_method(candidate):
			reload_method = candidate
			break
	if reload_method.is_empty():
		return {"status": "skipped", "reason": "reload_api_unavailable"}
	script_editor.call(reload_method)
	return {"status": "ok", "reloaded": true}

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
	var description: String = "Manage export templates. status: report installed versions + official URL for the current editor version. download: trusted background download from an allowlisted official mirror, verified and auto-installed; returns pending — poll with download_status, cancel with download_cancel. install: extract a local .tpz. remove: delete a version. Tool-side trusted network path (ScriptSandbox never applies). Godot 4.6+."

	var input_schema: Dictionary = {
		"type": "object",
		"properties": {
			"action": {
				"type": "string",
				"enum": ["status", "install", "remove", "download", "download_status", "download_cancel", "net_diag"],
				"description": "Operation.",
				"default": "status"
			},
			"mirror": {
				"type": "string",
				"enum": ["godotengine", "github", "tuxfamily"],
				"description": "download: mirror. Default godotengine (official geo portal).",
				"default": "godotengine"
			},
			"proxy": {
				"type": "string",
				"description": "download: loopback HTTP proxy (http://127.0.0.1:PORT); the system proxy is detected automatically."
			},
			"require_integrity": {
				"type": "boolean",
				"description": "download: fail when the official size check is unreachable.",
				"default": false
			},
			"connections": {
				"type": "integer",
				"description": "download: parallel connections (1-16), default 8, resumable.",
				"default": 8
			},
			"keep_archive": {
				"type": "boolean",
				"description": "download: keep the .tpz.",
				"default": false
			},
			"tpz_path": {
				"type": "string",
				"description": "install: local .tpz/.zip archive path."
			},
			"version": {
				"type": "string",
				"description": "remove: installed version directory name."
			},
			"templates_root": {
				"type": "string",
				"description": "Optional templates directory override."
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
		"base_version": short_version,
		"version_tag": tag,
		"tpz_filename": tpz_filename,
		"download_url": download_url
	}

## 官方镜像的模板下载 URL（按镜像 + 版本推导；调用方不可指定任意 URL）。
## "godotengine" 是官方下载门户（编辑器模板管理器同源入口）：按地理位置重定向到
## 实际对象存储（实测比 GitHub Releases 直连快一个数量级以上）。
static func templates_mirror_url(mirror: String, base_version: String,
		version_tag: String, tpz_filename: String) -> String:
	match mirror:
		"tuxfamily":
			return "https://downloads.tuxfamily.org/godotengine/%s/%s" % [base_version, tpz_filename]
		"godotengine":
			return "https://downloads.godotengine.org/?version=%s&flavor=stable&slug=export_templates.tpz&platform=templates" % base_version
		_:
			return "https://github.com/godotengine/godot/releases/download/%s/%s" % [version_tag, tpz_filename]

## 下载候选 URL 的主机必须命中官方白名单（纵深防御：即使未来改了 URL 构造）。
static func is_trusted_templates_url(url: String) -> bool:
	if not url.begins_with("https://"):
		return false
	var host: String = url.substr("https://".length()).get_slice("/", 0).to_lower()
	return host in TEMPLATES_MIRROR_HOSTS

## 解析官方 SUMS 文本（"<hash>  <filename>" 每行），返回对应文件的校验和。
## 官方发布仅提供 SHA-512，而 Godot 引擎原声哈希不支持 SHA-512，因此该校验
## 仅在引入外部哈希实现时才有意义；保留解析器供未来使用。
static func parse_checksum_sums(sums_text: String, filename: String) -> String:
	for raw_line in sums_text.split("\n"):
		var line: String = String(raw_line).strip_edges()
		if line.is_empty():
			continue
		var parts: PackedStringArray = line.split(" ", false)
		if parts.size() < 2:
			continue
		var candidate_name: String = String(parts[parts.size() - 1]).get_file()
		if candidate_name == filename:
			return String(parts[0]).to_lower()
	return ""

## 从 GitHub 发布 API 的 JSON 中提取指定资产的官方字节数；找不到返回 -1。
## 官方发布只附 SHA-512 校验和（引擎无法原生计算），因此完整性校验采用
## “API 元数据字节数 == 实际下载数”的交叉验证（两个独立 HTTPS 端点）。
static func templates_expected_size_from_release_json(json_text: String,
		tpz_filename: String) -> int:
	var parsed: Variant = JSON.parse_string(json_text)
	if not (parsed is Dictionary):
		return -1
	var assets_value: Variant = (parsed as Dictionary).get("assets", [])
	if not (assets_value is Array):
		return -1
	for asset_value in assets_value:
		if not (asset_value is Dictionary):
			continue
		var asset: Dictionary = asset_value
		if String(asset.get("name", "")) == tpz_filename:
			return int(asset.get("size", -1))
	return -1

## 完整性元数据源：GitHub 发布 API（官方资产清单，含精确字节数）。
static func templates_integrity_source_url(version_tag: String) -> String:
	return "https://api.github.com/repos/godotengine/godot/releases/tags/%s" % version_tag

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
	if not (action in ["status", "install", "remove", "download", "download_status", "download_cancel", "net_diag"]):
		return {"error": "Invalid action '%s'. Expected one of: status, install, remove, download, download_status, download_cancel, net_diag." % action}

	# net_diag 与下载状态机无关，也不需要 templates_root。
	if action == "net_diag":
		return _templates_net_diag(params)

	# download_status / download_cancel 只读写下载状态机，不需要安装目录；
	# 必须在 templates_root 解析之前分发，调用方才不必为轮询重复传 root。
	if action == "download_status":
		if _template_download.is_empty():
			return {"action": "download_status", "status": "idle",
				"message": "No template download has been started."}
		return {"action": "download_status", "status": _template_download.get("report_status", "pending"),
			"download": _templates_download_snapshot()}
	if action == "download_cancel":
		return _templates_download_cancel()

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

	if action == "download":
		return _templates_download_start(params, templates_root, version_meta, godot_version)

	if action == "install":
		var tpz_path: String = str(params.get("tpz_path", "")).strip_edges()
		if tpz_path.is_empty():
			return {"error": "action='install' requires tpz_path"}
		if tpz_path.begins_with("res://") or tpz_path.begins_with("user://"):
			tpz_path = ProjectSettings.globalize_path(tpz_path)
		if not FileAccess.file_exists(tpz_path):
			return {"error": "Template archive not found: " + tpz_path}
		var installed_result: Dictionary = _install_templates_from_tpz(
			tpz_path, templates_root, version_meta, godot_version)
		if installed_result.has("error"):
			return installed_result
		installed_result["action"] = "install"
		return installed_result

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

## 将 .tpz/.zip 模板包解压安装到 templates 目录（install 动作与下载完成后共用）。
func _install_templates_from_tpz(tpz_path: String, templates_root: String,
		version_meta: Dictionary, godot_version: String) -> Dictionary:
	var reader: ZIPReader = ZIPReader.new()
	var open_error: Error = reader.open(tpz_path)
	if open_error != OK:
		return {"error": "Failed to open archive: " + error_string(open_error)}

	var archive_files: PackedStringArray = reader.get_files()
	# Determine the installed version: prefer templates/version.txt inside the archive.
	var installed_version: String = String(version_meta.get("version_tag", ""))
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
		"templates_root": templates_root,
		"installed_version": installed_version,
		"dest_dir": dest_dir,
		"extracted_count": extracted.size(),
		"files": extracted,
		"godot_version": godot_version
	}

# ============================================================================
# 导出模板受信下载（官方镜像白名单 + 完整性交叉验证 + 完成后自动安装）
# ============================================================================

## 单次 HTTPS GET 驱动节点：直连，或经回环 HTTP 代理的 CONNECT 隧道 + TLS。
## Godot 的 HTTPRequest 不支持代理，而 GitHub 发布资产在部分网络只能经代理
## 可达，因此下载使用手写客户端；两条路径共用同一实现。
# 下载链路诊断：同一 _process 泵并行拨号 域名（DNS+TCP）/ IP 字面量（仅 TCP）/
# 公共对照 IP，上报 _process tick 数与状态时间线。判读：
#   ticks==0            —— 节点未被主循环处理（树挂载/线程问题，下载器同病）
#   ticks>0 全 connecting —— 编辑器进程出站 TCP 被网络层拦截
#   ip 通而域名卡        —— 进程内 DNS 解析挂起
class TemplatesNetDiag extends Node:
	var peers: Array = []
	var ticks: int = 0
	var started_ms: int = 0
	var deadline_ms: int = 12000
	var _done: bool = false

	static func _status_name(s: int) -> String:
		match s:
			StreamPeerTCP.STATUS_NONE: return "none"
			StreamPeerTCP.STATUS_CONNECTING: return "connecting"
			StreamPeerTCP.STATUS_CONNECTED: return "connected"
			StreamPeerTCP.STATUS_ERROR: return "error"
		return str(s)

	static func _spawn(label: String, host: String, port: int) -> Dictionary:
		var tcp: StreamPeerTCP = StreamPeerTCP.new()
		tcp.connect_to_host(host, port)
		return {"label": label, "tcp": tcp, "last": -1, "log": []}

	func setup(host: String, port: int, ip_control: String) -> void:
		peers = [
			_spawn("dns:" + host, host, port),
			_spawn("ip:" + ip_control, ip_control, port),
			_spawn("ip:1.1.1.1", "1.1.1.1", 443),
		]
		started_ms = Time.get_ticks_msec()

	func is_finished() -> bool:
		return _done

	func _process(_delta: float) -> void:
		ticks += 1
		if _done:
			return
		var pending: int = 0
		for peer in peers:
			var tcp: StreamPeerTCP = peer["tcp"]
			tcp.poll()
			var s: int = tcp.get_status()
			if s != int(peer["last"]):
				peer["last"] = s
				(peer["log"] as Array).append([Time.get_ticks_msec() - started_ms, _status_name(s)])
			if s == StreamPeerTCP.STATUS_CONNECTING or s == StreamPeerTCP.STATUS_NONE:
				pending += 1
		if pending == 0 or Time.get_ticks_msec() - started_ms > deadline_ms:
			_done = true
			for peer in peers:
				(peer["tcp"] as StreamPeerTCP).disconnect_from_host()

	func report() -> Dictionary:
		var out_peers: Array = []
		for peer in peers:
			out_peers.append({
				"label": peer["label"],
				"status": _status_name(int(peer["last"])) if int(peer["last"]) >= 0 else "unpolled",
				"timeline": peer["log"],
			})
		return {
			"action": "net_diag",
			"status": "finished" if _done else "running",
			"process_ticks": ticks,
			"elapsed_ms": (Time.get_ticks_msec() - started_ms) if started_ms > 0 else 0,
			"node_id": get_instance_id(),
			"in_tree": is_inside_tree(),
			"path": str(get_path()) if is_inside_tree() else "",
			"process_enabled": is_processing(),
			"peers": out_peers,
		}

# static 存储：热重载会重置工具实例成员，诊断节点句柄必须跨实例存活。
static var _net_diag_shared: Node = null
static var _net_diag_last_frames: int = -1

func _templates_net_diag(params: Dictionary) -> Dictionary:
	var host: String = str(params.get("host", "downloads.godotengine.org")).strip_edges()
	if host.is_empty():
		return {"error": "host must not be empty for net_diag."}
	var port: int = clampi(int(params.get("port", 443)), 1, 65535)
	var ip_control: String = str(params.get("ip", "172.67.193.253")).strip_edges()
	var base: Dictionary = {
		"handler_on_main_thread": Thread.is_main_thread(),
		"engine_frames": Engine.get_process_frames(),
	}
	if _net_diag_last_frames >= 0:
		base["frames_delta_since_last_call"] = Engine.get_process_frames() - _net_diag_last_frames
	_net_diag_last_frames = Engine.get_process_frames()
	if _net_diag_shared != null and is_instance_valid(_net_diag_shared):
		var running: TemplatesNetDiag = _net_diag_shared as TemplatesNetDiag
		if not running.is_finished():
			var rep: Dictionary = running.report()
			rep.merge(base, true)
			return rep
		running.queue_free()
	var root: Node = (Engine.get_main_loop() as SceneTree).root if Engine.get_main_loop() is SceneTree else null
	if root == null:
		base["error"] = "No scene tree root available for net diagnostics."
		return base
	var diag: TemplatesNetDiag = TemplatesNetDiag.new()
	diag.setup(host, port, ip_control)
	root.add_child(diag)
	if not diag.is_inside_tree():
		base["error"] = "net_diag node failed to enter the scene tree (add_child rejected)."
		return base
	_net_diag_shared = diag
	var rep2: Dictionary = diag.report()
	rep2.merge(base, true)
	return rep2

class TemplatesHttpGetter extends Node:
	signal completed(outcome: Dictionary)
	## progress_cb(bytes, total)
	var progress_cb: Callable = Callable()

	var _tcp: StreamPeerTCP = StreamPeerTCP.new()
	var _tls: StreamPeerTLS = null
	var _url: String = ""
	var _proxy: String = ""
	var _dest_abs: String = ""
	var _idle_timeout_msec: int = 30000
	var _last_progress_msec: int = 0
	var _phase: String = "idle"  # idle|tcp|tunnel|tls|headers|body|done
	var _connect_host: String = ""
	var _connect_port: int = 443
	var _tunnel_buffer: PackedByteArray = PackedByteArray()
	var _tunnel_scan: int = 0
	var _header_bytes: PackedByteArray = PackedByteArray()
	var _body_file: FileAccess = null
	var _body_memory: PackedByteArray = PackedByteArray()
	var _to_memory: bool = false
	var _content_length: int = -1
	# 并行分块支持：Range 头（接受 206）、写偏移（多 worker 共享目标文件）、
	# 打开模式（worker 用 READ_WRITE 避免互相截断）与响应头透出。
	var range_header: String = ""
	var write_offset: int = -1
	var file_open_mode: int = FileAccess.WRITE
	var response_headers: Dictionary = {}
	var response_status: int = 0
	var _chunked: bool = false
	var _body_buffer: PackedByteArray = PackedByteArray()
	var _chunk_remaining: int = -1
	var _bytes_downloaded: int = 0
	var _redirects_left: int = 5
	# 单帧最大读取量；并行 worker 由协调器调低以控制总资源占用。
	var frame_drain_cap: int = 4 * 1024 * 1024

	static func create(url: String, dest_abs: String, proxy: String,
			idle_timeout_msec: int = 30000, to_memory: bool = false) -> TemplatesHttpGetter:
		var getter: TemplatesHttpGetter = TemplatesHttpGetter.new()
		getter._url = url
		getter._dest_abs = dest_abs
		getter._proxy = proxy
		getter._idle_timeout_msec = idle_timeout_msec
		getter._to_memory = to_memory
		return getter

	func start() -> void:
		_last_progress_msec = Time.get_ticks_msec()
		if not _begin_request(_url):
			_fail("invalid URL: " + _url)

	func _fail(reason: String) -> void:
		_cleanup()
		completed.emit({"ok": false, "error": reason, "bytes": _bytes_downloaded})

	func _cleanup() -> void:
		_phase = "done"
		if _body_file != null:
			_body_file.close()
			_body_file = null
		_tcp.disconnect_from_host()
		set_process(false)

	func _begin_request(url: String) -> bool:
		if not url.begins_with("https://"):
			return false
		var host_port: String = url.substr("https://".length()).get_slice("/", 0)
		_connect_host = host_port.get_slice(":", 0)
		var port_text: String = host_port.get_slice(":", 1)
		_connect_port = int(port_text) if port_text.is_valid_int() else 443
		if _connect_host.is_empty():
			return false
		_header_bytes = PackedByteArray()
		_content_length = -1
		_bytes_downloaded = 0
		_tls = null
		_tunnel_buffer = PackedByteArray()
		_tunnel_scan = 0
		var dial_host: String = _connect_host
		var dial_port: int = _connect_port
		if not _proxy.is_empty():
			var proxy_host_port: String = _proxy.substr("http://".length())
			dial_host = proxy_host_port.get_slice(":", 0)
			dial_port = int(proxy_host_port.get_slice(":", 1))
		_tcp.connect_to_host(dial_host, dial_port)
		_phase = "tcp"
		return true

	func _process(_delta: float) -> void:
		if _phase == "done":
			return
		if Time.get_ticks_msec() - _last_progress_msec > _idle_timeout_msec:
			_fail("idle timeout (%d ms without progress)" % _idle_timeout_msec)
			return
		# 裸 StreamPeer 不会自行推进：连接建立与 TLS 握手都依赖每帧 poll()。
		_tcp.poll()
		if _tls != null:
			_tls.poll()
		match _phase:
			"tcp":
				_pump_tcp()
			"tunnel":
				_pump_tunnel()
			"tls":
				_pump_tls()
			"headers":
				_pump_headers()
			"body":
				_pump_body()

	func _pump_tcp() -> void:
		var status: int = _tcp.get_status()
		if status == StreamPeerTCP.STATUS_CONNECTED:
			_last_progress_msec = Time.get_ticks_msec()
			if _proxy.is_empty():
				_start_tls()
			else:
				var connect_line: String = "CONNECT %s:%d HTTP/1.1\r\nHost: %s:%d\r\n\r\n" % [
					_connect_host, _connect_port, _connect_host, _connect_port]
				_tcp.put_data(connect_line.to_utf8_buffer())
				_phase = "tunnel"
		elif status == StreamPeerTCP.STATUS_ERROR:
			_fail("TCP connect failed (host=%s proxy=%s)" % [_connect_host, _proxy])

	func _pump_tunnel() -> void:
		var available: int = _tcp.get_available_bytes()
		if available <= 0:
			return
		_tunnel_buffer.append_array((_tcp.get_data(available) as Array)[1])
		var header_end: int = _find_double_crlf(_tunnel_buffer)
		if header_end < 0:
			if _tunnel_buffer.size() > 16 * 1024:
				_fail("Proxy CONNECT response too large")
			return
		var first_line: String = _tunnel_buffer.slice(0, _tunnel_buffer.find(13)).get_string_from_utf8()
		var code_text: String = first_line.get_slice(" ", 1).split(" ")[0]
		if not code_text.is_valid_int():
			_fail("Malformed proxy CONNECT response")
			return
		if int(code_text) != 200:
			_fail("Proxy CONNECT rejected: " + first_line)
			return
		_last_progress_msec = Time.get_ticks_msec()
		_start_tls()

	static func build_get_request(path_and_query: String, host: String, range: String) -> String:
		var request_text: String = "GET %s HTTP/1.1\r\nHost: %s\r\nUser-Agent: GodotMCP\r\nAccept: */*\r\n" % [path_and_query, host]
		if not range.is_empty():
			request_text += "Range: %s\r\n" % range
		request_text += "Connection: close\r\n\r\n"
		return request_text

	static func is_acceptable_status(code: int, expects_partial: bool) -> bool:
		if expects_partial:
			return code == 206 or code == 200
		return code == 200

	func _start_tls() -> void:
		_tls = StreamPeerTLS.new()
		if _tls.connect_to_stream(_tcp, _connect_host) != OK:
			_tls = null
			_fail("TLS setup failed for " + _connect_host)
			return
		_phase = "tls"

	func _pump_tls() -> void:
		var status: int = _tls.get_status()
		if status == StreamPeerTLS.STATUS_CONNECTED:
			_last_progress_msec = Time.get_ticks_msec()
			var authority: String = _url.substr("https://".length()).get_slice("/", 0)
			var path_and_query: String = _url.substr(("https://" + authority).length())
			if not path_and_query.begins_with("/"):
				path_and_query = "/" + path_and_query
			var request_text: String = build_get_request(path_and_query, _connect_host, range_header)

			_tls.put_data(request_text.to_utf8_buffer())
			_phase = "headers"
		elif status == StreamPeerTLS.STATUS_ERROR:
			_fail("TLS handshake failed for " + _connect_host)

	func _pump_headers() -> void:
		while true:
			var available: int = _tls.get_available_bytes()
			if available <= 0:
				break
			_header_bytes.append_array((_tls.get_data(available) as Array)[1])
		if _header_bytes.size() > 0:
			_last_progress_msec = Time.get_ticks_msec()
		var header_end: int = _find_double_crlf(_header_bytes)
		if header_end < 0:
			if _header_bytes.size() > 64 * 1024:
				_fail("Response headers exceeded 64 KiB")
			return
		var header_text: String = _header_bytes.slice(0, header_end).get_string_from_utf8()
		var code_text: String = header_text.get_slice(" ", 1).split(" ")[0]
		if not code_text.is_valid_int():
			_fail("Malformed HTTP status line")
			return
		var status_code: int = int(code_text)
		if status_code >= 300 and status_code < 400 and _redirects_left > 0:
			var location: String = _header_value(header_text, "location")
			if location.is_empty():
				_fail("Redirect without Location header")
				return
			_redirects_left -= 1
			if location.begins_with("/"):
				location = "https://" + _connect_host + location
			_tcp.disconnect_from_host()
			_tcp = StreamPeerTCP.new()
			if not _begin_request(location):
				_fail("Invalid redirect target: " + location)
				return
			_url = location
			return
		response_status = status_code
		for raw_line in header_text.split("\r\n"):
			var line_separator: int = String(raw_line).find(":")
			if line_separator > 0:
				response_headers[String(raw_line).substr(0, line_separator).strip_edges().to_lower()] = \
					String(raw_line).substr(line_separator + 1).strip_edges()
		if not is_acceptable_status(status_code, not range_header.is_empty()):
			_fail("HTTP %d for %s" % [status_code, _url])
			return
		if not range_header.is_empty() and status_code == 200 and write_offset > 0:
			_fail("Origin ignored the Range request; parallel chunks would corrupt the file")
			return
		var length_text: String = _header_value(header_text, "content-length")
		_chunked = _header_value(header_text, "transfer-encoding").to_lower().contains("chunked")
		if not _chunked and not length_text.is_valid_int():
			_fail("Response has neither Content-Length nor chunked encoding")
			return
		_content_length = int(length_text) if length_text.is_valid_int() else -1
		_body_buffer = _header_bytes.slice(header_end + 4)
		_header_bytes = PackedByteArray()
		if not _to_memory:
			_body_file = FileAccess.open(_dest_abs, file_open_mode)
			if _body_file == null:
				_fail("Cannot open destination file: " + _dest_abs)
				return
			if write_offset > 0:
				_body_file.seek(write_offset)
		_bytes_downloaded = 0
		_phase = "body"
		_consume_body_buffer()
		if progress_cb.is_valid():
			progress_cb.call(_bytes_downloaded, _content_length)

	func _pump_body() -> void:
		# 每帧循环榨干缓冲（上限 4 MiB/帧）：编辑器失焦时帧率骤降，每帧单次
		# 读取会把吞吐锁死在"帧率 × 单帧到达量"（实测 152KB/s）；紧循环读取
		# 才能吃满 TCP 接收窗口，同时上限保证编辑器帧不被下载饿死。
		var drained: int = 0
		while drained < frame_drain_cap:
			var available: int = _tls.get_available_bytes()
			if available <= 0:
				break
			_body_buffer.append_array((_tls.get_data(available) as Array)[1])
			drained += available
		if drained > 0:
			_last_progress_msec = Time.get_ticks_msec()
		_consume_body_buffer()
		if progress_cb.is_valid() and drained > 0:
			progress_cb.call(_bytes_downloaded, _content_length)

	## 按需解码：Content-Length 直读；chunked 走 hex 大小行状态机。
	func _consume_body_buffer() -> void:
		if not _chunked:
			if _body_buffer.is_empty():
				if _content_length == 0:
					_finish_body()
				return
			var decoded: PackedByteArray = _body_buffer
			_body_buffer = PackedByteArray()
			_store_body(decoded)
			if _content_length >= 0 and _bytes_downloaded >= _content_length:
				_finish_body()
			elif _content_length < 0 and _phase != "done":
				_finish_body()
			return
		while true:
			if _chunk_remaining < 0:
				var line_end: int = _body_buffer.find(13)
				if line_end < 0 or line_end + 1 >= _body_buffer.size() or _body_buffer[line_end + 1] != 10:
					if _body_buffer.size() > 1024:
						_fail("Chunked size line exceeded 1 KiB")
					return
				var size_text: String = _body_buffer.slice(0, line_end).get_string_from_utf8().strip_edges()
				size_text = size_text.split(";")[0].strip_edges()
				if not size_text.is_valid_hex_number():
					_fail("Malformed chunk size: " + size_text)
					return
				_chunk_remaining = size_text.hex_to_int()
				_body_buffer = _body_buffer.slice(line_end + 2)
				if _chunk_remaining == 0:
					_finish_body()
					return
				continue
			if _body_buffer.size() < _chunk_remaining + 2:
				return
			var chunk: PackedByteArray = _body_buffer.slice(0, _chunk_remaining)
			_body_buffer = _body_buffer.slice(_chunk_remaining + 2)
			_chunk_remaining = -1
			_store_body(chunk)

	func _store_body(decoded: PackedByteArray) -> void:
		if decoded.is_empty():
			return
		if _to_memory:
			_body_memory.append_array(decoded)
		elif _body_file != null:
			_body_file.store_buffer(decoded)
		_bytes_downloaded += decoded.size()

	func _finish_body() -> void:
		var outcome: Dictionary = {
			"ok": true, "bytes": _bytes_downloaded, "total": _content_length,
			"chunked": _chunked, "status": response_status,
			"headers": response_headers.duplicate()}
		if _to_memory:
			outcome["text"] = _body_memory.get_string_from_utf8()
		_cleanup()
		completed.emit(outcome)

	static func _find_double_crlf(data: PackedByteArray) -> int:
		var limit: int = data.size() - 4
		for i in range(limit + 1):
			if data[i] == 13 and data[i + 1] == 10 and data[i + 2] == 13 and data[i + 3] == 10:
				return i
		return -1

	static func _header_value(header_text: String, name: String) -> String:
		for raw_line in header_text.split("\r\n"):
			var line: String = String(raw_line)
			var separator: int = line.find(":")
			if separator <= 0:
				continue
			if line.substr(0, separator).strip_edges().to_lower() == name:
				return line.substr(separator + 1).strip_edges()
		return ""


## 并行分块下载协调器：N 条 Range 连接（默认 4，上限 8）各写同一目标文件的
## 独立偏移区间。分块进度持久化到 <dest>.download.json，任何中断后重启只补
## 未完成分块（断点续传）。资源有界：每 worker 每帧 1 MiB 读取上限、磁盘流式
## 直写、固定小块缓冲，无内存增长。
class TemplatesParallelFetch extends Node:
	signal completed(outcome: Dictionary)
	## progress_cb(bytes, total)
	var progress_cb: Callable = Callable()

	var _url: String = ""
	var _dest_abs: String = ""
	var _proxy: String = ""
	var _connections: int = 8
	var _idle_ms: int = 60000
	var _total: int = -1
	var _etag: String = ""
	var _chunks: Array = []
	var _workers: Array = []
	var _done_count: int = 0
	var _failed: bool = false
	var _finished: bool = false
	var _resumed: bool = false
	var _last_persist_ms: int = 0
	var _state_path: String = ""

	static func plan_chunks(total: int, connections: int) -> Array:
		var count: int = maxi(1, mini(connections, 16))
		if total <= 0:
			return []
		count = mini(count, maxi(1, int(ceil(float(total) / 1048576.0))))
		var chunk_size: int = int(total / count)
		var out: Array = []
		var start: int = 0
		for i in range(count):
			var end: int = total - 1 if i == count - 1 else start + chunk_size - 1
			out.append({"start": start, "end": end, "have": 0, "retries": 0})
			start = end + 1
		return out

	func setup(url: String, dest_abs: String, proxy: String, connections: int,
			idle_ms: int = 60000) -> void:
		_url = url
		_dest_abs = dest_abs
		_proxy = proxy
		_connections = clampi(connections, 1, 16)
		_idle_ms = idle_ms
		_state_path = dest_abs + ".download.json"

	func start() -> void:
		_probe()

	func _run_probe() -> Dictionary:
		var probe: TemplatesHttpGetter = TemplatesHttpGetter.create(_url, "", _proxy, 60000, true)
		probe.range_header = "bytes=0-0"
		probe.frame_drain_cap = 65536
		get_tree().root.add_child(probe)
		var outcome: Dictionary = await probe.completed
		probe.queue_free()
		return outcome

	func _probe() -> void:
		# 探针只有 1 字节，但重定向链 + TLS 握手在高延迟网络可能超过 20 秒；
		# 与 worker 相同的 60 秒空闲上限，失败自动重试一次。
		var outcome: Dictionary = await _run_probe()
		if _finished:
			return
		if not bool(outcome.get("ok", false)):
			outcome = await _run_probe()
		if _finished:
			return
		if not bool(outcome.get("ok", false)):
			_finish(false, "probe failed: " + String(outcome.get("error", "")))
			return
		var headers: Dictionary = outcome.get("headers", {})
		_etag = String(headers.get("etag", ""))
		var content_range: String = String(headers.get("content-range", ""))
		if content_range.contains("/") and content_range.get_slice("/", 1).is_valid_int():
			_total = int(content_range.get_slice("/", 1))
		elif String(outcome.get("total", "-1")).is_valid_int() and int(outcome.get("total", -1)) > 1:
			_total = int(outcome["total"])
		if _total <= 0:
			_finish(false, "origin did not report a usable size for parallel ranges")
			return
		_resumed = _load_state()
		if not _resumed:
			_chunks = plan_chunks(_total, _connections)
			var preallocate: FileAccess = FileAccess.open(_dest_abs, FileAccess.WRITE)
			if preallocate == null:
				_finish(false, "cannot create destination file: " + _dest_abs)
				return
			preallocate.close()
		_persist()
		_spawn_missing_workers()

	func _state_dict() -> Dictionary:
		return {
			"url": _url, "total": _total, "etag": _etag,
			"chunks": _chunks.duplicate(true),
		}

	func _persist() -> void:
		_last_persist_ms = Time.get_ticks_msec()
		var file: FileAccess = FileAccess.open(_state_path, FileAccess.WRITE)
		if file:
			file.store_string(JSON.stringify(_state_dict()))
			file.close()

	func _load_state() -> bool:
		if not FileAccess.file_exists(_state_path) or not FileAccess.file_exists(_dest_abs):
			return false
		var file: FileAccess = FileAccess.open(_state_path, FileAccess.READ)
		if file == null:
			return false
		var parsed: Variant = JSON.parse_string(file.get_as_text())
		file.close()
		if not (parsed is Dictionary):
			return false
		var state: Dictionary = parsed
		if int(state.get("total", -1)) != _total or String(state.get("url", "")) != _url:
			return false
		var stored: Array = state.get("chunks", [])
		if stored.is_empty():
			return false
		var rebuilt: Array = []
		for chunk_value in stored:
			var chunk: Dictionary = chunk_value
			chunk["retries"] = 0
			rebuilt.append(chunk)
		_chunks = rebuilt
		return true

	func _chunk_length(chunk: Dictionary) -> int:
		return int(chunk.get("end", 0)) - int(chunk.get("start", 0)) + 1

	func _spawn_missing_workers() -> void:
		if _failed:
			return
		for chunk_value in _chunks:
			var chunk: Dictionary = chunk_value
			if int(chunk.get("have", 0)) >= _chunk_length(chunk):
				_done_count += 1
				continue
			_spawn_worker(chunk)
		if _done_count >= _chunks.size():
			_all_done()

	func _spawn_worker(chunk: Dictionary) -> void:
		var worker: TemplatesHttpGetter = TemplatesHttpGetter.create(
			_url, _dest_abs, _proxy, _idle_ms)
		var offset: int = int(chunk.get("start", 0)) + int(chunk.get("have", 0))
		worker.range_header = "bytes=%d-%d" % [offset, int(chunk.get("end", 0))]
		worker.write_offset = offset
		worker.file_open_mode = FileAccess.READ_WRITE
		worker.frame_drain_cap = 1024 * 1024
		worker.progress_cb = Callable(self, "_on_worker_progress").bind(chunk)
		worker.completed.connect(_on_worker_completed.bind(chunk))
		_workers.append(worker)
		get_tree().root.add_child(worker)
		worker.start()

	func _on_worker_progress(bytes: int, _chunk_total: int, chunk: Dictionary) -> void:
		if _finished or _failed:
			return
		chunk["have"] = mini(bytes, _chunk_length(chunk))
		if Time.get_ticks_msec() - _last_persist_ms > 30000:
			_persist()
		if progress_cb.is_valid():
			var aggregate: int = 0
			for chunk_value in _chunks:
				aggregate += int((chunk_value as Dictionary).get("have", 0))
			progress_cb.call(aggregate, _total)

	func _on_worker_completed(outcome: Dictionary, chunk: Dictionary) -> void:
		if _finished:
			return
		if not bool(outcome.get("ok", false)):
			if int(chunk.get("retries", 0)) < 2 and not _failed:
				chunk["retries"] = int(chunk.get("retries", 0)) + 1
				_persist()
				_spawn_worker(chunk)
			else:
				_fail_all(String(outcome.get("error", "chunk failed")))
			return
		chunk["have"] = _chunk_length(chunk)
		_done_count += 1
		_persist()
		if _done_count >= _chunks.size():
			_all_done()

	func _all_done() -> void:
		var staged: FileAccess = FileAccess.open(_dest_abs, FileAccess.READ)
		var size: int = staged.get_length() if staged != null else -1
		if staged != null:
			staged.close()
		if size != _total:
			_finish(false, "assembled size %d != expected %d" % [size, _total])
			return
		_finish(true, "")

	func _fail_all(reason: String) -> void:
		for worker_value in _workers:
			var worker: Node = worker_value
			if is_instance_valid(worker) and worker.has_method("_fail"):
				worker.call("_fail", "coordinator cancelled")
		_finish(false, reason)

	func cancel() -> void:
		if _finished:
			return
		_persist()
		_fail_all("cancelled")

	func _finish(ok: bool, reason: String) -> void:
		if _finished:
			return
		_finished = true
		_failed = not ok
		for worker_value in _workers:
			var worker: Node = worker_value
			if is_instance_valid(worker) and worker.is_inside_tree():
				worker.get_parent().remove_child(worker)
				worker.queue_free()
		_workers.clear()
		var outcome: Dictionary = {
			"ok": ok, "bytes": _total if ok else 0, "total": _total,
			"connections": _chunks.size(), "resumed": _resumed,
		}
		if not ok:
			outcome["error"] = reason
		completed.emit(outcome)

## 校验代理参数：仅允许本机回环代理（http://127.0.0.1:PORT / http://localhost:PORT）。
static func _templates_proxy_allowed(raw: String) -> String:
	var proxy: String = raw.strip_edges()
	if proxy.is_empty():
		return ""
	if proxy.begins_with("http://"):
		var host_port: String = proxy.substr("http://".length()).strip_edges().trim_suffix("/")
		var host: String = host_port.get_slice(":", 0).to_lower()
		var port_text: String = host_port.get_slice(":", 1)
		if (host == "127.0.0.1" or host == "localhost") and port_text.is_valid_int() \
				and int(port_text) > 0 and int(port_text) < 65536:
			return "http://%s:%d" % [host, int(port_text)]
	return ""

func _templates_download_snapshot() -> Dictionary:
	var state: Dictionary = _template_download
	var snapshot: Dictionary = {
		"phase": String(state.get("phase", "")),
		"mirror": String(state.get("mirror", "")),
		"url": String(state.get("url", "")),
		"bytes": int(state.get("bytes", 0)),
		"total_bytes": int(state.get("total_bytes", 0)),
		"elapsed_ms": Time.get_ticks_usec() / 1000 - int(state.get("started_ms", 0)),
	}
	var total_bytes: int = int(snapshot["total_bytes"])
	if total_bytes > 0:
		snapshot["percent"] = round(float(snapshot["bytes"]) / float(total_bytes) * 1000.0) / 10.0
	var elapsed_sec: float = float(snapshot["elapsed_ms"]) / 1000.0
	if elapsed_sec > 0.5 and int(snapshot["bytes"]) > 0:
		snapshot["speed_kbps"] = int(float(snapshot["bytes"]) / 1024.0 / elapsed_sec)
	if state.has("integrity"):
		snapshot["integrity"] = state["integrity"]
	if state.has("result"):
		snapshot["result"] = state["result"]
	if state.has("error"):
		snapshot["error"] = state["error"]
	return snapshot

func _templates_download_proxy(params: Dictionary) -> String:
	var explicit: String = _templates_proxy_allowed(String(params.get("proxy", "")))
	if not explicit.is_empty():
		return explicit
	# 无显式代理时自动检测系统代理（仅回环地址会被采用）。
	return _templates_proxy_allowed(TUNNEL_MANAGER_SCRIPT.detect_system_proxy())

func _templates_download_start(params: Dictionary, templates_root: String,
		version_meta: Dictionary, godot_version: String) -> Dictionary:
	var active_phase: String = String(_template_download.get("phase", ""))
	if active_phase in ["downloading", "verifying", "installing"]:
		return {
			"action": "download", "status": "pending",
			"download": _templates_download_snapshot(),
			"message": "A download is already in progress; poll with action='download_status'."
		}
	var mirror: String = String(params.get("mirror", "godotengine")).strip_edges().to_lower()
	if not mirror in ["github", "tuxfamily", "godotengine"]:
		return {"error": "Invalid mirror '%s'. Expected one of: github, tuxfamily, godotengine." % mirror}
	var info: Dictionary = Engine.get_version_info()
	if int(info.get("major", 0)) == 0:
		return {"error": "Could not determine the running editor version."}
	var tpz_filename: String = String(version_meta.get("tpz_filename", ""))
	var url: String = templates_mirror_url(mirror,
		String(version_meta.get("base_version", "")),
		String(version_meta.get("version_tag", "")), tpz_filename)
	if not is_trusted_templates_url(url):
		return {"error": "Derived download URL is not on the trusted template hosts: " + url}
	var proxy: String = _templates_download_proxy(params)

	var dir_abs: String = ProjectSettings.globalize_path(TEMPLATES_DOWNLOAD_DIR)
	DirAccess.make_dir_recursive_absolute(dir_abs)
	var part_path: String = TEMPLATES_DOWNLOAD_DIR.path_join(tpz_filename + ".part")
	var part_abs: String = ProjectSettings.globalize_path(part_path)
	DirAccess.remove_absolute(part_abs)  # 不做断点续传，旧分片一律作废

	var root: Node = (Engine.get_main_loop() as SceneTree).root if Engine.get_main_loop() is SceneTree else null
	if root == null:
		return {"error": "No scene tree root available to host the download request."}
	# 并行分块路径（默认 4 连接，上限 8）：Range 分块直写目标文件 + .download.json
	# 断点续传；中断后重启只补未完成分块。资源有界：每 worker 每帧 1 MiB。
	var connections: int = clampi(int(params.get("connections", 8)), 1, 16)
	var tpz_abs: String = ProjectSettings.globalize_path(
		TEMPLATES_DOWNLOAD_DIR.path_join(String(version_meta.get("tpz_filename", ""))))
	if connections >= 2:
		var fetch: TemplatesParallelFetch = TemplatesParallelFetch.new()
		fetch.setup(url, tpz_abs, proxy, connections, 60000)
		fetch.progress_cb = Callable(self, "_on_templates_download_progress")
		fetch.completed.connect(_on_templates_download_completed)
		root.add_child(fetch)
		_template_download = {
			"phase": "downloading",
			"report_status": "pending",
			"mirror": mirror,
			"url": url,
			"part_abs": "",
			"tpz_abs": tpz_abs,
			"tpz_filename": String(version_meta.get("tpz_filename", "")),
			"coordinator": fetch,
			"started_ms": Time.get_ticks_usec() / 1000,
			"bytes": 0,
			"total_bytes": 0,
			"templates_root": templates_root,
			"version_meta": version_meta.duplicate(true),
			"godot_version": godot_version,
			"proxy": proxy,
			"state_json": tpz_abs + ".download.json",
			"require_integrity": bool(params.get("require_integrity", false)),
			"keep_archive": bool(params.get("keep_archive", false)),
		}
		_templates_begin_update_continuously()
		fetch.start()
		return {
			"action": "download", "status": "pending",
			"download": _templates_download_snapshot(),
			"poll": "Poll with action='download_status'; cancel with action='download_cancel'."
		}
	# 单连接路径：手写 HTTPS GET（直连或回环代理 CONNECT 隧道）。
	var getter: TemplatesHttpGetter = TemplatesHttpGetter.create(url, part_abs, proxy, 60000)
	root.add_child(getter)

	_template_download = {
		"phase": "downloading",
		"report_status": "pending",
		"mirror": mirror,
		"url": url,
		"part_abs": part_abs,
		"tpz_abs": ProjectSettings.globalize_path(TEMPLATES_DOWNLOAD_DIR.path_join(tpz_filename)),
		"tpz_filename": tpz_filename,
		"getter": getter,
		"started_ms": Time.get_ticks_usec() / 1000,
		"bytes": 0,
		"total_bytes": 0,
		"templates_root": templates_root,
		"version_meta": version_meta.duplicate(true),
		"godot_version": godot_version,
		"proxy": proxy,
		"require_integrity": bool(params.get("require_integrity", false)),
		"keep_archive": bool(params.get("keep_archive", false)),
	}
	getter.progress_cb = Callable(self, "_on_templates_download_progress")
	getter.completed.connect(_on_templates_download_completed)
	_templates_begin_update_continuously()
	getter.start()
	return {
		"action": "download", "status": "pending",
		"download": _templates_download_snapshot(),
		"poll": "Poll with action='download_status'; cancel with action='download_cancel'."
	}

func _templates_download_cleanup_getter(getter: Node) -> void:
	if getter != null and is_instance_valid(getter):
		if getter.is_inside_tree():
			getter.get_parent().remove_child(getter)
		getter.queue_free()

func _on_templates_download_progress(bytes: int, total_bytes: int) -> void:
	if _template_download.is_empty():
		return
	_template_download["bytes"] = bytes
	_template_download["total_bytes"] = total_bytes

# 编辑器失焦/被遮挡/最小化时主循环可能停迭代：节点 _process 停摆会让
# 下载器的裸 StreamPeer 永不推进（连 socket 都不建，探测 60s 空转超时）。
# 下载期间临时开启 update_continuously 强制编辑器持续迭代；终态/取消恢复。
const TEMPLATES_UPDATE_CONTINUOUSLY: String = "interface/editor/update_continuously"

func _templates_begin_update_continuously() -> void:
	if _template_download.has("_uc_prev"):
		return
	var editor_interface: EditorInterface = _get_editor_interface()
	if editor_interface == null:
		return
	var settings: EditorSettings = editor_interface.get_editor_settings()
	if settings == null:
		return
	var prev: bool = false
	if settings.has_setting(TEMPLATES_UPDATE_CONTINUOUSLY):
		prev = bool(settings.get_setting(TEMPLATES_UPDATE_CONTINUOUSLY))
	if not prev:
		settings.set_setting(TEMPLATES_UPDATE_CONTINUOUSLY, true)
		_template_download["_uc_prev"] = false

func _templates_restore_update_continuously() -> void:
	if not _template_download.has("_uc_prev"):
		return
	_template_download.erase("_uc_prev")
	var editor_interface: EditorInterface = _get_editor_interface()
	if editor_interface == null:
		return
	var settings: EditorSettings = editor_interface.get_editor_settings()
	if settings != null:
		settings.set_setting(TEMPLATES_UPDATE_CONTINUOUSLY, false)

func _templates_download_cancel() -> Dictionary:
	if _template_download.is_empty():
		return {"action": "download_cancel", "status": "idle",
			"message": "No template download has been started."}
	var coordinator: Node = _template_download.get("coordinator", null)
	if coordinator != null and is_instance_valid(coordinator) and coordinator.has_method("cancel"):
		# 并行路径：保留目标文件与 .download.json，重启后从断点续传。
		coordinator.call("cancel")
	var getter: Node = _template_download.get("getter", null)
	if getter != null and is_instance_valid(getter) and getter.has_method("_fail"):
		getter.call("_fail", "cancelled")
	_templates_download_cleanup_getter(getter)
	var part_abs: String = String(_template_download.get("part_abs", ""))
	if not part_abs.is_empty():
		DirAccess.remove_absolute(part_abs)
	_templates_restore_update_continuously()
	_template_download = {}
	return {"action": "download_cancel", "status": "cancelled",
		"message": "Template download cancelled; partial file removed."}

func _on_templates_download_completed(outcome: Dictionary) -> void:
	if _template_download.is_empty():
		return
	if not bool(outcome.get("ok", false)):
		var detail: String = String(outcome.get("error", "unknown failure"))
		_templates_download_finish("failed",
			"Download failed (%s). Retry, try another mirror, or check the proxy." % detail,
			false)
		return
	_template_download["phase"] = "verifying"
	await _templates_verify_and_install()

func _templates_download_finish(status: String, message: String, keep_tpz: bool) -> void:
	var state: Dictionary = _template_download
	_templates_restore_update_continuously()
	_templates_download_cleanup_getter(state.get("getter", null))
	var tpz_abs: String = String(state.get("tpz_abs", ""))
	var part_abs: String = String(state.get("part_abs", ""))
	if FileAccess.file_exists(part_abs) and status != "done":
		DirAccess.remove_absolute(part_abs)
	if status != "done" and not keep_tpz and FileAccess.file_exists(tpz_abs):
		DirAccess.remove_absolute(tpz_abs)
	if status == "done" and not String(state.get("state_json", "")).is_empty():
		# 成功后清除断点状态；失败/取消保留以便续传。
		DirAccess.remove_absolute(String(state.get("state_json", "")))
	# 终态保留 result/checksum 供 download_status 轮询读取；"completed" 与
	# 工作流引擎的成功状态词表对齐。
	var finished: Dictionary = {
		"phase": "finished",
		"report_status": "completed" if status == "done" else status,
		"mirror": String(state.get("mirror", "")),
		"url": String(state.get("url", "")),
		"bytes": int(state.get("bytes", 0)),
		"total_bytes": int(state.get("total_bytes", 0)),
		"started_ms": int(state.get("started_ms", 0)),
		"tpz_abs": tpz_abs,
		"error": message if status != "done" else "",
	}
	for carry_key in ["result", "integrity"]:
		if state.has(carry_key):
			finished[carry_key] = state[carry_key]
	_template_download = finished

## 下载完成后：从 GitHub 发布 API 获取官方资产字节数做完整性交叉验证
## （取不到时按 require_integrity 决策），通过后立即解压安装并回报结果。
func _templates_verify_and_install() -> void:
	var state: Dictionary = _template_download
	var tpz_abs: String = String(state.get("tpz_abs", ""))
	var part_abs: String = String(state.get("part_abs", ""))
	var tpz_filename: String = String(state.get("tpz_filename", ""))
	DirAccess.remove_absolute(tpz_abs)
	var rename_error: Error = DirAccess.rename_absolute(part_abs, tpz_abs)
	if rename_error != OK and not FileAccess.file_exists(tpz_abs):
		_templates_download_finish("failed",
			"Downloaded data could not be staged (%s)." % error_string(rename_error), false)
		return

	var expected_size: int = await _templates_fetch_expected_size(
		String(state.get("version_meta", {}).get("version_tag", "")), tpz_filename)
	var integrity_state: String = "unavailable"
	if expected_size > 0:
		var staged_file: FileAccess = FileAccess.open(tpz_abs, FileAccess.READ)
		var actual_size: int = staged_file.get_length() if staged_file != null else -1
		if staged_file != null:
			staged_file.close()
		if actual_size != expected_size:
			_template_download["integrity"] = "size_mismatch"
			_templates_download_finish("failed",
				"Integrity check failed: official asset is %d bytes, download has %d; archive deleted." % [
					expected_size, actual_size], false)
			return
		integrity_state = "size_verified:%d" % expected_size
	elif bool(state.get("require_integrity", false)):
		_template_download["result"] = {"integrity_error": "official asset size unavailable"}
		_templates_download_finish("failed",
			"The GitHub release API was not reachable for integrity metadata; retry, or pass require_integrity=false to accept allowlisted-HTTPS-only verification.",
			true)
		return
	_template_download["integrity"] = integrity_state

	_template_download["phase"] = "installing"
	var install: Dictionary = _install_templates_from_tpz(
		tpz_abs, String(state.get("templates_root", "")),
		state.get("version_meta", {}), String(state.get("godot_version", "")))
	if install.has("error"):
		# 安装失败但档案有效：保留 .tpz 供人工处理，并给出路径。
		_template_download["result"] = {"install_error": String(install["error"])}
		_templates_download_finish("failed",
			"Download %s but installation failed: %s (archive kept at %s)" % [
				integrity_state, String(install["error"]), tpz_abs], true)
		return
	if not bool(state.get("keep_archive", false)):
		DirAccess.remove_absolute(tpz_abs)
	_template_download["result"] = install
	_templates_download_finish("done", "", bool(state.get("keep_archive", false)))

## 从官方发布 API 获取 .tpz 资产的精确字节数；不可达/缺失返回 -1。
func _templates_fetch_expected_size(version_tag: String, tpz_filename: String) -> int:
	var source_url: String = templates_integrity_source_url(version_tag)
	if not is_trusted_templates_url(source_url):
		return -1
	var fetched: Array = await _templates_fetch_text(source_url)
	if not bool(fetched[0]):
		return -1
	return templates_expected_size_from_release_json(String(fetched[1]), tpz_filename)

## 小型 GET（内存态，不落盘）；返回 [ok, text]。直连失败且存在回环代理时自动
## 经代理重试一次（完整性与下载共用同一客户端实现）。
func _templates_fetch_text(url: String) -> Array:
	var root: Node = (Engine.get_main_loop() as SceneTree).root if Engine.get_main_loop() is SceneTree else null
	if root == null:
		return [false, ""]
	for proxy in ["", _templates_download_proxy({})]:
		var getter: TemplatesHttpGetter = TemplatesHttpGetter.create(
			url, "", proxy, 15000, true)
		root.add_child(getter)
		var outcome: Dictionary = await getter.completed
		_templates_download_cleanup_getter(getter)
		if bool(outcome.get("ok", false)):
			return [true, String(outcome.get("text", ""))]
	return [false, ""]

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
	var description: String = "Configure Android options on an existing Android export preset in export_presets.cfg (package name, app name, version code/name, Gradle build, APK/AAB format, SDK levels, architectures, keystore paths). Only sets provided fields; preset platform must be Android. Keystore passwords are NOT written here (set via GODOT_ANDROID_KEYSTORE_* env vars). Godot 4.6+."

	var input_schema: Dictionary = {
		"type": "object",
		"properties": {
			"preset": {"type": "string", "description": "Preset name or section."},
			"config_path": {"type": "string", "description": "Path to export_presets.cfg.", "default": "res://export_presets.cfg"},
			"package_name": {"type": "string", "description": "App id -> package/unique_name."},
			"app_name": {"type": "string", "description": "Display name -> package/name."},
			"version_code": {"type": "integer", "description": "Int version -> version/code."},
			"version_name": {"type": "string", "description": "String version -> version/name."},
			"use_gradle_build": {"type": "boolean", "description": "-> gradle_build/use_gradle_build."},
			"export_format": {"type": "string", "enum": ["apk", "aab"], "description": "-> gradle_build/export_format."},
			"min_sdk": {"type": "string", "description": "-> gradle_build/min_sdk."},
			"target_sdk": {"type": "string", "description": "-> gradle_build/target_sdk."},
			"architectures": {"type": "array", "description": "Enabled archs; rest disabled."},
			"keystore_release": {"type": "string", "description": "-> keystore/release (path only)."},
			"keystore_debug": {"type": "string", "description": "-> keystore/debug (path only)."}
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

# ============================================================================
# undo / redo / get_undo_history - 编辑器 UndoRedo 栈操作
# ============================================================================
# Godot 4.x 的 EditorUndoRedoManager（editor_interface.get_undo_redo()）管理
# 编辑器撤销/重做栈。AI 用 MCP 改场景后，agent 可通过这些工具一键撤销/重做，
# 或查询撤销栈内容决定下一步。

func _get_undo_redo_manager() -> UndoRedo:
	var editor_interface: EditorInterface = _get_editor_interface()
	if not editor_interface:
		return null
	var method_name: String = _first_supported_method(editor_interface, ["get_undo_redo"])
	if method_name == "":
		return null
	return editor_interface.call(method_name) as UndoRedo

# 纯函数：在给定 UndoRedo 上执行撤销，便于单测覆盖（Godot 的 undo() 返回 void，
# 空栈调用无副作用 —— 用 has_undo() 判断何时停止）。
static func _apply_undo_actions(undo_redo: UndoRedo, count: int) -> Dictionary:
	if undo_redo == null:
		return {"error": "UndoRedo not available"}
	if not undo_redo.has_undo():
		return {"status": "noop", "message": "Nothing to undo"}
	var undone_count: int = 0
	var limit: int = maxi(count, 1)
	while undone_count < limit and undo_redo.has_undo():
		undo_redo.undo()
		undone_count += 1
	return {
		"status": "success",
		"undone_count": undone_count,
		"has_undo": undo_redo.has_undo()
	}

static func _apply_redo_actions(undo_redo: UndoRedo, count: int) -> Dictionary:
	if undo_redo == null:
		return {"error": "UndoRedo not available"}
	if not undo_redo.has_redo():
		return {"status": "noop", "message": "Nothing to redo"}
	var redone_count: int = 0
	var limit: int = maxi(count, 1)
	while redone_count < limit and undo_redo.has_redo():
		undo_redo.redo()
		redone_count += 1
	return {
		"status": "success",
		"redone_count": redone_count,
		"has_redo": undo_redo.has_redo()
	}

# 纯函数：生成撤销栈摘要。UndoRedo 语义：get_current_action() 指向下一个可撤销
# 的动作（无动作时为 -1），get_history_count() 为栈内总动作数。可撤销数 = current+1，
# 可重做数 = total-(current+1)。动作名列表按“最近优先”排列，受 limit 截断。
static func _describe_undo_history(undo_redo: UndoRedo, limit: int) -> Dictionary:
	if undo_redo == null:
		return {"error": "UndoRedo not available"}
	var total_actions: int = undo_redo.get_history_count()
	var current_action: int = undo_redo.get_current_action()
	var undo_count: int = current_action + 1
	var redo_count: int = maxi(total_actions - (current_action + 1), 0)
	var max_items: int = maxi(limit, 1)
	var undo_actions: Array = []
	var redo_actions: Array = []
	for i in range(current_action, -1, -1):
		if undo_actions.size() >= max_items:
			break
		undo_actions.append({"name": str(undo_redo.get_action_name(i))})
	for i in range(current_action + 1, total_actions):
		if redo_actions.size() >= max_items:
			break
		redo_actions.append({"name": str(undo_redo.get_action_name(i))})
	return {
		"undo_count": undo_count,
		"redo_count": redo_count,
		"can_undo": undo_redo.has_undo(),
		"can_redo": undo_redo.has_redo(),
		"undo_actions": undo_actions,
		"redo_actions": redo_actions
	}

func _register_undo(server_core: RefCounted) -> void:
	var tool_name: String = "undo"
	var description: String = "Undo the most recent editor action(s). Each editor UndoRedo action typically bundles one scene edit (node create/delete, property change, tile paint) — undo() pops the latest undoable action and restores the previous state. Pass count to undo several actions at once; the loop stops when the undo stack is empty. Returns status 'noop' with message 'Nothing to undo' when the stack is empty."

	var input_schema: Dictionary = {
		"type": "object",
		"properties": {
			"count": {
				"type": "integer",
				"description": "Number of actions to undo. Default 1.",
				"default": 1
			}
		}
	}

	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"status": {"type": "string"},
			"undone_count": {"type": "integer"},
			"has_undo": {"type": "boolean"},
			"message": {"type": "string"}
		}
	}

	var annotations: Dictionary = {
		"readOnlyHint": false,
		"destructiveHint": false,
		"idempotentHint": false,
		"openWorldHint": false
	}

	server_core.register_tool(tool_name, description, input_schema,
		Callable(self, "_tool_undo"),
		output_schema, annotations,
		"supplementary", "Editor-Advanced")

func _tool_undo(params: Dictionary) -> Dictionary:
	var count: int = int(params.get("count", 1))
	if count < 1:
		return {"error": "count must be a positive integer"}
	var editor_interface: EditorInterface = _get_editor_interface()
	if not editor_interface:
		return {"error": "Editor interface not available"}
	var undo_redo: UndoRedo = _get_undo_redo_manager()
	if undo_redo == null:
		return {"error": "Editor UndoRedo not available"}
	return _apply_undo_actions(undo_redo, count)

func _register_redo(server_core: RefCounted) -> void:
	var tool_name: String = "redo"
	var description: String = "Redo the most recently undone editor action(s). Each redo re-applies the next action from the editor's redo stack. Pass count to redo several actions at once; the loop stops when the redo stack is empty. Returns status 'noop' with message 'Nothing to redo' when the stack is empty."

	var input_schema: Dictionary = {
		"type": "object",
		"properties": {
			"count": {
				"type": "integer",
				"description": "Number of actions to redo. Default 1.",
				"default": 1
			}
		}
	}

	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"status": {"type": "string"},
			"redone_count": {"type": "integer"},
			"has_redo": {"type": "boolean"},
			"message": {"type": "string"}
		}
	}

	var annotations: Dictionary = {
		"readOnlyHint": false,
		"destructiveHint": false,
		"idempotentHint": false,
		"openWorldHint": false
	}

	server_core.register_tool(tool_name, description, input_schema,
		Callable(self, "_tool_redo"),
		output_schema, annotations,
		"supplementary", "Editor-Advanced")

func _tool_redo(params: Dictionary) -> Dictionary:
	var count: int = int(params.get("count", 1))
	if count < 1:
		return {"error": "count must be a positive integer"}
	var editor_interface: EditorInterface = _get_editor_interface()
	if not editor_interface:
		return {"error": "Editor interface not available"}
	var undo_redo: UndoRedo = _get_undo_redo_manager()
	if undo_redo == null:
		return {"error": "Editor UndoRedo not available"}
	return _apply_redo_actions(undo_redo, count)

func _register_get_undo_history(server_core: RefCounted) -> void:
	var tool_name: String = "get_undo_history"
	var description: String = "Read-only summary of the editor's UndoRedo stack: how many actions can be undone and redone, plus the names of the most recent undoable and redoable actions (most recent first, capped by 'limit' which defaults to 20)."

	var input_schema: Dictionary = {
		"type": "object",
		"properties": {
			"limit": {
				"type": "integer",
				"description": "Maximum number of action names to list per direction. Default 20.",
				"default": 20
			}
		}
	}

	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"undo_count": {"type": "integer"},
			"redo_count": {"type": "integer"},
			"can_undo": {"type": "boolean"},
			"can_redo": {"type": "boolean"},
			"undo_actions": {"type": "array", "items": {"type": "object"}},
			"redo_actions": {"type": "array", "items": {"type": "object"}}
		}
	}

	var annotations: Dictionary = {
		"readOnlyHint": true,
		"destructiveHint": false,
		"idempotentHint": true,
		"openWorldHint": false
	}

	server_core.register_tool(tool_name, description, input_schema,
		Callable(self, "_tool_get_undo_history"),
		output_schema, annotations,
		"supplementary", "Editor-Advanced")

func _tool_get_undo_history(params: Dictionary) -> Dictionary:
	var limit: int = int(params.get("limit", 20))
	if limit < 1:
		return {"error": "limit must be a positive integer"}
	var editor_interface: EditorInterface = _get_editor_interface()
	if not editor_interface:
		return {"error": "Editor interface not available"}
	var undo_redo: UndoRedo = _get_undo_redo_manager()
	if undo_redo == null:
		return {"error": "Editor UndoRedo not available"}
	return _describe_undo_history(undo_redo, limit)
