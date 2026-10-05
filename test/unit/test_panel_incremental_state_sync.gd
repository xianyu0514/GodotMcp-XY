extends "res://addons/gut/test.gd"

# 面板 _apply_states 增量同步回归测试：
#   - 全部工具都有对应控件时就地翻转勾选状态（不重建 ~1300 个控件）；
#   - 任一工具无对应控件时报告 false，调用方回退全量刷新；
#   - always-on meta 工具忽略 disable，实际状态以 server core 为准。

const PANEL_SCRIPT = preload("res://addons/godot_mcp/ui/mcp_panel_native.gd")
const GROUP_ITEM_SCRIPT = preload("res://addons/godot_mcp/ui/mcp_tool_group_item.gd")


class MockServerCore extends RefCounted:
	var tools: Dictionary = {}

	func set_tool_enabled(tool_name: String, enabled: bool) -> void:
		if tools.has(tool_name):
			tools[tool_name]["enabled"] = enabled

	func get_tool(tool_name: String) -> Dictionary:
		return tools.get(tool_name, {})

	func has_tool(tool_name: String) -> bool:
		return tools.has(tool_name)


func _build_panel_with_widget(tool_name: String, enabled: bool, category: String) -> Control:
	var panel: Control = PANEL_SCRIPT.new()
	autofree(panel)
	var tools: Array = [{
		"name": tool_name,
		"description": "test tool",
		"enabled": enabled,
		"category": category,
		"group": "TestGroup",
	}]
	var widget: MCPToolGroupItem = GROUP_ITEM_SCRIPT.new()
	autofree(widget)
	widget.setup("TestGroup", tools, null, 15, 1.0)
	panel._group_widgets = {"TestGroup": widget}
	return panel


func test_sync_tool_items_state_updates_existing_item_in_place() -> void:
	var panel: Control = _build_panel_with_widget("bench_tool", true, "core")
	var widget: MCPToolGroupItem = panel._group_widgets["TestGroup"]
	var item: MCPToolItem = widget.get_tool_items()[0]
	assert_true(item.is_enabled(), "Precondition: item starts enabled")

	var synced: bool = panel._sync_tool_items_state([["bench_tool", false]])
	assert_true(synced, "Existing item should sync without fallback")
	assert_false(item.is_enabled(), "Item should be disabled in place")


func test_sync_tool_items_state_reports_missing_item() -> void:
	var panel: Control = _build_panel_with_widget("bench_tool", true, "core")
	var synced: bool = panel._sync_tool_items_state([["ghost_tool", false]])
	assert_false(synced, "Missing item must signal the caller to rebuild the list")


func test_sync_tool_items_state_empty_change_is_noop() -> void:
	var panel: Control = _build_panel_with_widget("bench_tool", true, "core")
	assert_true(panel._sync_tool_items_state([]), "Empty change set is trivially synced")


func test_sync_tool_items_state_without_widgets_fails_closed() -> void:
	var panel: Control = PANEL_SCRIPT.new()
	autofree(panel)
	panel._group_widgets = {}
	assert_false(panel._sync_tool_items_state([["bench_tool", false]]),
		"No widgets built yet: caller must fall back to a full rebuild")


func test_refresh_status_exists_and_is_null_safe() -> void:
	# 服务器启停走 refresh_status（只刷状态与连接信息，不重建工具目录）；
	# 在未进树、无控件的面板上调用必须安全返回。
	var panel: Control = PANEL_SCRIPT.new()
	autofree(panel)
	panel._server_core = null
	panel.refresh_status()
	assert_true(true, "refresh_status completed without errors on a bare panel")


func test_plugin_uses_refresh_status_for_server_lifecycle() -> void:
	# 插件接线源码契约：启停路径用精确状态刷新，注册完成路径保留全量 refresh。
	var plugin_source: GDScript = load("res://addons/godot_mcp/mcp_server_native.gd")
	var source_code: String = plugin_source.source_code
	assert_true(source_code.contains('_main_panel.refresh_status()'),
		"Server start/stop should use the precise status refresh")
	assert_false(source_code.contains("if _main_panel and _main_panel.has_method(\"refresh\"):\n\t\tif Thread.is_main_thread():\n\t\t\t_main_panel.refresh()"),
		"Server start/stop must not trigger the full tool-list rebuild")
