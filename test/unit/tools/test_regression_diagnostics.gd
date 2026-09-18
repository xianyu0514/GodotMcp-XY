extends "res://addons/gut/test.gd"

## 回归失败取证摘要测试：CI 失败原因必须携带实际值——
## 位移断言展开 before/after/displacement（区分零位移 vs 部分位移），
## 常规断言保持 expected/actual。旧格式化对位移断言打出
## "expected ?, got ?"（run 35189295410），零取证。

const WorkflowToolsScript = preload("res://addons/godot_mcp/tools/game_workflow_tools.gd")

func test_displacement_failure_carries_actual_values() -> void:
	var summary: String = WorkflowToolsScript._assertion_failure_summary({
		"description": "player moved right while holding move_right",
		"passed": false,
		"displacement": 12.4,
		"before_value": -40.0,
		"after_value": -27.6,
		"displacement_min": 15.0,
		"step": 3,
	})
	assert_string_contains(summary, "got 12.4 px", "actual displacement is reported")
	assert_string_contains(summary, "before -40.0 -> after -27.6", "positions give context (zero vs partial)")
	assert_string_contains(summary, ">= 15.0 px", "the threshold is named")
	assert_string_contains(summary, "at step 3", "step index survives")

func test_displacement_max_failure_reports_upper_bound() -> void:
	var summary: String = WorkflowToolsScript._assertion_failure_summary({
		"description": "player moved left while holding move_left",
		"passed": false,
		"displacement": 3.0,
		"before_value": 64.0,
		"after_value": 67.0,
		"displacement_max": -15.0,
		"step": 5,
	})
	assert_string_contains(summary, "<= -15.0 px", "upper-bound threshold is named")
	assert_string_contains(summary, "got 3.0 px", "wrong-direction displacement is visible")

func test_condition_failure_keeps_expected_actual_format() -> void:
	var summary: String = WorkflowToolsScript._assertion_failure_summary({
		"description": "every pickup sounded (no silent collections)",
		"passed": false,
		"expected": true,
		"actual": false,
		"context": "step 8",
	})
	assert_string_contains(summary, "expected true, got false", "condition asserts keep their format")
	assert_string_contains(summary, "at step 8", "context survives")

func test_missing_values_still_report_step() -> void:
	var summary: String = WorkflowToolsScript._assertion_failure_summary({
		"description": "bare assertion",
		"passed": false,
		"step": 2,
	})
	assert_string_contains(summary, "expected ?, got ?", "unknown payloads degrade gracefully")
	assert_string_contains(summary, "at step 2", "step still points at the failing leg")

# --- 回归演练步组装：解锁前缀必须在演练之前 -------------------------------

func test_regression_steps_unlock_before_the_drill() -> void:
	# CI 实证（35189295410/35190923900 双 09❌ 同签名）：解锁 Enter 追加在
	# 演练尾部时，注册表无 state 的语境（09 自己的完成门禁）第一条演练
	# 在标题门控下空转——移动腿零位移。组装必须：wait → 解锁 → 演练 → 锚点。
	var derived: Array = [
		{"action": "move_right", "pressed": true, "wait_frames": 24,
			"assert": {"expression": "position.x", "displacement_min": 15}},
	]
	var steps: Array = WorkflowToolsScript._assemble_regression_steps(
		derived, "Arrow-key player movement with walls that block the player.", true)
	assert_eq(str((steps[0] as Dictionary).get("wait_ms", 0)), "800", "settle wait comes first")
	var second: Dictionary = steps[1]
	assert_eq(str(second.get("action", "")), "ui_accept", "unlock enter precedes the drill")
	assert_true(bool(second.get("pressed", false)), "the unlock is a press")
	# 演练本体在解锁对之后：找到第一个 move_right 的位置
	var unlock_count: int = 0
	var drill_index: int = -1
	for i in steps.size():
		var step: Dictionary = steps[i]
		if str(step.get("action", "")) == "ui_accept" and bool(step.get("pressed", false)):
			unlock_count += 1
		if str(step.get("action", "")) == "move_right" and drill_index == -1:
			drill_index = i
	assert_gt(drill_index, unlock_count * 2, "the movement drill starts after every unlock pair")
	assert_eq(unlock_count, 3, "triple-enter unlock (restore/auto-pickup tolerance)")
	# 锚点在最后
	var last_action: String = ""
	for step_value in steps:
		var step: Dictionary = step_value
		if step.has("action"):
			last_action = String(step.get("action", ""))
	assert_eq(last_action, "move_left", "the origin-anchor sweep closes the drill")

func test_regression_steps_skip_unlock_when_prior_is_state_goal() -> void:
	var steps: Array = WorkflowToolsScript._assemble_regression_steps(
		[{"action": "move_right", "pressed": true}], 
		"Add a title screen with start, gameplay, win state and restart.", true)
	var has_unlock: bool = false
	for step_value in steps:
		if str((step_value as Dictionary).get("action", "")) == "ui_accept":
			has_unlock = true
	assert_false(has_unlock, "state goals unlock themselves — no external prefix")

func test_regression_steps_skip_unlock_without_state_context() -> void:
	var steps: Array = WorkflowToolsScript._assemble_regression_steps(
		[{"action": "move_right", "pressed": true}],
		"Arrow-key player movement with walls.", false)
	var has_unlock: bool = false
	for step_value in steps:
		if str((step_value as Dictionary).get("action", "")) == "ui_accept":
			has_unlock = true
	assert_false(has_unlock, "no state machine anywhere — nothing to unlock")
