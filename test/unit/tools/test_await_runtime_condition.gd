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

class SingleSampleHarness extends "res://addons/godot_mcp/tools/debug_runtime_tools.gd":
	var evaluations: int = 0
	var first_value: Variant = false
	func _tool_evaluate_runtime_expression(_params: Dictionary) -> Dictionary:
		evaluations += 1
		return {
			"status": "success",
			"stale": false,
			"value": (first_value if evaluations == 1 else true),
			"refresh_result": {"status": "success"}
		}

func test_single_sample_returns_fresh_false_immediately() -> void:
	# 快照语义：新鲜但为假 → 立即返回（不等真值、不带 error）。
	# play_and_verify 的位移步前快照依赖此行为（原点表达式必为假）。
	var harness: SingleSampleHarness = SingleSampleHarness.new()
	harness.first_value = false
	var result: Dictionary = await harness._tool_await_runtime_condition({
		"expression": "snapshot", "single_sample": true,
		"timeout_ms": 3000, "poll_interval_ms": 50})
	assert_eq(result.get("condition_met"), false, "Fresh-false snapshot reports condition_met=false")
	assert_false(result.has("error"), "A fresh false read is NOT an error (snapshot semantics)")
	assert_eq(harness.evaluations, 1, "Must return after the first fresh evaluation — no waiting")

func test_single_sample_still_retries_until_fresh() -> void:
	# 陈旧读不算数：single_sample 也要等到新鲜值（测量造假的防线不变）。
	var stale_then_fresh: SingleSampleHarness = SingleSampleHarness.new()
	stale_then_fresh.first_value = true
	var result: Dictionary = await stale_then_fresh._tool_await_runtime_condition({
		"expression": "snapshot", "single_sample": true,
		"timeout_ms": 3000, "poll_interval_ms": 50})
	assert_eq(result.get("condition_met"), true, "Truthy fresh value still reports met")

# --- 数值宽松相等（实测坑：expected 3 被 float 化为 "3.0"，actual "3"，eq 字符串比较误判）---

func test_compare_values_eq_is_numeric_tolerant():
	var harness: FalseThenTrueHarness = FalseThenTrueHarness.new()
	assert_true(harness._compare_values("3", "3.0", "eq"), "int vs float-formatted equal values must pass eq")
	assert_true(harness._compare_values("0", "0.0", "eq"), "zero forms must compare equal")
	assert_true(harness._compare_values("543.99", "543.99", "eq"), "identical floats pass")
	assert_false(harness._compare_values("3", "4", "eq"), "different numbers still fail")
	assert_true(harness._compare_values("true", "true", "eq"), "non-numeric strings compare verbatim")
	assert_false(harness._compare_values("abc", "abd", "eq"), "different strings fail")

func test_compare_values_ne_is_numeric_tolerant():
	var harness: FalseThenTrueHarness = FalseThenTrueHarness.new()
	assert_false(harness._compare_values("3", "3.0", "ne"), "equal numbers must not be 'ne'")
	assert_true(harness._compare_values("3", "3.5", "ne"), "different numbers are 'ne'")
