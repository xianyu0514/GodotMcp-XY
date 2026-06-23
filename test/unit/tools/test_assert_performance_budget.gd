extends "res://addons/gut/test.gd"

# Unit tests for the assert_performance_budget gate. The pure evaluator
# (_evaluate_performance_budget) and the snapshot-driven path are tested
# without a running game by passing an explicit 'snapshot'.

var _tools: RefCounted = null

func before_each() -> void:
	_tools = load("res://addons/godot_mcp/tools/debug_tools_native.gd").new()

func after_each() -> void:
	_tools = null

func _snapshot() -> Dictionary:
	return {
		"fps": 60.0,
		"frame_time_sec": 0.016,
		"physics_frame_time_sec": 0.004,
		"object_count": 1200,
		"resource_count": 300,
		"rendered_objects_in_frame": 80,
		"memory_static_mb": 42.0,
		"node_count": 95
	}

# ---- _evaluate_performance_budget -----------------------------------------

func test_evaluate_all_pass():
	var result: Dictionary = _tools._evaluate_performance_budget(_snapshot(), {
		"min_fps": 30,
		"max_frame_time_ms": 20,
		"max_memory_mb": 64,
		"max_object_count": 2000
	})
	assert_true(bool(result["passed"]), "All thresholds satisfied")
	assert_eq((result["checks"] as Array).size(), 4, "One check per budget key")

func test_evaluate_min_fps_failure():
	var result: Dictionary = _tools._evaluate_performance_budget(_snapshot(), {"min_fps": 120})
	assert_false(bool(result["passed"]), "60 fps < 120 min fails")
	var check: Dictionary = (result["checks"] as Array)[0]
	assert_eq(str(check["comparator"]), "gte")
	assert_false(bool(check["passed"]))

func test_evaluate_max_frame_time_scaled_to_ms():
	var result: Dictionary = _tools._evaluate_performance_budget(_snapshot(), {"max_frame_time_ms": 16.0})
	var check: Dictionary = (result["checks"] as Array)[0]
	assert_almost_eq(float(check["actual"]), 16.0, 0.001, "0.016s scaled to 16ms")
	assert_true(bool(check["passed"]), "16ms <= 16ms passes")

func test_evaluate_max_frame_time_failure():
	var result: Dictionary = _tools._evaluate_performance_budget(_snapshot(), {"max_frame_time_ms": 10.0})
	assert_false(bool(result["passed"]), "16ms > 10ms fails")

func test_evaluate_missing_field_marks_failure():
	var result: Dictionary = _tools._evaluate_performance_budget({"fps": 60.0}, {"max_memory_mb": 64})
	assert_false(bool(result["passed"]), "Missing snapshot field fails the check")
	var check: Dictionary = (result["checks"] as Array)[0]
	assert_true(check.has("error"), "Reports the missing field")

func test_evaluate_only_specified_keys_checked():
	var result: Dictionary = _tools._evaluate_performance_budget(_snapshot(), {"min_fps": 30})
	assert_eq((result["checks"] as Array).size(), 1, "Only the provided key is evaluated")

# ---- _tool_assert_performance_budget --------------------------------------

func test_tool_with_explicit_snapshot_passes():
	var result: Dictionary = await _tools._tool_assert_performance_budget({
		"snapshot": _snapshot(),
		"budget": {"min_fps": 30, "max_memory_mb": 64}
	})
	assert_true(bool(result["passed"]), "Explicit snapshot evaluated without a game")
	var echoed: Dictionary = result["snapshot"]
	assert_almost_eq(float(echoed["fps"]), 60.0, 0.001, "Echoes the snapshot used")

func test_tool_with_explicit_snapshot_fails():
	var result: Dictionary = await _tools._tool_assert_performance_budget({
		"snapshot": _snapshot(),
		"budget": {"min_fps": 144}
	})
	assert_false(bool(result["passed"]), "60 < 144 fails")

func test_tool_empty_budget_errors():
	var result: Dictionary = await _tools._tool_assert_performance_budget({"snapshot": _snapshot(), "budget": {}})
	assert_true(result.has("error"), "Empty budget errors")

func test_tool_unknown_budget_key_errors():
	var result: Dictionary = await _tools._tool_assert_performance_budget({
		"snapshot": _snapshot(),
		"budget": {"max_triangles": 1000}
	})
	assert_true(result.has("error"), "Unknown budget key errors")

func test_tool_non_dict_budget_errors():
	var result: Dictionary = await _tools._tool_assert_performance_budget({"snapshot": _snapshot(), "budget": "nope"})
	assert_true(result.has("error"), "Non-object budget errors")
