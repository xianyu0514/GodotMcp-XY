extends "res://addons/gut/test.gd"

var _core: RefCounted = null

func before_each():
	_core = load("res://addons/godot_mcp/native_mcp/mcp_server_core.gd").new()

func after_each():
	if _core and _core.is_running():
		_core.stop()
	_core = null

func test_negotiate_protocol_version_older():
	var result: String = _core._negotiate_protocol_version("2024-11-05")
	assert_eq(result, "2024-11-05", "Should return older supported version")

func test_negotiate_protocol_version_unsupported():
	var result: String = _core._negotiate_protocol_version("2099-01-01")
	assert_ne(result, "2099-01-01", "Should not return unsupported version")

func test_register_tool():
	_core.register_tool("test_tool", "A test tool", {"type": "object"}, func(args): return {"status": "ok"})
	assert_true(_core.has_tool("test_tool"), "Should have registered tool")

func test_register_tool_with_category_and_group():
	_core.register_tool("test_tool", "A test tool", {"type": "object"}, func(args): return {"status": "ok"}, {}, {}, "supplementary", "Editor-Advanced")
	assert_true(_core.has_tool("test_tool"), "Should have registered tool with category/group")
	var tools: Array = _core.get_registered_tools()
	for t in tools:
		if t.get("name") == "test_tool":
			assert_eq(t.get("category"), "supplementary", "Tool category should be supplementary")
			assert_eq(t.get("group"), "Editor-Advanced", "Tool group should be Editor-Advanced")

func test_register_tool_default_category_and_group():
	_core.register_tool("test_tool", "A test tool", {"type": "object"}, func(args): return {"status": "ok"})
	var tools: Array = _core.get_registered_tools()
	for t in tools:
		if t.get("name") == "test_tool":
			assert_eq(t.get("category"), "core", "Default category should be 'core'")
			assert_eq(t.get("group"), "", "Default group should be empty")

func test_unregister_tool():
	_core.register_tool("test_tool", "A test tool", {"type": "object"}, func(args): return {"status": "ok"})
	_core.unregister_tool("test_tool")
	assert_false(_core.has_tool("test_tool"), "Should not have unregistered tool")

func test_set_tool_enabled():
	_core.register_tool("test_tool", "A test tool", {"type": "object"}, func(args): return {"status": "ok"})
	_core.set_tool_enabled("test_tool", false)
	assert_true(_core.has_tool("test_tool"), "Disabled tool should still exist in tools dict")
	var tools: Array = _core.get_registered_tools()
	var found: bool = false
	for t in tools:
		if t.get("name") == "test_tool":
			assert_false(t.get("enabled", true), "Disabled tool should have enabled=false")
			found = true
	assert_true(found, "Disabled tool should appear in get_registered_tools")

func test_set_tool_enabled_re_enable():
	_core.register_tool("test_tool", "A test tool", {"type": "object"}, func(args): return {"status": "ok"})
	_core.set_tool_enabled("test_tool", false)
	_core.set_tool_enabled("test_tool", true)
	assert_true(_core.has_tool("test_tool"), "Re-enabled tool should exist")
	var tools: Array = _core.get_registered_tools()
	for t in tools:
		if t.get("name") == "test_tool":
			assert_true(t.get("enabled", false), "Re-enabled tool should have enabled=true")

func test_set_tool_enabled_sets_dirty_flag():
	_core.register_tool("test_tool", "Test", {"type": "object"}, func(args): return {})
	assert_false(_core.get_tool_list_dirty(), "Dirty flag should be false initially")
	_core.set_tool_enabled("test_tool", false)
	assert_true(_core.get_tool_list_dirty(), "Dirty flag should be true after disabling tool")

func test_clear_tool_list_dirty():
	_core.register_tool("test_tool", "Test", {"type": "object"}, func(args): return {})
	_core.set_tool_enabled("test_tool", false)
	assert_true(_core.get_tool_list_dirty(), "Dirty flag should be true")
	_core.clear_tool_list_dirty()
	assert_false(_core.get_tool_list_dirty(), "Dirty flag should be false after clear")

func test_set_group_enabled_disables_group():
	_core.register_tool("reload_project", "Reload", {"type": "object"}, func(args): return {}, {}, {}, "supplementary", "Editor-Advanced")
	_core.register_tool("execute_editor_script", "Exec Editor Script", {"type": "object"}, func(args): return {}, {}, {}, "supplementary", "Editor-Advanced")
	_core.set_group_enabled("Editor-Advanced", true)
	var changed: int = _core.set_group_enabled("Editor-Advanced", false)
	assert_true(changed >= 2, "Should change at least 2 tools: %d" % [changed])
	var tools: Array = _core.get_registered_tools()
	for t in tools:
		if t["name"] in ["reload_project", "execute_editor_script"]:
			assert_false(t["enabled"], "Tool %s should be disabled" % t["name"])

func test_set_group_enabled_re_enables_group():
	_core.register_tool("reload_project", "Reload", {"type": "object"}, func(args): return {}, {}, {}, "supplementary", "Editor-Advanced")
	_core.register_tool("execute_editor_script", "Exec Script", {"type": "object"}, func(args): return {}, {}, {}, "supplementary", "Editor-Advanced")
	_core.set_group_enabled("Editor-Advanced", true)
	var tools: Array = _core.get_registered_tools()
	for t in tools:
		if t["name"] in ["reload_project", "execute_editor_script"]:
			assert_true(t["enabled"], "Tool %s should be enabled" % t["name"])

func test_set_group_enabled_unknown_group():
	var changed: int = _core.set_group_enabled("NonExistent", false)
	assert_eq(changed, 0, "Unknown group should change 0 tools")

func test_notify_tool_list_changed_not_dirty():
	_core.notify_tool_list_changed()
	assert_false(_core.get_tool_list_dirty(), "Dirty flag should remain false when not dirty")

func test_get_classifier():
	var classifier = _core.get_classifier()
	assert_ne(classifier, null, "Should return a classifier instance")
	assert_true(classifier.has_method("get_all_tools"), "Classifier should have get_all_tools method")

func test_get_state_manager():
	var mgr = _core.get_state_manager()
	assert_ne(mgr, null, "Should return a state manager instance")
	assert_true(mgr.has_method("load_state"), "State manager should have load_state method")

func test_load_tool_states_returns_zero_when_no_saved_state():
	var count: int = _core.load_tool_states()
	assert_true(count >= 0, "Should return 0 or more: %d" % [count])

func test_save_and_load_tool_states():
	_core.register_tool("save_test_tool", "Save Test", {"type": "object"}, func(args): return {})
	_core.set_tool_enabled("save_test_tool", false)
	_core.save_tool_states()
	var count: int = _core.load_tool_states()
	assert_eq(count, 1, "Should load 1 tool state")
	var tools: Array = _core.get_registered_tools()
	for t in tools:
		if t["name"] == "save_test_tool":
			assert_false(t["enabled"], "Loaded state should have tool disabled")

func test_disabled_tool_not_in_tools_list():
	_core.register_tool("test_tool", "A test tool", {"type": "object"}, func(args): return {"status": "ok"})
	_core.register_tool("other_tool", "Another tool", {"type": "object"}, func(args): return {"status": "ok"})
	_core.set_tool_enabled("test_tool", false)
	var msg: Dictionary = {"id": 1, "method": "tools/list"}
	var response: Dictionary = _core._handle_tools_list(msg)
	var tools_list: Array = response.get("result", {}).get("tools", [])
	assert_eq(tools_list.size(), 1, "Should only have 1 enabled tool in tools/list response")
	if tools_list.size() > 0:
		assert_eq(tools_list[0].get("name", ""), "other_tool", "Only other_tool should appear")

func test_disabled_tool_call_returns_error():
	_core.register_tool("test_tool", "A test tool", {"type": "object"}, func(args): return {"status": "ok"})
	_core.set_tool_enabled("test_tool", false)
	var msg: Dictionary = {"id": 2, "method": "tools/call", "params": {"name": "test_tool", "arguments": {}}}
	var response: Dictionary = await _core._handle_tool_call(msg)
	assert_true(response.get("result", {}).get("isError", false), "Calling disabled tool should return isError")

func test_tool_enabled_default_core():
	_core.register_tool("test_tool", "A test tool", {"type": "object"}, func(args): return {"status": "ok"}, {}, {}, "core", "Script")
	var tools: Array = _core.get_registered_tools()
	for t in tools:
		if t.get("name") == "test_tool":
			assert_true(t.get("enabled", false), "Core tool should be enabled by default")

func test_tool_enabled_default_supplementary():
	_core.register_tool("test_supp_tool", "A supp tool", {"type": "object"}, func(args): return {"status": "ok"}, {}, {}, "supplementary", "Script-Advanced")
	var tools: Array = _core.get_registered_tools()
	for t in tools:
		if t.get("name") == "test_supp_tool":
			assert_false(t.get("enabled", true), "Supplementary tool should be disabled by default")

func test_get_tools_count():
	assert_eq(_core.get_tools_count(), 0, "Should have 0 tools initially")
	_core.register_tool("test_tool", "A test tool", {"type": "object"}, func(args): return {})
	assert_eq(_core.get_tools_count(), 1, "Should have 1 tool after registration")

func test_get_resources_count():
	assert_eq(_core.get_resources_count(), 0, "Should have 0 resources initially")

func test_register_resource():
	_core.register_resource("godot://test", "Test", "application/json", func(params): return {})
	assert_eq(_core.get_resources_count(), 1, "Should have 1 resource after registration")

func test_clear_cache():
	_core.set_cached_scene_structure("res://test.tscn", {"test": true})
	_core.clear_cache()
	var cached: Dictionary = _core.get_cached_scene_structure("res://test.tscn")
	assert_eq(cached.size(), 0, "Cache should be empty after clear")

func test_set_log_level():
	_core.set_log_level(MCPTypes.LogLevel.DEBUG)
	assert_eq(_core._log_level, MCPTypes.LogLevel.DEBUG, "Log level should be DEBUG")

func test_set_security_level():
	_core.set_security_level(MCPTypes.SecurityLevel.STRICT)
	assert_eq(_core._security_level, MCPTypes.SecurityLevel.STRICT, "Security level should be STRICT")

func test_set_rate_limit():
	_core.set_rate_limit(100)
	assert_eq(_core._rate_limit, 100, "Rate limit should be 100")

func test_is_running_initially():
	assert_false(_core.is_running(), "Should not be running initially")

func test_protocol_version_constant():
	assert_eq(MCPTypes.PROTOCOL_VERSION, "2025-11-25", "Protocol version should be 2025-11-25")

func test_sync_tool_call_with_await():
	_core.register_tool("sync_tool", "A sync tool", {"type": "object"}, func(args): return {"status": "ok"})
	var msg: Dictionary = {"id": 10, "method": "tools/call", "params": {"name": "sync_tool", "arguments": {}}}
	var response: Dictionary = await _core._handle_tool_call(msg)
	assert_false(response.get("result", {}).get("isError", true), "Sync tool via await should succeed")
	assert_eq(response.get("result", {}).get("content", [])[0].get("text"), '{"status":"ok"}', "Sync tool result should be preserved")

func test_async_tool_call_with_await():
	var tool_called: bool = false
	_core.register_tool("async_tool", "An async tool", {"type": "object"}, func(args):
		tool_called = true
		await get_tree().process_frame
		return {"status": "async_ok"}
	)
	var msg: Dictionary = {"id": 11, "method": "tools/call", "params": {"name": "async_tool", "arguments": {}}}
	var response: Dictionary = await _core._handle_tool_call(msg)
	assert_true(tool_called, "Async tool should have been called")
	assert_false(response.get("result", {}).get("isError", true), "Async tool via await should succeed")

func test_handle_request_awaits_tool_call():
	_core.register_tool("test_req_tool", "Test", {"type": "object"}, func(args): return {"value": 42})
	var msg: Dictionary = {"id": 12, "method": "tools/call", "params": {"name": "test_req_tool", "arguments": {}}}
	var response: Dictionary = await _core._handle_request(msg)
	assert_false(response.get("result", {}).get("isError", true), "handle_request should await tool_call successfully")

# ============================================================================
# Serial request queue
# ============================================================================

func test_request_queue_depth_initially_zero():
	assert_eq(_core.get_request_queue_depth(), 0, "Queue should start empty")

func test_queue_holds_requests_when_inactive():
	# _active is false by default, so the drain loop should not consume requests.
	_core.register_tool("queued_tool", "Test", {"type": "object"}, func(args): return {})
	for i in range(3):
		var msg: Dictionary = {"jsonrpc": "2.0", "id": i, "method": "tools/call", "params": {"name": "queued_tool", "arguments": {}}}
		_core._on_transport_message_received(msg, null)
	assert_eq(_core.get_request_queue_depth(), 3, "Inactive server should hold all queued requests")

func test_queue_backpressure_rejects_when_full():
	_core.register_tool("queued_tool", "Test", {"type": "object"}, func(args): return {})
	var max_size: int = _core.MAX_REQUEST_QUEUE_SIZE
	for i in range(max_size):
		var msg: Dictionary = {"jsonrpc": "2.0", "id": i, "method": "tools/call", "params": {"name": "queued_tool", "arguments": {}}}
		_core._on_transport_message_received(msg, null)
	assert_eq(_core.get_request_queue_depth(), max_size, "Queue should accept up to MAX_REQUEST_QUEUE_SIZE")
	# Server is inactive (_active == false), so no slot can ever free: the overflow
	# request must be rejected rather than queued or hung waiting indefinitely.
	var overflow: Dictionary = {"jsonrpc": "2.0", "id": 99999, "method": "tools/call", "params": {"name": "queued_tool", "arguments": {}}}
	_core._on_transport_message_received(overflow, null)
	assert_eq(_core.get_request_queue_depth(), max_size, "Request beyond MAX (server stopped) should be rejected, not queued")

func test_await_queue_slot_true_when_space_available():
	_core._active = true
	var ok: bool = await _core._await_queue_slot()
	assert_true(ok, "Should return true immediately when the queue has free space")

func test_await_queue_slot_false_when_inactive_and_full():
	_core._active = false
	for i in range(_core.MAX_REQUEST_QUEUE_SIZE):
		_core._request_queue.append({"message": {}, "context": null})
	# A stopped server can never free a slot; it must give up instead of hanging.
	var ok: bool = await _core._await_queue_slot()
	assert_false(ok, "Should return false (no hang) when server is stopped and queue is full")

func test_full_queue_waits_then_accepts_when_slot_frees():
	_core._active = true
	for i in range(_core.MAX_REQUEST_QUEUE_SIZE):
		_core._request_queue.append({"message": {}, "context": null})
	var result: Array = [null]
	var waiter: Callable = func():
		result[0] = await _core._await_queue_slot()
	waiter.call()
	await get_tree().process_frame
	assert_eq(result[0], null, "Waiter should still be blocked while the queue is full")
	# Free one slot; the waiter must resolve to true instead of being rejected.
	_core._request_queue.pop_front()
	await get_tree().process_frame
	await get_tree().process_frame
	assert_eq(result[0], true, "Waiter should resolve to true once a slot frees up")

func test_serial_queue_runs_requests_in_fifo_order():
	# Each tool call awaits two frames; if execution were concurrent we'd see
	# interleaving (start_1, start_2, ...). Serial execution must yield
	# start_1, end_1, start_2, end_2.
	_core._active = true
	var order: Array = []
	_core.register_tool("slow_tool", "Slow", {"type": "object"}, func(args):
		var n: int = args.get("n", 0)
		order.append("start_%d" % n)
		await get_tree().process_frame
		await get_tree().process_frame
		order.append("end_%d" % n)
		return {"n": n}
	)
	var m1: Dictionary = {"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": "slow_tool", "arguments": {"n": 1}}}
	var m2: Dictionary = {"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {"name": "slow_tool", "arguments": {"n": 2}}}
	_core._on_transport_message_received(m1, null)
	_core._on_transport_message_received(m2, null)
	for i in range(12):
		await get_tree().process_frame
	assert_eq(order, ["start_1", "end_1", "start_2", "end_2"], "Requests must run serially in FIFO order")
	assert_eq(_core.get_request_queue_depth(), 0, "Queue should be drained after processing")

func test_stop_clears_pending_queue():
	_core.register_tool("queued_tool", "Test", {"type": "object"}, func(args): return {})
	for i in range(3):
		var msg: Dictionary = {"jsonrpc": "2.0", "id": i, "method": "tools/call", "params": {"name": "queued_tool", "arguments": {}}}
		_core._on_transport_message_received(msg, null)
	assert_eq(_core.get_request_queue_depth(), 3, "Queue should hold requests before stop")
	# Mark active so stop() proceeds through its cleanup path.
	_core._active = true
	_core.stop()
	assert_eq(_core.get_request_queue_depth(), 0, "stop() should clear the pending request queue")
