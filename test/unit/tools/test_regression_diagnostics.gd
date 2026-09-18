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
