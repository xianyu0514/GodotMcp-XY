extends "res://addons/gut/test.gd"

# 长任务超时对齐（2026-10-03 English Rift 台账 E-6）回归测试：
# 客户端 30s 超时 vs 任务 53s 完成 → 误判超时重发。长任务工具的成功响应
# 必须携带 long_running 元信息（预期时长 + "静默不代表失败"提示），
# 调用方第一次调用后就学会设长超时或轮询，而不是重复发起。

const CORE_SCRIPT = preload("res://addons/godot_mcp/native_mcp/mcp_server_core.gd")

var _core = null


func before_each() -> void:
	_core = CORE_SCRIPT.new()


func after_each() -> void:
	_core = null


func test_hint_attaches_expected_seconds_and_reassuring_note() -> void:
	var result: Dictionary = {"status": "ok"}
	_core._append_long_running_hint(result, "audit_project_health")
	assert_true(result.has("long_running"), "Hinted tool must carry long_running")
	assert_eq(int(result["long_running"]["expected_seconds"]), 30)
	assert_true(String(result["long_running"]["note"]).contains("may still have completed server-side"),
		"Note must tell the caller a timed-out run may still have completed")


func test_hint_is_idempotent_and_skips_errors_and_unlisted_tools() -> void:
	# handler 自己给了 long_running → 不覆盖
	var owned: Dictionary = {"status": "ok", "long_running": {"expected_seconds": 999}}
	_core._append_long_running_hint(owned, "audit_project_health")
	assert_eq(int(owned["long_running"]["expected_seconds"]), 999,
		"Handler-provided values must win")

	# 错误结果不附加（失败路径没有"它还在跑"的语义）
	var errored: Dictionary = {"error": "boom"}
	_core._append_long_running_hint(errored, "audit_project_health")
	assert_false(errored.has("long_running"), "Error results must not carry the hint")

	# 名单外工具不附加
	var quick: Dictionary = {"status": "ok"}
	_core._append_long_running_hint(quick, "bench_noop")
	assert_false(quick.has("long_running"), "Unlisted tools stay untouched")


func test_handle_tool_call_pipeline_attaches_hint_end_to_end() -> void:
	# 管线级：注册真名（reimport_resources）的假 handler，走完整分发，
	# 响应 JSON 必须已包含 long_running —— 调用方无需任何额外开关。
	_core.register_tool(
		"reimport_resources",
		"fake reimport for hint pipeline test",
		{"type": "object"},
		func(_args: Dictionary) -> Dictionary: return {"status": "reimported"},
		{}, MCPTypes.MCPTool.create_annotations(false, true, true, false),
		"supplementary", "Project-Advanced")
	_core.set_tool_enabled("reimport_resources", true)

	var response: Dictionary = await _core._handle_tool_call({
		"jsonrpc": "2.0", "id": 1, "method": "tools/call",
		"params": {"name": "reimport_resources", "arguments": {}}})
	var text: String = String(response["result"]["content"][0]["text"])
	var parsed: Dictionary = JSON.parse_string(text)
	assert_true(parsed is Dictionary and parsed.has("long_running"),
		"Full pipeline response must embed the long_running block")
	assert_eq(int(parsed["long_running"]["expected_seconds"]), 120)
