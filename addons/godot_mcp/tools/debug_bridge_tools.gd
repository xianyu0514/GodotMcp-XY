# debug_bridge_tools.gd - Debug bridge/execution-control domain tools (split from debug_tools_native.gd)

@tool
class_name DebugBridgeTools
extends RefCounted

const ScriptCompileMemoScript = preload("res://addons/godot_mcp/utils/script_compile_memo.gd")

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
	_register_get_debugger_sessions(server_core)
	_register_get_debug_threads(server_core)
	_register_set_debugger_breakpoint(server_core)
	_register_send_debugger_message(server_core)
	_register_toggle_debugger_profiler(server_core)
	_register_get_debugger_messages(server_core)
	_register_get_debug_state_events(server_core)
	_register_get_debug_output(server_core)
	_register_add_debugger_capture_prefix(server_core)
	_register_get_debug_stack_frames(server_core)
	_register_get_debug_stack_variables(server_core)
	_register_get_debug_scopes(server_core)
	_register_get_debug_variables(server_core)
	_register_expand_debug_variable(server_core)
	_register_evaluate_debug_expression(server_core)
	_register_install_runtime_probe(server_core)
	_register_remove_runtime_probe(server_core)
	_register_request_debug_break(server_core)
	_register_send_debug_command(server_core)
	_register_debug_step_into(server_core)
	_register_debug_step_over(server_core)
	_register_debug_step_out(server_core)
	_register_debug_continue(server_core)
	_register_debug_step_into_and_wait(server_core)
	_register_debug_step_over_and_wait(server_core)
	_register_debug_step_out_and_wait(server_core)
	_register_debug_continue_and_wait(server_core)
	_register_await_debugger_state(server_core)

func _register_get_debugger_sessions(server_core: RefCounted) -> void:
	server_core.register_tool(
		"get_debugger_sessions",
		"List Godot editor debugger sessions and their active/break state.",
		{"type": "object", "properties": {}},
		Callable(self, "_tool_get_debugger_sessions"),
		{"type": "object", "properties": {"sessions": {"type": "array"}, "count": {"type": "integer"}}},
		{"readOnlyHint": true, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false},
		"supplementary", "Debug-Advanced"
	)

func _tool_get_debugger_sessions(params: Dictionary) -> Dictionary:
	var bridge: RefCounted = _get_debugger_bridge()
	if not bridge:
		return {"error": "Debugger bridge is not available"}
	var sessions: Array = bridge.get_sessions_info()
	return {"sessions": sessions, "count": sessions.size()}

func _register_set_debugger_breakpoint(server_core: RefCounted) -> void:
	server_core.register_tool(
		"set_debugger_breakpoint",
		"Enable or disable a breakpoint in active Godot debugger sessions.",
		{
			"type": "object",
			"properties": {
				"path": {"type": "string", "description": "Script path, e.g. res://player.gd"},
				"line": {"type": "integer", "description": "1-based line number"},
				"enabled": {"type": "boolean", "description": "Whether the breakpoint is enabled"},
				"session_id": {"type": "integer", "description": "Optional debugger session id. Omit or use -1 for all sessions."}
			},
			"required": ["path", "line", "enabled"]
		},
		Callable(self, "_tool_set_debugger_breakpoint"),
		{"type": "object", "properties": {"status": {"type": "string"}, "sessions_updated": {"type": "integer"}}},
		{"readOnlyHint": false, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false},
		"supplementary", "Debug-Advanced"
	)

func _tool_set_debugger_breakpoint(params: Dictionary) -> Dictionary:
	var path: String = params.get("path", "")
	var line: int = params.get("line", 0)
	var enabled: bool = params.get("enabled", true)
	var session_id: int = params.get("session_id", -1)
	if path.is_empty():
		return {"error": "Missing required parameter: path"}
	if line < 1:
		return {"error": "line must be >= 1"}
	var bridge: RefCounted = _get_debugger_bridge()
	if not bridge:
		return {"error": "Debugger bridge is not available"}
	return bridge.set_breakpoint(path, line, enabled, session_id)

func _register_get_debug_threads(server_core: RefCounted) -> void:
	server_core.register_tool(
		"get_debug_threads",
		"Return DAP-style debugger threads visible from the active Godot debug session.",
		{"type": "object", "properties": {}},
		Callable(self, "_tool_get_debug_threads"),
		{"type": "object", "properties": {"threads": {"type": "array"}, "count": {"type": "integer"}}},
		{"readOnlyHint": true, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false},
		"supplementary", "Debug-Advanced"
	)

func _tool_get_debug_threads(params: Dictionary) -> Dictionary:
	var bridge: RefCounted = _get_debugger_bridge()
	if not bridge:
		return {"error": "Debugger bridge is not available"}
	var threads: Array = bridge.get_threads()
	return {"threads": threads, "count": threads.size()}

func _register_send_debugger_message(server_core: RefCounted) -> void:
	server_core.register_tool(
		"send_debugger_message",
		"Send a custom debugger message to active Godot debugger sessions.",
		{
			"type": "object",
			"properties": {
				"message": {"type": "string"},
				"data": {"type": "array", "items": {"type": "object"}},
				"session_id": {"type": "integer"}
			},
			"required": ["message"]
		},
		Callable(self, "_tool_send_debugger_message"),
		{"type": "object", "properties": {"status": {"type": "string"}, "sessions_updated": {"type": "integer"}}},
		{"readOnlyHint": false, "destructiveHint": false, "idempotentHint": false, "openWorldHint": true},
		"supplementary", "Debug-Advanced"
	)

func _tool_send_debugger_message(params: Dictionary) -> Dictionary:
	var message: String = params.get("message", "")
	var data: Array = params.get("data", [])
	var session_id: int = params.get("session_id", -1)
	if message.is_empty():
		return {"error": "Missing required parameter: message"}
	var bridge: RefCounted = _get_debugger_bridge()
	if not bridge:
		return {"error": "Debugger bridge is not available"}
	return bridge.send_debugger_message(message, data, session_id)

func _register_toggle_debugger_profiler(server_core: RefCounted) -> void:
	server_core.register_tool(
		"toggle_debugger_profiler",
		"Toggle an EngineProfiler in active Godot debugger sessions.",
		{
			"type": "object",
			"properties": {
				"profiler": {"type": "string", "description": "Profiler name"},
				"enabled": {"type": "boolean"},
				"data": {"type": "array", "items": {"type": "object"}},
				"session_id": {"type": "integer"}
			},
			"required": ["profiler", "enabled"]
		},
		Callable(self, "_tool_toggle_debugger_profiler"),
		{"type": "object", "properties": {"status": {"type": "string"}, "sessions_updated": {"type": "integer"}}},
		{"readOnlyHint": false, "destructiveHint": false, "idempotentHint": true, "openWorldHint": true},
		"supplementary", "Debug-Advanced"
	)

func _tool_toggle_debugger_profiler(params: Dictionary) -> Dictionary:
	var profiler: String = params.get("profiler", "")
	var enabled: bool = params.get("enabled", false)
	var data: Array = params.get("data", [])
	var session_id: int = params.get("session_id", -1)
	if profiler.is_empty():
		return {"error": "Missing required parameter: profiler"}
	var bridge: RefCounted = _get_debugger_bridge()
	if not bridge:
		return {"error": "Debugger bridge is not available"}
	return bridge.toggle_profiler(profiler, enabled, data, session_id)

func _register_get_debugger_messages(server_core: RefCounted) -> void:
	server_core.register_tool(
		"get_debugger_messages",
		"Read custom messages captured by the Godot debugger bridge.",
		{
			"type": "object",
			"properties": {
				"count": {"type": "integer", "default": 100},
				"offset": {"type": "integer", "default": 0},
				"order": {"type": "string", "enum": ["asc", "desc"], "default": "desc"}
			}
		},
		Callable(self, "_tool_get_debugger_messages"),
		{"type": "object", "properties": {"messages": {"type": "array"}, "count": {"type": "integer"}, "total_available": {"type": "integer"}}},
		{"readOnlyHint": true, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false},
		"supplementary", "Debug-Advanced"
	)

func _tool_get_debugger_messages(params: Dictionary) -> Dictionary:
	var bridge: RefCounted = _get_debugger_bridge()
	if not bridge:
		return {"error": "Debugger bridge is not available"}
	return bridge.get_captured_messages(params.get("count", 100), params.get("offset", 0), params.get("order", "desc"))

func _register_get_debug_state_events(server_core: RefCounted) -> void:
	server_core.register_tool(
		"get_debug_state_events",
		"Read recorded debugger break/resume/stop state transitions from the bridge.",
		{
			"type": "object",
			"properties": {
				"count": {"type": "integer", "default": 100},
				"offset": {"type": "integer", "default": 0},
				"order": {"type": "string", "enum": ["asc", "desc"], "default": "desc"}
			}
		},
		Callable(self, "_tool_get_debug_state_events"),
		{"type": "object", "properties": {"events": {"type": "array"}, "count": {"type": "integer"}, "total_available": {"type": "integer"}}},
		{"readOnlyHint": true, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false},
		"supplementary", "Debug-Advanced"
	)

func _tool_get_debug_state_events(params: Dictionary) -> Dictionary:
	var bridge: RefCounted = _get_debugger_bridge()
	if not bridge:
		return {"error": "Debugger bridge is not available"}
	return bridge.get_state_events(params.get("count", 100), params.get("offset", 0), params.get("order", "desc"))

func _register_get_debug_output(server_core: RefCounted) -> void:
	server_core.register_tool(
		"get_debug_output",
		"Read categorized runtime debugger output captured by the editor bridge.",
		{
			"type": "object",
			"properties": {
				"count": {"type": "integer", "default": 100},
				"offset": {"type": "integer", "default": 0},
				"order": {"type": "string", "enum": ["asc", "desc"], "default": "desc"},
				"category": {"type": "string", "enum": ["", "stdout", "stderr", "stdout_rich"], "default": ""}
			}
		},
		Callable(self, "_tool_get_debug_output"),
		{"type": "object", "properties": {"events": {"type": "array"}, "count": {"type": "integer"}, "total_available": {"type": "integer"}}},
		{"readOnlyHint": true, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false},
		"supplementary", "Debug-Advanced"
	)

func _tool_get_debug_output(params: Dictionary) -> Dictionary:
	var bridge: RefCounted = _get_debugger_bridge()
	if not bridge:
		return {"error": "Debugger bridge is not available"}
	return bridge.get_output_events(params.get("count", 100), params.get("offset", 0), params.get("order", "desc"), str(params.get("category", "")))

func _register_add_debugger_capture_prefix(server_core: RefCounted) -> void:
	server_core.register_tool(
		"add_debugger_capture_prefix",
		"Allow the debugger bridge to capture custom EngineDebugger messages with the given prefix.",
		{
			"type": "object",
			"properties": {
				"prefix": {"type": "string", "description": "Message prefix without the trailing colon, or * for all prefixes."}
			},
			"required": ["prefix"]
		},
		Callable(self, "_tool_add_debugger_capture_prefix"),
		{"type": "object", "properties": {"status": {"type": "string"}, "prefixes": {"type": "array"}}},
		{"readOnlyHint": false, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false},
		"supplementary", "Debug-Advanced"
	)

func _tool_add_debugger_capture_prefix(params: Dictionary) -> Dictionary:
	var prefix: String = params.get("prefix", "")
	if prefix.is_empty():
		return {"error": "Missing required parameter: prefix"}
	var bridge: RefCounted = _get_debugger_bridge()
	if not bridge:
		return {"error": "Debugger bridge is not available"}
	bridge.add_capture_prefix(prefix)
	return {"status": "success", "prefixes": bridge.get_capture_prefixes()}

func _register_get_debug_stack_frames(server_core: RefCounted) -> void:
	server_core.register_tool(
		"get_debug_stack_frames",
		"Get captured script stack frames with lossless limit/offset pages. Refresh once, then follow next_offset with refresh=false.",
		{
			"type": "object",
			"properties": {
				"refresh": {"type": "boolean", "default": true},
				"session_id": {"type": "integer", "description": "Optional debugger session id. Omit or use -1 for all active sessions."},
				"limit": {"type": "integer", "description": "Maximum number of stack frames to return. Default is 1000.", "default": 1000},
				"offset": {"type": "integer", "description": "Zero-based frame offset. For follow-up pages, use next_offset with refresh=false to keep the same captured stack.", "default": 0}
			}
		},
		Callable(self, "_tool_get_debug_stack_frames"),
		{"type": "object", "properties": {"frames": {"type": "array"}, "count": {"type": "integer"}, "total_count": {"type": "integer"}, "truncated": {"type": "boolean"}, "offset": {"type": "integer"}, "limit": {"type": "integer"}, "returned_count": {"type": "integer"}, "has_more": {"type": "boolean"}, "next_offset": {"type": "integer"}, "refresh_result": {"type": "object"}}},
		{"readOnlyHint": false, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false},
		"supplementary", "Debug-Advanced"
	)

func _tool_get_debug_stack_frames(params: Dictionary) -> Dictionary:
	var bridge: RefCounted = _get_debugger_bridge()
	if not bridge:
		return {"error": "Debugger bridge is not available"}
	var refresh_result: Dictionary = {}
	if params.get("refresh", true):
		refresh_result = bridge.request_stack_dump(params.get("session_id", -1))
	var frames: Array = bridge.get_latest_stack_dump()
	var page: Dictionary = PayloadUtils.paginate_list(
		frames, int(params.get("limit", 0)), int(params.get("offset", 0)))
	var result: Dictionary = {
		"frames": page["items"],
		"count": page["items"].size(),
		"total_count": page["total_count"],
		"truncated": page["truncated"],
		"offset": page["offset"],
		"limit": page["limit"],
		"returned_count": page["returned_count"],
		"has_more": page["has_more"],
		"refresh_result": refresh_result
	}
	if page.has("next_offset"):
		result["next_offset"] = page["next_offset"]
	return result

func _register_get_debug_stack_variables(server_core: RefCounted) -> void:
	server_core.register_tool(
		"get_debug_stack_variables",
		"Get captured stack-frame variables with lossless limit/offset pages. Refresh once, then follow next_offset with refresh=false.",
		{
			"type": "object",
			"properties": {
				"frame": {"type": "integer", "default": 0},
				"refresh": {"type": "boolean", "default": true},
				"session_id": {"type": "integer", "description": "Optional debugger session id. Omit or use -1 for all active sessions."},
				"limit": {"type": "integer", "description": "Maximum number of variables to return. Default is 1000.", "default": 1000},
				"offset": {"type": "integer", "description": "Zero-based variable offset. For follow-up pages, use next_offset with refresh=false to keep the same captured frame.", "default": 0}
			}
		},
		Callable(self, "_tool_get_debug_stack_variables"),
		{"type": "object", "properties": {"frame": {"type": "integer"}, "variables": {"type": "array"}, "count": {"type": "integer"}, "total_count": {"type": "integer"}, "truncated": {"type": "boolean"}, "offset": {"type": "integer"}, "limit": {"type": "integer"}, "returned_count": {"type": "integer"}, "has_more": {"type": "boolean"}, "next_offset": {"type": "integer"}, "refresh_result": {"type": "object"}}},
		{"readOnlyHint": false, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false},
		"supplementary", "Debug-Advanced"
	)

func _tool_get_debug_stack_variables(params: Dictionary) -> Dictionary:
	var bridge: RefCounted = _get_debugger_bridge()
	if not bridge:
		return {"error": "Debugger bridge is not available"}
	var frame: int = params.get("frame", 0)
	if frame < 0:
		return {"error": "frame must be >= 0"}
	var refresh_result: Dictionary = {}
	if params.get("refresh", true):
		refresh_result = bridge.request_stack_frame_vars(frame, params.get("session_id", -1))
	var variables: Array = bridge.get_latest_stack_variables(frame)
	var page: Dictionary = PayloadUtils.paginate_list(
		variables, int(params.get("limit", 0)), int(params.get("offset", 0)))
	var result: Dictionary = {
		"frame": frame,
		"variables": page["items"],
		"count": page["items"].size(),
		"total_count": page["total_count"],
		"truncated": page["truncated"],
		"offset": page["offset"],
		"limit": page["limit"],
		"returned_count": page["returned_count"],
		"has_more": page["has_more"],
		"refresh_result": refresh_result
	}
	if page.has("next_offset"):
		result["next_offset"] = page["next_offset"]
	return result

func _register_get_debug_scopes(server_core: RefCounted) -> void:
	server_core.register_tool(
		"get_debug_scopes",
		"Group latest captured stack variables into DAP-like scopes for a frame.",
		{
			"type": "object",
			"properties": {
				"frame": {"type": "integer", "default": 0},
				"refresh": {"type": "boolean", "default": true},
				"session_id": {"type": "integer", "description": "Optional debugger session id. Omit or use -1 for all active sessions."}
			}
		},
		Callable(self, "_tool_get_debug_scopes"),
		{"type": "object", "properties": {"frame": {"type": "integer"}, "scopes": {"type": "array"}, "count": {"type": "integer"}, "refresh_result": {"type": "object"}}},
		{"readOnlyHint": false, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false},
		"supplementary", "Debug-Advanced"
	)

func _tool_get_debug_scopes(params: Dictionary) -> Dictionary:
	# Scopes only summarize variables into per-scope counts, so the full variable
	# list must be grouped without truncation to keep named_variables accurate.
	var variables_params: Dictionary = params.duplicate()
	variables_params["limit"] = 0x7FFFFFFF
	var variables_result: Dictionary = _tool_get_debug_stack_variables(variables_params)
	if variables_result.has("error"):
		return variables_result
	var bridge: RefCounted = _get_debugger_bridge()
	if not bridge:
		return {"error": "Debugger bridge is not available"}
	var frame: int = int(variables_result.get("frame", 0))
	var grouped: Dictionary = {}
	for variable_entry in variables_result.get("variables", []):
		var scope_name: String = str(variable_entry.get("scope", "unknown"))
		if not grouped.has(scope_name):
			grouped[scope_name] = []
		grouped[scope_name].append(variable_entry)

	var scopes: Array = []
	for scope_name in ["local", "member", "global", "constant", "unknown"]:
		if not grouped.has(scope_name):
			continue
		var dap_variables_reference: int = bridge.get_scope_variables_reference(frame, scope_name)
		scopes.append({
			"name": scope_name,
			"frame": frame,
			"variables_reference": "%d:%s" % [frame, scope_name],
			"dap_variables_reference": dap_variables_reference,
			"named_variables": grouped[scope_name].size(),
			"indexed_variables": 0,
			"presentation_hint": _debug_scope_presentation_hint(scope_name),
			"expensive": false
		})

	return {
		"frame": frame,
		"scopes": scopes,
		"count": scopes.size(),
		"refresh_result": variables_result.get("refresh_result", {})
	}

func _register_get_debug_variables(server_core: RefCounted) -> void:
	server_core.register_tool(
		"get_debug_variables",
		"Resolve a DAP-style variablesReference into child variables, with optional pagination for large arrays and dictionaries.",
		{
			"type": "object",
			"properties": {
				"variables_reference": {"type": "integer"},
				"offset": {"type": "integer", "default": 0},
				"count": {"type": "integer", "default": 100}
			},
			"required": ["variables_reference"]
		},
		Callable(self, "_tool_get_debug_variables"),
		{"type": "object", "properties": {"variables_reference": {"type": "integer"}, "variables": {"type": "array"}, "count": {"type": "integer"}, "total_available": {"type": "integer"}}},
		{"readOnlyHint": true, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false},
		"supplementary", "Debug-Advanced"
	)

func _tool_get_debug_variables(params: Dictionary) -> Dictionary:
	var variables_reference: int = int(params.get("variables_reference", 0))
	if variables_reference <= 0:
		return {"error": "variables_reference must be > 0"}
	var bridge: RefCounted = _get_debugger_bridge()
	if not bridge:
		return {"error": "Debugger bridge is not available"}
	var result: Dictionary = bridge.get_variables_by_reference(
		variables_reference,
		int(params.get("count", 100)),
		int(params.get("offset", 0))
	)
	if result.get("total_available", 0) == 0:
		return {"error": "Unknown debug variables reference: " + str(variables_reference)}
	return result

func _register_expand_debug_variable(server_core: RefCounted) -> void:
	server_core.register_tool(
		"expand_debug_variable",
		"Expand a captured debug variable or evaluated expression value by scope and path, with pagination for arrays and dictionaries.",
		{
			"type": "object",
			"properties": {
				"frame": {"type": "integer", "default": 0},
				"scope": {"type": "string", "description": "Scope name such as local, member, global, constant, or evaluation."},
				"variable_path": {"type": "array", "items": {"type": "string"}, "description": "Path segments starting with the top-level variable name or expression text, then child keys or indices."},
				"offset": {"type": "integer", "default": 0},
				"count": {"type": "integer", "default": 100}
			},
			"required": ["scope", "variable_path"]
		},
		Callable(self, "_tool_expand_debug_variable"),
		{"type": "object", "properties": {"frame": {"type": "integer"}, "scope": {"type": "string"}, "variable_path": {"type": "array"}, "entries": {"type": "array"}, "count": {"type": "integer"}, "total_available": {"type": "integer"}}},
		{"readOnlyHint": true, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false},
		"supplementary", "Debug-Advanced"
	)

func _tool_expand_debug_variable(params: Dictionary) -> Dictionary:
	var bridge: RefCounted = _get_debugger_bridge()
	if not bridge:
		return {"error": "Debugger bridge is not available"}
	var frame: int = int(params.get("frame", 0))
	var scope: String = str(params.get("scope", "")).strip_edges().to_lower()
	var variable_path: Array = params.get("variable_path", [])
	if scope.is_empty():
		return {"error": "Missing required parameter: scope"}
	if variable_path.is_empty():
		return {"error": "Missing required parameter: variable_path"}

	var variables: Array = bridge.get_latest_stack_variables(frame)
	var current_value: Variant = null
	var current_type: String = ""
	if scope == "evaluation":
		var evaluation_entry: Variant = bridge.get_latest_evaluation(str(variable_path[0]))
		if evaluation_entry is Dictionary:
			current_value = evaluation_entry.get("value", null)
			current_type = str(evaluation_entry.get("type", ""))
	else:
		for variable_entry in variables:
			if str(variable_entry.get("scope", "")).to_lower() == scope and str(variable_entry.get("name", "")) == str(variable_path[0]):
				current_value = variable_entry.get("value", null)
				current_type = str(variable_entry.get("type", ""))
				break
	if current_type.is_empty():
		return {"error": "Debug variable not found in scope: " + str(variable_path[0])}

	for i in range(1, variable_path.size()):
		var step: String = str(variable_path[i])
		var resolved: Dictionary = _resolve_debug_path_step(current_value, step)
		if not resolved.get("ok", false):
			return {"error": "Value at path is not expandable: " + JSON.stringify(variable_path.slice(0, i))}
		current_value = resolved.get("value", null)

	var entries: Array = _expand_debug_value_entries(current_value, variable_path)
	var offset: int = max(0, int(params.get("offset", 0)))
	var count: int = max(0, int(params.get("count", 100)))
	var start: int = mini(offset, entries.size())
	var end: int = mini(start + count, entries.size())

	return {
		"frame": frame,
		"scope": scope,
		"variable_path": variable_path,
		"entries": entries.slice(start, end),
		"count": end - start,
		"total_available": entries.size()
	}

func _resolve_debug_path_step(current_value: Variant, step: String) -> Dictionary:
	if current_value is Array:
		if step == "size":
			return {"ok": true, "value": current_value.size()}
		if not step.is_valid_int():
			return {"ok": false}
		var index: int = int(step)
		if index < 0 or index >= current_value.size():
			return {"ok": false}
		return {"ok": true, "value": current_value[index]}
	match typeof(current_value):
		TYPE_PACKED_BYTE_ARRAY, TYPE_PACKED_INT32_ARRAY, TYPE_PACKED_INT64_ARRAY, TYPE_PACKED_FLOAT32_ARRAY, TYPE_PACKED_FLOAT64_ARRAY, TYPE_PACKED_STRING_ARRAY, TYPE_PACKED_VECTOR2_ARRAY, TYPE_PACKED_VECTOR3_ARRAY, TYPE_PACKED_COLOR_ARRAY, TYPE_PACKED_VECTOR4_ARRAY:
			if step == "size":
				return {"ok": true, "value": current_value.size()}
			if not step.is_valid_int():
				return {"ok": false}
			var packed_index: int = int(step)
			if packed_index < 0 or packed_index >= current_value.size():
				return {"ok": false}
			return {"ok": true, "value": current_value[packed_index]}
	if current_value is Dictionary:
		for key in current_value.keys():
			if str(key) == step:
				return {"ok": true, "value": current_value[key]}
		return {"ok": false}
	match typeof(current_value):
		TYPE_VECTOR2, TYPE_VECTOR2I:
			if step == "x" or step == "y":
				return {"ok": true, "value": current_value[step]}
		TYPE_VECTOR3, TYPE_VECTOR3I:
			if step == "x" or step == "y" or step == "z":
				return {"ok": true, "value": current_value[step]}
		TYPE_VECTOR4, TYPE_VECTOR4I, TYPE_QUATERNION:
			if step == "x" or step == "y" or step == "z" or step == "w":
				return {"ok": true, "value": current_value[step]}
		TYPE_COLOR:
			if step == "r" or step == "g" or step == "b" or step == "a":
				return {"ok": true, "value": current_value[step]}
		TYPE_PLANE:
			if step == "normal":
				return {"ok": true, "value": current_value.normal}
			if step == "d":
				return {"ok": true, "value": current_value.d}
		TYPE_RECT2, TYPE_RECT2I, TYPE_AABB:
			if step == "position" or step == "size" or step == "end":
				return {"ok": true, "value": current_value[step]}
		TYPE_BASIS:
			if step == "x" or step == "y" or step == "z":
				return {"ok": true, "value": current_value[step]}
		TYPE_TRANSFORM2D:
			if step == "x" or step == "y" or step == "origin":
				return {"ok": true, "value": current_value[step]}
		TYPE_TRANSFORM3D:
			if step == "basis" or step == "origin":
				return {"ok": true, "value": current_value[step]}
		TYPE_PROJECTION:
			if step == "x" or step == "y" or step == "z" or step == "w":
				return {"ok": true, "value": current_value[step]}
		TYPE_OBJECT:
			return _resolve_debug_object_path_step(current_value, step)
	return {"ok": false}

func _resolve_debug_object_path_step(current_value: Variant, step: String) -> Dictionary:
	if typeof(current_value) != TYPE_OBJECT or current_value == null:
		return {"ok": false}
	var object_value: Object = current_value
	if not is_instance_valid(object_value):
		return {"ok": false}
	if step == "@class_name":
		return {"ok": true, "value": object_value.get_class()}
	if step == "@instance_id":
		return {"ok": true, "value": object_value.get_instance_id()}
	if step == "@script_path":
		var script: Script = object_value.get_script() as Script
		return {"ok": true, "value": String(script.resource_path) if script else ""}
	if step == "@node_path" and object_value is Node:
		var node_value: Node = object_value as Node
		var node_path: String = str(node_value.get_path())
		if node_path.is_empty() and not String(node_value.name).is_empty():
			node_path = "/" + String(node_value.name)
		return {"ok": true, "value": node_path}
	if step == "@resource_path" and object_value is Resource:
		return {"ok": true, "value": String((object_value as Resource).resource_path)}
	for property_info in object_value.get_property_list():
		var property_name: String = str(property_info.get("name", ""))
		if property_name != step:
			continue
		if property_name == "script" or property_name.begins_with("_") or property_name.contains("/"):
			return {"ok": false}
		var usage: int = int(property_info.get("usage", 0))
		var include_property: bool = (usage & PROPERTY_USAGE_SCRIPT_VARIABLE) != 0 or (usage & PROPERTY_USAGE_STORAGE) != 0
		if not include_property:
			return {"ok": false}
		return {"ok": true, "value": object_value.get(property_name)}
	return {"ok": false}

func _register_evaluate_debug_expression(server_core: RefCounted) -> void:
	server_core.register_tool(
		"evaluate_debug_expression",
		"Evaluate an expression in the paused script debugger context for a given frame.",
		{
			"type": "object",
			"properties": {
				"expression": {"type": "string"},
				"frame": {"type": "integer", "default": 0},
				"session_id": {"type": "integer", "description": "Optional debugger session id. Omit or use -1 for all active sessions."}
			},
			"required": ["expression"]
		},
		Callable(self, "_tool_evaluate_debug_expression"),
		{"type": "object", "properties": {"status": {"type": "string"}, "expression": {"type": "string"}, "frame": {"type": "integer"}, "type": {"type": "string"}, "value": {}, "has_children": {"type": "boolean"}, "refresh_result": {"type": "object"}}},
		{"readOnlyHint": false, "destructiveHint": false, "idempotentHint": false, "openWorldHint": true},
		"supplementary", "Debug-Advanced"
	)

func _tool_evaluate_debug_expression(params: Dictionary) -> Dictionary:
	var expression: String = str(params.get("expression", "")).strip_edges()
	if expression.is_empty():
		return {"error": "Missing required parameter: expression"}
	var guard: Dictionary = MCPScriptSandbox.scan(expression, _sandbox_config())
	if guard.get("blocked", false):
		return {"error": guard.get("error", "blocked by script sandbox"), "blocked": true, "reason": guard.get("reason", ""), "category": guard.get("category", "")}
	var frame: int = max(0, int(params.get("frame", 0)))
	var bridge: RefCounted = _get_debugger_bridge()
	if not bridge:
		return {"error": "Debugger bridge is not available"}
	var refresh_result: Dictionary = bridge.request_evaluate(expression, frame, int(params.get("session_id", -1)))
	if refresh_result.has("error"):
		return refresh_result
	var evaluation: Variant = bridge.get_latest_evaluation(expression)
	if evaluation == null:
		return {
			"status": "pending",
			"expression": expression,
			"frame": frame,
			"refresh_result": refresh_result
		}
	var value: Variant = evaluation.get("value", null) if evaluation is Dictionary else evaluation
	return {
		"status": "success",
		"expression": expression,
		"frame": frame,
		"type": str(evaluation.get("type", "")),
		"value": _serialize_runtime_value(value),
		"variables_reference": bridge.get_evaluation_variables_reference(expression),
		"named_variables": _debug_named_variable_count(value),
		"indexed_variables": _debug_indexed_variable_count(value),
		"has_children": _debug_value_has_children(value),
		"refresh_result": refresh_result
	}

func _debug_scope_presentation_hint(scope_name: String) -> String:
	match scope_name:
		"local":
			return "locals"
		"member":
			return "members"
		"global":
			return "globals"
		"constant":
			return "constants"
		_:
			return "unknown"

func _debug_named_variable_count(value: Variant) -> int:
	match typeof(value):
		TYPE_DICTIONARY:
			return value.size()
		TYPE_VECTOR2, TYPE_VECTOR2I:
			return 2
		TYPE_VECTOR3, TYPE_VECTOR3I, TYPE_RECT2, TYPE_RECT2I, TYPE_AABB, TYPE_BASIS:
			return 3
		TYPE_PLANE, TYPE_TRANSFORM3D:
			return 2
		TYPE_TRANSFORM2D:
			return 3
		TYPE_VECTOR4, TYPE_VECTOR4I, TYPE_PROJECTION, TYPE_COLOR, TYPE_QUATERNION:
			return 4
		TYPE_OBJECT:
			return _expand_debug_object_entries(value, []).size()
		_:
			return 0

func _debug_indexed_variable_count(value: Variant) -> int:
	match typeof(value):
		TYPE_ARRAY, TYPE_PACKED_BYTE_ARRAY, TYPE_PACKED_INT32_ARRAY, TYPE_PACKED_INT64_ARRAY, TYPE_PACKED_FLOAT32_ARRAY, TYPE_PACKED_FLOAT64_ARRAY, TYPE_PACKED_STRING_ARRAY, TYPE_PACKED_VECTOR2_ARRAY, TYPE_PACKED_VECTOR3_ARRAY, TYPE_PACKED_COLOR_ARRAY, TYPE_PACKED_VECTOR4_ARRAY:
			return value.size() + 1
		_:
			return 0

func _expand_debug_value_entries(value: Variant, parent_path: Array) -> Array:
	var entries: Array = []
	if value is Array:
		entries.append({
			"name": "size",
			"path": parent_path + ["size"],
			"type": "int",
			"value": value.size(),
			"has_children": false
		})
		for index in range(value.size()):
			var item: Variant = value[index]
			entries.append({
				"name": str(index),
				"path": parent_path + [str(index)],
				"type": type_string(typeof(item)),
				"value": _serialize_runtime_value(item),
				"has_children": _debug_value_has_children(item)
			})
	elif value is Dictionary:
		for key in value.keys():
			var item: Variant = value[key]
			entries.append({
				"name": str(key),
				"path": parent_path + [str(key)],
				"type": type_string(typeof(item)),
				"value": _serialize_runtime_value(item),
				"has_children": _debug_value_has_children(item)
			})
	else:
		match typeof(value):
			TYPE_PACKED_BYTE_ARRAY, TYPE_PACKED_INT32_ARRAY, TYPE_PACKED_INT64_ARRAY, TYPE_PACKED_FLOAT32_ARRAY, TYPE_PACKED_FLOAT64_ARRAY, TYPE_PACKED_STRING_ARRAY, TYPE_PACKED_VECTOR2_ARRAY, TYPE_PACKED_VECTOR3_ARRAY, TYPE_PACKED_COLOR_ARRAY, TYPE_PACKED_VECTOR4_ARRAY:
				entries.append({
					"name": "size",
					"path": parent_path + ["size"],
					"type": "int",
					"value": value.size(),
					"has_children": false
				})
				for index in range(value.size()):
					var packed_item: Variant = value[index]
					entries.append({
						"name": str(index),
						"path": parent_path + [str(index)],
						"type": type_string(typeof(packed_item)),
						"value": _serialize_runtime_value(packed_item),
						"has_children": _debug_value_has_children(packed_item)
					})
				return entries
		var vector_entries: Array = _expand_debug_struct_fields(value, parent_path)
		if not vector_entries.is_empty():
			return vector_entries
		if typeof(value) == TYPE_OBJECT:
			return _expand_debug_object_entries(value, parent_path)
	return entries

func _expand_debug_struct_fields(value: Variant, parent_path: Array) -> Array:
	var entries: Array = []
	match typeof(value):
		TYPE_VECTOR2:
			entries.append_array([
				{"name": "x", "path": parent_path + ["x"], "type": "float", "value": value.x, "has_children": false},
				{"name": "y", "path": parent_path + ["y"], "type": "float", "value": value.y, "has_children": false}
			])
		TYPE_VECTOR2I:
			entries.append_array([
				{"name": "x", "path": parent_path + ["x"], "type": "int", "value": value.x, "has_children": false},
				{"name": "y", "path": parent_path + ["y"], "type": "int", "value": value.y, "has_children": false}
			])
		TYPE_VECTOR3:
			entries.append_array([
				{"name": "x", "path": parent_path + ["x"], "type": "float", "value": value.x, "has_children": false},
				{"name": "y", "path": parent_path + ["y"], "type": "float", "value": value.y, "has_children": false},
				{"name": "z", "path": parent_path + ["z"], "type": "float", "value": value.z, "has_children": false}
			])
		TYPE_VECTOR3I:
			entries.append_array([
				{"name": "x", "path": parent_path + ["x"], "type": "int", "value": value.x, "has_children": false},
				{"name": "y", "path": parent_path + ["y"], "type": "int", "value": value.y, "has_children": false},
				{"name": "z", "path": parent_path + ["z"], "type": "int", "value": value.z, "has_children": false}
			])
		TYPE_VECTOR4:
			entries.append_array([
				{"name": "x", "path": parent_path + ["x"], "type": "float", "value": value.x, "has_children": false},
				{"name": "y", "path": parent_path + ["y"], "type": "float", "value": value.y, "has_children": false},
				{"name": "z", "path": parent_path + ["z"], "type": "float", "value": value.z, "has_children": false},
				{"name": "w", "path": parent_path + ["w"], "type": "float", "value": value.w, "has_children": false}
			])
		TYPE_VECTOR4I:
			entries.append_array([
				{"name": "x", "path": parent_path + ["x"], "type": "int", "value": value.x, "has_children": false},
				{"name": "y", "path": parent_path + ["y"], "type": "int", "value": value.y, "has_children": false},
				{"name": "z", "path": parent_path + ["z"], "type": "int", "value": value.z, "has_children": false},
				{"name": "w", "path": parent_path + ["w"], "type": "int", "value": value.w, "has_children": false}
			])
		TYPE_PROJECTION:
			entries.append_array([
				{"name": "x", "path": parent_path + ["x"], "type": "Vector4", "value": _serialize_runtime_value(value.x), "has_children": true},
				{"name": "y", "path": parent_path + ["y"], "type": "Vector4", "value": _serialize_runtime_value(value.y), "has_children": true},
				{"name": "z", "path": parent_path + ["z"], "type": "Vector4", "value": _serialize_runtime_value(value.z), "has_children": true},
				{"name": "w", "path": parent_path + ["w"], "type": "Vector4", "value": _serialize_runtime_value(value.w), "has_children": true}
			])
		TYPE_PLANE:
			entries.append_array([
				{"name": "normal", "path": parent_path + ["normal"], "type": "Vector3", "value": _serialize_runtime_value(value.normal), "has_children": true},
				{"name": "d", "path": parent_path + ["d"], "type": "float", "value": value.d, "has_children": false}
			])
		TYPE_RECT2:
			entries.append_array([
				{"name": "position", "path": parent_path + ["position"], "type": "Vector2", "value": _serialize_runtime_value(value.position), "has_children": true},
				{"name": "size", "path": parent_path + ["size"], "type": "Vector2", "value": _serialize_runtime_value(value.size), "has_children": true},
				{"name": "end", "path": parent_path + ["end"], "type": "Vector2", "value": _serialize_runtime_value(value.end), "has_children": true}
			])
		TYPE_RECT2I:
			entries.append_array([
				{"name": "position", "path": parent_path + ["position"], "type": "Vector2i", "value": _serialize_runtime_value(value.position), "has_children": true},
				{"name": "size", "path": parent_path + ["size"], "type": "Vector2i", "value": _serialize_runtime_value(value.size), "has_children": true},
				{"name": "end", "path": parent_path + ["end"], "type": "Vector2i", "value": _serialize_runtime_value(value.end), "has_children": true}
			])
		TYPE_AABB:
			entries.append_array([
				{"name": "position", "path": parent_path + ["position"], "type": "Vector3", "value": _serialize_runtime_value(value.position), "has_children": true},
				{"name": "size", "path": parent_path + ["size"], "type": "Vector3", "value": _serialize_runtime_value(value.size), "has_children": true},
				{"name": "end", "path": parent_path + ["end"], "type": "Vector3", "value": _serialize_runtime_value(value.end), "has_children": true}
			])
		TYPE_BASIS:
			entries.append_array([
				{"name": "x", "path": parent_path + ["x"], "type": "Vector3", "value": _serialize_runtime_value(value.x), "has_children": true},
				{"name": "y", "path": parent_path + ["y"], "type": "Vector3", "value": _serialize_runtime_value(value.y), "has_children": true},
				{"name": "z", "path": parent_path + ["z"], "type": "Vector3", "value": _serialize_runtime_value(value.z), "has_children": true}
			])
		TYPE_COLOR:
			entries.append_array([
				{"name": "r", "path": parent_path + ["r"], "type": "float", "value": value.r, "has_children": false},
				{"name": "g", "path": parent_path + ["g"], "type": "float", "value": value.g, "has_children": false},
				{"name": "b", "path": parent_path + ["b"], "type": "float", "value": value.b, "has_children": false},
				{"name": "a", "path": parent_path + ["a"], "type": "float", "value": value.a, "has_children": false}
			])
		TYPE_QUATERNION:
			entries.append_array([
				{"name": "x", "path": parent_path + ["x"], "type": "float", "value": value.x, "has_children": false},
				{"name": "y", "path": parent_path + ["y"], "type": "float", "value": value.y, "has_children": false},
				{"name": "z", "path": parent_path + ["z"], "type": "float", "value": value.z, "has_children": false},
				{"name": "w", "path": parent_path + ["w"], "type": "float", "value": value.w, "has_children": false}
			])
		TYPE_TRANSFORM2D:
			entries.append_array([
				{"name": "x", "path": parent_path + ["x"], "type": "Vector2", "value": _serialize_runtime_value(value.x), "has_children": true},
				{"name": "y", "path": parent_path + ["y"], "type": "Vector2", "value": _serialize_runtime_value(value.y), "has_children": true},
				{"name": "origin", "path": parent_path + ["origin"], "type": "Vector2", "value": _serialize_runtime_value(value.origin), "has_children": true}
			])
		TYPE_TRANSFORM3D:
			entries.append_array([
				{"name": "basis", "path": parent_path + ["basis"], "type": "Basis", "value": _serialize_runtime_value(value.basis), "has_children": true},
				{"name": "origin", "path": parent_path + ["origin"], "type": "Vector3", "value": _serialize_runtime_value(value.origin), "has_children": true}
			])
	return entries

func _expand_debug_object_entries(value: Variant, parent_path: Array) -> Array:
	if typeof(value) != TYPE_OBJECT or value == null:
		return []
	var object_value: Object = value
	if not is_instance_valid(object_value):
		return []
	var entries: Array = []
	var seen: Dictionary = {}
	entries.append({
		"name": "@class_name",
		"path": parent_path + ["@class_name"],
		"type": "String",
		"value": object_value.get_class(),
		"has_children": false
	})
	entries.append({
		"name": "@instance_id",
		"path": parent_path + ["@instance_id"],
		"type": "int",
		"value": object_value.get_instance_id(),
		"has_children": false
	})
	var script: Script = object_value.get_script() as Script
	entries.append({
		"name": "@script_path",
		"path": parent_path + ["@script_path"],
		"type": "String",
		"value": String(script.resource_path) if script else "",
		"has_children": false
	})
	if object_value is Node:
		var node_value: Node = object_value as Node
		var node_path: String = str(node_value.get_path())
		if node_path.is_empty() and not String(node_value.name).is_empty():
			node_path = "/" + String(node_value.name)
		entries.append({
			"name": "@node_path",
			"path": parent_path + ["@node_path"],
			"type": "NodePath",
			"value": node_path,
			"has_children": false
		})
	elif object_value is Resource:
		entries.append({
			"name": "@resource_path",
			"path": parent_path + ["@resource_path"],
			"type": "String",
			"value": String((object_value as Resource).resource_path),
			"has_children": false
		})
	for property_info in object_value.get_property_list():
		var property_name: String = str(property_info.get("name", ""))
		if property_name.is_empty() or seen.has(property_name):
			continue
		if property_name == "script" or property_name.begins_with("_") or property_name.contains("/"):
			continue
		var usage: int = int(property_info.get("usage", 0))
		var include_property: bool = (usage & PROPERTY_USAGE_SCRIPT_VARIABLE) != 0 or (usage & PROPERTY_USAGE_STORAGE) != 0
		if not include_property:
			continue
		seen[property_name] = true
		var property_value: Variant = object_value.get(property_name)
		entries.append({
			"name": property_name,
			"path": parent_path + [property_name],
			"type": type_string(typeof(property_value)),
			"value": _serialize_runtime_value(property_value),
			"has_children": _debug_value_has_children(property_value)
		})
	return entries

func _debug_value_has_children(value: Variant) -> bool:
	match typeof(value):
		TYPE_ARRAY, TYPE_DICTIONARY, TYPE_VECTOR2, TYPE_VECTOR2I, TYPE_VECTOR3, TYPE_VECTOR3I, TYPE_VECTOR4, TYPE_VECTOR4I, TYPE_PROJECTION, TYPE_PLANE, TYPE_RECT2, TYPE_RECT2I, TYPE_AABB, TYPE_BASIS, TYPE_COLOR, TYPE_QUATERNION, TYPE_TRANSFORM2D, TYPE_TRANSFORM3D:
			return true
		TYPE_OBJECT:
			return not _expand_debug_object_entries(value, []).is_empty()
		_:
			return false

func _serialize_runtime_value(value: Variant) -> Variant:
	if value == null:
		return null
	match typeof(value):
		TYPE_BOOL, TYPE_INT, TYPE_FLOAT, TYPE_STRING:
			return value
		TYPE_STRING_NAME:
			return str(value)
		TYPE_NODE_PATH:
			return str(value)
		TYPE_RID:
			return {
				"id": value.get_id(),
				"valid": value.is_valid()
			}
		TYPE_CALLABLE:
			return _serialize_runtime_callable(value)
		TYPE_SIGNAL:
			return _serialize_runtime_signal(value)
		TYPE_VECTOR2:
			return {"x": value.x, "y": value.y}
		TYPE_VECTOR2I:
			return {"x": value.x, "y": value.y}
		TYPE_VECTOR3:
			return {"x": value.x, "y": value.y, "z": value.z}
		TYPE_VECTOR3I:
			return {"x": value.x, "y": value.y, "z": value.z}
		TYPE_VECTOR4:
			return {"x": value.x, "y": value.y, "z": value.z, "w": value.w}
		TYPE_VECTOR4I:
			return {"x": value.x, "y": value.y, "z": value.z, "w": value.w}
		TYPE_PROJECTION:
			return {
				"x": _serialize_runtime_value(value.x),
				"y": _serialize_runtime_value(value.y),
				"z": _serialize_runtime_value(value.z),
				"w": _serialize_runtime_value(value.w)
			}
		TYPE_PLANE:
			return {
				"normal": _serialize_runtime_value(value.normal),
				"d": value.d
			}
		TYPE_RECT2:
			return {
				"position": _serialize_runtime_value(value.position),
				"size": _serialize_runtime_value(value.size),
				"end": _serialize_runtime_value(value.end)
			}
		TYPE_RECT2I:
			return {
				"position": _serialize_runtime_value(value.position),
				"size": _serialize_runtime_value(value.size),
				"end": _serialize_runtime_value(value.end)
			}
		TYPE_AABB:
			return {
				"position": _serialize_runtime_value(value.position),
				"size": _serialize_runtime_value(value.size),
				"end": _serialize_runtime_value(value.end)
			}
		TYPE_BASIS:
			return {
				"x": _serialize_runtime_value(value.x),
				"y": _serialize_runtime_value(value.y),
				"z": _serialize_runtime_value(value.z)
			}
		TYPE_COLOR:
			return {"r": value.r, "g": value.g, "b": value.b, "a": value.a}
		TYPE_QUATERNION:
			return {"x": value.x, "y": value.y, "z": value.z, "w": value.w}
		TYPE_TRANSFORM2D:
			return {
				"x": _serialize_runtime_value(value.x),
				"y": _serialize_runtime_value(value.y),
				"origin": _serialize_runtime_value(value.origin)
			}
		TYPE_TRANSFORM3D:
			return {
				"basis": _serialize_runtime_value(value.basis),
				"origin": _serialize_runtime_value(value.origin)
			}
		TYPE_OBJECT:
			return _serialize_runtime_object(value)
		TYPE_ARRAY:
			var array_result: Array = []
			for item in value:
				array_result.append(_serialize_runtime_value(item))
			return array_result
		TYPE_DICTIONARY:
			var dict_result: Dictionary = {}
			for key in value:
				dict_result[str(key)] = _serialize_runtime_value(value[key])
			return dict_result
		_:
			return str(value)

func _serialize_runtime_object(value: Variant) -> Dictionary:
	if typeof(value) != TYPE_OBJECT or value == null:
		return {}
	var object_value: Object = value
	if not is_instance_valid(object_value):
		return {"class_name": "<freed>"}
	var properties: Dictionary = {}
	for entry in _expand_debug_object_entries(object_value, []):
		properties[str(entry.get("name", ""))] = entry.get("value", null)
	var serialized: Dictionary = {
		"class_name": object_value.get_class(),
		"instance_id": object_value.get_instance_id(),
		"script_path": "",
		"properties": properties
	}
	var script: Script = object_value.get_script() as Script
	if script:
		serialized["script_path"] = String(script.resource_path)
	if object_value is Node:
		var node_value: Node = object_value as Node
		var node_path: String = str(node_value.get_path())
		if node_path.is_empty() and not String(node_value.name).is_empty():
			node_path = "/" + String(node_value.name)
		serialized["node_path"] = node_path
	elif object_value is Resource:
		serialized["resource_path"] = String((object_value as Resource).resource_path)
	return serialized

func _serialize_runtime_callable(value: Variant) -> Dictionary:
	if typeof(value) != TYPE_CALLABLE:
		return {}
	var callable_value: Callable = value
	var target: Object = callable_value.get_object()
	return {
		"method": callable_value.get_method(),
		"object_id": callable_value.get_object_id(),
		"object_class": target.get_class() if is_instance_valid(target) else "",
		"is_custom": callable_value.is_custom(),
		"is_standard": callable_value.is_standard(),
		"is_null": callable_value.is_null(),
		"is_valid": callable_value.is_valid(),
		"bound_argument_count": callable_value.get_bound_arguments_count()
	}

func _serialize_runtime_signal(value: Variant) -> Dictionary:
	if typeof(value) != TYPE_SIGNAL:
		return {}
	var signal_value: Signal = value
	var target: Object = signal_value.get_object()
	return {
		"name": signal_value.get_name(),
		"object_id": target.get_instance_id() if is_instance_valid(target) else 0,
		"object_class": target.get_class() if is_instance_valid(target) else "",
		"is_null": signal_value.is_null()
	}

func _register_install_runtime_probe(server_core: RefCounted) -> void:
	server_core.register_tool(
		"install_runtime_probe",
		"Register the MCP runtime probe as an Autoload singleton so the running game can answer debugger messages. Survives scene changes.",
		{
			"type": "object",
			"properties": {
				"node_name": {"type": "string", "default": "MCPRuntimeProbe"}
			}
		},
		Callable(self, "_tool_install_runtime_probe"),
		{"type": "object", "properties": {"status": {"type": "string"}, "node_path": {"type": "string"}, "autoload": {"type": "boolean"}}},
		{"readOnlyHint": false, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false},
		"supplementary", "Debug-Advanced"
	)

func _tool_install_runtime_probe(params: Dictionary) -> Dictionary:
	var editor_interface: EditorInterface = _get_editor_interface()
	if not editor_interface:
		return {"error": "Editor interface not available"}
	
	var node_name: String = params.get("node_name", "MCPRuntimeProbe")
	if node_name.is_empty():
		return {"error": "node_name cannot be empty"}
	
	# Register the probe as an Autoload singleton via ProjectSettings.
	# Using the "*" prefix marks it as a global singleton that survives
	# scene changes and is never written into .tscn files.
	var autoload_key: String = "autoload/" + node_name
	var autoload_path: String = "*res://addons/godot_mcp/runtime/mcp_runtime_probe.gd"
	
	if ProjectSettings.has_setting(autoload_key):
		return {"status": "already_installed", "node_path": node_name}

	ProjectSettings.set_setting(autoload_key, autoload_path)
	ProjectSettings.save()
	# 探针以 autoload 落地：autoload 变化改变脚本的编译结论，全清编译 memo。
	ScriptCompileMemoScript.clear()

	return {"status": "success", "node_path": node_name, "autoload": true}

func _register_remove_runtime_probe(server_core: RefCounted) -> void:
	server_core.register_tool(
		"remove_runtime_probe",
		"Remove the MCP runtime probe node from the current scene.",
		{
			"type": "object",
			"properties": {
				"node_name": {"type": "string", "default": "MCPRuntimeProbe"}
			}
		},
		Callable(self, "_tool_remove_runtime_probe"),
		{"type": "object", "properties": {"status": {"type": "string"}, "removed_node": {"type": "string"}}},
		{"readOnlyHint": false, "destructiveHint": true, "idempotentHint": true, "openWorldHint": false},
		"supplementary", "Debug-Advanced"
	)

func _tool_remove_runtime_probe(params: Dictionary) -> Dictionary:
	var node_name: String = params.get("node_name", "MCPRuntimeProbe")
	var autoload_key: String = "autoload/" + node_name
	
	if not ProjectSettings.has_setting(autoload_key):
		return {"status": "not_installed", "removed_node": ""}

	ProjectSettings.clear(autoload_key)
	ProjectSettings.save()
	# 同 install：autoload 移除翻转编译结论，全清编译 memo。
	ScriptCompileMemoScript.clear()
	return {"status": "success", "removed_node": node_name}

func _register_request_debug_break(server_core: RefCounted) -> void:
	server_core.register_tool(
		"request_debug_break",
		"Ask the MCP runtime probe to enter Godot's script debugger break loop.",
		{
			"type": "object",
			"properties": {
				"session_id": {"type": "integer", "description": "Optional debugger session id. Omit or use -1 for all active sessions."}
			}
		},
		Callable(self, "_tool_request_debug_break"),
		{"type": "object", "properties": {"status": {"type": "string"}, "sessions_updated": {"type": "integer"}}},
		{"readOnlyHint": false, "destructiveHint": false, "idempotentHint": false, "openWorldHint": true},
		"supplementary", "Debug-Advanced"
	)

func _tool_request_debug_break(params: Dictionary) -> Dictionary:
	var bridge: RefCounted = _get_debugger_bridge()
	if not bridge:
		return {"error": "Debugger bridge is not available"}
	return bridge.send_debugger_message("mcp:debug_break", [], params.get("session_id", -1))

func _register_send_debug_command(server_core: RefCounted) -> void:
	server_core.register_tool(
		"send_debug_command",
		"Send a raw Godot script-debugger command to active breaked sessions. Commands are handled by Godot's debug loop.",
		{
			"type": "object",
			"properties": {
				"command": {"type": "string", "enum": ["step", "next", "out", "continue", "get_stack_dump", "get_stack_frame_vars"]},
				"data": {"type": "array", "items": {"type": "object"}, "description": "Command payload, e.g. [0] for get_stack_frame_vars frame 0."},
				"session_id": {"type": "integer", "description": "Optional debugger session id. Omit or use -1 for all active sessions."}
			},
			"required": ["command"]
		},
		Callable(self, "_tool_send_debug_command"),
		{"type": "object", "properties": {"status": {"type": "string"}, "sessions_updated": {"type": "integer"}, "note": {"type": "string"}}},
		{"readOnlyHint": false, "destructiveHint": false, "idempotentHint": false, "openWorldHint": true},
		"supplementary", "Debug-Advanced"
	)

func _tool_send_debug_command(params: Dictionary) -> Dictionary:
	var command: String = params.get("command", "")
	var allowed: Array[String] = ["step", "next", "out", "continue", "get_stack_dump", "get_stack_frame_vars"]
	if not allowed.has(command):
		return {"error": "Unsupported debug command: " + command}
	var bridge: RefCounted = _get_debugger_bridge()
	if not bridge:
		return {"error": "Debugger bridge is not available"}
	var result: Dictionary = bridge.send_debugger_message(command, params.get("data", []), params.get("session_id", -1))
	if command.begins_with("get_stack"):
		result["note"] = "Godot may route stack responses to the built-in ScriptEditorDebugger UI instead of EditorDebuggerPlugin captures."
	return result

func _register_debug_step_into(server_core: RefCounted) -> void:
	_register_debug_execution_control_tool(
		server_core,
		"debug_step_into",
		"Step into the next statement in the active Godot script debugger session.",
		"step",
		"breaked"
	)

func _register_debug_step_over(server_core: RefCounted) -> void:
	_register_debug_execution_control_tool(
		server_core,
		"debug_step_over",
		"Step over the next statement in the active Godot script debugger session.",
		"next",
		"breaked"
	)

func _register_debug_step_out(server_core: RefCounted) -> void:
	_register_debug_execution_control_tool(
		server_core,
		"debug_step_out",
		"Step out of the current frame in the active Godot script debugger session.",
		"out",
		"breaked"
	)

func _register_debug_continue(server_core: RefCounted) -> void:
	_register_debug_execution_control_tool(
		server_core,
		"debug_continue",
		"Resume execution in the active Godot script debugger session.",
		"continue",
		"running"
	)

func _register_debug_execution_control_tool(server_core: RefCounted, tool_name: String, description: String, command: String, target_state: String) -> void:
	server_core.register_tool(
		tool_name,
		description,
		{
			"type": "object",
			"properties": {
				"session_id": {"type": "integer", "description": "Optional debugger session id. Omit or use -1 for all active sessions."}
			}
		},
		func(params: Dictionary) -> Dictionary:
			return _tool_debug_execution_control(params, command, target_state),
		{
			"type": "object",
			"properties": {
				"status": {"type": "string"},
				"sessions_updated": {"type": "integer"},
				"command": {"type": "string"},
				"target_state": {"type": "string"}
			}
		},
		{"readOnlyHint": false, "destructiveHint": false, "idempotentHint": false, "openWorldHint": true},
		"supplementary", "Debug-Advanced"
	)

func _tool_debug_execution_control(params: Dictionary, command: String, target_state: String) -> Dictionary:
	var bridge: RefCounted = _get_debugger_bridge()
	if not bridge:
		return {"error": "Debugger bridge is not available"}
	var result: Dictionary = bridge.send_debugger_message(command, [], params.get("session_id", -1))
	result["command"] = command
	result["target_state"] = target_state
	return result

func _register_debug_step_into_and_wait(server_core: RefCounted) -> void:
	_register_debug_execution_wait_tool(server_core, "debug_step_into_and_wait", "Send a step-into command and wait for the debugger to report a breaked state.", "step", "breaked")

func _register_debug_step_over_and_wait(server_core: RefCounted) -> void:
	_register_debug_execution_wait_tool(server_core, "debug_step_over_and_wait", "Send a step-over command and wait for the debugger to report a breaked state.", "next", "breaked")

func _register_debug_step_out_and_wait(server_core: RefCounted) -> void:
	_register_debug_execution_wait_tool(server_core, "debug_step_out_and_wait", "Send a step-out command and wait for the debugger to report a breaked state.", "out", "breaked")

func _register_debug_continue_and_wait(server_core: RefCounted) -> void:
	_register_debug_execution_wait_tool(server_core, "debug_continue_and_wait", "Send a continue command and wait for the debugger to report a running state.", "continue", "running")

func _register_debug_execution_wait_tool(server_core: RefCounted, tool_name: String, description: String, command: String, target_state: String) -> void:
	server_core.register_tool(
		tool_name,
		description,
		{
			"type": "object",
			"properties": {
				"session_id": {"type": "integer", "description": "Optional debugger session id. Omit or use -1 for all active sessions."},
				"timeout_ms": {"type": "integer", "default": 3000},
				"poll_interval_ms": {"type": "integer", "default": 100}
			}
		},
		func(params: Dictionary) -> Dictionary:
			return _tool_debug_execution_and_wait(params, command, target_state),
		{"type": "object", "properties": {"status": {"type": "string"}, "command": {"type": "string"}, "target_state": {"type": "string"}, "matched_state": {"type": "object"}, "sessions": {"type": "array"}, "state_events": {"type": "array"}, "attempts": {"type": "integer"}, "elapsed_ms": {"type": "integer"}}},
		{"readOnlyHint": false, "destructiveHint": false, "idempotentHint": false, "openWorldHint": true},
		"supplementary", "Debug-Advanced"
	)

func _tool_debug_execution_and_wait(params: Dictionary, command: String, target_state: String) -> Dictionary:
	var command_result: Dictionary = _tool_debug_execution_control(params, command, target_state)
	if command_result.has("error"):
		return command_result
	var wait_params: Dictionary = {
		"target_state": target_state,
		"session_id": params.get("session_id", -1),
		"timeout_ms": params.get("timeout_ms", 3000),
		"poll_interval_ms": params.get("poll_interval_ms", 100)
	}
	var wait_result: Dictionary = _tool_await_debugger_state(wait_params)
	wait_result["command"] = command
	wait_result["target_state"] = target_state
	wait_result["command_result"] = command_result
	return wait_result

func _register_await_debugger_state(server_core: RefCounted) -> void:
	server_core.register_tool(
		"await_debugger_state",
		"Check whether debugger sessions have reached the target execution state using the latest bridge snapshots. Call repeatedly from the client after continue/step/next/out/break actions.",
		{
			"type": "object",
			"properties": {
				"target_state": {"type": "string", "enum": ["breaked", "running", "stopped"], "default": "breaked"},
				"session_id": {"type": "integer", "description": "Optional debugger session id. Omit or use -1 for any session."},
				"timeout_ms": {"type": "integer", "default": 3000},
				"poll_interval_ms": {"type": "integer", "default": 100}
			}
		},
		Callable(self, "_tool_await_debugger_state"),
		{"type": "object", "properties": {"status": {"type": "string"}, "target_state": {"type": "string"}, "matched_state": {"type": "object"}, "sessions": {"type": "array"}, "state_events": {"type": "array"}, "attempts": {"type": "integer"}, "elapsed_ms": {"type": "integer"}}},
		{"readOnlyHint": true, "destructiveHint": false, "idempotentHint": false, "openWorldHint": false},
		"supplementary", "Debug-Advanced"
	)

func _tool_await_debugger_state(params: Dictionary) -> Dictionary:
	var bridge: RefCounted = _get_debugger_bridge()
	if not bridge:
		return {"error": "Debugger bridge is not available"}
	var target_state: String = str(params.get("target_state", "breaked"))
	var timeout_ms: int = max(1, int(params.get("timeout_ms", 3000)))
	var session_id: int = int(params.get("session_id", -1))
	var last_sessions: Array = bridge.get_sessions_info()
	var state_events: Array = bridge.get_state_events(20, 0, "desc").get("events", [])
	var matched_state: Dictionary = _find_matching_debug_state(target_state, last_sessions, state_events, session_id)
	if not matched_state.is_empty():
		return {
			"status": "success",
			"target_state": target_state,
			"matched_state": matched_state,
			"sessions": last_sessions,
			"state_events": state_events,
			"attempts": 1,
			"elapsed_ms": 0
		}
	return {
		"status": "pending",
		"target_state": target_state,
		"matched_state": {},
		"sessions": last_sessions,
		"state_events": state_events,
		"attempts": 1,
		"elapsed_ms": timeout_ms
	}

func _find_matching_debug_state(target_state: String, sessions: Array, state_events: Array, session_id: int) -> Dictionary:
	match target_state:
		"breaked":
			for session in sessions:
				if session_id >= 0 and int(session.get("session_id", -1)) != session_id:
					continue
				if session.get("breaked", false):
					var result: Dictionary = session.duplicate(true)
					result["state"] = "breaked"
					for event in state_events:
						if event.get("state", "") == "breaked":
							result["reason"] = event.get("reason", "")
							result["has_stackdump"] = event.get("has_stackdump", false)
							break
					return result
		"running":
			for session in sessions:
				if session_id >= 0 and int(session.get("session_id", -1)) != session_id:
					continue
				if session.get("active", false) and not session.get("breaked", false):
					var result: Dictionary = session.duplicate(true)
					result["state"] = "running"
					for event in state_events:
						if event.get("state", "") == "running":
							result["reason"] = event.get("reason", "")
							break
					return result
		"stopped":
			if session_id >= 0:
				for session in sessions:
					if int(session.get("session_id", -1)) == session_id:
						return {}
			if sessions.is_empty():
				for event in state_events:
					if event.get("state", "") == "stopped":
						return event.duplicate(true)
				return {"state": "stopped"}
	return {}
