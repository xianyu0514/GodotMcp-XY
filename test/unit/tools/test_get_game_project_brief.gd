extends "res://addons/gut/test.gd"

## get_game_project_brief（M2 WP2）单测：一次调用重建会话上下文。
## store 路径与内容根通过 _brief_overrides 注入夹具，避免依赖真实 .mcp/ 状态。

const ToolsScript = preload("res://addons/godot_mcp/tools/project_tools_native.gd")

const TMP: String = "res://.tmp_brief"

var _tools: RefCounted

func before_each() -> void:
	DirAccess.make_dir_recursive_absolute(TMP)
	_tools = ToolsScript.new()
	_tools._brief_overrides = {
		"content_root": TMP,
		"plan": TMP + "/plan.json",
		"queues": TMP + "/queues.json",
		"journal": TMP + "/journal.json",
	}

func after_each() -> void:
	_tools = null
	var dir: DirAccess = DirAccess.open(TMP)
	if dir:
		for entry in dir.get_files():
			dir.remove(entry)
	var root: DirAccess = DirAccess.open("res://")
	if root and root.dir_exists(TMP.trim_prefix("res://")):
		root.remove(TMP.trim_prefix("res://"))

func _write(path: String, content: String) -> void:
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	file.store_string(content)
	file.close()

func _write_plan(tasks: Array) -> void:
	_write(TMP + "/plan.json", JSON.stringify({"revision": 1, "tasks": tasks}))

func _sentences(result: Dictionary) -> Array:
	return result.get("next_sentences", [])

func test_empty_project_points_to_first_game() -> void:
	var result: Dictionary = _tools._tool_get_game_project_brief({})
	assert_false(result.has("error"), str(result))
	assert_eq(int(result.get("content", {}).get("scenes_count", -1)), 0)
	var sentences: Array = _sentences(result)
	var points_to_first: bool = false
	for sentence in sentences:
		if String(sentence).contains("make_first_game"):
			points_to_first = true
	assert_true(points_to_first, "empty project suggests the entry recipe: %s" % str(sentences))
	var points_to_plan: bool = false
	for sentence in sentences:
		if String(sentence).contains("plan_game_feature"):
			points_to_plan = true
	assert_true(points_to_plan, "missing plan is self-disclosed, not an error (S-1)")

func test_task_plan_state_summarized_with_blocked_priority() -> void:
	_write_plan([
		{"id": "t1", "title": "player move", "status": "done"},
		{"id": "t2", "title": "boss phase 2", "status": "in_progress"},
		{"id": "t3", "title": "export leg", "status": "blocked"},
	])
	var result: Dictionary = _tools._tool_get_game_project_brief({})
	var plan: Dictionary = result.get("task_plan", {})
	assert_true(bool(plan.get("exists", false)))
	assert_eq(int(plan.get("by_status", {}).get("done", 0)), 1)
	assert_eq(int(plan.get("by_status", {}).get("blocked", 0)), 1)
	assert_eq((plan.get("active", []) as Array).size(), 2, "done tasks are not active")
	var sentences: Array = _sentences(result)
	var names_blocked: bool = false
	for sentence in sentences:
		if String(sentence).contains("export leg"):
			names_blocked = true
	assert_true(names_blocked, "blocked task named with the unblock verb: %s" % str(sentences))

func test_unverified_requirements_named_one_by_one() -> void:
	_write(TMP + "/queues.json", JSON.stringify({"schema_version": 1, "queues": [{
		"queue_id": "q1", "goal": "melee enemy contract", "phase": "incomplete",
		"requirements": ["detect_chase", "windup", "drop_once"],
		"items": [
			{"requirement": "detect_chase", "status": "passed",
				"evidence": {"assertions_total": 2, "assertions_passed": 2, "evidence_level": "native_run"}},
			{"requirement": "windup", "status": "pending", "evidence": {}},
			{"requirement": "drop_once", "status": "passed",
				"evidence": {"assertions_total": 0, "assertions_passed": 0, "evidence_level": "native_run"}},
		],
	}]}))
	var result: Dictionary = _tools._tool_get_game_project_brief({})
	var verification: Array = result.get("verification", [])
	assert_eq(verification.size(), 1)
	var unverified: Array = verification[0].get("unverified", [])
	assert_true(unverified.has("windup"), "pending named")
	assert_true(unverified.has("drop_once"), "zero-assertion pass is smoke, named as unverified")
	assert_false(unverified.has("detect_chase"), "verified requirement not flagged")
	var sentences: Array = _sentences(result)
	var names_gap: bool = false
	for sentence in sentences:
		if String(sentence).contains("windup"):
			names_gap = true
	assert_true(names_gap, "the gap reaches next_sentences: %s" % str(sentences))

func test_external_claim_never_counts_as_verified() -> void:
	_write(TMP + "/queues.json", JSON.stringify({"schema_version": 1, "queues": [{
		"queue_id": "q2", "goal": "claimed but unproven", "phase": "completed",
		"requirements": ["r1"],
		"items": [{"requirement": "r1", "status": "passed",
			"evidence": {"assertions_total": 1, "assertions_passed": 1, "evidence_level": "external_claim"}}],
	}]}))
	var result: Dictionary = _tools._tool_get_game_project_brief({})
	var verification: Array = result.get("verification", [])
	assert_true(verification[0].get("unverified", []).has("r1"),
		"external claims are not verified evidence (H-1 口径)")

func test_all_green_suggests_pillars_or_ship() -> void:
	_write_plan([{"id": "t1", "title": "core loop", "status": "done"}])
	# 有内容（夹具里放一个场景）、无缺口 => 建议进入打磨/扩展/发布
	_write(TMP + "/level.tscn", "[gd_scene format=3]\n\n[node name=\"Root\" type=\"Node2D\"]\n")
	var result: Dictionary = _tools._tool_get_game_project_brief({})
	assert_eq(int(result.get("content", {}).get("scenes_count", 0)), 1)
	var sentences: Array = _sentences(result)
	var suggests_ship: bool = false
	for sentence in sentences:
		if String(sentence).contains("release_export_flow"):
			suggests_ship = true
	assert_true(suggests_ship, "green state suggests pillars/ship: %s" % str(sentences))

func test_recent_changes_capped_and_ordered() -> void:
	var operations: Array = []
	for i in range(10):
		operations.append({"title": "change %d" % i, "path": "res://a%d.gd" % i, "status": "done"})
	_write(TMP + "/journal.json", JSON.stringify({"schema_version": 1, "operations": operations}))
	var result: Dictionary = _tools._tool_get_game_project_brief({"max_changes": 3})
	var changes: Array = result.get("recent_changes", [])
	assert_eq(changes.size(), 3, "capped")
	assert_eq(String(changes[2].get("title", "")), "change 9", "latest last, newest tail kept")

func test_corrupt_stores_never_break_the_brief() -> void:
	# 结构损坏（合法 JSON、错误形状）：同样走优雅错误路径，且不触发引擎
	# JSON 解析的 stderr 噪音（GUT 会把引擎错误计为 Unexpected Errors）。
	_write(TMP + "/queues.json", "{\"queues\": \"not an array\"}")
	_write(TMP + "/journal.json", "{\"operations\": {}}")
	var result: Dictionary = _tools._tool_get_game_project_brief({})
	assert_eq(String(result.get("status", "")), "success",
		"the brief degrades honestly, one bad store must not kill it")
