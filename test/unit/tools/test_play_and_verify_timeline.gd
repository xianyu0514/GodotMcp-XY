extends "res://addons/gut/test.gd"

## play_and_verify timeline 模式（M7，学习自竞品 input_sequence）单测：
## 探针侧事件编译（compile_timeline 纯函数）、编辑器侧断言折叠
## （fold_timeline_assertions）、总帧数口径一致、参数校验。

const VerifyToolsScript = preload("res://addons/godot_mcp/tools/debug_verify_tools.gd")
const ProbeScript = preload("res://addons/godot_mcp/runtime/mcp_runtime_probe.gd")

func test_probe_compile_timeline_schedules_and_counts() -> void:
	var compiled: Dictionary = ProbeScript.compile_timeline([
		{"frame": 0, "action": "move_right", "pressed": true},
		{"frame": 5, "action": "move_right", "pressed": false},
		{"frame": 5, "action": "jump", "pressed": true},
		{"frame": 3, "action": "", "pressed": true},
		"not an event",
	], 10)
	assert_eq(int(compiled.get("total_frames", -1)), 16, "max frame 5 + 1 + settle 10")
	var by_frame: Dictionary = compiled.get("by_frame", {})
	assert_eq((by_frame.get(5, []) as Array).size(), 2, "two events share frame 5")
	assert_false(by_frame.has(3), "empty-action events dropped")

func test_total_frames_same_semantics_on_both_sides() -> void:
	# 编辑器侧（超时预算用）与探针侧必须同口径，否则预算先于步进超时。
	var events: Array = [{"frame": 7, "action": "attack", "pressed": true}]
	assert_eq(VerifyToolsScript.timeline_total_frames(events, 0),
		int(ProbeScript.compile_timeline(events, 0).get("total_frames", -1)),
		"editor budget == probe stepping")
	assert_eq(VerifyToolsScript.timeline_total_frames([], 0), 1, "empty timeline still steps one frame")

func test_fold_assertions_match_operators_and_missing_labels() -> void:
	var results: Array = VerifyToolsScript.fold_timeline_assertions(
		[
			{"label": "hp", "expression": "hp", "expected": 3},
			{"label": "moved", "expression": "position.x", "displacement_min": 0, "expected": 120, "operator": "gte"},
			{"label": "dead", "expression": "dead"},
			{"label": "ghost", "expression": "x", "expected": 1},
			{"label": "name", "expression": "name", "expected": "Grunt"},
		],
		{"hp": 3.0, "moved": 130, "dead": false, "name": "Grunt"})
	assert_eq(results.size(), 5)
	assert_true(bool(results[0].get("passed")), "numeric eq tolerant (3 == 3.0)")
	assert_true(bool(results[1].get("passed")), "gte operator honored")
	assert_false(bool(results[2].get("passed")), "truthiness: false fails without expected")
	assert_true(results[3].has("error"), "missing final value names the label mismatch")
	assert_true(bool(results[4].get("passed")), "string equality")

func test_fold_assertions_ne_and_numeric_only_paths() -> void:
	var results: Array = VerifyToolsScript.fold_timeline_assertions(
		[{"label": "a", "expected": 5, "operator": "ne"},
			{"label": "b", "expected": "x", "operator": "ne"}],
		{"a": 4, "b": "y"})
	assert_true(bool(results[0].get("passed")), "numeric ne")
	assert_true(bool(results[1].get("passed")), "string ne")

func test_timeline_mode_rejects_empty_events() -> void:
	var tools: RefCounted = VerifyToolsScript.new()
	var result: Dictionary = await tools._tool_play_and_verify({
		"timeline": {"events": [], "assertions": [{"label": "x", "expected": 1}]}})
	assert_true(result.has("error"), "empty events rejected: %s" % str(result))
	assert_true(String(result.get("error", "")).contains("events"))
