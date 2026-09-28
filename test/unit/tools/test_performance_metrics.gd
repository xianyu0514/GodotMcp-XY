extends "res://addons/gut/test.gd"

# get_performance_metrics 口径测试：编辑器进程 vs 游戏进程（runtime probe）。
# 回归背景：2026-09-27 体检 P0-3 —— 该工具曾只返回编辑器进程数据且无口径声明，
# 导致"节点泄漏"误判（编辑器 101,780 对象 vs 游戏真实 2,235）。

const DebugToolsScript = preload("res://addons/godot_mcp/tools/debug_tools_native.gd")

const PROBE_PAYLOAD: Dictionary = {
	"fps": 60.0,
	"frame_time_sec": 0.016,
	"physics_frame_time_sec": 0.008,
	"object_count": 2235,
	"resource_count": 900,
	"rendered_objects_in_frame": 300,
	"memory_static_bytes": 170917376,
	"memory_static_mb": 163.0,
	"current_scene": "/root/Title",
	"node_count": 202
}

# send 后即递增 sequence，让 get_captured_message_after_sequence 在首次提取时就命中。
class FakePerfBridge:
	extends RefCounted

	var message_sequence: int = 0
	var latest_payload: Variant = null
	var send_count: int = 0

	func _init(payload: Variant) -> void:
		latest_payload = payload

	func get_message_sequence() -> int:
		return message_sequence

	func send_debugger_message(_message: String, _data: Array, _session_id: int = -1) -> Dictionary:
		send_count += 1
		message_sequence += 1
		return {"status": "success", "sessions_updated": 1}

	func get_captured_messages(_count: int = 100, _offset: int = 0, _order: String = "desc") -> Dictionary:
		return {"messages": [], "count": 0, "total_available": 0}

	func get_captured_message_after_sequence(sequence: int, response_messages: Array, _error_messages: Array = [], _match_fields: Dictionary = {}) -> Dictionary:
		if latest_payload != null and message_sequence > sequence and response_messages.has("mcp:performance_snapshot"):
			return {"message": "mcp:performance_snapshot", "data": [latest_payload], "sequence": message_sequence}
		return {}

	func get_latest_message_payload(_message: String, _match_fields: Dictionary = {}) -> Variant:
		return latest_payload

class FakeRuntimePlugin:
	extends RefCounted

	var bridge: RefCounted

	func _init(runtime_bridge: RefCounted) -> void:
		bridge = runtime_bridge

	func get_debugger_bridge() -> RefCounted:
		return bridge

func before_each() -> void:
	if Engine.has_meta("GodotMCPPlugin"):
		Engine.remove_meta("GodotMCPPlugin")

func after_each() -> void:
	if Engine.has_meta("GodotMCPPlugin"):
		Engine.remove_meta("GodotMCPPlugin")

func test_editor_source_declares_scope_and_hint():
	var tools: RefCounted = DebugToolsScript.new()
	var result: Dictionary = await tools._tool_get_performance_metrics({"source": "editor"})
	assert_eq(String(result["scope"]), "editor", "显式 editor 必须声明编辑器口径")
	assert_true(result.has("hint"), "编辑器口径必须附游戏进程取数指引")
	assert_true(result.has("fps") and result.has("object_count") and result.has("memory_usage_mb"))

func test_default_source_without_bridge_falls_back_to_editor():
	var tools: RefCounted = DebugToolsScript.new()
	var result: Dictionary = await tools._tool_get_performance_metrics({})
	assert_eq(String(result["scope"]), "editor", "无桥时 auto 应回落编辑器口径")
	assert_true(result.has("hint"))

func test_runtime_source_without_bridge_returns_actionable_error():
	var tools: RefCounted = DebugToolsScript.new()
	var result: Dictionary = await tools._tool_get_performance_metrics({"source": "runtime"})
	assert_true(result.has("error"), "显式 runtime 无会话必须报错而非静默回落")
	assert_true(result.has("recommended_action"), "错误必须携带下一步指引")
	assert_true(str(result["recommended_action"]).contains("run_project"))

func test_runtime_source_with_live_probe_returns_game_scope():
	Engine.set_meta("GodotMCPPlugin", FakeRuntimePlugin.new(FakePerfBridge.new(PROBE_PAYLOAD.duplicate(true))))
	var tools: RefCounted = DebugToolsScript.new()
	var result: Dictionary = await tools._tool_get_performance_metrics({"source": "runtime", "timeout_ms": 500})
	assert_eq(String(result["scope"]), "runtime", "探针存活时应返回游戏进程口径")
	assert_eq(int(result["object_count"]), 2235)
	assert_almost_eq(float(result["memory_usage_mb"]), 163.0, 0.5, "memory_usage_mb 应从探针 memory_static_mb 归一")
	assert_eq(int(result["node_count"]), 202)

func test_auto_source_with_live_probe_prefers_runtime():
	Engine.set_meta("GodotMCPPlugin", FakeRuntimePlugin.new(FakePerfBridge.new(PROBE_PAYLOAD.duplicate(true))))
	var tools: RefCounted = DebugToolsScript.new()
	var result: Dictionary = await tools._tool_get_performance_metrics({"timeout_ms": 500})
	assert_eq(String(result["scope"]), "runtime", "auto 在探针存活时优先游戏进程")
	assert_false(result.has("hint"), "runtime 口径不应带编辑器 hint")

func test_invalid_source_rejected_with_guidance():
	var tools: RefCounted = DebugToolsScript.new()
	var result: Dictionary = await tools._tool_get_performance_metrics({"source": "game"})
	assert_true(result.has("error"))
	assert_true(str(result["error"]).contains("auto"), "错误应说明合法取值")
