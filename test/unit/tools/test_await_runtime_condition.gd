extends "res://addons/gut/test.gd"

# await_runtime_condition 的等待语义回归：
# 首版实现在拿到"新鲜但为假"的求值后立即返回 failed（名为 await 实为单次采样），
# 迫使所有调用方外层手写重试循环。first-playable 冒烟实测：按下移动键后 28ms
# 即放弃，而玩家 300ms 后确实在移动。本测试钉死：条件在超时窗口内变真 → 成功；
# 全程为假 → 超时失败（诚实失败，不提前放弃）。

const TOOL_SCRIPT: String = "res://addons/godot_mcp/tools/debug_runtime_tools.gd"

class FalseThenTrueHarness extends "res://addons/godot_mcp/tools/debug_runtime_tools.gd":
	var evaluations: int = 0
	var turn_true_after: int = 3
	func _tool_evaluate_runtime_expression(_params: Dictionary) -> Dictionary:
		evaluations += 1
		var value: bool = evaluations >= turn_true_after
		return {
			"status": "success",
			"stale": false,
			"value": value,
			"refresh_result": {"status": "success"}
		}

class AlwaysFalseHarness extends "res://addons/godot_mcp/tools/debug_runtime_tools.gd":
	var evaluations: int = 0
	func _tool_evaluate_runtime_expression(_params: Dictionary) -> Dictionary:
		evaluations += 1
		return {
			"status": "success",
			"stale": false,
			"value": false,
			"refresh_result": {"status": "success"}
		}

class AlwaysStaleHarness extends "res://addons/godot_mcp/tools/debug_runtime_tools.gd":
	func _tool_evaluate_runtime_expression(_params: Dictionary) -> Dictionary:
		return {
			"status": "success",
			"stale": true,
			"value": false,
			"refresh_result": {"status": "success"}
		}

func test_await_waits_until_condition_turns_true() -> void:
	var harness: FalseThenTrueHarness = FalseThenTrueHarness.new()
	var result: Dictionary = await harness._tool_await_runtime_condition({
		"expression": "player_moving", "timeout_ms": 3000, "poll_interval_ms": 50})
	assert_eq(result.get("status"), "success", "Condition turning true within the window must succeed")
	assert_eq(result.get("condition_met"), true)
	assert_eq(harness.evaluations, 3, "Must re-evaluate after fresh-false samples instead of giving up")

func test_await_times_out_honestly_when_never_true() -> void:
	var harness: AlwaysFalseHarness = AlwaysFalseHarness.new()
	var result: Dictionary = await harness._tool_await_runtime_condition({
		"expression": "never_true", "timeout_ms": 250, "poll_interval_ms": 50})
	assert_eq(result.get("status"), "failed", "Never-true condition must fail")
	assert_eq(result.get("condition_met"), false)
	assert_true(result.has("error"), "Timeout must carry an explicit error")
	assert_gt(harness.evaluations, 1, "Must have polled more than once before timing out")

func test_await_never_treats_stale_as_final() -> void:
	var harness: AlwaysStaleHarness = AlwaysStaleHarness.new()
	var result: Dictionary = await harness._tool_await_runtime_condition({
		"expression": "stale_forever", "timeout_ms": 200, "poll_interval_ms": 50})
	assert_eq(result.get("status"), "failed", "Stale-only stream must end in timeout failure")
	assert_eq(result.get("condition_met"), false, "A stale sample must never be reported as met")
