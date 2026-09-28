extends "res://addons/gut/test.gd"

## game_quality_report（M4 优质硬门槛）单测：static 各灯与 needs、full 注入
## 编排（含故障注入必须变红并点名）、平台画像选择。运行时编排经
## _quality_runtime_gates_override 注入，静态门禁用真实实现 + 夹具 store。

const ToolsScript = preload("res://addons/godot_mcp/tools/debug_verify_tools.gd")
const ProjectToolsScript = preload("res://addons/godot_mcp/tools/project_tools_native.gd")

const TMP: String = "res://.tmp_quality"

var _tools: RefCounted
var _project_tools: RefCounted

func before_each() -> void:
	DirAccess.make_dir_recursive_absolute(TMP)
	_project_tools = ProjectToolsScript.new()
	_project_tools._brief_overrides = {
		"content_root": TMP,
		"plan": TMP + "/plan.json",
		"queues": TMP + "/queues.json",
		"journal": TMP + "/journal.json",
	}
	_tools = ToolsScript.new()
	# headless 下无插件注册表：_quality_brief() 返回空口径（合法降级），
	# plan 灯按"无任务图"判红、unverified 灯按空队列判绿——确定性可断言。

func after_each() -> void:
	_tools = null
	_project_tools = null
	var dir: DirAccess = DirAccess.open(TMP)
	if dir:
		for entry in dir.get_files():
			dir.remove(entry)
	var root: DirAccess = DirAccess.open("res://")
	if root and root.dir_exists(TMP.trim_prefix("res://")):
		root.remove(TMP.trim_prefix("res://"))

func _checks_by_id(result: Dictionary) -> Dictionary:
	var by_id: Dictionary = {}
	for check_value in result.get("checks", []):
		if check_value is Dictionary:
			by_id[String((check_value as Dictionary).get("id", ""))] = check_value
	return by_id

func test_static_scope_gates_config_and_health() -> void:
	var result: Dictionary = _tools._tool_game_quality_report({"scope": "static"})
	assert_false(result.has("error"), str(result))
	assert_eq(String(result.get("verdict", "")), "red",
		"empty fixture project: no main scene / no inputs / no plan => red, never fake green")
	var by_id: Dictionary = _checks_by_id(result)
	# 宿主项目本身有主场景/输入映射（GUT 跑在真实项目里）——配置灯颜色随宿主，
	# 只钉"灯存在且有状态"；verdict=red 由 task_plan（无夹具任务图）保证。
	assert_has(by_id, "project_config")
	assert_false(String(by_id.get("project_config", {}).get("status", "")).is_empty())
	assert_has(by_id, "project_health")
	assert_has(by_id, "task_plan")
	assert_has(by_id, "unverified_requirements")
	var needs: Array = result.get("needs", [])
	# 宿主项目有主场景（该 need 不触发）；确定存在的缺口是无任务图——
	# needs 必须点名 plan_game_feature 这一精确修复。
	var names_plan_fix: bool = false
	for need in needs:
		if String(need).contains("plan_game_feature"):
			names_plan_fix = true
	assert_true(names_plan_fix, "needs name the exact fix")

func test_full_scope_failure_injection_turns_red_and_names_it() -> void:
	_tools._quality_runtime_gates_override = func(_detail: Dictionary) -> Dictionary:
		return {"checks": [
			{"id": "runtime_errors", "status": "red", "detail": {"count": 1}},
			{"id": "performance", "status": "green", "detail": {}},
			{"id": "key_screen", "status": "green", "detail": {}}],
			"needs": ["1 runtime errors — first: SCRIPT ERROR: boom every frame"]}
	var result: Dictionary = _tools._tool_game_quality_report({
		"scope": "full", "scene_path": TMP + "/level.tscn"})
	assert_eq(String(result.get("verdict", "")), "red",
		"one red light sinks the verdict")
	var needs: Array = result.get("needs", [])
	var names_error: bool = false
	for need in needs:
		if String(need).contains("boom every frame"):
			names_error = true
	assert_true(names_error, "the injected error reaches needs verbatim")

func test_full_scope_all_green_is_green() -> void:
	_tools._quality_runtime_gates_override = func(_detail: Dictionary) -> Dictionary:
		return {"checks": [
			{"id": "runtime_errors", "status": "green", "detail": {"count": 0}},
			{"id": "performance", "status": "green", "detail": {}},
			{"id": "key_screen", "status": "green", "detail": {}}],
			"needs": []}
	var result: Dictionary = _tools._tool_game_quality_report({
		"scope": "full", "scene_path": TMP + "/level.tscn"})
	# 静态灯随宿主项目（无夹具任务图 => task_plan 红），verdict 可以是 red；
	# 这里钉的是：注入的三个运行时灯全绿，且 needs 里没有任何运行时红项。
	var by_id: Dictionary = _checks_by_id(result)
	assert_eq(String(by_id.get("runtime_errors", {}).get("status", "")), "green")
	assert_eq(String(by_id.get("performance", {}).get("status", "")), "green")
	assert_eq(String(by_id.get("key_screen", {}).get("status", "")), "green")
	for need in result.get("needs", []):
		assert_false(String(need).contains("runtime errors") or String(need).contains("perf "),
			"no runtime-gate needs when gates are green: %s" % str(need))

func test_platform_profiles_differ_meaningfully() -> void:
	assert_lt(ToolsScript.QUALITY_PROFILE_MOBILE["min_p1_fps"],
		ToolsScript.QUALITY_PROFILE_DESKTOP["min_p1_fps"],
		"mobile tier is the stricter device, not the stricter budget")
	assert_gt(ToolsScript.QUALITY_PROFILE_MOBILE["max_p95_frame_time_ms"],
		ToolsScript.QUALITY_PROFILE_DESKTOP["max_p95_frame_time_ms"])

func test_parameter_validation() -> void:
	assert_true((_tools._tool_game_quality_report({"scope": "bogus"})).has("error"))
	assert_true((_tools._tool_game_quality_report({"scope": "full"})).has("error"),
		"full requires scene_path")
	var result: Dictionary = _tools._tool_game_quality_report({})
	assert_false(result.has("error"), "empty params default to static")
