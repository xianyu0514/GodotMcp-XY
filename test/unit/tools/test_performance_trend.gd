extends "res://addons/gut/test.gd"

# get_performance_trend：趋势统计纯函数 + 采样聚合。

const RuntimeToolsScript = preload("res://addons/godot_mcp/tools/debug_runtime_tools.gd")

func test_trend_stats_basic():
	var stats: Dictionary = RuntimeToolsScript._trend_stats([10.0, 20.0, 30.0, 40.0, 100.0])
	assert_eq(float(stats["min"]), 10.0)
	assert_eq(float(stats["max"]), 100.0)
	assert_eq(float(stats["avg"]), 40.0)
	assert_eq(float(stats["p95"]), 100.0, "5 个样本 p95 取第 5 个（ceil(4.75)=5）")

func test_trend_stats_single_value():
	var stats: Dictionary = RuntimeToolsScript._trend_stats([42.0])
	assert_eq(float(stats["min"]), 42.0)
	assert_eq(float(stats["max"]), 42.0)
	assert_eq(float(stats["avg"]), 42.0)
	assert_eq(float(stats["p95"]), 42.0)

func test_trend_stats_empty_returns_empty():
	assert_eq(RuntimeToolsScript._trend_stats([]).size(), 0)

func test_trend_stats_p95_indexing():
	# 20 个样本 p95 = ceil(19)-1 = 第 19 个（0-indexed 18）
	var values: Array = []
	for i in range(20):
		values.append(float(i + 1))
	var stats: Dictionary = RuntimeToolsScript._trend_stats(values)
	assert_eq(float(stats["p95"]), 19.0, "20 个样本的 p95 是第 19 个值")

func test_trend_stats_unsorted_input():
	var stats: Dictionary = RuntimeToolsScript._trend_stats([50.0, 10.0, 30.0])
	assert_eq(float(stats["min"]), 10.0, "输入无序也能正确取 min")
	assert_eq(float(stats["max"]), 50.0)
