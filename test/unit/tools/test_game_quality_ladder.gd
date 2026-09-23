extends "res://addons/gut/test.gd"

## game_quality_ladder（§8.8 WP2）单测：延迟首变帧纯函数、参数校验、
## 注入编排下的天梯组装（rung_reached 逐级、豁免、awaiting_review 永不伪造绿）。

const ToolsScript = preload("res://addons/godot_mcp/tools/debug_verify_tools.gd")

func test_latency_frames_first_change() -> void:
	var traj: Array = [
		{"frame_index": 0, "values": {"p": 100.0}},
		{"frame_index": 1, "values": {"p": 100.0}},
		{"frame_index": 2, "values": {"p": 103.5}},
		{"frame_index": 3, "values": {"p": 107.0}},
	]
	assert_eq(ToolsScript.ladder_latency_frames(traj), 2, "first changed frame is the latency")

func test_latency_frames_never_changes_or_garbage() -> void:
	assert_eq(ToolsScript.ladder_latency_frames([
		{"frame_index": 0, "values": {"p": 5.0}},
		{"frame_index": 1, "values": {"p": 5.0}}]), -1, "no movement -> -1")
	assert_eq(ToolsScript.ladder_latency_frames([]), -1, "empty trajectory -> -1")
	assert_eq(ToolsScript.ladder_latency_frames([{"frame_index": 0, "values": {}}]), -1,
		"missing label -> -1")

func test_parameter_validation() -> void:
	var tools: RefCounted = ToolsScript.new()
	var r1: Dictionary = await tools._tool_game_quality_ladder({})
	assert_true(r1.has("error"))
	var r2: Dictionary = await tools._tool_game_quality_ladder({"scene_path": "res://x.tscn"})
	assert_true(r2.has("error") and String(r2.get("error", "")).contains("movement"))
	var r3: Dictionary = await tools._tool_game_quality_ladder({
		"scene_path": "res://x.tscn", "movement": {"action": "move_right"}})
	assert_true(r3.has("error") and String(r3.get("error", "")).contains("node"))

func test_ladder_assembly_with_injected_legs() -> void:
	var tools: RefCounted = ToolsScript.new()
	# 注入 full 报告腿：全部绿（覆盖 game_quality_report 的调用）。
	tools._quality_runtime_gates_override = func(_detail: Dictionary) -> Dictionary:
		return {"checks": [
			{"id": "runtime_errors", "status": "green", "detail": {"count": 0}},
			{"id": "performance", "status": "green", "detail": {}},
			{"id": "key_screen", "status": "green", "detail": {}}],
			"needs": []}
	# R1 静态腿会真跑（宿主项目健康绿、配置绿——GUT 跑在真实项目上）。
	# 注入 ladder 运行腿：延迟 2 帧 + 一个 r3 项通过、一个 r4 项失败。
	tools._ladder_run_override = func(detail: Dictionary) -> Dictionary:
		if detail.get("kind") == "latency":
			return {"latency_frames": 2, "passed": true}
		var item: Dictionary = detail.get("item", {})
		if String(item.get("rung", "")) == "r4":
			return {"passed": false, "evidence": {"assertions_total": 1, "assertions_passed": 0}}
		return {"passed": true, "evidence": {"assertions_total": 1, "assertions_passed": 1}}
	var result: Dictionary = await tools._tool_game_quality_ladder({
		"scene_path": "res://scenes/whatever.tscn",
		"movement": {"action": "move_right", "node": "Player"},
		"extra_items": [
			{"requirement": "fairness", "rung": "r3", "detail": {"timeline": {"events": []}}},
			{"requirement": "density", "rung": "r4", "detail": {"timeline": {"events": []}}},
		]})
	assert_false(result.has("error"), str(result).substr(0, 200))
	var ladder: Dictionary = result.get("ladder", {})
	# r1 依赖宿主项目健康（真实审计）——不假设；r2 延迟 2 帧注入为绿。
	assert_eq(int(ladder.get("r2", {}).get("latency_frames", -1)), 2, "latency frames surfaced")
	assert_true((ladder.get("r4", {}).get("a_items_awaiting_review", []) as Array).size() >= 4,
		"A items listed as awaiting_review, never green")
	var r4_items: Array = ladder.get("r4", {}).get("m_items", [])
	assert_eq(r4_items.size(), 1)
	assert_false(bool(r4_items[0].get("passed", true)), "failing r4 item stays red")
	var needs: Array = result.get("needs", [])
	var names_r4: bool = false
	for need in needs:
		if String(need).contains("density"):
			names_r4 = true
	assert_true(names_r4, "failing r4 item reaches needs: %s" % str(needs))
	# rung_reached 不越过失败级：r1/r2/r3 绿则到 r3（r4 红挡住）。
	assert_eq(String(result.get("rung_reached", "")), "r3" if String(ladder.get("r1", {}).get("status", "")) == "green" else "r1",
		"rung_reached never skips a failing rung")

func test_waivers_keep_rungs_honest() -> void:
	var tools: RefCounted = ToolsScript.new()
	tools._quality_runtime_gates_override = func(_detail: Dictionary) -> Dictionary:
		return {"checks": [
			{"id": "runtime_errors", "status": "green", "detail": {}},
			{"id": "performance", "status": "green", "detail": {}},
			{"id": "key_screen", "status": "green", "detail": {}}], "needs": []}
	tools._ladder_run_override = func(detail: Dictionary) -> Dictionary:
		if detail.get("kind") == "latency":
			return {"latency_frames": 99, "passed": false}
		return {"passed": false, "evidence": {"assertions_total": 1, "assertions_passed": 0}}
	var result: Dictionary = await tools._tool_game_quality_ladder({
		"scene_path": "res://scenes/whatever.tscn",
		"movement": {"action": "move_right", "node": "Player"},
		"waivers": [{"rung": "r2", "id": "input_latency", "reason": "turn-based game, latency N/A"}]})
	assert_false(result.has("error"))
	var r2: Dictionary = result.get("ladder", {}).get("r2", {})
	assert_true(bool(r2.get("latency_waived", false)), "waiver recorded")
	assert_eq(int(r2.get("latency_frames", -1)), 99, "honest frames still surfaced")
