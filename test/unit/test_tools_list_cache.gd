extends "res://addons/gut/test.gd"

# tools/list 服务端缓存回归测试：
#   - 重复请求复用同一个已排序数组（不重复构建 schema Dictionary）
#   - 注册 / 注销 / 启用状态 / 分组启停都会使缓存失效并反映在下一轮结果中

const CORE_SCRIPT = preload("res://addons/godot_mcp/native_mcp/mcp_server_core.gd")

var _core = null


func before_each() -> void:
	_core = CORE_SCRIPT.new()


func after_each() -> void:
	_core = null


func _register(name: String, category: String = "core", group: String = "") -> void:
	_core.register_tool(
		name,
		"Test tool " + name,
		{"type": "object"},
		func(_args): return {"status": "ok"},
		{},
		{},
		category,
		group
	)


func _tool_names(response: Dictionary) -> Array[String]:
	var names: Array[String] = []
	for entry in response.get("result", {}).get("tools", []):
		names.append(str(entry.get("name", "")))
	return names


func test_tools_list_empty_before_registration() -> void:
	var response: Dictionary = _core._handle_tools_list({"id": 1, "method": "tools/list"})
	assert_eq(response.get("result", {}).get("tools", []).size(), 0, "Empty registry should produce an empty tools list")


func test_tools_list_reuses_sorted_cache() -> void:
	_register("zeta_tool")
	_register("alpha_tool")
	var first: Dictionary = _core._handle_tools_list({"id": 1, "method": "tools/list"})
	var second: Dictionary = _core._handle_tools_list({"id": 2, "method": "tools/list"})

	var first_tools: Array = first.get("result", {}).get("tools", [])
	var second_tools: Array = second.get("result", {}).get("tools", [])
	assert_eq(_tool_names(first), ["alpha_tool", "zeta_tool"], "tools/list must be sorted deterministically by name")
	assert_same(first_tools, second_tools, "Unchanged tools/list must reuse the cached payload array")


func test_register_invalidates_cache() -> void:
	_register("alpha_tool")
	var first: Dictionary = _core._handle_tools_list({"id": 1, "method": "tools/list"})
	_register("beta_tool")
	var second: Dictionary = _core._handle_tools_list({"id": 2, "method": "tools/list"})

	assert_eq(_tool_names(second), ["alpha_tool", "beta_tool"], "Newly registered tool must appear after cache invalidation")
	assert_ne(first.get("result", {}).get("tools", []).size(), second.get("result", {}).get("tools", []).size(),
		"Registering a tool must rebuild the tools/list payload")


func test_unregister_invalidates_cache() -> void:
	_register("alpha_tool")
	_register("beta_tool")
	var first: Dictionary = _core._handle_tools_list({"id": 1, "method": "tools/list"})
	_core.unregister_tool("beta_tool")
	var second: Dictionary = _core._handle_tools_list({"id": 2, "method": "tools/list"})

	assert_eq(_tool_names(second), ["alpha_tool"], "Unregistered tool must disappear after cache invalidation")


func test_set_tool_enabled_invalidates_cache() -> void:
	_register("alpha_tool")
	var first: Dictionary = _core._handle_tools_list({"id": 1, "method": "tools/list"})
	_core.set_tool_enabled("alpha_tool", false)
	var second: Dictionary = _core._handle_tools_list({"id": 2, "method": "tools/list"})

	assert_eq(_tool_names(first), ["alpha_tool"], "Enabled core tool should be listed before disabling")
	assert_eq(_tool_names(second), [], "Disabled tool must disappear from tools/list after cache invalidation")


func test_set_group_enabled_invalidates_cache() -> void:
	# 使用 manifest/classifier 中真实存在的工具名，set_group_enabled 依赖
	# classifier.get_group_tools() 查询分组。
	_register("reload_project", "supplementary", "Editor-Advanced")
	var first: Dictionary = _core._handle_tools_list({"id": 1, "method": "tools/list"})
	_core.set_group_enabled("Editor-Advanced", true)
	var second: Dictionary = _core._handle_tools_list({"id": 2, "method": "tools/list"})

	assert_eq(_tool_names(first), [], "Supplementary tool is disabled by default")
	assert_eq(_tool_names(second), ["reload_project"], "Enabling its group must rebuild and include the supplementary tool")
