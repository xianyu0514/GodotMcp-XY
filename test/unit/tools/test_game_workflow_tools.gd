extends "res://addons/gut/test.gd"

const WorkflowToolsScript = preload("res://addons/godot_mcp/tools/game_workflow_tools.gd")
const ManifestScript = preload("res://addons/godot_mcp/native_mcp/tools_manifest.gd")
const TaskPlanStoreScript = preload("res://addons/godot_mcp/tools/task_plan_store.gd")

class FakeCore extends RefCounted:
	var registrations: Dictionary = {}
	var schemas: Dictionary = {}
	var responses: Dictionary = {}
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
	_core.responses["list_project_tests"] = {"tests": [{"name": "smoke"}]}
	_core.responses["verify_scripts"] = {"total_checked": 2, "verified": 2, "failed": 0, "results": []}
	_core.responses["run_project_tests"] = [
		{"status": "pending", "job_id": "tests"},
		{"status": "passed", "total_count": 2, "passed_count": 2, "failed_count": 0}
	]
	var planned: Dictionary = _plan(["quality_assurance"])
	var first: Dictionary = await _tools._tool_run_game_workflow({
		"plan_path": _plan_path, "expected_workflow_id": planned["workflow_id"], "max_steps": 4
	})
	assert_eq(first.get("status", ""), "waiting", str(first.get("error", "")))
	assert_eq(_core.calls.size(), 3)
	assert_true(_core.calls.all(func(call: Dictionary) -> bool:
		return (call.get("authorization", {}) as Dictionary).get("kind", "") == "game_workflow"))
	var second: Dictionary = await _tools._tool_run_game_workflow({
		"plan_path": _plan_path, "expected_workflow_id": planned["workflow_id"], "max_steps": 4
	})
	assert_eq(second.get("status", ""), "completed", str(second.get("error", "")))
	assert_eq(_core.calls.size(), 4, "Polling reuses the same authorized step and arguments")

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
