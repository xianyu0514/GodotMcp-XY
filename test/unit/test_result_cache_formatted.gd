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
