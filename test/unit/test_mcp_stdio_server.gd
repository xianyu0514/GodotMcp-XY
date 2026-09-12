extends "res://addons/gut/test.gd"

var _stdio_server: RefCounted = null

func before_each():
	_stdio_server = load("res://addons/godot_mcp/native_mcp/mcp_stdio_server.gd").new()

func after_each():
	if _stdio_server and _stdio_server.is_running():
		_stdio_server.stop()
	_stdio_server = null

func test_is_running_initially():
	assert_false(_stdio_server.is_running(), "Should not be running initially")

func test_active_flag_initially_false():
	assert_false(_stdio_server._active, "Active flag should be false initially")

func test_message_queue_initially_empty():
	assert_eq(_stdio_server._message_queue.size(), 0, "Message queue should be empty initially")

func test_parse_and_queue_message_valid_json():
	var valid_json: String = '{"jsonrpc":"2.0","method":"initialize","id":1}'
	_stdio_server._parse_and_queue_message(valid_json)
	_stdio_server._mutex.lock()
	assert_eq(_stdio_server._message_queue.size(), 1, "Message queue should have 1 item after valid JSON")
	var msg: Dictionary = _stdio_server._message_queue[0]
	assert_eq(msg["jsonrpc"], "2.0", "Message should have jsonrpc field")
	assert_eq(msg["method"], "initialize", "Message should have method field")
	_stdio_server._mutex.unlock()

func test_parse_and_queue_message_invalid_json():
	var invalid_json: String = "not valid json {{{"
	_stdio_server._parse_and_queue_message(invalid_json)
	_stdio_server._mutex.lock()
	assert_eq(_stdio_server._message_queue.size(), 0, "Message queue should be empty after invalid JSON")
	_stdio_server._mutex.unlock()

func test_parse_and_queue_message_multiline():
	var multiline: String = '{"jsonrpc":"2.0","method":"initialize","id":1}\n{"jsonrpc":"2.0","method":"tools/list","id":2}'
	_stdio_server._parse_and_queue_message(multiline)
	_stdio_server._mutex.lock()
	assert_eq(_stdio_server._message_queue.size(), 2, "Message queue should have 2 items for multiline input")
	_stdio_server._mutex.unlock()

func test_parse_and_queue_message_empty_lines():
	var input: String = '{"jsonrpc":"2.0","method":"initialize","id":1}\n\n\n{"jsonrpc":"2.0","method":"tools/list","id":2}'
	_stdio_server._parse_and_queue_message(input)
	_stdio_server._mutex.lock()
	assert_eq(_stdio_server._message_queue.size(), 2, "Empty lines should be skipped")
	_stdio_server._mutex.unlock()

func test_send_response_format():
	var response: Dictionary = {"jsonrpc": "2.0", "result": {"status": "ok"}, "id": 1}
	var json_string: String = JSON.stringify(response)
	var parsed: Variant = JSON.parse_string(json_string)
	assert_true(parsed is Dictionary, "Response should be valid JSON")
	assert_eq(parsed["jsonrpc"], "2.0", "Response should have jsonrpc field")
	assert_eq(parsed["id"], 1, "Response should have id field")

func test_send_error_format():
	var error_response: Dictionary = MCPTypes.create_error_response(1, -32700, "Parse error")
	assert_true(error_response.has("error"), "Error response should have error key")
	assert_eq(error_response["error"]["code"], -32700, "Error code should be -32700")
	assert_eq(error_response["id"], 1, "Error response should have id")

func test_mutex_exists():
	assert_ne(_stdio_server._mutex, null, "Mutex should be initialized")

func test_stop_when_not_running():
	_stdio_server.stop()
	assert_false(_stdio_server._active, "Should remain not active after stop")

func test_stdio_server_has_send_raw_message():
	assert_true(_stdio_server.has_method("send_raw_message"), "Stdio server should have send_raw_message method")

func test_send_raw_message_output():
	var test_message: Dictionary = {"jsonrpc": "2.0", "method": "notifications/tools/list_changed", "params": {}}
	_stdio_server.send_raw_message(test_message)
	assert_true(true, "send_raw_message should not crash when called")

# ------------------------------------------------------------------------------
# P9 修复：stop() 有界等待，避免阻塞在 stdin 读线程上导致死锁
# ------------------------------------------------------------------------------

func test_stop_timeout_constant():
	assert_eq(_stdio_server.STDIO_STOP_TIMEOUT_MS, 2000, "STDIO_STOP_TIMEOUT_MS should be 2000ms")

func test_wait_for_thread_exit_returns_true_when_thread_finishes():
	var t: Thread = Thread.new()
	t.start(func():
		OS.delay_msec(50)
	)
	var finished: bool = _stdio_server._wait_for_thread_exit(t, 2000)
	assert_true(finished, "A thread that finishes quickly should report exited")
	t.wait_to_finish()

func test_wait_for_thread_exit_returns_false_before_timeout():
	var t: Thread = Thread.new()
	t.start(func():
		OS.delay_msec(1500)
	)
	var start_ms: int = Time.get_ticks_msec()
	var finished: bool = _stdio_server._wait_for_thread_exit(t, 200)
	var elapsed: int = Time.get_ticks_msec() - start_ms
	assert_false(finished, "A long-running thread should report not exited after a short timeout")
	assert_lt(elapsed, 3000, "Bounded wait must return within its timeout (no deadlock)")
	# 清理：等待线程自然结束并 join
	assert_true(_stdio_server._wait_for_thread_exit(t, 3000), "Thread should finish eventually")
	t.wait_to_finish()

func test_stop_abandons_blocked_thread_within_timeout():
	# 模拟"运行中 stop 且读线程阻塞（无 stdin 输入）"：读线程不会因 _active=false
	# 立即退出（如同阻塞在 OS.read_string_from_stdin() 上），stop() 必须在有界
	# 时间内返回并放弃等待，而不是永久挂起。
	var t: Thread = Thread.new()
	t.start(func():
		OS.delay_msec(2500)
	)
	_stdio_server._active = true
	_stdio_server._thread = t
	var start_ms: int = Time.get_ticks_msec()
	_stdio_server.stop()
	var elapsed: int = Time.get_ticks_msec() - start_ms
	assert_false(_stdio_server._active, "stop() should clear the active flag")
	assert_eq(_stdio_server._thread, null, "stop() should drop the abandoned thread reference")
	assert_lt(elapsed, 3000, "stop() must return within bounded time (no deadlock)")
	assert_true(elapsed >= 1500, "stop() should have waited for the reader thread before abandoning")
	# 清理：等待线程自然结束并 join（stop() 已放弃对该线程的引用）
	assert_true(_stdio_server._wait_for_thread_exit(t, 3000), "Blocked thread should finish eventually")
	t.wait_to_finish()

func test_stop_joins_finished_thread():
	var t: Thread = Thread.new()
	t.start(func():
		OS.delay_msec(50)
	)
	_stdio_server._active = true
	_stdio_server._thread = t
	var start_ms: int = Time.get_ticks_msec()
	_stdio_server.stop()
	var elapsed: int = Time.get_ticks_msec() - start_ms
	assert_false(_stdio_server._active, "stop() should clear the active flag")
	assert_eq(_stdio_server._thread, null, "stop() should clear the thread reference after joining")
	assert_lt(elapsed, 3000, "stop() should return quickly when the thread exits on its own")

# ---- 畸形输入必须回答 JSON-RPC -32700（真实 stdio 握手测试发现的缺陷）------

class CaptureStdioServer extends "res://addons/godot_mcp/native_mcp/mcp_stdio_server.gd":
	var responses: Array = []
	func _send_response(response: Dictionary) -> void:
		responses.append(response)

func test_parse_error_answers_with_jsonrpc_32700() -> void:
	var server: CaptureStdioServer = CaptureStdioServer.new()
	server._parse_and_queue_message("this is definitely not json {{{")
	# _emit_error 经 call_deferred 在主线程执行；等两帧让延迟调用落地
	await get_tree().process_frame
	await get_tree().process_frame
	assert_eq(server.responses.size(), 1,
		"a malformed line must be answered with exactly one JSON-RPC error response")
	var payload: Dictionary = server.responses[0]
	assert_eq(payload.get("jsonrpc", ""), "2.0")
	assert_eq((payload.get("error", {}) as Dictionary).get("code", 0), -32700,
		"the parse error code must be -32700")
	assert_eq(payload.get("id", "missing"), null,
		"the parse error response carries id=null (the request id is unrecoverable)")

func test_parse_error_does_not_queue_or_answer_valid_lines_twice() -> void:
	var server: CaptureStdioServer = CaptureStdioServer.new()
	server._parse_and_queue_message('{"jsonrpc":"2.0","id":7,"method":"ping"}')
	# 入队是同步的：先验证队列，再等帧（延迟的 _process_next_message 会弹出）
	server._mutex.lock()
	var queued: int = server._message_queue.size()
	server._mutex.unlock()
	assert_eq(queued, 1, "the valid message reached the queue exactly once")
	await get_tree().process_frame
	await get_tree().process_frame
	assert_eq(server.responses.size(), 0,
		"valid messages are queued for the core, not answered by the transport")
