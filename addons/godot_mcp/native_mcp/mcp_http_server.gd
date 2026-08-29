class_name McpHttpServer
extends McpTransportBase

# HTTP 传输实现 - 支持 JSON-RPC over HTTP
# Streamable HTTP 双轨（MCP 2025-06-18+ 规范）：
#   - POST /mcp + Accept: application/json（默认）-> 单 JSON 响应（stateless 优先）
#   - POST /mcp + Accept: text/event-stream    -> SSE 单事件响应（流式客户端）
#   - GET /mcp + Accept: text/event-stream     -> 纯 SSE 长连接（向后兼容保留）
# 使用 Godot TCPServer 实现 HTTP 服务器

# ==============================================================================
# 信号继承自 McpTransportBase（不要在此重新定义，避免遮蔽父类信号）
# - message_received(message: Dictionary, context: Variant)
# - server_error(error: String)
# - server_started()
# - server_stopped()
# ==============================================================================


# ==============================================================================
# 常量
# ==============================================================================

## 最大请求大小（1MB）
const MAX_REQUEST_SIZE: int = 1024 * 1024

## 请求超时时间（30秒）
const REQUEST_TIMEOUT: float = 30.0

## HTTP 认证头名称
const AUTH_HEADER: String = "authorization"

## Bearer 认证方案
const AUTH_SCHEME: String = "Bearer"

## 最大并发连接数（防止连接数过多导致资源耗尽）
const MAX_CONNECTIONS: int = 64


# ==============================================================================
# 状态变量（带类型提示 - 根据 godot-dev-guide）
# ==============================================================================

## TCP 服务器实例
var _tcp_server: TCPServer = null

## 监听端口
var _port: int = 9080

## 是否正在运行
var _active: bool = false

## HTTP 服务器线程
var _thread: Thread = null

## 活跃连接列表
var _connections: Array[StreamPeerTCP] = []

## SSE 连接列表（保持打开的连接）
var _sse_connections: Dictionary = {}  # peer -> session_id

## 认证管理器
var _auth_manager: McpAuthManager = null

## 会话管理
var _sessions: Dictionary = {}  # session_id -> session_data

## POST 请求按 peer 协商的响应格式（"json" 或 "sse"），主线程 send_response 据此选择。
## 与 _sse_connections 相同的既有跨线程访问模式（服务器线程写、主线程读）。
var _post_response_formats: Dictionary = {}  # peer -> "json" | "sse"

## 尚未接收完整的 HTTP 请求状态。服务器线程按轮询增量组装每个 peer 的请求，
## 避免一个慢客户端在等待剩余正文时阻塞其他连接与 SSE 心跳。
var _request_states: Dictionary = {}  # peer -> request state

## 插件进程级稳定会话 ID（stateless 服务器仍返回该 id，兼容 stateful 客户端）
var _server_session_id: String = ""

## 远程访问配置
var _allow_remote: bool = false
## CORS 允许的源；空串表示不发送 CORS 头（浏览器跨域默认拒绝）
var _cors_origin: String = ""


## 日志回调函数（由 McpServerCore 设置，用于替代 printerr）
var _log_callback: Callable = Callable()


# ==============================================================================
# McpTransportBase 接口实现
# ==============================================================================

## 设置端口
## @param port: int - 监听端口
func set_port(port: int) -> void:
	if _active:
		push_error("Cannot change port while server is running")
		return
	_port = port

## 设置日志回调
## @param callback: Callable - 日志回调函数，接受 level (String) 和 message (String) 参数
func set_log_callback(callback: Callable) -> void:
	_log_callback = callback

## 设置认证管理器
## @param manager: RefCounted - 认证管理器实例（与父类签名一致）
func set_auth_manager(manager: RefCounted) -> void:
	_auth_manager = manager as McpAuthManager

## 启动 HTTP 服务器
## @returns: bool - 启动成功返回 true，失败返回 false
func start() -> bool:
	var conflict_info: String = _check_port_conflict(_port)
	if not conflict_info.is_empty():
		var error_msg: String = "Port " + str(_port) + " is already in use! " + conflict_info + " Please change the port in MCP settings or close the conflicting application."
		server_error.emit(error_msg)
		if _log_callback.is_valid():
			_log_callback.call("ERROR", error_msg)
		push_error(error_msg)
		return false
	
	_tcp_server = TCPServer.new()
	
	# 默认只绑定回环地址（127.0.0.1），仅当显式开启 allow_remote 时才绑定所有网卡（0.0.0.0）
	var bind_address: String = "0.0.0.0" if _allow_remote else "127.0.0.1"
	var error: Error = _tcp_server.listen(_port, bind_address)
	if error != OK:
		var error_msg: String = "Failed to listen on port " + str(_port) + ": " + str(error)
		server_error.emit(error_msg)
		if _log_callback.is_valid():
			_log_callback.call("ERROR", error_msg)
		return false
	
	_active = true
	_thread = Thread.new()
	_thread.start(_http_server_loop)
	
	server_started.emit()
	if _log_callback.is_valid():
		_log_callback.call("INFO", "Server started on port " + str(_port) + " (bind: " + bind_address + ")")
	
	return true

func _check_port_conflict(port: int) -> String:
	var os_name: String = OS.get_name()
	if os_name == "Windows":
		return _check_port_conflict_windows(port)
	elif os_name == "Linux" or os_name == "FreeBSD":
		return _check_port_conflict_linux(port)
	elif os_name == "macOS":
		return _check_port_conflict_macos(port)
	return ""

func _check_port_conflict_windows(port: int) -> String:
	var output: Array = []
	var exit_code: int = OS.execute("netstat", ["-ano"], output)
	if exit_code != OK or output.is_empty():
		return ""
	var port_str: String = ":" + str(port) + " "
	var lines: PackedStringArray = output[0].split("\n")
	for line in lines:
		var stripped: String = line.strip_edges()
		if stripped.find(port_str) >= 0 and stripped.find("LISTENING") >= 0:
			var parts: PackedStringArray = stripped.split(" ", false)
			var pid: String = ""
			if parts.size() >= 5:
				pid = parts[parts.size() - 1]
			if pid.is_empty() or not pid.is_valid_int():
				continue
			var proc_output: Array = []
			var proc_exit: int = OS.execute("tasklist", ["/FI", "PID eq " + pid, "/FO", "CSV", "/NH"], proc_output)
			if proc_exit == OK and not proc_output.is_empty():
				var proc_line: String = proc_output[0].strip_edges().replace("\"", "")
				if proc_line.find("INFO:") >= 0:
					return "(PID " + pid + ")"
				var proc_parts: PackedStringArray = proc_line.split(",")
				if proc_parts.size() >= 2:
					var proc_name: String = proc_parts[0]
					return "(PID " + pid + ", process: " + proc_name + ")"
			return "(PID " + pid + ")"
	return ""

func _check_port_conflict_linux(port: int) -> String:
	var output: Array = []
	var exit_code: int = OS.execute("ss", ["-tlnp"], output)
	if exit_code != OK or output.is_empty():
		exit_code = OS.execute("netstat", ["-tlnp"], output)
		if exit_code != OK or output.is_empty():
			return ""
	var port_str: String = ":" + str(port)
	var lines: PackedStringArray = output[0].split("\n")
	for line in lines:
		var stripped: String = line.strip_edges()
		if stripped.find(port_str) >= 0 and stripped.find("LISTEN") >= 0:
			var pid_start: int = stripped.find("pid=")
			if pid_start >= 0:
				var pid_section: String = stripped.substr(pid_start + 4)
				var pid_end: int = pid_section.find(",")
				if pid_end < 0:
					pid_end = pid_section.find(")")
				var pid: String = pid_section.substr(0, pid_end) if pid_end >= 0 else pid_section
				if pid.is_valid_int():
					return _resolve_process_name_linux(pid)
			return ""
	return ""

func _check_port_conflict_macos(port: int) -> String:
	var output: Array = []
	var exit_code: int = OS.execute("lsof", ["-i", ":" + str(port), "-sTCP:LISTEN", "-P", "-n"], output)
	if exit_code != OK or output.is_empty():
		return ""
	var lines: PackedStringArray = output[0].split("\n")
	if lines.size() >= 2:
		var parts: PackedStringArray = lines[1].strip_edges().split(" ", false)
		if parts.size() >= 2:
			var proc_name: String = parts[0]
			var pid: String = parts[1]
			if pid.is_valid_int():
				return "(PID " + pid + ", process: " + proc_name + ")"
			return "(PID " + pid + ")"
	return ""

func _resolve_process_name_linux(pid: String) -> String:
	var proc_output: Array = []
	var proc_exit: int = OS.execute("ps", ["-p", pid, "-o", "comm=", "--no-headers"], proc_output)
	if proc_exit == OK and not proc_output.is_empty():
		var proc_name: String = proc_output[0].strip_edges()
		if not proc_name.is_empty():
			return "(PID " + pid + ", process: " + proc_name + ")"
	return "(PID " + pid + ")"

## 停止 HTTP 服务器
func stop() -> void:
	_active = false
	
	# 停止 TCP 服务器（不再接受新连接）
	if _tcp_server:
		_tcp_server.stop()
		_tcp_server = null
	
	# 等待线程结束（必须在线程退出后再修改共享数据）
	if _thread and _thread.is_alive():
		_thread.wait_to_finish()
	_thread = null
	
	# 线程已退出，安全清理连接
	for peer in _connections:
		if peer and peer.get_status() == StreamPeerTCP.STATUS_CONNECTED:
			peer.disconnect_from_host()
	
	_connections.clear()
	_post_response_formats.clear()
	_request_states.clear()
	
	server_stopped.emit()
	if _log_callback.is_valid():
		_log_callback.call("INFO", "Server stopped")

## 检查传输层是否正在运行
## @returns: bool - 运行中返回 true，否则返回 false
func is_running() -> bool:
	return _active and _tcp_server != null and _tcp_server.is_listening()


# ==============================================================================
# HTTP 服务器核心逻辑
# ==============================================================================

## HTTP 服务器主循环（在独立线程中运行）
func _http_server_loop() -> void:
	if _log_callback.is_valid():
		_log_callback.call("INFO", "Server loop started")
	
	var last_keepalive: int = Time.get_ticks_msec()
	
	while _active:
		if not _tcp_server:
			break
		
		# 检查新连接
		var peer: StreamPeerTCP = null
		if _tcp_server.is_connection_available():
			peer = _tcp_server.take_connection()
		if peer:
			if _connections.size() >= MAX_CONNECTIONS:
				peer.disconnect_from_host()
				if _log_callback.is_valid():
					_log_callback.call("WARN", "Connection rejected: maximum connections reached (" + str(MAX_CONNECTIONS) + ")")
			else:
				_connections.append(peer)
				if _log_callback.is_valid():
					_log_callback.call("INFO", "New connection: " + str(peer.get_status()))
		
		# 倒序处理所有活跃连接：断开的连接就地移除，不需要每轮
		# `_connections.duplicate()` 复制整张连接表（服务端线程是唯一写入方）。
		var index: int = _connections.size() - 1
		while index >= 0:
			if not _active:
				break
			var p: StreamPeerTCP = _connections[index]
			if p.get_status() != StreamPeerTCP.STATUS_CONNECTED:
				_remove_connection_at(index)
				index -= 1
				continue
			
			# 已开始但尚未完成的请求即使本轮没有新字节也要推进，以便执行
			# 超时检查；没有请求状态的空闲 SSE 连接不会被误判为新请求。
			var available_bytes: int = p.get_available_bytes()
			if available_bytes > 0 or _request_states.has(p):
				_handle_http_request(p, available_bytes)
			
			index -= 1
		
		# 处理 SSE 连接的心跳
		var current_time: int = Time.get_ticks_msec()
		if current_time - last_keepalive > 30000:
			_send_sse_keepalive()
			last_keepalive = current_time
		
		# 避免 CPU 占用过高
		OS.delay_msec(2)
	
	# 清理所有 SSE 连接
	_cleanup_all_sse_connections()
	
	if _log_callback.is_valid():
		_log_callback.call("INFO", "Server loop stopped")

## 移除指定下标的连接，并清理其关联的 SSE 会话与 POST 响应格式。
## 仅供服务器线程在倒序扫描 _connections 时调用；调用后下标整体前移。
func _remove_connection_at(index: int) -> void:
	if index < 0 or index >= _connections.size():
		return
	var p: StreamPeerTCP = _connections[index]
	if _sse_connections.has(p):
		_close_sse_connection(p)
	if _post_response_formats.has(p):
		_post_response_formats.erase(p)
	if _request_states.has(p):
		_request_states.erase(p)
	_connections.remove_at(index)

## 发送 SSE 心跳
func _send_sse_keepalive() -> void:
	var disconnected_peers: Array[StreamPeerTCP] = []
	
	for peer in _sse_connections.keys():
		var message: String = ": keepalive\r\n\r\n"
		var error: Error = peer.put_data(message.to_utf8_buffer())
		
		if error != OK:
			if _log_callback.is_valid():
				_log_callback.call("WARN", "Failed to send keepalive, closing connection")
			disconnected_peers.append(peer)
	
	# 清理断开的连接
	for peer in disconnected_peers:
		_close_sse_connection(peer)

## 清理所有 SSE 连接
func _cleanup_all_sse_connections() -> void:
	var peers: Array = _sse_connections.keys()
	for peer in peers:
		_close_sse_connection(peer)
	
	_sse_connections.clear()
	_sessions.clear()
	
	if _log_callback.is_valid():
		_log_callback.call("INFO", "All SSE connections cleaned up")

## 处理 HTTP 请求
## @param peer: StreamPeerTCP - 客户端连接
## @param available_bytes: int - 本轮已查询的可读字节数；省略时现场查询
func _handle_http_request(peer: StreamPeerTCP, available_bytes: int = -1) -> void:
	# 以原始字节累积请求，最后一次性按 UTF-8 解码。
	# 不可按 TCP 分片逐段解码：中文等多字节字符可能被拆到分片边界，
	# 单独解码任一分片都会损坏该字符（即“乱码”）。
	var state: Dictionary = _request_states.get(peer, {})
	if state.is_empty():
		state = {
			"request_bytes": PackedByteArray(),
			"started_at": Time.get_ticks_msec(),
			"headers_complete": false,
			"content_length": -1,
			"header_end": -1,
			"header_scan_offset": 0
		}
		_request_states[peer] = state

	var request_bytes: PackedByteArray = state["request_bytes"]
	var available: int = available_bytes if available_bytes >= 0 else peer.get_available_bytes()
	if available > 0:
		var read_result: Array = peer.get_partial_data(available)
		var read_error: int = read_result[0]
		if read_error != OK:
			_request_states.erase(peer)
			_send_http_error(peer, 400, "Failed to read request data.")
			return
		request_bytes.append_array(read_result[1])
		state["request_bytes"] = request_bytes

	if request_bytes.size() > MAX_REQUEST_SIZE:
		_request_states.erase(peer)
		_send_http_error(peer, 413, "Request too large. Maximum size is " + str(MAX_REQUEST_SIZE / 1024) + "KB")
		return

	var current_time: int = Time.get_ticks_msec()
	if current_time - int(state["started_at"]) > REQUEST_TIMEOUT * 1000:
		_request_states.erase(peer)
		_send_http_error(peer, 408, "Request timeout. Please ensure the request is sent completely within " + str(REQUEST_TIMEOUT) + " seconds.")
		return

	if not bool(state["headers_complete"]):
		var scan_offset: int = int(state["header_scan_offset"])
		var header_end: int = _find_header_terminator(request_bytes, scan_offset)
		if header_end == -1:
			# 保留最后 3 个字节作为下轮扫描的重叠区，因为分隔符本身有 4 字节。
			state["header_scan_offset"] = maxi(0, request_bytes.size() - 3)
			return

		state["headers_complete"] = true
		state["header_end"] = header_end
		# 头部为 ASCII，可安全解码。
		var header_section: String = request_bytes.slice(0, header_end).get_string_from_utf8()
		var header_lines: PackedStringArray = header_section.split("\r\n")
		for line in header_lines:
			var lower_line: String = line.to_lower()
			if lower_line.begins_with("content-length:"):
				var cl_str: String = line.substr(15).strip_edges()
				if not cl_str.is_valid_int() or cl_str.to_int() < 0:
					_request_states.erase(peer)
					_send_http_error(peer, 400, "Invalid Content-Length header.")
					return
				state["content_length"] = cl_str.to_int()
				break

		var expected_size: int = header_end + 4 + maxi(0, int(state["content_length"]))
		if expected_size > MAX_REQUEST_SIZE:
			_request_states.erase(peer)
			_send_http_error(peer, 413, "Request too large. Maximum size is " + str(MAX_REQUEST_SIZE / 1024) + "KB")
			return

	var completed_header_end: int = int(state["header_end"])
	var content_length: int = int(state["content_length"])
	var body_received: int = request_bytes.size() - (completed_header_end + 4)
	if content_length >= 0 and body_received < content_length:
		return
	
	if request_bytes.is_empty():
		_request_states.erase(peer)
		return

	# 请求已完整，先移除增量状态再路由；后续响应可能立即断开 peer。
	_request_states.erase(peer)
	if content_length >= 0:
		var request_end: int = completed_header_end + 4 + content_length
		request_bytes = request_bytes.slice(0, request_end)
	
	# 一次性按 UTF-8 解码完整请求，确保多字节字符（如中文）不被损坏
	var request: String = request_bytes.get_string_from_utf8()
	
	# 解析 HTTP 请求
	var parsed: Dictionary = _parse_http_request(request)
	
	# 检查认证（如果启用了认证）
	if _auth_manager and not _auth_manager.validate_request(parsed["headers"]):
		_send_http_error(peer, 401, "Unauthorized. Please provide a valid Bearer token in the Authorization header.")
		return
	
	# 路由请求
	match parsed["method"]:
		"POST":
			_handle_post_request(peer, parsed)
		"GET":
			_handle_get_request(peer, parsed)
		"OPTIONS":
			_handle_options_request(peer, parsed)
		_:
			_send_http_error(peer, 405, "Method not allowed. Only POST, GET, and OPTIONS are supported.")

## 在原始字节中查找 HTTP 头与正文的分隔符 "\r\n\r\n"
## @param bytes: PackedByteArray - 已累积的请求字节
## @param start_index: int - 增量扫描起点；调用方应保留最多 3 字节重叠区
## @returns: int - 分隔符起始下标；未找到返回 -1
func _find_header_terminator(bytes: PackedByteArray, start_index: int = 0) -> int:
	# \r=13, \n=10
	var stop: int = bytes.size() - 3
	for i in range(clampi(start_index, 0, maxi(0, stop)), stop):
		if bytes[i] == 13 and bytes[i + 1] == 10 and bytes[i + 2] == 13 and bytes[i + 3] == 10:
			return i
	return -1

## 解析 HTTP 请求
## @param raw: String - 原始 HTTP 请求字符串
## @returns: Dictionary - 解析后的请求信息（method, path, headers, body）
func _parse_http_request(raw: String) -> Dictionary:
	var lines: PackedStringArray = raw.split("\r\n")
	var request_line: PackedStringArray = lines[0].split(" ")
	
	var method: String = request_line[0]
	var path: String = request_line[1]
	var version: String = request_line[2] if request_line.size() > 2 else "HTTP/1.1"
	
	# 解析头部
	var headers: Dictionary = {}
	var body_start: int = -1
	
	for i in range(1, lines.size()):
		if lines[i].is_empty():
			body_start = i + 1
			break
		
		var colon_pos: int = lines[i].find(":")
		if colon_pos > 0:
			var header_name: String = lines[i].left(colon_pos).to_lower()
			var header_value: String = lines[i].substr(colon_pos + 1).strip_edges()
			headers[header_name] = header_value
	
	# 提取正文
	var body: String = ""
	if body_start != -1 and body_start < lines.size():
		var body_parts: PackedStringArray = []
		for i in range(body_start, lines.size()):
			body_parts.append(lines[i])
		body = "\r\n".join(body_parts)
	
	return {
		"method": method,
		"path": path,
		"version": version,
		"headers": headers,
		"body": body
	}

## 判断 JSON-RPC 载荷是否为批处理（JSON 数组）或非对象类型
## @param data: Variant - JSON.parse 得到的载荷
## @returns: bool - 非 Dictionary（如批处理数组）返回 true
static func is_batch_payload(data: Variant) -> bool:
	return not (data is Dictionary)

## 构造 JSON-RPC -32600 Invalid Request 错误载荷
## @returns: Dictionary - JSON-RPC 错误响应体
static func batch_error_payload() -> Dictionary:
	return {
		"jsonrpc": "2.0",
		"id": null,
		"error": {
			"code": -32600,
			"message": "Invalid Request"
		}
	}

# ==============================================================================
# Streamable HTTP 双轨（Accept 协商）
# ==============================================================================

## 根据 Accept 头判断客户端是否期望 SSE 流式响应（Streamable HTTP 双轨协商）。
## 仅当 Accept 显式包含 "text/event-stream" 时返回 true；
## application/json、空头、*/*（通用通配）均走默认的单 JSON 响应路径——
## stateless 优先，且与 Python requests（默认 Accept: */*）等通用 HTTP 客户端向后兼容。
## @param accept_header: String - 请求的 Accept 头原文（可为空）
## @returns: bool - 期望 SSE 返回 true，否则 false
static func _wants_sse(accept_header: String) -> bool:
	var header: String = accept_header.strip_edges().to_lower()
	return header.contains("text/event-stream")

## 处理 POST 请求（JSON-RPC over HTTP）
## @param peer: StreamPeerTCP - 客户端连接
## @param parsed: Dictionary - 解析后的 HTTP 请求
func _handle_post_request(peer: StreamPeerTCP, parsed: Dictionary) -> void:
	# 检查路径
	if parsed["path"] != "/mcp" and parsed["path"] != "/":
		_send_http_error(peer, 404, "Not found. Please use path '/mcp' for MCP requests.")
		return
	
	var content_type: String = parsed["headers"].get("content-type", "")
	var body: String = parsed["body"]
	
	if not body.is_empty() and not content_type.contains("application/json"):
		_send_http_error(peer, 415, "Unsupported media type. Please use 'Content-Type: application/json'.")
		return
	
	if body.is_empty():
		_send_http_error(peer, 400, "Empty request body")
		return
	
	var json: JSON = JSON.new()
	var parse_error: Error = json.parse(body)
	
	if parse_error != OK:
		_send_http_error(peer, 400, "Invalid JSON: " + json.get_error_message())
		return
	
	var data: Variant = json.get_data()
	
	# 批处理（JSON 数组）或其他非对象载荷不符合本服务器单消息约定，
	# 返回 JSON-RPC -32600 Invalid Request 错误响应（HTTP 200），避免类型断言崩溃。
	if is_batch_payload(data):
		_send_http_response(peer, batch_error_payload())
		return
	
	# --- Streamable HTTP 双轨：Accept 协商 ---
	# 仅当 Accept 显式包含 text/event-stream 时协商 SSE 流式响应；
	# 其余（application/json、空、*/*）走单 JSON 响应（stateless 优先，向后兼容）。
	# 协商结果按 peer 记录，主线程 send_response 时据此选择响应格式。
	var accept_header: String = parsed["headers"].get("accept", "")
	_post_response_formats[peer] = "sse" if _wants_sse(accept_header) else "json"
	if _log_callback.is_valid():
		_log_callback.call("DEBUG", "POST /mcp Accept negotiation: format=" + str(_post_response_formats[peer]) + " (Accept: " + accept_header + ")")
	
	# --- Mcp-Session-Id：stateless 服务器忽略客户端会话头，仅记录日志 ---
	var client_session_id: String = parsed["headers"].get("mcp-session-id", "")
	if not client_session_id.is_empty() and _log_callback.is_valid():
		_log_callback.call("DEBUG", "Ignoring Mcp-Session-Id header (stateless server): " + client_session_id)
	
	var message: Dictionary = data
	
	var is_notification: bool = not message.has("id")
	
	call_deferred("_emit_message_received", message, peer)
	
	if is_notification:
		_send_http_accepted(peer)

## 从插件配置文件读取版本号
## @returns: String - 插件版本号；读取失败时回退 "0.0.0"
static func read_plugin_version() -> String:
	var config: ConfigFile = ConfigFile.new()
	var err: Error = config.load("res://addons/godot_mcp/plugin.cfg")
	if err != OK:
		return "0.0.0"
	var version: Variant = config.get_value("plugin", "version", "0.0.0")
	return str(version)

## 处理 GET 请求（SSE 或健康检查）
## @param peer: StreamPeerTCP - 客户端连接
## @param parsed: Dictionary - 解析后的 HTTP 请求
func _handle_get_request(peer: StreamPeerTCP, parsed: Dictionary) -> void:
	# 检查是否是 SSE 请求
	if parsed["headers"].get("accept", "") == "text/event-stream":
		_handle_sse_request(peer, parsed)
		return
	
	# 普通 GET 请求，返回服务器信息
	var info: Dictionary = {
		"name": "Godot MCP Native",
		"version": read_plugin_version(),
		"transport": "http",
		"protocol": "MCP 2025-11-25",
		"endpoints": {
			"mcp": "/mcp (POST)",
			"sse": "/mcp (GET, SSE)"
		}
	}
	
	_send_http_response(peer, info)

## 处理 OPTIONS 请求（CORS 预检）
## @param peer: StreamPeerTCP - 客户端连接
## @param parsed: Dictionary - 解析后的 HTTP 请求
func _handle_options_request(peer: StreamPeerTCP, parsed: Dictionary) -> void:
	var response: String = "HTTP/1.1 204 No Content\r\n"
	response += _cors_header()
	response += "Access-Control-Allow-Methods: POST, GET, OPTIONS\r\n"
	response += "Access-Control-Allow-Headers: Content-Type, Authorization\r\n"
	response += "Access-Control-Max-Age: 86400\r\n"
	response += "\r\n"
	
	peer.put_data(response.to_utf8_buffer())
	peer.disconnect_from_host()

## 处理 SSE 请求（Server-sent Events）
## @param peer: StreamPeerTCP - 客户端连接
## @param parsed: Dictionary - 解析后的 HTTP 请求
func _handle_sse_request(peer: StreamPeerTCP, parsed: Dictionary) -> void:
	# 验证认证
	if _auth_manager and not _auth_manager.validate_request(parsed["headers"]):
		_send_http_error(peer, 401, "Unauthorized")
		return
	
	# 生成会话 ID
	var session_id: String = _generate_session_id()
	
	# 发送 SSE 响应头
	var response_header: String = "HTTP/1.1 200 OK\r\n"
	response_header += "Content-Type: text/event-stream\r\n"
	response_header += "Cache-Control: no-cache\r\n"
	response_header += "Connection: keep-alive\r\n"
	response_header += _cors_header()
	response_header += "\r\n"
	
	peer.put_data(response_header.to_utf8_buffer())
	
	# 发送初始消息
	_send_sse_event(peer, "connected", {"session_id": session_id})
	
	# 保存 SSE 连接
	_sse_connections[peer] = session_id
	_sessions[session_id] = {
		"peer": peer,
		"created_at": Time.get_time_dict_from_system()
	}
	
	if _log_callback.is_valid():
		_log_callback.call("INFO", "SSE connection established: " + session_id)

## 发送原始 JSON-RPC 消息（通过 SSE 广播到所有连接）
## @param message: Dictionary - 完整的 JSON-RPC 消息
func send_raw_message(message: Dictionary) -> void:
	var disconnected_peers: Array[StreamPeerTCP] = []
	for peer in _sse_connections.keys():
		_send_sse_event(peer, "message", message)
		if not _sse_connections.has(peer):
			disconnected_peers.append(peer)
	if _log_callback.is_valid():
		_log_callback.call("DEBUG", "Raw message broadcast to " + str(_sse_connections.size()) + " SSE connections")

## 发送 SSE 事件
## @param peer: StreamPeerTCP - 客户端连接
## @param event: String - 事件名称
## @param data: Dictionary - 事件数据
func _send_sse_event(peer: StreamPeerTCP, event: String, data: Dictionary) -> void:
	var message: String = "event: " + event + "\r\n"
	message += "data: " + JSON.stringify(data) + "\r\n"
	message += "\r\n"
	
	var error: Error = peer.put_data(message.to_utf8_buffer())
	if error != OK:
		if _log_callback.is_valid():
			_log_callback.call("ERROR", "Failed to send SSE event: " + str(error))
		_close_sse_connection(peer)

## 关闭 SSE 连接
## @param peer: StreamPeerTCP - 客户端连接
func _close_sse_connection(peer: StreamPeerTCP) -> void:
	if _sse_connections.has(peer):
		var session_id: String = _sse_connections[peer]
		_sse_connections.erase(peer)
		_sessions.erase(session_id)
		if _log_callback.is_valid():
			_log_callback.call("INFO", "SSE connection closed: " + session_id)
	

	if peer.get_status() == StreamPeerTCP.STATUS_CONNECTED:
		peer.disconnect_from_host()

## 生成会话 ID
## @returns: String - 唯一会话 ID
func _generate_session_id() -> String:
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.randomize()
	
	var chars: String = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
	var session_id: String = ""
	
	for i in range(32):
		var idx: int = rng.randi() % chars.length()
		session_id += chars[idx]
	
	return session_id

## 设置远程访问配置
## @param allow_remote: bool - 是否允许远程访问
## @param cors_origin: String - CORS 允许的源（空串 = 不发送 CORS 头）
func set_remote_config(allow_remote: bool, cors_origin: String = "") -> void:
	if _active:
		var warn_msg: String = "Remote access config changed while server is running; restart to apply the new bind address."
		if _log_callback.is_valid():
			_log_callback.call("WARN", warn_msg)
		push_warning(warn_msg)
	_allow_remote = allow_remote
	_cors_origin = cors_origin
	
	if _log_callback.is_valid():
		_log_callback.call("INFO", "Remote access config: allow_remote=" + str(allow_remote) + ", cors=" + cors_origin)

## 构建 CORS 响应头（白名单模式）
## _cors_origin 为空串时返回空串（不发送 CORS 头，浏览器跨域默认拒绝）
## @returns: String - 单行 CORS 响应头（含 \r\n），或空串
func _cors_header() -> String:
	if _cors_origin.is_empty():
		return ""
	return "Access-Control-Allow-Origin: " + _cors_origin + "\r\n"


# ==============================================================================
# 信号发射（线程安全）
# ==============================================================================

## 在主线程中发送消息接收信号
## @param message: Dictionary - JSON-RPC 消息
## @param peer: StreamPeerTCP - 客户端连接
func _emit_message_received(message: Dictionary, peer: StreamPeerTCP) -> void:
	message_received.emit(message, peer as Variant)


# ==============================================================================
# HTTP 响应处理
# ==============================================================================

## 发送 HTTP 响应（从主线程调用）
## @param peer: StreamPeerTCP - 客户端连接
## @param data: Dictionary - 要发送的 JSON 数据
func send_response(response: Dictionary, context: Variant) -> void:
	var peer: StreamPeerTCP = context as StreamPeerTCP
	if not peer:
		if _log_callback.is_valid():
			_log_callback.call("ERROR", "Cannot send response: invalid peer context")
		return
	# Streamable HTTP 双轨：按 POST 时协商的结果选择 JSON 单响应或 SSE 事件。
	# 未协商过的 peer 默认走 JSON（向后兼容）。
	var format: String = _post_response_formats.get(peer, "json")
	if format == "sse":
		_send_sse_post_response(peer, response)
	else:
		_send_http_response(peer, response)

## 构建并发送 HTTP 响应
## @param peer: StreamPeerTCP - 客户端连接
## @param data: Dictionary - 要发送的 JSON 数据
## 构建成功响应头。每次响应后服务器都会断开连接，因此必须显式声明
## Connection: close：否则 keep-alive 代理（如 cloudflared）会复用一条
## 即将关闭的连接，把在途请求撞上 EOF/连接重置，表现为间歇性 502。
static func json_response_header(body_size: int) -> String:
	var header: String = "HTTP/1.1 200 OK\r\n"
	header += "Content-Type: application/json; charset=utf-8\r\n"
	header += "Content-Length: " + str(body_size) + "\r\n"
	header += "Connection: close\r\n"
	return header

func _send_http_response(peer: StreamPeerTCP, data: Dictionary) -> void:
	var json_string: String = JSON.stringify(data)
	var json_bytes: PackedByteArray = json_string.to_utf8_buffer()

	var http_response: String = json_response_header(json_bytes.size())
	http_response += _cors_header()
	http_response += _session_id_header()
	http_response += "\r\n"
	
	var header_bytes: PackedByteArray = http_response.to_utf8_buffer()
	var full_response: PackedByteArray = header_bytes + json_bytes
	
	var error: Error = peer.put_data(full_response)
	if error != OK:
		server_error.emit("Failed to send HTTP response: " + str(error))
		if _log_callback.is_valid():
			_log_callback.call("ERROR", "Failed to send response: " + str(error))
	
	_post_response_formats.erase(peer)
	peer.disconnect_from_host()

## 发送 Streamable HTTP 的 SSE 单事件响应（POST /mcp 协商为 text/event-stream 时使用）
## 格式: event: message / data: {json}\n\n，写后断开连接（单事件最小实现，不做长连接）
## @param peer: StreamPeerTCP - 客户端连接
## @param data: Dictionary - 要发送的 JSON-RPC 响应
func _send_sse_post_response(peer: StreamPeerTCP, data: Dictionary) -> void:
	var json_string: String = JSON.stringify(data)
	
	var http_response: String = "HTTP/1.1 200 OK\r\n"
	http_response += "Content-Type: text/event-stream\r\n"
	http_response += "Cache-Control: no-cache\r\n"
	http_response += "Connection: close\r\n"
	http_response += _cors_header()
	http_response += _session_id_header()
	http_response += "\r\n"
	http_response += "event: message\r\n"
	http_response += "data: " + json_string + "\r\n"
	http_response += "\r\n"
	
	var error: Error = peer.put_data(http_response.to_utf8_buffer())
	if error != OK:
		server_error.emit("Failed to send SSE response: " + str(error))
		if _log_callback.is_valid():
			_log_callback.call("ERROR", "Failed to send SSE response: " + str(error))
	
	_post_response_formats.erase(peer)
	peer.disconnect_from_host()

## 获取插件进程级稳定会话 ID；首次调用时惰性生成，之后保持不变
## @returns: String - 稳定会话 ID
func _get_server_session_id() -> String:
	if _server_session_id.is_empty():
		_server_session_id = _generate_session_id()
	return _server_session_id

## 构建 Mcp-Session-Id 响应头（stateless 服务器仍返回稳定 id，兼容 stateful 客户端）
## @returns: String - 单行响应头（含 \r\n）
func _session_id_header() -> String:
	return "Mcp-Session-Id: " + _get_server_session_id() + "\r\n"

## 发送 HTTP 错误响应
## @param peer: StreamPeerTCP - 客户端连接
## @param status_code: int - HTTP 状态码
## @param message: String - 错误消息
func _send_http_accepted(peer: StreamPeerTCP) -> void:
	var response: String = "HTTP/1.1 202 Accepted\r\n"
	response += "Content-Length: 0\r\n"
	response += _cors_header()
	response += _session_id_header()
	response += "\r\n"
	peer.put_data(response.to_utf8_buffer())
	peer.disconnect_from_host()

## 构建错误响应头。与成功响应同理：显式 Connection: close 与随后的
## 主动断开保持一致，避免代理在复用连接上的在途请求收到连接重置。
static func error_response_header(status_code: int, status_text: String, body_size: int) -> String:
	var header: String = "HTTP/1.1 " + str(status_code) + " " + status_text + "\r\n"
	header += "Content-Type: text/plain; charset=utf-8\r\n"
	header += "Content-Length: " + str(body_size) + "\r\n"
	header += "Connection: close\r\n"
	return header

func _send_http_error(peer: StreamPeerTCP, status_code: int, message: String) -> void:
	var status_text: String = ""
	match status_code:
		400: status_text = "Bad Request"
		401: status_text = "Unauthorized"
		404: status_text = "Not Found"
		405: status_text = "Method Not Allowed"
		408: status_text = "Request Timeout"
		413: status_text = "Request Too Large"
		415: status_text = "Unsupported Media Type"
		500: status_text = "Internal Server Error"
		501: status_text = "Not Implemented"
		_: status_text = "Error"

	var response_header: String = error_response_header(
		status_code, status_text, message.to_utf8_buffer().size())
	response_header += _cors_header()
	response_header += _session_id_header()
	response_header += "\r\n"

	peer.put_data(response_header.to_utf8_buffer() + message.to_utf8_buffer())
	peer.disconnect_from_host()
	
	if _log_callback.is_valid():
		_log_callback.call("WARN", "Error response sent: " + str(status_code) + " " + message)
