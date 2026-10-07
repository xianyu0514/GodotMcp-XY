extends "res://addons/gut/test.gd"

# 结果缓存 formatted payload 回归测试：
#   - 首次执行时同时缓存原始结果与 _format_tool_result 的产物
#   - 缓存命中直接复用 formatted payload（跳过 JSON.stringify / spill 检查），
#     且不重新执行工具 handler
#   - 旧式（仅存 raw value）条目仍可回退到实时格式化路径

const CORE_SCRIPT = preload("res://addons/godot_mcp/native_mcp/mcp_server_core.gd")

var _core = null
var _calls: int = 0


func before_each() -> void:
	_core = CORE_SCRIPT.new()
	_calls = 0


func after_each() -> void:
	_core = null


func _cached_handler(_args: Dictionary) -> Dictionary:
	_calls += 1
	return {"items": ["alpha", "beta", "gamma"], "cached": true}


func _register_cacheable_tool() -> void:
	_core.register_tool(
		"get_scene_structure",
		"Cached scene structure",
		{"type": "object"},
		Callable(self, "_cached_handler"),
		{},
		MCPTypes.MCPTool.create_annotations(true, false, true, false),
		"core",
		"Scene"
	)


func _tool_call_message() -> Dictionary:
	return {
		"jsonrpc": "2.0",
		"id": 1,
		"method": "tools/call",
		"params": {"name": "get_scene_structure", "arguments": {}}
	}


func test_cache_stores_and_reuses_formatted_payload() -> void:
	_register_cacheable_tool()
	var msg: Dictionary = _tool_call_message()
	var first: Dictionary = await _core._handle_tool_call(msg)

	var cache_key: String = "get_scene_structure:" + _core._canonical_json({})
	assert_true(_core._result_cache.has(cache_key), "Successful cacheable read should populate the result cache")
	var entry: Dictionary = _core._result_cache[cache_key]
	assert_true(entry.has("formatted"), "Cache entry should store the formatted response payload")
	assert_true(entry.has("value"), "Cache entry should keep the raw tool result")
	var expected_bytes: int = JSON.stringify(entry["value"]).to_utf8_buffer().size()
	assert_eq(int(entry.get("size_bytes", -1)), expected_bytes,
		"Cache admission reuses the already formatted raw JSON byte count")
	assert_eq(int(_core.get_cache_diagnostics()["result_cache"].get("bytes", -1)), expected_bytes,
		"Diagnostics expose the admitted raw-result byte budget")

	var second: Dictionary = await _core._handle_tool_call(msg)
	assert_eq(_calls, 1, "Cache hit must not re-execute the tool handler")
	assert_same(first["result"], second["result"], "Cache hit should reuse the same formatted payload dictionary")


func test_legacy_raw_cache_entry_falls_back_to_formatting() -> void:
	_register_cacheable_tool()
	var cache_key: String = "get_scene_structure:" + _core._canonical_json({})
	var legacy_value: Dictionary = {"legacy": true}
	_core._result_cache_put(cache_key, legacy_value)

	var response: Dictionary = await _core._handle_tool_call(_tool_call_message())
	assert_eq(_calls, 0, "Legacy raw cache entry should be served without re-executing the handler")
	var text: String = str(response.get("result", {}).get("content", [{}])[0].get("text", ""))
	assert_eq(text, JSON.stringify(legacy_value), "Legacy entry should be formatted on demand")
	assert_false(_core._result_cache[cache_key].has("formatted"), "Fallback formatting should not mutate the legacy cache entry")


func test_format_tool_result_with_size_matches_format_and_bytes() -> void:
	# 单次编码优化契约：with_size 变体返回的 payload 与 _format_tool_result
	# 完全一致，且 size_bytes == 原始结果 JSON 的 UTF-8 字节数（spill 检查与
	# 缓存记账共用同一次 to_utf8_buffer，不再做第二次编码）。
	var tool: MCPTypes.MCPTool = MCPTypes.MCPTool.new()
	tool.name = "bench_tool"
	tool.description = "bench"
	var payload: Dictionary = {"nodes": [{"name": "法阵", "index": 1}, {"name": "N2", "index": 2}]}
	var with_size: Dictionary = _core._format_tool_result_with_size(payload, tool)
	var legacy: Dictionary = _core._format_tool_result(payload, tool)
	assert_eq(with_size["result"], legacy,
		"with_size payload must be identical to the legacy format path")
	var expected_bytes: int = JSON.stringify(payload).to_utf8_buffer().size()
	assert_eq(int(with_size["size_bytes"]), expected_bytes,
		"size_bytes must be the raw result JSON byte count")

	# 非 ASCII（中文）确保按字节而非字符计数。
	var unicode_payload: Dictionary = {"text": "法阵节点".repeat(100)}
	var unicode_result: Dictionary = _core._format_tool_result_with_size(unicode_payload, tool)
	var unicode_expected: int = JSON.stringify(unicode_payload).to_utf8_buffer().size()
	assert_eq(int(unicode_result["size_bytes"]), unicode_expected,
		"Multibyte content must count UTF-8 bytes, not characters")


func test_format_tool_result_with_size_reports_spilled_original_size() -> void:
	# 超过内联上限时走 spill：size_bytes 仍必须是"原始完整载荷"的字节数
	# （与 resource_link.size 一致），而不是截断预览的大小。
	var tool: MCPTypes.MCPTool = MCPTypes.MCPTool.new()
	tool.name = "bench_spill_tool"
	tool.description = "bench"
	var payload: Dictionary = {"blob": "x".repeat(60000)}
	var with_size: Dictionary = _core._format_tool_result_with_size(payload, tool)
	var expected_bytes: int = JSON.stringify(payload).to_utf8_buffer().size()
	assert_gt(expected_bytes, _core.MAX_INLINE_RESULT_BYTES,
		"Precondition: payload exceeds the inline limit")
	assert_eq(int(with_size["size_bytes"]), expected_bytes,
		"Spilled results must account the complete original payload size")
	var content: Array = with_size["result"]["content"]
	var link: Dictionary = {}
	for block_value in content:
		if block_value is Dictionary and String(block_value.get("type", "")) == "resource_link":
			link = block_value
			break
	assert_eq(int(link.get("size", -1)), expected_bytes,
		"resource_link.size must match the reported size_bytes")
	# 清理 spill 落盘文件
	var sha: String = _core._hash_bytes(JSON.stringify(payload).to_utf8_buffer())
	var spill_path: String = _core.SPILL_OUTPUT_DIR + "/" + sha + ".json"
	if FileAccess.file_exists(spill_path):
		DirAccess.remove_absolute(spill_path)
