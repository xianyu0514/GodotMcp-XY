extends "res://addons/gut/test.gd"

# 投递确认（输入模拟证据链往返层）单元测试：
# - _simulate_delivery_state 的判定语义（新鲜成功 + 回读一致才算 confirmed）
# - _purge_runtime_probe_request 强制重发
# - _tool_simulate_runtime_input_action 的重发与带证据失败（不静默假完成）
# 场景对应代表游戏 08/10 轮换根因：释放命令应答丢失 → 陈旧回退错配成
# 按下应答 → 残留按住态 → 反向键抵消 → 零位移。

const DebugToolsScript = preload("res://addons/godot_mcp/tools/debug_tools_native.gd")
const DebugRuntimeToolsScript = preload("res://addons/godot_mcp/tools/debug_runtime_tools.gd")

class FakeInputBridge:
	extends RefCounted

	var send_count: int = 0
	var message_sequence: int = 0
	# 已揭示的新鲜应答（sequence 之后可见）；与陈旧缓存分离。
	var fresh_ack: Dictionary = {}
	# 陈旧缓存：get_latest_message_payload 的回退数据源。
	var stale_cache: Variant = null
	# 揭示计划：send_count 达到该值时揭示新鲜应答（0 = 从不揭示，
	# 用于"命令/应答丢失"场景；每次发送都会重新检查，覆盖持续矛盾）。
	var reveal_on_send: int = 0
	var reveal_pressed: bool = false
	var reveal_runtime_pressed: bool = false

	func get_message_sequence() -> int:
		return message_sequence

	func send_debugger_message(message: String, data: Array, session_id: int = -1) -> Dictionary:
		send_count += 1
		if reveal_on_send > 0 and send_count >= reveal_on_send and not data.is_empty():
			reveal_ack(str(data[0]), reveal_pressed, reveal_runtime_pressed)
		return {"status": "success", "sessions_updated": 1}

	func get_captured_messages(_count: int = 100, _offset: int = 0, _order: String = "desc") -> Dictionary:
		return {"messages": [], "count": 0, "total_available": 0}

	func _payload_matches(payload: Dictionary, match_fields: Dictionary) -> bool:
		for key in match_fields:
			if payload.get(key, null) != match_fields[key]:
				return false
		return true

	func get_captured_message_after_sequence(sequence: int, response_messages: Array, _error_messages: Array = [], match_fields: Dictionary = {}) -> Dictionary:
		if fresh_ack.is_empty() or message_sequence <= sequence:
			return {}
		if not response_messages.has(String(fresh_ack.get("_message", ""))):
			return {}
		if not _payload_matches(fresh_ack, match_fields):
			return {}
		return {"message": fresh_ack["_message"], "data": [fresh_ack.duplicate(true)], "sequence": message_sequence}

	func get_latest_message_payload(message: String, match_fields: Dictionary = {}) -> Variant:
		if stale_cache == null:
			return null
		if stale_cache is Dictionary:
			var cached: Dictionary = stale_cache
			var cached_message: String = String(cached.get("_message", message))
			if cached_message != message or not _payload_matches(cached, match_fields):
				return null
		return stale_cache

	func reveal_ack(action_name: String, pressed: bool, runtime_pressed: bool) -> void:
		message_sequence += 1
		fresh_ack = {
			"_message": "mcp:input_action_simulated",
			"action_name": action_name,
			"action_exists": true,
			"pressed": pressed,
			"strength": 1.0 if pressed else 0.0,
			"runtime_pressed": runtime_pressed,
		}

class FakeRuntimePlugin:
	extends RefCounted

	var bridge: RefCounted

	func _init(runtime_bridge: RefCounted) -> void:
		bridge = runtime_bridge

	func get_debugger_bridge() -> RefCounted:
		return bridge

var _bridge: FakeInputBridge

func before_each() -> void:
	_bridge = FakeInputBridge.new()
	Engine.set_meta("GodotMCPPlugin", FakeRuntimePlugin.new(_bridge))

func after_each() -> void:
	Engine.remove_meta("GodotMCPPlugin")
	_bridge = null

# --- _simulate_delivery_state 判定语义 --------------------------------------

func test_delivery_state_confirmed_on_fresh_match():
	var verdict: String = DebugRuntimeToolsScript._simulate_delivery_state(
		{"status": "success", "runtime_pressed": false}, false)
	assert_eq(verdict, "confirmed", "fresh success with matching readback is confirmed")

func test_delivery_state_stale_ack_is_not_confirmed():
	var verdict: String = DebugRuntimeToolsScript._simulate_delivery_state(
		{"status": "success", "stale": true, "runtime_pressed": false}, false)
	assert_eq(verdict, "stale", "stale cache fallback must not count as delivered")

func test_delivery_state_fresh_mismatch_is_retryable():
	var verdict: String = DebugRuntimeToolsScript._simulate_delivery_state(
		{"status": "success", "runtime_pressed": true}, false)
	assert_eq(verdict, "mismatch", "fresh ack contradicting the request is a mismatch")

func test_delivery_state_missing_readback_defaults_to_mismatch():
	var verdict: String = DebugRuntimeToolsScript._simulate_delivery_state(
		{"status": "success"}, true)
	assert_eq(verdict, "mismatch", "missing runtime_pressed is never treated as delivered")

func test_delivery_state_non_success_is_unconfirmed():
	for status in ["timeout", "pending", "no_active_sessions"]:
		var verdict: String = DebugRuntimeToolsScript._simulate_delivery_state(
			{"status": status}, true)
		assert_eq(verdict, "unconfirmed", "%s must not count as delivered" % status)

# --- 正常路径：新鲜应答一次确认 ----------------------------------------------

func test_simulate_press_confirms_in_one_attempt():
	var tools: RefCounted = DebugRuntimeToolsScript.new()
	_bridge.reveal_on_send = 1
	_bridge.reveal_pressed = true
	_bridge.reveal_runtime_pressed = true
	var result: Dictionary = await tools._tool_simulate_runtime_input_action(
		{"action_name": "move_right", "pressed": true, "timeout_ms": 400})
	assert_eq(result.get("status"), "success", "press resolves with fresh success")
	assert_eq(bool(result.get("delivery_confirmed")), true, "delivery is confirmed")
	assert_eq(int(result.get("delivery_attempts")), 1, "no resend needed on the happy path")
	assert_eq(_bridge.send_count, 1, "exactly one probe command dispatched")

# --- 根因场景：释放应答丢失 + 陈旧按下缓存 → 清缓存重发后确认 ------------------

func test_release_recovers_after_lost_ack_and_stale_press_cache():
	var tools: RefCounted = DebugRuntimeToolsScript.new()
	# 陈旧缓存里只有旧按下应答（pressed:true），与本次释放请求方向相反——
	# match 带 pressed 使陈旧回退无法错配，轮询超时后由投递确认重发。
	_bridge.stale_cache = {
		"_message": "mcp:input_action_simulated",
		"action_name": "move_right",
		"action_exists": true,
		"pressed": true,
		"strength": 1.0,
		"runtime_pressed": true,
	}
	# 第一次发送不揭示（命令丢失）；第二次发送（重发）揭示新鲜释放应答。
	_bridge.reveal_on_send = 2
	_bridge.reveal_pressed = false
	_bridge.reveal_runtime_pressed = false
	var result: Dictionary = await tools._tool_simulate_runtime_input_action(
		{"action_name": "move_right", "pressed": false, "timeout_ms": 300})
	assert_eq(result.get("status"), "success", "release resolves after resend")
	assert_eq(bool(result.get("delivery_confirmed")), true, "delivery confirmed after recovery")
	assert_eq(int(result.get("delivery_attempts")), 2, "one resend recovered the lost command")
	assert_eq(_bridge.send_count, 2, "initial send + one resend")

# --- 持续矛盾应答：三次后带证据失败（不静默假完成） ----------------------------

func test_persistent_contradiction_fails_loudly_with_evidence():
	var tools: RefCounted = DebugRuntimeToolsScript.new()
	# 每次发送都揭示"新鲜但矛盾"的应答：请求释放、回读仍是按下。
	_bridge.reveal_on_send = 1
	_bridge.reveal_pressed = false
	_bridge.reveal_runtime_pressed = true
	var result: Dictionary = await tools._tool_simulate_runtime_input_action(
		{"action_name": "move_right", "pressed": false, "timeout_ms": 400})
	assert_true(result.has("error"), "persistent contradiction must surface an error")
	var message: String = str(result.get("error", ""))
	assert_string_contains(message, "delivery unconfirmed", "error names the delivery failure")
	assert_string_contains(message, "runtime_pressed", "error carries the readback evidence")
	assert_eq(_bridge.send_count, 3, "initial + two resends before giving up")

# --- 完全丢失（无应答无缓存）：带证据失败 --------------------------------------

func test_total_loss_fails_loudly_after_retries():
	var tools: RefCounted = DebugRuntimeToolsScript.new()
	# 从不揭示，也没有陈旧缓存：三轮全部超时。
	var result: Dictionary = await tools._tool_simulate_runtime_input_action(
		{"action_name": "move_up", "pressed": true, "timeout_ms": 200})
	assert_true(result.has("error"), "total delivery loss must surface an error")
	assert_string_contains(str(result.get("error", "")), "delivery unconfirmed")
	assert_eq(_bridge.send_count, 3, "initial + two resends before giving up")

# --- _purge_runtime_probe_request 强制重发 -----------------------------------

func test_purge_forces_fresh_dispatch():
	var command: String = "purge_probe_test_cmd"
	var payload: Array = ["move_right", false, 0.0]
	var messages: Array = ["mcp:input_action_simulated"]
	var match_fields: Dictionary = {"action_name": "move_right", "pressed": false}
	var params: Dictionary = {"timeout_ms": 5000}
	var first: Dictionary = DebugToolsScript._request_runtime_probe(command, payload, messages, params, match_fields)
	assert_eq(first.get("status"), "pending", "no ack yet: request stays pending")
	assert_eq(_bridge.send_count, 1, "first call dispatches once")
	# 未清除挂起缓存时：超时窗口内复用同一条挂起命令，不重发。
	var second: Dictionary = DebugToolsScript._request_runtime_probe(command, payload, messages, params, match_fields, false)
	assert_eq(second.get("status"), "pending")
	assert_eq(_bridge.send_count, 1, "poll reuses the pending entry without re-sending")
	# 清除后：下一次调用重新派发。
	DebugToolsScript._purge_runtime_probe_request(command, payload, messages, params, match_fields)
	var third: Dictionary = DebugToolsScript._request_runtime_probe(command, payload, messages, params, match_fields)
	assert_eq(third.get("status"), "pending")
	assert_eq(_bridge.send_count, 2, "purged request dispatches a fresh probe")

# --- 工具入口参数校验 ---------------------------------------------------------

func test_simulate_requires_action_name():
	var tools: RefCounted = DebugRuntimeToolsScript.new()
	var result: Dictionary = await tools._tool_simulate_runtime_input_action({"pressed": true})
	assert_true(result.has("error"), "empty action_name is rejected")
