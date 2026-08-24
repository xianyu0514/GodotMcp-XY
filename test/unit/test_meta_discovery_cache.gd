extends "res://addons/gut/test.gd"

# 元工具发现链路的结果缓存回归测试：
#   - list_tool_catalog / search_tools / get_tool_details 属于只读发现工具，
#     应进入通用结果缓存（重复查询不重复扫描 221 个注册条目）
#   - 工具启用状态 / 注册表变化必须使这些缓存失效，避免 catalog 返回过期 enabled

const CORE_SCRIPT = preload("res://addons/godot_mcp/native_mcp/mcp_server_core.gd")

var _core = null
var _catalog_calls: int = 0
var _project_read_calls: int = 0


func before_each() -> void:
	_core = CORE_SCRIPT.new()
	_catalog_calls = 0
	_project_read_calls = 0


func after_each() -> void:
	_core = null


func _catalog_handler(_args: Dictionary) -> Dictionary:
	_catalog_calls += 1
	return {"total_matched": 221, "calls": _catalog_calls}


func _project_read_handler(_args: Dictionary) -> Dictionary:
	_project_read_calls += 1
	return {"files": 42, "calls": _project_read_calls}


func _enable_handler(_args: Dictionary) -> Dictionary:
	_core.set_tool_enabled("toggle_tool", false)
	return {"status": "success"}


func _register_discovery_tools() -> void:
	_core.register_tool(
		"list_tool_catalog",
		"List the tool catalog",
		{"type": "object"},
		Callable(self, "_catalog_handler"),
		{},
		MCPTypes.MCPTool.create_annotations(true, false, true, false),
		"meta",
		"Meta"
	)
	_core.register_tool(
		"toggle_tool",
		"Toggleable tool",
		{"type": "object"},
		func(_args): return {"ok": true},
		{},
		MCPTypes.MCPTool.create_annotations(false, false, false, false),
		"core",
		"Editor"
	)
	_core.register_tool(
		"get_project_structure",
		"Read project structure",
		{"type": "object"},
		Callable(self, "_project_read_handler"),
		{},
		MCPTypes.MCPTool.create_annotations(true, false, true, false),
		"core",
		"Project"
	)


func _catalog_msg() -> Dictionary:
	return {
		"jsonrpc": "2.0",
		"id": 1,
		"method": "tools/call",
		"params": {"name": "list_tool_catalog", "arguments": {}}
	}


func _project_read_msg() -> Dictionary:
	return {
		"jsonrpc": "2.0",
		"id": 2,
		"method": "tools/call",
		"params": {"name": "get_project_structure", "arguments": {}}
	}


func test_meta_discovery_tools_are_cacheable_reads() -> void:
	for tool_name in ["list_tool_catalog", "search_tools", "get_tool_details"]:
		assert_true(tool_name in _core.CACHEABLE_READ_TOOLS,
			"%s must be a cacheable read so repeated discovery does not rescan all tools" % tool_name)


func test_catalog_served_from_cache_until_enable_state_change() -> void:
	_register_discovery_tools()
	var msg: Dictionary = _catalog_msg()

	var first: Dictionary = await _core._handle_tool_call(msg)
	var second: Dictionary = await _core._handle_tool_call(msg)
	assert_eq(_catalog_calls, 1, "Identical catalog calls must share one result-cache entry")
	assert_same(first["result"], second["result"], "Cached catalog should reuse the formatted payload")

	_core.set_tool_enabled("toggle_tool", false)
	var third: Dictionary = await _core._handle_tool_call(msg)
	assert_eq(_catalog_calls, 2, "Enable-state changes must invalidate cached catalog entries")
	assert_false(third["result"] is Dictionary and third["result"].has("error"), "Recomputed catalog should succeed")


func test_catalog_served_from_cache_until_unregister() -> void:
	_register_discovery_tools()
	var msg: Dictionary = _catalog_msg()

	await _core._handle_tool_call(msg)
	await _core._handle_tool_call(msg)
	assert_eq(_catalog_calls, 1, "Identical catalog calls must share one result-cache entry")

	_core.unregister_tool("toggle_tool")
	await _core._handle_tool_call(msg)
	assert_eq(_catalog_calls, 2, "Unregistering a tool must invalidate cached catalog entries")


func test_enable_state_change_preserves_unrelated_project_read_cache() -> void:
	_register_discovery_tools()
	await _core._handle_tool_call(_catalog_msg())
	await _core._handle_tool_call(_project_read_msg())
	await _core._handle_tool_call(_project_read_msg())
	assert_eq(_project_read_calls, 1, "Project read should be cached before the tool-state change")

	_core.set_tool_enabled("toggle_tool", false)
	await _core._handle_tool_call(_catalog_msg())
	await _core._handle_tool_call(_project_read_msg())
	assert_eq(_catalog_calls, 2, "Tool-state changes still invalidate discovery results")
	assert_eq(_project_read_calls, 1, "Tool-state changes must preserve unrelated project read cache entries")


func test_noop_tool_state_change_preserves_cache_generation() -> void:
	_register_discovery_tools()
	var generation_before: int = _core._cache_generation
	_core.set_tool_enabled("toggle_tool", true)
	assert_eq(_core._cache_generation, generation_before,
		"Setting an already-enabled tool must not invalidate any cache")


func test_bulk_tool_state_change_invalidates_once() -> void:
	_register_discovery_tools()
	_core.register_tool("extra_toggle", "Extra toggle", {"type": "object"},
		func(_args): return {"ok": true}, {}, {}, "supplementary", "Debug-Advanced")
	var generation_before: int = _core._cache_generation
	var result: Dictionary = _core.apply_tool_states({
		"toggle_tool": false,
		"extra_toggle": true
	})
	assert_eq(result.get("changed_count", -1), 2, "Both state changes should be applied")
	assert_eq(_core._cache_generation, generation_before + 1,
		"A bulk transition must invalidate discovery cache exactly once")


func test_enable_tools_control_plane_call_preserves_project_read_cache() -> void:
	_register_discovery_tools()
	_core.register_tool("enable_tools", "Enable tools", {"type": "object"},
		Callable(self, "_enable_handler"), {},
		MCPTypes.MCPTool.create_annotations(false, false, false, false), "meta", "Meta")
	await _core._handle_tool_call(_project_read_msg())
	await _core._handle_tool_call(_project_read_msg())
	var enable_msg: Dictionary = {
		"jsonrpc": "2.0",
		"id": 3,
		"method": "tools/call",
		"params": {"name": "enable_tools", "arguments": {}}
	}
	await _core._handle_tool_call(enable_msg)
	await _core._handle_tool_call(_project_read_msg())
	assert_eq(_project_read_calls, 1,
		"enable_tools changes catalog state only and must keep project read entries hot")
