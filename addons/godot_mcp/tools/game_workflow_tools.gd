@tool
class_name GameWorkflowTools
extends RefCounted

## Two compact, always-on meta tools for complete game-production loops.
##
## `plan_game_workflow` compiles/resumes a durable goal contract. The runner
## executes only structurally authorized atomic steps through MCPServerCore's
## internal path, so hidden supplementary tools remain available without
## expanding tools/list or changing visibility state.

const EngineScript = preload("res://addons/godot_mcp/native_mcp/game_workflow_engine.gd")
const TaskPlanStoreScript = preload("res://addons/godot_mcp/tools/task_plan_store.gd")

const DEFAULT_PLAN_PATH: String = "res://.mcp/task_plan.json"
const PLAN_ACTIONS: Array[String] = ["plan", "status", "replan", "cancel"]

var _server_core: RefCounted = null
var _engine: RefCounted = EngineScript.new()

func initialize(_editor_interface: EditorInterface) -> void:
	pass

func register_tools(server_core: RefCounted) -> void:
	_server_core = server_core
	_register_plan_tool(server_core)
	_register_run_tool(server_core)

func _register_plan_tool(server_core: RefCounted) -> void:
	server_core.register_tool(
		"plan_game_workflow",
		"Compile or resume a durable complete-game DAG from 12 composable profiles. Unknown goals and missing capabilities block; status, replan and cancel preserve explicit control.",
		{
			"type": "object",
			"properties": {
				"action": {"type": "string", "enum": PLAN_ACTIONS, "default": "plan"},
				"objective": {"type": "string"},
				"profiles": {"type": "array", "items": {"type": "string", "enum": EngineScript.PROFILE_IDS}},
				"required_capabilities": {"type": "array", "items": {"type": "string"}},
				"platform": {"type": "string"},
				"max_repair_attempts": {"type": "integer", "default": EngineScript.DEFAULT_REPAIR_ATTEMPTS},
				"protected_paths": {"type": "array", "items": {"type": "string"}},
				"plan_path": {"type": "string", "default": DEFAULT_PLAN_PATH},
				"replace": {"type": "boolean", "default": false},
				"expected_workflow_id": {"type": "string"},
				"include_plan": {"type": "boolean", "default": false}
			},
			"required": ["action"]
		},
		Callable(self, "_tool_plan_game_workflow"),
		{
			"type": "object",
			"properties": {
				"status": {"type": "string"},
				"workflow_id": {"type": "string"},
				"state": {"type": "string"},
				"objective": {"type": "string"},
				"profiles": {"type": "array"},
				"progress": {"type": "object"},
				"ready": {"type": "array"},
				"needs_input": {"type": "array"},
				"plan_path": {"type": "string"},
				"plan": {"type": "object"}
			}
		},
		{"readOnlyHint": false, "destructiveHint": false, "idempotentHint": false, "openWorldHint": false},
		"meta", "Meta"
	)

func _register_run_tool(server_core: RefCounted) -> void:
	server_core.register_tool(
		"run_game_workflow",
		"Advance at most four authorized DAG steps. Polls async work, preserves caches, enforces protected paths and integrity, bounds repairs, and requires objective evidence for completion.",
		{
			"type": "object",
			"properties": {
				"plan_path": {"type": "string", "default": DEFAULT_PLAN_PATH},
				"expected_workflow_id": {"type": "string"},
				"max_steps": {"type": "integer", "default": EngineScript.MAX_STEPS_PER_RUN},
				"step_inputs": {"type": "object", "description": "Ephemeral arguments keyed by step id, '<id>:repair', or exact tool name."}
			}
		},
		Callable(self, "_tool_run_game_workflow"),
		{
			"type": "object",
			"properties": {
				"status": {"type": "string"},
				"workflow_id": {"type": "string"},
				"state": {"type": "string"},
				"executed": {"type": "array"},
				"progress": {"type": "object"},
				"ready": {"type": "array"},
				"step_id": {"type": "string"},
				"tool_name": {"type": "string"},
				"missing_inputs": {"type": "array"},
				"blocked_reason": {"type": "string"}
			}
		},
		{"readOnlyHint": false, "destructiveHint": false, "idempotentHint": false, "openWorldHint": false},
		"meta", "Meta"
	)

func _tool_plan_game_workflow(params: Dictionary) -> Dictionary:
	if _server_core == null:
		return {"error": "Server core is not available"}
	var action: String = String(params.get("action", "plan")).strip_edges().to_lower()
	if not action in PLAN_ACTIONS:
		return {"error": "Unknown workflow action '%s'" % action}
	var path_result: Dictionary = _normalize_plan_path(String(params.get("plan_path", DEFAULT_PLAN_PATH)))
	if path_result.has("error"):
		return path_result
	var plan_path: String = path_result["path"]
	var available_tools: Array[String] = _available_tool_names()

	if action == "status":
		var loaded_status: Dictionary = _load_plan(plan_path)
		if loaded_status.has("error"):
			return loaded_status
		var status_integrity: Dictionary = _engine.validate_integrity(loaded_status, available_tools)
		if status_integrity.has("error"):
			return status_integrity
		var status_result: Dictionary = _engine.summarize(loaded_status)
		status_result["status"] = "ok"
		status_result["plan_path"] = plan_path
		if bool(params.get("include_plan", false)):
			status_result["plan"] = loaded_status
		return status_result

	if action == "cancel":
		var cancel_plan: Dictionary = _load_plan(plan_path)
		if cancel_plan.has("error"):
			return cancel_plan
		var cancel_cas: Dictionary = _check_expected_workflow(cancel_plan, params)
		if cancel_cas.has("error"):
			return cancel_cas
		(cancel_plan["workflow"] as Dictionary)["state"] = "cancelled"
		(cancel_plan["workflow"] as Dictionary)["blocked_reason"] = "Cancelled by the client"
		for task_value in cancel_plan.get("tasks", []):
			var task: Dictionary = task_value
			if String(task.get("status", "")) in ["pending", "in_progress"]:
				task["status"] = "blocked"
		var cancel_save: Dictionary = TaskPlanStoreScript.save_plan(cancel_plan, plan_path)
		if cancel_save.has("error"):
			return cancel_save
		var cancel_result: Dictionary = _engine.summarize(cancel_plan)
		cancel_result["status"] = "cancelled"
		cancel_result["plan_path"] = plan_path
		return cancel_result

	var existing_plan: Dictionary = {}
	if TaskPlanStoreScript.plan_exists(plan_path):
		existing_plan = _load_plan(plan_path)
		if existing_plan.has("error"):
			return existing_plan
	if action == "plan" and not existing_plan.is_empty() and not bool(params.get("replace", false)):
		return {
			"error": "A plan already exists at '%s'; use status/replan or set replace=true" % plan_path,
			"status": "conflict",
			"plan_path": plan_path
		}
	if action == "replan":
		if existing_plan.is_empty():
			return {"error": "No existing workflow to replan at '%s'" % plan_path}
		var replan_cas: Dictionary = _check_expected_workflow(existing_plan, params)
		if replan_cas.has("error"):
			return replan_cas

	var objective: String = String(params.get("objective", "")).strip_edges()
	var compile_options: Dictionary = {}
	for key in ["profiles", "required_capabilities", "platform", "max_repair_attempts", "protected_paths"]:
		if params.has(key):
			compile_options[key] = params[key]
	if action == "replan":
		var old_contract: Dictionary = (existing_plan.get("workflow", {}) as Dictionary).get("goal_contract", {})
		if objective.is_empty():
			objective = String(old_contract.get("objective", existing_plan.get("goal", "")))
		for key in ["profiles", "required_capabilities", "platform", "max_repair_attempts", "protected_paths"]:
			if not compile_options.has(key) and old_contract.has(key):
				compile_options[key] = old_contract[key]
	var compiled: Dictionary = _engine.compile(objective, compile_options, available_tools)
	if compiled.has("error"):
		compiled["plan_path"] = plan_path
		return compiled
	var plan: Dictionary = compiled["plan"]
	var save_result: Dictionary = TaskPlanStoreScript.save_plan(plan, plan_path)
	if save_result.has("error"):
		return save_result
	var summary: Dictionary = _engine.summarize(plan)
	summary["status"] = "planned"
	summary["plan_path"] = plan_path
	if bool(params.get("include_plan", false)):
		summary["plan"] = plan
	return summary

func _tool_run_game_workflow(params: Dictionary) -> Dictionary:
	if _server_core == null or not _server_core.has_method("invoke_planned_tool"):
		return {"error": "Server core does not support authorized workflow execution"}
	var path_result: Dictionary = _normalize_plan_path(String(params.get("plan_path", DEFAULT_PLAN_PATH)))
	if path_result.has("error"):
		return path_result
	var plan_path: String = path_result["path"]
	var plan: Dictionary = _load_plan(plan_path)
	if plan.has("error"):
		return plan
	var available_tools: Array[String] = _available_tool_names()
	var integrity: Dictionary = _engine.validate_integrity(plan, available_tools)
	if integrity.has("error"):
		integrity["status"] = "blocked"
		integrity["plan_path"] = plan_path
		return integrity
	var cas: Dictionary = _check_expected_workflow(plan, params)
	if cas.has("error"):
		return cas
	var workflow: Dictionary = plan["workflow"]
	var state: String = String(workflow.get("state", ""))
	if state in ["cancelled", "completed"]:
		var terminal: Dictionary = _engine.summarize(plan)
		terminal["status"] = state
		terminal["plan_path"] = plan_path
		return terminal

	# A persisted in-progress step means the process stopped after dispatch but
	# before recording evidence. Re-running a mutation could duplicate effects,
	# so fail closed and require status inspection/replan instead of guessing.
	for task_value in plan.get("tasks", []):
		var uncertain_task: Dictionary = task_value
		if String(uncertain_task.get("status", "")) == "in_progress" or bool(uncertain_task.get("repair_in_progress", false)):
			workflow["state"] = "blocked"
			workflow["blocked_reason"] = "A previously dispatched step has an unknown outcome; inspect the project and replan"
			var uncertain_save: Dictionary = TaskPlanStoreScript.save_plan(plan, plan_path)
			if uncertain_save.has("error"):
				return uncertain_save
			var uncertain: Dictionary = _engine.summarize(plan)
			uncertain["status"] = "recovery_required"
			uncertain["step_id"] = uncertain_task.get("id", "")
			uncertain["tool_name"] = uncertain_task.get("tool_name", "")
			uncertain["plan_path"] = plan_path
			return uncertain

	var max_steps: int = clampi(int(params.get("max_steps", EngineScript.MAX_STEPS_PER_RUN)), 1, EngineScript.MAX_STEPS_PER_RUN)
	var step_inputs: Dictionary = params.get("step_inputs", {}) if params.get("step_inputs", {}) is Dictionary else {}
	var executed: Array[Dictionary] = []
	var atomic_calls: int = 0

	while atomic_calls < max_steps:
		var repair_task: Dictionary = _find_repair_pending(plan)
		if not repair_task.is_empty():
			var repair_outcome: Dictionary = await _run_repair(plan, repair_task, step_inputs, plan_path)
			if repair_outcome.has("executed"):
				executed.append(repair_outcome["executed"])
				atomic_calls += 1
			if repair_outcome.get("stop", false):
				return _runner_response(plan, plan_path, String(repair_outcome.get("status", "blocked")), executed, repair_outcome)
			continue

		var ready: Array[Dictionary] = _engine.ready_steps(plan, 1)
		if ready.is_empty():
			break
		var task: Dictionary = ready[0]
		var tool_name: String = String(task.get("tool_name", ""))
		var arguments: Dictionary = _resolve_inputs(task, step_inputs, false)
		var missing: Array[String] = _missing_required_inputs(tool_name, arguments)
		if not missing.is_empty():
			task["needs_input"] = true
			task["missing_inputs"] = missing
			workflow["state"] = "waiting"
			workflow["blocked_reason"] = "Current step needs schema-required inputs"
			var input_save: Dictionary = TaskPlanStoreScript.save_plan(plan, plan_path)
			if input_save.has("error"):
				return input_save
			return _runner_response(plan, plan_path, "needs_input", executed, {
				"step_id": task.get("id", ""), "tool_name": tool_name, "missing_inputs": missing
			})
		var allowed: Dictionary = _engine.arguments_allowed(plan, arguments)
		if allowed.has("error"):
			task["status"] = "blocked"
			workflow["state"] = "blocked"
			workflow["blocked_reason"] = String(allowed["error"])
			var blocked_save: Dictionary = TaskPlanStoreScript.save_plan(plan, plan_path)
			if blocked_save.has("error"):
				return blocked_save
			allowed["step_id"] = task.get("id", "")
			allowed["tool_name"] = tool_name
			return _runner_response(plan, plan_path, "blocked", executed, allowed)

		task.erase("needs_input")
		task.erase("missing_inputs")
		task["status"] = "in_progress"
		workflow["state"] = "running"
		workflow["blocked_reason"] = ""
		var before_save: Dictionary = TaskPlanStoreScript.save_plan(plan, plan_path)
		if before_save.has("error"):
			return before_save
		var authorization: Dictionary = _authorization(plan, task, false)
		var raw_result: Variant = await _server_core.invoke_planned_tool(tool_name, arguments, authorization)
		atomic_calls += 1
		var verdict: Dictionary = _engine.record_step_result(plan, String(task.get("id", "")), raw_result)
		executed.append({
			"step_id": task.get("id", ""),
			"tool_name": tool_name,
			"status": verdict.get("status", ""),
			"receipt_digest": (verdict.get("receipt", {}) as Dictionary).get("digest", "")
		})
		var after_save: Dictionary = TaskPlanStoreScript.save_plan(plan, plan_path)
		if after_save.has("error"):
			return after_save
		if verdict.has("error"):
			return _runner_response(plan, plan_path, "blocked", executed, verdict)
		if String(verdict.get("status", "")) == "waiting":
			return _runner_response(plan, plan_path, "waiting", executed, verdict)
		if String(verdict.get("status", "")) == "blocked":
			return _runner_response(plan, plan_path, "blocked", executed, verdict)
		# repair_required is handled at the start of the next loop iteration if
		# this round still has atomic-call budget; otherwise it remains durable.

	var final_state: String = String((plan.get("workflow", {}) as Dictionary).get("state", "running"))
	var final_status: String = "completed" if final_state == "completed" else final_state
	if final_status in ["planned", ""]:
		final_status = "running"
	return _runner_response(plan, plan_path, final_status, executed)

func _run_repair(plan: Dictionary, task: Dictionary, step_inputs: Dictionary, plan_path: String) -> Dictionary:
	var repair_tool: String = String(task.get("repair_tool", ""))
	var arguments: Dictionary = _resolve_inputs(task, step_inputs, true)
	var missing: Array[String] = _missing_required_inputs(repair_tool, arguments)
	if not missing.is_empty():
		task["needs_input"] = true
		task["missing_inputs"] = missing
		(plan["workflow"] as Dictionary)["state"] = "waiting"
		(plan["workflow"] as Dictionary)["blocked_reason"] = "Authorized repair needs schema-required inputs"
		var missing_save: Dictionary = TaskPlanStoreScript.save_plan(plan, plan_path)
		if missing_save.has("error"):
			return {"stop": true, "status": "blocked", "error": missing_save["error"]}
		return {
			"stop": true, "status": "needs_input", "step_id": task.get("id", ""),
			"tool_name": repair_tool, "repair": true, "missing_inputs": missing
		}
	var allowed: Dictionary = _engine.arguments_allowed(plan, arguments)
	if allowed.has("error"):
		task["status"] = "blocked"
		task["repair_pending"] = false
		(plan["workflow"] as Dictionary)["state"] = "blocked"
		(plan["workflow"] as Dictionary)["blocked_reason"] = String(allowed["error"])
		var protected_save: Dictionary = TaskPlanStoreScript.save_plan(plan, plan_path)
		if protected_save.has("error"):
			return {"stop": true, "status": "blocked", "error": protected_save["error"]}
		return {
			"stop": true, "status": "blocked", "step_id": task.get("id", ""),
			"tool_name": repair_tool, "error": allowed["error"],
			"protected_paths": allowed.get("protected_paths", [])
		}
	task["repair_in_progress"] = true
	(plan["workflow"] as Dictionary)["state"] = "running"
	var before_save: Dictionary = TaskPlanStoreScript.save_plan(plan, plan_path)
	if before_save.has("error"):
		task.erase("repair_in_progress")
		return {"stop": true, "status": "blocked", "error": before_save["error"]}
	var raw_result: Variant = await _server_core.invoke_planned_tool(
		repair_tool, arguments, _authorization(plan, task, true))
	task.erase("repair_in_progress")
	var verdict: Dictionary = _engine.record_repair_result(plan, String(task.get("id", "")), raw_result)
	var save_result: Dictionary = TaskPlanStoreScript.save_plan(plan, plan_path)
	if save_result.has("error"):
		return {"stop": true, "status": "blocked", "error": save_result["error"]}
	return {
		"stop": String(verdict.get("status", "")) == "blocked",
		"status": verdict.get("status", ""),
		"executed": {
			"step_id": task.get("id", ""), "tool_name": repair_tool,
			"repair": true, "status": verdict.get("status", ""),
			"receipt_digest": (verdict.get("receipt", {}) as Dictionary).get("digest", "")
		}
	}

func _resolve_inputs(task: Dictionary, step_inputs: Dictionary, repair: bool) -> Dictionary:
	var arguments: Dictionary = {}
	var tool_name: String = String(task.get("repair_tool" if repair else "tool_name", ""))
	var step_key: String = String(task.get("id", "")) + (":repair" if repair else "")
	if step_inputs.get(tool_name) is Dictionary:
		arguments.merge((step_inputs[tool_name] as Dictionary).duplicate(true), true)
	if step_inputs.get(step_key) is Dictionary:
		arguments.merge((step_inputs[step_key] as Dictionary).duplicate(true), true)
	if not repair:
		# Plan-owned arguments (for example manage_localization.action) override
		# ephemeral input so a caller cannot change the authorized operation.
		arguments.merge((task.get("arguments", {}) as Dictionary).duplicate(true), true)
	return arguments

func _missing_required_inputs(tool_name: String, arguments: Dictionary) -> Array[String]:
	var schema: Dictionary = {}
	if _server_core.has_method("get_tool_input_schema"):
		schema = _server_core.get_tool_input_schema(tool_name)
	elif _server_core.has_method("get_tool"):
		var tool: Variant = _server_core.get_tool(tool_name)
		if tool != null:
			schema = tool.input_schema
	var missing: Array[String] = []
	for required_value in schema.get("required", []):
		var required_name: String = String(required_value)
		if not arguments.has(required_name):
			missing.append(required_name)
		elif arguments[required_name] is String and String(arguments[required_name]).strip_edges().is_empty():
			missing.append(required_name)
	return missing

func _find_repair_pending(plan: Dictionary) -> Dictionary:
	for task_value in plan.get("tasks", []):
		var task: Dictionary = task_value
		if bool(task.get("repair_pending", false)):
			return task
	return {}

func _authorization(plan: Dictionary, task: Dictionary, repair: bool) -> Dictionary:
	var workflow: Dictionary = plan.get("workflow", {})
	return {
		"kind": "game_workflow",
		"workflow_id": workflow.get("workflow_id", ""),
		"blueprint_hash": workflow.get("blueprint_hash", ""),
		"step_id": task.get("id", ""),
		"authorized_tool": task.get("repair_tool" if repair else "tool_name", ""),
		"repair": repair
	}

func _runner_response(plan: Dictionary, plan_path: String, status: String,
		executed: Array[Dictionary], extra: Dictionary = {}) -> Dictionary:
	var response: Dictionary = _engine.summarize(plan)
	response["status"] = status
	response["plan_path"] = plan_path
	response["executed"] = executed
	for key in extra:
		if key not in ["stop", "executed", "workflow", "receipt"]:
			response[key] = extra[key]
	return response

func _normalize_plan_path(raw_path: String) -> Dictionary:
	var plan_path: String = raw_path.strip_edges()
	if plan_path.is_empty():
		plan_path = DEFAULT_PLAN_PATH
	if not (plan_path.begins_with("res://") or plan_path.begins_with("user://")):
		return {"error": "plan_path must be a res:// or user:// path"}
	if plan_path.get_extension().to_lower() != "json":
		return {"error": "plan_path must end in .json"}
	var absolute: String = ProjectSettings.globalize_path(plan_path).simplify_path()
	var plugin_root: String = ProjectSettings.globalize_path("res://addons/godot_mcp").simplify_path().trim_suffix("/")
	if absolute == plugin_root or absolute.begins_with(plugin_root + "/"):
		return {"error": "plan_path cannot be inside the plugin source tree"}
	return {"path": plan_path}

func _load_plan(plan_path: String) -> Dictionary:
	var loaded: Dictionary = TaskPlanStoreScript.load_plan(plan_path)
	if loaded.has("error"):
		return loaded
	if not (loaded.get("workflow") is Dictionary):
		return {"error": "Plan at '%s' is not a game workflow" % plan_path}
	return loaded

func _check_expected_workflow(plan: Dictionary, params: Dictionary) -> Dictionary:
	var expected: String = String(params.get("expected_workflow_id", "")).strip_edges()
	if expected.is_empty():
		return {"status": "ok"}
	var actual: String = String((plan.get("workflow", {}) as Dictionary).get("workflow_id", ""))
	if expected != actual:
		return {
			"error": "Workflow changed: expected '%s', current '%s'" % [expected, actual],
			"status": "conflict",
			"workflow_id": actual
		}
	return {"status": "ok"}

func _available_tool_names() -> Array[String]:
	var names: Array[String] = []
	if _server_core == null or not _server_core.has_method("get_registered_tools"):
		return names
	for info_value in _server_core.get_registered_tools():
		var name: String = String((info_value as Dictionary).get("name", ""))
		if not name.is_empty() and not name in names:
			names.append(name)
	names.sort()
	return names
