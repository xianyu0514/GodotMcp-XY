# debug_tools_native.gd - Debug Tools native implementation (main class: shared helpers + log/script-execution domain)

@tool
class_name DebugToolsNative
extends RefCounted

var _editor_interface: EditorInterface = null
var _log_buffer: Array[String] = []
var _max_log_lines: int = 1000
var _server_core: RefCounted = null
var _log_mutex: Mutex = Mutex.new()
var _execution_mutex: Mutex = Mutex.new()

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

# 沙箱护栏配置：默认跟随 security_level（STRICT -> 开启）。取不到时默认安全（开启）。
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
	if server_core.has_signal("log_message"):
		server_core.log_message.connect(_on_log_message)

	_register_get_editor_logs(server_core)
	_register_execute_script(server_core)
	_register_get_performance_metrics(server_core)
	_register_debug_print(server_core)
	_register_execute_editor_script(server_core)
	_register_clear_output(server_core)

func _on_log_message(level: String, message: String) -> void:
	var log_entry: String = "[%s] %s" % [level, message]
	_log_mutex.lock()
	_log_buffer.append(log_entry)
	if _log_buffer.size() > _max_log_lines:
		_log_buffer.remove_at(0)
	_log_mutex.unlock()

# ============================================================================
# get_editor_logs - 获取编辑器日志
# ============================================================================

func _register_get_editor_logs(server_core: RefCounted) -> void:
	var tool_name: String = "get_editor_logs"
	var description: String = "Get recent log messages from the editor or runtime. Supports filtering by source, type, and pagination."

	var input_schema: Dictionary = {
		"type": "object",
		"properties": {
			"source": {
				"type": "string",
				"description": "Log source: 'mcp' (MCP server logs, default), 'runtime' (user://logs/godot.log), 'editor_panel' (Godot editor output panel including print/errors/warnings).",
				"default": "mcp",
				"enum": ["mcp", "runtime", "editor_panel"]
			},
			"type": {
				"type": "array",
				"items": {"type": "string"},
				"description": "Filter by log types (e.g. ['Error', 'Warning', 'Info']). Only applies to MCP source. Empty array returns all."
			},
			"count": {
				"type": "integer",
				"description": "Maximum number of log lines to return. Default is 100.",
				"default": 100
			},
			"offset": {
				"type": "integer",
				"description": "Number of log entries to skip. Default is 0.",
				"default": 0
			},
			"order": {
				"type": "string",
				"description": "Sort order: 'desc' (newest first, default) or 'asc' (oldest first).",
				"default": "desc",
				"enum": ["desc", "asc"]
			}
		}
	}

	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"logs": {
				"type": "array",
				"items": {"type": "object"}
			},
			"count": {"type": "integer"},
			"total_available": {"type": "integer"},
			"source": {"type": "string"}
		}
	}

	var annotations: Dictionary = {
		"readOnlyHint": true,
		"destructiveHint": false,
		"idempotentHint": true,
		"openWorldHint": false
	}

	server_core.register_tool(tool_name, description, input_schema,
						  Callable(self, "_tool_get_editor_logs"),
						  output_schema, annotations, "core", "Debug")

func _tool_get_editor_logs(params: Dictionary) -> Dictionary:
	var source: String = params.get("source", "mcp")
	var types: Array = params.get("type", [])
	var count: int = params.get("count", 100)
	var offset: int = params.get("offset", 0)
	var order: String = params.get("order", "desc")

	if source == "runtime":
		return _get_runtime_logs(types, count, offset, order)
	elif source == "editor_panel":
		return _get_editor_panel_logs(types, count, offset, order)

	return _get_mcp_logs(types, count, offset, order)

# ============================================================================
# Shared static helpers (debugger bridge + runtime probe request machinery).
# Called by DebugBridgeTools / DebugRuntimeTools / DebugVerifyTools through
# DebugToolsNative.<helper>() so the pending-probe state is shared across domains.
# ============================================================================

static var _pending_runtime_probe_requests: Dictionary = {}

static func _get_debugger_bridge() -> RefCounted:
	if Engine.has_meta("GodotMCPPlugin"):
		var plugin = Engine.get_meta("GodotMCPPlugin")
		if plugin and plugin.has_method("get_debugger_bridge"):
			return plugin.get_debugger_bridge()
	return null

static func _request_runtime_probe(command: String, payload: Array, response_messages: Array, params: Dictionary, match_fields: Dictionary = {}, allow_send: bool = true) -> Dictionary:
	var bridge: RefCounted = _get_debugger_bridge()
	if not bridge:
		return {"error": "Debugger bridge is not available"}
	var session_id: int = int(params.get("session_id", -1))
	var timeout_ms: int = maxi(int(params.get("timeout_ms", 3000)), 1)
	var request_key: String = _make_runtime_probe_request_key(command, payload, session_id, response_messages, match_fields)
	var now_ms: int = Time.get_ticks_msec()
	var pending_entry: Dictionary = _pending_runtime_probe_requests.get(request_key, {})

	var needs_send: bool = pending_entry.is_empty() or now_ms > int(pending_entry.get("expires_at_ms", 0))
	if needs_send and not allow_send:
		# Polling mode: do not dispatch a fresh probe. Reuse the existing pending
		# entry (if any) to extract a response, otherwise report still-pending.
		if pending_entry.is_empty():
			return {"status": "pending", "response_messages": response_messages}
	elif needs_send:
		if not pending_entry.is_empty():
			_pending_runtime_probe_requests.erase(request_key)
		var baseline_sequence: int = bridge.get_message_sequence() if bridge.has_method("get_message_sequence") else 0
		var refresh_result: Dictionary = bridge.send_debugger_message("mcp:" + command, payload, session_id)
		if refresh_result.has("error"):
			return refresh_result
		if refresh_result.get("status", "") == "no_active_sessions":
			return {"status": "no_active_sessions", "refresh_result": refresh_result}
		pending_entry = {
			"baseline_sequence": baseline_sequence,
			"refresh_result": refresh_result,
			"expires_at_ms": now_ms + timeout_ms
		}
		_pending_runtime_probe_requests[request_key] = pending_entry

	var response: Dictionary = _extract_pending_runtime_probe_response(bridge, pending_entry, response_messages, match_fields)
	if not response.is_empty():
		_pending_runtime_probe_requests.erase(request_key)
		response["refresh_result"] = pending_entry.get("refresh_result", {})
		return response

	return {
		"status": "pending",
		"refresh_result": pending_entry.get("refresh_result", {}),
		"response_messages": response_messages
	}

static func _make_runtime_probe_request_key(command: String, payload: Array, session_id: int, response_messages: Array, match_fields: Dictionary) -> String:
	# Use str() concatenation instead of JSON.stringify for lower overhead per call.
	# Include payload only when non-empty to differentiate calls with different
	# arguments (e.g. evaluate_expression with different expressions).
	# Empty payloads (common case) are omitted to keep the key shorter/faster.
	var key: String = command + "|" + str(session_id) + "|" + str(response_messages)
	if not payload.is_empty():
		key += "|" + str(payload)
	if not match_fields.is_empty():
		key += "|" + str(match_fields)
	return key

static func _extract_pending_runtime_probe_response(bridge: RefCounted, pending_entry: Dictionary, response_messages: Array, match_fields: Dictionary) -> Dictionary:
	# Force the debugger bridge to refresh captured message visibility before querying
	# for the latest runtime payload. Without this, headless editor sessions can leave
	# freshly received custom EngineDebugger captures invisible until another bridge read.
	bridge.get_captured_messages(1, 0, "desc")

	var response_entry: Dictionary = {}
	if bridge.has_method("get_captured_message_after_sequence"):
		response_entry = bridge.get_captured_message_after_sequence(
			int(pending_entry.get("baseline_sequence", 0)),
			response_messages,
			["mcp:error"],
			match_fields
		)

	if not response_entry.is_empty():
		var message_name: String = str(response_entry.get("message", ""))
		var captured_data: Array = response_entry.get("data", [])
		var runtime_payload: Variant = captured_data[0] if not captured_data.is_empty() else null
		if message_name == "mcp:error":
			return {"error": str(runtime_payload.get("message", runtime_payload)) if runtime_payload is Dictionary else str(runtime_payload)}
		if runtime_payload is Dictionary:
			var response: Dictionary = runtime_payload.duplicate(true)
			response["status"] = "success"
			return response
		if runtime_payload != null:
			return {"status": "success", "value": runtime_payload}

	# No fresh response yet. Return pending so the poll loop keeps waiting for the
	# newly-sent probe response. The eager stale fallback that lived here caused
	# repeated identical expressions to return "stale" immediately, which the poll
	# loop treated as retryable, burning the full timeout window on every call.
	# Stale fallback now happens only after the poll loop times out.
	return {}

static func _request_runtime_probe_poll(
	command: String, payload: Array, response_messages: Array,
	params: Dictionary, match_fields: Dictionary = {}
) -> Dictionary:
	# Wait for the runtime probe to signal readiness before sending requests.
	# This avoids the race where a request arrives before the probe has
	# registered its EngineDebugger message capture in the game process.
	var bridge: RefCounted = _get_debugger_bridge()
	if bridge and bridge.has_method("wait_for_probe_ready"):
		var probe_session_id: int = int(params.get("session_id", -1))
		# Fast path: skip await (and its coroutine overhead) when probe is already ready.
		# This saves ~1 frame (~16ms) per runtime tool call after the first.
		if bridge.has_method("is_probe_ready") and bridge.is_probe_ready(probe_session_id):
			pass  # Already ready — no await needed
		else:
			await bridge.wait_for_probe_ready(probe_session_id, 2000)
	# Wraps _request_runtime_probe with a poll loop that retries when pending.
	# Uses await get_tree().process_frame to let the editor main loop advance
	# so EngineDebugger IPC messages are dispatched to _capture().
	var result: Dictionary = _request_runtime_probe(command, payload, response_messages, params, match_fields)
	if result.get("status") in ["pending", "stale"]:
		var timeout_ms: int = maxi(int(params.get("timeout_ms", 3000)), 100)
		var deadline_ms: int = Time.get_ticks_msec() + timeout_ms
		var tree: SceneTree = Engine.get_main_loop() as SceneTree
		while Time.get_ticks_msec() < deadline_ms:
			if tree:
				await tree.process_frame
			else:
				OS.delay_msec(16)
			# Poll the in-flight request without re-sending. The single probe was
			# already dispatched above; re-sending here would burn extra debugger
			# messages each frame (and once more when the pending entry expires a
			# few ms before this loop's deadline). A fresh probe is only sent on
			# the next top-level call.
			result = _request_runtime_probe(command, payload, response_messages, params, match_fields, false)
			if result.get("status") not in ["pending", "stale"]:
				break
	# Timeout expired without a fresh response. Fall back to the latest cached
	# payload matching the request (if any) so callers still get data rather than
	# an empty result. This is the only place stale data is served now.
	if result.get("status") in ["pending", "stale"]:
		for message_name in response_messages:
			var cached_payload: Variant = bridge.get_latest_message_payload(message_name, match_fields) if bridge else null
			if cached_payload is Dictionary:
				result = cached_payload.duplicate(true)
				result["status"] = "success"
				result["from_cache"] = true
				result["stale"] = true
				return result
			if cached_payload != null:
				return {"status": "success", "from_cache": true, "stale": true, "value": cached_payload}
		# No cached payload either - return the pending status as-is
		result["status"] = "timeout"
		return result
	return result
func _get_mcp_logs(types: Array, count: int, offset: int, order: String) -> Dictionary:
	_log_mutex.lock()
	if _log_buffer.is_empty():
		_log_mutex.unlock()
		return {
			"logs": [],
			"count": 0,
			"total_available": 0,
			"source": "mcp"
		}

	var total_available: int = _log_buffer.size()
	var result_logs: Array = []
	if types.is_empty():
		# 快路径：无类型过滤时先切窗口再解析，只复制/解析 count 行
		# （默认 desc+100 最多处理 100 行，而非整个 1000 行缓冲）。
		var window_lines: Array[String] = []
		var window_indexes: Array[int] = []
		if order == "desc":
			for i in range(total_available - 1, -1, -1):
				window_indexes.append(i)
		else:
			for i in range(total_available):
				window_indexes.append(i)
		var start: int = mini(offset, window_indexes.size())
		var end: int = mini(start + count, window_indexes.size())
		for k in range(start, end):
			window_lines.append(_log_buffer[window_indexes[k]])
		_log_mutex.unlock()
		for k in range(window_lines.size()):
			var parsed_entry: Dictionary = _parse_mcp_log_line(window_indexes[start + k], window_lines[k])
			result_logs.append(parsed_entry)
		return {
			"logs": result_logs,
			"count": result_logs.size(),
			"total_available": total_available,
			"source": "mcp"
		}

	var all_entries: Array = []
	for i in range(_log_buffer.size()):
		all_entries.append(_parse_mcp_log_line(i, _log_buffer[i]))
	_log_mutex.unlock()

	var filtered: Array = all_entries
	if types.size() > 0:
		filtered = []
		for entry in all_entries:
			if types.has(entry["type"]):
				filtered.append(entry)

	if order == "desc":
		filtered.reverse()

	var start_all: int = mini(offset, filtered.size())
	var end_all: int = mini(start_all + count, filtered.size())
	result_logs = filtered.slice(start_all, end_all)

	return {
		"logs": result_logs,
		"count": result_logs.size(),
		"total_available": total_available,
		"source": "mcp"
	}


static func _parse_mcp_log_line(index: int, line: String) -> Dictionary:
	var log_type: String = "Info"
	var message: String = line
	if line.begins_with("[ERROR]"):
		log_type = "Error"
		message = line.substr(7).strip_edges()
	elif line.begins_with("[WARNING]"):
		log_type = "Warning"
		message = line.substr(9).strip_edges()
	elif line.begins_with("[INFO]"):
		log_type = "Info"
		message = line.substr(6).strip_edges()
	elif line.begins_with("[DEBUG]"):
		log_type = "Debug"
		message = line.substr(7).strip_edges()
	return {"index": index, "type": log_type, "message": message}

func _get_runtime_logs(types: Array, count: int, offset: int, order: String) -> Dictionary:
	var log_path: String = "user://logs/godot.log"
	if not FileAccess.file_exists(log_path):
		return {
			"logs": [],
			"count": 0,
			"total_available": 0,
			"source": "runtime",
			"note": "Runtime log file not found: " + log_path
		}

	var file: FileAccess = FileAccess.open(log_path, FileAccess.READ)
	if not file:
		return {
			"logs": [],
			"count": 0,
			"total_available": 0,
			"source": "runtime",
			"note": "Runtime log file not available. Logs are only created after running the project."
		}

	var all_lines: Array = []
	while not file.eof_reached():
		var line: String = file.get_line()
		if not line.is_empty():
			all_lines.append(line)
	file.close()

	var total_available: int = all_lines.size()
	if total_available == 0:
		return {
			"logs": [],
			"count": 0,
			"total_available": 0,
			"source": "runtime"
		}

	var entries: Array = []
	if order == "desc":
		for i in range(total_available - 1, -1, -1):
			entries.append({"index": i, "type": "Info", "message": all_lines[i]})
	else:
		for i in range(total_available):
			entries.append({"index": i, "type": "Info", "message": all_lines[i]})

	var start: int = mini(offset, entries.size())
	var end: int = mini(start + count, entries.size())
	var result_logs: Array = entries.slice(start, end)

	return {
		"logs": result_logs,
		"count": result_logs.size(),
		"total_available": total_available,
		"source": "runtime"
	}

# ============================================================================
# execute_script - 执行脚本代码
# ============================================================================

func _register_execute_script(server_core: RefCounted) -> void:
	var tool_name: String = "execute_script"
	var description: String = "Execute a GDScript expression or statement. Uses Godot's Expression class for safe evaluation."
	
	# inputSchema
	var input_schema: Dictionary = {
		"type": "object",
		"properties": {
			"code": {
				"type": "string",
				"description": "GDScript code to execute (expression or statement)"
			},
			"bind_objects": {
				"type": "object",
				"description": "Optional dictionary of objects to bind to the expression"
			}
		},
		"required": ["code"]
	}
	
	# outputSchema
	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"status": {"type": "string"},
			"result": {"type": "string"},
			"error": {"type": "string"}
		}
	}
	
	# annotations
	var annotations: Dictionary = {
		"readOnlyHint": false,
		"destructiveHint": false,
		"idempotentHint": false,
		"openWorldHint": false
	}
	
	# 注册工具（category=supplementary：默认禁用，降低 RCE 面）
	server_core.register_tool(tool_name, description, input_schema,
						  Callable(self, "_tool_execute_script"),
						  output_schema, annotations, "supplementary", "Script")

func _tool_execute_script(params: Dictionary) -> Dictionary:
	var code: String = params.get("code", "")
	var bind_objects: Dictionary = params.get("bind_objects", {})
	
	if code.is_empty():
		return {"error": "Missing required parameter: code"}

	# Guard the single-line Expression path too: it binds OS/ClassDB/Engine etc.,
	# so without this scan execute_script would be a sandbox bypass for
	# execute_editor_script. The multi-line branch below re-scans via delegation.
	var guard: Dictionary = MCPScriptSandbox.scan(code, _sandbox_config())
	if guard.get("blocked", false):
		return {"status": "error", "error": guard.get("error", "blocked by script sandbox"), "blocked": true, "reason": guard.get("reason", ""), "category": guard.get("category", "")}

	# Auto-detect multi-line code and delegate to execute_editor_script path.
	# Capture the last output item as "result" so the response format is
	# consistent with the single-line Expression path.
	if "\n" in code:
		var editor_result: Dictionary = _tool_execute_editor_script(params)
		if editor_result.has("output") and editor_result.get("output", []).size() > 0:
			var output: Array = editor_result["output"]
			editor_result["result"] = str(output[output.size() - 1])
		elif editor_result.get("status") == "success":
			editor_result["result"] = ""
		return editor_result
	
	var expression: Expression = Expression.new()

	var bind_names: PackedStringArray = []
	var bind_values: Array = []
	var singletons: Dictionary = {
		"OS": OS,
		"Engine": Engine,
		"ProjectSettings": ProjectSettings,
		"Input": Input,
		"Time": Time,
		"JSON": JSON,
		"ClassDB": ClassDB,
		"Performance": Performance,
		"ResourceLoader": ResourceLoader,
		"ResourceSaver": ResourceSaver,
		"EditorInterface": EditorInterface,
	}
	for singleton_name in singletons:
		bind_names.append(singleton_name)
		bind_values.append(singletons[singleton_name])

	if not bind_objects.is_empty():
		for key in bind_objects:
			bind_names.append(key)
			bind_values.append(bind_objects[key])

	var parse_error: Error = expression.parse(code, bind_names)

	if parse_error != OK:
		return {
			"status": "error",
			"error": "Parse failed: " + expression.get_error_text()
		}

	var base_instance: RefCounted = self
	_execution_mutex.lock()
	var result: Variant = expression.execute(bind_values, base_instance, true)
	_execution_mutex.unlock()
	
	if expression.has_execute_failed():
		return {
			"status": "error",
			"error": "Execution failed: " + expression.get_error_text()
		}
	
	return {
		"status": "success",
		"result": str(result)
	}

# ============================================================================
# get_performance_metrics - 获取性能指标
# ============================================================================

func _register_get_performance_metrics(server_core: RefCounted) -> void:
	var tool_name: String = "get_performance_metrics"
	var description: String = "Get performance metrics including FPS, memory usage, and object counts."
	
	# inputSchema
	var input_schema: Dictionary = {
		"type": "object",
		"properties": {}
	}
	
	# outputSchema
	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"fps": {"type": "number"},
			"object_count": {"type": "integer"},
			"resource_count": {"type": "integer"},
			"memory_usage_mb": {"type": "number"}
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
						  Callable(self, "_tool_get_performance_metrics"),
						  output_schema, annotations, "supplementary", "Debug-Advanced")

func _tool_get_performance_metrics(params: Dictionary) -> Dictionary:
	# 使用Performance单例获取性能指标
	var fps: float = Performance.get_monitor(Performance.TIME_FPS)
	var object_count: int = Performance.get_monitor(Performance.OBJECT_COUNT)
	var resource_count: int = Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT)
	var memory_usage: int = Performance.get_monitor(Performance.MEMORY_STATIC)  # 静态内存
	
	# 转换为MB
	var memory_mb: float = memory_usage / 1024.0 / 1024.0
	
	return {
		"fps": fps,
		"object_count": object_count,
		"resource_count": resource_count,
		"memory_usage_mb": memory_mb
	}

# ============================================================================
# debug_print - 输出调试信息
# ============================================================================

func _register_debug_print(server_core: RefCounted) -> void:
	var tool_name: String = "debug_print"
	var description: String = "Print a debug message to the Godot output console."
	
	# inputSchema
	var input_schema: Dictionary = {
		"type": "object",
		"properties": {
			"message": {
				"type": "string",
				"description": "Message to print"
			},
			"category": {
				"type": "string",
				"description": "Optional category tag for the message (e.g. 'MCP', 'AI', 'Debug')"
			}
		},
		"required": ["message"]
	}
	
	# outputSchema
	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"status": {"type": "string"},
			"printed_message": {"type": "string"}
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
						  Callable(self, "_tool_debug_print"),
						  output_schema, annotations, "core", "Debug")

func _tool_debug_print(params: Dictionary) -> Dictionary:
	# 参数提取
	var message: String = params.get("message", "")
	var category: String = params.get("category", "")
	
	# 参数验证
	if message.is_empty():
		return {"error": "Missing required parameter: message"}
	
	# 构建打印消息
	var full_message: String
	if category.is_empty():
		full_message = "[MCP Debug] " + message
	else:
		full_message = "[" + category + "] " + message
	
	# 输出到Godot控制台
	printerr(full_message)
	
	return {
		"status": "success",
		"printed_message": full_message
	}

# ============================================================================
# execute_editor_script - 执行完整的编辑器脚本
# ============================================================================

func _register_execute_editor_script(server_core: RefCounted) -> void:
	var tool_name: String = "execute_editor_script"
	var description: String = "Execute a full GDScript in the editor context. Unlike execute_script which only evaluates expressions, this tool can run multi-line scripts with loops, conditionals, and await. Use _custom_print(value) to return output (standard print() goes to editor panel only, not the tool response)."

	var input_schema: Dictionary = {
		"type": "object",
		"properties": {
			"code": {
				"type": "string",
				"description": "Full GDScript code to execute. Can contain multiple statements, loops, conditionals, and await. Use _custom_print(value) to send output back to the tool response (standard print() goes to editor panel only)."
			},
			"expect_files": {
				"type": "array",
				"items": {"type": "string"},
				"description": "Paths the script must create; any missing file fails the call (anti false-success)."
			}
		},
		"required": ["code"]
	}

	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"success": {"type": "boolean"},
			"output": {"type": "array", "items": {"type": "string"}},
			"error": {"type": "string"}
		}
	}

	var annotations: Dictionary = {
		"readOnlyHint": false,
		"destructiveHint": true,
		"idempotentHint": false,
		"openWorldHint": true
	}

	server_core.register_tool(tool_name, description, input_schema,
						  Callable(self, "_tool_execute_editor_script"),
						  output_schema, annotations, "supplementary", "Editor")

## 声明式副作用验证：调用方约定“这次执行应产生这些文件”。工具返回 success
## 但预期文件缺失即判定失败——堵住 workflow completed 而证据未生成的假成功。
static func verify_expected_files(expect_files: Array) -> Dictionary:
	var cleaned: Array = []
	for path_value in expect_files:
		var declared_path: String = String(path_value).strip_edges()
		if not declared_path.is_empty():
			cleaned.append(declared_path)
	var missing: Array = []
	for declared_path in cleaned:
		if not FileAccess.file_exists(declared_path):
			missing.append(declared_path)
	return {
		"declared_count": cleaned.size(),
		"verified_count": cleaned.size() - missing.size(),
		"missing_files": missing,
		"ok": missing.is_empty(),
	}

func _tool_execute_editor_script(params: Dictionary) -> Dictionary:
	var code: String = params.get("code", "")
	if code.is_empty():
		return {"success": false, "error": "Missing required parameter: code", "output": []}

	var guard: Dictionary = MCPScriptSandbox.scan(code, _sandbox_config())
	if guard.get("blocked", false):
		return {"success": false, "error": guard.get("error", "blocked by script sandbox"), "output": [], "blocked": true, "reason": guard.get("reason", ""), "category": guard.get("category", "")}

	var editor_interface: EditorInterface = _get_editor_interface()
	if not editor_interface:
		return {"success": false, "error": "Editor interface not available", "output": []}

	var normalized_code: String = _normalize_indentation(code)
	normalized_code = _spaces_to_tabs(normalized_code)

	var script: GDScript = GDScript.new()
	var class_level_lines: PackedStringArray = []
	var body_lines: PackedStringArray = []
	var in_block: bool = false
	var block_indent: int = -1
	for line in normalized_code.split("\n"):
		var stripped: String = line.strip_edges()
		if stripped.is_empty():
			if in_block:
				class_level_lines.append(line)
			else:
				body_lines.append(line)
			continue
		var indent: int = _count_indent(line)
		if in_block:
			if indent > block_indent or (indent == block_indent and (stripped.begins_with("@") or stripped.begins_with("pass"))):
				class_level_lines.append(line)
				continue
			else:
				in_block = false
		if stripped.begins_with("func ") or stripped.begins_with("class ") or stripped.begins_with("enum "):
			in_block = true
			block_indent = indent
			class_level_lines.append(line)
		else:
			body_lines.append(line)

	var wrapped_code: String = "extends RefCounted\n\nvar _output: Array = []\nvar edited_scene: Node = null\n\nfunc _custom_print(msg, msg2 = null) -> void:\n\t_output.append(str(msg))\n\tif msg2 != null: _output.append(str(msg2))\n\nfunc get_tree() -> SceneTree:\n\tif edited_scene:\n\t\treturn edited_scene.get_tree()\n\treturn Engine.get_main_loop() as SceneTree\n\nfunc get_node(path) -> Node:\n\tif edited_scene:\n\t\treturn edited_scene.get_node_or_null(path)\n\treturn null\n\n"
	if not class_level_lines.is_empty():
		for line in class_level_lines:
			wrapped_code += line + "\n"
		wrapped_code += "\n"
	wrapped_code += "func execute() -> Array:\n"
	for line in body_lines:
		wrapped_code += "\t" + line + "\n"
	wrapped_code += "\n\treturn _output\n"

	script.set_source_code(wrapped_code)

	var reload_ok: Error = script.reload()
	if reload_ok != OK:
		return {"success": false, "error": "Script compilation failed. Check syntax.", "output": []}

	var instance: RefCounted = script.new()
	if not instance:
		return {"success": false, "error": "Failed to create script instance", "output": []}

	instance.set("_output", [])
	var edited_scene: Node = editor_interface.get_edited_scene_root()
	if edited_scene:
		instance.set("edited_scene", edited_scene)

	var result_output: Variant = instance.call("execute")

	var output: Array = []
	if result_output is Array:
		output = result_output
	elif result_output != null:
		output.append(str(result_output))

	var instance_output: Variant = instance.get("_output")
	if instance_output is Array:
		for item in instance_output:
			if not output.has(item):
				output.append(item)

	if instance is RefCounted:
		pass

	var result: Dictionary = {
		"success": true,
		"output": output
	}
	var expect_value: Variant = params.get("expect_files", [])
	if expect_value is Array and not (expect_value as Array).is_empty():
		var verification: Dictionary = verify_expected_files(expect_value as Array)
		result["side_effects"] = verification
		if not bool(verification.get("ok", true)):
			result["success"] = false
			result["error"] = "Execution finished but expected files were not created: " + ", ".join(verification.get("missing_files", []))
	return result

func _count_indent(line: String) -> int:
	var count: int = 0
	for c in line:
		if c == "\t":
			count += 4
		elif c == " ":
			count += 1
		else:
			break
	return count

func _normalize_indentation(code: String) -> String:
	var lines: PackedStringArray = code.split("\n")
	var min_indent: int = 999999
	for line in lines:
		if line.strip_edges().is_empty():
			continue
		var indent: int = 0
		for c in line:
			if c == "\t":
				indent += 4
			elif c == " ":
				indent += 1
			else:
				break
		if indent < min_indent:
			min_indent = indent
	if min_indent == 0 or min_indent == 999999:
		return code
	var result_lines: PackedStringArray = []
	for line in lines:
		if line.strip_edges().is_empty():
			result_lines.append("")
			continue
		var removed: int = 0
		var new_line: String = ""
		for c in line:
			if removed >= min_indent:
				new_line += c
			elif c == "\t":
				removed += 4
				if removed > min_indent:
					new_line += " ".repeat(removed - min_indent)
			elif c == " ":
				removed += 1
			else:
				new_line += c
				removed = min_indent
		result_lines.append(new_line)
	return "\n".join(result_lines)

func _spaces_to_tabs(code: String) -> String:
	var lines: PackedStringArray = code.split("\n")
	var result_lines: PackedStringArray = []
	for line in lines:
		if line.is_empty():
			result_lines.append(line)
			continue
		var leading_spaces: int = 0
		for c in line:
			if c == " ":
				leading_spaces += 1
			else:
				break
		if leading_spaces == 0:
			result_lines.append(line)
			continue
		var tab_count: int = leading_spaces / 4
		var remaining_spaces: int = leading_spaces % 4
		var new_line: String = "\t".repeat(tab_count) + " ".repeat(remaining_spaces) + line.substr(leading_spaces)
		result_lines.append(new_line)
	return "\n".join(result_lines)

# ============================================================================
# clear_output - 清除输出面板和日志缓冲区
# ============================================================================

func _register_clear_output(server_core: RefCounted) -> void:
	var tool_name: String = "clear_output"
	var description: String = "Clear the editor output panel and MCP log buffer."

	var input_schema: Dictionary = {
		"type": "object",
		"properties": {
			"clear_mcp_buffer": {
				"type": "boolean",
				"description": "Whether to clear the MCP log buffer. Default is true."
			},
			"clear_editor_panel": {
				"type": "boolean",
				"description": "Whether to clear the editor output panel. Default is true."
			}
		}
	}

	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"status": {"type": "string"},
			"mcp_buffer_cleared": {"type": "boolean"},
			"editor_panel_cleared": {"type": "boolean"}
		}
	}

	var annotations: Dictionary = {
		"readOnlyHint": false,
		"destructiveHint": true,
		"idempotentHint": true,
		"openWorldHint": false
	}

	server_core.register_tool(tool_name, description, input_schema,
		Callable(self, "_tool_clear_output"),
		output_schema, annotations, "core", "Debug")

func _tool_clear_output(params: Dictionary) -> Dictionary:
	var clear_mcp_buffer: bool = params.get("clear_mcp_buffer", true)
	var clear_editor_panel: bool = params.get("clear_editor_panel", true)

	var mcp_cleared: bool = false
	var mcp_panel_cleared: bool = false
	var panel_cleared: bool = false

	if clear_mcp_buffer:
		_log_mutex.lock()
		_log_buffer.clear()
		_log_mutex.unlock()
		mcp_cleared = true
		mcp_panel_cleared = _clear_mcp_panel_log()

	if clear_editor_panel:
		var editor_interface: EditorInterface = _get_editor_interface()
		if editor_interface:
			var base_control: Control = editor_interface.get_base_control()
			if base_control:
				var log_panel: Node = base_control.find_child("*Output*", true, false)
				if log_panel:
					var rich_text: RichTextLabel = _find_rich_text_label(log_panel)
					if rich_text:
						rich_text.clear()
						panel_cleared = true

	return {
		"status": "success",
		"mcp_buffer_cleared": mcp_cleared,
		"mcp_panel_cleared": mcp_panel_cleared,
		"editor_panel_cleared": panel_cleared
	}

func _clear_mcp_panel_log() -> bool:
	var editor_interface: EditorInterface = _get_editor_interface()
	if not editor_interface:
		return false
	var main_screen: Control = editor_interface.get_editor_main_screen()
	if not main_screen:
		return false
	for child in main_screen.get_children():
		if child.get_script() and child.get_script().resource_path.find("mcp_panel_native") >= 0:
			var text_edit: TextEdit = child.find_child("*TextEdit*", true, false)
			if text_edit and not text_edit.editable:
				text_edit.text = ""
				return true
	return false

func _find_rich_text_label(node: Node) -> RichTextLabel:
	if node is RichTextLabel:
		return node as RichTextLabel
	for child in node.get_children():
		var result: RichTextLabel = _find_rich_text_label(child)
		if result:
			return result
	return null

func _find_tree_control(node: Node) -> Tree:
	if node is Tree:
		return node as Tree
	for child in node.get_children():
		var result: Tree = _find_tree_control(child)
		if result:
			return result
	return null

func _find_script_editor_debugger(base: Node) -> Node:
	var pending: Array[Node] = [base]
	while not pending.is_empty():
		var node: Node = pending.pop_back()
		if node.get_class() == 'ScriptEditorDebugger':
			return node
		for child in node.get_children():
			pending.append(child)
	return null

# 版本化编辑器日志文件名候选。Godot 编辑器日志文件名形如
# editor_log-{major}.{minor}.{patch}.{status}.txt（如 editor_log-4.7.2.stable.txt），
# 部分版本只有 editor_log-{major}.{minor}.{status}.txt；依次尝试，取第一个存在的。
# 动态读取引擎版本，避免硬编码 4.6 文件名导致 4.7 下回退永远失败。
static func _editor_log_filename_candidates() -> Array[String]:
	var vi: Dictionary = Engine.get_version_info()
	var major: int = int(vi.get("major", 4))
	var minor: int = int(vi.get("minor", 0))
	var patch: int = int(vi.get("patch", 0))
	var status: String = str(vi.get("status", "stable"))
	return [
		"editor_log-%d.%d.%d.%s.txt" % [major, minor, patch, status],
		"editor_log-%d.%d.%s.txt" % [major, minor, status],
	]

# 返回当前平台的编辑器日志目录（找不到时为空串）。Windows/Linux/macOS 路径模板保持。
static func _editor_log_dir() -> String:
	if OS.has_feature("windows"):
		var appdata: String = OS.get_environment("APPDATA")
		if not appdata.is_empty():
			return appdata.path_join("Godot")
	elif OS.has_feature("linux"):
		var home: String = OS.get_environment("HOME")
		if not home.is_empty():
			return home.path_join(".local").path_join("share").path_join("godot")
	elif OS.has_feature("macos"):
		var home: String = OS.get_environment("HOME")
		if not home.is_empty():
			return home.path_join("Library").path_join("Application Support").path_join("Godot")
	return ""

# 依次检查版本化候选文件名，返回第一个存在的完整路径；都不存在返回空串。
static func _find_editor_log_file_path() -> String:
	var dir_path: String = _editor_log_dir()
	if dir_path.is_empty():
		return ""
	for candidate in _editor_log_filename_candidates():
		var candidate_path: String = dir_path.path_join(candidate)
		if FileAccess.file_exists(candidate_path):
			return candidate_path
	return ""

# 优先按节点类名查找 Output 面板（非英语编辑器界面节点名是翻译后的，类名不会，
# 见 issue #32），找不到再回退旧的名字通配查找。
func _find_output_panel(base: Node) -> Node:
	var by_class: Array[Node] = base.find_children("*", "OutputPanel", true, false)
	if not by_class.is_empty():
		return by_class[0]
	return base.find_child('*Output*', true, false)

# Errors/Debugger 面板同理：按类名依次尝试多个候选，找不到再回退字符串通配查找。
func _find_errors_panel(base: Node) -> Node:
	for class_name_candidate in ["ScriptEditorDebugger", "EditorDebuggerPanel", "DebuggerErrors"]:
		var by_class: Array[Node] = base.find_children("*", class_name_candidate, true, false)
		if not by_class.is_empty():
			return by_class[0]
	var by_name: Node = base.find_child('*Errors*', true, false)
	if not by_name:
		by_name = base.find_child('*Error*', true, false)
	if not by_name:
		by_name = _find_script_editor_debugger(base)
	return by_name

# 扫描 godot.log（默认 user://logs/godot.log）中的 SCRIPT ERROR / PARSE ERROR 行。
# 这些行版本无关、i18n 无关，编辑器把编译/解析错误也写在这里；作为 editor_panel
# 回退链的兜底（issue #9/#12），让编译错误对 agent 可见。
func _scan_godot_log_error_lines(log_path: String = "user://logs/godot.log") -> Array[Dictionary]:
	var lines: Array[Dictionary] = []
	if not FileAccess.file_exists(log_path):
		return lines
	var file: FileAccess = FileAccess.open(log_path, FileAccess.READ)
	if not file:
		return lines
	while not file.eof_reached():
		var log_line: String = file.get_line().strip_edges()
		if log_line.is_empty():
			continue
		if log_line.contains("SCRIPT ERROR") or log_line.contains("PARSE ERROR"):
			lines.append({
				'index': lines.size(),
				'message': log_line,
				'type': _infer_log_type_from_line(log_line),
				'panel': 'godot_log_file'
			})
	file.close()
	return lines

func _get_editor_panel_logs(types: Array, count: int, offset: int, order: String) -> Dictionary:
	var editor_interface: EditorInterface = _get_editor_interface()
	if not editor_interface:
		return {"error": "Editor interface not available", "source": "editor_panel"}
	var base_control: Control = editor_interface.get_base_control()
	if not base_control:
		return {"error": "Could not get base control", "source": "editor_panel"}
	var parsed_lines: Array[Dictionary] = []
	var output_panel: Node = _find_output_panel(base_control)
	if output_panel:
		var rich_text: RichTextLabel = _find_rich_text_label(output_panel)
		if rich_text:
			var raw_text: String = rich_text.get_parsed_text() if rich_text.has_method('get_parsed_text') else rich_text.get_text()
			if not raw_text.is_empty():
				var text_lines: PackedStringArray = raw_text.split('\n')
				for j in text_lines.size():
					var text_line: String = text_lines[j].strip_edges()
					if text_line.is_empty(): continue
					parsed_lines.append({'index': parsed_lines.size(), 'message': text_line, 'type': _infer_log_type_from_line(text_line), 'panel': 'output'})
	var errors_panel: Node = _find_errors_panel(base_control)
	if errors_panel:
		var error_tree: Tree = _find_tree_control(errors_panel)
		if error_tree:
			var root_item: TreeItem = error_tree.get_root()
			if root_item:
				var item: TreeItem = root_item.get_first_child()
				while item:
					var error_text: String = ''
					for col in range(error_tree.get_columns()):
						var col_text: String = item.get_text(col)
						if not col_text.is_empty():
							if not error_text.is_empty(): error_text += ' | '
							error_text += col_text
					if not error_text.is_empty():
						parsed_lines.append({'index': parsed_lines.size(), 'message': error_text, 'type': 'Error', 'panel': 'script_errors'})
					item = item.get_next()
	# Fallback: try reading the editor log file directly when UI panels have no data.
	# 文件名按当前引擎版本动态构造（editor_log-{major}.{minor}.{patch}.{status}.txt），
	# 不再硬编码 4.6；候选列表依次检查，取第一个存在的。
	if parsed_lines.is_empty():
		var editor_log_path: String = _find_editor_log_file_path()
		if not editor_log_path.is_empty() and FileAccess.file_exists(editor_log_path):
			var file: FileAccess = FileAccess.open(editor_log_path, FileAccess.READ)
			if file:
				while not file.eof_reached():
					var log_line: String = file.get_line().strip_edges()
					if log_line.is_empty():
						continue
					parsed_lines.append({
						'index': parsed_lines.size(),
						'message': log_line,
						'type': _infer_log_type_from_line(log_line),
						'panel': 'editor_log_file'
					})
	# Last-resort fallback: user://logs/godot.log 中的 SCRIPT ERROR / PARSE ERROR 行
	# （版本无关、i18n 无关），保证编译/解析错误对 agent 可见（issue #9/#12）。
	if parsed_lines.is_empty():
		for entry in _scan_godot_log_error_lines():
			entry['index'] = parsed_lines.size()
			parsed_lines.append(entry)
	if not types.is_empty():
		var filtered: Array[Dictionary] = []
		for entry in parsed_lines:
			if types.has(entry['type']): filtered.append(entry)
		parsed_lines = filtered
	var total_available: int = parsed_lines.size()
	if order == 'desc': parsed_lines.reverse()
	var start: int = mini(offset, parsed_lines.size())
	var end: int = mini(start + count, parsed_lines.size())
	var result_lines: Array[Dictionary] = []
	for i in range(start, end): result_lines.append(parsed_lines[i])
	return {"logs": result_lines, "count": result_lines.size(), "total_available": total_available, "source": "editor_panel"}
func _infer_log_type_from_line(raw_line: String) -> String:
	var line: String = raw_line.strip_edges()
	if line.begins_with("ERROR:") or line.begins_with("SCRIPT ERROR:") or line.begins_with("PARSE ERROR:") or line.begins_with("ERROR at") or line.find("error") == 0:
		return "Error"
	if line.begins_with("WARNING:") or line.begins_with("WARN ") or line.find("warning") == 0:
		return "Warning"
	if line.begins_with("DEBUG:") or line.begins_with("DEBUG "):
		return "Debug"
	return "Info"
