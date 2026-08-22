extends "res://addons/gut/test.gd"

# 元工具发现链路的结果缓存回归测试：
#   - list_tool_catalog / search_tools / get_tool_details 属于只读发现工具，
#     应进入通用结果缓存（重复查询不重复扫描完整注册表）
#   - 工具启用状态 / 注册表变化必须使这些缓存失效，避免 catalog 返回过期 enabled

const CORE_SCRIPT = preload("res://addons/godot_mcp/native_mcp/mcp_server_core.gd")

var _core = null
var _catalog_calls: int = 0


func before_each() -> void:
	_core = CORE_SCRIPT.new()
	_catalog_calls = 0


func after_each() -> void:
	_core = null


func _catalog_handler(_args: Dictionary) -> Dictionary:
	_catalog_calls += 1
	return {"total_matched": 223, "calls": _catalog_calls}


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


func _catalog_msg() -> Dictionary:
	return {
		"jsonrpc": "2.0",
		"id": 1,
		"method": "tools/call",
		"params": {"name": "list_tool_catalog", "arguments": {}}
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
