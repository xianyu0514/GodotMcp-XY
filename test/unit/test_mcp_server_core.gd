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

func test_initialize_includes_instructions():
	var response: Dictionary = _core._handle_initialize({"id": 1, "params": {"protocolVersion": "2025-11-25"}})
	var result: Dictionary = response.get("result", {})
	assert_true(result.has("instructions"), "Initialize result should include an instructions field")
	var instructions: String = result.get("instructions", "")
	assert_true(instructions.contains("list_tool_catalog"), "Instructions should mention list_tool_catalog")
	assert_true(instructions.contains("enable_tools"), "Instructions should mention enable_tools")

func test_register_tool():
	_core.register_tool("test_tool", "A test tool", {"type": "object"}, func(args): return {"status": "ok"})
	assert_true(_core.has_tool("test_tool"), "Should have registered tool")

func test_meta_tool_cannot_be_disabled_via_set_tool_enabled():
	_core.register_tool("list_tool_catalog", "meta", {"type": "object"}, func(args): return {}, {}, {}, "meta", "Meta")
	_core.set_tool_enabled("list_tool_catalog", false)
	var enabled: bool = false
	for t in _core.get_registered_tools():
		if t.get("name") == "list_tool_catalog":
			enabled = t.get("enabled")
	assert_true(enabled, "Always-on meta tool must stay enabled despite a disable request")

func test_meta_group_cannot_be_disabled_via_set_group_enabled():
	_core.register_tool("enable_tools", "meta", {"type": "object"}, func(args): return {}, {}, {}, "meta", "Meta")
	_core.set_group_enabled("Meta", false)
	var enabled: bool = false
	for t in _core.get_registered_tools():
		if t.get("name") == "enable_tools":
			enabled = t.get("enabled")
	assert_true(enabled, "Disabling the Meta group must not disable always-on meta tools")

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
	_core.register_tool("select_node", "Select Node", {"type": "object"}, func(args): return {}, {}, {}, "supplementary", "Editor-Advanced")
	_core.set_group_enabled("Editor-Advanced", true)
	var changed: int = _core.set_group_enabled("Editor-Advanced", false)
	assert_true(changed >= 2, "Should change at least 2 tools: %d" % [changed])
	var tools: Array = _core.get_registered_tools()
	for t in tools:
		if t["name"] in ["reload_project", "select_node"]:
			assert_false(t["enabled"], "Tool %s should be disabled" % t["name"])

func test_set_group_enabled_re_enables_group():
	_core.register_tool("reload_project", "Reload", {"type": "object"}, func(args): return {}, {}, {}, "supplementary", "Editor-Advanced")
	_core.register_tool("select_node", "Select Node", {"type": "object"}, func(args): return {}, {}, {}, "supplementary", "Editor-Advanced")
	_core.set_group_enabled("Editor-Advanced", true)
	var tools: Array = _core.get_registered_tools()
	for t in tools:
		if t["name"] in ["reload_project", "select_node"]:
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

func test_tools_list_omits_output_schema():
	# tools/list 精简下发：outputSchema 不得随列表下发（完整 schema 由
	# get_tool_details 按需提供），inputSchema/annotations 等其余字段保留。
	_core.register_tool("schema_tool", "A tool with output schema", {"type": "object"}, func(args): return {"status": "ok"}, {"type": "object", "properties": {"result": {"type": "string"}}})
	var msg: Dictionary = {"jsonrpc": "2.0", "id": 1, "method": "tools/list"}
	var response: Dictionary = _core._handle_tools_list(msg)
	var tools_list: Array = response.get("result", {}).get("tools", [])
	assert_true(tools_list.size() >= 1, "Registered tool should appear in tools/list")
	for tool_entry in tools_list:
		assert_false(tool_entry.has("outputSchema"), "tools/list must not carry outputSchema: %s" % tool_entry.get("name", "?"))
		assert_true(tool_entry.has("inputSchema"), "tools/list should keep inputSchema: %s" % tool_entry.get("name", "?"))

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
	var state: Dictionary = {"called": false}
	_core.register_tool("async_tool", "An async tool", {"type": "object"}, func(args):
		state["called"] = true
		await get_tree().process_frame
		return {"status": "async_ok"}
	)
	var msg: Dictionary = {"id": 11, "method": "tools/call", "params": {"name": "async_tool", "arguments": {}}}
	var response: Dictionary = await _core._handle_tool_call(msg)
	assert_true(state["called"], "Async tool should have been called")
	assert_false(response.get("result", {}).get("isError", true), "Async tool via await should succeed")

func test_handle_request_awaits_tool_call():
	_core.register_tool("test_req_tool", "Test", {"type": "object"}, func(args): return {"value": 42})
	var msg: Dictionary = {"id": 12, "method": "tools/call", "params": {"name": "test_req_tool", "arguments": {}}}
	var response: Dictionary = await _core._handle_request(msg)
	assert_false(response.get("result", {}).get("isError", true), "handle_request should await tool_call successfully")

# ============================================================================
# Protocol compliance: ping / notifications / list _meta / server version
# ============================================================================

func test_ping_returns_empty_result():
	var msg: Dictionary = {"jsonrpc": "2.0", "id": 1, "method": "ping", "params": {}}
	var response: Dictionary = _core._handle_request(msg)
	assert_eq(response.get("jsonrpc", ""), "2.0", "Ping response should be JSON-RPC 2.0")
	assert_eq(response.get("id"), 1, "Ping response should echo the request id")
	assert_has(response, "result", "Ping response should carry a result")
	assert_eq(response.get("result", {}).size(), 0, "Ping result should be an empty dict")

func test_initialized_notification_no_response():
	var msg: Dictionary = {"jsonrpc": "2.0", "method": "notifications/initialized", "params": {}}
	var response: Dictionary = _core._handle_request(msg)
	assert_eq(response, {}, "Known notification must be handled without producing a response")

func test_notification_gets_no_response():
	var msg: Dictionary = {"jsonrpc": "2.0", "method": "notifications/cancelled", "params": {}}
	var response: Dictionary = _core._handle_request(msg)
	assert_eq(response, {}, "Notification must never produce a response")

func test_unknown_notification_no_error_response():
	var msg: Dictionary = {"jsonrpc": "2.0", "method": "notifications/unknown_method", "params": {}}
	var response: Dictionary = _core._handle_request(msg)
	assert_eq(response, {}, "Unknown notification must not produce an error response")

func test_rate_limit_skips_notifications():
	_core.set_rate_limit(1)
	# 消耗唯一的速率配额：一次带 id 的请求应通过。
	var req: Dictionary = {"jsonrpc": "2.0", "id": 1, "method": "ping", "params": {}}
	var req_response: Dictionary = _core._handle_request(req)
	assert_has(req_response, "result", "First request should pass the rate limit")
	# 第二个带 id 的请求应被限流拒绝。
	var second: Dictionary = {"jsonrpc": "2.0", "id": 2, "method": "ping", "params": {}}
	var limited: Dictionary = _core._handle_request(second)
	assert_true(limited.has("error"), "Second request should be rate limited")
	# 通知不受限流影响：仍返回空字典，且不计入配额（不再触发限流错误响应）。
	var notification: Dictionary = {"jsonrpc": "2.0", "method": "notifications/cancelled", "params": {}}
	var notif_response: Dictionary = _core._handle_request(notification)
	assert_eq(notif_response, {}, "Notification must skip rate limiting and never produce a response")

func test_tools_list_has_meta_ttl():
	var msg: Dictionary = {"jsonrpc": "2.0", "id": 1, "method": "tools/list"}
	var response: Dictionary = _core._handle_tools_list(msg)
	var result: Dictionary = response.get("result", {})
	assert_has(result, "_meta", "tools/list result should include _meta")
	var meta: Dictionary = result.get("_meta", {})
	assert_eq(meta.get("ttlMs", 0), _core.LIST_CACHE_TTL_MS, "_meta.ttlMs should equal LIST_CACHE_TTL_MS")
	assert_eq(meta.get("cacheScope", ""), "toolSet", "_meta.cacheScope should be 'toolSet'")

func test_resources_list_has_meta_ttl():
	var msg: Dictionary = {"jsonrpc": "2.0", "id": 1, "method": "resources/list"}
	var response: Dictionary = _core._handle_resources_list(msg)
	var result: Dictionary = response.get("result", {})
	var meta: Dictionary = result.get("_meta", {})
	assert_eq(meta.get("ttlMs", 0), _core.LIST_CACHE_TTL_MS, "_meta.ttlMs should equal LIST_CACHE_TTL_MS")
	assert_eq(meta.get("cacheScope", ""), "resourceList", "_meta.cacheScope should be 'resourceList'")

func test_prompts_list_has_meta_ttl():
	var msg: Dictionary = {"jsonrpc": "2.0", "id": 1, "method": "prompts/list"}
	var response: Dictionary = _core._handle_prompts_list(msg)
	var result: Dictionary = response.get("result", {})
	var meta: Dictionary = result.get("_meta", {})
	assert_eq(meta.get("ttlMs", 0), _core.LIST_CACHE_TTL_MS, "_meta.ttlMs should equal LIST_CACHE_TTL_MS")
	assert_eq(meta.get("cacheScope", ""), "promptList", "_meta.cacheScope should be 'promptList'")

func test_initialize_default_server_version_fallback():
	# start() 尚未调用时，_server_version 保持默认 "0.0.0"，且不再硬编码 "2.0.0"。
	var response: Dictionary = _core._handle_initialize({"id": 1, "params": {"protocolVersion": "2025-11-25"}})
	var server_info: Dictionary = response.get("result", {}).get("serverInfo", {})
	assert_eq(server_info.get("name", ""), "godot-native-mcp", "serverInfo.name should stay godot-native-mcp")
	assert_eq(server_info.get("version", ""), "0.0.0", "Before start(), serverInfo.version should fall back to 0.0.0")

func test_initialize_server_version_from_plugin_cfg():
	# start() 会在 _active = true 之前调用 _load_plugin_version()；测试直接调用它，
	# 避免启动 stdio 传输线程（headless 下会阻塞等待 stdin）。
	_core._load_plugin_version()
	var response: Dictionary = _core._handle_initialize({"id": 1, "params": {"protocolVersion": "2025-11-25"}})
	var server_info: Dictionary = response.get("result", {}).get("serverInfo", {})
	var version: String = server_info.get("version", "")
	assert_false(version.is_empty(), "serverInfo.version should be non-empty")
	assert_ne(version, "2.0.0", "serverInfo.version should not be the old hardcoded 2.0.0")
	var config: ConfigFile = ConfigFile.new()
	assert_eq(config.load(_core.PLUGIN_CONFIG_PATH), OK, "plugin.cfg should load")
	assert_eq(version, config.get_value("plugin", "version", ""), "serverInfo.version should equal plugin.cfg plugin/version")

func test_set_server_version_override():
	_core.set_server_version("9.9.9")
	var response: Dictionary = _core._handle_initialize({"id": 1, "params": {"protocolVersion": "2025-11-25"}})
	var server_info: Dictionary = response.get("result", {}).get("serverInfo", {})
	assert_eq(server_info.get("version", ""), "9.9.9", "set_server_version should override the reported version")

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

func test_admission_preserves_fifo_order_under_backpressure():
	# Fill the queue, then start three waiters in arrival order A, B, C. Each waiter
	# re-fills the queue on admission (as the real caller does), so exactly one waiter
	# is admitted per freed slot. Admission must follow arrival order, not coroutine
	# resume order.
	_core._active = true
	var max_size: int = _core.MAX_REQUEST_QUEUE_SIZE
	for i in range(max_size):
		_core._request_queue.append({"message": {}, "context": null})
	var admit_order: Array = []
	var make_waiter: Callable = func(tag: String):
		var ok: bool = await _core._await_queue_slot()
		if ok:
			admit_order.append(tag)
			_core._request_queue.append({"message": {}, "context": null})
	make_waiter.call("A")
	await get_tree().process_frame
	make_waiter.call("B")
	await get_tree().process_frame
	make_waiter.call("C")
	await get_tree().process_frame
	assert_eq(admit_order, [], "All waiters should be blocked while the queue is full")
	# Free one slot at a time; each frees exactly one waiter, in arrival order.
	for expected in ["A", "B", "C"]:
		_core._request_queue.pop_front()
		await get_tree().process_frame
		await get_tree().process_frame
	assert_eq(admit_order, ["A", "B", "C"], "Backpressured requests must be admitted in FIFO arrival order")

func test_waiter_cap_rejects_when_too_many_waiting():
	# When the queue is full AND the waiter line is already at MAX_WAITING_REQUESTS,
	# a new request must be rejected immediately instead of adding another live
	# coroutine, bounding coroutine overhead under sustained backpressure.
	_core._active = true
	var max_size: int = _core.MAX_REQUEST_QUEUE_SIZE
	for i in range(max_size):
		_core._request_queue.append({"message": {}, "context": null})
	for i in range(_core.MAX_WAITING_REQUESTS):
		_core._admission_waiters.append(i)
	_core._admission_waiter_seq = _core.MAX_WAITING_REQUESTS
	var overflow: Dictionary = {"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": "x", "arguments": {}}}
	_core._on_transport_message_received(overflow, null)
	assert_eq(_core._admission_waiters.size(), _core.MAX_WAITING_REQUESTS, "At the waiter cap, a new request must be rejected, not added as a waiter")
	assert_eq(_core.get_request_queue_depth(), max_size, "Rejected request must not be enqueued")

func test_drain_yields_a_frame_between_requests():
	# Two requests queued up front. The drain loop must yield a frame between them
	# so the editor stays responsive under sustained load; we detect the yield by
	# the process-frame counter advancing between the two tool executions.
	_core._active = true
	var frames: Array = []
	_core.register_tool("frame_probe", "Probe", {"type": "object"},
		func(args):
			frames.append(Engine.get_process_frames())
			return {})
	for i in range(2):
		var msg: Dictionary = {"jsonrpc": "2.0", "id": i, "method": "tools/call", "params": {"name": "frame_probe", "arguments": {}}}
		_core._request_queue.append({"message": msg, "context": null})
	_core._drain_request_queue()
	for i in range(8):
		await get_tree().process_frame
	assert_eq(frames.size(), 2, "Both queued requests should be processed")
	assert_true(frames[1] > frames[0], "Drain loop should yield at least one frame between requests")

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

# ============================================================================
# Scene structure read-through cache
# ============================================================================

func test_cacheable_read_served_from_cache_on_second_call():
	# "get_scene_structure" is in CACHEABLE_READ_TOOLS, so the second identical
	# call must be served from cache without re-executing the handler.
	var calls: Array = [0]
	_core.register_tool("get_scene_structure", "Read scene", {"type": "object"},
		func(args):
			calls[0] += 1
			return {"scene_name": "Main", "call": calls[0]},
		{}, {"readOnlyHint": true})
	var msg: Dictionary = {"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": "get_scene_structure", "arguments": {}}}
	var r1: Dictionary = await _core._handle_request(msg)
	var r2: Dictionary = await _core._handle_request(msg)
	assert_eq(calls[0], 1, "Handler should run once; the second call is served from cache")
	assert_eq(JSON.stringify(r1), JSON.stringify(r2), "Cached response should match the first response")

func test_mutating_tool_invalidates_read_cache():
	var calls: Array = [0]
	_core.register_tool("get_scene_structure", "Read scene", {"type": "object"},
		func(args):
			calls[0] += 1
			return {"scene_name": "Main", "call": calls[0]},
		{}, {"readOnlyHint": true})
	_core.register_tool("create_node", "Mutate", {"type": "object"},
		func(args): return {"status": "success"},
		{}, {"readOnlyHint": false})
	var read_msg: Dictionary = {"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": "get_scene_structure", "arguments": {}}}
	var mutate_msg: Dictionary = {"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {"name": "create_node", "arguments": {}}}
	await _core._handle_request(read_msg)        # populates cache (call 1)
	await _core._handle_request(read_msg)         # cache hit (still call 1)
	assert_eq(calls[0], 1, "Second read before mutation should be cached")
	await _core._handle_request(mutate_msg)        # mutation invalidates cache
	await _core._handle_request(read_msg)          # must recompute (call 2)
	assert_eq(calls[0], 2, "Read after a mutating tool must recompute, not serve stale cache")

func test_cacheable_read_keys_by_arguments():
	var calls: Array = [0]
	_core.register_tool("get_scene_structure", "Read scene", {"type": "object"},
		func(args):
			calls[0] += 1
			return {"scene_name": "Main", "depth": args.get("max_depth", -1)},
		{}, {"readOnlyHint": true})
	var deep: Dictionary = {"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": "get_scene_structure", "arguments": {"max_depth": 2}}}
	var shallow: Dictionary = {"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {"name": "get_scene_structure", "arguments": {"max_depth": 1}}}
	await _core._handle_request(deep)
	await _core._handle_request(shallow)
	await _core._handle_request(deep)
	await _core._handle_request(shallow)
	assert_eq(calls[0], 2, "Different arguments cache separately; each variant computed once")

func test_all_cacheable_read_tools_are_served_from_cache():
	# Guard the whole CACHEABLE_READ_TOOLS list (not just get_scene_structure):
	# every listed read-only tool must be served from cache on a repeat call.
	for tool_name in _core.CACHEABLE_READ_TOOLS:
		var calls: Array = [0]
		_core.register_tool(tool_name, "Read", {"type": "object"},
			func(args):
				calls[0] += 1
				return {"ok": true, "n": calls[0]},
			{}, {"readOnlyHint": true})
		var msg: Dictionary = {"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": tool_name, "arguments": {}}}
		await _core._handle_request(msg)
		await _core._handle_request(msg)
		assert_eq(calls[0], 1, "%s should be served from cache on the second call" % tool_name)

func test_unknown_mutation_invalidates_all_cacheable_read_tools():
	# Plugin-defined writers have no dependency metadata, so they must fail safe
	# to the global revision and invalidate every cacheable read domain.
	_core.register_tool("plugin_defined_writer", "Mutate", {"type": "object"},
		func(args): return {"status": "success"},
		{}, {"readOnlyHint": false}, "core", "Custom")
	var mutate_msg: Dictionary = {"jsonrpc": "2.0", "id": 99, "method": "tools/call", "params": {"name": "plugin_defined_writer", "arguments": {}}}
	for tool_name in _core.CACHEABLE_READ_TOOLS:
		var calls: Array = [0]
		_core.register_tool(tool_name, "Read", {"type": "object"},
			func(args):
				calls[0] += 1
				return {"n": calls[0]},
			{}, {"readOnlyHint": true})
		var read_msg: Dictionary = {"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": tool_name, "arguments": {}}}
		await _core._handle_request(read_msg)
		await _core._handle_request(read_msg)
		assert_eq(calls[0], 1, "%s should be cached before mutation" % tool_name)
		await _core._handle_request(mutate_msg)
		await _core._handle_request(read_msg)
		assert_eq(calls[0], 2, "%s must recompute after an unknown mutating tool" % tool_name)

# ============================================================================
# 通用结果缓存（LRU + 确定性 key + 依赖 revision 懒失效）
# ============================================================================

func test_result_cache_hit_serves_cached():
	# A cacheable read tool's repeat call (same tool + same args) must be served
	# straight from the result cache without re-executing the handler.
	var calls: Array = [0]
	_core.register_tool("get_project_structure", "Read structure", {"type": "object"},
		func(args):
			calls[0] += 1
			return {"total_files": 42, "calls": calls[0]},
		{}, {"readOnlyHint": true})
	var msg: Dictionary = {"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": "get_project_structure", "arguments": {}}}
	var r1: Dictionary = await _core._handle_request(msg)
	var r2: Dictionary = await _core._handle_request(msg)
	assert_eq(calls[0], 1, "Repeat call must be served from the result cache")
	assert_eq(JSON.stringify(r1), JSON.stringify(r2), "Cached response must match the first response")

func test_result_cache_key_canonical():
	# The cache key is built from canonical (key-sorted) JSON: two argument
	# dicts with identical content but different insertion order must hit the
	# same cache entry.
	var args_a: Dictionary = {"filter": "a", "opts": {"z": 1, "y": 2, "x": 3}, "list": [1, {"k": "v"}]}
	var args_b: Dictionary = {"list": [1, {"k": "v"}], "opts": {"x": 3, "y": 2, "z": 1}, "filter": "a"}
	assert_eq(_core._canonical_json(args_a), _core._canonical_json(args_b),
		"Canonical JSON must ignore dictionary insertion order")
	var calls: Array = [0]
	_core.register_tool("list_project_autoloads", "Read autoloads", {"type": "object"},
		func(args):
			calls[0] += 1
			return {"count": calls[0]},
		{}, {"readOnlyHint": true})
	var msg_a: Dictionary = {"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": "list_project_autoloads", "arguments": args_a}}
	var msg_b: Dictionary = {"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {"name": "list_project_autoloads", "arguments": args_b}}
	await _core._handle_request(msg_a)
	await _core._handle_request(msg_b)
	assert_eq(calls[0], 1, "Reordered arguments must share one cache entry")

func test_mutating_tool_invalidates_cache():
	# A scene mutation advances the scene revision, so the next scene read
	# recomputes instead of serving the stale entry.
	var calls: Array = [0]
	_core.register_tool("get_scene_tree", "Read tree", {"type": "object"},
		func(args):
			calls[0] += 1
			return {"nodes": ["A"], "calls": calls[0]},
		{}, {"readOnlyHint": true})
	_core.register_tool("rename_node", "Mutate", {"type": "object"},
		func(args): return {"status": "ok"},
		{}, {"readOnlyHint": false})
	var read_msg: Dictionary = {"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": "get_scene_tree", "arguments": {}}}
	var mutate_msg: Dictionary = {"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {"name": "rename_node", "arguments": {}}}
	await _core._handle_request(read_msg)
	await _core._handle_request(read_msg)
	assert_eq(calls[0], 1, "Second read before mutation should be a cache hit")
	await _core._handle_request(mutate_msg)
	await _core._handle_request(read_msg)
	assert_eq(calls[0], 2, "Read after a mutating tool must recompute, not serve stale cache")

func test_cache_lru_eviction():
	# Beyond RESULT_CACHE_MAX distinct keys, the least recently used entry must
	# be evicted: re-calling the earliest key re-executes the handler.
	var calls: Dictionary = {}
	_core.register_tool("get_scene_structure", "Read scene", {"type": "object"},
		func(args):
			var n: int = args.get("n", 0)
			calls[n] = calls.get(n, 0) + 1
			return {"n": n},
		{}, {"readOnlyHint": true})
	var max: int = _core.RESULT_CACHE_MAX
	for n in range(max + 5):
		var msg: Dictionary = {"jsonrpc": "2.0", "id": n, "method": "tools/call",
			"params": {"name": "get_scene_structure", "arguments": {"n": n}}}
		await _core._handle_request(msg)
	assert_true(_core._result_cache.size() <= max,
		"Cache must not exceed RESULT_CACHE_MAX entries (has %d)" % _core._result_cache.size())
	assert_true(_core._result_cache_order.size() <= max,
		"LRU order must not exceed RESULT_CACHE_MAX entries (has %d)" % _core._result_cache_order.size())
	# The earliest key (n=0) fell off the LRU: re-calling it must recompute.
	var before: int = calls.get(0, 0)
	var msg0: Dictionary = {"jsonrpc": "2.0", "id": 900, "method": "tools/call",
		"params": {"name": "get_scene_structure", "arguments": {"n": 0}}}
	await _core._handle_request(msg0)
	assert_eq(calls.get(0, 0), before + 1, "LRU-evicted entry must recompute on next access")

func test_spill_large_result():
	# A result whose JSON exceeds MAX_INLINE_RESULT_BYTES is spilled to disk and
	# returned as a truncated head/tail preview — isError stays false and the
	# spill file contains the full JSON.
	var big_value: Dictionary = {"items": []}
	for i in range(3000):
		big_value["items"].append({"index": i, "payload": "x".repeat(40)})
	_core.register_tool("big_result_tool", "Big result", {"type": "object"},
		func(args): return big_value,
		{}, {"readOnlyHint": true})
	var msg: Dictionary = {"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": "big_result_tool", "arguments": {}}}
	var response: Dictionary = await _core._handle_request(msg)
	var result: Dictionary = response.get("result", {})
	assert_false(result.get("isError", false), "Spilled result must not be an error")
	assert_false(result.has("structuredContent"), "Spilled result must not echo the full payload as structuredContent")
	var text: String = result.get("content", [{}])[0].get("text", "")
	var payload: Dictionary = JSON.parse_string(text)
	assert_true(payload.has("truncated"), "Large result should carry the truncated flag")
	assert_true(payload.get("truncated", false), "truncated must be true")
	assert_true(payload.get("total_bytes", 0) > _core.MAX_INLINE_RESULT_BYTES,
		"total_bytes must exceed the inline limit")
	var path: String = payload.get("path", "")
	assert_false(path.is_empty(), "Spill path must be non-empty")
	assert_true(FileAccess.file_exists(path), "Spill file must exist on disk: " + path)
	assert_true(FileAccess.get_file_as_string(path).length() > 0, "Spill file must contain the full JSON")
	assert_false(str(payload.get("head", "")).is_empty(), "head preview must be non-empty")
	assert_false(str(payload.get("tail", "")).is_empty(), "tail preview must be non-empty")
	# Clean up the test artifact so the repo stays clean.
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)

func test_spill_exempt_tools_not_spilled():
	# File-content tools in SPILL_EXEMPT_TOOLS keep returning their content
	# inline even when it exceeds the size limit (no spill ping-pong).
	var big_content: String = "y".repeat(60000)
	_core.register_tool("read_script", "Read script", {"type": "object"},
		func(args): return {"script_path": "res://x.gd", "content": big_content, "line_count": 1},
		{}, {"readOnlyHint": true})
	var msg: Dictionary = {"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": "read_script", "arguments": {"script_path": "res://x.gd"}}}
	var response: Dictionary = await _core._handle_request(msg)
	var result: Dictionary = response.get("result", {})
	assert_false(result.get("isError", false), "Exempt tool result must not be an error")
	var text: String = result.get("content", [{}])[0].get("text", "")
	var payload: Variant = JSON.parse_string(text)
	assert_false(payload is Dictionary and payload.has("truncated"),
		"Exempt tools must never spill: %s" % text.substr(0, 120))

# ============================================================================
# Progress 通知与取消支持（notifications/progress + notifications/cancelled）
# ============================================================================

## Minimal transport double that records every raw message sent. Extends the
## transport base so it can be assigned to the core's typed _transport member.
class MockTransport:
	extends McpTransportBase
	var sent: Array = []
	func send_raw_message(message: Dictionary) -> void:
		sent.append(message)
	func is_running() -> bool:
		return false

# --- notifications/cancelled handling ---------------------------------------

func test_cancelled_notification_marks_request():
	var msg: Dictionary = {"jsonrpc": "2.0", "method": "notifications/cancelled", "params": {"requestId": 42}}
	var response: Dictionary = _core._handle_request(msg)
	assert_eq(response, {}, "cancelled notification must never produce a response")
	assert_true(_core.is_request_cancelled(42), "request id should be marked cancelled")

func test_cancelled_unknown_request_noop():
	var msg: Dictionary = {"jsonrpc": "2.0", "method": "notifications/cancelled", "params": {"requestId": 999}}
	var response: Dictionary = _core._handle_request(msg)
	assert_eq(response, {}, "unknown cancelled notification produces no response")
	assert_false(_core.is_request_cancelled(1), "unrelated ids must not be marked")
	# clear_cancelled on a known id removes it; on an unknown id it is a no-op.
	_core.clear_cancelled(999)
	assert_false(_core.is_request_cancelled(999), "clear_cancelled removes the marker")
	_core.clear_cancelled(12345)
	assert_true(true, "clear_cancelled on an unknown id must not crash")

func test_cancelled_notification_without_request_id_ignored():
	var msg: Dictionary = {"jsonrpc": "2.0", "method": "notifications/cancelled", "params": {}}
	var response: Dictionary = _core._handle_request(msg)
	assert_eq(response, {}, "missing requestId still yields no response")
	assert_eq(_core._cancelled_requests.size(), 0, "no marker added without requestId")

func test_cancelled_notification_fast_path_bypasses_queue():
	# Cancellation must not wait behind the serial queue (it is meant to cancel
	# the in-flight request, which is exactly the one occupying the queue), so it
	# is processed immediately when received through the transport.
	var msg: Dictionary = {"jsonrpc": "2.0", "method": "notifications/cancelled", "params": {"requestId": "req-1"}}
	_core._on_transport_message_received(msg, null)
	assert_true(_core.is_request_cancelled("req-1"), "fast path marks the request immediately")
	assert_eq(_core.get_request_queue_depth(), 0, "cancelled notification must not enter the serial queue")

# --- send_progress_notification --------------------------------------------

func test_send_progress_without_transport_silent():
	# No transport connected: sending must not crash and must silently no-op.
	_core.send_progress_notification("tok-1", 1, 0, "hi")
	assert_true(true, "send_progress with no transport should not crash")

func test_send_progress_without_token_silent():
	var mock: MockTransport = MockTransport.new()
	_core._transport = mock
	_core.send_progress_notification(null, 1)
	assert_eq(mock.sent.size(), 0, "no notification sent without a progress token")
	_core._transport = null

func test_send_progress_with_token_sends_notification():
	var mock: MockTransport = MockTransport.new()
	_core._transport = mock
	_core.send_progress_notification("tok-1", 5, 10, "working")
	assert_eq(mock.sent.size(), 1, "one progress notification sent")
	var msg: Dictionary = mock.sent[0]
	assert_eq(msg.get("jsonrpc", ""), "2.0", "payload should be JSON-RPC 2.0")
	assert_eq(msg.get("method", ""), "notifications/progress", "method should be notifications/progress")
	var params: Dictionary = msg.get("params", {})
	assert_eq(params.get("progressToken"), "tok-1", "progressToken echoed")
	assert_eq(params.get("progress"), 5, "progress value")
	assert_eq(params.get("total"), 10, "total value")
	assert_eq(params.get("message"), "working", "message value")
	_core._transport = null

func test_send_progress_omits_optional_fields_when_empty():
	var mock: MockTransport = MockTransport.new()
	_core._transport = mock
	_core.send_progress_notification("tok-2", 3)
	var params: Dictionary = mock.sent[0].get("params", {})
	assert_false(params.has("total"), "total omitted when 0")
	assert_false(params.has("message"), "message omitted when empty")
	_core._transport = null

# --- tool-call execution context + cancellation cleanup ---------------------

func test_tool_call_clears_cancelled_marker():
	var observed: Array = []
	_core.register_tool("cancel_probe", "Probe", {"type": "object"}, func(args):
		observed.append(_core.is_request_cancelled(77))
		return {})
	_core._cancelled_requests[77] = true
	var msg: Dictionary = {"jsonrpc": "2.0", "id": 77, "method": "tools/call", "params": {"name": "cancel_probe", "arguments": {}}}
	var response: Dictionary = await _core._handle_tool_call(msg)
	assert_eq(observed.size(), 1, "tool executed once")
	assert_true(observed[0], "marker visible to the tool during execution")
	assert_false(_core.is_request_cancelled(77), "marker cleared after tool execution")
	assert_false(response.get("result", {}).get("isError", false), "call should succeed")

func test_execution_context_set_during_call_and_cleared_after():
	var observed: Array = []
	_core.register_tool("ctx_probe", "Probe", {"type": "object"}, func(args):
		observed.append(_core._execution_context.duplicate())
		return {})
	var msg: Dictionary = {"jsonrpc": "2.0", "id": 55, "method": "tools/call", "params": {"name": "ctx_probe", "arguments": {"_meta": {"progressToken": "pt-55"}}}}
	await _core._handle_tool_call(msg)
	assert_eq(observed.size(), 1, "tool executed once")
	assert_eq(observed[0].get("tool_name"), "ctx_probe", "context records the tool name")
	assert_eq(observed[0].get("request_id"), 55, "context records the request id")
	assert_eq(observed[0].get("progress_token"), "pt-55", "context records arguments._meta.progressToken")
	assert_true(_core._execution_context.is_empty(), "execution context cleared after the tool call")

func test_execution_context_token_from_params_meta():
	# Spec-compliant clients put _meta.progressToken next to arguments, not inside
	# them; the core must capture it from there as well.
	var observed: Array = []
	_core.register_tool("meta_probe", "Probe", {"type": "object"}, func(args):
		observed.append(_core._execution_context.duplicate())
		return {})
	var msg: Dictionary = {"jsonrpc": "2.0", "id": 7, "method": "tools/call", "params": {"name": "meta_probe", "arguments": {}, "_meta": {"progressToken": "pt-params"}}}
	await _core._handle_tool_call(msg)
	assert_eq(observed[0].get("progress_token"), "pt-params", "params._meta.progressToken captured")

func test_is_current_tool_cancelled_outside_execution():
	assert_false(_core.is_current_tool_cancelled(), "no execution context -> not cancelled")
	assert_eq(_core.get_current_progress_token(), null, "no execution context -> no progress token")

func test_fast_path_cancel_flips_inflight_flag():
	# A cancel notification delivered before a queued tool call runs must be
	# observed by that call (fast path), and the marker must be cleared once the
	# call finishes.
	var saw: Array = []
	_core.register_tool("inflight_probe", "Probe", {"type": "object"}, func(args):
		await get_tree().process_frame
		saw.append(_core.is_current_tool_cancelled())
		return {"done": true})
	_core._active = true
	var msg: Dictionary = {"jsonrpc": "2.0", "id": 321, "method": "tools/call", "params": {"name": "inflight_probe", "arguments": {}}}
	_core._request_queue.append({"message": msg, "context": null})
	var cancel_msg: Dictionary = {"jsonrpc": "2.0", "method": "notifications/cancelled", "params": {"requestId": 321}}
	_core._on_transport_message_received(cancel_msg, null)
	assert_true(_core.is_request_cancelled(321), "fast path marks before the queued call runs")
	_core._drain_request_queue()
	await get_tree().process_frame
	await get_tree().process_frame
	assert_eq(saw.size(), 1, "tool ran once")
	assert_true(saw[0], "tool observed the cancellation mid-run")
	assert_false(_core.is_request_cancelled(321), "marker cleared after the call finished")
	assert_eq(_core.get_request_queue_depth(), 0, "queue fully drained")
	_core._active = false

# --- tool integration: run_project_test through the real core ----------------

func test_run_project_test_progress_and_cancel_via_core():
	# End-to-end: the real project tool wired to the real core. The cancelled
	# path returns a cancelled status; the pending-poll path emits a progress
	# notification through the (mock) transport.
	var core: RefCounted = load("res://addons/godot_mcp/native_mcp/mcp_server_core.gd").new()
	var tools: RefCounted = load("res://addons/godot_mcp/tools/project_tools_native.gd").new()
	tools._server_core = core
	core.register_tool("run_project_test", "Run a single test", {"type": "object"},
		Callable(tools, "_tool_run_project_test"), {}, {}, "supplementary", "Project-Advanced")
	core.set_tool_enabled("run_project_test", true)
	var mock: MockTransport = MockTransport.new()
	core._transport = mock
	var test_path: String = "res://test/unit/test_async_job_runner.gd"
	# Seed a running job so the tool takes the pending/poll path.
	tools._test_runner.start(test_path, func() -> Dictionary:
		OS.delay_msec(800)
		return {"status": "passed", "framework": "fake"})
	# 1) Cancelled request -> tool aborts with a cancelled status.
	core._cancelled_requests[1001] = true
	var cancel_msg: Dictionary = {"jsonrpc": "2.0", "id": 1001, "method": "tools/call", "params": {"name": "run_project_test", "arguments": {"test_path": test_path, "_meta": {"progressToken": "tok-x"}}}}
	var cancel_resp: Dictionary = await core._handle_tool_call(cancel_msg)
	var cancel_payload: Dictionary = JSON.parse_string(cancel_resp.get("result", {}).get("content", [{}])[0].get("text", "{}"))
	assert_eq(cancel_payload.get("status"), "cancelled", "run_project_test aborts when the request is cancelled")
	assert_false(core.is_request_cancelled(1001), "marker cleared after the cancelled call finished")
	# 2) Normal pending poll -> a progress notification is emitted.
	var poll_msg: Dictionary = {"jsonrpc": "2.0", "id": 1002, "method": "tools/call", "params": {"name": "run_project_test", "arguments": {"test_path": test_path, "_meta": {"progressToken": "tok-y"}}}}
	var poll_resp: Dictionary = await core._handle_tool_call(poll_msg)
	var poll_payload: Dictionary = JSON.parse_string(poll_resp.get("result", {}).get("content", [{}])[0].get("text", "{}"))
	assert_eq(poll_payload.get("status"), "pending", "running job still reports pending")
	assert_true(mock.sent.size() >= 1, "at least one progress notification was sent")
	var sent_methods: Array = []
	for m in mock.sent:
		sent_methods.append(m.get("method", ""))
	assert_true("notifications/progress" in sent_methods, "a notifications/progress message was sent during polling")
	tools._test_runner.flush()
