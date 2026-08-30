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
const WorkflowRouterScript = preload("res://addons/godot_mcp/native_mcp/workflow_router.gd")

const DEFAULT_PLAN_PATH: String = "res://.mcp/task_plan.json"
const PLAN_ACTIONS: Array[String] = ["plan", "status", "replan", "cancel"]

# Workflow-authorized runtime tools: the objective already authorizes runtime
# verification, so the interactive window-policy prompt must not stall the run.
const RUNTIME_WINDOW_TOOLS: Array[String] = ["run_project", "stop_project"]

# Scene activation changes editor focus; plan-authorized opens must not stall
# on the interactive focus policy either. Key = tool, value = policy parameter.
const FOCUS_POLICY_TOOLS: Dictionary = {"open_scene": "allow_ui_focus"}

# Tools whose node writes target the currently edited scene. When the workflow
# knows which scene a profile created, the runner passes scene_path so the
# shared context guard activates exactly that scene (no silent cross-scene
# writes when multiple profiles create scenes in one goal).
const SCENE_SCOPED_TOOLS: Array[String] = [
	"create_node", "update_node_property", "delete_node", "set_anchor_preset",
	"attach_script", "save_scene", "set_tilemap_layer_cells"
]

# Schema-required input -> workflow artifact kind. Lets create -> configure
# chains (create_script -> attach_script, create_scene -> save_scene, ...)
# proceed autonomously instead of stopping on needs_input.
const DERIVED_INPUT_ARTIFACTS: Dictionary = {
	"script_path": "script",
	"scene_path": "scene",
	"theme_path": "theme",
	"tileset_path": "tileset",
	"animation_path": "animation",
	"animation_name": "animation_name",
	"test_path": "smoke_test",
	"search_path": "test_dir",
	"test_dir": "test_dir",
	"candidate_path": "screenshot"
}

var _server_core: RefCounted = null
var _engine: RefCounted = EngineScript.new()
var _workflow_router: RefCounted = WorkflowRouterScript.new()

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
				"expect_fail": {
					"type": "object",
					"description": "Map of objective-gate step key to true (for example {\"verify_scripts\": true}) to invert that gate's verdict. Use for fault-injection loops that must prove a detector fails.",
					"additionalProperties": {"type": "boolean"}
				},
				"max_repair_attempts": {
					"type": "integer", "default": EngineScript.DEFAULT_REPAIR_ATTEMPTS,
					"description": "0 adapts while failure evidence changes; a positive value is an explicit repair policy and requests replan when exhausted."
				},
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
		"Advance an adaptive authorized DAG slice. Budgets yield but never drop work; async waits, safe restart recovery, caches, protected paths, integrity and objective evidence remain enforced.",
		{
			"type": "object",
			"properties": {
				"plan_path": {"type": "string", "default": DEFAULT_PLAN_PATH},
				"expected_workflow_id": {"type": "string"},
				"max_steps": {"type": "integer", "default": 0, "description": "0 chooses an adaptive slice; a positive value controls only this call and never truncates the persisted goal."},
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
				"input_schema": {"type": "object"},
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
	var objective_supplied: bool = not objective.is_empty()
	var caller_mapped_capabilities: bool = (
		(params.get("profiles") is Array and not (params["profiles"] as Array).is_empty())
		or (params.get("required_capabilities") is Array
			and not (params["required_capabilities"] as Array).is_empty()))
	var compile_options: Dictionary = {}
	for key in ["profiles", "required_capabilities", "platform", "max_repair_attempts", "protected_paths"]:
		if params.has(key):
			compile_options[key] = params[key]
	var reuse_existing_mapping: bool = false
	if action == "replan":
		var old_contract: Dictionary = (existing_plan.get("workflow", {}) as Dictionary).get("goal_contract", {})
		var old_objective: String = String(old_contract.get("objective", existing_plan.get("goal", "")))
		if objective.is_empty():
			objective = old_objective
		var objective_changed: bool = objective_supplied and objective != old_objective
		reuse_existing_mapping = not objective_changed
		for key in ["profiles", "required_capabilities", "platform", "max_repair_attempts", "protected_paths"]:
			if objective_changed and key in ["profiles", "required_capabilities"]:
				continue
			if not compile_options.has(key) and old_contract.has(key):
				compile_options[key] = old_contract[key]
	var exact_mentions: Array[String] = _exact_atomic_mentions(objective, available_tools)
	_merge_required_capabilities(compile_options, exact_mentions)
	# Audit each semantic clause that is not already owned by one of the twelve
	# profiles. This catches mixed goals such as “create player movement; do an
	# unknown operation” instead of allowing the known first clause to hide the
	# uncovered second clause. Explicit caller mappings and unchanged replans are
	# trusted; otherwise schema-free clause routes may add more than ten names.
	if not caller_mapped_capabilities and not reuse_existing_mapping:
		var route_audit: Dictionary = _route_unprofiled_clauses(objective, available_tools)
		var uncovered: Array[String] = route_audit.get("uncovered_requirements", [])
		if not uncovered.is_empty():
			return {
				"error": "Objective contains requirements not covered by registered atomic capabilities: %s" % ", ".join(uncovered),
				"status": "needs_clarification",
				"uncovered_requirements": uncovered,
				"matched_capabilities": route_audit.get("capabilities", []),
				"supported_profiles": EngineScript.PROFILE_IDS,
				"plan_path": plan_path
			}
		_merge_required_capabilities(
			compile_options, route_audit.get("capabilities", []))
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
	if state in ["cancelled", "completed", "replan_required", "recovery_required"]:
		var terminal: Dictionary = _engine.summarize(plan)
		terminal["status"] = state
		terminal["plan_path"] = plan_path
		return terminal

	# A persisted read-only or idempotent step is safe to replay after restart.
	# Unknown mutations still fail closed because repeating them could duplicate
	# effects; this distinction improves recovery without weakening correctness.
	var recovered_safe_step: bool = false
	for task_value in plan.get("tasks", []):
		var uncertain_task: Dictionary = task_value
		if String(uncertain_task.get("status", "")) == "in_progress" or bool(uncertain_task.get("repair_in_progress", false)):
			var uncertain_is_repair: bool = bool(uncertain_task.get("repair_in_progress", false))
			var uncertain_tool: String = String(uncertain_task.get(
				"repair_tool" if uncertain_is_repair else "tool_name", ""))
			var traits: Dictionary = _tool_execution_traits(uncertain_tool)
			if bool(traits.get("read_only", false)) or bool(traits.get("idempotent", false)):
				if uncertain_is_repair:
					uncertain_task.erase("repair_in_progress")
					uncertain_task["repair_pending"] = true
					uncertain_task["status"] = "blocked"
				else:
					uncertain_task["status"] = "pending"
				_engine.append_receipt(plan, {
					"step_id": uncertain_task.get("id", ""),
					"tool_name": uncertain_tool,
					"recovered": true,
					"replay_safe": true
				})
				var recovery_metrics: Dictionary = _engine.workflow_metrics(plan)
				recovery_metrics["safe_recoveries"] = int(recovery_metrics.get("safe_recoveries", 0)) + 1
				recovered_safe_step = true
				continue
			workflow["state"] = "recovery_required"
			workflow["blocked_reason"] = "A previously dispatched non-idempotent step has an unknown outcome; inspect the project and replan"
			var uncertain_save: Dictionary = TaskPlanStoreScript.save_plan(plan, plan_path)
			if uncertain_save.has("error"):
				return uncertain_save
			var uncertain: Dictionary = _engine.summarize(plan)
			uncertain["status"] = "recovery_required"
			uncertain["step_id"] = uncertain_task.get("id", "")
			uncertain["tool_name"] = uncertain_task.get("tool_name", "")
			uncertain["plan_path"] = plan_path
			return uncertain
	if recovered_safe_step:
		workflow["state"] = "running"
		workflow["blocked_reason"] = ""
		var recovery_save: Dictionary = TaskPlanStoreScript.save_plan(plan, plan_path)
		if recovery_save.has("error"):
			return recovery_save

	var requested_steps: int = int(params.get("max_steps", 0))
	var max_steps: int = _engine.recommended_step_budget(plan, requested_steps)
	var step_inputs: Dictionary = params.get("step_inputs", {}) if params.get("step_inputs", {}) is Dictionary else {}
	var executed: Array[Dictionary] = []
	var atomic_calls: int = 0
	var metrics: Dictionary = _engine.workflow_metrics(plan)
	metrics["rounds"] = int(metrics.get("rounds", 0)) + 1

	while atomic_calls < max_steps:
		var repair_task: Dictionary = _find_repair_pending(plan)
		if not repair_task.is_empty():
			var repair_outcome: Dictionary = await _run_repair(plan, repair_task, step_inputs, plan_path)
			if repair_outcome.has("executed"):
				executed.append(repair_outcome["executed"])
				atomic_calls += 1
				metrics["atomic_calls"] = int(metrics.get("atomic_calls", 0)) + 1
			if repair_outcome.get("stop", false):
				return _runner_response(plan, plan_path, String(repair_outcome.get("status", "blocked")), executed, repair_outcome)
			continue

		var ready: Array[Dictionary] = _engine.ready_steps(plan, 1)
		if ready.is_empty():
			break
		var task: Dictionary = ready[0]
		var tool_name: String = String(task.get("tool_name", ""))
		var arguments: Dictionary = _derive_step_arguments(
			plan, task, tool_name, _resolve_inputs(task, step_inputs, false))
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
				"step_id": task.get("id", ""), "tool_name": tool_name,
				"missing_inputs": missing, "input_schema": _tool_input_schema(tool_name)
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
		metrics["atomic_calls"] = int(metrics.get("atomic_calls", 0)) + 1
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
		if String(verdict.get("status", "")) in ["waiting", "blocked", "recovery_required", "replan_required"]:
			return _runner_response(plan, plan_path, String(verdict.get("status", "")), executed, verdict)
		# repair_required is handled at the start of the next loop iteration if
		# this round still has atomic-call budget; otherwise it remains durable.

	var final_state: String = String((plan.get("workflow", {}) as Dictionary).get("state", "running"))
	var final_status: String = "completed" if final_state == "completed" else final_state
	if final_status in ["planned", ""]:
		final_status = "running"
	var final_extra: Dictionary = {}
	if final_status != "completed" and atomic_calls >= max_steps:
		metrics["yield_count"] = int(metrics.get("yield_count", 0)) + 1
		final_extra["yield_reason"] = "execution_slice_complete"
		final_extra["resume_safe"] = true
		var yield_save: Dictionary = TaskPlanStoreScript.save_plan(plan, plan_path)
		if yield_save.has("error"):
			return yield_save
	return _runner_response(plan, plan_path, final_status, executed, final_extra)

func _run_repair(plan: Dictionary, task: Dictionary, step_inputs: Dictionary, plan_path: String) -> Dictionary:
	var repair_tool: String = String(task.get("repair_tool", ""))
	var arguments: Dictionary = _derive_step_arguments(
		plan, task, repair_tool, _resolve_inputs(task, step_inputs, true))
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
			"tool_name": repair_tool, "repair": true, "missing_inputs": missing,
			"input_schema": _tool_input_schema(repair_tool)
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
		"stop": String(verdict.get("status", "")) in ["blocked", "retry_required", "replan_required", "recovery_required"],
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

## Resolve "$artifact" references and fill schema-required inputs from the
## workflow artifact registry, then apply plan-authorized runtime defaults.
func _derive_step_arguments(plan: Dictionary, task: Dictionary, tool_name: String,
		arguments: Dictionary) -> Dictionary:
	var workflow: Dictionary = plan.get("workflow", {})
	var artifacts_value: Variant = workflow.get("artifacts", {})
	var artifacts: Dictionary = artifacts_value if artifacts_value is Dictionary else {}
	if not artifacts.is_empty():
		var resolved: Variant = _engine.resolve_argument_references(arguments, artifacts)
		if resolved is Dictionary:
			arguments = resolved
		var missing: Array[String] = _missing_required_inputs(tool_name, arguments)
		var derived: Dictionary = {}
		var profile: String = String(task.get("profile", ""))
		for param in missing:
			var artifact_key: String = String(DERIVED_INPUT_ARTIFACTS.get(param, ""))
			if not artifact_key.is_empty() and artifacts.has(artifact_key):
				derived[param] = artifacts[artifact_key]
				arguments[param] = artifacts[artifact_key]
		_derive_visual_baseline_path(tool_name, arguments, artifacts, derived)
		_derive_scene_context(tool_name, profile, arguments, artifacts, derived)
		if not derived.is_empty():
			task["derived_inputs"] = derived
		else:
			task.erase("derived_inputs")
	# 首个建场景/建脚本步骤没有任何已注册工件可引用（上面的推导块只在有工件时
	# 运行）：按 profile 推导确定性路径，让"给一个目标"从第一步起就不需要
	# 调用方发明路径；step id 保证同 profile 多脚本不冲突。
	var step_profile: String = String(task.get("profile", ""))
	if tool_name == "create_scene" and not arguments.has("scene_path") \
			and not artifacts.has("scene"):
		var profile_slug: String = step_profile.replace("_", "-") if not step_profile.is_empty() else "game"
		arguments["scene_path"] = "res://scenes/%s.tscn" % profile_slug
		task["derived_inputs"] = (task.get("derived_inputs", {}) if task.get("derived_inputs", {}) is Dictionary else {})
		task["derived_inputs"]["scene_path"] = arguments["scene_path"]
	if tool_name == "create_script" and not arguments.has("script_path") \
			and not artifacts.has("script"):
		var script_slug: String = step_profile.replace("_", "-") if not step_profile.is_empty() else "game"
		var step_id: String = String(task.get("id", ""))
		arguments["script_path"] = "res://scripts/%s%s.gd" % [
			script_slug, "-" + step_id if not step_id.is_empty() else ""]
		task["derived_inputs"] = (task.get("derived_inputs", {}) if task.get("derived_inputs", {}) is Dictionary else {})
		task["derived_inputs"]["script_path"] = arguments["script_path"]
	# 挂载步骤缺 node_path 时默认场景根：gameplay profile 不建独立玩家节点，
	# 控制器脚本挂到场景根即可运行。
	if tool_name == "attach_script" and not arguments.has("node_path") \
			and artifacts.has("scene"):
		arguments["node_path"] = "/root"
		task["derived_inputs"] = (task.get("derived_inputs", {}) if task.get("derived_inputs", {}) is Dictionary else {})
		task["derived_inputs"]["node_path"] = "/root"
	# 输入动作步骤缺 action_name 时给移动类目标的规范默认；调用方可用
	# step_inputs 覆盖为完整键位方案。
	if tool_name == "upsert_project_input_action" and not arguments.has("action_name"):
		arguments["action_name"] = "move_up"
		task["derived_inputs"] = (task.get("derived_inputs", {}) if task.get("derived_inputs", {}) is Dictionary else {})
		task["derived_inputs"]["action_name"] = "move_up"
	# 首个主题步骤同理：按 profile 推导确定性 .tres 路径。
	if tool_name == "create_theme" and not arguments.has("theme_path") \
			and not artifacts.has("theme"):
		var theme_slug: String = step_profile.replace("_", "-") if not step_profile.is_empty() else "game"
		arguments["theme_path"] = "res://themes/%s.tres" % theme_slug
		task["derived_inputs"] = (task.get("derived_inputs", {}) if task.get("derived_inputs", {}) is Dictionary else {})
		task["derived_inputs"]["theme_path"] = arguments["theme_path"]
	if tool_name == "create_theme" and not arguments.has("theme_name"):
		arguments["theme_name"] = "GameTheme"
		task["derived_inputs"] = (task.get("derived_inputs", {}) if task.get("derived_inputs", {}) is Dictionary else {})
		task["derived_inputs"]["theme_name"] = "GameTheme"
	# UI 建节点步骤的语义默认：场景根下一个 Label（与"win label"类目标对齐）。
	if tool_name == "create_node" and not arguments.has("node_name") \
			and artifacts.has("scene") and step_profile == "ui_screen":
		arguments["parent_path"] = "/root"
		arguments["node_type"] = "Label"
		arguments["node_name"] = "WinLabel"
		task["derived_inputs"] = (task.get("derived_inputs", {}) if task.get("derived_inputs", {}) is Dictionary else {})
		task["derived_inputs"]["parent_path"] = "/root"
		task["derived_inputs"]["node_type"] = "Label"
		task["derived_inputs"]["node_name"] = "WinLabel"
	if tool_name == "set_anchor_preset" and not arguments.has("node_path") \
			and artifacts.has("scene") and step_profile == "ui_screen":
		arguments["node_path"] = "/root/WinLabel"
		task["derived_inputs"] = (task.get("derived_inputs", {}) if task.get("derived_inputs", {}) is Dictionary else {})
		arguments["preset"] = 8
		task["derived_inputs"]["preset"] = 8
		task["derived_inputs"]["node_path"] = "/root/WinLabel"
	if tool_name in RUNTIME_WINDOW_TOOLS and not arguments.has("allow_window"):
		arguments["allow_window"] = true
	var focus_param: String = String(FOCUS_POLICY_TOOLS.get(tool_name, ""))
	if not focus_param.is_empty() and not arguments.has(focus_param):
		arguments[focus_param] = true
	return arguments

## Visual gates derive candidate_path from the latest runtime screenshot and a
## deterministic baseline location; assert_visual_baseline captures the golden
## image itself on first run, so the gate never stalls on missing paths.
func _derive_visual_baseline_path(tool_name: String, arguments: Dictionary,
		artifacts: Dictionary, derived: Dictionary) -> void:
	if tool_name != "assert_visual_baseline":
		return
	var screenshot: String = String(artifacts.get("screenshot", ""))
	if screenshot.is_empty():
		return
	if not arguments.has("candidate_path"):
		arguments["candidate_path"] = screenshot
		derived["candidate_path"] = screenshot
	if not arguments.has("baseline_path"):
		var baseline: String = "user://visual_baselines/" + screenshot.get_file()
		arguments["baseline_path"] = baseline
		derived["baseline_path"] = baseline

## Scene-scoped tools get the creating profile's scene as an optional
## scene_path so the shared context guard pins the right edited scene even
## when several profiles created scenes in the same goal.
func _derive_scene_context(tool_name: String, profile: String, arguments: Dictionary,
		artifacts: Dictionary, derived: Dictionary) -> void:
	if tool_name not in SCENE_SCOPED_TOOLS or arguments.has("scene_path"):
		return
	var profile_scene: String = String(artifacts.get("scene:" + profile, ""))
	if not profile_scene.is_empty():
		arguments["scene_path"] = profile_scene
		derived["scene_path"] = profile_scene
		return
	var last_scene: String = String(artifacts.get("scene", ""))
	if not last_scene.is_empty():
		arguments["scene_path"] = last_scene
		derived["scene_path"] = last_scene

func _missing_required_inputs(tool_name: String, arguments: Dictionary) -> Array[String]:
	var schema: Dictionary = _tool_input_schema(tool_name)
	var missing: Array[String] = []
	for required_value in schema.get("required", []):
		var required_name: String = String(required_value)
		if not arguments.has(required_name):
			missing.append(required_name)
		elif arguments[required_name] is String and String(arguments[required_name]).strip_edges().is_empty():
			missing.append(required_name)
	return missing

func _tool_input_schema(tool_name: String) -> Dictionary:
	var schema: Dictionary = {}
	if _server_core.has_method("get_tool_input_schema"):
		schema = _server_core.get_tool_input_schema(tool_name)
	elif _server_core.has_method("get_tool"):
		var tool: Variant = _server_core.get_tool(tool_name)
		if tool != null:
			schema = tool.input_schema
	return schema.duplicate(true)

func _tool_execution_traits(tool_name: String) -> Dictionary:
	if _server_core != null and _server_core.has_method("get_tool_execution_traits"):
		return _server_core.get_tool_execution_traits(tool_name)
	return {"read_only": false, "idempotent": false, "destructive": false}

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

func _registered_tool_infos() -> Array:
	if _server_core == null or not _server_core.has_method("get_registered_tools"):
		return []
	return _server_core.get_registered_tools()

func _merge_required_capabilities(options: Dictionary, additions: Array) -> void:
	if additions.is_empty():
		return
	var merged: Array = []
	if options.get("required_capabilities") is Array:
		merged = (options["required_capabilities"] as Array).duplicate()
	for tool_value in additions:
		var tool_name: String = String(tool_value)
		if not tool_name.is_empty() and tool_name not in merged:
			merged.append(tool_name)
	options["required_capabilities"] = merged

func _route_unprofiled_clauses(objective: String,
		available_tools: Array[String]) -> Dictionary:
	var capabilities: Array[String] = []
	var uncovered: Array[String] = []
	for clause in _semantic_clauses(objective):
		if not _engine.classify_profiles(clause).has("error"):
			continue
		if not _exact_atomic_mentions(clause, available_tools).is_empty():
			continue
		var route: Dictionary = _route_complete_goal(clause)
		for tool_name in route.get("capabilities", []):
			if String(tool_name) not in capabilities:
				capabilities.append(String(tool_name))
		var clause_uncovered: Array = route.get("uncovered_requirements", [])
		if clause_uncovered.is_empty() and (route.get("capabilities", []) as Array).is_empty():
			clause_uncovered = [clause]
		for term_value in clause_uncovered:
			var term: String = String(term_value)
			if not term.is_empty() and term not in uncovered:
				uncovered.append(term)
	capabilities.sort()
	uncovered.sort()
	return {"capabilities": capabilities, "uncovered_requirements": uncovered}

func _route_complete_goal(objective: String) -> Dictionary:
	var registered: Array = _registered_tool_infos()
	var revision: int = -1
	if _server_core != null and _server_core.has_method("get_tool_registry_revision"):
		revision = int(_server_core.get_tool_registry_revision())
	var whole: Dictionary = _workflow_router.route(objective, registered, 10, revision)
	if whole.has("error"):
		return {"capabilities": [], "uncovered_requirements": [objective]}
	var routes: Array[Dictionary] = [whole]
	var clauses: Array[String] = _semantic_clauses(objective)
	var failed_clauses: Array[String] = []
	if (clauses.size() > 1 and (
			int(whole.get("tool_count", 0)) >= 10
			or not (whole.get("uncovered_terms", []) as Array).is_empty())):
		routes.clear()
		for clause in clauses:
			var clause_route: Dictionary = _workflow_router.route(clause, registered, 10, revision)
			if not clause_route.has("error"):
				routes.append(clause_route)
			else:
				failed_clauses.append(clause)
	var capabilities: Array[String] = []
	var uncovered: Array[String] = []
	for failed_clause in failed_clauses:
		if String(failed_clause) not in uncovered:
			uncovered.append(String(failed_clause))
	for route in routes:
		for tool_name in _route_tool_names(route):
			if tool_name not in capabilities:
				capabilities.append(tool_name)
		for term_value in route.get("uncovered_terms", []):
			var term: String = String(term_value).strip_edges()
			if not term.is_empty() and term not in uncovered:
				uncovered.append(term)
	capabilities.sort()
	uncovered.sort()
	return {
		"capabilities": capabilities,
		"uncovered_requirements": uncovered,
		"route_count": routes.size()
	}

func _semantic_clauses(objective: String) -> Array[String]:
	var normalized: String = objective.replace("\r\n", "\n").replace("\r", "\n")
	for separator in [";", "；", "。", "!", "！", "?", "？", "\n", " and then ", " then ", " and ", "然后", "并且", "以及", "并", "和"]:
		normalized = normalized.replace(separator, "\n")
	var clauses: Array[String] = []
	for value in normalized.split("\n", false):
		var clause: String = String(value).strip_edges()
		if not clause.is_empty() and clause not in clauses:
			clauses.append(clause)
	if clauses.is_empty():
		clauses.append(objective.strip_edges())
	return clauses

func _route_tool_names(route: Dictionary) -> Array[String]:
	var names: Array[String] = []
	for stage_value in route.get("stages", []):
		for tool_value in (stage_value as Dictionary).get("tools", []):
			var tool_name: String = String(tool_value)
			if (not tool_name.is_empty() and tool_name not in names
					and tool_name not in EngineScript.FORBIDDEN_NESTED_CAPABILITIES):
				names.append(tool_name)
	return names

func _exact_atomic_mentions(objective: String, available_tools: Array[String]) -> Array[String]:
	var normalized: String = objective.strip_edges().to_lower()
	for separator in ["`", "\"", "'", ",", ";", ":", ".", "!", "?", "(", ")", "[", "]", "{", "}", "/", "\\", "\n", "\r", "\t", "，", "；", "：", "。", "！", "？", "、"]:
		normalized = normalized.replace(separator, " ")
	normalized = " " + normalized + " "
	while normalized.contains("  "):
		normalized = normalized.replace("  ", " ")
	var matches: Array[String] = []
	for tool_name in available_tools:
		if (tool_name not in EngineScript.FORBIDDEN_NESTED_CAPABILITIES
				and normalized.contains(" " + tool_name.to_lower() + " ")):
			matches.append(tool_name)
	matches.sort()
	return matches
