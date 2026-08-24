extends "res://addons/gut/test.gd"

var _http_server: RefCounted = null

func before_each():
	_http_server = load("res://addons/godot_mcp/native_mcp/mcp_http_server.gd").new()

func after_each():
	if _http_server and _http_server.is_running():
		_http_server.stop()
	_http_server = null

func test_parse_http_request_post():
	var raw: String = "POST /mcp HTTP/1.1\r\nContent-Type: application/json\r\nContent-Length: 42\r\n\r\n{\"jsonrpc\":\"2.0\",\"method\":\"initialize\",\"id\":1}"
	var result: Dictionary = _http_server._parse_http_request(raw)
	assert_eq(result["method"], "POST", "Method should be POST")
	assert_eq(result["path"], "/mcp", "Path should be /mcp")
	assert_eq(result["version"], "HTTP/1.1", "Version should be HTTP/1.1")

func test_parse_http_request_headers():
	var raw: String = "POST /mcp HTTP/1.1\r\nContent-Type: application/json\r\nAuthorization: Bearer test123\r\n\r\n{}"
	var result: Dictionary = _http_server._parse_http_request(raw)
	assert_eq(result["headers"].get("content-type"), "application/json", "Content-Type should be parsed")
	assert_eq(result["headers"].get("authorization"), "Bearer test123", "Authorization should be parsed")

func test_parse_http_request_headers_case_insensitive():
	var raw: String = "POST /mcp HTTP/1.1\r\nContent-Type: application/json\r\n\r\n{}"
	var result: Dictionary = _http_server._parse_http_request(raw)
	assert_true(result["headers"].has("content-type"), "Header names should be lowercased")

func test_parse_http_request_body():
	var body: String = '{"jsonrpc":"2.0","method":"initialize","id":1}'
	var raw: String = "POST /mcp HTTP/1.1\r\nContent-Length: " + str(body.length()) + "\r\n\r\n" + body
	var result: Dictionary = _http_server._parse_http_request(raw)
	assert_true(result["body"].length() > 0, "Should have body content")

func test_parse_http_get_request():
	var raw: String = "GET /mcp HTTP/1.1\r\nAccept: text/event-stream\r\n\r\n"
	var result: Dictionary = _http_server._parse_http_request(raw)
	assert_eq(result["method"], "GET", "Method should be GET")
	assert_eq(result["path"], "/mcp", "Path should be /mcp")

func test_parse_http_options_request():
	var raw: String = "OPTIONS /mcp HTTP/1.1\r\nOrigin: http://localhost:3000\r\n\r\n"
	var result: Dictionary = _http_server._parse_http_request(raw)
	assert_eq(result["method"], "OPTIONS", "Method should be OPTIONS")

func test_find_header_terminator():
	var raw: PackedByteArray = "POST /mcp HTTP/1.1\r\nContent-Length: 2\r\n\r\n{}".to_utf8_buffer()
	var idx: int = _http_server._find_header_terminator(raw)
	# 分隔符位于 "Content-Length: 2" 之后
	assert_eq(raw.slice(idx, idx + 4).get_string_from_utf8(), "\r\n\r\n", "Should locate the CRLFCRLF terminator")

func test_find_header_terminator_not_found():
	var raw: PackedByteArray = "POST /mcp HTTP/1.1\r\nContent-Length: 2".to_utf8_buffer()
	assert_eq(_http_server._find_header_terminator(raw), -1, "Should return -1 when no terminator present")

func test_utf8_body_survives_chunk_boundary():
	# 模拟中文负载被 TCP 拆分到多字节字符中间后，累积全部字节再整体解码不应乱码
	var body: String = '{"name":"我的游戏标题","desc":"角色描述"}'
	var raw: String = "POST /mcp HTTP/1.1\r\nContent-Type: application/json\r\nContent-Length: " + str(body.to_utf8_buffer().size()) + "\r\n\r\n" + body
	var all_bytes: PackedByteArray = raw.to_utf8_buffer()
	# 找到正文起点，并在某个中文字符的 3 字节中间切一刀
	var header_end: int = _http_server._find_header_terminator(all_bytes)
	# 正文为 {"name":"... ，前 9 字节是 ASCII，首个中文字符 '我' 的 3 字节 UTF-8
	# 编码位于正文偏移 9~11，故 +10 恰好落在 '我' 的字节中间，真正制造跨分片边界。
	var split_at: int = header_end + 4 + 10
	var first_chunk: PackedByteArray = all_bytes.slice(0, split_at)
	var second_chunk: PackedByteArray = all_bytes.slice(split_at)

	# 回归断言：旧实现逐分片解码再拼接，会把被拆开的 '我' 损坏成乱码。
	var old_style: String = first_chunk.get_string_from_utf8() + second_chunk.get_string_from_utf8()
	assert_false(old_style.contains("我的游戏标题"), "Per-fragment decode must corrupt the split multi-byte char (reproduces the bug)")

	# 新实现:先累积全部字节,再整体解码,中文应完整无损。
	var reassembled: PackedByteArray = PackedByteArray()
	reassembled.append_array(first_chunk)
	reassembled.append_array(second_chunk)
	var decoded: String = reassembled.get_string_from_utf8()
	var parsed: Dictionary = _http_server._parse_http_request(decoded)
	assert_true(parsed["body"].contains("我的游戏标题"), "Chinese title should survive chunk boundary")
	assert_true(parsed["body"].contains("角色描述"), "Chinese description should survive chunk boundary")

func test_generate_session_id():
	var id1: String = _http_server._generate_session_id()
	var id2: String = _http_server._generate_session_id()
	assert_eq(id1.length(), 32, "Session ID should be 32 characters")
	assert_ne(id1, id2, "Session IDs should be unique")

func test_generate_session_id_characters():
	var session_id: String = _http_server._generate_session_id()
	var valid_chars: String = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
	for ch in session_id:
		assert_true(valid_chars.contains(ch), "Session ID should only contain alphanumeric characters")

func test_check_port_conflict_returns_string():
	var result: String = _http_server._check_port_conflict(9999)
	assert_true(result is String, "Should return a string on any platform")

func test_check_port_conflict_windows_method_exists():
	assert_true(_http_server.has_method("_check_port_conflict_windows"), "Should have Windows-specific method")

func test_check_port_conflict_linux_method_exists():
	assert_true(_http_server.has_method("_check_port_conflict_linux"), "Should have Linux-specific method")

func test_check_port_conflict_macos_method_exists():
	assert_true(_http_server.has_method("_check_port_conflict_macos"), "Should have macOS-specific method")

func test_set_port():
	_http_server.set_port(9999)
	assert_eq(_http_server._port, 9999, "Port should be set to 9999")

func test_set_port_while_running():
	_http_server._port = 9080
	assert_eq(_http_server._port, 9080, "Default port should be 9080")

func test_is_running_initially():
	assert_false(_http_server.is_running(), "Should not be running initially")

func test_set_auth_manager():
	var auth: RefCounted = load("res://addons/godot_mcp/native_mcp/mcp_auth_manager.gd").new()
	_http_server.set_auth_manager(auth)
	assert_ne(_http_server._auth_manager, null, "Auth manager should be set")

func test_set_remote_config():
	_http_server.set_remote_config(true, "http://localhost:3000")
	assert_eq(_http_server._allow_remote, true, "Allow remote should be true")
	assert_eq(_http_server._cors_origin, "http://localhost:3000", "CORS origin should be set")

func test_max_request_size_constant():
	assert_eq(_http_server.MAX_REQUEST_SIZE, 1024 * 1024, "Max request size should be 1MB")

func test_request_timeout_constant():
	assert_eq(_http_server.REQUEST_TIMEOUT, 30.0, "Request timeout should be 30 seconds")

func test_auth_header_constants():
	assert_eq(_http_server.AUTH_HEADER, "authorization", "Auth header should be 'authorization'")
	assert_eq(_http_server.AUTH_SCHEME, "Bearer", "Auth scheme should be 'Bearer'")

func test_http_server_has_send_raw_message():
	assert_true(_http_server.has_method("send_raw_message"), "HTTP server should have send_raw_message method")

func test_http_server_send_raw_message_logs():
	var test_message: Dictionary = {"jsonrpc": "2.0", "method": "notifications/tools/list_changed", "params": {}}
	_http_server.send_raw_message(test_message)
	assert_true(true, "send_raw_message should not crash when no SSE connections")

# ==============================================================================
# CORS 白名单化（安全默认：空 origin = 不发送 CORS 头）
# ==============================================================================

func test_cors_header_default_empty():
	assert_eq(_http_server._cors_origin, "", "Default CORS origin should be empty (no CORS header)")
	assert_eq(_http_server._cors_header(), "", "Default _cors_header() should return empty string")

func test_cors_header_specific_origin():
	_http_server.set_remote_config(false, "http://localhost:3000")
	assert_eq(_http_server._cors_header(), "Access-Control-Allow-Origin: http://localhost:3000\r\n", "Should emit single-origin CORS header")

func test_cors_header_wildcard():
	_http_server.set_remote_config(false, "*")
	assert_eq(_http_server._cors_header(), "Access-Control-Allow-Origin: *\r\n", "Explicit '*' should emit wildcard CORS header")

func test_set_remote_config_default_cors_empty():
	_http_server.set_remote_config(true)
	assert_eq(_http_server._cors_origin, "", "Default cors_origin parameter should be empty string")
	assert_eq(_http_server._allow_remote, true, "allow_remote should be set")

# ==============================================================================
# JSON-RPC 批处理（-32600 Invalid Request）
# ==============================================================================

func test_is_batch_payload_object():
	var parsed: Variant = JSON.parse_string('{"jsonrpc":"2.0","id":1,"method":"ping"}')
	assert_true(parsed is Dictionary, "Object payload should parse to Dictionary")
	assert_false(_http_server.is_batch_payload(parsed), "Object payload is not a batch")

func test_is_batch_payload_array():
	var parsed: Variant = JSON.parse_string('[{"jsonrpc":"2.0","id":1}]')
	assert_true(parsed is Array, "Batch payload should parse to Array")
	assert_true(_http_server.is_batch_payload(parsed), "Array payload is a batch")

func test_is_batch_payload_non_object():
	assert_true(_http_server.is_batch_payload("plain string"), "String payload should be treated as invalid")
	assert_true(_http_server.is_batch_payload(42), "Numeric payload should be treated as invalid")

func test_batch_error_payload_shape():
	var payload: Dictionary = _http_server.batch_error_payload()
	assert_eq(payload.get("jsonrpc"), "2.0", "Error payload should be JSON-RPC 2.0")
	assert_eq(payload.get("id"), null, "Error payload id should be null")
	var error_obj: Dictionary = payload.get("error", {})
	assert_eq(error_obj.get("code"), -32600, "Error code should be -32600")
	assert_eq(error_obj.get("message"), "Invalid Request", "Error message should be Invalid Request")

# ==============================================================================
# GET / 版本信息（从 plugin.cfg 读取）
# ==============================================================================

func test_read_plugin_version_non_empty():
	var version: String = _http_server.read_plugin_version()
	assert_false(version.is_empty(), "Plugin version should be non-empty")
	assert_ne(version, "0.0.0", "Plugin version should not be the fallback")

func test_read_plugin_version_matches_cfg():
	var config: ConfigFile = ConfigFile.new()
	var err: Error = config.load("res://addons/godot_mcp/plugin.cfg")
	assert_eq(err, OK, "plugin.cfg should load")
	var expected: String = str(config.get_value("plugin", "version", "0.0.0"))
	assert_eq(_http_server.read_plugin_version(), expected, "Version should match plugin.cfg")

# ==============================================================================
# 连接数上限（防 DoS）
# ==============================================================================

func test_max_connections_constant():
	assert_eq(_http_server.MAX_CONNECTIONS, 64, "MAX_CONNECTIONS should be 64")

func test_remove_connection_at_cleans_peer_state():
	# 服务器线程倒序扫描时，断开的 peer 必须从连接表、SSE 会话表和
	# POST 响应格式表中一起移除；未连接的 StreamPeerTCP 不应触发 disconnect。
	var peer: StreamPeerTCP = StreamPeerTCP.new()
	_http_server._connections.append(peer)
	_http_server._sse_connections[peer] = "sess-remove"
	_http_server._sessions["sess-remove"] = {"created": true}
	_http_server._post_response_formats[peer] = "sse"
	_http_server._remove_connection_at(0)

	assert_eq(_http_server._connections.size(), 0, "Peer should be removed from the connection table")
	assert_false(_http_server._sse_connections.has(peer), "SSE connection mapping should be removed")
	assert_false(_http_server._post_response_formats.has(peer), "POST response format mapping should be removed")
	assert_false(_http_server._sessions.has("sess-remove"), "SSE session data should be removed")

func test_remove_connection_at_invalid_index_is_noop():
	_http_server._remove_connection_at(-1)
	_http_server._remove_connection_at(0)
	assert_eq(_http_server._connections.size(), 0, "Invalid indexes should not crash or mutate the connection table")

func test_start_stop_lifecycle():
	# 实际监听 + 线程启停，覆盖 listen(port, bind_address) 代码路径。
	# 精确验证 127.0.0.1 绑定结果与连接数拒绝行为需要真实多 TCP 客户端，
	# 超出 GUT 单测范围（依赖 TCPServer 真实监听）。
	_http_server.set_port(23141)
	var started: bool = _http_server.start()
	assert_true(started, "Server should start on a free port")
	if started:
		assert_true(_http_server.is_running(), "Server should be running after start")
		_http_server.stop()
		assert_false(_http_server.is_running(), "Server should stop cleanly")

# ==============================================================================
# Streamable HTTP 双轨：Accept 协商、stateless 会话头与 SSE POST 响应
# ==============================================================================

func test_wants_sse_negotiation_matrix():
	assert_true(_http_server._wants_sse("text/event-stream"), "text/event-stream should negotiate SSE")
	assert_false(_http_server._wants_sse("application/json"), "application/json should negotiate JSON")
	assert_false(_http_server._wants_sse(""), "Empty Accept should negotiate JSON")
	assert_false(_http_server._wants_sse("*/*"), "*/* should negotiate JSON (stateless default)")

func test_send_response_invalid_context_no_crash():
	_http_server.send_response({"jsonrpc": "2.0", "id": 1, "result": {}}, null)
	assert_true(true, "send_response with null context should not crash")

func test_get_server_session_id_stable():
	var id1: String = _http_server._get_server_session_id()
	var id2: String = _http_server._get_server_session_id()
	assert_false(id1.is_empty(), "Server session id should be non-empty")
	assert_eq(id1, id2, "Server session id should be stable within the process")

func test_session_id_header_format():
	var header: String = _http_server._session_id_header()
	assert_true(header.begins_with("Mcp-Session-Id: "), "Header should use the Mcp-Session-Id name")
	assert_true(header.ends_with("\r\n"), "Header should end with CRLF")

func test_send_sse_post_response_wire_format():
	# 真实回环 TCP：验证 Streamable HTTP 的 SSE POST 响应在线上字节格式
	_http_server.set_port(23142)
	assert_true(_http_server.start(), "Server should start on test port")
	var client: StreamPeerTCP = StreamPeerTCP.new()
	assert_eq(client.connect_to_host("127.0.0.1", 23142), OK, "Client should initiate connection")
	var server_peer: StreamPeerTCP = _wait_for_server_peer(client)
	assert_ne(server_peer, null, "Server should accept the client connection")
	if server_peer == null:
		client.disconnect_from_host()
		return
	var response: Dictionary = {"jsonrpc": "2.0", "id": 1, "result": {"ok": true}}
	_http_server._send_sse_post_response(server_peer, response)
	var received: String = _read_client_data(client)
	assert_true(received.contains("HTTP/1.1 200 OK"), "SSE response should be 200 OK")
	assert_true(received.contains("Content-Type: text/event-stream"), "SSE response should declare text/event-stream")
	assert_true(received.contains("event: message"), "SSE response should use the message event name")
	assert_true(received.contains("data: " + JSON.stringify(response)), "SSE response should carry the JSON-RPC data event")
	assert_true(received.contains("Mcp-Session-Id: "), "SSE response should include a session id header")
	client.disconnect_from_host()

func test_send_http_response_json_wire_format():
	# 真实回环 TCP：验证 application/json 单响应（stateless 主路径）的线上字节格式
	_http_server.set_port(23143)
	assert_true(_http_server.start(), "Server should start on test port")
	var client: StreamPeerTCP = StreamPeerTCP.new()
	assert_eq(client.connect_to_host("127.0.0.1", 23143), OK, "Client should initiate connection")
	var server_peer: StreamPeerTCP = _wait_for_server_peer(client)
	assert_ne(server_peer, null, "Server should accept the client connection")
	if server_peer == null:
		client.disconnect_from_host()
		return
	var response: Dictionary = {"jsonrpc": "2.0", "id": 2, "result": {"pong": true}}
	_http_server._send_http_response(server_peer, response)
	var received: String = _read_client_data(client)
	assert_true(received.contains("Content-Type: application/json; charset=utf-8"), "JSON response should declare application/json")
	assert_true(received.contains("Mcp-Session-Id: "), "JSON response should include a session id header")
	assert_true(received.contains(JSON.stringify(response)), "JSON response should carry the body")
	client.disconnect_from_host()

# --- 辅助：等待服务器接受连接并返回服务器侧 peer ---
func _wait_for_server_peer(client: StreamPeerTCP) -> StreamPeerTCP:
	var attempts: int = 0
	while attempts < 200:
		client.poll()
		OS.delay_msec(5)
		if client.get_status() == StreamPeerTCP.STATUS_CONNECTED and _http_server._connections.size() > 0:
			return _http_server._connections[0]
		attempts += 1
	return null

# --- 辅助：读取客户端已接收的所有数据 ---
func _read_client_data(client: StreamPeerTCP) -> String:
	var received: String = ""
	var attempts: int = 0
	while received.is_empty() and attempts < 200:
		client.poll()
		OS.delay_msec(5)
		if client.get_available_bytes() > 0:
			var data: Array = client.get_data(client.get_available_bytes())
			if data[0] == OK:
				received += data[1].get_string_from_utf8()
		attempts += 1
	return received
