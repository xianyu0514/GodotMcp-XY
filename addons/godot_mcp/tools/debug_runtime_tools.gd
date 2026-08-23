# debug_runtime_tools.gd - Debug runtime-probe domain tools (split from debug_tools_native.gd)

@tool
class_name DebugRuntimeTools
extends RefCounted

var _editor_interface: EditorInterface = null
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

func _get_debugger_bridge() -> RefCounted:
	if Engine.has_meta("GodotMCPPlugin"):
		var plugin = Engine.get_meta("GodotMCPPlugin")
		if plugin and plugin.has_method("get_debugger_bridge"):
			return plugin.get_debugger_bridge()
	return null

# Sandbox guard config: follows security_level (STRICT -> enabled); defaults to safe (enabled).
func _sandbox_config() -> Dictionary:
	var strict: bool = true
	if _server_core and _server_core.has_method("get_security_level"):
		strict = int(_server_core.get_security_level()) == MCPTypes.SecurityLevel.STRICT
	return {"enabled": strict}

# ============================================================================
# Tool registration
# ============================================================================

func register_tools(server_core: RefCounted) -> void:
	_server_core = server_core
	_register_get_runtime_info(server_core)
	_register_await_scene_ready(server_core)
	_register_get_runtime_performance_snapshot(server_core)
	_register_get_runtime_memory_trend(server_core)
	_register_get_runtime_scene_tree(server_core)
	_register_get_runtime_ui_semantics(server_core)
	_register_inspect_runtime_node(server_core)
	_register_create_runtime_node(server_core)
	_register_delete_runtime_node(server_core)
	_register_update_runtime_node_property(server_core)
	_register_call_runtime_node_method(server_core)
	_register_evaluate_runtime_expression(server_core)
	_register_simulate_runtime_input_event(server_core)
	_register_simulate_runtime_input_action(server_core)
	_register_list_runtime_input_actions(server_core)
	_register_upsert_runtime_input_action(server_core)
	_register_remove_runtime_input_action(server_core)
	_register_list_runtime_animations(server_core)
	_register_play_runtime_animation(server_core)
	_register_stop_runtime_animation(server_core)
	_register_get_runtime_animation_state(server_core)
	_register_get_runtime_animation_tree_state(server_core)
	_register_set_runtime_animation_tree_active(server_core)
	_register_travel_runtime_animation_tree(server_core)
	_register_get_runtime_material_state(server_core)
	_register_get_runtime_theme_item(server_core)
	_register_set_runtime_theme_override(server_core)
	_register_clear_runtime_theme_override(server_core)
	_register_get_runtime_shader_parameters(server_core)
	_register_set_runtime_shader_parameter(server_core)
	_register_list_runtime_tilemap_layers(server_core)
	_register_get_runtime_tilemap_cell(server_core)
	_register_set_runtime_tilemap_cell(server_core)
	_register_list_runtime_audio_buses(server_core)
	_register_get_runtime_audio_bus(server_core)
	_register_update_runtime_audio_bus(server_core)
	_register_get_runtime_screenshot(server_core)
	_register_await_runtime_condition(server_core)
	_register_assert_runtime_condition(server_core)
func _get_user_scene_root() -> Node:
	var editor_interface: EditorInterface = _get_editor_interface()
	if not editor_interface:
		return null
	var scene_root: Node = editor_interface.get_edited_scene_root()
	if _is_user_scene_root(scene_root):
		return scene_root
	var open_scene_roots: Array = editor_interface.get_open_scene_roots()
	for root in open_scene_roots:
		var node_root: Node = root
		if _is_user_scene_root(node_root):
			return node_root
	return null

func _is_user_scene_root(node: Node) -> bool:
	if not node:
		return false
	if node.name.begins_with("@") or node.get_class() == "PanelContainer":
		return false
	return not String(node.scene_file_path).is_empty()

func _to_runtime_friendly_path(node: Node, scene_root: Node = null) -> String:
	if not node:
		return ""
	var resolved_scene_root: Node = scene_root
	if not resolved_scene_root:
		resolved_scene_root = _get_user_scene_root()
	if not resolved_scene_root:
		return str(node.get_path())
	var root_name: String = String(resolved_scene_root.name)
	if root_name.is_empty():
		return str(node.get_path())
	if node == resolved_scene_root:
		return "/root/" + root_name
	var node_path: String = str(node.get_path())
	var scene_root_path: String = str(resolved_scene_root.get_path())
	if node_path.begins_with(scene_root_path + "/"):
		return "/root/" + root_name + node_path.substr(scene_root_path.length())
	return node_path

func _register_get_runtime_info(server_core: RefCounted) -> void:
	server_core.register_tool(
		"get_runtime_info",
		"Query the running game instance through the MCP runtime probe and return runtime metrics.",
		{"type": "object", "properties": {"session_id": {"type": "integer"}, "timeout_ms": {"type": "integer", "default": 1500}}},
		Callable(self, "_tool_get_runtime_info"),
		{"type": "object", "properties": {"fps": {"type": "number"}, "physics_frames": {"type": "integer"}, "process_frames": {"type": "integer"}, "debugger_active": {"type": "boolean"}, "current_scene": {"type": "string"}, "node_count": {"type": "integer"}}},
		{"readOnlyHint": true, "destructiveHint": false, "idempotentHint": true, "openWorldHint": true},
		"supplementary", "Debug-Advanced"
	)

func _register_get_runtime_ui_semantics(server_core: RefCounted) -> void:
	server_core.register_tool(
		"get_runtime_ui_semantics",
		"Return visible runtime Controls as a compact semantic tree with paths, text, screen rectangles and interaction state. Optional point hit-testing provides reliable targets for input simulation and visual playtests.",
		{"type": "object", "properties": {
			"point": {"type": "object", "properties": {"x": {"type": "number"}, "y": {"type": "number"}}, "required": ["x", "y"]},
			"include_hidden": {"type": "boolean", "default": false}, "only_interactive": {"type": "boolean", "default": false},
			"name_contains": {"type": "string"}, "text_contains": {"type": "string"}, "class_name": {"type": "string"},
			"limit": {"type": "integer", "default": 300}, "session_id": {"type": "integer"}, "timeout_ms": {"type": "integer", "default": 1500}
		}},
		Callable(self, "_tool_get_runtime_ui_semantics"),
		{"type": "object", "properties": {"control_count": {"type": "integer"}, "controls": {"type": "array"}, "hit_stack": {"type": "array"}}},
		{"readOnlyHint": true, "destructiveHint": false, "idempotentHint": true, "openWorldHint": true},
		"supplementary", "Debug-Advanced"
	)

func _tool_get_runtime_ui_semantics(params: Dictionary) -> Dictionary:
	if params.has("point"):
		if not (params["point"] is Dictionary) or not params["point"].has("x") or not params["point"].has("y"):
			return {"error": "point must be an object with x and y"}
	return await DebugToolsNative._request_runtime_probe_poll("get_ui_semantics", [params], ["mcp:ui_semantics"], params)

func _tool_get_runtime_info(params: Dictionary) -> Dictionary:
	var result: Dictionary = await DebugToolsNative._request_runtime_probe_poll("get_runtime_info", [], ["mcp:runtime_info"], params)
	if result.get("status", "") in ["pending", "stale"]:
		var bridge: RefCounted = _get_debugger_bridge()
		if bridge:
			var latest_runtime_info: Variant = bridge.get_latest_message_payload("mcp:runtime_info")
			if latest_runtime_info is Dictionary:
				var stale_runtime: Dictionary = latest_runtime_info.duplicate(true)
				stale_runtime["status"] = "stale"
				stale_runtime["stale"] = true
				stale_runtime["refresh_result"] = result.get("refresh_result", {})
				return stale_runtime
			var probe_ready: Variant = bridge.get_latest_message_payload("mcp:probe_ready")
			if probe_ready is Dictionary:
				var fallback: Dictionary = probe_ready.duplicate(true)
				fallback["status"] = "stale"
				fallback["stale"] = true
				fallback["refresh_result"] = result.get("refresh_result", {})
				return fallback
	return result

func _register_await_scene_ready(server_core: RefCounted) -> void:
	server_core.register_tool(
		"await_scene_ready",
		"Poll the runtime until the specified scene is loaded and ready. Internally checks get_runtime_info().current_scene until it matches the requested scene name.",
		{
			"type": "object",
			"properties": {
				"scene_name": {
					"type": "string",
					"description": "The expected scene name (e.g. 'Main', 'GameLevel'). The tool waits until current_scene contains this name."
				},
				"timeout_sec": {
					"type": "number",
					"description": "Maximum time to wait in seconds.",
					"default": 10
				},
				"session_id": {"type": "integer"}
			},
			"required": ["scene_name"]
		},
		Callable(self, "_tool_await_scene_ready"),
		{
			"type": "object",
			"properties": {
				"status": {"type": "string"},
				"scene_name": {"type": "string"},
				"elapsed_sec": {"type": "number"},
				"timeout": {"type": "boolean"},
				"attempts": {"type": "integer"}
			}
		},
		{"readOnlyHint": true, "destructiveHint": false, "idempotentHint": false, "openWorldHint": true},
		"supplementary", "Debug-Advanced"
	)

func _tool_await_scene_ready(params: Dictionary) -> Dictionary:
	var scene_name: String = params.get("scene_name", "")
	if scene_name.is_empty():
		return {"error": "Missing required parameter: scene_name"}

	var timeout_sec: float = float(params.get("timeout_sec", 10.0))
	var timeout_ms: int = int(timeout_sec * 1000)
	var poll_interval_ms: int = 200
	var deadline_ms: int = Time.get_ticks_msec() + timeout_ms
	var attempts: int = 0

	while Time.get_ticks_msec() < deadline_ms:
		attempts += 1
		var runtime_info: Dictionary = await _tool_get_runtime_info(params)

		if runtime_info.has("error"):
			# Probe might not be ready yet, wait and retry
			if Time.get_ticks_msec() + poll_interval_ms < deadline_ms:
				var tree: SceneTree = Engine.get_main_loop() as SceneTree
				if tree:
					await tree.process_frame
				else:
					OS.delay_msec(poll_interval_ms)
				continue
			else:
				return {
					"status": "timeout",
					"scene_name": scene_name,
					"elapsed_sec": timeout_sec,
					"timeout": true,
					"error": "Timeout waiting for scene: " + runtime_info.get("error", "probe not available"),
					"attempts": attempts
				}

		var current_scene_path: String = runtime_info.get("current_scene", "")
		if not current_scene_path.is_empty() and current_scene_path.contains(scene_name):
			var elapsed: float = (Time.get_ticks_msec() - (deadline_ms - timeout_ms)) / 1000.0
			return {
				"status": "success",
				"scene_name": scene_name,
				"elapsed_sec": elapsed,
				"timeout": false,
				"attempts": attempts
			}

		# Wait before next poll
		if Time.get_ticks_msec() + poll_interval_ms < deadline_ms:
			var tree: SceneTree = Engine.get_main_loop() as SceneTree
			if tree:
				await tree.process_frame
			else:
				OS.delay_msec(poll_interval_ms)

	return {
		"status": "timeout",
		"scene_name": scene_name,
		"elapsed_sec": timeout_sec,
		"timeout": true,
		"attempts": attempts,
		"error": "Timeout: scene '" + scene_name + "' not ready after " + str(timeout_sec) + " seconds"
	}

func _register_get_runtime_performance_snapshot(server_core: RefCounted) -> void:
	server_core.register_tool(
		"get_runtime_performance_snapshot",
		"Capture a runtime performance snapshot from the running game, including frame timing, object counts, and memory usage.",
		{"type": "object", "properties": {"session_id": {"type": "integer"}, "timeout_ms": {"type": "integer", "default": 1500}}},
		Callable(self, "_tool_get_runtime_performance_snapshot"),
		{"type": "object", "properties": {"fps": {"type": "number"}, "frame_time_sec": {"type": "number"}, "physics_frame_time_sec": {"type": "number"}, "object_count": {"type": "integer"}, "resource_count": {"type": "integer"}, "rendered_objects_in_frame": {"type": "integer"}, "memory_static_bytes": {"type": "integer"}, "memory_static_mb": {"type": "number"}, "current_scene": {"type": "string"}, "node_count": {"type": "integer"}}},
		{"readOnlyHint": true, "destructiveHint": false, "idempotentHint": true, "openWorldHint": true},
		"supplementary", "Debug-Advanced"
	)

func _tool_get_runtime_performance_snapshot(params: Dictionary) -> Dictionary:
	var result: Dictionary = await DebugToolsNative._request_runtime_probe_poll("get_performance_snapshot", [], ["mcp:performance_snapshot"], params)
	if result.get("status", "") == "pending":
		var bridge: RefCounted = _get_debugger_bridge()
		if bridge:
			var latest_snapshot: Variant = bridge.get_latest_message_payload("mcp:performance_snapshot")
			if latest_snapshot is Dictionary:
				var stale_snapshot: Dictionary = latest_snapshot.duplicate(true)
				stale_snapshot["status"] = "stale"
				stale_snapshot["refresh_result"] = result.get("refresh_result", {})
				return stale_snapshot
	return result

func _register_get_runtime_memory_trend(server_core: RefCounted) -> void:
	server_core.register_tool(
		"get_runtime_memory_trend",
		"Capture a short runtime memory and object-count trend from the running game over multiple samples.",
		{
			"type": "object",
			"properties": {
				"sample_count": {"type": "integer", "default": 5},
				"sample_interval_ms": {"type": "integer", "default": 100},
				"session_id": {"type": "integer"},
				"timeout_ms": {"type": "integer", "default": 3000}
			}
		},
		Callable(self, "_tool_get_runtime_memory_trend"),
		{
			"type": "object",
			"properties": {
				"sample_count": {"type": "integer"},
				"sample_interval_ms": {"type": "integer"},
				"memory_static_delta_bytes": {"type": "integer"},
				"object_count_delta": {"type": "integer"},
				"resource_count_delta": {"type": "integer"},
				"current_scene": {"type": "string"},
				"samples": {"type": "array"}
			}
		},
		{"readOnlyHint": true, "destructiveHint": false, "idempotentHint": true, "openWorldHint": true},
		"supplementary", "Debug-Advanced"
	)

func _tool_get_runtime_memory_trend(params: Dictionary) -> Dictionary:
	var sample_count: int = max(int(params.get("sample_count", 5)), 1)
	var sample_interval_ms: int = max(int(params.get("sample_interval_ms", 100)), 0)
	var result: Dictionary = await DebugToolsNative._request_runtime_probe_poll(
		"get_memory_trend",
		[sample_count, sample_interval_ms],
		["mcp:memory_trend"],
		params,
		{
			"sample_count": sample_count,
			"sample_interval_ms": sample_interval_ms
		}
	)
	if result.get("status", "") == "pending":
		var bridge: RefCounted = _get_debugger_bridge()
		if bridge:
			var latest_trend: Variant = bridge.get_latest_message_payload("mcp:memory_trend")
			if latest_trend is Dictionary \
					and int(latest_trend.get("sample_count", -1)) == sample_count \
					and int(latest_trend.get("sample_interval_ms", -1)) == sample_interval_ms:
				var stale_trend: Dictionary = latest_trend.duplicate(true)
				stale_trend["status"] = "stale"
				stale_trend["refresh_result"] = result.get("refresh_result", {})
				return stale_trend
	return result

func _register_get_runtime_scene_tree(server_core: RefCounted) -> void:
	server_core.register_tool(
		"get_runtime_scene_tree",
		"Read the live runtime scene tree from the running game instance.",
		{"type": "object", "properties": {"max_depth": {"type": "integer", "default": 6}, "session_id": {"type": "integer"}, "timeout_ms": {"type": "integer", "default": 1500}}},
		Callable(self, "_tool_get_runtime_scene_tree"),
		{"type": "object", "properties": {"name": {"type": "string"}, "type": {"type": "string"}, "path": {"type": "string"}, "child_count": {"type": "integer"}, "children": {"type": "array"}}},
		{"readOnlyHint": true, "destructiveHint": false, "idempotentHint": true, "openWorldHint": true},
		"supplementary", "Debug-Advanced"
	)

func _tool_get_runtime_scene_tree(params: Dictionary) -> Dictionary:
	var result: Dictionary = await DebugToolsNative._request_runtime_probe_poll("get_scene_tree", [params.get("max_depth", 6)], ["mcp:scene_tree"], params)
	if result.get("status", "") in ["pending", "stale"]:
		# Check runtime info to verify game session is alive
		var runtime_info: Dictionary = await _tool_get_runtime_info(params)
		var is_stale: bool = runtime_info.get("stale", false) or result.get("stale", false)
		if is_stale or result.get("status", "") == "stale":
			return {
				"status": "stale",
				"stale": true,
				"scene_tree": {},
				"message": "Game session is no longer active. The returned scene tree may be cached data from a previous session.",
				"node_count": 0
			}
	return result

func _register_inspect_runtime_node(server_core: RefCounted) -> void:
	server_core.register_tool(
		"inspect_runtime_node",
		"Inspect a live runtime node and its serializable properties through the runtime probe.",
		{
			"type": "object",
			"properties": {
				"node_path": {"type": "string"},
				"session_id": {"type": "integer"},
				"timeout_ms": {"type": "integer", "default": 1500}
			},
			"required": ["node_path"]
		},
		Callable(self, "_tool_inspect_runtime_node"),
		{"type": "object", "properties": {"name": {"type": "string"}, "type": {"type": "string"}, "path": {"type": "string"}, "properties": {"type": "object"}}},
		{"readOnlyHint": true, "destructiveHint": false, "idempotentHint": true, "openWorldHint": true},
		"supplementary", "Debug-Advanced"
	)

func _tool_inspect_runtime_node(params: Dictionary) -> Dictionary:
	var node_path: String = params.get("node_path", "")
	if node_path.is_empty():
		return {"error": "Missing required parameter: node_path"}
	return await DebugToolsNative._request_runtime_probe_poll("inspect_node", [node_path], ["mcp:node"], params, {"path": node_path})

func _register_create_runtime_node(server_core: RefCounted) -> void:
	server_core.register_tool(
		"create_runtime_node",
		"Create a new runtime node under an existing parent node in the running game.",
		{
			"type": "object",
			"properties": {
				"parent_path": {"type": "string", "description": "Runtime node path for the parent, e.g. /root/MainScene"},
				"node_type": {"type": "string", "description": "Godot node class name to instantiate, e.g. Node2D or Sprite2D."},
				"node_name": {"type": "string", "description": "Name for the new runtime node."},
				"session_id": {"type": "integer"},
				"timeout_ms": {"type": "integer", "default": 1500}
			},
			"required": ["parent_path", "node_type", "node_name"]
		},
		Callable(self, "_tool_create_runtime_node"),
		{"type": "object", "properties": {"parent_path": {"type": "string"}, "node_path": {"type": "string"}, "node_type": {"type": "string"}, "node_name": {"type": "string"}}},
		{"readOnlyHint": false, "destructiveHint": false, "idempotentHint": false, "openWorldHint": true},
		"supplementary", "Debug-Advanced"
	)

func _tool_create_runtime_node(params: Dictionary) -> Dictionary:
	var parent_path: String = params.get("parent_path", "")
	var node_type: String = params.get("node_type", "")
	var node_name: String = params.get("node_name", "")
	if parent_path.is_empty():
		return {"error": "Missing required parameter: parent_path"}
	if node_type.is_empty():
		return {"error": "Missing required parameter: node_type"}
	if node_name.is_empty():
		return {"error": "Missing required parameter: node_name"}
	return await DebugToolsNative._request_runtime_probe_poll("create_node", [parent_path, node_type, node_name], ["mcp:runtime_node_created"], params, {"node_path": parent_path.path_join(node_name)})

func _register_delete_runtime_node(server_core: RefCounted) -> void:
	server_core.register_tool(
		"delete_runtime_node",
		"Delete a runtime node from the running game. The runtime scene root and MCPRuntimeProbe node are protected.",
		{
			"type": "object",
			"properties": {
				"node_path": {"type": "string", "description": "Runtime node path to delete, e.g. /root/MainScene/Enemy"},
				"session_id": {"type": "integer"},
				"timeout_ms": {"type": "integer", "default": 1500}
			},
			"required": ["node_path"]
		},
		Callable(self, "_tool_delete_runtime_node"),
		{"type": "object", "properties": {"node_path": {"type": "string"}, "node_type": {"type": "string"}}},
		{"readOnlyHint": false, "destructiveHint": true, "idempotentHint": false, "openWorldHint": true},
		"supplementary", "Debug-Advanced"
	)

func _tool_delete_runtime_node(params: Dictionary) -> Dictionary:
	var node_path: String = params.get("node_path", "")
	if node_path.is_empty():
		return {"error": "Missing required parameter: node_path"}
	return await DebugToolsNative._request_runtime_probe_poll("delete_node", [node_path], ["mcp:runtime_node_deleted"], params, {"node_path": node_path})

func _register_update_runtime_node_property(server_core: RefCounted) -> void:
	server_core.register_tool(
		"update_runtime_node_property",
		"Modify a property on a live runtime node through the runtime probe.",
		{
			"type": "object",
			"properties": {
				"node_path": {"type": "string"},
				"property_name": {"type": "string"},
				"property_value": {},
				"session_id": {"type": "integer"},
				"timeout_ms": {"type": "integer", "default": 1500}
			},
			"required": ["node_path", "property_name", "property_value"]
		},
		Callable(self, "_tool_update_runtime_node_property"),
		{"type": "object", "properties": {"node_path": {"type": "string"}, "property_name": {"type": "string"}, "old_value": {}, "new_value": {}}},
		{"readOnlyHint": false, "destructiveHint": false, "idempotentHint": false, "openWorldHint": true},
		"supplementary", "Debug-Advanced"
	)

func _tool_update_runtime_node_property(params: Dictionary) -> Dictionary:
	var node_path: String = params.get("node_path", "")
	var property_name: String = params.get("property_name", "")
	if node_path.is_empty() or property_name.is_empty() or not params.has("property_value"):
		return {"error": "node_path, property_name, and property_value are required"}
	return await DebugToolsNative._request_runtime_probe_poll("set_node_property", [node_path, property_name, params.get("property_value")], ["mcp:node_property_updated"], params, {"node_path": node_path, "property_name": property_name})

func _register_call_runtime_node_method(server_core: RefCounted) -> void:
	server_core.register_tool(
		"call_runtime_node_method",
		"Call a method on a live runtime node and return the serialized result.",
		{
			"type": "object",
			"properties": {
				"node_path": {"type": "string"},
				"method_name": {"type": "string"},
				"arguments": {"type": "array", "items": {"type": "object"}},
				"session_id": {"type": "integer"},
				"timeout_ms": {"type": "integer", "default": 1500}
			},
			"required": ["node_path", "method_name"]
		},
		Callable(self, "_tool_call_runtime_node_method"),
		{"type": "object", "properties": {"node_path": {"type": "string"}, "method_name": {"type": "string"}, "arguments": {"type": "array", "items": {"type": "object"}}, "result": {}}},
		{"readOnlyHint": false, "destructiveHint": false, "idempotentHint": false, "openWorldHint": true},
		"supplementary", "Debug-Advanced"
	)

func _tool_call_runtime_node_method(params: Dictionary) -> Dictionary:
	var node_path: String = params.get("node_path", "")
	var method_name: String = params.get("method_name", "")
	if node_path.is_empty() or method_name.is_empty():
		return {"error": "node_path and method_name are required"}
	return await DebugToolsNative._request_runtime_probe_poll("call_node_method", [node_path, method_name, params.get("arguments", [])], ["mcp:node_method_result"], params, {"node_path": node_path, "method_name": method_name})

func _register_evaluate_runtime_expression(server_core: RefCounted) -> void:
	server_core.register_tool(
		"evaluate_runtime_expression",
		"Evaluate a GDScript Expression in the running game, optionally relative to a target node.",
		{
			"type": "object",
			"properties": {
				"expression": {"type": "string"},
				"node_path": {"type": "string"},
				"session_id": {"type": "integer"},
				"timeout_ms": {"type": "integer", "default": 1500}
			},
			"required": ["expression"]
		},
		Callable(self, "_tool_evaluate_runtime_expression"),
		{"type": "object", "properties": {"expression": {"type": "string"}, "node_path": {"type": "string"}, "value": {}}},
		{"readOnlyHint": false, "destructiveHint": false, "idempotentHint": false, "openWorldHint": true},
		"supplementary", "Debug-Advanced"
	)

func _tool_evaluate_runtime_expression(params: Dictionary) -> Dictionary:
	var expression: String = params.get("expression", "")
	if expression.is_empty():
		return {"error": "Missing required parameter: expression"}
	var guard: Dictionary = MCPScriptSandbox.scan(expression, _sandbox_config())
	if guard.get("blocked", false):
		return {"error": guard.get("error", "blocked by script sandbox"), "blocked": true, "reason": guard.get("reason", ""), "category": guard.get("category", "")}
	var payload: Array = [expression, params.get("node_path", "")]
	return await DebugToolsNative._request_runtime_probe_poll("evaluate_expression", payload, ["mcp:expression_result"], params, {"expression": expression})

func _register_simulate_runtime_input_event(server_core: RefCounted) -> void:
	server_core.register_tool(
		"simulate_runtime_input_event",
		"Inject a structured InputEvent into the running game through Input.parse_input_event().",
		{
			"type": "object",
			"properties": {
				"event": {
					"type": "object",
					"description": "Structured input event payload. Supported types: action, key, mouse_button, mouse_motion."
				},
				"session_id": {"type": "integer"},
				"timeout_ms": {"type": "integer", "default": 1500}
			},
			"required": ["event"]
		},
		Callable(self, "_tool_simulate_runtime_input_event"),
		{"type": "object", "properties": {"type": {"type": "string"}}},
		{"readOnlyHint": false, "destructiveHint": false, "idempotentHint": false, "openWorldHint": true},
		"supplementary", "Debug-Advanced"
	)

func _tool_simulate_runtime_input_event(params: Dictionary) -> Dictionary:
	var event_payload: Variant = params.get("event", null)
	if not (event_payload is Dictionary):
		return {"error": "Missing required parameter: event"}

	# Build match_fields from the event payload to distinguish press/release responses.
	# Without this, a stale cached response from a previous call could be returned.
	var match_fields: Dictionary = {}
	if event_payload.has("type"):
		match_fields["type"] = event_payload["type"]
	if event_payload.has("button_index"):
		match_fields["button_index"] = event_payload["button_index"]
	if event_payload.has("pressed"):
		match_fields["pressed"] = event_payload["pressed"]

	return await DebugToolsNative._request_runtime_probe_poll("simulate_input_event", [event_payload], ["mcp:input_event_simulated"], params, match_fields)

func _register_simulate_runtime_input_action(server_core: RefCounted) -> void:
	server_core.register_tool(
		"simulate_runtime_input_action",
		"Inject an InputEventAction into the running game through Input.parse_input_event(). runtime_pressed is only meaningful when the action exists in InputMap.",
		{
			"type": "object",
			"properties": {
				"action_name": {"type": "string"},
				"pressed": {"type": "boolean", "default": true},
				"strength": {"type": "number", "default": 1.0},
				"session_id": {"type": "integer"},
				"timeout_ms": {"type": "integer", "default": 1500}
			},
			"required": ["action_name"]
		},
		Callable(self, "_tool_simulate_runtime_input_action"),
		{"type": "object", "properties": {"action_name": {"type": "string"}, "action_exists": {"type": "boolean"}, "pressed": {"type": "boolean"}, "strength": {"type": "number"}, "runtime_pressed": {"type": "boolean"}}},
		{"readOnlyHint": false, "destructiveHint": false, "idempotentHint": false, "openWorldHint": true},
		"supplementary", "Debug-Advanced"
	)

func _tool_simulate_runtime_input_action(params: Dictionary) -> Dictionary:
	var action_name: String = params.get("action_name", "")
	if action_name.is_empty():
		return {"error": "Missing required parameter: action_name"}
	var pressed: bool = bool(params.get("pressed", true))
	var strength: float = float(params.get("strength", 1.0 if pressed else 0.0))
	return await DebugToolsNative._request_runtime_probe_poll("simulate_input_action", [action_name, pressed, strength], ["mcp:input_action_simulated"], params, {"action_name": action_name})

func _register_list_runtime_input_actions(server_core: RefCounted) -> void:
	server_core.register_tool(
		"list_runtime_input_actions",
		"List InputMap actions available in the running game, including serialized input events.",
		{
			"type": "object",
			"properties": {
				"action_name": {"type": "string", "description": "Optional exact action name filter."},
				"session_id": {"type": "integer"},
				"timeout_ms": {"type": "integer", "default": 1500}
			}
		},
		Callable(self, "_tool_list_runtime_input_actions"),
		{"type": "object", "properties": {"actions": {"type": "array"}, "count": {"type": "integer"}, "filter": {"type": "string"}}},
		{"readOnlyHint": true, "destructiveHint": false, "idempotentHint": true, "openWorldHint": true},
		"supplementary", "Debug-Advanced"
	)

func _tool_list_runtime_input_actions(params: Dictionary) -> Dictionary:
	var action_name: String = params.get("action_name", "")
	return await DebugToolsNative._request_runtime_probe_poll("list_input_actions", [action_name], ["mcp:input_actions"], params, {"filter": action_name})

func _register_upsert_runtime_input_action(server_core: RefCounted) -> void:
	server_core.register_tool(
		"upsert_runtime_input_action",
		"Create or update an InputMap action in the running game. Supports replacing existing events.",
		{
			"type": "object",
			"properties": {
				"action_name": {"type": "string"},
				"deadzone": {"type": "number", "default": 0.5},
				"erase_existing": {"type": "boolean", "default": false},
				"events": {"type": "array", "items": {"type": "object"}, "description": "Optional structured input event payloads to add to the action."},
				"session_id": {"type": "integer"},
				"timeout_ms": {"type": "integer", "default": 1500}
			},
			"required": ["action_name"]
		},
		Callable(self, "_tool_upsert_runtime_input_action"),
		{"type": "object", "properties": {"action_name": {"type": "string"}, "existed_before": {"type": "boolean"}, "deadzone": {"type": "number"}, "event_count": {"type": "integer"}, "events": {"type": "array", "items": {"type": "object"}}, "added_events": {"type": "array", "items": {"type": "object"}}}},
		{"readOnlyHint": false, "destructiveHint": false, "idempotentHint": false, "openWorldHint": true},
		"supplementary", "Debug-Advanced"
	)

func _tool_upsert_runtime_input_action(params: Dictionary) -> Dictionary:
	var action_name: String = params.get("action_name", "")
	if action_name.is_empty():
		return {"error": "Missing required parameter: action_name"}
	var deadzone: float = float(params.get("deadzone", 0.5))
	var erase_existing: bool = bool(params.get("erase_existing", false))
	var events: Array = params.get("events", [])
	return await DebugToolsNative._request_runtime_probe_poll("upsert_input_action", [action_name, deadzone, erase_existing, events], ["mcp:input_action_updated"], params, {"action_name": action_name})

func _register_remove_runtime_input_action(server_core: RefCounted) -> void:
	server_core.register_tool(
		"remove_runtime_input_action",
		"Remove an InputMap action from the running game.",
		{
			"type": "object",
			"properties": {
				"action_name": {"type": "string"},
				"session_id": {"type": "integer"},
				"timeout_ms": {"type": "integer", "default": 1500}
			},
			"required": ["action_name"]
		},
		Callable(self, "_tool_remove_runtime_input_action"),
		{"type": "object", "properties": {"action_name": {"type": "string"}, "removed": {"type": "boolean"}, "event_count": {"type": "integer"}}},
		{"readOnlyHint": false, "destructiveHint": true, "idempotentHint": false, "openWorldHint": true},
		"supplementary", "Debug-Advanced"
	)

func _tool_remove_runtime_input_action(params: Dictionary) -> Dictionary:
	var action_name: String = params.get("action_name", "")
	if action_name.is_empty():
		return {"error": "Missing required parameter: action_name"}
	return await DebugToolsNative._request_runtime_probe_poll("remove_input_action", [action_name], ["mcp:input_action_removed"], params, {"action_name": action_name})

func _register_list_runtime_animations(server_core: RefCounted) -> void:
	server_core.register_tool(
		"list_runtime_animations",
		"List animations available on a runtime AnimationPlayer node.",
		{
			"type": "object",
			"properties": {
				"node_path": {"type": "string"},
				"session_id": {"type": "integer"},
				"timeout_ms": {"type": "integer", "default": 1500}
			},
			"required": ["node_path"]
		},
		Callable(self, "_tool_list_runtime_animations"),
		{"type": "object", "properties": {"node_path": {"type": "string"}, "animations": {"type": "array"}, "count": {"type": "integer"}}},
		{"readOnlyHint": true, "destructiveHint": false, "idempotentHint": true, "openWorldHint": true},
		"supplementary", "Debug-Advanced"
	)

func _tool_list_runtime_animations(params: Dictionary) -> Dictionary:
	var node_path: String = params.get("node_path", "")
	if node_path.is_empty():
		return {"error": "Missing required parameter: node_path"}
	return await DebugToolsNative._request_runtime_probe_poll("list_animations", [node_path], ["mcp:animation_list"], params, {"node_path": node_path})

func _register_play_runtime_animation(server_core: RefCounted) -> void:
	server_core.register_tool(
		"play_runtime_animation",
		"Play an animation on a runtime AnimationPlayer node.",
		{
			"type": "object",
			"properties": {
				"node_path": {"type": "string"},
				"animation_name": {"type": "string"},
				"custom_blend": {"type": "number", "default": -1.0},
				"custom_speed": {"type": "number", "default": 1.0},
				"from_end": {"type": "boolean", "default": false},
				"session_id": {"type": "integer"},
				"timeout_ms": {"type": "integer", "default": 1500}
			},
			"required": ["node_path", "animation_name"]
		},
		Callable(self, "_tool_play_runtime_animation"),
		{"type": "object", "properties": {"node_path": {"type": "string"}, "current_animation": {"type": "string"}, "is_playing": {"type": "boolean"}, "current_position": {"type": "number"}, "current_length": {"type": "number"}, "speed_scale": {"type": "number"}, "playing_speed": {"type": "number"}}},
		{"readOnlyHint": false, "destructiveHint": false, "idempotentHint": false, "openWorldHint": true},
		"supplementary", "Debug-Advanced"
	)

func _tool_play_runtime_animation(params: Dictionary) -> Dictionary:
	var node_path: String = params.get("node_path", "")
	var animation_name: String = params.get("animation_name", "")
	if node_path.is_empty() or animation_name.is_empty():
		return {"error": "node_path and animation_name are required"}
	return await DebugToolsNative._request_runtime_probe_poll("play_animation", [node_path, animation_name, float(params.get("custom_blend", -1.0)), float(params.get("custom_speed", 1.0)), bool(params.get("from_end", false))], ["mcp:animation_started"], params, {"node_path": node_path, "current_animation": animation_name})

func _register_stop_runtime_animation(server_core: RefCounted) -> void:
	server_core.register_tool(
		"stop_runtime_animation",
		"Stop playback on a runtime AnimationPlayer node.",
		{
			"type": "object",
			"properties": {
				"node_path": {"type": "string"},
				"keep_state": {"type": "boolean", "default": false},
				"session_id": {"type": "integer"},
				"timeout_ms": {"type": "integer", "default": 1500}
			},
			"required": ["node_path"]
		},
		Callable(self, "_tool_stop_runtime_animation"),
		{"type": "object", "properties": {"node_path": {"type": "string"}, "current_animation": {"type": "string"}, "is_playing": {"type": "boolean"}, "current_position": {"type": "number"}}},
		{"readOnlyHint": false, "destructiveHint": false, "idempotentHint": false, "openWorldHint": true},
		"supplementary", "Debug-Advanced"
	)

func _tool_stop_runtime_animation(params: Dictionary) -> Dictionary:
	var node_path: String = params.get("node_path", "")
	if node_path.is_empty():
		return {"error": "Missing required parameter: node_path"}
	return await DebugToolsNative._request_runtime_probe_poll("stop_animation", [node_path, bool(params.get("keep_state", false))], ["mcp:animation_stopped"], params, {"node_path": node_path})

func _register_get_runtime_animation_state(server_core: RefCounted) -> void:
	server_core.register_tool(
		"get_runtime_animation_state",
		"Return the current playback state of a runtime AnimationPlayer node.",
		{
			"type": "object",
			"properties": {
				"node_path": {"type": "string"},
				"session_id": {"type": "integer"},
				"timeout_ms": {"type": "integer", "default": 1500}
			},
			"required": ["node_path"]
		},
		Callable(self, "_tool_get_runtime_animation_state"),
		{"type": "object", "properties": {"node_path": {"type": "string"}, "current_animation": {"type": "string"}, "is_playing": {"type": "boolean"}, "current_position": {"type": "number"}, "current_length": {"type": "number"}, "speed_scale": {"type": "number"}, "playing_speed": {"type": "number"}}},
		{"readOnlyHint": true, "destructiveHint": false, "idempotentHint": true, "openWorldHint": true},
		"supplementary", "Debug-Advanced"
	)

func _tool_get_runtime_animation_state(params: Dictionary) -> Dictionary:
	var node_path: String = params.get("node_path", "")
	if node_path.is_empty():
		return {"error": "Missing required parameter: node_path"}
	return await DebugToolsNative._request_runtime_probe_poll("get_animation_state", [node_path], ["mcp:animation_state"], params, {"node_path": node_path})

func _register_get_runtime_animation_tree_state(server_core: RefCounted) -> void:
	server_core.register_tool(
		"get_runtime_animation_tree_state",
		"Return the current state of a runtime AnimationTree node, including playback metadata when available.",
		{
			"type": "object",
			"properties": {
				"node_path": {"type": "string"},
				"session_id": {"type": "integer"},
				"timeout_ms": {"type": "integer", "default": 1500}
			},
			"required": ["node_path"]
		},
		Callable(self, "_tool_get_runtime_animation_tree_state"),
		{"type": "object", "properties": {"node_path": {"type": "string"}, "active": {"type": "boolean"}, "anim_player": {"type": "string"}, "tree_root_type": {"type": "string"}, "has_playback": {"type": "boolean"}, "current_node": {"type": "string"}}},
		{"readOnlyHint": true, "destructiveHint": false, "idempotentHint": true, "openWorldHint": true},
		"supplementary", "Debug-Advanced"
	)

func _tool_get_runtime_animation_tree_state(params: Dictionary) -> Dictionary:
	var node_path: String = params.get("node_path", "")
	if node_path.is_empty():
		return {"error": "Missing required parameter: node_path"}
	return await DebugToolsNative._request_runtime_probe_poll("get_animation_tree_state", [node_path], ["mcp:animation_tree_state"], params, {"node_path": node_path})

func _register_set_runtime_animation_tree_active(server_core: RefCounted) -> void:
	server_core.register_tool(
		"set_runtime_animation_tree_active",
		"Enable or disable a runtime AnimationTree node.",
		{
			"type": "object",
			"properties": {
				"node_path": {"type": "string"},
				"active": {"type": "boolean"},
				"session_id": {"type": "integer"},
				"timeout_ms": {"type": "integer", "default": 1500}
			},
			"required": ["node_path", "active"]
		},
		Callable(self, "_tool_set_runtime_animation_tree_active"),
		{"type": "object", "properties": {"node_path": {"type": "string"}, "active": {"type": "boolean"}, "tree_root_type": {"type": "string"}}},
		{"readOnlyHint": false, "destructiveHint": false, "idempotentHint": true, "openWorldHint": true},
		"supplementary", "Debug-Advanced"
	)

func _tool_set_runtime_animation_tree_active(params: Dictionary) -> Dictionary:
	var node_path: String = params.get("node_path", "")
	if node_path.is_empty():
		return {"error": "Missing required parameter: node_path"}
	if not params.has("active"):
		return {"error": "Missing required parameter: active"}
	return await DebugToolsNative._request_runtime_probe_poll("set_animation_tree_active", [node_path, bool(params.get("active"))], ["mcp:animation_tree_active_updated"], params, {"node_path": node_path})

func _register_travel_runtime_animation_tree(server_core: RefCounted) -> void:
	server_core.register_tool(
		"travel_runtime_animation_tree",
		"Travel a runtime AnimationTree state machine playback to a target node.",
		{
			"type": "object",
			"properties": {
				"node_path": {"type": "string"},
				"state_name": {"type": "string"},
				"session_id": {"type": "integer"},
				"timeout_ms": {"type": "integer", "default": 1500}
			},
			"required": ["node_path", "state_name"]
		},
		Callable(self, "_tool_travel_runtime_animation_tree"),
		{"type": "object", "properties": {"node_path": {"type": "string"}, "current_node": {"type": "string"}, "travel_path": {"type": "array"}}},
		{"readOnlyHint": false, "destructiveHint": false, "idempotentHint": false, "openWorldHint": true},
		"supplementary", "Debug-Advanced"
	)

func _tool_travel_runtime_animation_tree(params: Dictionary) -> Dictionary:
	var node_path: String = params.get("node_path", "")
	var state_name: String = params.get("state_name", "")
	if node_path.is_empty() or state_name.is_empty():
		return {"error": "node_path and state_name are required"}
	return await DebugToolsNative._request_runtime_probe_poll("travel_animation_tree", [node_path, state_name], ["mcp:animation_tree_travelled"], params, {"node_path": node_path})

func _register_get_runtime_material_state(server_core: RefCounted) -> void:
	server_core.register_tool(
		"get_runtime_material_state",
		"Resolve a runtime node material binding and return material metadata.",
		{
			"type": "object",
			"properties": {
				"node_path": {"type": "string"},
				"material_target": {"type": "string", "enum": ["auto", "material", "material_override", "surface_override"], "default": "auto"},
				"surface_index": {"type": "integer", "default": 0},
				"session_id": {"type": "integer"},
				"timeout_ms": {"type": "integer", "default": 1500}
			},
			"required": ["node_path"]
		},
		Callable(self, "_tool_get_runtime_material_state"),
		{"type": "object", "properties": {"node_path": {"type": "string"}, "material_class": {"type": "string"}, "material_target": {"type": "string"}, "is_shader_material": {"type": "boolean"}}},
		{"readOnlyHint": true, "destructiveHint": false, "idempotentHint": true, "openWorldHint": true},
		"supplementary", "Debug-Advanced"
	)

func _tool_get_runtime_material_state(params: Dictionary) -> Dictionary:
	var node_path: String = params.get("node_path", "")
	if node_path.is_empty():
		return {"error": "Missing required parameter: node_path"}
	return await DebugToolsNative._request_runtime_probe_poll("get_material_state", [node_path, str(params.get("material_target", "auto")), int(params.get("surface_index", 0))], ["mcp:material_state"], params, {"node_path": node_path})

func _register_get_runtime_theme_item(server_core: RefCounted) -> void:
	server_core.register_tool(
		"get_runtime_theme_item",
		"Resolve one runtime Control theme item and report its current value and override status.",
		{
			"type": "object",
			"properties": {
				"node_path": {"type": "string"},
				"item_type": {"type": "string", "enum": ["color", "constant", "font", "font_size", "stylebox", "icon"]},
				"item_name": {"type": "string"},
				"theme_type": {"type": "string"},
				"session_id": {"type": "integer"},
				"timeout_ms": {"type": "integer", "default": 1500}
			},
			"required": ["node_path", "item_type", "item_name"]
		},
		Callable(self, "_tool_get_runtime_theme_item"),
		{"type": "object", "properties": {"node_path": {"type": "string"}, "item_type": {"type": "string"}, "item_name": {"type": "string"}, "has_override": {"type": "boolean"}, "has_item": {"type": "boolean"}, "value": {}}},
		{"readOnlyHint": true, "destructiveHint": false, "idempotentHint": true, "openWorldHint": true},
		"supplementary", "Debug-Advanced"
	)

func _tool_get_runtime_theme_item(params: Dictionary) -> Dictionary:
	var node_path: String = params.get("node_path", "")
	var item_type: String = params.get("item_type", "")
	var item_name: String = params.get("item_name", "")
	if node_path.is_empty() or item_type.is_empty() or item_name.is_empty():
		return {"error": "node_path, item_type, and item_name are required"}
	return await DebugToolsNative._request_runtime_probe_poll("get_theme_item", [node_path, item_type, item_name, str(params.get("theme_type", ""))], ["mcp:theme_item"], params, {"node_path": node_path, "item_type": item_type, "item_name": item_name})

func _register_set_runtime_theme_override(server_core: RefCounted) -> void:
	server_core.register_tool(
		"set_runtime_theme_override",
		"Apply one runtime Control theme override for a color, constant, font, font_size, stylebox, or icon item.",
		{
			"type": "object",
			"properties": {
				"node_path": {"type": "string"},
				"item_type": {"type": "string", "enum": ["color", "constant", "font", "font_size", "stylebox", "icon"]},
				"item_name": {"type": "string"},
				"value": {},
				"theme_type": {"type": "string"},
				"session_id": {"type": "integer"},
				"timeout_ms": {"type": "integer", "default": 1500}
			},
			"required": ["node_path", "item_type", "item_name", "value"]
		},
		Callable(self, "_tool_set_runtime_theme_override"),
		{"type": "object", "properties": {"node_path": {"type": "string"}, "item_type": {"type": "string"}, "item_name": {"type": "string"}, "has_override": {"type": "boolean"}, "value": {}}},
		{"readOnlyHint": false, "destructiveHint": false, "idempotentHint": false, "openWorldHint": true},
		"supplementary", "Debug-Advanced"
	)

func _tool_set_runtime_theme_override(params: Dictionary) -> Dictionary:
	var node_path: String = params.get("node_path", "")
	var item_type: String = params.get("item_type", "")
	var item_name: String = params.get("item_name", "")
	if node_path.is_empty() or item_type.is_empty() or item_name.is_empty() or not params.has("value"):
		return {"error": "node_path, item_type, item_name, and value are required"}
	return await DebugToolsNative._request_runtime_probe_poll("set_theme_override", [node_path, item_type, item_name, params.get("value"), str(params.get("theme_type", ""))], ["mcp:theme_override_updated"], params, {"node_path": node_path, "item_type": item_type, "item_name": item_name})

func _register_clear_runtime_theme_override(server_core: RefCounted) -> void:
	server_core.register_tool(
		"clear_runtime_theme_override",
		"Remove one runtime Control theme override and return the resolved post-clear value.",
		{
			"type": "object",
			"properties": {
				"node_path": {"type": "string"},
				"item_type": {"type": "string", "enum": ["color", "constant", "font", "font_size", "stylebox", "icon"]},
				"item_name": {"type": "string"},
				"theme_type": {"type": "string"},
				"session_id": {"type": "integer"},
				"timeout_ms": {"type": "integer", "default": 1500}
			},
			"required": ["node_path", "item_type", "item_name"]
		},
		Callable(self, "_tool_clear_runtime_theme_override"),
		{"type": "object", "properties": {"node_path": {"type": "string"}, "item_type": {"type": "string"}, "item_name": {"type": "string"}, "has_override": {"type": "boolean"}, "value": {}}},
		{"readOnlyHint": false, "destructiveHint": false, "idempotentHint": false, "openWorldHint": true},
		"supplementary", "Debug-Advanced"
	)

func _tool_clear_runtime_theme_override(params: Dictionary) -> Dictionary:
	var node_path: String = params.get("node_path", "")
	var item_type: String = params.get("item_type", "")
	var item_name: String = params.get("item_name", "")
	if node_path.is_empty() or item_type.is_empty() or item_name.is_empty():
		return {"error": "node_path, item_type, and item_name are required"}
	return await DebugToolsNative._request_runtime_probe_poll("clear_theme_override", [node_path, item_type, item_name, str(params.get("theme_type", ""))], ["mcp:theme_override_cleared"], params, {"node_path": node_path, "item_type": item_type, "item_name": item_name})

func _register_get_runtime_shader_parameters(server_core: RefCounted) -> void:
	server_core.register_tool(
		"get_runtime_shader_parameters",
		"List shader uniforms and current values from a runtime ShaderMaterial binding.",
		{
			"type": "object",
			"properties": {
				"node_path": {"type": "string"},
				"material_target": {"type": "string", "enum": ["auto", "material", "material_override", "surface_override"], "default": "auto"},
				"surface_index": {"type": "integer", "default": 0},
				"session_id": {"type": "integer"},
				"timeout_ms": {"type": "integer", "default": 1500}
			},
			"required": ["node_path"]
		},
		Callable(self, "_tool_get_runtime_shader_parameters"),
		{"type": "object", "properties": {"node_path": {"type": "string"}, "parameters": {"type": "array"}, "count": {"type": "integer"}}},
		{"readOnlyHint": true, "destructiveHint": false, "idempotentHint": true, "openWorldHint": true},
		"supplementary", "Debug-Advanced"
	)

func _tool_get_runtime_shader_parameters(params: Dictionary) -> Dictionary:
	var node_path: String = params.get("node_path", "")
	if node_path.is_empty():
		return {"error": "Missing required parameter: node_path"}
	return await DebugToolsNative._request_runtime_probe_poll("get_shader_parameters", [node_path, str(params.get("material_target", "auto")), int(params.get("surface_index", 0))], ["mcp:shader_parameters"], params, {"node_path": node_path})

func _register_set_runtime_shader_parameter(server_core: RefCounted) -> void:
	server_core.register_tool(
		"set_runtime_shader_parameter",
		"Update one shader uniform on a runtime ShaderMaterial binding.",
		{
			"type": "object",
			"properties": {
				"node_path": {"type": "string"},
				"parameter_name": {"type": "string"},
				"value": {},
				"material_target": {"type": "string", "enum": ["auto", "material", "material_override", "surface_override"], "default": "auto"},
				"surface_index": {"type": "integer", "default": 0},
				"session_id": {"type": "integer"},
				"timeout_ms": {"type": "integer", "default": 1500}
			},
			"required": ["node_path", "parameter_name", "value"]
		},
		Callable(self, "_tool_set_runtime_shader_parameter"),
		{"type": "object", "properties": {"node_path": {"type": "string"}, "parameter_name": {"type": "string"}, "old_value": {}, "new_value": {}}},
		{"readOnlyHint": false, "destructiveHint": false, "idempotentHint": false, "openWorldHint": true},
		"supplementary", "Debug-Advanced"
	)

func _tool_set_runtime_shader_parameter(params: Dictionary) -> Dictionary:
	var node_path: String = params.get("node_path", "")
	var parameter_name: String = params.get("parameter_name", "")
	if node_path.is_empty() or parameter_name.is_empty() or not params.has("value"):
		return {"error": "node_path, parameter_name, and value are required"}
	return await DebugToolsNative._request_runtime_probe_poll("set_shader_parameter", [node_path, parameter_name, params.get("value"), str(params.get("material_target", "auto")), int(params.get("surface_index", 0))], ["mcp:shader_parameter_updated"], params, {"node_path": node_path, "parameter_name": parameter_name})

func _register_list_runtime_tilemap_layers(server_core: RefCounted) -> void:
	server_core.register_tool(
		"list_runtime_tilemap_layers",
		"List the layers and used-cell counts of a runtime TileMap node.",
		{
			"type": "object",
			"properties": {
				"node_path": {"type": "string"},
				"session_id": {"type": "integer"},
				"timeout_ms": {"type": "integer", "default": 1500}
			},
			"required": ["node_path"]
		},
		Callable(self, "_tool_list_runtime_tilemap_layers"),
		{"type": "object", "properties": {"node_path": {"type": "string"}, "layers": {"type": "array"}, "count": {"type": "integer"}}},
		{"readOnlyHint": true, "destructiveHint": false, "idempotentHint": true, "openWorldHint": true},
		"supplementary", "Debug-Advanced"
	)

func _tool_list_runtime_tilemap_layers(params: Dictionary) -> Dictionary:
	var node_path: String = params.get("node_path", "")
	if node_path.is_empty():
		return {"error": "Missing required parameter: node_path"}
	return await DebugToolsNative._request_runtime_probe_poll("list_tilemap_layers", [node_path], ["mcp:tilemap_layers"], params, {"node_path": node_path})

func _register_get_runtime_tilemap_cell(server_core: RefCounted) -> void:
	server_core.register_tool(
		"get_runtime_tilemap_cell",
		"Return the runtime cell data at one TileMap layer coordinate.",
		{
			"type": "object",
			"properties": {
				"node_path": {"type": "string"},
				"layer": {"type": "integer"},
				"coords": {"type": "object", "properties": {"x": {"type": "integer"}, "y": {"type": "integer"}}, "required": ["x", "y"]},
				"use_proxies": {"type": "boolean", "default": false},
				"session_id": {"type": "integer"},
				"timeout_ms": {"type": "integer", "default": 1500}
			},
			"required": ["node_path", "layer", "coords"]
		},
		Callable(self, "_tool_get_runtime_tilemap_cell"),
		{"type": "object", "properties": {"node_path": {"type": "string"}, "layer": {"type": "integer"}, "coords": {"type": "object"}, "source_id": {"type": "integer"}, "atlas_coords": {"type": "object"}, "alternative_tile": {"type": "integer"}, "is_empty": {"type": "boolean"}}},
		{"readOnlyHint": true, "destructiveHint": false, "idempotentHint": true, "openWorldHint": true},
		"supplementary", "Debug-Advanced"
	)

func _tool_get_runtime_tilemap_cell(params: Dictionary) -> Dictionary:
	var node_path: String = params.get("node_path", "")
	if node_path.is_empty():
		return {"error": "Missing required parameter: node_path"}
	if not params.has("coords"):
		return {"error": "Missing required parameter: coords"}
	return await DebugToolsNative._request_runtime_probe_poll("get_tilemap_cell", [node_path, int(params.get("layer", 0)), params.get("coords", {}), bool(params.get("use_proxies", false))], ["mcp:tilemap_cell"], params, {"node_path": node_path, "layer": int(params.get("layer", 0))})

func _register_set_runtime_tilemap_cell(server_core: RefCounted) -> void:
	server_core.register_tool(
		"set_runtime_tilemap_cell",
		"Write or erase a single runtime TileMap cell at one layer coordinate.",
		{
			"type": "object",
			"properties": {
				"node_path": {"type": "string"},
				"layer": {"type": "integer"},
				"coords": {"type": "object", "properties": {"x": {"type": "integer"}, "y": {"type": "integer"}}, "required": ["x", "y"]},
				"source_id": {"type": "integer"},
				"atlas_coords": {"type": "object", "properties": {"x": {"type": "integer"}, "y": {"type": "integer"}}},
				"alternative_tile": {"type": "integer", "default": 0},
				"erase": {"type": "boolean", "default": false},
				"session_id": {"type": "integer"},
				"timeout_ms": {"type": "integer", "default": 1500}
			},
			"required": ["node_path", "layer", "coords"]
		},
		Callable(self, "_tool_set_runtime_tilemap_cell"),
		{"type": "object", "properties": {"node_path": {"type": "string"}, "layer": {"type": "integer"}, "coords": {"type": "object"}, "source_id": {"type": "integer"}, "atlas_coords": {"type": "object"}, "alternative_tile": {"type": "integer"}, "is_empty": {"type": "boolean"}}},
		{"readOnlyHint": false, "destructiveHint": false, "idempotentHint": false, "openWorldHint": true},
		"supplementary", "Debug-Advanced"
	)

func _tool_set_runtime_tilemap_cell(params: Dictionary) -> Dictionary:
	var node_path: String = params.get("node_path", "")
	if node_path.is_empty():
		return {"error": "Missing required parameter: node_path"}
	if not params.has("coords"):
		return {"error": "Missing required parameter: coords"}
	var updates: Dictionary = {"erase": bool(params.get("erase", false))}
	if params.has("source_id"):
		updates["source_id"] = int(params.get("source_id"))
	if params.has("atlas_coords"):
		updates["atlas_coords"] = params.get("atlas_coords")
	if params.has("alternative_tile"):
		updates["alternative_tile"] = int(params.get("alternative_tile"))
	return await DebugToolsNative._request_runtime_probe_poll("set_tilemap_cell", [node_path, int(params.get("layer", 0)), params.get("coords", {}), updates], ["mcp:tilemap_cell_updated"], params, {"node_path": node_path, "layer": int(params.get("layer", 0))})

func _register_list_runtime_audio_buses(server_core: RefCounted) -> void:
	server_core.register_tool(
		"list_runtime_audio_buses",
		"List AudioServer buses available in the running game.",
		{
			"type": "object",
			"properties": {
				"session_id": {"type": "integer"},
				"timeout_ms": {"type": "integer", "default": 1500}
			}
		},
		Callable(self, "_tool_list_runtime_audio_buses"),
		{"type": "object", "properties": {"buses": {"type": "array"}, "count": {"type": "integer"}}},
		{"readOnlyHint": true, "destructiveHint": false, "idempotentHint": true, "openWorldHint": true},
		"supplementary", "Debug-Advanced"
	)

func _tool_list_runtime_audio_buses(params: Dictionary) -> Dictionary:
	return await DebugToolsNative._request_runtime_probe_poll("list_audio_buses", [], ["mcp:audio_buses"], params)

func _register_get_runtime_audio_bus(server_core: RefCounted) -> void:
	server_core.register_tool(
		"get_runtime_audio_bus",
		"Return the current state of one AudioServer bus in the running game.",
		{
			"type": "object",
			"properties": {
				"bus_name": {"type": "string"},
				"session_id": {"type": "integer"},
				"timeout_ms": {"type": "integer", "default": 1500}
			},
			"required": ["bus_name"]
		},
		Callable(self, "_tool_get_runtime_audio_bus"),
		{"type": "object", "properties": {"index": {"type": "integer"}, "name": {"type": "string"}, "volume_db": {"type": "number"}, "mute": {"type": "boolean"}, "solo": {"type": "boolean"}, "bypass_effects": {"type": "boolean"}, "send": {"type": "string"}, "effect_count": {"type": "integer"}}},
		{"readOnlyHint": true, "destructiveHint": false, "idempotentHint": true, "openWorldHint": true},
		"supplementary", "Debug-Advanced"
	)

func _tool_get_runtime_audio_bus(params: Dictionary) -> Dictionary:
	var bus_name: String = params.get("bus_name", "")
	if bus_name.is_empty():
		return {"error": "Missing required parameter: bus_name"}
	return await DebugToolsNative._request_runtime_probe_poll("get_audio_bus", [bus_name], ["mcp:audio_bus"], params, {"name": bus_name})

func _register_update_runtime_audio_bus(server_core: RefCounted) -> void:
	server_core.register_tool(
		"update_runtime_audio_bus",
		"Update mute and/or volume_db on an AudioServer bus in the running game.",
		{
			"type": "object",
			"properties": {
				"bus_name": {"type": "string"},
				"volume_db": {"type": "number"},
				"mute": {"type": "boolean"},
				"session_id": {"type": "integer"},
				"timeout_ms": {"type": "integer", "default": 1500}
			},
			"required": ["bus_name"]
		},
		Callable(self, "_tool_update_runtime_audio_bus"),
		{"type": "object", "properties": {"index": {"type": "integer"}, "name": {"type": "string"}, "volume_db": {"type": "number"}, "mute": {"type": "boolean"}, "solo": {"type": "boolean"}, "bypass_effects": {"type": "boolean"}, "send": {"type": "string"}, "effect_count": {"type": "integer"}}},
		{"readOnlyHint": false, "destructiveHint": false, "idempotentHint": false, "openWorldHint": true},
		"supplementary", "Debug-Advanced"
	)

func _tool_update_runtime_audio_bus(params: Dictionary) -> Dictionary:
	var bus_name: String = params.get("bus_name", "")
	if bus_name.is_empty():
		return {"error": "Missing required parameter: bus_name"}
	var updates: Dictionary = {}
	if params.has("volume_db"):
		updates["volume_db"] = float(params.get("volume_db"))
	if params.has("mute"):
		updates["mute"] = bool(params.get("mute"))
	return await DebugToolsNative._request_runtime_probe_poll("update_audio_bus", [bus_name, updates], ["mcp:audio_bus_updated"], params, {"name": bus_name})

func _register_get_runtime_screenshot(server_core: RefCounted) -> void:
	server_core.register_tool(
		"get_runtime_screenshot",
		"Capture the current runtime viewport, or a specific runtime Viewport/SubViewport node, from the running game and save it to a file.",
		{
			"type": "object",
			"properties": {
				"save_path": {"type": "string", "description": "Output path for the screenshot. Must use res:// or user://."},
				"format": {"type": "string", "enum": ["png", "jpg"], "default": "jpg"},
				"viewport_path": {"type": "string", "description": "Optional runtime node path to a Viewport or SubViewport to capture instead of the active root viewport."},
				"session_id": {"type": "integer"},
				"timeout_ms": {"type": "integer", "default": 1500}
			}
		},
		Callable(self, "_tool_get_runtime_screenshot"),
		{"type": "object", "properties": {"save_path": {"type": "string"}, "format": {"type": "string"}, "viewport_path": {"type": "string"}, "width": {"type": "integer"}, "height": {"type": "integer"}, "size": {"type": "string"}, "current_scene": {"type": "string"}}},
		{"readOnlyHint": true, "destructiveHint": false, "idempotentHint": false, "openWorldHint": true},
		"supplementary", "Debug-Advanced"
	)

func _tool_get_runtime_screenshot(params: Dictionary) -> Dictionary:
	var save_path: String = params.get("save_path", "user://mcp_runtime_capture.jpg")
	var path_validation: Dictionary = PathValidator.validate_file_path(save_path, [".png", ".jpg", ".jpeg"])
	if not path_validation.get("valid", false):
		return {"error": "Invalid save path: " + str(path_validation.get("error", "unknown error"))}
	save_path = path_validation["sanitized"]

	var format: String = String(params.get("format", "jpg")).to_lower()
	if not ["png", "jpg"].has(format):
		return {"error": "Unsupported format: " + format}
	if format == "png" and not save_path.to_lower().ends_with(".png"):
		return {"error": "save_path must end with .png when format is png"}
	if format == "jpg" and not (save_path.to_lower().ends_with(".jpg") or save_path.to_lower().ends_with(".jpeg")):
		return {"error": "save_path must end with .jpg or .jpeg when format is jpg"}

	var viewport_path: String = str(params.get("viewport_path", "")).strip_edges()
	var match_fields: Dictionary = {"save_path": save_path}
	if not viewport_path.is_empty():
		match_fields["viewport_path"] = viewport_path
	return await DebugToolsNative._request_runtime_probe_poll("get_runtime_screenshot", [save_path, format, viewport_path], ["mcp:runtime_screenshot"], params, match_fields)

func _register_await_runtime_condition(server_core: RefCounted) -> void:
	server_core.register_tool(
		"await_runtime_condition",
		"Poll a runtime expression until it becomes truthy or the timeout expires.",
		{
			"type": "object",
			"properties": {
				"expression": {"type": "string"},
				"node_path": {"type": "string"},
				"timeout_ms": {"type": "integer", "default": 3000},
				"poll_interval_ms": {"type": "integer", "default": 100},
				"session_id": {"type": "integer"}
			},
			"required": ["expression"]
		},
		Callable(self, "_tool_await_runtime_condition"),
		{"type": "object", "properties": {"condition_met": {"type": "boolean"}, "attempts": {"type": "integer"}, "elapsed_ms": {"type": "integer"}, "last_value": {}}},
		{"readOnlyHint": false, "destructiveHint": false, "idempotentHint": false, "openWorldHint": true},
		"supplementary", "Debug-Advanced"
	)

func _tool_await_runtime_condition(params: Dictionary) -> Dictionary:
	var expression: String = params.get("expression", "")
	if expression.is_empty():
		return {"error": "Missing required parameter: expression"}
	
	var timeout_ms: int = maxi(int(params.get("timeout_ms", 10000)), 100)
	var poll_interval_ms: int = maxi(int(params.get("poll_interval_ms", 500)), 50)
	var deadline_ms: int = Time.get_ticks_msec() + timeout_ms
	var attempts: int = 0
	
	while Time.get_ticks_msec() < deadline_ms:
		attempts += 1
		var result: Dictionary = await _tool_evaluate_runtime_expression(params)
		if result.has("error"):
			return result
		if result.get("status", "") == "success":
			var last_value: Variant = result.get("value", null)
			var condition_met: bool = _is_truthy_runtime_value(last_value)
			return {
				"status": "success" if condition_met else "failed",
				"condition_met": condition_met,
				"last_value": last_value,
				"refresh_result": result.get("refresh_result", {}),
				"attempts": attempts,
				"elapsed_ms": timeout_ms - (deadline_ms - Time.get_ticks_msec())
			}
		# If still pending or failed, wait before retrying
		if Time.get_ticks_msec() + poll_interval_ms < deadline_ms:
			var tree: SceneTree = Engine.get_main_loop() as SceneTree
			if tree:
				await tree.process_frame
			else:
				OS.delay_msec(poll_interval_ms)
	
	# Timeout reached
	var last_result: Dictionary = await _tool_evaluate_runtime_expression(params)
	var last_value: Variant = last_result.get("value", null) if not last_result.has("error") else null
	return {
		"status": "failed",
		"condition_met": false,
		"last_value": last_value,
		"error": "Timeout waiting for runtime condition: " + expression,
		"attempts": attempts,
		"elapsed_ms": timeout_ms
	}

func _register_assert_runtime_condition(server_core: RefCounted) -> void:
	server_core.register_tool(
		"assert_runtime_condition",
		"Assert that a runtime expression becomes truthy within the timeout window, or matches an expected value when provided.",
		{
			"type": "object",
			"properties": {
				"expression": {"type": "string"},
				"node_path": {"type": "string"},
				"timeout_ms": {"type": "integer", "default": 3000},
				"poll_interval_ms": {"type": "integer", "default": 100},
				"session_id": {"type": "integer"},
				"description": {"type": "string"},
				"expected": {"type": "string", "description": "Expected value to compare against. If provided, asserts expression == expected instead of truthiness."},
				"operator": {"type": "string", "description": "Comparison operator: 'eq' (default), 'ne', 'gt', 'gte', 'lt', 'lte'. Only used when expected is provided.", "default": "eq", "enum": ["eq", "ne", "gt", "gte", "lt", "lte"]}
			},
			"required": ["expression"]
		},
		Callable(self, "_tool_assert_runtime_condition"),
		{"type": "object", "properties": {"status": {"type": "string"}, "description": {"type": "string"}, "attempts": {"type": "integer"}, "elapsed_ms": {"type": "integer"}, "last_value": {}, "passed": {"type": "boolean"}, "expected": {"type": "string"}, "actual": {"type": "string"}}},
		{"readOnlyHint": false, "destructiveHint": false, "idempotentHint": false, "openWorldHint": true},
		"supplementary", "Debug-Advanced"
	)

func _tool_assert_runtime_condition(params: Dictionary) -> Dictionary:
	var wait_result: Dictionary = await _tool_await_runtime_condition(params)
	if wait_result.has("error"):
		return wait_result

	var last_value = wait_result.get("last_value", null)
	var expected_raw = params.get("expected", null)
	var attempts: int = wait_result.get("attempts", 0)
	var elapsed_ms: int = wait_result.get("elapsed_ms", 0)

	# If expected is provided, compare using operator instead of truthiness
	if expected_raw != null:
		var operator: String = params.get("operator", "eq")
		var expected_str: String = str(expected_raw)
		var actual_str: String = str(last_value) if last_value != null else "null"
		var passed: bool = _compare_values(actual_str, expected_str, operator)

		return {
			"status": "passed" if passed else "failed",
			"description": params.get("description", params.get("expression", "")),
			"passed": passed,
			"expected": expected_str,
			"actual": actual_str,
			"last_value": last_value,
			"attempts": attempts,
			"elapsed_ms": elapsed_ms
		}

	# Original truthy behavior (no expected parameter)
	if wait_result.get("status", "") == "pending":
		return {
			"status": "pending",
			"description": params.get("description", params.get("expression", "")),
			"last_value": null,
			"refresh_result": wait_result.get("refresh_result", {})
		}
	if not wait_result.get("condition_met", false):
		return {
			"error": "Runtime condition was not met within timeout",
			"description": params.get("description", params.get("expression", "")),
			"last_value": wait_result.get("last_value", null)
		}
	return {
		"status": "success",
		"description": params.get("description", params.get("expression", "")),
		"last_value": wait_result.get("last_value", null),
		"refresh_result": wait_result.get("refresh_result", {})
	}

func _compare_values(actual: String, expected: String, operator: String) -> bool:
	match operator:
		"eq":
			return actual == expected
		"ne":
			return actual != expected
		"gt":
			return float(actual) > float(expected)
		"gte":
			return float(actual) >= float(expected)
		"lt":
			return float(actual) < float(expected)
		"lte":
			return float(actual) <= float(expected)
	return false

func _is_truthy_runtime_value(value: Variant) -> bool:
	match typeof(value):
		TYPE_NIL:
			return false
		TYPE_BOOL:
			return value
		TYPE_INT, TYPE_FLOAT:
			return value != 0
		TYPE_STRING:
			return not String(value).is_empty()
		TYPE_ARRAY:
			return not value.is_empty()
		TYPE_DICTIONARY:
			return not value.is_empty()
		_:
			return true
