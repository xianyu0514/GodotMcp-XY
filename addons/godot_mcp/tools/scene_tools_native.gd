# scene_tools_native.gd - Scene Tools原生实现
# 根据godot-dev-guide添加完整的类型提示
# 根据mcp-builder添加outputSchema和annotations

@tool
class_name SceneToolsNative
extends RefCounted

const VIBE_CODING_POLICY = preload("res://addons/godot_mcp/utils/vibe_coding_policy.gd")
const SCENE_CONTEXT = preload("res://addons/godot_mcp/utils/scene_context.gd")
const ChangeJournalScript = preload("res://addons/godot_mcp/tools/change_journal.gd")

var _editor_interface: EditorInterface = null
var _scene_operation_in_progress: bool = false

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

func _is_vibe_coding_mode() -> bool:
	if Engine.has_meta("GodotMCPPlugin"):
		var plugin = Engine.get_meta("GodotMCPPlugin")
		if plugin and plugin.get("vibe_coding_mode") != null:
			return bool(plugin.vibe_coding_mode)
	return true

func _get_user_scene_root() -> Node:
	return SCENE_CONTEXT.get_edited_user_scene_root(_get_editor_interface())

# ============================================================================
# 工具注册
# ============================================================================

func register_tools(server_core: RefCounted) -> void:
	# 注册create_scene工具
	_register_create_scene(server_core)
	
	# 注册save_scene工具
	_register_save_scene(server_core)
	
	# 注册open_scene工具
	_register_open_scene(server_core)
	
	# 注册get_current_scene工具
	_register_get_current_scene(server_core)
	
	# 注册get_scene_structure工具
	_register_get_scene_structure(server_core)
	
	# 注册list_project_scenes工具
	_register_list_project_scenes(server_core)
	_register_list_open_scenes(server_core)
	_register_close_scene_tab(server_core)
	_register_instantiate_scene(server_core)
	_register_save_branch_as_scene(server_core)
	_register_set_tilemap_layer_cells(server_core)
	_register_get_tilemap_layer_cells(server_core)
	_register_batch_update_scene_files(server_core)
	_register_create_scene_variant(server_core)
	_register_create_navigation_region(server_core)

# ============================================================================
# create_scene - 创建新场�?
# ============================================================================

func _register_create_scene(server_core: RefCounted) -> void:
	var tool_name: String = "create_scene"
	var description: String = "Create a new Godot scene with a root node. The scene is saved to the specified path."
	
	# inputSchema
	var input_schema: Dictionary = {
		"type": "object",
		"properties": {
			"scene_path": {
				"type": "string",
				"description": "Path where the scene will be saved (e.g. 'res://scenes/NewScene.tscn')"
			},
			"root_node_type": {
				"type": "string",
				"description": "Type of the root node (e.g. 'Node3D', 'Node2D', 'Control'). Default is 'Node'.",
				"default": "Node"
			}
		},
		"required": ["scene_path"]
	}
	
	# outputSchema
	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"status": {"type": "string"},
			"scene_path": {"type": "string"},
			"open_after_create": {"type": "boolean", "default": true, "description": "Open the new scene as the active edited scene immediately (saves an open_scene call). Default true; false keeps the old write-only behavior."},
			"root_node_type": {"type": "string"}
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
						  Callable(self, "_tool_create_scene"),
						  output_schema, annotations,
						  "core", "Scene")

func _tool_create_scene(params: Dictionary) -> Dictionary:
	# 参数提取
	var scene_path: String = params.get("scene_path", "")
	var root_node_type: String = params.get("root_node_type", "Node")
	
	# 参数验证
	if scene_path.is_empty():
		return {"error": "Missing required parameter: scene_path"}
	
	# 使用PathValidator验证路径安全�?
	var validation: Dictionary = PathValidator.validate_file_path(scene_path, [".tscn"])
	if not validation["valid"]:
		return {"error": "Invalid path: " + validation["error"]}
	
	# 使用清理后的路径
	scene_path = validation["sanitized"]
	
	# 验证节点类型
	if not ClassDB.class_exists(root_node_type):
		return {"error": "Invalid node type: " + root_node_type}
	
	# 创建根节�?
	var root_node: Node = ClassDB.instantiate(root_node_type)
	root_node.name = scene_path.get_file().get_basename()
	
	# 创建PackedScene
	var packed_scene: PackedScene = PackedScene.new()
	
	# 设置owner并打�?
	root_node.owner = root_node  # 临时设置
	packed_scene.pack(root_node)
	
	# 保存场景
	# 目标目录不存在时先创建（工作流按 profile 推导的 res://scenes/ 等新目录）。
	var parent_dir: String = scene_path.get_base_dir()
	if parent_dir != "res://" and not parent_dir.is_empty():
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(parent_dir))

	var before_hash: String = ChangeJournalScript.file_sha256(scene_path)
	# Q1 累积性：场景已存在时不覆盖——返回 existing 状态，调用方可继续
	# 在其上叠加（目标 B 的金币/敌人/墙进入目标 A 的场景，而非重建）。
	if FileAccess.file_exists(scene_path):
		root_node.free()
		# 累积模式：打开既有场景，让后续 attach/save 操作作用于它
		var editor_interface: EditorInterface = _get_editor_interface()
		if editor_interface:
			var loaded: PackedScene = load(scene_path)
			if loaded is PackedScene:
				editor_interface.open_scene_from_path(scene_path)
		return {
			"status": "existing",
			"scene_path": scene_path,
			"root_node_type": root_node_type,
			"note": "scene already exists; opened for accumulation"
		}
	var error: Error = ResourceSaver.save(packed_scene, scene_path)
	
	# 清理
	root_node.free()
	
	if error != OK:
		return {"error": "Failed to save scene: " + error_string(error)}
	
	ChangeJournalScript.record_write_operation("create_scene " + scene_path,
		scene_path, before_hash, ChangeJournalScript.file_sha256(scene_path), true)
	var response: Dictionary = {
		"status": "success",
		"scene_path": scene_path,
		"root_node_type": root_node_type
	}
	if bool(params.get("open_after_create", true)):
		var opener: EditorInterface = _get_editor_interface()
		if opener:
			# 用带确认的打开（注册 + 有限重试 + 连续帧稳定确认）：冷启动期间
			# 裸 open_scene_from_path 可能被编辑器恢复上次会话布局覆盖（CI
			# 实测：audit 测试在全新 checkout 上偶发回到 TestScene.tscn）。
			var opened_root: Node = await SCENE_CONTEXT.open_scene_and_wait(
				opener, scene_path)
			response["opened"] = opened_root != null
			if opened_root == null:
				response["open_note"] = "open unconfirmed during editor startup; call open_scene next"
		else:
			response["opened"] = false
			response["open_note"] = "editor interface unavailable; call open_scene next"
	return response

# ============================================================================
# save_scene - 保存当前场景
# ============================================================================

func _register_save_scene(server_core: RefCounted) -> void:
	var tool_name: String = "save_scene"
	var description: String = "Save the current scene to disk. If no path is provided, saves to the current scene's path."
	
	# inputSchema
	var input_schema: Dictionary = {
		"type": "object",
		"properties": {
			"scene_path": {"type": "string", "description": "Optional: ensure THIS scene is the active edited scene before saving (auto-activated; guards cross-scene drift). file_path is the destination on disk."},
			"file_path": {
				"type": "string",
				"description": "Optional path to save the scene (e.g. 'res://scenes/MyScene.tscn'). If not provided, uses current scene path."
			}
		}
	}
	
	# outputSchema
	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"status": {"type": "string"},
			"saved_path": {"type": "string"},
			"operation": {"type": "string", "description": "'save' for same-path save, 'save_as' for different-path export"}
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
						  Callable(self, "_tool_save_scene"),
						  output_schema, annotations,
						  "core", "Scene")

func _tool_save_scene(params: Dictionary) -> Dictionary:
	if _scene_operation_in_progress:
		return {"error": "Scene operation in progress, please retry"}

	var editor_interface: EditorInterface = _get_editor_interface()
	if not editor_interface:
		return {"error": "Editor interface not available"}

	# Optional scene_path pins WHICH scene is saved (guards cross-scene drift);
	# file_path below is the destination on disk.
	var context_guard: Dictionary = await SCENE_CONTEXT.ensure_scene_active(
		editor_interface, String(params.get("scene_path", "")))
	if not bool(context_guard.get("ok", false)):
		return {"error": String(context_guard.get("error", "scene context guard failed"))}

	var scene_root: Node = _get_user_scene_root()
	if not scene_root:
		return {"error": "No scene is currently open"}

	var file_path: String = params.get("file_path", "")

	if file_path.is_empty():
		# Use current scene path
		var current_scene_path: String = scene_root.scene_file_path
		if current_scene_path.is_empty():
			return {"error": "Scene has no file path. Please provide a file_path parameter."}
		file_path = current_scene_path

	# Validate and sanitize path
	var validation: Dictionary = PathValidator.validate_file_path(file_path, [".tscn"])
	if not validation["valid"]:
		return {"error": "Invalid path: " + validation["error"]}

	file_path = validation["sanitized"]

	# Detect save-as: target path differs from current scene path
	var current_path: String = scene_root.scene_file_path
	var is_save_as: bool = not current_path.is_empty() and current_path != file_path

	# Pack the scene tree
	var packed_scene: PackedScene = PackedScene.new()
	var error: Error = packed_scene.pack(scene_root)

	if error != OK:
		return {"error": "Failed to pack scene: " + error_string(error)}

	# Save to file（写入前后指纹进变更日志：崩溃后可判定磁盘实况）
	var before_hash: String = ChangeJournalScript.file_sha256(file_path)
	error = ResourceSaver.save(packed_scene, file_path)

	if error != OK:
		return {"error": "Failed to save scene: " + error_string(error)}

	var after_hash: String = ChangeJournalScript.file_sha256(file_path)
	var journal_result: Dictionary = ChangeJournalScript.record_write_operation(
		"save_scene " + file_path, file_path, before_hash, after_hash,
		not after_hash.is_empty())
	var journaled: Dictionary = {
		"status": "success",
		"saved_path": file_path,
		"operation": "save_as" if is_save_as else "save"
	}
	if journal_result.has("operation"):
		journaled["change_journal"] = {
			"operation_id": journal_result["operation"].get("operation_id", ""),
			"verified": true,
		}
	return journaled

# ============================================================================
# open_scene - 打开场景
# ============================================================================

func _register_open_scene(server_core: RefCounted) -> void:
	var tool_name: String = "open_scene"
	var description: String = "Open a scene file from the project. Closes the current scene if one is open."
	
	# inputSchema
	var input_schema: Dictionary = {
		"type": "object",
		"properties": {
			"scene_path": {
				"type": "string",
				"description": "Path to the scene file to open (e.g. 'res://scenes/Main.tscn')"
			},
			"allow_ui_focus": {
				"type": "boolean",
				"description": "Allow this call to change the active editor scene when Vibe Coding mode is enabled.",
				"default": false
			}
		},
		"required": ["scene_path"]
	}
	
	# outputSchema
	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"status": {"type": "string"},
			"scene_path": {"type": "string"},
			"root_node_type": {"type": "string"},
			"verification_tip": {"type": "string"}
		}
	}
	
	# annotations
	var annotations: Dictionary = {
		"readOnlyHint": false,
		"destructiveHint": true,  # will close current scene
		"idempotentHint": false,
		"openWorldHint": false
	}
	
	# register tool
	server_core.register_tool(tool_name, description, input_schema,
						  Callable(self, "_tool_open_scene"),
						  output_schema, annotations,
						  "core", "Scene")

func _tool_open_scene(params: Dictionary) -> Dictionary:
	var policy_result: Dictionary = VIBE_CODING_POLICY.evaluate_editor_focus(_is_vibe_coding_mode(), params)
	if policy_result.get("blocked", false):
		return policy_result

	if _scene_operation_in_progress:
		return {"error": "Scene operation in progress, please retry"}
	_scene_operation_in_progress = true
	
	var scene_path: String = params.get("scene_path", "")
	
	if scene_path.is_empty():
		_scene_operation_in_progress = false
		return {"error": "Missing required parameter: scene_path"}
	
	var validation: Dictionary = PathValidator.validate_file_path(scene_path, [".tscn"])
	if not validation["valid"]:
		_scene_operation_in_progress = false
		return {"error": "Invalid path: " + validation["error"]}
	
	scene_path = validation["sanitized"]
	
	if not FileAccess.file_exists(scene_path):
		_scene_operation_in_progress = false
		return {"error": "Scene file not found: " + scene_path}
	
	var editor_interface: EditorInterface = _get_editor_interface()
	if not editor_interface:
		_scene_operation_in_progress = false
		return {"error": "Editor interface not available"}

	# Idempotent: re-opening the scene that is already being edited would
	# discard unsaved state for no benefit.
	var active_root: Node = _get_user_scene_root()
	if active_root and String(active_root.scene_file_path) == scene_path:
		_scene_operation_in_progress = false
		return {
			"status": "success",
			"scene_path": scene_path,
			"already_open": true,
			"scene_name": String(active_root.name),
			"root_node_type": String(active_root.get_class())
		}

	# 新保存的场景可能尚未进入 EditorFileSystem，open_scene_from_path 会
	# 静默失败；统一屏障负责登记、有限重试和连续帧稳定确认。
	var scene_root: Node = await SCENE_CONTEXT.open_scene_and_wait(
		editor_interface, scene_path)
	if not scene_root:
		_scene_operation_in_progress = false
		return {"error": "Failed to open scene: " + scene_path}
	var root_type: String = scene_root.get_class()

	_scene_operation_in_progress = false
	return {
		"status": "success",
		"scene_path": scene_path,
		"root_node_type": root_type,
		"verification_tip": "Call get_editor_logs(source='editor_panel', type=['Error']) to check for scene loading errors. Then call get_current_scene() to confirm the correct scene is active."
	}

# ============================================================================
# get_current_scene - 获取当前场景信息
# ============================================================================

func _register_get_current_scene(server_core: RefCounted) -> void:
	var tool_name: String = "get_current_scene"
	var description: String = "Get information about the currently open scene, including name, path, and root node type."
	
	# inputSchema
	var input_schema: Dictionary = {
		"type": "object",
		"properties": {}
	}
	
	# outputSchema
	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"scene_name": {"type": "string"},
			"scene_path": {"type": "string"},
			"root_node_type": {"type": "string"},
			"node_count": {"type": "integer"},
			"is_modified": {"type": "boolean"}
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
						  Callable(self, "_tool_get_current_scene"),
						  output_schema, annotations,
						  "core", "Scene")

func _tool_get_current_scene(params: Dictionary) -> Dictionary:
	var editor_interface: EditorInterface = _get_editor_interface()
	if not editor_interface:
		return {"error": "Editor interface not available"}
	
	# 获取当前场景根节�?
	var scene_root: Node = _get_user_scene_root()
	
	if not scene_root:
		return {"error": "No scene is currently open"}
	
	# 获取场景信息
	var scene_name: String = scene_root.name
	var scene_path: String = scene_root.scene_file_path
	var root_node_type: String = scene_root.get_class()
	var node_count: int = _count_nodes(scene_root)
	
	var is_modified: bool = false
	var undo_redo_mgr: EditorUndoRedoManager = editor_interface.get_editor_undo_redo()
	if undo_redo_mgr and scene_root:
		var history_id: int = undo_redo_mgr.get_object_history_id(scene_root)
		var undo_redo: UndoRedo = undo_redo_mgr.get_history_undo_redo(history_id)
		if undo_redo:
			is_modified = undo_redo.has_undo()
	
	return {
		"scene_name": scene_name,
		"scene_path": scene_path,
		"root_node_type": root_node_type,
		"node_count": node_count,
		"is_modified": is_modified
	}

# ============================================================================
# get_scene_structure - 获取场景树结�?
# ============================================================================

func _register_get_scene_structure(server_core: RefCounted) -> void:
	var tool_name: String = "get_scene_structure"
	var description: String = "Get the complete structure of the current scene as a tree. Returns node types, names, and hierarchy."
	
	# inputSchema
	var input_schema: Dictionary = {
		"type": "object",
		"properties": {
			"max_depth": {
				"type": "integer",
				"description": "Maximum depth to traverse. -1 means no limit."
			}
		}
	}
	
	# outputSchema
	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"scene_name": {"type": "string"},
			"root_node": {"type": "object"},
			"total_nodes": {"type": "integer"}
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
						  Callable(self, "_tool_get_scene_structure"),
						  output_schema, annotations,
						  "supplementary", "Scene-Advanced")

func _tool_get_scene_structure(params: Dictionary) -> Dictionary:
	var max_depth: int = params.get("max_depth", -1)
	
	var editor_interface: EditorInterface = _get_editor_interface()
	if not editor_interface:
		return {"error": "Editor interface not available"}
	
	# 获取场景根节�?
	var scene_root: Node = _get_user_scene_root()
	if not scene_root:
		return {"error": "No scene is currently open"}
	
	# 构建场景结构（一次遍历同时得到树与可见节点数，避免默认情况下二次 _count_nodes 遍历）
	var built: Dictionary = _build_node_tree_with_count(scene_root, 0, max_depth, scene_root)
	# max_depth 截断时 built["count"] 只统计可见部分的节点，而 total_nodes
	# 的语义是完整场景节点总数，此时回退到全量统计。
	var total_nodes: int = built["count"] if max_depth < 0 else _count_nodes(scene_root)
	var scene_structure: Dictionary = {
		"scene_name": scene_root.name,
		"root_node": built["tree"],
		"total_nodes": total_nodes
	}
	
	return scene_structure

# 辅助函数：递归构建节点�?
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

static func _build_node_tree(node: Node, current_depth: int, max_depth: int, scene_root: Node = null) -> Dictionary:
	return _build_node_tree_with_count(node, current_depth, max_depth, scene_root)["tree"]

## 单次遍历构建节点树并统计已展开部分的节点数；max_depth 截断时 count
## 只包含可见节点，不包含被 children_truncated 隐藏的子树。返回 {"tree": Dictionary, "count": int}。
static func _build_node_tree_with_count(node: Node, current_depth: int, max_depth: int, scene_root: Node = null) -> Dictionary:
	var node_info: Dictionary = {
		"name": node.name,
		"type": node.get_class(),
		"path": _make_friendly_path(node, scene_root),
		"children": []
	}
	var count: int = 1  # 当前节点
	
	# 检查是否达到最大深�?
	if max_depth >= 0 and current_depth >= max_depth:
		node_info["children_truncated"] = true
		return {"tree": node_info, "count": count}
	
	# 递归处理子节�?
	for child_index in range(node.get_child_count()):
		var child: Node = node.get_child(child_index)
		var child_result: Dictionary = _build_node_tree_with_count(child, current_depth + 1, max_depth, scene_root)
		node_info["children"].append(child_result["tree"])
		count += int(child_result["count"])
	
	return {"tree": node_info, "count": count}

# 辅助函数：计算节点总数
static func _count_nodes(node: Node) -> int:
	var count: int = 1  # 当前节点
	
	for child_index in range(node.get_child_count()):
		var child: Node = node.get_child(child_index)
		count += _count_nodes(child)
	
	return count

# ============================================================================
# list_project_scenes - 列出项目中的所有场�?
# ============================================================================

func _register_list_project_scenes(server_core: RefCounted) -> void:
	var tool_name: String = "list_project_scenes"
	var description: String = "List all scene files (.tscn) in the project. Returns paths relative to res://."
	
	# inputSchema
	var input_schema: Dictionary = {
		"type": "object",
		"properties": {
			"search_path": {
				"type": "string",
				"description": "Optional subpath to search (e.g. 'res://scenes/'). Default is 'res://'.",
				"default": "res://"
			},
			"limit": {
				"type": "integer",
				"description": "Maximum number of scene paths to return. Default is 1000. Extra paths are omitted and 'truncated' is set true."
			},
			"offset": {
				"type": "integer",
				"description": "Number of scene paths to skip before applying limit. Default 0."
			}
		}
	}
	
	# outputSchema
	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"scenes": {
				"type": "array",
				"items": {"type": "string"}
			},
			"count": {"type": "integer"},
			"total_count": {"type": "integer"},
			"truncated": {"type": "boolean"}
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
						  Callable(self, "_tool_list_project_scenes"),
						  output_schema, annotations,
						  "supplementary", "Scene-Advanced")

func _tool_list_project_scenes(params: Dictionary) -> Dictionary:
	# 参数提取
	var search_path: String = params.get("search_path", "res://")
	
	# 使用PathValidator验证路径安全�?
	var validation: Dictionary = PathValidator.validate_directory_path(search_path)
	if not validation["valid"]:
		return {"error": "Invalid path: " + validation["error"]}
	
	# 使用清理后的路径
	search_path = validation["sanitized"]
	
	# 转换为文件系统路�?
	var fs_path: String = search_path
	
	var limit: int = int(params.get("limit", 1000))
	if limit <= 0:
		limit = 1000
	var offset: int = int(params.get("offset", 0))
	
	# 使用DirAccess递归查找所�?tscn文件
	var collected: Array[String] = []
	_collect_scenes(fs_path, collected)
	
	# 排序
	collected.sort()
	
	var page: Dictionary = PayloadUtils.paginate_list(collected, limit, offset)
	var scenes: Array = page["items"]
	
	return {
		"scenes": scenes,
		"count": scenes.size(),
		"total_count": page["total_count"],
		"truncated": page["truncated"]
	}

# ============================================================================
# list_open_scenes - 列出当前已打开的场景 tab
# ============================================================================

func _register_list_open_scenes(server_core: RefCounted) -> void:
	var tool_name: String = "list_open_scenes"
	var description: String = "List scene tabs currently open in the Godot editor."

	var input_schema: Dictionary = {
		"type": "object",
		"properties": {}
	}

	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"active_scene": {"type": "string"},
			"count": {"type": "integer"},
			"open_scenes": {"type": "array"}
		}
	}

	var annotations: Dictionary = {
		"readOnlyHint": true,
		"destructiveHint": false,
		"idempotentHint": true,
		"openWorldHint": false
	}

	server_core.register_tool(tool_name, description, input_schema,
						  Callable(self, "_tool_list_open_scenes"),
						  output_schema, annotations,
						  "supplementary", "Scene-Advanced")

func _tool_list_open_scenes(params: Dictionary) -> Dictionary:
	var editor_interface: EditorInterface = _get_editor_interface()
	if not editor_interface:
		return {"error": "Editor interface not available"}

	var open_scene_paths: PackedStringArray = editor_interface.get_open_scenes()
	var open_scene_roots: Array = editor_interface.get_open_scene_roots()
	var active_root: Node = editor_interface.get_edited_scene_root()
	var active_scene_path: String = active_root.scene_file_path if active_root else ""

	var open_scenes: Array = []
	for i in range(open_scene_paths.size()):
		var scene_path: String = str(open_scene_paths[i])
		var root_name: String = ""
		var root_type: String = ""
		if i < open_scene_roots.size():
			var root_node: Node = open_scene_roots[i]
			if root_node:
				root_name = root_node.name
				root_type = root_node.get_class()
		open_scenes.append({
			"index": i,
			"scene_path": scene_path,
			"root_name": root_name,
			"root_type": root_type,
			"is_active": scene_path == active_scene_path
		})

	return {
		"active_scene": active_scene_path,
		"count": open_scenes.size(),
		"open_scenes": open_scenes
	}

# ============================================================================
# close_scene_tab - 关闭当前或指定场景 tab
# ============================================================================

func _register_close_scene_tab(server_core: RefCounted) -> void:
	var tool_name: String = "close_scene_tab"
	var description: String = "Close the active scene tab, or activate a specified scene tab and close it."

	var input_schema: Dictionary = {
		"type": "object",
		"properties": {
			"scene_path": {
				"type": "string",
				"description": "Optional scene path to close. If omitted, closes the currently active scene."
			},
			"allow_ui_focus": {
				"type": "boolean",
				"description": "Allow this call to activate or close editor scene tabs when Vibe Coding mode is enabled.",
				"default": false
			}
		}
	}

	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"status": {"type": "string"},
			"closed_scene": {"type": "string"},
			"remaining_count": {"type": "integer"}
		}
	}

	var annotations: Dictionary = {
		"readOnlyHint": false,
		"destructiveHint": true,
		"idempotentHint": false,
		"openWorldHint": false
	}

	server_core.register_tool(tool_name, description, input_schema,
						  Callable(self, "_tool_close_scene_tab"),
						  output_schema, annotations,
						  "supplementary", "Scene-Advanced")

func _tool_close_scene_tab(params: Dictionary) -> Dictionary:
	var policy_result: Dictionary = VIBE_CODING_POLICY.evaluate_editor_focus(_is_vibe_coding_mode(), params)
	if policy_result.get("blocked", false):
		return policy_result

	var editor_interface: EditorInterface = _get_editor_interface()
	if not editor_interface:
		return {"error": "Editor interface not available"}

	var scene_path: String = str(params.get("scene_path", "")).strip_edges()
	if not scene_path.is_empty():
		var validation: Dictionary = PathValidator.validate_file_path(scene_path, [".tscn"])
		if not validation["valid"]:
			return {"error": "Invalid path: " + validation["error"]}
		scene_path = validation["sanitized"]

		var open_scene_paths: PackedStringArray = editor_interface.get_open_scenes()
		if not open_scene_paths.has(scene_path):
			return {"error": "Scene is not currently open: " + scene_path}
		# 先把目标稳定激活再 close，否则过渡帧可能关掉另一个场景。
		var pending_root: Node = await SCENE_CONTEXT.open_scene_and_wait(
			editor_interface, scene_path)
		if not pending_root:
			return {"error": "Failed to activate scene before closing: " + scene_path}

	var active_root: Node = SCENE_CONTEXT.get_edited_user_scene_root(editor_interface)
	var closed_scene: String = active_root.scene_file_path if active_root else scene_path
	var close_error: Error = editor_interface.close_scene()
	if close_error != OK:
		return {"error": "Failed to close scene: " + error_string(close_error)}

	return {
		"status": "success",
		"closed_scene": closed_scene,
		"remaining_count": editor_interface.get_open_scenes().size()
	}

# ============================================================================
# instantiate_scene - Instance an existing .tscn as a child of a scene node
# ============================================================================

func _register_instantiate_scene(server_core: RefCounted) -> void:
	var tool_name: String = "instantiate_scene"
	var description: String = "Instance an existing scene file (.tscn) as a child of a node in the currently edited scene. Useful for placing prefabs such as card UIs or enemy instances into the scene tree."

	# inputSchema
	var input_schema: Dictionary = {
		"type": "object",
		"properties": {
			"scene_path": {
				"type": "string",
				"description": "Path to the scene file to instance (e.g. 'res://scenes/Card.tscn')."
			},
			"parent_path": {
				"type": "string",
				"description": "Path to the parent node in the edited scene (e.g. '/root/Main/HandContainer'). Defaults to the scene root."
			},
			"instance_name": {
				"type": "string",
				"description": "Optional name for the instanced node. Defaults to the scene file's base name."
			}
		},
		"required": ["scene_path"]
	}

	# outputSchema
	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"status": {"type": "string"},
			"scene_path": {"type": "string"},
			"instance_path": {"type": "string"},
			"node_type": {"type": "string"}
		}
	}

	# annotations
	var annotations: Dictionary = {
		"readOnlyHint": false,
		"destructiveHint": false,
		"idempotentHint": false,
		"openWorldHint": false
	}

	server_core.register_tool(tool_name, description, input_schema,
						  Callable(self, "_tool_instantiate_scene"),
						  output_schema, annotations,
						  "supplementary", "Scene-Advanced")

func _tool_instantiate_scene(params: Dictionary) -> Dictionary:
	var scene_path: String = str(params.get("scene_path", "")).strip_edges()
	var parent_path: String = str(params.get("parent_path", "")).strip_edges()
	var instance_name: String = str(params.get("instance_name", "")).strip_edges()

	# Parameter validation (runs before editor access so it is testable headless)
	if scene_path.is_empty():
		return {"error": "Missing required parameter: scene_path"}

	var validation: Dictionary = PathValidator.validate_file_path(scene_path, [".tscn"])
	if not validation["valid"]:
		return {"error": "Invalid path: " + validation["error"]}
	scene_path = validation["sanitized"]

	if not ResourceLoader.exists(scene_path):
		return {"error": "Scene file not found: " + scene_path}

	var editor_interface: EditorInterface = _get_editor_interface()
	if not editor_interface:
		return {"error": "Editor interface not available"}

	var scene_root: Node = _get_user_scene_root()
	if not scene_root:
		return {"error": "No scene is currently open"}

	# Resolve the parent node; default to the scene root.
	var parent: Node = scene_root
	if not parent_path.is_empty():
		parent = _resolve_node_path(parent_path)
		if not parent:
			return {"error": "Parent node not found: " + parent_path
				+ NodeToolsNative._suggest_parent_path(scene_root, parent_path)}

	# Load and instance the packed scene.
	var packed_scene: PackedScene = ResourceLoader.load(scene_path) as PackedScene
	if not packed_scene:
		return {"error": "Failed to load scene as PackedScene: " + scene_path}

	var instance: Node = packed_scene.instantiate()
	if not instance:
		return {"error": "Failed to instantiate scene: " + scene_path}

	if not instance_name.is_empty():
		instance.name = instance_name

	# Traverse the parent chain to find the correct owner for nested/instanced scenes.
	var correct_owner: Node = scene_root
	if scene_root and parent != scene_root:
		var current: Node = parent
		while current and current != scene_root:
			if current.owner and current.owner != scene_root and current.owner != current:
				correct_owner = current.owner
				break
			current = current.get_parent()

	# Wrap in EditorUndoRedoManager so the editor tracks the change.
	var undo_redo: EditorUndoRedoManager = editor_interface.get_editor_undo_redo()
	if undo_redo:
		undo_redo.create_action("Instantiate Scene: " + scene_path.get_file())
		undo_redo.add_do_method(parent, "add_child", instance)
		undo_redo.add_do_method(instance, "set_owner", correct_owner)
		undo_redo.add_undo_method(parent, "remove_child", instance)
		undo_redo.commit_action()
	else:
		parent.add_child(instance)
		if correct_owner:
			instance.owner = correct_owner

	editor_interface.mark_scene_as_unsaved()

	# Build a friendly /root-relative path for the new instance.
	var instance_friendly: String = str(instance.get_path())
	var root_full: String = str(scene_root.get_path())
	if instance_friendly.begins_with(root_full):
		instance_friendly = "/root/" + scene_root.name + instance_friendly.substr(root_full.length())

	return {
		"status": "success",
		"scene_path": scene_path,
		"instance_path": instance_friendly,
		"node_type": instance.get_class()
	}

# ============================================================================
# save_branch_as_scene - Save a node subtree as a reusable .tscn file
# ============================================================================

func _register_save_branch_as_scene(server_core: RefCounted) -> void:
	var tool_name: String = "save_branch_as_scene"
	var description: String = "Save a node and all of its descendants from the currently edited scene as a reusable scene file (.tscn). Useful for extracting a designed UI branch (e.g. a card layout) into a prefab. Does not modify the source scene tree."

	# inputSchema
	var input_schema: Dictionary = {
		"type": "object",
		"properties": {
			"node_path": {
				"type": "string",
				"description": "Path to the branch root node in the edited scene (e.g. '/root/Main/CardLayout')."
			},
			"scene_path": {
				"type": "string",
				"description": "Path where the branch will be saved (e.g. 'res://scenes/Card.tscn')."
			}
		},
		"required": ["node_path", "scene_path"]
	}

	# outputSchema
	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"status": {"type": "string"},
			"saved_path": {"type": "string"},
			"node_count": {"type": "integer"}
		}
	}

	# annotations
	var annotations: Dictionary = {
		"readOnlyHint": false,
		"destructiveHint": false,
		"idempotentHint": false,
		"openWorldHint": false
	}

	server_core.register_tool(tool_name, description, input_schema,
						  Callable(self, "_tool_save_branch_as_scene"),
						  output_schema, annotations,
						  "supplementary", "Scene-Advanced")

func _tool_save_branch_as_scene(params: Dictionary) -> Dictionary:
	var node_path: String = str(params.get("node_path", "")).strip_edges()
	var scene_path: String = str(params.get("scene_path", "")).strip_edges()

	# Parameter validation (runs before editor access so it is testable headless)
	if node_path.is_empty():
		return {"error": "Missing required parameter: node_path"}
	if scene_path.is_empty():
		return {"error": "Missing required parameter: scene_path"}

	var validation: Dictionary = PathValidator.validate_file_path(scene_path, [".tscn"])
	if not validation["valid"]:
		return {"error": "Invalid path: " + validation["error"]}
	scene_path = validation["sanitized"]

	var editor_interface: EditorInterface = _get_editor_interface()
	if not editor_interface:
		return {"error": "Editor interface not available"}

	var scene_root: Node = _get_user_scene_root()
	if not scene_root:
		return {"error": "No scene is currently open"}

	var source: Node = _resolve_node_path(node_path)
	if not source:
		return {"error": "Node not found: " + node_path}
	if source == scene_root:
		return {"error": "Cannot save the scene root as a branch. Use save_scene instead."}

	# Duplicate the branch so we can reassign ownership without mutating the
	# live scene, then own every descendant by the duplicate root so pack()
	# includes the whole subtree. DUPLICATE_USE_INSTANTIATION recreates nested
	# instanced sub-scenes through their PackedScene so scene_file_path is
	# preserved instead of the instance being flattened into inline nodes.
	var branch: Node = source.duplicate(
		Node.DUPLICATE_SIGNALS | Node.DUPLICATE_GROUPS
		| Node.DUPLICATE_SCRIPTS | Node.DUPLICATE_USE_INSTANTIATION)
	if not branch:
		return {"error": "Failed to duplicate branch: " + node_path}
	_assign_owner_recursive(branch, branch)

	var node_count: int = _count_nodes(branch)

	var packed_scene: PackedScene = PackedScene.new()
	var pack_error: Error = packed_scene.pack(branch)
	branch.free()
	if pack_error != OK:
		return {"error": "Failed to pack branch: " + error_string(pack_error)}

	var save_error: Error = ResourceSaver.save(packed_scene, scene_path)
	if save_error != OK:
		return {"error": "Failed to save scene: " + error_string(save_error)}

	return {
		"status": "success",
		"saved_path": scene_path,
		"node_count": node_count
	}

# Resolve a /root-relative node path within the edited scene tree.
func _resolve_node_path(node_path: String) -> Node:
	var scene_root: Node = _get_user_scene_root()
	if not scene_root:
		return null

	if node_path == "/root" or node_path.is_empty():
		return scene_root

	var relative: String = node_path.trim_prefix("/root/")
	var parts: PackedStringArray = relative.split("/")

	if parts.size() > 0 and parts[0] == scene_root.name:
		if parts.size() == 1:
			return scene_root
		var sub_path: String = "/".join(parts.slice(1))
		return scene_root.get_node_or_null(sub_path)

	return scene_root.get_node_or_null(relative)

# Recursively set the owner of every descendant so PackedScene.pack() captures
# the full subtree. Instanced sub-scene roots are owned by root (so they are
# included) but their internal children are left untouched: descending into
# them would force pack() to serialize the instance inline instead of as a
# scene reference, flattening the nested instance.
func _assign_owner_recursive(node: Node, root: Node) -> void:
	for child in node.get_children():
		child.owner = root
		if child.scene_file_path.is_empty():
			_assign_owner_recursive(child, root)

# 辅助函数：递归收集场景文件
func _collect_scenes(directory_path: String, result: Array[String]) -> void:
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
				# 递归处理子目�?
				_collect_scenes(full_path, result)
			elif file_name.ends_with(".tscn"):
				# 添加场景文件
				result.append(full_path)
		
		file_name = dir.get_next()
	
	dir.list_dir_end()

# ============================================================================
# set_tilemap_layer_cells - Paint/erase cells on a TileMapLayer (Godot 4.x)
# in the currently edited scene. Operates with the single-layer TileMapLayer
# API (one node per layer), unlike the legacy multi-layer TileMap runtime tool.
# ============================================================================

func _register_set_tilemap_layer_cells(server_core: RefCounted) -> void:
	var tool_name: String = "set_tilemap_layer_cells"
	var description: String = "Set or erase a batch of cells on a TileMapLayer node (Godot 4.x) in the currently edited scene. Uses the single-layer TileMapLayer API. Each cell is {coords:[x,y], source_id, atlas_coords:[x,y], alternative} or {coords:[x,y], erase:true}. Assign a TileSet to the layer (e.g. via create_tileset + update_node_property) so painted cells render. Wrapped in editor UndoRedo."

	var input_schema: Dictionary = {
		"type": "object",
		"properties": {
			"scene_path": {"type": "string", "description": "Optional: ensure this scene is the active edited scene first (auto-activated; the previous scene is saved when modified)."},
			"node_path": {"type": "string", "description": "Path to the TileMapLayer node in the edited scene (e.g. '/root/Main/Ground')."},
			"cells": {
				"type": "array",
				"description": "Cells to set/erase. Each item: {coords:[x,y], source_id, atlas_coords:[x,y], alternative} or {coords:[x,y], erase:true}.",
				"items": {"type": "object"}
			}
		},
		"required": ["node_path", "cells"]
	}

	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"status": {"type": "string"},
			"node_path": {"type": "string"},
			"cells_set": {"type": "integer"},
			"cells_erased": {"type": "integer"}
		}
	}

	var annotations: Dictionary = {
		"readOnlyHint": false,
		"destructiveHint": false,
		"idempotentHint": false,
		"openWorldHint": false
	}

	server_core.register_tool(tool_name, description, input_schema,
						  Callable(self, "_tool_set_tilemap_layer_cells"),
						  output_schema, annotations,
						  "supplementary", "Scene-Advanced")

func _tool_set_tilemap_layer_cells(params: Dictionary) -> Dictionary:
	var node_path: String = str(params.get("node_path", "")).strip_edges()
	if node_path.is_empty():
		return {"error": "Missing required parameter: node_path"}
	if not params.has("cells"):
		return {"error": "Missing required parameter: cells"}

	var cells: Variant = params["cells"]
	if not (cells is Array) or (cells as Array).is_empty():
		return {"error": "Parameter 'cells' must be a non-empty array"}

	# Pre-validate every cell entry before touching the editor so bad input
	# fails cleanly and is testable without an editor.
	var prepared: Array = []
	for entry in (cells as Array):
		if not (entry is Dictionary):
			return {"error": "Each cell must be an object"}
		var cell: Dictionary = entry
		if not cell.has("coords"):
			return {"error": "Each cell must include 'coords'"}
		var coords_value: Variant = _parse_vector2i(cell["coords"])
		if coords_value == null:
			return {"error": "Cell 'coords' must be [x, y] or {x, y}"}
		var prepared_cell: Dictionary = {"coords": coords_value, "erase": bool(cell.get("erase", false))}
		if not prepared_cell["erase"]:
			prepared_cell["source_id"] = int(cell.get("source_id", -1))
			var atlas_value: Variant = _parse_vector2i(cell.get("atlas_coords", [-1, -1]))
			if atlas_value == null:
				return {"error": "Cell 'atlas_coords' must be [x, y] or {x, y}"}
			prepared_cell["atlas_coords"] = atlas_value
			prepared_cell["alternative"] = int(cell.get("alternative", 0))
		prepared.append(prepared_cell)

	var editor_interface: EditorInterface = _get_editor_interface()
	if not editor_interface:
		return {"error": "Editor interface not available"}
	if not _get_user_scene_root():
		return {"error": "No scene is currently open"}
	var context_guard: Dictionary = await SCENE_CONTEXT.ensure_scene_active(
		editor_interface, String(params.get("scene_path", "")))
	if not bool(context_guard.get("ok", false)):
		return {"error": String(context_guard.get("error", "scene context guard failed"))}

	var node: Node = _resolve_node_path(node_path)
	if not node:
		# Name the active scene so the caller can recover from editor-context
		# drift (created scene exists but a different one is being edited).
		var active_root: Node = _get_user_scene_root()
		var active_hint: String = ""
		if active_root:
			var active_scene: String = String(active_root.scene_file_path)
			if active_scene.is_empty():
				active_scene = String(active_root.name)
			active_hint = " (active scene: " + active_scene + "; open the target scene first)"
		return {"error": "Node not found: " + node_path + active_hint}
	if not (node is TileMapLayer):
		return {"error": "Node is not a TileMapLayer: " + node_path + " (got " + node.get_class() + ")"}
	var layer: TileMapLayer = node

	var cells_set: int = 0
	var cells_erased: int = 0
	var undo_redo: EditorUndoRedoManager = editor_interface.get_editor_undo_redo()
	if undo_redo:
		undo_redo.create_action("Set TileMapLayer Cells: " + node_path.get_file())
	for prepared_cell in prepared:
		var coords: Vector2i = prepared_cell["coords"]
		var old_source: int = layer.get_cell_source_id(coords)
		var old_atlas: Vector2i = layer.get_cell_atlas_coords(coords)
		var old_alt: int = layer.get_cell_alternative_tile(coords)
		if prepared_cell["erase"]:
			if undo_redo:
				undo_redo.add_do_method(layer, "erase_cell", coords)
			else:
				layer.erase_cell(coords)
			cells_erased += 1
		else:
			if undo_redo:
				undo_redo.add_do_method(layer, "set_cell", coords, prepared_cell["source_id"], prepared_cell["atlas_coords"], prepared_cell["alternative"])
			else:
				layer.set_cell(coords, prepared_cell["source_id"], prepared_cell["atlas_coords"], prepared_cell["alternative"])
			cells_set += 1
		if undo_redo:
			if old_source == -1:
				undo_redo.add_undo_method(layer, "erase_cell", coords)
			else:
				undo_redo.add_undo_method(layer, "set_cell", coords, old_source, old_atlas, old_alt)
	if undo_redo:
		undo_redo.commit_action()

	editor_interface.mark_scene_as_unsaved()

	# E-3 下沉（知识清单#4）：无 TileSet 的图层刷了格子不渲染——静默陷阱
	# 变成响应内警告（格子合法地可以先刷后赋，故不报错）。
	var result_payload: Dictionary = {
		"status": "success",
		"node_path": node_path,
		"cells_set": cells_set,
		"cells_erased": cells_erased
	}
	if layer.tile_set == null:
		result_payload["warning"] = "layer has no TileSet — these cells will NOT render; create_tileset then set the layer's tile_set property"
	return result_payload

# ============================================================================
# get_tilemap_layer_cells - Read cells from a TileMapLayer (Godot 4.x)
# in the currently edited scene. Returns used cells, or specific coords.
# ============================================================================

func _register_get_tilemap_layer_cells(server_core: RefCounted) -> void:
	var tool_name: String = "get_tilemap_layer_cells"
	var description: String = "Read cells from a TileMapLayer node (Godot 4.x) in the currently edited scene. Without 'coords' it returns every used cell; with 'coords' (array of [x,y]) it returns just those. Each cell reports source_id, atlas_coords and alternative (source_id -1 means empty)."

	var input_schema: Dictionary = {
		"type": "object",
		"properties": {
			"node_path": {"type": "string", "description": "Path to the TileMapLayer node in the edited scene (e.g. '/root/Main/Ground')."},
			"coords": {
				"type": "array",
				"description": "Optional list of [x,y] cells to query. Omit to return all used cells.",
				"items": {"type": "array"}
			}
		},
		"required": ["node_path"]
	}

	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"status": {"type": "string"},
			"node_path": {"type": "string"},
			"cell_count": {"type": "integer"},
			"cells": {"type": "array"}
		}
	}

	var annotations: Dictionary = {
		"readOnlyHint": true,
		"destructiveHint": false,
		"idempotentHint": true,
		"openWorldHint": false
	}

	server_core.register_tool(tool_name, description, input_schema,
						  Callable(self, "_tool_get_tilemap_layer_cells"),
						  output_schema, annotations,
						  "supplementary", "Scene-Advanced")

func _tool_get_tilemap_layer_cells(params: Dictionary) -> Dictionary:
	var node_path: String = str(params.get("node_path", "")).strip_edges()
	if node_path.is_empty():
		return {"error": "Missing required parameter: node_path"}

	var requested: Array = []
	if params.has("coords"):
		var coords_param: Variant = params["coords"]
		if not (coords_param is Array):
			return {"error": "Parameter 'coords' must be an array of [x, y]"}
		for item in (coords_param as Array):
			var parsed: Variant = _parse_vector2i(item)
			if parsed == null:
				return {"error": "Each entry in 'coords' must be [x, y] or {x, y}"}
			requested.append(parsed)

	if not _get_user_scene_root():
		return {"error": "No scene is currently open"}

	var node: Node = _resolve_node_path(node_path)
	if not node:
		# Name the active scene so the caller can recover from editor-context
		# drift (created scene exists but a different one is being edited).
		var active_root: Node = _get_user_scene_root()
		var active_hint: String = ""
		if active_root:
			var active_scene: String = String(active_root.scene_file_path)
			if active_scene.is_empty():
				active_scene = String(active_root.name)
			active_hint = " (active scene: " + active_scene + "; open the target scene first)"
		return {"error": "Node not found: " + node_path + active_hint}
	if not (node is TileMapLayer):
		return {"error": "Node is not a TileMapLayer: " + node_path + " (got " + node.get_class() + ")"}
	var layer: TileMapLayer = node

	var target_coords: Array = requested
	if target_coords.is_empty() and not params.has("coords"):
		for used in layer.get_used_cells():
			target_coords.append(used)

	var cells: Array = []
	for coords in target_coords:
		var source_id: int = layer.get_cell_source_id(coords)
		var atlas: Vector2i = layer.get_cell_atlas_coords(coords)
		cells.append({
			"coords": [coords.x, coords.y],
			"source_id": source_id,
			"atlas_coords": [atlas.x, atlas.y],
			"alternative": layer.get_cell_alternative_tile(coords)
		})

	return {
		"status": "success",
		"node_path": node_path,
		"cell_count": cells.size(),
		"cells": cells
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
# batch_update_scene_files（P1 场景变体与批量修改）：跨多个 .tscn 文件的
# 语义化批量属性修改 —— 修改几十种敌人/道具时保留各自的特殊配置。
#
# 保留特殊配置的两道闸：
#   1. expect_current（旧默认值守卫）：只有当前序列化值 == expect_current 的
#      节点才改写；Boss 那份已经改成 300 的配置原样保留并如实上报。
#   2. preserve 显式清单：逐 scene|node|property 指定"这份不许动"。
# 纯文本级编辑（不打开编辑器、其余字节原样保留），逐文件报告
# changed / preserved / unchanged / missing + 汇总；dry_run 默认开。
# ============================================================================

func _register_batch_update_scene_files(server_core: RefCounted) -> void:
	server_core.register_tool(
		"batch_update_scene_files",
		"Semantic batch property edit across many .tscn FILES at once (text-level, no editor round-trip — everything but the edited lines stays byte-identical). Each edit targets {node, property, value} with an optional expect_current guard: only nodes whose CURRENT serialized value equals expect_current are rewritten, so tuning all grunts while the boss keeps its special 300 is one call, not per-file surgery; nodes whose value already drifted are reported as preserved (special config kept, never clobbered). An explicit preserve list ({scene, node, property}) is a second, absolute keep. Values serialize via var_to_str (floats/int/string/bool/Vector2/Color); the existing serialized type is followed when the new value converts losslessly (200.0 over int 200 stays '200'). Properties not serialized in a node section are reported as missing (with the exact node path), never silently appended. dry_run defaults to true — the first call is the preview, re-run with dry_run=false to write. Per-scene report: changed / preserved / unchanged / missing with from- and to-values.",
		{
			"type": "object",
			"properties": {
				"scenes": {
					"type": "array", "items": {"type": "string"},
					"description": "Target .tscn files, e.g. ['res://scenes/grunt.tscn', 'res://scenes/boss.tscn']."
				},
				"edits": {
					"type": "array", "items": {"type": "object"},
					"description": "[{node: 'Enemy/Brain' (scene-relative, root included), property: 'detect_range', value: <new>, expect_current: <optional old-default guard>}]"
				},
				"preserve": {
					"type": "array", "items": {"type": "object"},
					"description": "Absolute keep list: [{scene, node, property}] — matched nodes are never rewritten, reported as preserved."
				},
				"dry_run": {
					"type": "boolean", "default": true,
					"description": "Preview only (default). Set false to write the files."
				}
			},
			"required": ["scenes", "edits"]
		},
		Callable(self, "_tool_batch_update_scene_files"),
		{"type": "object", "properties": {
			"status": {"type": "string"},
			"dry_run": {"type": "boolean"},
			"written": {"type": "boolean"},
			"scenes": {"type": "array"},
			"totals": {"type": "object"}}},
		{"readOnlyHint": false, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false},
		"supplementary", "Scene-Advanced"
	)

func _tool_batch_update_scene_files(params: Dictionary) -> Dictionary:
	var scenes_raw: Variant = params.get("scenes", [])
	if not (scenes_raw is Array) or (scenes_raw as Array).is_empty():
		return {"error": "scenes must be a non-empty array of .tscn paths"}
	var edits_raw: Variant = params.get("edits", [])
	if not (edits_raw is Array) or (edits_raw as Array).is_empty():
		return {"error": "edits must be a non-empty array of {node, property, value[, expect_current]}"}
	var edits: Array = []
	for edit_value in edits_raw:
		if not (edit_value is Dictionary):
			return {"error": "each edit must be an object"}
		var edit: Dictionary = edit_value
		var node: String = String(edit.get("node", "")).strip_edges()
		var property: String = String(edit.get("property", "")).strip_edges()
		if node.is_empty():
			return {"error": "each edit requires a non-empty 'node' (scene-relative, root included)"}
		if property.is_empty() or not property.is_valid_identifier():
			return {"error": "edit for node '%s' requires a valid 'property' identifier (got '%s')" % [node, property]}
		if not edit.has("value") or edit.get("value", null) == null:
			return {"error": "edit for '%s.%s' requires a non-null 'value'" % [node, property]}
		edits.append(edit)
	var preserve_keys: Dictionary = {}
	var preserve_raw: Variant = params.get("preserve", [])
	if preserve_raw is Array:
		for keep_value in preserve_raw:
			if keep_value is Dictionary:
				var keep: Dictionary = keep_value
				preserve_keys["%s|%s|%s" % [
					String(keep.get("scene", "")).strip_edges(),
					String(keep.get("node", "")).strip_edges(),
					String(keep.get("property", "")).strip_edges()]] = true
	var dry_run: bool = bool(params.get("dry_run", true))

	var reports: Array = []
	var totals: Dictionary = {"scenes_touched": 0, "changed": 0, "preserved": 0, "unchanged": 0, "missing": 0}
	var written: bool = false
	for scene_value in scenes_raw:
		var scene_path: String = String(scene_value).strip_edges()
		var report: Dictionary = {"scene": scene_path, "changed": [], "preserved": [], "unchanged": [], "missing": []}
		var access: FileAccess = FileAccess.open(scene_path, FileAccess.READ) if FileAccess.file_exists(scene_path) else null
		if access == null:
			report["error"] = "scene file not found or unreadable"
			reports.append(report)
			continue
		var text: String = access.get_as_text()
		access.close()
		var lines: PackedStringArray = text.split("\n")
		var sections: Array = []
		var root_name: String = ""
		var current: Dictionary = {}
		for i in lines.size():
			var line: String = lines[i].strip_edges()
			if line.begins_with("[node"):
				if not current.is_empty():
					current["end"] = i
					sections.append(current)
				var header_attrs: Dictionary = _batch_parse_attrs(line)
				current = {"attrs": header_attrs, "start": i + 1, "end": lines.size()}
				if not header_attrs.has("parent") and root_name.is_empty():
					root_name = String(header_attrs.get("name", ""))
			elif line.begins_with("[") and not current.is_empty():
				current["end"] = i
				sections.append(current)
				current = {}
		if not current.is_empty():
			current["end"] = lines.size()
			sections.append(current)

		var file_dirty: bool = false
		for edit_value in edits:
			var edit: Dictionary = edit_value
			var node: String = String(edit.get("node", "")).strip_edges()
			var property: String = String(edit.get("property", "")).strip_edges()
			var new_value: Variant = edit.get("value", null)
			var target_key: String = "%s|%s|%s" % [scene_path, node, property]
			# 定位节点段：完整路径优先，退化为段名匹配（与实体解析同一语义）。
			var section: Dictionary = {}
			for section_value in sections:
				var attrs: Dictionary = (section_value as Dictionary).get("attrs", {})
				var name: String = String(attrs.get("name", ""))
				var full_path: String = name
				if attrs.has("parent"):
					var parent: String = String(attrs["parent"])
					full_path = root_name + "/" + name if parent == "." else root_name + "/" + parent + "/" + name
				if full_path == node or (section.is_empty() and name == node):
					section = section_value
					if full_path == node:
						break
			if section.is_empty():
				report["missing"].append({"node": node, "property": property,
					"reason": "node not present in the scene file"})
				continue
			# 段体内找属性行（tab 缩进的 "<property> ="）。
			var property_line_index: int = -1
			var current_text: String = ""
			var property_prefix: String = property + " ="
			for i in range(int(section.get("start", 0)), int(section.get("end", 0))):
				var body_line: String = lines[i].strip_edges()
				if body_line.begins_with(property_prefix):
					property_line_index = i
					current_text = body_line.substr(property_prefix.length()).strip_edges()
					break
			if property_line_index < 0:
				report["missing"].append({"node": node, "property": property,
					"reason": "property not serialized in the node section (value comes from the script default or an instance override) — set it once via batch_scene_node_edits and save, then batch-edit it here"})
				continue
			if preserve_keys.has(target_key):
				report["preserved"].append({"node": node, "property": property,
					"current": current_text, "reason": "explicit preserve list"})
				continue
			var current_value: Variant = str_to_var(current_text)
			if _batch_values_equal(current_value, new_value):
				report["unchanged"].append({"node": node, "property": property, "current": current_text})
				continue
			if edit.has("expect_current") and not _batch_values_equal(current_value, edit.get("expect_current", null)):
				report["preserved"].append({"node": node, "property": property,
					"current": current_text, "reason": "current value differs from expect_current — special config kept"})
				continue
			# 跟随既有序列化类型（无损时）：int 行写回 int，避免 200 变 200.0。
			var serialized: Variant = new_value
			if typeof(current_value) == TYPE_INT and new_value is float and is_equal_approx(float(new_value), roundf(float(new_value))):
				serialized = int(roundf(float(new_value)))
			var new_text: String = var_to_str(serialized)
			# 保留原行缩进（.tscn 用 tab，逐字跟随而不是硬编码）。
			var raw_line: String = lines[property_line_index]
			var leading: String = raw_line.substr(0, raw_line.length() - raw_line.lstrip("\t").length())
			lines[property_line_index] = leading + property + " = " + new_text
			file_dirty = true
			report["changed"].append({"node": node, "property": property,
				"from": current_text, "to": new_text})
		if file_dirty and not dry_run:
			var writer: FileAccess = FileAccess.open(scene_path, FileAccess.WRITE)
			if writer == null:
				report["error"] = "could not open for writing"
			else:
				writer.store_string("\n".join(lines))
				writer.close()
				written = true
				totals["scenes_touched"] = int(totals["scenes_touched"]) + 1
				# 文本级改写绕过编辑器：资源缓存里还是旧场景，重开场景会实例化
				# 旧值（实测坑）。写盘即刷新缓存——答案同行，调用方无需知道缓存语义。
				# headless（无编辑器）跳过：夹具场景常引用不存在的资源，强行加载
				# 只产生引擎解析噪音（GUT 计为 Unexpected Errors）。
				if _get_editor_interface() != null:
					ResourceLoader.load(scene_path, "", ResourceLoader.CACHE_MODE_REPLACE)
		reports.append(report)
		totals["changed"] = int(totals["changed"]) + (report["changed"] as Array).size()
		totals["preserved"] = int(totals["preserved"]) + (report["preserved"] as Array).size()
		totals["unchanged"] = int(totals["unchanged"]) + (report["unchanged"] as Array).size()
		totals["missing"] = int(totals["missing"]) + (report["missing"] as Array).size()
	return {
		"status": "success",
		"dry_run": dry_run,
		"written": written,
		"scenes": reports,
		"totals": totals,
	}

## 数值宽容相等：浮点近似、布尔精确、其余字符串比较（str_to_var 解析当前值）。
static func _batch_values_equal(a: Variant, b: Variant) -> bool:
	if a == null or b == null:
		return false
	if typeof(a) == TYPE_BOOL or typeof(b) == TYPE_BOOL:
		return bool(a) == bool(b) and typeof(a) == typeof(b)
	if (a is int or a is float) and (b is int or b is float):
		return is_equal_approx(float(a), float(b))
	return str(a) == str(b)

## 解析资源头部属性键值对（与 debug_verify_tools 同一语义的本地实现）。
static func _batch_parse_attrs(header: String) -> Dictionary:
	var attrs: Dictionary = {}
	var regex: RegEx = RegEx.new()
	regex.compile("([A-Za-z_]+)=\"([^\"]*)\"")
	for m in regex.search_all(header):
		attrs[String(m.get_string(1))] = m.get_string(2)
	return attrs

# ============================================================================
# create_scene_variant（M3 变体与规模）：基于场景继承创建变体 —— boss.tscn
# 继承 enemy.tscn 并带属性覆盖；基场景改动自动流到变体，变体只保留差异。
# 纯文本生成（继承关系的 .tscn 结构稳定），on_exists 默认 skip 幂等。
# ============================================================================

func _register_create_scene_variant(server_core: RefCounted) -> void:
	server_core.register_tool(
		"create_scene_variant",
		"Create a scene VARIANT by inheritance: boss.tscn <- enemy.tscn with property overrides. The variant keeps only its differences (stats knobs, exported values) — every base-scene change flows into all variants automatically, and batch_update_scene_files can retune them later while expect_current keeps each variant's specials. Overrides are {node, property, value} with node relative to the root ('' or '.' = the root itself, 'Brain' = child, 'Mid/Leaf' = deeper). Idempotent: an existing scene_path is skipped by default (on_exists='skip'|'error'). Text-level generation, no editor round-trip; open_after_create opens it through the scene-ready barrier.",
		{
			"type": "object",
			"properties": {
				"scene_path": {"type": "string", "description": "The variant scene to create, e.g. 'res://scenes/boss.tscn'."},
				"base_scene": {"type": "string", "description": "Existing scene to inherit from."},
				"overrides": {"type": "array", "items": {"type": "object"},
					"description": "[{node: '.' | 'Brain' | 'Mid/Leaf', property: 'detect_range', value: 300.0}]"},
				"on_exists": {"type": "string", "enum": ["skip", "error"], "default": "skip"},
				"open_after_create": {"type": "boolean", "default": false}
			},
			"required": ["scene_path", "base_scene"]
		},
		Callable(self, "_tool_create_scene_variant"),
		{"type": "object", "properties": {
			"status": {"type": "string"},
			"scene_path": {"type": "string"},
			"base_scene": {"type": "string"},
			"root_name": {"type": "string"},
			"overrides_applied": {"type": "integer"},
			"warning": {"type": "string"}}},
		{"readOnlyHint": false, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false},
		"supplementary", "Scene-Advanced"
	)

func _tool_create_scene_variant(params: Dictionary) -> Dictionary:
	var scene_path: String = String(params.get("scene_path", "")).strip_edges()
	var base_scene: String = String(params.get("base_scene", "")).strip_edges()
	if scene_path.is_empty():
		return {"error": "scene_path is required (e.g. 'res://scenes/boss.tscn')"}
	if base_scene.is_empty():
		return {"error": "base_scene is required (the scene to inherit from)"}
	if scene_path == base_scene:
		return {"error": "scene_path and base_scene must differ"}
	if not FileAccess.file_exists(base_scene):
		return {"error": "base_scene not found: %s" % base_scene}
	if FileAccess.file_exists(scene_path):
		if String(params.get("on_exists", "skip")) == "error":
			return {"error": "scene already exists: %s" % scene_path}
		return {"status": "exists", "scene_path": scene_path, "base_scene": base_scene,
			"note": "variant already present (on_exists=skip) — untouched"}

	var overrides: Array = []
	var overrides_raw: Variant = params.get("overrides", [])
	if overrides_raw is Array:
		for override_value in overrides_raw:
			if not (override_value is Dictionary):
				return {"error": "each override must be an object {node, property, value}"}
			var override: Dictionary = override_value
			var property: String = String(override.get("property", "")).strip_edges()
			if property.is_empty() or not property.is_valid_identifier():
				return {"error": "override requires a valid 'property' identifier (got '%s')" % property}
			if not override.has("value") or override.get("value", null) == null:
				return {"error": "override for '%s' requires a non-null 'value'" % property}
			overrides.append(override)

	# 基场景：根名 + 自身 uid（4.4+ 存在 gd_scene 头里，透传给 ext_resource）。
	var base_text: String = _variant_read_text(base_scene)
	var root_name: String = _variant_base_root_name(base_text)
	if root_name.is_empty():
		return {"error": "could not parse the base scene's root node name"}
	var base_uid: String = _variant_base_uid(base_text)

	# 组装继承场景：根 = instance=ExtResource；根覆盖写根段体；子覆盖
	# parent 相对根（"."=根的直接子级），与仓库解析器同一语义。
	var lines: PackedStringArray = []
	lines.append("[gd_scene load_steps=2 format=3]")
	lines.append("")
	var uid_attr: String = "" if base_uid.is_empty() else "uid=\"%s\" " % base_uid
	lines.append("[ext_resource type=\"PackedScene\" %spath=\"%s\" id=\"1_base\"]" % [uid_attr, base_scene])
	lines.append("")
	lines.append("[node name=\"%s\" instance=ExtResource(\"1_base\")]" % root_name)
	var applied: int = 0
	# 子覆盖行用 Array（引用类型）——PackedStringArray 是值类型，as 转换后 append
	# 改的是副本，字典里的存量不变（本会话实测坑）。
	var child_sections: Dictionary = {}  # 相对路径 -> 属性行 Array
	for override_value in overrides:
		var override: Dictionary = override_value
		var property: String = String(override.get("property", "")).strip_edges()
		var node: String = String(override.get("node", ".")).strip_edges()
		if node.is_empty():
			node = "."
		var line: String = "\t%s = %s" % [property, var_to_str(override.get("value", null))]
		if node == ".":
			lines.append(line)
		else:
			var normalized: String = node.trim_prefix("./").trim_prefix("/")
			if not child_sections.has(normalized):
				child_sections[normalized] = []
			(child_sections[normalized] as Array).append(line)
		applied += 1
	# 子覆盖段：路径 A/B => name=B, parent=A（A 为空即 "."）。
	for path_value in child_sections.keys():
		var path: String = String(path_value)
		var segments: PackedStringArray = path.split("/")
		var section_name: String = String(segments[segments.size() - 1])
		var parent_attr: String = "." if segments.size() == 1 else "/".join(segments.slice(0, segments.size() - 1))
		lines.append("")
		lines.append("[node name=\"%s\" parent=\"%s\"]" % [section_name, parent_attr])
		for body_line in child_sections[path_value]:
			lines.append(body_line)

	var writer: FileAccess = FileAccess.open(scene_path, FileAccess.WRITE)
	if writer == null:
		return {"error": "could not write %s" % scene_path}
	writer.store_string("\n".join(lines) + "\n")
	writer.close()

	var result: Dictionary = {
		"status": "success",
		"scene_path": scene_path,
		"base_scene": base_scene,
		"root_name": root_name,
		"overrides_applied": applied,
	}
	if applied == 0:
		result["warning"] = "no overrides given — the variant is a pure alias of the base for now"
	if bool(params.get("open_after_create", false)):
		var editor_interface: EditorInterface = _get_editor_interface()
		if editor_interface:
			await SCENE_CONTEXT.open_scene_and_wait(editor_interface, scene_path)
	return result

static func _variant_read_text(path: String) -> String:
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		return ""
	var content: String = file.get_as_text()
	file.close()
	return content

## 基场景根名：第一个无 parent 属性的 [node ...] 段的名字。
static func _variant_base_root_name(base_text: String) -> String:
	for line_value in base_text.split("\n"):
		var line: String = line_value.strip_edges()
		if line.begins_with("[node"):
			var attrs: Dictionary = _batch_parse_attrs(line)
			if not attrs.has("parent"):
				return String(attrs.get("name", ""))
	return ""

## 基场景自身 uid：gd_scene 头部的 uid 属性（4.4+）。
static func _variant_base_uid(base_text: String) -> String:
	for line_value in base_text.split("\n"):
		var line: String = line_value.strip_edges()
		if line.begins_with("[gd_scene"):
			var attrs: Dictionary = _batch_parse_attrs(line)
			return String(attrs.get("uid", ""))
		if line.begins_with("["):
			break
	return ""

# ============================================================================
# create_navigation_region（M6 尾·3D/寻路补强）：在当前编辑场景创建
# NavigationRegion2D + 轮廓驱动的烘焙导航网格（4.6 静默路径：轮廓即源几何，
# 跳过 parse 直接 bake_from_source_geometry_data）。答案同行：顶点/多边形数
# 直接进响应；agent_radius 为数据旋钮。
# ============================================================================

func _register_create_navigation_region(server_core: RefCounted) -> void:
	server_core.register_tool(
		"create_navigation_region",
		"Create a NavigationRegion2D in the currently edited scene with an OUTLINE-DRIVEN baked navigation polygon. Give outlines as arrays of [x, y] points (world space, same space as the nodes); agent_radius grows the shrink margin so baked paths keep distance from walls. Baking uses the quiet 4.6 path (outlines ARE the source geometry; no scene parse, no engine noise) and the response reports vertex/polygon counts inline. Navigation-obstacle parity: bake again after walls change. For runtime proof, assert get_node('<region>').navigation_polygon.get_vertices().size() >= 4.",
		{
			"type": "object",
			"properties": {
				"parent_path": {"type": "string", "default": "", "description": "Parent for the region node; default is the edited scene root."},
				"node_name": {"type": "string", "default": "NavRegion"},
				"outlines": {"type": "array", "items": {"type": "array"},
					"description": "One or more outlines, each an array of [x, y] points (clockwise or counter-clockwise, >= 3 points)."},
				"agent_radius": {"type": "number", "default": 1.0, "description": "Bake shrink margin — keep paths away from outline edges."},
				"bake": {"type": "boolean", "default": true, "description": "Bake immediately (recommended; the quiet outline path)."}
			},
			"required": ["outlines"]
		},
		Callable(self, "_tool_create_navigation_region"),
		{"type": "object", "properties": {
			"status": {"type": "string"},
			"node_path": {"type": "string"},
			"vertices_count": {"type": "integer"},
			"polygons_count": {"type": "integer"},
			"baked": {"type": "boolean"}}},
		{"readOnlyHint": false, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false},
		"supplementary", "Scene-Advanced"
	)

func _tool_create_navigation_region(params: Dictionary) -> Dictionary:
	var outlines_raw: Variant = params.get("outlines", [])
	if not (outlines_raw is Array) or (outlines_raw as Array).is_empty():
		return {"error": "outlines must be a non-empty array of point arrays ([[x, y], ...] per outline)"}
	var baked_poly: Dictionary = _bake_navigation_outlines(outlines_raw, float(params.get("agent_radius", 1.0)),
		bool(params.get("bake", true)))
	if baked_poly.has("error"):
		return baked_poly

	var editor_interface: EditorInterface = _get_editor_interface()
	if editor_interface == null:
		return {"error": "Editor interface not available (open the scene in the editor first)"}
	var scene_root: Node = SCENE_CONTEXT.get_edited_user_scene_root(editor_interface)
	if scene_root == null:
		return {"error": "No edited scene — open_scene first"}
	var parent_path: String = String(params.get("parent_path", "")).strip_edges()
	var parent: Node = scene_root if parent_path.is_empty() else scene_root.get_node_or_null(NodePath(parent_path))
	if parent == null:
		return {"error": "parent_path not found in the edited scene: %s" % parent_path}
	var node_name: String = String(params.get("node_name", "NavRegion")).strip_edges()
	if node_name.is_empty():
		node_name = "NavRegion"
	var existing: Node = parent.get_node_or_null(NodePath(node_name))
	var region: NavigationRegion2D = null
	if existing is NavigationRegion2D:
		region = existing  # 幂等：同名区域复用并重烘
	else:
		region = NavigationRegion2D.new()
		region.name = node_name
		parent.add_child(region)
		region.owner = scene_root
	region.navigation_polygon = baked_poly["navigation_polygon"]
	editor_interface.mark_scene_as_unsaved()
	# 场景相对路径（编辑器 get_path 是 @EditorNode@ 内部树，运行时不可用）。
	var relative_path: String = ""
	var walker: Node = region
	while walker != null and walker != scene_root:
		relative_path = String(walker.name) + "/" + relative_path
		walker = walker.get_parent()
	relative_path = relative_path.trim_suffix("/")
	if relative_path.is_empty():
		relative_path = String(region.name)
	return {
		"status": "success",
		"node_path": relative_path,
		"vertices_count": int(baked_poly["vertices_count"]),
		"polygons_count": int(baked_poly["polygons_count"]),
		"baked": bool(baked_poly["baked"]),
	}

## 纯内核（headless 可单测）：轮廓数组 -> 烘焙后的 NavigationPolygon + 计数。
## 4.6 实测：NavigationPolygon 无 bake_navigation_polygon 方法；静默路径是
## 跳过 parse、以轮廓为源几何直接 bake_from_source_geometry_data（带 root 的
## parse 会打 "No parsing root node" 引擎噪音且不需要）。
static func _bake_navigation_outlines(outlines_raw: Array, agent_radius: float, do_bake: bool) -> Dictionary:
	if outlines_raw.is_empty():
		return {"error": "outlines must contain at least one outline"}
	var poly := NavigationPolygon.new()
	var outline_count: int = 0
	for outline_value in outlines_raw:
		if not (outline_value is Array) or (outline_value as Array).size() < 3:
			return {"error": "each outline needs at least 3 points (got %s)" % (str(outline_value)).substr(0, 60)}
		var points: PackedVector2Array = PackedVector2Array()
		for point_value in outline_value:
			if point_value is Dictionary:
				points.append(Vector2(float(point_value.get("x", 0.0)), float(point_value.get("y", 0.0))))
			elif point_value is Array and (point_value as Array).size() >= 2:
				points.append(Vector2(float((point_value as Array)[0]), float((point_value as Array)[1])))
			elif point_value is Vector2:
				points.append(point_value)
			else:
				return {"error": "outline points must be [x, y] arrays, {x, y} objects or Vector2s"}
		poly.add_outline(points)
		outline_count += 1
	poly.agent_radius = maxf(agent_radius, 0.0)
	var baked: bool = false
	if do_bake:
		var source := NavigationMeshSourceGeometryData2D.new()
		NavigationServer2D.bake_from_source_geometry_data(poly, source)
		baked = true
	return {
		"navigation_polygon": poly,
		"vertices_count": poly.get_vertices().size(),
		"polygons_count": poly.get_polygon_count(),
		"baked": baked,
		"outlines_used": outline_count}
