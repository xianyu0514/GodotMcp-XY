extends "res://addons/gut/test.gd"

const WorkflowToolsScript = preload("res://addons/godot_mcp/tools/game_workflow_tools.gd")
const EngineScript = preload("res://addons/godot_mcp/native_mcp/game_workflow_engine.gd")
const ManifestScript = preload("res://addons/godot_mcp/native_mcp/tools_manifest.gd")
const TaskPlanStoreScript = preload("res://addons/godot_mcp/tools/task_plan_store.gd")

class FakeCore extends RefCounted:
	var registrations: Dictionary = {}
	var schemas: Dictionary = {}
	var responses: Dictionary = {}
	var traits: Dictionary = {}
	var calls: Array[Dictionary] = []

	func register_tool(name: String, description: String, input_schema: Dictionary,
			callable: Callable, output_schema: Dictionary = {}, annotations: Dictionary = {},
			category: String = "core", group: String = "") -> void:
		registrations[name] = {
			"name": name, "description": description, "input_schema": input_schema,
			"callable": callable, "output_schema": output_schema,
			"annotations": annotations, "category": category, "group": group
		}

	func get_registered_tools() -> Array:
		var result: Array = []
		for tool_name in ManifestScript.tool_names():
			result.append({"name": tool_name, "category": ManifestScript.category_of(tool_name), "enabled": false})
		for tool_name in registrations:
			if not tool_name in ManifestScript.TOOLS:
				result.append({"name": tool_name, "category": registrations[tool_name]["category"], "enabled": true})
		return result

	func get_tool_input_schema(tool_name: String) -> Dictionary:
		return schemas.get(tool_name, {"type": "object", "properties": {}})

	func get_tool_execution_traits(tool_name: String) -> Dictionary:
		return traits.get(tool_name, {
			"read_only": false, "idempotent": false, "destructive": false
		})

	func invoke_planned_tool(tool_name: String, arguments: Dictionary, authorization: Dictionary) -> Variant:
		calls.append({"tool_name": tool_name, "arguments": arguments.duplicate(true), "authorization": authorization.duplicate(true)})
		var configured: Variant = responses.get(tool_name, {"status": "ok", "data": true})
		if configured is Array:
			var queue: Array = configured
			if queue.is_empty():
				return {"error": "No fake response remains for %s" % tool_name}
			return queue.pop_front()
		return configured

var _core: FakeCore
var _tools: RefCounted
var _plan_path: String

func before_each() -> void:
	_core = FakeCore.new()
	_tools = WorkflowToolsScript.new()
	_tools.register_tools(_core)
	_plan_path = "user://game_workflow_tool_test_%s.json" % str(get_instance_id())
	_remove_plan()
	# 按需演练测试隔离：清除功能注册表（累积模式会让主演练只测新功能腿）
	if FileAccess.file_exists("res://.mcp/feature_registry.json"):
		DirAccess.remove_absolute(ProjectSettings.globalize_path("res://.mcp/feature_registry.json"))
	# 游戏模型同样隔离：合并数量/参数注入/手改保护都读默认模型路径
	if FileAccess.file_exists("res://.mcp/game_model.json"):
		DirAccess.remove_absolute(ProjectSettings.globalize_path("res://.mcp/game_model.json"))

func after_each() -> void:
	_remove_plan()
	if FileAccess.file_exists("res://.mcp/game_model.json"):
		DirAccess.remove_absolute(ProjectSettings.globalize_path("res://.mcp/game_model.json"))

func _remove_plan() -> void:
	for suffix in ["", ".next", ".bak"]:
		var absolute: String = ProjectSettings.globalize_path(_plan_path + suffix)
		if FileAccess.file_exists(absolute):
			DirAccess.remove_absolute(absolute)

func _plan(profiles: Array, objective: String = "Run project tests") -> Dictionary:
	return _tools._tool_plan_game_workflow({
		"action": "plan",
		"objective": objective,
		"profiles": profiles,
		"plan_path": _plan_path
	})

func _successful_gate_responses() -> void:
	_core.responses["prepare_project_test_environment"] = {
		"status": "ready", "count": 1, "recoverable": false,
		"environment": [{"path": "res://test", "exists": true, "count": 1, "state": "ready"}]
	}
	_core.responses["ensure_project_directory"] = {
		"status": "unchanged", "path": "res://test", "created": false, "already_exists": true
	}
	_core.responses["list_project_tests"] = {
		"status": "ready", "count": 1, "tests": [{"name": "smoke"}]
	}
	_core.responses["verify_scripts"] = {
		"status": "passed", "total_checked": 3, "verified": 3, "failed": 0
	}
	_core.responses["run_project_tests"] = {
		"status": "passed", "total_count": 2, "passed_count": 2, "failed_count": 0
	}

func _universal_evidence() -> Dictionary:
	return {
		"status": "passed", "passed": true, "success": true, "valid": true,
		"count": 1, "total_count": 1, "passed_count": 1, "failed_count": 0,
		"total_checked": 1, "verified": 1, "failed": 0,
		"error_count": 0, "issue_count": 0, "must_fix_count": 0,
		"broken_count": 0, "total_nodes": 1, "artifact_exists": true,
		"runtime_info": {"running": true}, "checks": [{"passed": true}],
		"diff_pixel_count": 0, "diff_ratio": 0.0, "data": true
	}

func test_registers_only_two_compact_always_on_meta_tools() -> void:
	assert_true(_core.registrations.has("plan_game_workflow"))
	assert_true(_core.registrations.has("run_game_workflow"))
	assert_eq(_core.registrations["plan_game_workflow"]["category"], "meta")
	assert_eq(_core.registrations["run_game_workflow"]["category"], "meta")
	var run_schema: Dictionary = _core.registrations["run_game_workflow"]["input_schema"]
	assert_false((run_schema.get("properties", {}) as Dictionary).has("tool_name"),
		"The runner must not expose an arbitrary nested tool invocation escape hatch")
	assert_true((run_schema.get("properties", {}) as Dictionary).has("command"),
		"One natural-language command must be able to create or resume its durable workflow")

func test_command_entrypoint_plans_runs_and_replays_without_duplicate_work() -> void:
	_successful_gate_responses()
	var first: Dictionary = await _tools._tool_run_game_workflow({
		"command": "Run project tests", "plan_path": _plan_path, "max_steps": 2
	})
	assert_false(first.has("error"), str(first.get("error", "")))
	assert_true(TaskPlanStoreScript.plan_exists(_plan_path))
	var workflow_id: String = String(first.get("workflow_id", ""))
	assert_false(workflow_id.is_empty())
	var second: Dictionary = await _tools._tool_run_game_workflow({
		"command": "  run   PROJECT tests  ", "plan_path": _plan_path, "max_steps": 20
	})
	assert_eq(second.get("workflow_id", ""), workflow_id,
		"A retried equivalent command must attach to the existing checkpoint")
	assert_eq(second.get("status", ""), "completed", str(second.get("error", "")))
	var calls_after_completion: int = _core.calls.size()
	var replay: Dictionary = await _tools._tool_run_game_workflow({
		"command": "Run project tests", "plan_path": _plan_path
	})
	assert_eq(replay.get("status", ""), "completed")
	assert_eq(replay.get("workflow_id", ""), workflow_id)
	assert_eq(_core.calls.size(), calls_after_completion,
		"Retrying a completed command must return its terminal checkpoint without re-execution")

func test_command_entrypoint_rejects_a_different_goal_without_replacing_checkpoint() -> void:
	_successful_gate_responses()
	var first: Dictionary = await _tools._tool_run_game_workflow({
		"command": "Run project tests", "plan_path": _plan_path, "max_steps": 1
	})
	assert_false(first.has("error"), str(first.get("error", "")))
	var calls_before_conflict: int = _core.calls.size()
	var conflict: Dictionary = await _tools._tool_run_game_workflow({
		"command": "Build a polished pause menu", "plan_path": _plan_path
	})
	assert_eq(conflict.get("status", ""), "conflict")
	assert_true(conflict.has("error"))
	assert_eq(conflict.get("workflow_id", ""), first.get("workflow_id", ""))
	assert_eq(_core.calls.size(), calls_before_conflict,
		"A different command must never mutate or advance the existing workflow")

func test_plan_persists_contract_and_status_resumes_it() -> void:
	var planned: Dictionary = _plan(["quality_assurance"])
	assert_eq(planned.get("status", ""), "planned", str(planned.get("error", "")))
	assert_true(FileAccess.file_exists(_plan_path))
	var status: Dictionary = _tools._tool_plan_game_workflow({
		"action": "status", "plan_path": _plan_path
	})
	assert_eq(status.get("status", ""), "ok", str(status.get("error", "")))
	assert_eq(status.get("workflow_id", ""), planned.get("workflow_id", ""))
	assert_eq(status.get("state", ""), "planned")

func test_runner_executes_hidden_atomic_tools_without_changing_visibility() -> void:
	_core.responses["prepare_project_test_environment"] = {
		"status": "ready", "count": 1, "recoverable": false,
		"environment": [{"path": "res://test", "exists": true, "count": 1, "state": "ready"}]
	}
	_core.responses["ensure_project_directory"] = {
		"status": "unchanged", "path": "res://test", "created": false, "already_exists": true
	}
	_core.responses["list_project_tests"] = {
		"status": "ready", "count": 2, "tests": [{"name": "smoke", "framework": "native"}]
	}
	_core.responses["verify_scripts"] = {"total_checked": 2, "verified": 2, "failed": 0, "results": []}
	_core.responses["run_project_tests"] = [
		{"status": "pending", "job_id": "tests"},
		{"status": "passed", "total_count": 2, "passed_count": 2, "failed_count": 0}
	]
	var planned: Dictionary = _plan(["quality_assurance"])
	var first: Dictionary = await _tools._tool_run_game_workflow({
		"plan_path": _plan_path, "expected_workflow_id": planned["workflow_id"], "max_steps": 6
	})
	assert_eq(first.get("status", ""), "waiting", str(first.get("error", "")))
	assert_eq(_core.calls.size(), 5)
	assert_true(_core.calls.all(func(call: Dictionary) -> bool:
		return (call.get("authorization", {}) as Dictionary).get("kind", "") == "game_workflow"))
	var second: Dictionary = await _tools._tool_run_game_workflow({
		"plan_path": _plan_path, "expected_workflow_id": planned["workflow_id"], "max_steps": 6
	})
	assert_eq(second.get("status", ""), "completed", str(second.get("error", "")))
	assert_eq(_core.calls.size(), 6, "Polling reuses the same authorized step and arguments")

func test_default_runner_adapts_above_four_without_expanding_tools_list() -> void:
	_successful_gate_responses()
	var required: Array[String] = []
	for tool_name in ManifestScript.tool_names():
		if tool_name not in EngineScript.FORBIDDEN_NESTED_CAPABILITIES:
			required.append(tool_name)
			_core.responses[tool_name] = _universal_evidence()
		if required.size() >= 25:
			break
	_core.responses["audit_project_health"] = {
		"status": "healthy", "summary": {"errors": 0}, "passed": true
	}
	_core.responses["manage_localization"] = {
		"status": "completed", "written": 1, "passed": true
	}
	var planned: Dictionary = _tools._tool_plan_game_workflow({
		"action": "plan",
		"objective": "Run project tests with a large supported capability set",
		"profiles": ["quality_assurance"],
		"required_capabilities": required,
		"plan_path": _plan_path
	})
	assert_eq(planned.get("status", ""), "planned", str(planned.get("error", "")))
	var first: Dictionary = await _tools._tool_run_game_workflow({
		"plan_path": _plan_path, "expected_workflow_id": planned["workflow_id"]
	})
	assert_gt((first.get("executed", []) as Array).size(), 4,
		"The omitted max_steps value should choose an adaptive execution slice")
	assert_lt((first.get("executed", []) as Array).size(), required.size() + 10,
		"Adaptive execution remains a time slice instead of loading the whole goal at once")
	assert_eq(_core.registrations.size(), 2,
		"Adaptive execution must not create more always-on schemas")

func test_hundred_capability_goal_completes_across_adaptive_slices() -> void:
	var required: Array[String] = []
	for tool_name in ManifestScript.tool_names():
		if tool_name in EngineScript.FORBIDDEN_NESTED_CAPABILITIES:
			continue
		required.append(tool_name)
		_core.responses[tool_name] = _universal_evidence()
		if required.size() >= 100:
			break
	_core.responses["audit_project_health"] = {
		"status": "healthy", "summary": {"errors": 0}, "passed": true
	}
	_core.responses["manage_localization"] = {
		"status": "completed", "written": 1, "passed": true
	}
	var planned: Dictionary = _tools._tool_plan_game_workflow({
		"action": "plan", "objective": "Execute every required supported capability",
		"required_capabilities": required, "plan_path": _plan_path
	})
	assert_eq(planned.get("status", ""), "planned", str(planned.get("error", "")))
	var full_status: Dictionary = _tools._tool_plan_game_workflow({
		"action": "status", "plan_path": _plan_path, "include_plan": true
	})
	var compact_bytes: int = JSON.stringify(planned).to_utf8_buffer().size()
	var full_bytes: int = JSON.stringify(full_status).to_utf8_buffer().size()
	assert_lt(compact_bytes * 10, full_bytes,
		"Default status should avoid over 90% of a 100-capability durable plan payload")
	print("[WorkflowTokens] compact=%d full=%d avoided=%.2f%%" % [
		compact_bytes, full_bytes, (1.0 - float(compact_bytes) / float(full_bytes)) * 100.0])
	var result: Dictionary = {}
	var largest_slice: int = 0
	for round_index in range(20):
		result = await _tools._tool_run_game_workflow({
			"plan_path": _plan_path, "expected_workflow_id": planned["workflow_id"]
		})
		largest_slice = maxi(largest_slice, (result.get("executed", []) as Array).size())
		if String(result.get("status", "")) == "completed":
			break
		assert_eq(result.get("yield_reason", ""), "execution_slice_complete",
			"An internal slice yields resumably instead of truncating the goal")
	assert_eq(result.get("status", ""), "completed", str(result.get("error", "")))
	var called: Dictionary = {}
	for call_value in _core.calls:
		called[String((call_value as Dictionary).get("tool_name", ""))] = true
	for tool_name in required:
		assert_true(called.has(tool_name), "Every explicitly required capability executes: %s" % tool_name)
	assert_gte(_core.calls.size(), 100)
	assert_lte(largest_slice, 32, "Adaptive slices bound one turn's load without bounding the goal")
	assert_eq(_core.registrations.size(), 2,
		"One hundred hidden capabilities still add no always-on MCP schemas")
	# 全新计划启动会先 stop_project（残留游戏防护，运行时类计划必发）：
	# 该次调用计入 calls 但不计入 atomic_calls——这里核对的语义是"每个
	# 原子调用都有记账"，容许恰好一次的启动期 stop。
	var atomic_calls: int = int((result.get("metrics", {}) as Dictionary).get("atomic_calls", 0))
	var stop_calls: int = 0
	for call_value in _core.calls:
		if String((call_value as Dictionary).get("tool_name", "")) == "stop_project":
			stop_calls += 1
	# The feature registry lookup + goal ledger are file reads, not tool calls.
	# The accounting: atomic_calls == tool_calls - stop_calls
	assert_eq(atomic_calls, _core.calls.size() - stop_calls,
		"every atomic call is accounted (plus exactly the fresh-plan stop)")

func test_default_workflow_responses_are_compact_projections() -> void:
	var planned: Dictionary = _tools._tool_plan_game_workflow({
		"action": "plan", "objective": "Run project tests",
		"profiles": ["quality_assurance"], "plan_path": _plan_path
	})
	assert_false(planned.has("plan"), "The durable DAG is opt-in instead of repeated every turn")
	var ready: Array = planned.get("ready", [])
	assert_lte(ready.size(), EngineScript.READY_PREVIEW_LIMIT)
	for value in ready:
		var preview: Dictionary = value
		assert_eq(preview.keys().size(), 3)
		assert_false(preview.has("arguments"))
		assert_false(preview.has("description"))
	assert_false(JSON.stringify(planned).contains("inputSchema"),
		"Only the current missing-input step may load an atomic schema")

func test_composite_game_loop_runs_beyond_ten_tools_to_evidence_completion() -> void:
	_successful_gate_responses()
	_core.responses["play_and_verify"] = {
		"passed": true, "runtime_info": {"running": true}
	}
	_core.responses["assert_no_runtime_errors"] = {
		"passed": true, "error_count": 0, "errors": []
	}
	_core.responses["assert_visual_baseline"] = {
		"passed": true, "diff_pixel_count": 0, "diff_ratio": 0.0
	}
	var planned: Dictionary = _plan(
		["gameplay_feature", "ui_screen", "quality_assurance"],
		"Create player gameplay, a pause UI, and run project tests")
	assert_eq(planned.get("status", ""), "planned", str(planned.get("error", "")))
	var result: Dictionary = {}
	for round_index in range(20):
		result = await _tools._tool_run_game_workflow({
			"plan_path": _plan_path,
			"expected_workflow_id": planned["workflow_id"],
			"max_steps": 4
		})
		if String(result.get("status", "")) == "completed":
			break
	assert_eq(result.get("status", ""), "completed", str(result.get("error", "")))
	assert_gt(_core.calls.size(), 10, "The persisted workflow must cross the ad-hoc route budget")
	var create_scene_calls: int = 0
	for call_value in _core.calls:
		if String((call_value as Dictionary).get("tool_name", "")) == "create_scene":
			create_scene_calls += 1
	assert_eq(create_scene_calls, 2,
		"Distinct gameplay and UI scene writes both execute in the completed loop")
	assert_eq(int((result.get("progress", {}) as Dictionary).get("pending", -1)), 0)
	assert_eq(int((result.get("progress", {}) as Dictionary).get("blocked", -1)), 0)

func test_exact_atomic_goal_uses_adaptive_catalog_fallback() -> void:
	var planned: Dictionary = _tools._tool_plan_game_workflow({
		"action": "plan",
		"objective": "read_script",
		"plan_path": _plan_path
	})
	assert_eq(planned.get("status", ""), "planned", str(planned.get("error", "")))
	assert_eq(planned.get("profiles", []), [])
	var completed: Dictionary = await _tools._tool_run_game_workflow({
		"plan_path": _plan_path, "expected_workflow_id": planned["workflow_id"]
	})
	assert_eq(completed.get("status", ""), "completed", str(completed.get("error", "")))
	assert_eq(_core.calls.size(), 1)
	assert_eq(_core.calls[0].get("tool_name", ""), "read_script")

func test_complete_fallback_can_route_more_than_ten_semantic_clauses() -> void:
	var names: Array[String] = []
	for tool_name in ManifestScript.tool_names():
		if tool_name not in EngineScript.FORBIDDEN_NESTED_CAPABILITIES:
			names.append(tool_name)
		if names.size() >= 12:
			break
	var route: Dictionary = _tools._route_complete_goal("; ".join(names))
	assert_eq(route.get("uncovered_requirements", []), [])
	for tool_name in names:
		assert_true(tool_name in route.get("capabilities", []),
			"Clause routing must retain every exact atomic intent: %s" % tool_name)
	assert_gt((route.get("capabilities", []) as Array).size(), 10,
		"Ten is a per-clause discovery budget, not a complete-goal ceiling")

func test_partial_fallback_never_claims_an_uncovered_goal_is_planned() -> void:
	var result: Dictionary = _tools._tool_plan_game_workflow({
		"action": "plan",
		"objective": "Inspect quasar_flux and prove flibbertigibbet alignment",
		"plan_path": _plan_path
	})
	assert_eq(result.get("status", ""), "needs_clarification")
	assert_true(result.get("uncovered_requirements", []) is Array)
	assert_false((result.get("uncovered_requirements", []) as Array).is_empty())
	assert_false(TaskPlanStoreScript.plan_exists(_plan_path),
		"A matched subset must not be persisted as if it represented the full objective")

func test_known_profile_clause_cannot_hide_a_later_uncovered_requirement() -> void:
	var result: Dictionary = _tools._tool_plan_game_workflow({
		"action": "plan",
		"objective": "Create player movement; inspect quasar_flux alignment",
		"plan_path": _plan_path
	})
	assert_eq(result.get("status", ""), "needs_clarification")
	assert_false((result.get("uncovered_requirements", []) as Array).is_empty())
	assert_false(TaskPlanStoreScript.plan_exists(_plan_path))

func test_profile_and_supported_unprofiled_clause_compose_automatically() -> void:
	var result: Dictionary = _tools._tool_plan_game_workflow({
		"action": "plan",
		"objective": "Build a polished pause UI menu and verify its visuals",
		"plan_path": _plan_path, "include_plan": true
	})
	assert_eq(result.get("status", ""), "planned", str(result.get("error", "")))
	var names: Array[String] = []
	for task_value in (result.get("plan", {}) as Dictionary).get("tasks", []):
		names.append(String((task_value as Dictionary).get("tool_name", "")))
	assert_true("create_theme" in names)
	assert_true("assert_visual_baseline" in names)

func test_exact_atomic_name_augments_a_recognized_composite_goal() -> void:
	var planned: Dictionary = _tools._tool_plan_game_workflow({
		"action": "plan",
		"objective": "Create player movement and explicitly inspect with (`read_script`).",
		"plan_path": _plan_path,
		"include_plan": true
	})
	assert_eq(planned.get("status", ""), "planned", str(planned.get("error", "")))
	var names: Array[String] = []
	var read_task: Dictionary = {}
	for task_value in (planned.get("plan", {}) as Dictionary).get("tasks", []):
		var task: Dictionary = task_value
		names.append(String(task.get("tool_name", "")))
		if String(task.get("tool_name", "")) == "read_script":
			read_task = task
	assert_true("read_script" in names,
		"Exact atomic intent must survive profile composition without expanding tools/list")
	assert_true(bool(read_task.get("objective_gate", false)),
		"Explicit atomic intent must be proven, not merely executed as optional inspection")

func test_transient_failure_yields_then_resumes_without_consuming_repair_budget() -> void:
	_successful_gate_responses()
	_core.responses["list_project_tests"] = [
		{"error": "Service temporarily unavailable (503)"},
		{"status": "ready", "count": 1, "tests": [{"name": "smoke"}]}
	]
	var planned: Dictionary = _plan(["quality_assurance"])
	var first: Dictionary = await _tools._tool_run_game_workflow({
		"plan_path": _plan_path, "expected_workflow_id": planned["workflow_id"]
	})
	assert_eq(first.get("status", ""), "waiting")
	assert_gte(int(first.get("retry_after_ms", 0)), 1000,
		"Transient retries expose backoff guidance instead of encouraging a hot loop")
	assert_eq(_core.calls.size(), 3)
	var second: Dictionary = await _tools._tool_run_game_workflow({
		"plan_path": _plan_path, "expected_workflow_id": planned["workflow_id"]
	})
	assert_eq(second.get("status", ""), "completed", str(second.get("error", "")))

func test_restart_replays_safe_read_but_never_guesses_unknown_mutation() -> void:
	_core.responses["prepare_project_test_environment"] = {
		"status": "ready", "count": 1, "recoverable": false,
		"environment": [{"path": "res://test", "exists": true, "count": 1, "state": "ready"}]
	}
	_core.traits["prepare_project_test_environment"] = {"read_only": true, "idempotent": true, "destructive": false}
	var planned: Dictionary = _plan(["quality_assurance"])
	var status: Dictionary = _tools._tool_plan_game_workflow({
		"action": "status", "plan_path": _plan_path, "include_plan": true
	})
	var plan: Dictionary = status["plan"]
	plan["tasks"][0]["status"] = "in_progress"
	assert_false(TaskPlanStoreScript.save_plan(plan, _plan_path).has("error"))
	var recovered: Dictionary = await _tools._tool_run_game_workflow({
		"plan_path": _plan_path, "expected_workflow_id": planned["workflow_id"], "max_steps": 1
	})
	assert_ne(recovered.get("status", ""), "recovery_required")
	assert_eq(_core.calls.size(), 1)

	_remove_plan()
	planned = _plan(["gameplay_feature"], "Create player movement")
	status = _tools._tool_plan_game_workflow({
		"action": "status", "plan_path": _plan_path, "include_plan": true
	})
	plan = status["plan"]
	var mutation: Dictionary = {}
	for task_value in plan.get("tasks", []):
		if String((task_value as Dictionary).get("tool_name", "")) == "create_scene":
			mutation = task_value
			break
	mutation["status"] = "in_progress"
	assert_false(TaskPlanStoreScript.save_plan(plan, _plan_path).has("error"))
	var guarded: Dictionary = await _tools._tool_run_game_workflow({
		"plan_path": _plan_path, "expected_workflow_id": planned["workflow_id"]
	})
	assert_eq(guarded.get("status", ""), "recovery_required")
	var calls_at_guard: int = _core.calls.size()
	var still_guarded: Dictionary = await _tools._tool_run_game_workflow({
		"plan_path": _plan_path, "expected_workflow_id": planned["workflow_id"]
	})
	assert_eq(still_guarded.get("status", ""), "recovery_required")
	assert_eq(_core.calls.size(), calls_at_guard,
		"Recovery-required workflows stay fail-closed until an explicit replan")

func test_missing_current_step_inputs_waits_without_invoking_or_losing_plan() -> void:
	_core.schemas["create_scene"] = {
		"type": "object", "properties": {"scene_name": {"type": "string"}}, "required": ["scene_name"]
	}
	var planned: Dictionary = _plan(["gameplay_feature"], "Create player movement")
	var result: Dictionary = await _tools._tool_run_game_workflow({
		"plan_path": _plan_path, "expected_workflow_id": planned["workflow_id"], "max_steps": 10
	})
	assert_eq(result.get("status", ""), "needs_input")
	# 移动目标在两次巡检与 create_scene 之间合法执行四个方向输入注册步骤。
	assert_eq(_core.calls.size(), 7, "Two inspections plus four directional input steps (+1 fresh-plan stop) run before the missing build input")
	assert_true("scene_name" in result.get("missing_inputs", []))
	assert_eq((result.get("input_schema", {}) as Dictionary).get("required", []), ["scene_name"],
		"The current atomic schema is returned on demand without expanding tools/list")
	var step_id: String = String(result.get("step_id", ""))
	var resumed: Dictionary = await _tools._tool_run_game_workflow({
		"plan_path": _plan_path,
		"expected_workflow_id": planned["workflow_id"],
		"max_steps": 1,
		"step_inputs": {step_id: {"scene_name": "Player"}}
	})
	assert_ne(resumed.get("status", ""), "needs_input")
	assert_eq(_core.calls.back()["tool_name"], "create_scene")

func test_protected_path_and_tampered_blueprint_stop_before_execution() -> void:
	_core.schemas["create_scene"] = {
		"type": "object", "properties": {"scene_path": {"type": "string"}}, "required": ["scene_path"]
	}
	var planned: Dictionary = _plan(["gameplay_feature"], "Create player movement")
	var initial: Dictionary = await _tools._tool_run_game_workflow({
		"plan_path": _plan_path, "expected_workflow_id": planned["workflow_id"], "max_steps": 2
	})
	assert_ne(initial.get("status", ""), "error")
	var status: Dictionary = _tools._tool_plan_game_workflow({
		"action": "status", "plan_path": _plan_path, "include_plan": true
	})
	var plan: Dictionary = status["plan"]
	var create_step: Dictionary = {}
	for task_value in plan.get("tasks", []):
		if (task_value as Dictionary).get("tool_name", "") == "create_scene":
			create_step = task_value
			break
	var protected: Dictionary = await _tools._tool_run_game_workflow({
		"plan_path": _plan_path,
		"expected_workflow_id": planned["workflow_id"],
		"max_steps": 8,
		"step_inputs": {create_step["id"]: {"scene_path": "res://scenes/../addons/godot_mcp/overwrite.tscn"}}
	})
	assert_eq(protected.get("status", ""), "blocked")
	var calls_before_tamper: int = _core.calls.size()
	plan["tasks"][0]["tool_name"] = "delete_node"
	var saved: Dictionary = TaskPlanStoreScript.save_plan(plan, _plan_path)
	assert_false(saved.has("error"))
	var tampered: Dictionary = await _tools._tool_run_game_workflow({"plan_path": _plan_path})
	assert_true(tampered.has("error"))
	assert_eq(_core.calls.size(), calls_before_tamper)

func test_replan_requires_compare_and_swap_for_existing_workflow() -> void:
	var planned: Dictionary = _plan(["quality_assurance"])
	var stale: Dictionary = _tools._tool_plan_game_workflow({
		"action": "replan", "plan_path": _plan_path,
		"expected_workflow_id": "stale", "objective": "Run project tests",
		"profiles": ["quality_assurance"]
	})
	assert_true(stale.has("error"))
	var replaced: Dictionary = _tools._tool_plan_game_workflow({
		"action": "replan", "plan_path": _plan_path,
		"expected_workflow_id": planned["workflow_id"], "objective": "Run project tests",
		"profiles": ["quality_assurance"]
	})
	assert_eq(replaced.get("status", ""), "planned", str(replaced.get("error", "")))
	assert_ne(replaced.get("workflow_id", ""), planned.get("workflow_id", ""))

func test_changed_replan_reclassifies_instead_of_reusing_stale_capabilities() -> void:
	var planned: Dictionary = _tools._tool_plan_game_workflow({
		"action": "plan", "objective": "read_script", "plan_path": _plan_path
	})
	var replaced: Dictionary = _tools._tool_plan_game_workflow({
		"action": "replan", "plan_path": _plan_path,
		"expected_workflow_id": planned["workflow_id"],
		"objective": "get_project_info", "include_plan": true
	})
	assert_eq(replaced.get("status", ""), "planned", str(replaced.get("error", "")))
	var names: Array[String] = []
	for task_value in (replaced.get("plan", {}) as Dictionary).get("tasks", []):
		names.append(String((task_value as Dictionary).get("tool_name", "")))
	assert_true("get_project_info" in names)
	assert_false("read_script" in names,
		"A changed objective must not inherit the old adaptive route")

# --- Workflow reliability: artifact-derived inputs and runtime window authorization ---

func test_created_script_artifact_derives_attach_script_input() -> void:
	_core.schemas["create_script"] = {
		"type": "object", "properties": {"script_path": {"type": "string"}},
		"required": ["script_path"]
	}
	_core.schemas["attach_script"] = {
		"type": "object", "properties": {"script_path": {"type": "string"}},
		"required": ["script_path"]
	}
	_core.responses["create_script"] = {
		"success": true, "script_path": "res://scripts/player.gd"
	}
	var planned: Dictionary = _plan(["gameplay_feature"], "Create player movement")
	var result: Dictionary = await _tools._tool_run_game_workflow({
		"plan_path": _plan_path,
		"expected_workflow_id": planned["workflow_id"],
		"max_steps": 14,
		"step_inputs": {"create_script": {"script_path": "res://scripts/player.gd"}}
	})
	assert_ne(String(result.get("status", "")), "needs_input",
		"attach_script must not stall when the artifact registry knows the script")
	var attach_call: Dictionary = {}
	for call_value in _core.calls:
		var call: Dictionary = call_value
		if String(call["tool_name"]) == "attach_script":
			attach_call = call
	assert_false(attach_call.is_empty(), "attach_script executed after derivation")
	assert_eq(String((attach_call.get("arguments", {}) as Dictionary).get("script_path", "")),
		"res://scripts/player.gd",
		"script_path derives from the create_script artifact instead of asking the caller")

func test_runner_auto_authorizes_runtime_window_for_planned_run() -> void:
	var planned: Dictionary = _tools._tool_plan_game_workflow({
		"action": "plan",
		"objective": "Run the game and verify runtime state",
		"required_capabilities": ["run_project"],
		"plan_path": _plan_path
	})
	assert_false(planned.has("error"), str(planned.get("error", "")))
	var result: Dictionary = await _tools._tool_run_game_workflow({
		"plan_path": _plan_path,
		"expected_workflow_id": planned["workflow_id"],
		"max_steps": 10
	})
	assert_ne(String(result.get("status", "")), "needs_input")
	var run_call: Dictionary = {}
	for call_value in _core.calls:
		var call: Dictionary = call_value
		if String(call["tool_name"]) == "run_project":
			run_call = call
	assert_false(run_call.is_empty(), "run_project executed inside the plan")
	assert_eq(bool((run_call.get("arguments", {}) as Dictionary).get("allow_window", false)), true,
		"Plan-authorized runtime steps auto-pass the interactive window policy")

func test_plan_tool_documents_expect_fail_option() -> void:
	var properties: Dictionary = ((_core.registrations["plan_game_workflow"] as Dictionary)\
		.get("input_schema", {}) as Dictionary).get("properties", {})
	assert_true((properties as Dictionary).has("expect_fail"),
		"Negative-gate configuration is discoverable in the plan schema")

func test_scene_scoped_steps_derive_profile_scene_and_visual_paths() -> void:
	_core.schemas["create_node"] = {
		"type": "object", "properties": {"node_path": {"type": "string"}},
		"required": ["node_path"]
	}
	_core.responses["create_scene"] = {
		"success": true, "scene_path": "res://ui_main.tscn"
	}
	_core.responses["get_runtime_screenshot"] = {
		"status": "ok", "save_path": "user://mcp_runtime_capture.jpg"
	}
	_core.responses["assert_visual_baseline"] = {
		"passed": true, "baseline_created": true, "diff_pixel_count": 0, "diff_ratio": 0.0
	}
	var planned: Dictionary = _plan(["ui_screen"], "Polished pause menu")
	var result: Dictionary = await _tools._tool_run_game_workflow({
		"plan_path": _plan_path,
		"expected_workflow_id": planned["workflow_id"],
		"max_steps": 12,
		"step_inputs": {"create_node": {"node_path": "/root/UI/Panel"}}
	})
	assert_ne(String(result.get("status", "")), "needs_input",
		"Scene-scoped and visual steps derive their inputs from artifacts")
	var create_node_call: Dictionary = {}
	var visual_call: Dictionary = {}
	for call_value in _core.calls:
		var call: Dictionary = call_value
		if String(call["tool_name"]) == "create_node":
			create_node_call = call
		if String(call["tool_name"]) == "assert_visual_baseline":
			visual_call = call
	assert_eq(String((create_node_call.get("arguments", {}) as Dictionary).get("scene_path", "")),
		"res://ui_main.tscn",
		"Node writes pin the profile's created scene so they cannot land in another scene")
	assert_eq(String((visual_call.get("arguments", {}) as Dictionary).get("candidate_path", "")),
		"user://mcp_runtime_capture.jpg",
		"Visual gate candidate derives from the runtime screenshot artifact")
	var old_baseline: String = String((visual_call.get("arguments", {}) as Dictionary).get("baseline_path", ""))
	assert_true(old_baseline.begins_with("user://visual_baselines/") and old_baseline.ends_with("_mcp_runtime_capture.jpg"),
		"Visual gate baseline derives a per-workflow golden location (got " + old_baseline + ")")

func test_collectible_goal_derives_character_body_root() -> void:
	# 蓝图控制器对任意动词（含金币/胜利）都 extends CharacterBody2D：
	# 根节点派生必须与之一致，否则 collect-only 目标得到挂在 Node 根上的
	# CharacterBody2D 脚本，attach 阶段直接失败。
	_core.schemas["create_scene"] = {
		"type": "object", "properties": {"scene_path": {"type": "string"}},
		"required": ["scene_path"]
	}
	_core.responses["create_scene"] = {
		"success": true, "scene_path": "res://scenes/gameplay-feature.tscn"
	}
	var planned: Dictionary = _plan(["gameplay_feature"],
		"Collect a coin and show a win label")
	var result: Dictionary = await _tools._tool_run_game_workflow({
		"plan_path": _plan_path,
		"expected_workflow_id": planned["workflow_id"],
		"max_steps": 3
	})
	var create_scene_call: Dictionary = {}
	for call_value in _core.calls:
		var call: Dictionary = call_value
		if String(call["tool_name"]) == "create_scene":
			create_scene_call = call
			break
	assert_false(create_scene_call.is_empty(), "create_scene executed")
	assert_eq(String((create_scene_call.get("arguments", {}) as Dictionary).get("root_node_type", "")),
		"CharacterBody2D",
		"Collectible-only goal still derives a CharacterBody2D scene root")

func test_movement_goal_derives_play_and_verify_input_steps() -> void:
	# 空 steps 的 play_and_verify 只证明"能启动不崩"；派生的方向键演练让
	# _physics_process 真正执行，控制器脚本错误才会被捕获。
	var planned: Dictionary = _plan(["gameplay_feature"], "Create player movement")
	var status: Dictionary = _tools._tool_plan_game_workflow({
		"action": "status", "plan_path": _plan_path, "include_plan": true
	})
	var play_task: Dictionary = {}
	for task_value in (status["plan"] as Dictionary).get("tasks", []):
		var task: Dictionary = task_value
		if String(task.get("tool_name", "")) == "play_and_verify":
			play_task = task
			break
	assert_false(play_task.is_empty(), "gameplay profile has a play gate")
	var arguments: Dictionary = _tools._derive_step_arguments(
		status["plan"], play_task, "play_and_verify",
		_tools._resolve_inputs(play_task, {}, false))
	var steps: Array = arguments.get("steps", [])
	assert_gt(steps.size(), 0, "movement goal derives input exercise steps")
	var actions: Array = []
	for step_value in steps:
		actions.append(String((step_value as Dictionary).get("action", "")))
	assert_true("move_left" in actions and "move_right" in actions,
		"derived steps exercise horizontal movement (got %s)" % str(actions))
	assert_ne(str(arguments.get("steps", [])), "", str(planned.get("error", "")))

func test_gate_repair_requeues_profile_screenshot_evidence() -> void:
	# 修复改变项目状态后必须重采截图：否则视觉门禁拿旧候选与旧基线恒等比较。
	var plan: Dictionary = _plan(["ui_screen"], "Polished pause menu with a screen")
	var status: Dictionary = _tools._tool_plan_game_workflow({
		"action": "status", "plan_path": _plan_path, "include_plan": true
	})
	var loaded: Dictionary = status["plan"]
	var shot_task: Dictionary = {}
	for task_value in loaded.get("tasks", []):
		var task: Dictionary = task_value
		if String(task.get("tool_name", "")) == "get_runtime_screenshot":
			shot_task = task
			break
	shot_task["status"] = "done"
	var repaired_gate: Dictionary = {"profile": "ui_screen", "id": "wf_xxx"}
	_tools._requeue_profile_evidence(loaded, repaired_gate)
	assert_eq(String(shot_task.get("status", "")), "pending",
		"done screenshot of the repaired profile is requeued for fresh evidence")
	# 状态名不是 "completed"（引擎写 "done"）：错误的状态名曾让该函数静默
	# 匹配不到任何步骤（死代码回归守卫）。
	var mismatch_status: Dictionary = {"profile": "ui_screen"}
	_tools._requeue_profile_evidence(loaded, mismatch_status)
	assert_eq(String(shot_task.get("status", "")), "pending",
		"already-pending screenshot is untouched by a second requeue")

func test_anchor_step_with_caller_node_path_derives_preset() -> void:
	# preset 是 set_anchor_preset 的 schema 必填项：调用方只给 node_path 时
	# 必须派生默认 CENTER(8)，否则该步永远停在 needs_input。
	var task: Dictionary = {
		"id": "wf_anchor", "profile": "ui_screen", "tool_name": "set_anchor_preset",
		"arguments": {"node_path": "/root/Hud/Label"}}
	var plan: Dictionary = {"goal": "polished pause menu", "workflow": {"artifacts": {}}}
	var derived: Dictionary = _tools._derive_step_arguments(
		plan, task, "set_anchor_preset", task.get("arguments", {}).duplicate(true))
	assert_eq(int(derived.get("preset", -1)), 8,
		"missing preset derives CENTER even when node_path is caller-supplied")

func test_non_movement_goal_derives_boot_settle_steps() -> void:
	# 非移动目标的 play_and_verify 此前是零 steps：编排立即返回，启动期
	# 错误还没到调试桥——只证明了"发起过运行"。默认给一个启动等待窗口。
	var planned: Dictionary = _plan(["gameplay_feature"], "Collect a coin and show a win label")
	var status: Dictionary = _tools._tool_plan_game_workflow({
		"action": "status", "plan_path": _plan_path, "include_plan": true
	})
	var loaded: Dictionary = status["plan"]
	var play_task: Dictionary = {}
	for task_value in loaded.get("tasks", []):
		var task: Dictionary = task_value
		if String(task.get("tool_name", "")) == "play_and_verify":
			play_task = task
			break
	assert_false(play_task.is_empty(), "gameplay profile has a play gate")
	var arguments: Dictionary = _tools._derive_step_arguments(
		loaded, play_task, "play_and_verify",
		_tools._resolve_inputs(play_task, {}, false))
	var steps: Array = arguments.get("steps", [])
	assert_gt(steps.size(), 0, "non-movement play gate derives a boot-settle window")

func test_visual_baseline_is_scoped_per_workflow() -> void:
	# 截图文件名全目标相同（mcp_runtime_capture.jpg）：基线必须带
	# workflow_id 隔离，否则目标 B 拿目标 A 的图当金标准。
	var planned: Dictionary = _plan(["ui_screen"], "Polished pause menu with a screen")
	var status: Dictionary = _tools._tool_plan_game_workflow({
		"action": "status", "plan_path": _plan_path, "include_plan": true
	})
	var loaded: Dictionary = status["plan"]
	(loaded.get("workflow", {}) as Dictionary)["artifacts"] = {
		"screenshot": "user://mcp_runtime_capture.jpg"}
	var gate_task: Dictionary = {}
	for task_value in loaded.get("tasks", []):
		var task: Dictionary = task_value
		if String(task.get("tool_name", "")) == "assert_visual_baseline":
			gate_task = task
			break
	var arguments: Dictionary = _tools._derive_step_arguments(
		loaded, gate_task, "assert_visual_baseline",
		_tools._resolve_inputs(gate_task, {}, false))
	var baseline: String = String(arguments.get("baseline_path", ""))
	var workflow_id: String = String(loaded.get("workflow", {}).get("workflow_id", ""))
	assert_true(baseline.contains(workflow_id),
		"baseline path carries the workflow id (got %s)" % baseline)
	assert_eq(String(arguments.get("candidate_path", "")), "user://mcp_runtime_capture.jpg",
		"candidate still derives from the screenshot artifact")

func test_export_chain_derives_the_goal_platform_preset() -> void:
	# validate/run/smoke 三步的预设名必须来自目标平台（此前硬编码
	# "Windows Desktop"：web 目标校验/导出/冒烟一个 Windows exe）。
	var planned: Dictionary = _tools._tool_plan_game_workflow({
		"action": "plan", "objective": "Export the game for web",
		"profiles": ["release_export"], "platform": "web", "plan_path": _plan_path})
	assert_eq(planned.get("status", ""), "planned", str(planned.get("error", "")))
	var status: Dictionary = _tools._tool_plan_game_workflow({
		"action": "status", "plan_path": _plan_path, "include_plan": true
	})
	var loaded: Dictionary = status["plan"]
	for expected_tool in ["validate_export_preset", "run_export", "smoke_test_export"]:
		var chain_task: Dictionary = {}
		for task_value in loaded.get("tasks", []):
			var task: Dictionary = task_value
			if String(task.get("tool_name", "")) == expected_tool:
				chain_task = task
				break
		assert_false(chain_task.is_empty(), "%s present in release plan" % expected_tool)
		var derived_args: Dictionary = _tools._derive_step_arguments(
			loaded, chain_task, expected_tool,
			_tools._resolve_inputs(chain_task, {}, false))
		assert_eq(String(derived_args.get("preset", "")), "Web",
			"%s derives the goal-platform preset (got %s)" % [expected_tool, derived_args.get("preset", "")])

func test_pause_goal_derives_behavioral_play_steps() -> void:
	# 暂停目标（含中文）的 play 门禁必须派生"Esc 暂停→断言已停→Esc 恢复→
	# 断言继续"的演练：缺这两条步内断言只证明了"游戏能启动"。
	var planned: Dictionary = _plan(["gameplay_feature"], "做一个 Esc 暂停菜单，按 Esc 暂停世界再按恢复")
	assert_eq(planned.get("status", ""), "planned", str(planned.get("error", "")))
	var status: Dictionary = _tools._tool_plan_game_workflow({
		"action": "status", "plan_path": _plan_path, "include_plan": true
	})
	var loaded: Dictionary = status["plan"]
	var play_task: Dictionary = {}
	for task_value in loaded.get("tasks", []):
		var task: Dictionary = task_value
		if String(task.get("tool_name", "")) == "play_and_verify":
			play_task = task
			break
	assert_false(play_task.is_empty(), "gameplay profile contains the play gate")
	var arguments: Dictionary = _tools._derive_step_arguments(
		loaded, play_task, "play_and_verify",
		_tools._resolve_inputs(play_task, {}, false))
	var steps: Array = arguments.get("steps", [])
	assert_eq(str((play_task.get("derived_inputs", {}) as Dictionary).get("steps", "")),
		"pause-exercise", "pause goals derive the pause exercise, not boot-settle")
	assert_true(steps.size() >= 4, "press/wait/release sequence present")
	var first: Dictionary = steps[0] if steps.size() > 0 else {}
	assert_eq(str(first.get("action", "")), "ui_cancel", "pause uses the built-in Esc action")
	assert_eq(bool((first.get("assert", {}) as Dictionary).get("expected", null)), true,
		"first Esc asserts the world IS paused")
	assert_true(bool(first.get("screenshot", false)), "paused-state screenshot is part of the evidence")
	var third: Dictionary = steps[2] if steps.size() > 2 else {}
	assert_eq(bool((third.get("assert", {}) as Dictionary).get("expected", null)), false,
		"second Esc asserts the world RESUMED")

func test_movement_goal_derives_displacement_assertions() -> void:
	# 移动演练必须带位移断言（N1 oracle 形态）：四向按键各断言位置变化，
	# 否则控制器没挂上/没在动时门禁空转通过（#124 抓到过的盲区）。
	var planned: Dictionary = _plan(["gameplay_feature"], "arrow-key movement controller")
	var status: Dictionary = _tools._tool_plan_game_workflow({
		"action": "status", "plan_path": _plan_path, "include_plan": true
	})
	var loaded: Dictionary = status["plan"]
	for task_value in loaded.get("tasks", []):
		var task: Dictionary = task_value
		if String(task.get("tool_name", "")) != "play_and_verify":
			continue
		var arguments: Dictionary = _tools._derive_step_arguments(
			loaded, task, "play_and_verify", _tools._resolve_inputs(task, {}, false))
		assert_eq(str((task.get("derived_inputs", {}) as Dictionary).get("steps", "")),
			"movement-exercise")
		var steps: Array = arguments.get("steps", [])
		# 四向位移腿 + 手感腿（末个 move_right 按压为帧步进保持，
		# 断言走 metric 而非内联）= 5 组按压/释放
		var leg_actions: Array = []
		var assert_count: int = 0
		for step_value in steps:
			var step: Dictionary = step_value
			if bool(step.get("pressed", false)):
				leg_actions.append(step.get("action"))
				if step.has("assert"):
					var leg_assert: Dictionary = step.get("assert", {})
					assert_true(leg_assert.has("displacement_min") or leg_assert.has("displacement_max"),
						"displacement asserts are snapshot-relative (signed deltas)")
					assert_count += 1
		assert_eq(leg_actions, ["move_right", "move_left", "move_up", "move_down", "move_right"],
			"four directions + the feel hold leg")
		assert_eq(assert_count, 4, "all four displacement legs assert")
		assert_true(bool(arguments.get("deterministic", false)), "feel sampling enables deterministic mode")
		var final_assertions: Array = arguments.get("assertions", [])
		assert_gt(final_assertions.size(), 0, "feel metric assertion appended")
		return
	fail_test("play_and_verify task not found for movement goal")

func test_movement_and_pause_goal_derives_combined_exercise() -> void:
	# 组合目标两套演练都要：位移断言 + 暂停/恢复断言。
	var planned: Dictionary = _plan(["gameplay_feature"], "arrow-key movement with an Esc pause menu")
	var status: Dictionary = _tools._tool_plan_game_workflow({
		"action": "status", "plan_path": _plan_path, "include_plan": true
	})
	var loaded: Dictionary = status["plan"]
	for task_value in loaded.get("tasks", []):
		var task: Dictionary = task_value
		if String(task.get("tool_name", "")) != "play_and_verify":
			continue
		var arguments: Dictionary = _tools._derive_step_arguments(
			loaded, task, "play_and_verify", _tools._resolve_inputs(task, {}, false))
		assert_eq(str((task.get("derived_inputs", {}) as Dictionary).get("steps", "")),
			"movement+pause-exercise")
		var steps: Array = arguments.get("steps", [])
		var has_displacement: bool = false
		var has_pause: bool = false
		for step_value in steps:
			var step: Dictionary = step_value
			if String(step.get("action", "")) == "ui_cancel":
				has_pause = true
			var leg_assert: Dictionary = step.get("assert", {}) if step.has("assert") else {}
			if String(leg_assert.get("expression", "")) == "position.x":
				has_displacement = true
		assert_true(has_displacement, "combined exercise keeps displacement asserts")
		assert_true(has_pause, "combined exercise keeps pause/resume asserts")
		return
	fail_test("play_and_verify task not found for combined goal")

func test_save_goal_derives_save_and_restore_exercises() -> void:
	# 存档链两侧门禁各有专属演练（N3），通用 play 门禁对存档目标给移动演练。
	var planned: Dictionary = _plan(["gameplay_feature"], "加存档读档：关闭进程再启动进度还在")
	var status: Dictionary = _tools._tool_plan_game_workflow({
		"action": "status", "plan_path": _plan_path, "include_plan": true
	})
	var loaded: Dictionary = status["plan"]
	var by_key: Dictionary = {}
	for task_value in loaded.get("tasks", []):
		var task: Dictionary = task_value
		by_key[String(task.get("step_key", ""))] = task
	assert_true(by_key.has("save_play"), "plan carries the save gate")
	assert_true(by_key.has("restore_play"), "plan carries the restore gate")

	var save_args: Dictionary = _tools._derive_step_arguments(
		loaded, by_key["save_play"], "play_and_verify",
		_tools._resolve_inputs(by_key["save_play"], {}, false))
	assert_eq(str((by_key["save_play"].get("derived_inputs", {}) as Dictionary).get("steps", "")),
		"save-exercise")
	var save_actions: Array = []
	for step_value in save_args.get("steps", []):
		var step: Dictionary = step_value
		if bool(step.get("pressed", false)):
			save_actions.append(step.get("action"))
	assert_eq(save_actions, ["move_right", "save_game"])

	var restore_args: Dictionary = _tools._derive_step_arguments(
		loaded, by_key["restore_play"], "play_and_verify",
		_tools._resolve_inputs(by_key["restore_play"], {}, false))
	assert_eq(str((by_key["restore_play"].get("derived_inputs", {}) as Dictionary).get("steps", "")),
		"save-restore-exercise")
	var restore_steps: Array = restore_args.get("steps", [])
	assert_eq(str(((restore_steps[0] as Dictionary).get("assert", {}) as Dictionary).get("expression", "")),
		"position.x")

	# 通用 play_verify 对存档目标派生移动演练（蓝图口径：存档暗含移动）
	var generic_args: Dictionary = _tools._derive_step_arguments(
		loaded, by_key["play_verify"], "play_and_verify",
		_tools._resolve_inputs(by_key["play_verify"], {}, false))
	assert_eq(str((by_key["play_verify"].get("derived_inputs", {}) as Dictionary).get("steps", "")),
		"movement-exercise")

func test_remap_goal_parses_and_overrides_upsert() -> void:
	# E1：换键目标解析 + upsert 覆盖（擦除旧绑定、仅新键）+ remap 演练派生
	var planned: Dictionary = _plan(["gameplay_feature"],
		"arrow-key movement, then rebind move_up from the W key to the U key")
	var status: Dictionary = _tools._tool_plan_game_workflow({
		"action": "status", "plan_path": _plan_path, "include_plan": true
	})
	var loaded: Dictionary = status["plan"]
	var remap_parse: Dictionary = _tools.parse_remap_goal(
		"arrow-key movement, then rebind move_up from the W key to the U key")
	assert_eq(str(remap_parse.get("action", "")), "move_up")
	assert_eq(str(remap_parse.get("old_key", "")), "W")
	assert_eq(str(remap_parse.get("new_key", "")), "U")
	for task_value in loaded.get("tasks", []):
		var task: Dictionary = task_value
		var tool: String = String(task.get("tool_name", ""))
		var arguments: Dictionary = _tools._derive_step_arguments(
			loaded, task, tool, _tools._resolve_inputs(task, {}, false))
		if tool == "upsert_project_input_action" and String(arguments.get("action_name", "")) == "move_up":
			assert_true(bool(arguments.get("erase_existing", false)), "rebound action erases old bindings")
			var events: Array = arguments.get("events", [])
			assert_eq(events.size(), 1, "single new binding")
			assert_eq(int((events[0] as Dictionary).get("keycode", 0)), KEY_U)
		if tool == "play_and_verify":
			assert_eq(str((task.get("derived_inputs", {}) as Dictionary).get("steps", "")),
				"remap-exercise")
			var steps: Array = arguments.get("steps", [])
			var first: Dictionary = steps[0] if steps.size() > 0 else {}
			var inert_found: bool = false
			for step_value in steps:
				var step_check: Dictionary = step_value
				if step_check.has("assert") and bool((step_check.get("assert", {}) as Dictionary).get("inert", false)):
					inert_found = true
			assert_true(inert_found, "old binding asserted inert via a pre-step snapshot")
			# 新键断言存在
			var has_new_key_leg: bool = false
			for step_value in steps:
				var step: Dictionary = step_value
				if step.has("event") and String((step.get("assert", {}) as Dictionary).get("description", "")).contains("new binding"):
					has_new_key_leg = true
			assert_true(has_new_key_leg, "new binding asserted effective")
			return
	fail_test("play_and_verify task not found for remap goal")

func test_remap_parse_zh_and_failure_modes() -> void:
	var zh: Dictionary = _tools.parse_remap_goal("把 move_left 从 A 键改成 Q 键")
	assert_eq(str(zh.get("action", "")), "move_left")
	assert_eq(str(zh.get("old_key", "")), "A")
	assert_eq(str(zh.get("new_key", "")), "Q")
	# 无换键动词 / 未知动作 → 空解析（宁可交给通用路径也不猜）
	assert_true(_tools.parse_remap_goal("arrow-key movement only").is_empty())
	assert_true(_tools.parse_remap_goal("rebind attack to R").is_empty())

func test_rename_goal_parses_and_derives_step_arguments() -> void:
	# E4：更名目标 → rename 步骤自主拿到 symbol 对 + 行为回归演练
	var parsed: Dictionary = _tools.parse_rename_goal("rename the field speed to velocity in the scripts")
	assert_eq(str(parsed.get("symbol_name", "")), "speed")
	assert_eq(str(parsed.get("new_name", "")), "velocity")
	var zh: Dictionary = _tools.parse_rename_goal("把 speed 重命名为 velocity")
	assert_eq(str(zh.get("symbol_name", "")), "speed")
	assert_eq(str(zh.get("new_name", "")), "velocity")
	assert_true(_tools.parse_rename_goal("arrow-key movement only").is_empty())

# ---------- P1/P2 新增：数量保留、state_machine 保留、手改保护、
# ---------- 回归门禁、调参方向证明、完整循环验收器 ----------

const GameModelStoreScript = preload("res://addons/godot_mcp/tools/game_model_store.gd")
const FeatureRegistryScript = preload("res://addons/godot_mcp/tools/feature_registry.gd")

func _create_script_task_from(plan: Dictionary) -> Dictionary:
	for task_value in (plan as Dictionary).get("tasks", []):
		var task: Dictionary = task_value
		if String(task.get("tool_name", "")) == "create_script":
			return task
	return {}

func test_merged_objective_carries_counts_from_game_model() -> void:
	GameModelStoreScript.save_model({"counts": {"coins": 1, "enemies": 1}})
	var merged: String = _tools._build_merged_objective(
		{"movement": true, "collectible": true, "enemy": true},
		"Add 3 collectible coins and another patrolling enemy.")
	assert_true(merged.contains("collect 4 coins"),
		"additive request: 1 existing + 3 requested (got: %s)" % merged)
	assert_true(merged.contains("2 patrolling enemies"),
		"'another enemy': 1 existing + 1 (got: %s)" % merged)

func test_additive_request_only_touches_mentioned_kinds() -> void:
	# 真机复现："Add another patrolling enemy." 给金币也 +1（3→4）
	GameModelStoreScript.save_model({"counts": {"coins": 3, "enemies": 1}})
	var merged: String = _tools._build_merged_objective(
		{"movement": true, "collectible": true, "enemy": true},
		"Add another patrolling enemy.")
	assert_true(merged.contains("collect 3 coins"),
		"an enemy-only additive goal does not inflate coins (got: %s)" % merged)
	assert_true(merged.contains("2 patrolling enemies"),
		"the enemy count increments (got: %s)" % merged)

func test_tuning_goal_on_fresh_plan_still_merges() -> void:
	# 真缺陷回归：合并块曾嵌在非调参 else 里——全新计划的调参目标生成
	# extends Node 空壳，modify 找不到常量，目标必败。
	FeatureRegistryScript.record_feature("Arrow-key player movement",
		{"movement": true, "enemy": true}, [{"wait_ms": 1}], "fp")
	var planned: Dictionary = _plan(["gameplay_feature"], "Make the enemy slower so the game is easier.")
	assert_false(planned.has("error"), planned.get("error", ""))
	var plan_doc: Dictionary = _tools._load_plan(_plan_path)
	var task: Dictionary = _create_script_task_from(plan_doc)
	var arguments: Dictionary = _tools._derive_step_arguments(
		plan_doc, task, "create_script", _tools._resolve_inputs(task, {}, false))
	var content: String = String(arguments.get("content", ""))
	assert_true(content.contains("extends CharacterBody2D"),
		"a tuning goal on a fresh plan still generates a real controller (not an extends Node stub)")
	assert_true(content.contains("const ENEMY_SPEED"),
		"the tuned parameter exists in the merged controller")

func test_tune_apply_derives_modify_script_arguments() -> void:
	# 真缺陷回归：tune_apply 分支曾被缩进吞进 upsert 分支体内——
	# modify_script 步骤永远派生不出 content（目标卡在 needs_input）。
	var script_path: String = "user://tune_target_%s.gd" % str(get_instance_id())
	var absolute: String = ProjectSettings.globalize_path(script_path)
	var file: FileAccess = FileAccess.open(absolute, FileAccess.WRITE)
	file.store_string("const ENEMY_SPEED: float = 120.0\n")
	file.close()
	var plan: Dictionary = {"goal": "Make the enemy slower so the game is easier.",
		"workflow": {"artifacts": {"script": script_path}}}
	var task: Dictionary = {"tool_name": "modify_script", "step_key": "tune_apply",
		"profile": "gameplay_feature"}
	var arguments: Dictionary = _tools._derive_step_arguments(plan, task, "modify_script", {})
	assert_true(arguments.has("content"), "tune_apply derives its modify content")
	assert_eq(String(arguments.get("old_text", "")), "const ENEMY_SPEED: float = 120.0",
		"old_text reads the current value from disk truth")
	assert_eq(String(arguments.get("content", "")), "const ENEMY_SPEED: float = 78.0",
		"content applies the slower direction (x0.65)")
	DirAccess.remove_absolute(absolute)

func test_merged_objective_total_request_never_shrinks() -> void:
	GameModelStoreScript.save_model({"counts": {"coins": 3}})
	var merged: String = _tools._build_merged_objective({"collectible": true}, "Add a coin.")
	assert_true(merged.contains("collect 3 coins"),
		"a total request keeps the existing 3 (got: %s)" % merged)

func test_merged_content_parses_model_counts() -> void:
	# 端到端：注册表有移动功能 + 模型记 3 金币 → 新目标的合并源码
	# 必须生成 COINS_TO_WIN = 3（数量不再被合并吞掉）
	FeatureRegistryScript.record_feature("Arrow-key player movement",
		{"movement": true}, [{"wait_ms": 1}], "fp")
	GameModelStoreScript.save_model({"counts": {"coins": 3}})
	var planned: Dictionary = _plan(["gameplay_feature"], "Add 3 collectible coins.")
	assert_false(planned.has("error"), planned.get("error", ""))
	var plan_doc: Dictionary = _tools._load_plan(_plan_path)
	var task: Dictionary = _create_script_task_from(plan_doc)
	assert_false(task.is_empty(), "gameplay profile has a create_script step")
	var arguments: Dictionary = _tools._derive_step_arguments(
		plan_doc, task, "create_script", _tools._resolve_inputs(task, {}, false))
	var content: String = String(arguments.get("content", ""))
	assert_true(content.contains("const COINS_TO_WIN: int = 3"),
		"merged controller keeps three coins (cumulative-merge with model counts)")
	assert_eq(String(task.get("derived_inputs", {}).get("content", "")), "cumulative-merge")

func test_state_machine_survives_cumulative_merge() -> void:
	# 旧实现直接 erase state_machine——"加完标题屏再加玩法"失去标题流程
	FeatureRegistryScript.record_feature("title screen game flow",
		{"state_machine": true, "movement": true, "collectible": true}, [{"wait_ms": 1}], "fp")
	var planned: Dictionary = _plan(["gameplay_feature"], "Add a pause menu.")
	assert_false(planned.has("error"), planned.get("error", ""))
	var plan_doc: Dictionary = _tools._load_plan(_plan_path)
	var task: Dictionary = _create_script_task_from(plan_doc)
	var arguments: Dictionary = _tools._derive_step_arguments(
		plan_doc, task, "create_script", _tools._resolve_inputs(task, {}, false))
	var content: String = String(arguments.get("content", ""))
	assert_true(content.contains("_title_label"),
		"merged controller keeps the title screen when the goal does not mention it")

func test_user_edit_conflict_blocks_regeneration() -> void:
	var script_path: String = "user://protection_controller_%s.gd" % str(get_instance_id())
	var absolute: String = ProjectSettings.globalize_path(script_path)
	var file: FileAccess = FileAccess.open(absolute, FileAccess.WRITE)
	file.store_string("# controller v1\n")
	file.close()
	GameModelStoreScript.apply_completion("movement goal", {"movement": true},
		script_path, "# controller v1\n")
	FeatureRegistryScript.record_feature("Arrow-key movement", {"movement": true},
		[{"wait_ms": 1}], "fp")
	# 用户手改（指纹漂移）
	var edit: FileAccess = FileAccess.open(absolute, FileAccess.WRITE)
	edit.store_string("# controller v1 + user tweaks\n")
	edit.close()
	var planned: Dictionary = _plan(["gameplay_feature"], "Add 3 collectible coins.")
	assert_false(planned.has("error"), planned.get("error", ""))
	var plan_doc: Dictionary = _tools._load_plan(_plan_path)
	(plan_doc["workflow"] as Dictionary)["artifacts"] = {"script": script_path}
	var task: Dictionary = _create_script_task_from(plan_doc)
	var arguments: Dictionary = _tools._derive_step_arguments(
		plan_doc, task, "create_script", _tools._resolve_inputs(task, {}, false))
	assert_true(task.has("protection_conflict"),
		"fingerprint drift blocks cumulative regeneration")
	assert_false(arguments.has("content"), "no overwrite content derived")
	assert_true(String((task["protection_conflict"] as Dictionary).get("reason", "")).contains("user edits"),
		"conflict reason explains the manual-edit detection")
	DirAccess.remove_absolute(absolute)

func test_enemy_tune_verify_asserts_live_parameter() -> void:
	# P2-1 v2：验证步断言 ENEMY_SPEED == 计划新值——运行中的游戏仍持旧值
	# （"调了没变"）必然失败，且相位免疫（取代峰顶饱和的振幅对比）。
	FeatureRegistryScript.record_feature("patrolling enemy",
		{"enemy": true}, [{"wait_ms": 1}], "fp")
	var plan: Dictionary = {"goal": "Make the enemy slower so the game is easier.",
		"workflow": {"artifacts": {"tune_planned": {"param": "ENEMY_SPEED", "old": 120.0, "new": 78.0}}}}
	var task: Dictionary = {"tool_name": "play_and_verify", "step_key": "tune_verify",
		"profile": "gameplay_feature"}
	var arguments: Dictionary = _tools._derive_step_arguments(plan, task, "play_and_verify", {})
	var steps: Array = arguments.get("steps", [])
	var expressions: Array = []
	for step_value in steps:
		var step: Dictionary = step_value
		if step.has("assert"):
			expressions.append(String((step["assert"] as Dictionary).get("expression", "")))
	assert_true(expressions.has("ENEMY_SPEED"),
		"the live parameter is asserted in the running game (got %s)" % str(expressions))
	var live_assert: Dictionary = {}
	for step_value in steps:
		var step: Dictionary = step_value
		if step.has("assert") and String((step["assert"] as Dictionary).get("expression", "")) == "ENEMY_SPEED":
			live_assert = step["assert"]
	assert_eq(float(live_assert.get("expected", 0.0)), 78.0,
		"the expected value is the planned new speed")
	assert_true(expressions.has("abs(_enemy.position.x - 300.0)"),
		"patrol-alive behavior is still asserted")

func test_prior_regression_failure_blocks_completion() -> void:
	FeatureRegistryScript.record_feature("Arrow-key player movement",
		{"movement": true}, [{"wait_ms": 1}], "fp")
	_core.responses["run_project"] = {"status": "ok"}
	_core.responses["play_and_verify"] = {"passed": false,
		"assertions": [{"description": "player moved right while holding move_right", "passed": false}]}
	var plan: Dictionary = {"goal": "Add a pause menu.", "workflow": {"workflow_id": "w1"}}
	var regression: Dictionary = await _tools._run_prior_feature_regression(plan)
	assert_true(bool(regression.get("failed", false)),
		"a failed prior exercise marks the regression failed")
	assert_true(String(regression.get("reason", "")).contains("player moved right"),
		"the failing assertion is surfaced in the reason")
	# 授权结构校验（真缺陷：空 step_id 会被 invoke_planned_tool 拒绝，
	# 回归门禁因此从未真正执行过演练）；且必须先 stop 再 run——直接
	# run_project 会复用残留游戏（真机复现：回归在 x=4782 的陈旧会话上跑）
	assert_eq(str(_core.calls[0]["tool_name"]), "stop_project",
		"the gate stops any stale game first")
	assert_eq(str(_core.calls[0]["authorization"].get("step_id", "")), "prior_regression_stop",
		"stop carries a non-empty synthetic step_id")
	assert_eq(str(_core.calls[1]["tool_name"]), "run_project",
		"a fresh game is launched for the regression")
	assert_eq(str(_core.calls[2]["tool_name"]), "play_and_verify",
		"the prior exercise ran through play_and_verify")
	assert_eq(str(_core.calls[2]["authorization"].get("authorized_tool", "")), "play_and_verify",
		"authorization matches the invoked tool")

func test_prior_regression_success_allows_completion() -> void:
	FeatureRegistryScript.record_feature("Arrow-key player movement",
		{"movement": true}, [{"wait_ms": 1}], "fp")
	_core.responses["run_project"] = {"status": "ok"}
	_core.responses["play_and_verify"] = {"passed": true, "assertions": []}
	var plan: Dictionary = {"goal": "Add a pause menu.", "workflow": {"workflow_id": "w1"}}
	var regression: Dictionary = await _tools._run_prior_feature_regression(plan)
	assert_false(bool(regression.get("failed", true)),
		"passing prior exercises do not block completion")
	assert_eq((regression.get("checked", []) as Array).size(), 1, "one prior feature checked")

func test_prior_regression_skips_current_goal_verbs() -> void:
	FeatureRegistryScript.record_feature("Arrow-key player movement",
		{"movement": true}, [{"wait_ms": 1}], "fp")
	FeatureRegistryScript.record_feature("Patrolling enemy",
		{"enemy": true}, [{"wait_ms": 1}], "fp2")
	_core.responses["run_project"] = {"status": "ok"}
	_core.responses["play_and_verify"] = {"passed": true, "assertions": []}
	var plan: Dictionary = {"goal": "Improve the patrolling enemy.",
		"workflow": {"workflow_id": "w1"}}
	var regression: Dictionary = await _tools._run_prior_feature_regression(plan)
	assert_eq((regression.get("checked", []) as Array).size(), 1,
		"the enemy feature is excluded (current goal touches it); only movement re-verifies")

func test_state_play_steps_cover_full_two_round_loop() -> void:
	var steps: Array = _tools._state_play_steps()
	var expressions: PackedStringArray = []
	for step_value in steps:
		var step: Dictionary = step_value
		if step.has("assert"):
			var assertion: Dictionary = step["assert"]
			expressions.append("%s == %s" % [String(assertion.get("expression", "")),
				str(assertion.get("expected", ""))])
	var joined: String = ";".join(expressions)
	assert_true(joined.contains("coins_collected == COINS_TO_WIN"),
		"full collection is asserted")
	assert_true(joined.contains("game_state") and joined.contains("win"),
		"the win state is asserted")
	assert_true(joined.contains("game_state == title"),
		"the restart-to-title transition is asserted")
	assert_true(joined.contains("abs(position.x) < 20"),
		"the origin reset is asserted (racy counter observable replaced)")
	assert_true(joined.contains("game_state == playing"),
		"the second-round start is asserted")
	assert_true(joined.to_lower().contains("and game_state"),
		"the second-round full win is asserted")

func test_tune_steps_unlock_title_when_state_machine_registered() -> void:
	FeatureRegistryScript.record_feature("title screen game flow",
		{"state_machine": true}, [{"wait_ms": 1}], "fp")
	var plan: Dictionary = {"goal": "Make the player faster and snappier.", "workflow": {}}
	var task: Dictionary = {"tool_name": "play_and_verify", "step_key": "tune_baseline",
		"profile": "gameplay_feature"}
	var arguments: Dictionary = _tools._derive_step_arguments(plan, task, "play_and_verify", {})
	var steps: Array = arguments.get("steps", [])
	assert_gt(steps.size(), 0, "tune baseline derives steps")
	assert_eq(String((steps[0] as Dictionary).get("action", "")), "ui_accept",
		"the first step unlocks the title gate before measuring")
	assert_eq(String((steps[2] as Dictionary).get("action", "")), "ui_accept",
		"double Enter covers a win-state start")
func test_verify_gate_repair_dead_end_fails_fast() -> void:
	# 真缺陷回归：play 门禁失败后 repair=modify_script 派生不出 content
	# → 卡 waiting 63s 直到超时（goal 06 现场复现）。验证类失败应快速
	# replan 而非挂起。
	var plan: Dictionary = _plan(["gameplay_feature"], "Arrow-key movement and a coin.")
	assert_false(plan.has("error"), plan.get("error", ""))
	var plan_doc: Dictionary = _tools._load_plan(_plan_path)
	var verify_task: Dictionary = {}
	for task_value in plan_doc.get("tasks", []):
		var task: Dictionary = task_value
		if String(task.get("tool_name", "")) == "play_and_verify":
			verify_task = task
			break
	assert_false(verify_task.is_empty(), "gameplay plan has a play gate")
	# 真实服务端的 modify_script 要求 content（FakeCore 默认无 required）
	_core.schemas["modify_script"] = {"type": "object",
		"required": ["script_path", "old_text", "content"], "properties": {}}
	verify_task["repair_pending"] = true
	verify_task["repair_tool"] = "modify_script"
	# modify_script 的 content 无从派生（演练失败没有代码修复语义）
	var outcome: Dictionary = await _tools._run_repair(plan_doc, verify_task, {}, _plan_path)
	assert_eq(str(outcome.get("status", "")), "replan_required",
		"an underivable verify repair fails fast instead of waiting")
	assert_eq(str((plan_doc["workflow"] as Dictionary).get("state", "")), "replan_required",
		"the workflow state moves to replan_required")
	assert_true(str((plan_doc["workflow"] as Dictionary).get("blocked_reason", "")).contains("verification gate"),
		"the blocked reason explains the verify-gate dead end")
