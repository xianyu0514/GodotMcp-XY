extends "res://addons/gut/test.gd"

# 错误自愈分发层模式表回归测试（2026-10-03 台账 S12）：
# 全部工具的 {"error": ...} 返回按消息短语匹配附加 next_step，
# 调用方一次往返拿到"发生了什么 + 下一步做什么"。

const CORE_SCRIPT = preload("res://addons/godot_mcp/native_mcp/mcp_server_core.gd")

var _core = null


func before_each() -> void:
	_core = CORE_SCRIPT.new()


func after_each() -> void:
	_core = null


func test_node_not_found_suggests_scene_tree_verification() -> void:
	var result: Dictionary = {"error": "Node not found: /root/Main/Player"}
	_core._append_error_recovery_hint(result)
	assert_true(result.has("next_step"), "Node-not-found must carry a next step")
	assert_true(String(result["next_step"]).contains("get_scene_tree"),
		"Hint must name the discovery tool for node paths")


func test_no_scene_open_suggests_open_scene() -> void:
	var result: Dictionary = {"error": "No scene is currently open"}
	_core._append_error_recovery_hint(result)
	assert_true(String(result["next_step"]).contains("open_scene"),
		"No-scene error must point at open_scene")


func test_debugger_bridge_suggests_run_project_then_probe() -> void:
	var result: Dictionary = {"error": "Debugger bridge is not available"}
	_core._append_error_recovery_hint(result)
	var step: String = String(result["next_step"])
	assert_true(step.contains("run_project"), "Hint must start the game")
	assert_true(step.contains("install_runtime_probe"), "Hint must install the probe")


func test_editor_interface_unavailable_explains_headless_limit() -> void:
	var result: Dictionary = {"error": "Editor interface not available"}
	_core._append_error_recovery_hint(result)
	assert_true(String(result["next_step"]).contains("headless"),
		"Hint must explain the headless/CLI limitation")


func test_file_not_found_suggests_resource_listing() -> void:
	var result: Dictionary = {"error": "File not found: res://data/missing.json"}
	_core._append_error_recovery_hint(result)
	assert_true(String(result["next_step"]).contains("list_project_resources"),
		"File-not-found must name the discovery tool")


func test_handler_provided_next_step_wins() -> void:
	var result: Dictionary = {"error": "Node not found: /root/X", "next_step": "use the custom hint"}
	_core._append_error_recovery_hint(result)
	assert_eq(String(result["next_step"]), "use the custom hint",
		"Handler-authored hints must never be overwritten")


func test_unmatched_error_stays_untouched() -> void:
	var result: Dictionary = {"error": "Missing required parameter: node_path"}
	_core._append_error_recovery_hint(result)
	assert_false(result.has("next_step"),
		"Parameter errors are self-explanatory; no hint added")
	var non_dict: Variant = "not a dict"
	_core._append_error_recovery_hint(non_dict)


func test_pipeline_error_response_embeds_next_step_with_is_error() -> void:
	# 管线级：假 handler 返回错误字典，完整分发后响应 JSON 含 next_step 且 isError。
	_core.register_tool(
		"bench_node_reader",
		"fake node reader for recovery test",
		{"type": "object"},
		func(_args: Dictionary) -> Dictionary: return {"error": "Node not found: /root/Missing"},
		{}, MCPTypes.MCPTool.create_annotations(true, false, true, false),
		"core", "Node")
	var response: Dictionary = await _core._handle_tool_call({
		"jsonrpc": "2.0", "id": 7, "method": "tools/call",
		"params": {"name": "bench_node_reader", "arguments": {}}})
	assert_true(bool(response["result"]["isError"]), "Error path must set isError")
	var text: String = String(response["result"]["content"][0]["text"])
	var parsed: Dictionary = JSON.parse_string(text)
	assert_true(parsed is Dictionary and parsed.has("next_step"),
		"Full pipeline error response must embed next_step")
