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

func after_each() -> void:
	_remove_plan()

func _remove_plan() -> void:
	var absolute: String = ProjectSettings.globalize_path(_plan_path)
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
	assert_eq(int((result.get("metrics", {}) as Dictionary).get("atomic_calls", 0)), _core.calls.size())

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
		"plan_path": _plan_path, "expected_workflow_id": planned["workflow_id"], "max_steps": 4
	})
	assert_eq(result.get("status", ""), "needs_input")
	assert_eq(_core.calls.size(), 2, "Only the two no-input inspections run before the missing build input")
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
		"max_steps": 1,
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
		"max_steps": 5,
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
	assert_eq(String((visual_call.get("arguments", {}) as Dictionary).get("baseline_path", "")),
		"user://visual_baselines/mcp_runtime_capture.jpg",
		"Visual gate baseline derives a deterministic golden-image location")

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
