extends "res://addons/gut/test.gd"

# Unit tests for the deterministic playtest helpers added to play_and_verify:
# trajectory accumulation, metric aggregation, and metric-based assertions.
# These are pure logic and do not require a running game / runtime probe.

var tools: DebugVerifyTools

func before_each() -> void:
	tools = DebugVerifyTools.new()

func after_each() -> void:
	tools = null

# --- _append_trajectory ----------------------------------------------------

func test_append_trajectory_keeps_first_advance_intact():
	var trajectory: Array = []
	var samples: Array = [
		{"frame_index": 0, "values": {"y": 0.0}},
		{"frame_index": 1, "values": {"y": -5.0}},
		{"frame_index": 2, "values": {"y": -9.0}}
	]
	var cursor: int = tools._append_trajectory(trajectory, samples, 0)
	assert_eq(cursor, 3, "cursor equals trajectory length")
	assert_eq(trajectory.size(), 3)
	assert_eq(int(trajectory[0]["frame_index"]), 0)
	assert_eq(int(trajectory[2]["frame_index"]), 2)

func test_append_trajectory_dedups_boundary_frame_on_subsequent_advance():
	var trajectory: Array = []
	var first: Array = [
		{"frame_index": 0, "values": {"y": 0.0}},
		{"frame_index": 1, "values": {"y": -5.0}}
	]
	var second: Array = [
		{"frame_index": 0, "values": {"y": -5.0}},
		{"frame_index": 1, "values": {"y": -8.0}}
	]
	var cursor: int = tools._append_trajectory(trajectory, first, 0)
	cursor = tools._append_trajectory(trajectory, second, cursor)
	# 2 frames + (2-1 deduped) = 3 entries, indices 0..2 continuous.
	assert_eq(trajectory.size(), 3, "boundary frame deduped")
	assert_eq(cursor, 3)
	assert_eq(int(trajectory[2]["frame_index"]), 2, "global frame index is continuous")
	assert_almost_eq(float(trajectory[2]["values"]["y"]), -8.0, 0.001)

# --- _compute_trajectory_metrics -------------------------------------------

func test_compute_metrics_basic_aggregates():
	var trajectory: Array = [
		{"frame_index": 0, "values": {"y": 0.0}},
		{"frame_index": 1, "values": {"y": -6.0}},
		{"frame_index": 2, "values": {"y": -10.0}},
		{"frame_index": 3, "values": {"y": -4.0}}
	]
	var metrics: Dictionary = tools._compute_trajectory_metrics(trajectory, 0.5)
	assert_true(metrics.has("y"))
	var y: Dictionary = metrics["y"]
	assert_almost_eq(float(y["min"]), -10.0, 0.001)
	assert_almost_eq(float(y["max"]), 0.0, 0.001)
	assert_almost_eq(float(y["first"]), 0.0, 0.001)
	assert_almost_eq(float(y["last"]), -4.0, 0.001)
	assert_almost_eq(float(y["delta"]), -4.0, 0.001)
	assert_almost_eq(float(y["range"]), 10.0, 0.001)
	assert_eq(int(y["min_frame"]), 2, "peak (most negative) at frame 2")
	assert_almost_eq(float(y["min_time"]), 1.0, 0.001, "min_time = min_frame * step_delta")
	assert_eq(int(y["samples"]), 4)

func test_compute_metrics_ignores_non_numeric_values():
	var trajectory: Array = [
		{"frame_index": 0, "values": {"name": "Player", "hp": 3}},
		{"frame_index": 1, "values": {"name": "Player", "hp": 2}}
	]
	var metrics: Dictionary = tools._compute_trajectory_metrics(trajectory, 1.0)
	assert_false(metrics.has("name"), "string label is not aggregated")
	assert_true(metrics.has("hp"))
	assert_almost_eq(float(metrics["hp"]["min"]), 2.0, 0.001)

func test_compute_metrics_empty_trajectory():
	var metrics: Dictionary = tools._compute_trajectory_metrics([], 1.0)
	assert_eq(metrics.size(), 0)

# --- _evaluate_metric_assertion --------------------------------------------

func test_metric_assertion_passes_with_operator():
	var metrics: Dictionary = {"y": {"min": -96.0, "max": 0.0, "first": 0.0, "last": 0.0, "delta": 0.0, "range": 96.0, "min_frame": 8, "max_frame": 0, "min_time": 0.13, "max_time": 0.0, "samples": 20}}
	var result: Dictionary = tools._evaluate_metric_assertion({"metric": "y", "aggregate": "min", "operator": "lte", "expected": -90.0}, metrics)
	assert_true(bool(result["passed"]), "min y (-96) <= -90 passes")
	assert_almost_eq(float(result["actual"]), -96.0, 0.001)

func test_metric_assertion_fails_with_operator():
	var metrics: Dictionary = {"y": {"min": -50.0, "max": 0.0, "first": 0.0, "last": 0.0, "delta": 0.0, "range": 50.0, "min_frame": 5, "max_frame": 0, "min_time": 0.08, "max_time": 0.0, "samples": 20}}
	var result: Dictionary = tools._evaluate_metric_assertion({"metric": "y", "aggregate": "min", "operator": "lte", "expected": -90.0}, metrics)
	assert_false(bool(result["passed"]), "min y (-50) <= -90 fails")

func test_metric_assertion_missing_metric_errors():
	var result: Dictionary = tools._evaluate_metric_assertion({"metric": "missing", "aggregate": "max"}, {})
	assert_false(bool(result["passed"]))
	assert_true(result.has("error"))

func test_metric_assertion_unknown_aggregate_errors():
	var metrics: Dictionary = {"y": {"min": 0.0, "max": 1.0}}
	var result: Dictionary = tools._evaluate_metric_assertion({"metric": "y", "aggregate": "bogus"}, metrics)
	assert_false(bool(result["passed"]))
	assert_true(result.has("error"))

func test_metric_assertion_truthy_without_expected():
	var metrics: Dictionary = {"hits": {"max": 3.0, "min": 0.0}}
	var result: Dictionary = tools._evaluate_metric_assertion({"metric": "hits", "aggregate": "max"}, metrics)
	assert_true(bool(result["passed"]), "max hits (3) is truthy")

# --- _compare_metric_value -------------------------------------------------

func test_compare_metric_value_operators():
	assert_true(tools._compare_metric_value(5.0, 5.0, "eq"))
	assert_true(tools._compare_metric_value(5.0, 4.0, "ne"))
	assert_true(tools._compare_metric_value(5.0, 4.0, "gt"))
	assert_true(tools._compare_metric_value(5.0, 5.0, "gte"))
	assert_true(tools._compare_metric_value(4.0, 5.0, "lt"))
	assert_true(tools._compare_metric_value(5.0, 5.0, "lte"))
	assert_false(tools._compare_metric_value(5.0, 4.0, "lt"))
	assert_false(tools._compare_metric_value(5.0, 4.0, "unknown_op"))
