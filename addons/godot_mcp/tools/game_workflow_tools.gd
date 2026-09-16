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
const GoalBlueprintsScript = preload("res://addons/godot_mcp/native_mcp/goal_blueprints.gd")
const ChangeJournalScript = preload("res://addons/godot_mcp/tools/change_journal.gd")
const LayoutVerifierScript = preload("res://addons/godot_mcp/tools/layout_verifier.gd")
const FeatureRegistryScript = preload("res://addons/godot_mcp/tools/feature_registry.gd")
const GameModelStoreScript = preload("res://addons/godot_mcp/tools/game_model_store.gd")

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
	"attach_script", "save_scene", "set_tilemap_layer_cells", "run_project"
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
	"candidate_path": "screenshot",
	"path": "model"
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
		"Create or resume a durable workflow from one natural-language command, then advance an adaptive authorized DAG slice. Repeating the same command after a yield, retry or restart attaches to the checkpoint without duplicating completed work.",
		{
			"type": "object",
			"properties": {
				"command": {
					"type": "string",
					"description": "Natural-language objective. Creates the plan when absent and resumes it when equivalent; a different command conflicts instead of replacing durable work."
				},
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
				"objective": {"type": "string"},
				"requested_command": {"type": "string"},
				"plan_path": {"type": "string"},
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
	var command: String = String(params.get("command", "")).strip_edges()
	if not TaskPlanStoreScript.plan_exists(plan_path) and not command.is_empty():
		var planned: Dictionary = _tool_plan_game_workflow({
			"action": "plan", "objective": command, "plan_path": plan_path
		})
		if planned.has("error"):
			return planned
	var plan: Dictionary = _load_plan(plan_path)
	if plan.has("error"):
		return plan
	var available_tools: Array[String] = _available_tool_names()
	var integrity: Dictionary = _engine.validate_integrity(plan, available_tools)
	if integrity.has("error"):
		integrity["status"] = "blocked"
		integrity["plan_path"] = plan_path
		return integrity
	if not command.is_empty() and _normalize_command(command) != _normalize_command(String(plan.get("goal", ""))):
		return {
			"error": "A different command is already checkpointed at '%s'; use plan_game_workflow action=replan with the current workflow id to replace it" % plan_path,
			"status": "conflict",
			"workflow_id": (plan["workflow"] as Dictionary).get("workflow_id", ""),
			"objective": plan.get("goal", ""),
			"requested_command": command,
			"plan_path": plan_path
		}
	var cas: Dictionary = _check_expected_workflow(plan, params)
	if cas.has("error"):
		return cas
	var workflow: Dictionary = plan["workflow"]
	var state: String = String(workflow.get("state", ""))
	# 全新计划（尚未执行任何步骤）启动前停掉残留游戏：上一目标完成时其
	# 游戏可能仍在运行，run_project 的 already_running 复用会让本目标的
	# 行为断言在旧进程/旧位置上跑（E4 校准实测：重试从 x=+810 起步）。
	var plan_needs_runtime: bool = false
	for task_value in plan.get("tasks", []):
		var task_tool: String = String((task_value as Dictionary).get("tool_name", ""))
		if task_tool in ["play_and_verify", "run_project", "install_runtime_probe",
				"assert_no_runtime_errors", "assert_performance_budget", "get_runtime_screenshot"]:
			plan_needs_runtime = true
			break
	if state == "planned" and plan_needs_runtime:
		# 授权必须是完整的（step_id 非空 + authorized_tool 匹配）——空任务的
		# _authorization 会因 "missing 'step_id'" 被拒，stale-stop 从未真正
		# 生效（残留游戏污染下一目标的调试器会话，N4/E1/R3 的 waiting 类
		# 失败与此相关）。合成 step_id 仅需非空与工具匹配。
		var stale_stop: Variant = await _server_core.invoke_planned_tool("stop_project",
			{"allow_window": true}, _synthetic_authorization(plan, "stale_stop", "stop_project"))
		if stale_stop is Dictionary and not (stale_stop as Dictionary).has("error"):
			var stopped_scene: String = String((stale_stop as Dictionary).get("last_played_scene",
				(stale_stop as Dictionary).get("scene", "")))
			if not stopped_scene.is_empty():
				var stop_metrics: Dictionary = _engine.workflow_metrics(plan)
				stop_metrics["stale_game_stops"] = int(stop_metrics.get("stale_game_stops", 0)) + 1
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
			# journal 自动收口（R3）：该工具最近一次提交写入按磁盘复判为
			# complete_receipt 且无 pending 冲突 → 写入已确凿发生，补回执
			# 收口继续推进（崩溃慢测契约允许"步骤实际已完成"的诚实路径）；
			# 无证据时维持 fail-closed 并附处方。
			var autoclose_receipt: Dictionary = _journal_autoclose(plan, uncertain_task)
			if not autoclose_receipt.is_empty():
				var autoclose_metrics: Dictionary = _engine.workflow_metrics(plan)
				autoclose_metrics["journal_autocloses"] = int(autoclose_metrics.get("journal_autocloses", 0)) + 1
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
			# 变更日志处方（信息性，不改变恢复语义）：pending 操作逐条分类，
			# 该工具最近一条提交记录按磁盘实况复判——AI 从"inspect and replan"
			# 升级为"写入已确认落盘/存在冲突需人工/可安全重放"的明确指引。
			var journal_recovery: Dictionary = _change_journal_recovery(
				String(uncertain_task.get("tool_name", "")))
			if not journal_recovery.is_empty():
				uncertain["change_journal"] = journal_recovery
				workflow["blocked_reason"] = "Unknown non-idempotent outcome; change_journal verdict attached — %s" % str(journal_recovery.get("recommended", "inspect pending operations"))
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
		# 用户手改保护（P1-5）：累积合并会整脚本覆盖控制器——指纹漂移说明
		# 脚本含插件未确认写入的修改，阻止覆盖并以明确指引失败。
		if task.has("protection_conflict"):
			var conflict: Dictionary = task["protection_conflict"]
			task["status"] = "blocked"
			workflow["state"] = "blocked"
			workflow["blocked_reason"] = String(conflict.get("reason", "user edits detected"))
			var conflict_save: Dictionary = TaskPlanStoreScript.save_plan(plan, plan_path)
			if conflict_save.has("error"):
				return conflict_save
			return _runner_response(plan, plan_path, "blocked", executed, {
				"step_id": task.get("id", ""), "tool_name": tool_name,
				"protection_conflict": conflict,
			})
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
		# 调参测量前新鲜重启（P2-1 相位一致）：基线与验证必须在相同的初始
		# 状态下测量——复用运行中的游戏会让敌相位随历史漂移，振幅对比
		# 失去意义（真机复现：baseline 30.4 vs tuned 77.1，方向门禁正确地
		# 拒绝了不可比的数据）。重启后 enemy_time 从 0 起算，两窗口同相位。
		if tool_name == "play_and_verify" \
				and String(task.get("step_key", "")) in ["tune_baseline", "tune_verify"]:
			await _server_core.invoke_planned_tool("stop_project", {"allow_window": true},
				_synthetic_authorization(plan, "tune_fresh_stop", "stop_project"))
			await _server_core.invoke_planned_tool("run_project", {"allow_window": true},
				_synthetic_authorization(plan, "tune_fresh_run", "run_project"))
		var raw_result: Variant = await _server_core.invoke_planned_tool(tool_name, arguments, authorization)
		atomic_calls += 1
		metrics["atomic_calls"] = int(metrics.get("atomic_calls", 0)) + 1
		# 调参计划值捕获（P2-1 v2）：modify 成功后把 old→new 记入工件，
		# 验证步断言新值在运行中的游戏里生效（"调了没变"必败、相位免疫）。
		if tool_name == "modify_script" and String(task.get("step_key", "")) == "tune_apply" \
				and raw_result is Dictionary and not (raw_result as Dictionary).has("error"):
			var planned_tune: Dictionary = _parse_planned_tune(arguments)
			if not planned_tune.is_empty():
				if not (workflow.get("artifacts", {}) is Dictionary):
					workflow["artifacts"] = {}
				(workflow["artifacts"] as Dictionary)["tune_planned"] = planned_tune
		# E3 离线布局门禁：ui profile 的 save_scene 成功后，按锚点在三种
		# 视口尺寸解算根级控件矩形——越界/重叠即本步失败（确定性证据，
		# 无需真机改窗口；真机交互抽查由 play 演练承担）。
		if tool_name == "save_scene" and raw_result is Dictionary 				and String((raw_result as Dictionary).get("status", "")) == "success" 				and String(task.get("profile", "")) == "ui_screen":
			var layout_check: Dictionary = LayoutVerifierScript.verify_scene_layout(
				String((raw_result as Dictionary).get("saved_path", "")),
				[Vector2i(854, 480), Vector2i(1280, 720), Vector2i(1920, 1080)])
			if not (layout_check.get("violations", []) as Array).is_empty():
				raw_result = {
					"error": "Layout violations at multiple viewport sizes (E3 gate)",
					"layout_check": layout_check,
				}
			else:
				(raw_result as Dictionary)["layout_check"] = {
					"checked": layout_check.get("checked", 0),
					"sizes": layout_check.get("sizes", []),
				}
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
	if final_status == "completed":
		# 旧行为回归门禁（P1-4）：完成前重验受影响的旧功能——回归失败
		# 阻止宣布完成（"错误完成声明"的核心来源：completed ≠ 十项需求完成）。
		var prior_regression: Dictionary = await _run_prior_feature_regression(plan)
		if bool(prior_regression.get("failed", false)):
			workflow["state"] = "replan_required"
			workflow["blocked_reason"] = "prior feature regression failed: %s" % String(prior_regression.get("reason", "unknown"))
			var regression_save: Dictionary = TaskPlanStoreScript.save_plan(plan, plan_path)
			if regression_save.has("error"):
				return regression_save
			return _runner_response(plan, plan_path, "replan_required", executed, {"prior_regression": prior_regression})
		if not prior_regression.is_empty():
			final_extra["prior_regression"] = prior_regression
		# 真实指纹（P1-4）：控制器脚本内容 sha256——注册表与游戏模型都以
		# 磁盘实况为准（差距分析：空字符串指纹永远检不出漂移）。
		var completion_artifacts: Dictionary = workflow.get("artifacts", {}) if workflow.get("artifacts", {}) is Dictionary else {}
		var artifact_script: String = String(completion_artifacts.get("script", ""))
		var script_source: String = ""
		if not artifact_script.is_empty() and FileAccess.file_exists(artifact_script):
			script_source = FileAccess.get_file_as_string(artifact_script)
		var script_fingerprint: String = GameModelStoreScript.file_fingerprint(artifact_script)
		# Phase B 功能归属注册：记录本功能的动词与验收步骤，
		# 供后续目标的旧行为重验使用
		var feature_verbs: Dictionary = GoalBlueprintsScript.match_verbs(String(plan.get("goal", "")))
		if GoalBlueprintsScript.has_any_verb(feature_verbs):
			var feature_args: Dictionary = {}
			_derive_generic_play_steps(plan, {}, "play_and_verify", feature_args)
			var feature_exercise: Array = feature_args.get("steps", [])
			FeatureRegistryScript.record_feature(String(plan.get("goal", "")),
				feature_verbs, feature_exercise, script_fingerprint)
		# 持久游戏模型（P1-1）：数量/参数/指纹入档——调参与更名目标同样
		# 刷新指纹，用户手改检测的基线始终是"插件最后一次确认写入"。
		if not script_source.is_empty():
			var model_result: Dictionary = GameModelStoreScript.apply_completion(
				String(plan.get("goal", "")), feature_verbs, artifact_script, script_source)
			if not model_result.has("error"):
				final_extra["game_model"] = model_result
		# 跨目标账本（P4 v1）：目标完成时把 goal + 工件持久记录到项目级
		# 账本（与 plan 文件分开——plan 会被 replace，账本累积）。后续目标
		# 的回归与冲突检测以此为准（修复/新目标不得破坏既有目标产物）。
		var ledger_extra: Dictionary = _append_goal_ledger(plan)
		if not ledger_extra.is_empty():
			final_extra["goal_ledger"] = ledger_extra
		# Q1 账本重验：既往目标的脚本仍能编译（跨目标编译回归）。
		var prior_compile: Dictionary = await _verify_ledger_scripts(plan)
		if not prior_compile.is_empty():
			final_extra["ledger_regression"] = prior_compile
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
		# 修复死端快速失败（真机复现：验证类门禁失败后 repair=modify_script
		# 永远派生不出 content → 卡 waiting 63s 直到测试超时）。验证步的
		# 失败是证据失败，没有可派生的代码修复——直接 replan 而非挂起。
		var repaired_step_tool: String = String(task.get("tool_name", ""))
		var verify_class_repair: bool = repair_tool == "modify_script" \
			and repaired_step_tool in ["play_and_verify", "assert_no_runtime_errors",
				"assert_performance_budget", "assert_visual_baseline", "get_runtime_screenshot"] \
			and "content" in missing
		if verify_class_repair:
			task["repair_pending"] = false
			task["status"] = "failed"
			(plan["workflow"] as Dictionary)["state"] = "replan_required"
			(plan["workflow"] as Dictionary)["blocked_reason"] = \
				"verification gate '%s' failed and its code repair cannot be derived; replan with different inputs or capabilities" % repaired_step_tool
			var fast_fail_save: Dictionary = TaskPlanStoreScript.save_plan(plan, plan_path)
			if fast_fail_save.has("error"):
				return {"stop": true, "status": "blocked", "error": fast_fail_save["error"]}
			return {
				"stop": true, "status": "replan_required", "step_id": task.get("id", ""),
				"tool_name": repaired_step_tool, "repair": true,
				"missing_inputs": missing,
			}
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
	if not verdict.has("error") and String(verdict.get("status", "")) not in ["blocked", "recovery_required"]:
		_requeue_profile_evidence(plan, task)
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

## 修复改变了项目状态：把同 profile 已完成的运行期证据步骤（截图）重置为
## pending，让视觉门禁在下一片重新截图比对。否则门禁拿修复前的旧候选与
## 旧基线比较（恒等），修复是否生效永远验证不出来（重言式门禁）。
func _requeue_profile_evidence(plan: Dictionary, repaired_task: Dictionary) -> void:
	var profile: String = String(repaired_task.get("profile", ""))
	if profile.is_empty():
		return
	for task_value in plan.get("tasks", []):
		var candidate: Dictionary = task_value
		if String(candidate.get("profile", "")) != profile:
			continue
		if String(candidate.get("tool_name", "")) != "get_runtime_screenshot":
			continue
		if String(candidate.get("status", "")) != "done":
			continue
		candidate["status"] = "pending"
		candidate.erase("needs_input")

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
		_derive_visual_baseline_path(tool_name, arguments, artifacts, derived,
			String(plan.get("workflow", {}).get("workflow_id", "")))
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
		var script_suffix: String = "-" + step_id if not step_id.is_empty() else ""
		# 跨目标同 step_id 复用同一派生路径：create_script 拒绝覆盖已存在
		# 文件（安全特性），同路径的第二个目标会 replan——对已存在文件
		# 自动递增后缀（真机 E2E：连续 gameplay 目标在同一项目累积时抓到）。
		var script_candidate: String = "res://scripts/%s%s.gd" % [script_slug, script_suffix]
		var collision_index: int = 2
		while FileAccess.file_exists(script_candidate):
			script_candidate = "res://scripts/%s%s-%d.gd" % [script_slug, script_suffix, collision_index]
			collision_index += 1
		arguments["script_path"] = script_candidate
		task["derived_inputs"] = (task.get("derived_inputs", {}) if task.get("derived_inputs", {}) is Dictionary else {})
		task["derived_inputs"]["script_path"] = arguments["script_path"]
	# 目标命中蓝图动词时生成真实可运行内容（调用方显式 content 永远优先）。
	if tool_name == "create_script" and not arguments.has("content") \
			and step_profile == "gameplay_feature":
		var objective: String = String(plan.get("goal", ""))
		# Phase B 累积功能合成：注册表已有功能时，合并已注册动词与新目标
		# 动词，生成包含所有功能的完整控制器——每次替换都是功能超集，
		# 旧功能不丢失（差距分析：只追加独立函数不接入 _ready 是行不通的，
		# 正确做法是累积动词集 → 完整控制器）。
		# 调参目标例外：不重新生成控制器——调参链用 modify_script 改参数，
		# 重新生成会覆盖调参（累积模式下调参目标全部失败的根因）。
		var is_tuning_goal: bool = not parse_tuning_goal(objective).is_empty()
		var registered_verbs: Dictionary = {}
		if is_tuning_goal:
			var existing_for_tune: String = String((plan.get("workflow", {}) as Dictionary).get("artifacts", {}).get("script", ""))
			if not existing_for_tune.is_empty() and FileAccess.file_exists(existing_for_tune):
				arguments["content"] = FileAccess.get_file_as_string(existing_for_tune)
				task["derived_inputs"] = (task.get("derived_inputs", {}) if task.get("derived_inputs", {}) is Dictionary else {})
				task["derived_inputs"]["content"] = "reuse-for-tuning"
			else:
				registered_verbs = FeatureRegistryScript.registered_verbs()
		else:
			registered_verbs = FeatureRegistryScript.registered_verbs()
# 调参与非调参目标共用合并路径（真缺陷：合并块曾嵌在非调参 else 里，
# 全新计划的调参目标生成 extends Node 空壳——modify 找不到常量，目标必败）。
		var goal_verbs: Dictionary = GoalBlueprintsScript.match_verbs(objective)
		# 累积合并仅当目标本身命中蓝图动词时生效——非玩法目标（如导出、
		# 本地化）不应被合并拉入游戏控制器。
		if not registered_verbs.is_empty() and GoalBlueprintsScript.has_any_verb(goal_verbs):
			# 合并：已注册动词 ∪ 新目标动词（新目标优先——同动词可能被
				# 新目标重新启用）
			var merged_verbs: Dictionary = registered_verbs.duplicate()
			for verb_key in goal_verbs.keys():
				merged_verbs[verb_key] = goal_verbs[verb_key] or bool(registered_verbs.get(verb_key, false))
			# state_machine 保留在合并里（P1-6）：旧实现直接从合并动词里
				# 抹掉 state_machine，"加完标题屏再加玩法"会静默失去标题流程。
				# 门控兼容由双 Enter 前缀（on-demand/generic 两处演练都会先
				# 进入 playing）与完成前旧行为回归门禁兜底。
				# 用合并动词集构建合成目标语句（controller_script 按动词匹配，
				# 所以只要动词集正确，生成的控制器就包含所有功能）
				var merged_objective: String = _build_merged_objective(merged_verbs, objective)
				var merged_source: String = GoalBlueprintsScript.controller_script(merged_objective)
				if not merged_source.is_empty():
					# 用户手改保护（P1-5）：指纹漂移 = 插件最后确认写入之后有
						# 人工修改——整脚本重生成会覆盖手改，阻止并给出指引
						# （runner 在参数派生后拦截 protection_conflict）。
					var merge_artifacts: Dictionary = (plan.get("workflow", {}) as Dictionary).get("artifacts", {}) \
						if (plan.get("workflow", {}) as Dictionary).get("artifacts", {}) is Dictionary else {}
					var merge_script: String = String(merge_artifacts.get("script", ""))
					if GameModelStoreScript.has_user_edits(merge_script):
						task["protection_conflict"] = {
							"script": merge_script,
							"reason": "user edits detected in %s (content differs from the fingerprint recorded in res://.mcp/game_model.json); cumulative regeneration would overwrite them — resolve manually, or delete game_model.json to accept regeneration" % merge_script,
							}
					else:
						# 已调参数注入（P1-2）：调参成果不被合并重生成覆盖
						merged_source = GameModelStoreScript.apply_param_overrides(merged_source)
						arguments["content"] = merged_source
						task["derived_inputs"] = (task.get("derived_inputs", {}) if task.get("derived_inputs", {}) is Dictionary else {})
						task["derived_inputs"]["content"] = "cumulative-merge"
				else:
					var fallback_source: String = GoalBlueprintsScript.controller_script(objective)
					if not fallback_source.is_empty():
						arguments["content"] = fallback_source
						task["derived_inputs"] = (task.get("derived_inputs", {}) if task.get("derived_inputs", {}) is Dictionary else {})
						task["derived_inputs"]["content"] = "goal-blueprint"
		else:
			var blueprint_source: String = GoalBlueprintsScript.controller_script(objective)
			if not blueprint_source.is_empty():
				arguments["content"] = blueprint_source
			task["derived_inputs"] = (task.get("derived_inputs", {}) if task.get("derived_inputs", {}) is Dictionary else {})
			task["derived_inputs"]["content"] = "goal-blueprint"
	# 读取脚本步骤无工件可引用时，回退到磁盘上项目脚本目录的第一个脚本。
	if tool_name == "read_script" and not arguments.has("script_path") 			and not artifacts.has("script"):
		var scripts_dir: String = ProjectSettings.globalize_path("res://scripts")
		if DirAccess.dir_exists_absolute(scripts_dir):
			var dir: DirAccess = DirAccess.open(scripts_dir)
			if dir != null:
				dir.list_dir_begin()
				while true:
					var entry: String = dir.get_next()
					if entry.is_empty():
						break
					if entry.ends_with(".gd"):
						arguments["script_path"] = "res://scripts/" + entry
						task["derived_inputs"] = (task.get("derived_inputs", {}) if task.get("derived_inputs", {}) is Dictionary else {})
						task["derived_inputs"]["script_path"] = arguments["script_path"]
						break
				dir.list_dir_end()
	# 首个动画资源步骤：按 profile 推导确定性 .tres 路径。
	if tool_name == "create_animation" and not arguments.has("animation_path") 			and not artifacts.has("animation"):
		var anim_slug: String = step_profile.replace("_", "-") if not step_profile.is_empty() else "game"
		arguments["animation_path"] = "res://animations/%s.tres" % anim_slug
		task["derived_inputs"] = (task.get("derived_inputs", {}) if task.get("derived_inputs", {}) is Dictionary else {})
		task["derived_inputs"]["animation_path"] = arguments["animation_path"]
	# 动画关键帧步骤：默认给场景根 position 的两帧往返（工具会确保轨道存在）。
	if tool_name == "insert_animation_keys" and not arguments.has("animation_path"):
		var insert_anim_slug: String = step_profile.replace("_", "-") if not step_profile.is_empty() else "game"
		arguments["animation_path"] = "res://animations/%s.tres" % insert_anim_slug
		task["derived_inputs"] = (task.get("derived_inputs", {}) if task.get("derived_inputs", {}) is Dictionary else {})
		task["derived_inputs"]["animation_path"] = arguments["animation_path"]
	if tool_name == "insert_animation_keys" and not arguments.has("track_path"):
		arguments["track_path"] = ".:position"
		arguments["value_type"] = "vector2"
		arguments["keys"] = [
			{"time": 0.0, "value": {"x": 0.0, "y": 0.0}},
			{"time": 1.0, "value": {"x": 96.0, "y": 0.0}},
		]
		task["derived_inputs"] = (task.get("derived_inputs", {}) if task.get("derived_inputs", {}) is Dictionary else {})
		task["derived_inputs"]["track_path"] = ".:position"
		task["derived_inputs"]["keys"] = "default-two-key-position"
	# 导出链步骤默认指向目标平台映射出的预设（与引擎 release_preset 步骤
	# 同源：export_preset_for_platform）。此前硬编码 "Windows Desktop"，
	# "export for web" 目标会校验/导出/冒烟一个 Windows .exe 并 completed。
	if tool_name in ["validate_export_preset", "run_export", "smoke_test_export"] \
			and not arguments.has("preset"):
		var contract_platform: String = String(
			plan.get("workflow", {}).get("goal_contract", {}).get("platform", ""))
		var export_preset: Dictionary = EngineScript.export_preset_for_platform(contract_platform)
		arguments["preset"] = export_preset["name"]
		task["derived_inputs"] = (task.get("derived_inputs", {}) if task.get("derived_inputs", {}) is Dictionary else {})
		task["derived_inputs"]["preset"] = export_preset["name"]
	# 重导入步骤缺路径时：重导入本目标已产出的主题/瓦片/动画资源（磁盘真相）。
	if tool_name == "reimport_resources" and not arguments.has("resource_paths"):
		var produced: Array = []
		for dir_name in ["themes", "tilesets", "animations", "scenes"]:
			var dir_abs: String = ProjectSettings.globalize_path("res://" + dir_name)
			if not DirAccess.dir_exists_absolute(dir_abs):
				continue
			var d: DirAccess = DirAccess.open(dir_abs)
			if d == null:
				continue
			d.list_dir_begin()
			while true:
				var entry: String = d.get_next()
				if entry.is_empty():
					break
				if entry.ends_with(".tres") or entry.ends_with(".tscn"):
					produced.append("res://%s/%s" % [dir_name, entry])
			d.list_dir_end()
		if not produced.is_empty():
			arguments["resource_paths"] = produced
			task["derived_inputs"] = (task.get("derived_inputs", {}) if task.get("derived_inputs", {}) is Dictionary else {})
			task["derived_inputs"]["resource_paths"] = "%d produced resources" % produced.size()
	# 动画运行时链：profile 固定建 AnimPlayer；关键帧步骤自动接线（显式值优先）。
	# 运行时探针用游戏内绝对路径 /root/<场景根名>/AnimPlayer。
	if step_profile == "animation_audio":
		var player_node_path: String = "/root/AnimPlayer"
		var media_scene: String = String(artifacts.get("scene", ""))
		if not media_scene.is_empty():
			player_node_path = "/root/%s/AnimPlayer" % media_scene.get_file().get_basename()
		if tool_name == "insert_animation_keys" and not arguments.has("attach_player_node"):
			arguments["attach_player_node"] = "/root/AnimPlayer"
			task["derived_inputs"] = (task.get("derived_inputs", {}) if task.get("derived_inputs", {}) is Dictionary else {})
			task["derived_inputs"]["attach_player_node"] = "/root/AnimPlayer"
		if tool_name in ["list_runtime_animations", "play_runtime_animation",
				"get_runtime_animation_state"] and not arguments.has("node_path"):
			arguments["node_path"] = player_node_path
			task["derived_inputs"] = (task.get("derived_inputs", {}) if task.get("derived_inputs", {}) is Dictionary else {})
			task["derived_inputs"]["node_path"] = player_node_path
		if tool_name == "get_runtime_audio_bus" and not arguments.has("bus_name"):
			arguments["bus_name"] = "Master"
			task["derived_inputs"] = (task.get("derived_inputs", {}) if task.get("derived_inputs", {}) is Dictionary else {})
			task["derived_inputs"]["bus_name"] = "Master"
		if tool_name == "update_runtime_audio_bus" and not arguments.has("bus_name"):
			arguments["bus_name"] = "Master"
			task["derived_inputs"] = (task.get("derived_inputs", {}) if task.get("derived_inputs", {}) is Dictionary else {})
			task["derived_inputs"]["bus_name"] = "Master"
		if tool_name == "play_runtime_animation" and not arguments.has("animation_name"):
			arguments["animation_name"] = "anim"
			task["derived_inputs"] = (task.get("derived_inputs", {}) if task.get("derived_inputs", {}) is Dictionary else {})
			task["derived_inputs"]["animation_name"] = "anim"
	# 瓦片绘制步骤：level profile 固定建 LevelTiles 层；无纹理瓦片集没有图集
	# 可画，给一个擦除型单元格保持步骤可执行且诚实（cells 数组非空）。
	if tool_name == "set_tilemap_layer_cells" and step_profile == "level_design":
		if not arguments.has("node_path"):
			arguments["node_path"] = "/root/LevelTiles"
			task["derived_inputs"] = (task.get("derived_inputs", {}) if task.get("derived_inputs", {}) is Dictionary else {})
			task["derived_inputs"]["node_path"] = "/root/LevelTiles"
		if not arguments.has("cells"):
			arguments["cells"] = [{"coords": [0, 0], "erase": true}, {"coords": [1, 0], "erase": true}]
			task["derived_inputs"] = (task.get("derived_inputs", {}) if task.get("derived_inputs", {}) is Dictionary else {})
			task["derived_inputs"]["cells"] = "default-erase-pattern"
	# 性能预算门缺 budget 时给保守默认（30fps）；目标里的具体数值由调用方覆盖。
	if tool_name == "assert_performance_budget" and not arguments.has("budget"):
		arguments["budget"] = {"min_fps": 30}
		task["derived_inputs"] = (task.get("derived_inputs", {}) if task.get("derived_inputs", {}) is Dictionary else {})
		task["derived_inputs"]["budget"] = {"min_fps": 30}
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
	# 迭代调参（tune_apply）：按磁盘实况读当前值再按方向换算
	# （P2-1：old_text 不再假设固定基线——重复调参 80→52、跨目标
	# 调参都能工作；faster ×1.5 / slower ×0.65）
	if tool_name == "modify_script" and String(task.get("step_key", "")) == "tune_apply":
		var tune_info: Dictionary = parse_tuning_goal(String(plan.get("goal", "")))
		if not tune_info.is_empty():
			var tune_artifacts: Dictionary = (plan.get("workflow", {}) as Dictionary).get("artifacts", {}) \
				if (plan.get("workflow", {}) as Dictionary).get("artifacts", {}) is Dictionary else {}
			arguments["script_path"] = String(tune_artifacts.get("script", ""))
			var tune_param: String = String(tune_info.get("param", "SPEED"))
			# MAGNET 解析名映射到产物常量名 COIN_RADIUS（蓝图已把拾取
			# 半径收敛为单一常量，三处创建点共用）。
			var const_name: String = "COIN_RADIUS" if tune_param == "MAGNET" else tune_param
			var tune_source: String = ""
			if FileAccess.file_exists(String(tune_artifacts.get("script", ""))):
				tune_source = FileAccess.get_file_as_string(String(tune_artifacts.get("script", "")))
			var current_value: float = GameModelStoreScript.current_param_value(tune_source, const_name) \
				if not tune_source.is_empty() else float(tune_info.get("old", "260.0"))
			var tune_direction: String = String(tune_info.get("direction", "faster"))
			var new_value: float = current_value * (1.5 if tune_direction == "faster" else 0.65)
			var tune_old: String = "%.1f" % current_value
			var tune_new: String = "%.1f" % new_value
			arguments["old_text"] = "const %s: float = %s" % [const_name, tune_old]
			arguments["content"] = "const %s: float = %s" % [const_name, tune_new]
			arguments["validate"] = true
			task["derived_inputs"] = (task.get("derived_inputs", {}) if task.get("derived_inputs", {}) is Dictionary else {})
			task["derived_inputs"]["tune"] = "%s %s->%s" % [const_name, tune_old, tune_new]
	# E4 更名目标：rename 步骤缺 symbol_name 时从目标解析（受控模式），
	# 并默认真写（工作流上下文里 dry_run 预览不推进目标）。
	if tool_name == "rename_script_symbol" and not arguments.has("symbol_name"):
		var rename_info: Dictionary = parse_rename_goal(String(plan.get("goal", "")))
		if not rename_info.is_empty():
			arguments["symbol_name"] = rename_info["symbol_name"]
			arguments["new_name"] = rename_info["new_name"]
			arguments["dry_run"] = false
			arguments["search_path"] = "res://"
			task["derived_inputs"] = (task.get("derived_inputs", {}) if task.get("derived_inputs", {}) is Dictionary else {})
			task["derived_inputs"]["rename"] = "%s -> %s" % [rename_info["symbol_name"], rename_info["new_name"]]
	# E1 换键目标：被换键动作的 upsert 覆盖为"擦除旧绑定 + 仅新键"，
	# 演练随后以事件级断言验证旧键失效、新键生效。
	if tool_name == "upsert_project_input_action":
		var remap_info: Dictionary = parse_remap_goal(String(plan.get("goal", "")))
		if not remap_info.is_empty() and String(remap_info.get("new_key", "")) != "" \
				and String(arguments.get("action_name", "")) == String(remap_info["action"]):
			arguments["erase_existing"] = true
			arguments["events"] = [{"type": "key", "keycode": KEY_NAME_TO_CODE[remap_info["new_key"]]}]
			task["derived_inputs"] = (task.get("derived_inputs", {}) if task.get("derived_inputs", {}) is Dictionary else {})
			task["derived_inputs"]["rebind"] = "%s -> %s" % [remap_info["action"], remap_info["new_key"]]
	# 游玩门禁缺步骤时给移动类目标派生输入演练：空 steps 的 play_and_verify
	# 只证明"游戏能启动不崩"，输入驱动的 _physics_process 根本不会执行——
	# 按下四个方向键才能真正跑到控制器逻辑（脚本错误会被本步捕获）。
	if tool_name == "play_and_verify" and not arguments.has("steps"):
		var play_objective: String = String(plan.get("goal", ""))
		# 存档链的两侧门禁各有专属演练（N3）：save_play = 移动+存档+断言
		# 写盘；restore_play = 全新进程读档后断言磁盘状态回归。
		var play_step_key: String = String(task.get("step_key", ""))
		if play_step_key == "tune_baseline" \
				and String(parse_tuning_goal(String(plan.get("goal", ""))).get("param", "")) == "ENEMY_SPEED":
			# 敌速基线（P2-1 v2）：改参前的健全性——敌人确实在巡逻（振幅>10）。
			# 行为方向证明由 tune_verify 的运行时参数铁证承担（相位免疫）。
			arguments["steps"] = _title_unlock_prefix() + [{"wait_frames": 24,
				"assert": {"expression": "abs(_enemy.position.x - 300.0)", "operator": "gt", "expected": 10.0,
					"description": "baseline: the enemy patrols at the pre-tune speed"}}]
			arguments["deterministic"] = true
			task["derived_inputs"] = (task.get("derived_inputs", {}) if task.get("derived_inputs", {}) is Dictionary else {})
			task["derived_inputs"]["steps"] = "tune-baseline-enemy"
		elif play_step_key == "tune_baseline":
			# 基线 = 短右腿健全性。敌人在场时用位移相对式（敌人死亡重置
			# 会干扰绝对阈值——真机审计：累积模式下带敌人的调参基线闪断）。
			arguments["steps"] = _title_unlock_prefix() + [
					{"action": "move_right", "pressed": true, "wait_ms": 400,
						"assert": {"expression": "position.x", "displacement_min": 15,
							"description": "baseline: the player moves at base speed"}},
					{"action": "move_right", "pressed": false, "wait_ms": 80},
				]
			task["derived_inputs"] = (task.get("derived_inputs", {}) if task.get("derived_inputs", {}) is Dictionary else {})
			task["derived_inputs"]["steps"] = "tune-baseline"
		elif play_step_key == "tune_verify" \
				and String(parse_tuning_goal(String(plan.get("goal", ""))).get("param", "")) == "ENEMY_SPEED":
			# 敌速调参验证（P2-1 v2）：运行时参数铁证——断言 ENEMY_SPEED ==
			# 计划新值。常量在运行中的游戏里可读："调了没变"（游戏仍持旧值）
			# 必然失败，且相位免疫。旧振幅对比在峰顶饱和 + 相位噪声下不可比
			# （真机复现：baseline 78.6 vs tuned 78.9——同相位同速度）。
			var verify_enemy_steps: Array = [
				{"wait_frames": 24,
					"assert": {"expression": "abs(_enemy.position.x - 300.0)", "operator": "gt", "expected": 10.0,
						"description": "the enemy still patrols after tuning (behavior alive)"}},
			]
			var planned_enemy: Dictionary = {}
			if (plan.get("workflow", {}) as Dictionary).get("artifacts", {}) is Dictionary:
				planned_enemy = ((plan.get("workflow", {}) as Dictionary)["artifacts"] as Dictionary).get("tune_planned", {})
			if planned_enemy is Dictionary and String(planned_enemy.get("param", "")) == "ENEMY_SPEED":
				verify_enemy_steps.append({
					"assert": {"expression": "ENEMY_SPEED", "operator": "eq",
						"expected": float(planned_enemy.get("new", 0.0)),
						"description": "the tuned speed is live in the running game (unchanged parameters cannot pass)"}
				})
			arguments["steps"] = _title_unlock_prefix() + verify_enemy_steps
			arguments["deterministic"] = true
			task["derived_inputs"] = (task.get("derived_inputs", {}) if task.get("derived_inputs", {}) is Dictionary else {})
			task["derived_inputs"]["steps"] = "tune-verify-enemy"
		elif play_step_key == "tune_verify" \
				and String(parse_tuning_goal(String(plan.get("goal", ""))).get("param", "")) == "MAGNET":
			# 磁吸半径验证（P2-2）：配置级（新半径值已生效，计划值由
			# runner 在 tune_apply 成功后记入工件）+ 行为级（拾取仍完成）。
			var magnet_steps: Array = [
				{"action": "move_right", "pressed": true, "wait_ms": 1200},
				{"action": "move_right", "pressed": false, "wait_ms": 300,
					"assert": {"expression": "coins_collected", "operator": "gt", "expected": 0,
						"description": "pickup still works at the tuned radius"}},
			]
			var planned_magnet: Dictionary = {}
			if (plan.get("workflow", {}) as Dictionary).get("artifacts", {}) is Dictionary:
				planned_magnet = ((plan.get("workflow", {}) as Dictionary)["artifacts"] as Dictionary).get("tune_planned", {})
			if planned_magnet is Dictionary and String(planned_magnet.get("param", "")) == "COIN_RADIUS":
				magnet_steps.append({
					"assert": {"expression": "COIN_RADIUS", "operator": "eq",
						"expected": float(planned_magnet.get("new", 0.0)),
						"description": "tuned pickup radius is in effect"}
				})
			arguments["steps"] = _title_unlock_prefix() + magnet_steps
			task["derived_inputs"] = (task.get("derived_inputs", {}) if task.get("derived_inputs", {}) is Dictionary else {})
			task["derived_inputs"]["steps"] = "tune-verify-magnet"
		elif play_step_key == "tune_verify":
			# 对比用帧步进位移 delta（起点无关，且区分调参前后）：
			# 20 物理帧保持下 260px/s ≈ 86px，360px/s ≈ 120px，180px/s ≈ 60px。
			# 阈值卡在两档之间——"调了但没变"不可能通过。
			var verify_tune: Dictionary = parse_tuning_goal(String(plan.get("goal", "")))
			var verify_threshold: float = 100.0
			var verify_operator: String = "gt"
			var verify_note: String = "tuned faster: 20-frame hold delta > 100px (base was ~86)"
			if not verify_tune.is_empty() and String(verify_tune["direction"]) == "slower":
					verify_threshold = 75.0
					verify_operator = "lt"
					verify_note = "tuned slower: 20-frame hold delta < 75px (base was ~86)"
			arguments["steps"] = _title_unlock_prefix() + [
					{"action": "move_right", "pressed": true, "wait_frames": 20},
					{"action": "move_right", "pressed": false, "wait_ms": 80},
				]
			arguments["deterministic"] = true
			arguments["sample"] = [{"label": "px", "expression": "position.x"}]
			arguments["assertions"] = [{
				"metric": "px", "aggregate": "delta", "operator": verify_operator,
				"expected": verify_threshold, "description": verify_note,
			}]
			task["derived_inputs"] = (task.get("derived_inputs", {}) if task.get("derived_inputs", {}) is Dictionary else {})
			task["derived_inputs"]["steps"] = "tune-verify"
		elif play_step_key == "save_play":
			arguments["steps"] = _title_unlock_prefix() + _save_play_steps()
			task["derived_inputs"] = (task.get("derived_inputs", {}) if task.get("derived_inputs", {}) is Dictionary else {})
			task["derived_inputs"]["steps"] = "save-exercise"
		elif play_step_key == "restore_play":
			arguments["steps"] = _restore_play_steps()
			task["derived_inputs"] = (task.get("derived_inputs", {}) if task.get("derived_inputs", {}) is Dictionary else {})
			task["derived_inputs"]["steps"] = "save-restore-exercise"
		else:
			# 按需演练：累积模式下（注册表非空），非首目标的主演练只测
			# 新增功能的腿 + boot-settle——不重测全部功能（每个目标的演练
			# 与本目标新增内容成比例，旧功能由各自目标的门禁和账本回归覆盖）。
			var accumulation_mode: bool = not FeatureRegistryScript.registered_verbs().is_empty()
			if accumulation_mode:
				var is_tune: bool = not parse_tuning_goal(play_objective).is_empty()
				if is_tune:
					arguments["steps"] = [{"wait_ms": 600}]
					task["derived_inputs"] = (task.get("derived_inputs", {}) if task.get("derived_inputs", {}) is Dictionary else {})
					task["derived_inputs"]["steps"] = "tune-boot-settle"
				else:
					var reg_verbs: Dictionary = FeatureRegistryScript.registered_verbs()
					var goal_verbs: Dictionary = GoalBlueprintsScript.match_verbs(play_objective)
					var on_demand: Array = [{"wait_ms": 600}]
					if bool(reg_verbs.get("state_machine", false)) \
							and not bool(goal_verbs.get("state_machine", false)):
						# 双 Enter（P1-6）：任意起步态都能进 playing——win→title→playing
						# 或 title→playing（playing 态下 Enter 无副作用）。单次 Enter
						# 从 win 起步会停在 title，演练被门控空转。
						on_demand.append({"action": "ui_accept", "pressed": true, "wait_ms": 300})
						on_demand.append({"action": "ui_accept", "pressed": false, "wait_ms": 100})
						on_demand.append({"action": "ui_accept", "pressed": true, "wait_ms": 300})
						on_demand.append({"action": "ui_accept", "pressed": false, "wait_ms": 100})
					if bool(goal_verbs.get("state_machine", false)):
						on_demand.append_array(_state_play_steps())
					if bool(goal_verbs.get("movement", false)) and not bool(reg_verbs.get("movement", false)):
						on_demand.append_array(_movement_play_steps())
					if (bool(goal_verbs.get("collectible", false)) or bool(goal_verbs.get("audio", false))) \
							and not bool(reg_verbs.get("collectible", false)):
						on_demand.append_array(_collect_play_steps())
					if bool(goal_verbs.get("enemy", false)) and not bool(reg_verbs.get("enemy", false)):
						var enemy_legs: Dictionary = _enemy_play_legs()
						on_demand.append_array(enemy_legs["steps"])
						arguments["deterministic"] = true
						arguments["sample"] = enemy_legs["sample"]
						arguments["assertions"] = enemy_legs["assertions"]
					if bool(goal_verbs.get("pause", false)) and not bool(reg_verbs.get("pause", false)):
						on_demand.append_array(_pause_play_steps())
					if bool(goal_verbs.get("save", false)) and not bool(reg_verbs.get("save", false)):
						on_demand.append_array(_save_play_steps())
					arguments["steps"] = on_demand
					task["derived_inputs"] = (task.get("derived_inputs", {}) if task.get("derived_inputs", {}) is Dictionary else {})
					task["derived_inputs"]["steps"] = "on-demand" if on_demand.size() > 1 else "revisit-boot-settle"
			else:
				_derive_generic_play_steps(plan, task, tool_name, arguments)
				# generic 分支保留在 _derive_generic_play_steps 中实现
	# 首个主题步骤同理：按 profile 推导确定性 .tres 路径。
	if tool_name == "create_theme" and not arguments.has("theme_path") \
			and not artifacts.has("theme"):
		var theme_slug: String = step_profile.replace("_", "-") if not step_profile.is_empty() else "game"
		arguments["theme_path"] = "res://themes/%s.tres" % theme_slug
		task["derived_inputs"] = (task.get("derived_inputs", {}) if task.get("derived_inputs", {}) is Dictionary else {})
		task["derived_inputs"]["theme_path"] = arguments["theme_path"]
	# 首个 TileSet 步骤同理：按 profile 推导确定性 .tres 路径。
	if tool_name == "create_tileset" and not arguments.has("tileset_path") 			and not artifacts.has("tileset"):
		var tileset_slug: String = step_profile.replace("_", "-") if not step_profile.is_empty() else "game"
		arguments["tileset_path"] = "res://tilesets/%s.tres" % tileset_slug
		task["derived_inputs"] = (task.get("derived_inputs", {}) if task.get("derived_inputs", {}) is Dictionary else {})
		task["derived_inputs"]["tileset_path"] = arguments["tileset_path"]
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
	# preset 是 schema 必填项：调用方自带 node_path 而未给 preset 时同样
	# 派生 CENTER(8)，否则该步仍会停在 needs_input。
	elif tool_name == "set_anchor_preset" and not arguments.has("preset") \
			and arguments.has("node_path"):
		arguments["preset"] = 8
		task["derived_inputs"] = (task.get("derived_inputs", {}) if task.get("derived_inputs", {}) is Dictionary else {})
		task["derived_inputs"]["preset"] = 8
	if tool_name in RUNTIME_WINDOW_TOOLS and not arguments.has("allow_window"):
		arguments["allow_window"] = true
	var focus_param: String = String(FOCUS_POLICY_TOOLS.get(tool_name, ""))
	if not focus_param.is_empty() and not arguments.has(focus_param):
		arguments[focus_param] = true
	# wait_frames 只在 deterministic=true 时步进（执行器契约）——任何演练
	# 含帧步进步而未设标志 = 零等待立即断言（真缺陷：帧步进迁移后移动/
	# 收集/存档/状态演练静默失效，位移恒 0，多轮退化至此）。统一出口兜底。
	if tool_name == "play_and_verify" and arguments.has("steps") \
			and not bool(arguments.get("deterministic", false)):
		for step_value in arguments["steps"]:
			if step_value is Dictionary and (step_value as Dictionary).has("wait_frames"):
				arguments["deterministic"] = true
				break
	return arguments

## Visual gates derive candidate_path from the latest runtime screenshot and a
## deterministic baseline location. On a fresh project the gate bootstraps the
## golden image itself (status baseline_created, passed=false); the workflow
## engine annotates that round as bootstrap evidence and the next run compares
## against the stored baseline, so the gate never stalls on missing paths and
## never reports a capture as a visual verification pass.
## 常用键名 → KEY_* 常量（E1 换键解析的受控词表；越界键名解析失败即
## 不派生，宁可让通用路径接手也不猜）。
const KEY_NAME_TO_CODE: Dictionary = {
	"A": KEY_A, "B": KEY_B, "C": KEY_C, "D": KEY_D, "E": KEY_E, "F": KEY_F,
	"G": KEY_G, "H": KEY_H, "I": KEY_I, "J": KEY_J, "K": KEY_K, "L": KEY_L,
	"M": KEY_M, "N": KEY_N, "O": KEY_O, "P": KEY_P, "Q": KEY_Q, "R": KEY_R,
	"S": KEY_S, "T": KEY_T, "U": KEY_U, "V": KEY_V, "W": KEY_W, "X": KEY_X,
	"Y": KEY_Y, "Z": KEY_Z,
	"UP": KEY_UP, "DOWN": KEY_DOWN, "LEFT": KEY_LEFT, "RIGHT": KEY_RIGHT,
	"SPACE": KEY_SPACE, "ENTER": KEY_ENTER, "ESC": KEY_ESCAPE,
	"F1": KEY_F1, "F2": KEY_F2, "F3": KEY_F3, "F4": KEY_F4, "F5": KEY_F5,
	"F6": KEY_F6, "F7": KEY_F7, "F8": KEY_F8, "F9": KEY_F9, "F10": KEY_F10,
	"F11": KEY_F11, "F12": KEY_F12,
}

const REMAP_KEYWORDS: Array[String] = [
	"rebind", "remap", "reassign", "rebind ", "换键", "改键", "重绑", "改成",
]

const RENAME_GOAL_KEYWORDS: Array[String] = ["rename", "更名", "重命名", "改名为", "改名成"]

## 解析更名目标（E4）："rename <ident> to <ident>" / 中文
## "把 X 更名/重命名/改名为 Y"。两个标识符都是合法 GDScript 名才派生。
static func parse_rename_goal(goal: String) -> Dictionary:
	var text: String = " " + goal.to_lower() + " "
	var has_rename_verb: bool = false
	for keyword in RENAME_GOAL_KEYWORDS:
		if text.contains(keyword.to_lower()):
			has_rename_verb = true
			break
	if not has_rename_verb:
		return {}
	var ident_regex: RegEx = RegEx.new()
	if ident_regex.compile("[a-z_][a-z0-9_]*") != OK:
		return {}
	# 英文模式：rename X ... to Y
	var to_index: int = text.find(" to ")
	if to_index > 0:
		var before: String = text.substr(0, to_index)
		var after: String = text.substr(to_index + 4)
		var old_idents: Array = []
		for match_value in ident_regex.search_all(before):
			var candidate: String = String(match_value.get_string())
			if candidate not in ["rename", "the", "field", "variable", "signal", "function", "symbol", "to", "and", "in", "scripts", "script"]:
				old_idents.append(candidate)
		var new_idents: Array = []
		for match_value in ident_regex.search_all(after):
			var candidate2: String = String(match_value.get_string())
			if candidate2 not in ["in", "the", "scripts", "script", "everywhere", "and", "keep"]:
				new_idents.append(candidate2)
		if not old_idents.is_empty() and not new_idents.is_empty():
			return {"symbol_name": old_idents[old_idents.size() - 1], "new_name": new_idents[0]}
	# 中文模式：把 X 更名/重命名/改名为 Y
	for zh_verb in ["更名", "重命名", "改名为", "改名成"]:
		var verb_index: int = text.find(zh_verb)
		if verb_index > 0:
			var zh_before: String = text.substr(0, verb_index)
			var zh_after: String = text.substr(verb_index + zh_verb.length())
			var zh_old: Array = []
			for match_value in ident_regex.search_all(zh_before):
				zh_old.append(String(match_value.get_string()))
			var zh_new: Array = []
			for match_value in ident_regex.search_all(zh_after):
				zh_new.append(String(match_value.get_string()))
			if not zh_old.is_empty() and not zh_new.is_empty():
				return {"symbol_name": zh_old[zh_old.size() - 1], "new_name": zh_new[0]}
	return {}

## 解析换键目标（E1，受控模式）："rebind <action> (from <key>) to <key>" /
## 中文"把 <action> (从 <key>) 改成 <key> 键"。解析不出完整三元组时
## old_key 可空（只验证新键生效）；action 不在受控动作表内则返回空。
static func parse_remap_goal(goal: String) -> Dictionary:
	var text: String = " " + goal.to_lower() + " "
	var has_remap_verb: bool = false
	for keyword in REMAP_KEYWORDS:
		if text.contains(keyword.to_lower()):
			has_remap_verb = true
			break
	if not has_remap_verb:
		return {}
	var action: String = ""
	for candidate in ["move_left", "move_right", "move_up", "move_down", "jump", "dash"]:
		if text.contains(candidate):
			action = candidate
			break
	if action.is_empty():
		return {}
	# 键名候选：受控词表中的任何词出现在目标里，按出现位置排序
	# （"from X to Y" 的归属由位置决定，与词表遍历顺序无关）
	var key_hits: Array = []
	for key_name in KEY_NAME_TO_CODE.keys():
		var lowered: String = key_name.to_lower()
		var position: int = text.find(" " + lowered + " ")
		if position < 0:
			position = text.find(" " + lowered + " key")
		if position < 0:
			position = text.find(lowered + " 键")
		if position >= 0:
			key_hits.append({"position": position, "key": key_name.to_upper()})
	if key_hits.is_empty():
		return {"action": action}
	key_hits.sort_custom(func(a, b) -> bool: return int(a["position"]) < int(b["position"]))
	var old_key: String = ""
	var new_key: String = ""
	var from_index: int = text.find(" from ")
	if from_index < 0:
		from_index = text.find(" 从 ")
	for hit_value in key_hits:
		var hit: Dictionary = hit_value
		if from_index >= 0 and int(hit["position"]) > from_index:
			old_key = String(hit["key"])
			break
	if old_key != "":
		for hit_value in key_hits:
			var hit2: Dictionary = hit_value
			if String(hit2["key"]) != old_key and int(hit2["position"]) > from_index:
				new_key = String(hit2["key"])
				break
		if new_key == "":
			# from 之后只有一个键：它就是新键（旧键未明说）
			new_key = old_key
			old_key = ""
	else:
		new_key = String(key_hits[key_hits.size() - 1]["key"])
		if key_hits.size() > 1:
			old_key = String(key_hits[0]["key"])
	return {"action": action, "old_key": old_key, "new_key": new_key}

## Phase B 累积目标构建：从动词集构建一个能触发所有动词的目标语句。
## controller_script 按关键词匹配动词，所以只要语句包含每个动词的
## 触发词，生成的控制器就包含所有功能。
## P1-2 数量保留：金币/敌人数量由游戏模型核算后写进语句——
## "已有移动，再加 3 个金币"不再退化为 "collect a coin"（数量 1）；
## "再加一个敌人" 走增量语义（existing + 1）。增量只作用于目标真正
## 提到的种类："加另一个敌人"不得给金币 +1（真机复现：coins 3→4）。
func _build_merged_objective(merged_verbs: Dictionary, original_goal: String) -> String:
	var parts: Array = []
	var additive: bool = GoalBlueprintsScript.is_additive_request(original_goal)
	var additive_coins: bool = additive \
		and GoalBlueprintsScript._mentions(original_goal, GoalBlueprintsScript.COLLECTIBLE_KEYWORDS)
	var additive_enemies: bool = additive \
		and GoalBlueprintsScript._mentions(original_goal, GoalBlueprintsScript.ENEMY_KEYWORDS)
	if bool(merged_verbs.get("movement", false)):
		parts.append("arrow-key movement")
	if bool(merged_verbs.get("collectible", false)):
		var coin_total: int = GameModelStoreScript.merged_count("coins",
			GoalBlueprintsScript._coin_count(original_goal), additive_coins)
		parts.append("collect %d coins" % coin_total)
	if bool(merged_verbs.get("win", false)):
		parts.append("win label")
	if bool(merged_verbs.get("pause", false)):
		parts.append("pause menu")
	if bool(merged_verbs.get("save", false)):
		parts.append("save/load")
	if bool(merged_verbs.get("enemy", false)):
		var enemy_total: int = GameModelStoreScript.merged_count("enemies",
			GoalBlueprintsScript._enemy_count(original_goal), additive_enemies)
		parts.append("%d patrolling enemies" % enemy_total)
	if bool(merged_verbs.get("state_machine", false)):
		parts.append("title screen game flow restart")
	if bool(merged_verbs.get("audio", false)):
		parts.append("sound effect")
	if bool(merged_verbs.get("wall", false)):
		parts.append("walls")
	if bool(merged_verbs.get("three_d", false)):
		parts.append("3D")
	if parts.is_empty():
		return original_goal
	return ", ".join(parts)

## Phase B 增量代码块生成：只为尚未注册的动词生成功能块，追加到现有
## 控制器末尾（不覆盖已有功能）。返回空串表示无需追加。
func _generate_incremental_blocks(new_verbs: Dictionary, current_source: String) -> String:
	var blocks: String = ""
	# 收集动词（需要收集代码块）
	if bool(new_verbs.get("collectible", false)) and not current_source.contains("_coin_area"):
		blocks += "\n# --- incremental: collectible ---\n"
		blocks += "var _coin_area: Area2D\n"
		blocks += "const COINS_TO_WIN: int = 1\n"
		blocks += "var coins_collected: int = 0\n"
		blocks += "\nfunc _spawn_coin() -> void:\n"
		blocks += "\t_coin_area = Area2D.new()\n"
		blocks += "\t_coin_area.name = \"Coin\"\n"
		blocks += "\t_coin_area.position = Vector2(200, 0)\n"
		blocks += "\tvar coin_col := CollisionShape2D.new()\n"
		blocks += "\tvar coin_shape := CircleShape2D.new()\n"
		blocks += "\tcoin_shape.radius = 90\n"
		blocks += "\tcoin_col.shape = coin_shape\n"
		blocks += "\t_coin_area.add_child(coin_col)\n"
		blocks += "\t_coin_area.body_entered.connect(_on_coin_touched)\n"
		blocks += "\tget_parent().add_child.call_deferred(_coin_area)\n"
		blocks += "\nfunc _on_coin_touched(body: Node) -> void:\n"
		blocks += "\tif body != self:\n"
		blocks += "\t\treturn\n"
		blocks += "\tcoins_collected += 1\n"
		blocks += "\t_coin_area.queue_free()\n"
	# 暂停动词
	if bool(new_verbs.get("pause", false)) and not current_source.contains("set_paused"):
		blocks += "\n# --- incremental: pause ---\n"
		blocks += "var _pause_label: Label\n"
		blocks += "\nfunc _setup_pause() -> void:\n"
		blocks += "\tprocess_mode = Node.PROCESS_MODE_ALWAYS\n"
		blocks += "\tvar pause_layer := CanvasLayer.new()\n"
		blocks += "\tpause_layer.name = \"PauseLayer\"\n"
		blocks += "\tadd_child(pause_layer)\n"
		blocks += "\t_pause_label = Label.new()\n"
		blocks += "\t_pause_label.name = \"PauseLabel\"\n"
		blocks += "\t_pause_label.text = \"Paused - press Esc to resume\"\n"
		blocks += "\t_pause_label.visible = false\n"
		blocks += "\tpause_layer.add_child(_pause_label)\n"
		blocks += "\nfunc set_paused(value: bool) -> void:\n"
		blocks += "\tget_tree().paused = value\n"
		blocks += "\tif _pause_label != null:\n"
		blocks += "\t\t_pause_label.visible = value\n"
	# 敌人动词
	if bool(new_verbs.get("enemy", false)) and not current_source.contains("_enemy"):
		blocks += "\n# --- incremental: enemy ---\n"
		blocks += "var _enemy: Area2D\n"
		blocks += "var deaths_count: int = 0\n"
		blocks += "var _enemy_time: float = 0.0\n"
		blocks += "const ENEMY_HOME_X: float = 300.0\n"
		blocks += "const ENEMY_RANGE: float = 80.0\n"
		blocks += "\nfunc _setup_enemy() -> void:\n"
		blocks += "\t_enemy = Area2D.new()\n"
		blocks += "\t_enemy.name = \"Enemy\"\n"
		blocks += "\t_enemy.position = Vector2(ENEMY_HOME_X, 0)\n"
		blocks += "\tvar enemy_col := CollisionShape2D.new()\n"
		blocks += "\tvar enemy_shape := RectangleShape2D.new()\n"
		blocks += "\tenemy_shape.size = Vector2(16, 240)\n"
		blocks += "\tenemy_col.shape = enemy_shape\n"
		blocks += "\t_enemy.add_child(enemy_col)\n"
		blocks += "\t_enemy.body_entered.connect(_on_enemy_touched)\n"
		blocks += "\tget_parent().add_child.call_deferred(_enemy)\n"
		blocks += "\nfunc _on_enemy_touched(body: Node) -> void:\n"
		blocks += "\tif body != self:\n"
		blocks += "\t\treturn\n"
		blocks += "\tdeaths_count += 1\n"
		blocks += "\tposition = Vector2.ZERO\n"
	# 存档动词
	if bool(new_verbs.get("save", false)) and not current_source.contains("save_game"):
		blocks += "\n# --- incremental: save/load ---\n"
		blocks += "const SAVE_PATH := \"user://save_game.json\"\n"
		blocks += "var last_save_ok: bool = false\n"
		blocks += "\nfunc save_game() -> bool:\n"
		blocks += "\tvar data := {\"coins\": coins_collected, \"x\": position.x, \"y\": position.y}\n"
		blocks += "\tvar file := FileAccess.open(SAVE_PATH, FileAccess.WRITE)\n"
		blocks += "\tif file == null:\n"
		blocks += "\t\treturn false\n"
		blocks += "\tfile.store_string(JSON.stringify(data))\n"
		blocks += "\treturn true\n"
		blocks += "\nfunc load_game() -> bool:\n"
		blocks += "\tif not FileAccess.file_exists(SAVE_PATH):\n"
		blocks += "\t\treturn false\n"
		blocks += "\tvar file := FileAccess.open(SAVE_PATH, FileAccess.READ)\n"
		blocks += "\tif file == null:\n"
		blocks += "\t\treturn false\n"
		blocks += "\tvar parsed: Variant = JSON.parse_string(file.get_as_text())\n"
		blocks += "\tif not (parsed is Dictionary):\n"
		blocks += "\t\treturn false\n"
		blocks += "\tcoins_collected = int(parsed.get(\"coins\", 0))\n"
		blocks += "\tposition = Vector2(float(parsed.get(\"x\", 0.0)), float(parsed.get(\"y\", 0.0)))\n"
		blocks += "\treturn true\n"
	# 音效动词
	if bool(new_verbs.get("audio", false)) and not current_source.contains("_sfx_player"):
		blocks += "\n# --- incremental: audio ---\n"
		blocks += "var sfx_played_count: int = 0\n"
		blocks += "var _sfx_player: AudioStreamPlayer\n"
		blocks += "\nfunc _setup_sfx() -> void:\n"
		blocks += "\t_sfx_player = AudioStreamPlayer.new()\n"
		blocks += "\t_sfx_player.name = \"SfxPlayer\"\n"
		blocks += "\tadd_child(_sfx_player)\n"
		blocks += "\t_sfx_player.stream = _generate_blip()\n"
		blocks += "\nfunc _generate_blip() -> AudioStreamWAV:\n"
		blocks += "\tvar sample_rate: int = 22050\n"
		blocks += "\tvar frames: int = int(0.4 * sample_rate)\n"
		blocks += "\tvar pcm := PackedByteArray()\n"
		blocks += "\tpcm.resize(frames * 2)\n"
		blocks += "\tfor i in range(frames):\n"
		blocks += "\t\tvar decay: float = 1.0 - float(i) / float(frames)\n"
		blocks += "\t\tvar square: float = 1.0 if fmod(float(i) * 880.0 / float(sample_rate), 2.0) < 1.0 else -1.0\n"
		blocks += "\t\tpcm.encode_s16(i * 2, int(square * decay * 12000.0))\n"
		blocks += "\tvar wav := AudioStreamWAV.new()\n"
		blocks += "\twav.format = AudioStreamWAV.FORMAT_16_BITS\n"
		blocks += "\twav.mix_rate = sample_rate\n"
		blocks += "\twav.data = pcm\n"
		blocks += "\treturn wav\n"
	# 墙动词
	if bool(new_verbs.get("wall", false)) and not current_source.contains("WallRight"):
		blocks += "\n# --- incremental: walls ---\n"
		blocks += "\nfunc _setup_walls() -> void:\n"
		blocks += "\tfor wall_spec in [{\"name\": \"WallRight\", \"x\": 500.0}, {\"name\": \"WallLeft\", \"x\": -40.0}]:\n"
		blocks += "\t\tvar wall_node := StaticBody2D.new()\n"
		blocks += "\t\twall_node.name = wall_spec[\"name\"]\n"
		blocks += "\t\twall_node.position = Vector2(wall_spec[\"x\"], 0)\n"
		blocks += "\t\tvar wall_col := CollisionShape2D.new()\n"
		blocks += "\t\tvar wall_shape := RectangleShape2D.new()\n"
		blocks += "\t\twall_shape.size = Vector2(16, 240)\n"
		blocks += "\t\twall_col.shape = wall_shape\n"
		blocks += "\t\twall_node.add_child(wall_col)\n"
		blocks += "\t\tget_parent().add_child.call_deferred(wall_node)\n"
	return blocks

## 标题解锁前缀（P1-6 配套）：注册表已有 state_machine 时，游戏从标题
## （或上一轮演练留下的 win 态）启动——调参/存档等演练先双 Enter 进入
## playing（win→title→playing 或 title→playing；playing 态 Enter 无副作用）。
## 不解锁时采样/位移发生在门控之下：敌人冻结、玩家不动，基线必假。
func _title_unlock_prefix() -> Array:
	if not bool(FeatureRegistryScript.registered_verbs().get("state_machine", false)):
		return []
	return [
		{"action": "ui_accept", "pressed": true, "wait_ms": 300,
			"description": "enter playing state (win or title start)"},
		{"action": "ui_accept", "pressed": false, "wait_ms": 100},
		{"action": "ui_accept", "pressed": true, "wait_ms": 300},
		{"action": "ui_accept", "pressed": false, "wait_ms": 100},
	]

## 换键演练（E1 行为证据，事件级）：旧键按下必须**无效**（位移不变），
## 新键按下必须生效（位移达成），再跑其余轴向回归——防误伤。
func _remap_play_steps(action: String, old_key: String, new_key: String) -> Array:
	var steps: Array = []
	# 回归先行（四向位移断言以原点为基准）；remap 腿随后——inert 断言
	# 用步前快照（位移相对），在任意起步位置都成立。
	steps.append_array(_movement_play_steps())
	var axis_expression: String = "position.x"
	var axis_moved_operator: String = "gt"
	var axis_moved_value: int = 15
	if action in ["move_up", "move_down", "jump"]:
		axis_expression = "position.y"
	if action in ["move_left", "move_up"]:
		axis_moved_operator = "lt"
		axis_moved_value = -15
	if not old_key.is_empty():
		steps.append({
			"event": {"type": "key", "keycode": KEY_NAME_TO_CODE.get(old_key, 0), "pressed": true},
			"wait_ms": 350,
			"assert": {"expression": axis_expression, "inert": true,
				"description": "old binding is inert after the rebind (%s)" % old_key}
		})
		steps.append({
			"event": {"type": "key", "keycode": KEY_NAME_TO_CODE.get(old_key, 0), "pressed": false},
			"wait_ms": 80
		})
	steps.append({
		"event": {"type": "key", "keycode": KEY_NAME_TO_CODE.get(new_key, 0), "pressed": true},
		"wait_ms": 400,
		"screenshot": true,
		"assert": ({"expression": axis_expression, "displacement_min": 15,
			"description": "new binding moves the player (%s)" % new_key}
			if axis_moved_operator == "gt" else
			{"expression": axis_expression, "displacement_max": -15,
			"description": "new binding moves the player (%s)" % new_key})
	})
	steps.append({
		"event": {"type": "key", "keycode": KEY_NAME_TO_CODE.get(new_key, 0), "pressed": false},
		"wait_ms": 80
	})
	return steps

## 移动类目标的游玩演练：四方向按键各配位移断言。蓝图控制器的
## _physics_process 只有在输入驱动下才会执行，脚本错误才会暴露给
## play_and_verify 的错误捕获；而位移断言进一步证明移动真的发生——
## 控制器没挂上或没在动时，门禁必须失败而不是空转通过。
func _movement_play_steps() -> Array:
	# 移动演练带位移断言（N1 oracle 形态）：蓝图场景根在原点、SPEED=260、
	# 60fps 物理。**确定性帧步进**（wait_frames 24 = 恰好 104px，与机器
	# 负载无关——墙钟等待在冷启动/高负载下物理帧缩水 ±40%，位移断言
	# 轮换闪断的根本原因；真机 11 轮复现）。阈值 15px 留 6 倍余量。
	# 没有这些断言，门禁只证明"按键已发送"，控制器没挂上/没在动也照样
	# 通过（#124 真机 E2E 抓到过这种空转）。
	# 位移相对断言（步前快照差值）：起点无关——任何起点都测"本腿走够没有"。
	var steps: Array = []
	steps.append({
		"action": "move_right", "pressed": true, "wait_frames": 24,
		"assert": {"expression": "position.x", "displacement_min": 15,
			"description": "player moved right while holding move_right"}
	})
	steps.append({"action": "move_right", "pressed": false, "wait_ms": 80})
	steps.append({
		"action": "move_left", "pressed": true, "wait_frames": 24,
		"assert": {"expression": "position.x", "displacement_max": -15,
			"description": "player moved left while holding move_left"}
	})
	steps.append({"action": "move_left", "pressed": false, "wait_ms": 80})
	steps.append({
		"action": "move_up", "pressed": true, "wait_frames": 24,
		"assert": {"expression": "position.y", "displacement_max": -15,
			"description": "player moved up while holding move_up"}
	})
	steps.append({"action": "move_up", "pressed": false, "wait_ms": 80})
	steps.append({
		"action": "move_down", "pressed": true, "wait_frames": 24,
		"assert": {"expression": "position.y", "displacement_min": 15,
			"description": "player moved down while holding move_down"}
	})
	steps.append({"action": "move_down", "pressed": false, "wait_ms": 80})
	return steps

## 暂停类目标的游玩演练（评测任务 N2 的行为证据）：
## Esc 暂停 → 断言 get_tree().paused == true（附暂停画面截图）→
## Esc 恢复 → 断言 == false。步内断言按序求值，任一不通过即门禁失败。
func _pause_play_steps() -> Array:
	var steps: Array = []
	steps.append({
		"action": "ui_cancel", "pressed": true, "wait_ms": 400,
		"screenshot": true,
		"assert": {
			"expression": "get_tree().paused", "expected": true,
			"description": "world pauses after Esc"
		}
	})
	steps.append({"action": "ui_cancel", "pressed": false, "wait_ms": 120})
	steps.append({
		"action": "ui_cancel", "pressed": true, "wait_ms": 400,
		"assert": {
			"expression": "get_tree().paused", "expected": false,
			"description": "world resumes after the second Esc"
		}
	})
	steps.append({"action": "ui_cancel", "pressed": false, "wait_ms": 120})
	return steps

## 手感腿（P3 feel 预算）：确定性帧步进下按住输入 20 物理帧并逐帧采样
## position.x——delta ≥ 60px 证明输入→响应延迟 ≤ ~3 帧（20 帧全速理论
## 86px）。非确定性墙钟等待测不了延迟，只有帧步进能。
func _movement_feel_legs() -> Dictionary:
	return {
		"steps": [
			{"action": "move_right", "pressed": true, "wait_frames": 20},
			{"action": "move_right", "pressed": false, "wait_ms": 80},
		],
		"sample": [{"label": "px", "expression": "position.x"}],
		"assertions": [{
			"metric": "px", "aggregate": "delta", "operator": "gt", "expected": 60,
			"description": "input->response feel: 20 held physics frames displace >= 60px (response within ~3 frames)"
		}],
	}

## 收集腿（评测 N1 收集面）：走到金币（蓝图固定 (180,120)）→ 断言
## 金币已消失、计数已增、胜利标签已显示——收集/胜利的行为证据。
func _collect_play_steps(coin_count_expression: String = "coins_collected") -> Array:
	var steps: Array = []
	# 先回归原点：save 恢复或上一轮演练可能把玩家留在金币右侧——从右侧
	# 起扫一无所获，"金币已消失"断言闪断（真机复现：goal 06 完成前回归）。
	# 左扫最多撞左墙（或死于敌带重置回原点）——两种结局都锚定原点附近。
	# 帧步进（72 帧 = 312px）：与机器负载无关的确定性锚定。
	steps.append({"action": "move_left", "pressed": true, "wait_frames": 72})
	steps.append({"action": "move_left", "pressed": false, "wait_ms": 200})
	# 磁吸金币聚簇在 (110..190)：从原点右扫横扫必然穿越全部拾取窗
	# （开环 + 宽恕半径 = 确定性收集）。96 帧 = 416px，远超最后一窗 (292)。
	steps.append({"action": "move_right", "pressed": true, "wait_frames": 96})
	steps.append({
		"action": "move_right", "pressed": false, "wait_ms": 400, "screenshot": true,
		"assert": {"expression": coin_count_expression, "operator": "gt", "expected": 0,
			"description": "the coin was collected by the sweep"}
	})
	steps.append({
		"assert": {"expression": "_coin_area == null or not is_instance_valid(_coin_area)",
			"expected": true,
			"description": "the collected coin is gone from the tree"}
	})
	steps.append({
		"assert": {"expression": "_win_label.text", "expected": "You Win!",
			"description": "the win label shows after collection"}
	})
	return steps

## 迭代调参（闭环的"玩→调→再玩"）：解析方向 → 派生 modify_script 的
## SPEED 调整（跟手/更快 = +30%，更慢 = -30%）→ 对比演练断言位移朝
## 请求方向变化。"调了但没变"不算完成。
static func parse_tuning_goal(goal: String) -> Dictionary:
	var text: String = " " + goal.to_lower() + " "
	if not GoalBlueprintsScript._mentions(goal, GoalBlueprintsScript.TUNING_KEYWORDS):
		return {}
	# 调参方向：用户说"太快了"= 太快 = 需要更慢；"太慢了"= 太慢 = 需要更快。
	# 中英语义一致：too fast → slower, too slow → faster（真实审计发现原实现反向）。
	var wants_faster: bool = text.contains("faster") or text.contains("snappier") \
		or text.contains("more responsive") or text.contains("too slow") \
		or text.contains("更跟手") or text.contains("更灵敏") or text.contains("调快") \
		or text.contains("太慢") or text.contains("跟手")
	var wants_slower: bool = text.contains("slower") or text.contains("too fast") \
		or text.contains("调慢") or text.contains("太快")
	# Q4 多参数调参：除 SPEED 外，敌速/磁吸半径/跳跃力也可调
	if text.contains("enemy") or text.contains("敌人"):
		if wants_faster:
			return {"direction": "faster", "param": "ENEMY_SPEED", "old": "120.0", "new": "180.0"}
		if wants_slower:
			return {"direction": "slower", "param": "ENEMY_SPEED", "old": "120.0", "new": "80.0"}
	if text.contains("magnet") or text.contains("磁吸") or text.contains("pickup radius") or text.contains("拾取"):
		if wants_faster:
			return {"direction": "faster", "param": "MAGNET", "old": "90", "new": "130"}
		if wants_slower:
			return {"direction": "slower", "param": "MAGNET", "old": "90", "new": "60"}
	if wants_faster:
		return {"direction": "faster", "param": "SPEED", "old": "260.0", "new": "360.0"}
	if wants_slower:
		return {"direction": "slower", "param": "SPEED", "old": "260.0", "new": "180.0"}
	return {}

## 音效腿（P3 juice）：收集事件后断言声音确实播放过（可观测计数器，
## 不依赖声音时序窗口）。
func _audio_play_steps() -> Array:
	var steps: Array = []
	steps.append({
		"assert": {"expression": "sfx_played_count", "operator": "gt", "expected": 0,
			"description": "collecting the coin played a sound effect"}
	})
	return steps

## 状态机腿（P4 游戏流 / P2-3 完整循环验收器）：
## 标题→玩法→收集全部金币→胜利→重开（计数清零+金币重生）→第二轮→再次胜利。
## 金币聚簇在敌人巡逻带之前（蓝图 80+i*60，全在 x<210 走廊），一次右扫
## 即可全收——"带敌人的完整通关"几何可达（旧布局 200/380/560 的第二、
## 三枚落在死亡带 [220,380] 内，完整通关不可能发生）。
func _state_play_steps() -> Array:
	var steps: Array = []
	# 双 Enter 处理任意起步态：win→title→playing、title→playing、
	# playing（Enter 无副作用）——save 恢复导致的 win 起步也被覆盖。
	steps.append({"action": "ui_accept", "pressed": true, "wait_ms": 300})
	steps.append({"action": "ui_accept", "pressed": false, "wait_ms": 100})
	steps.append({"action": "ui_accept", "pressed": true, "wait_ms": 300})
	steps.append({"action": "ui_accept", "pressed": false, "wait_ms": 100})
	# 第一轮：右扫聚簇金币 → 全部收集（身份安全拾取）→ 胜利
	steps.append({"action": "move_right", "pressed": true, "wait_frames": 90})
	steps.append({
		"action": "move_right", "pressed": false, "wait_ms": 300,
		"assert": {"expression": "coins_collected == COINS_TO_WIN", "expected": true,
			"description": "first round: every coin collected (identity-safe pickup)"}
	})
	steps.append({
		"assert": {"expression": "_win_label.text", "expected": "You Win!",
			"description": "first round: the win label shows"}
	})
	steps.append({
		"assert": {"expression": "game_state", "expected": "win",
			"description": "first round: the flow reached the win state"}
	})
	# 重开：win --Enter--> title（计数清零、金币重生、玩家回原点）
	steps.append({"action": "ui_accept", "pressed": true, "wait_ms": 300})
	steps.append({
		"action": "ui_accept", "pressed": false, "wait_ms": 200,
		"assert": {"expression": "game_state", "expected": "title",
			"description": "restart returns the flow to the title state"}
	})
	steps.append({
		"assert": {"expression": "abs(position.x) < 20", "expected": true,
			"description": "restart reset the player to the origin"}
	})
	# 第二轮：title --Enter--> playing → 再收集 → 再次胜利
	steps.append({"action": "ui_accept", "pressed": true, "wait_ms": 300})
	steps.append({
		"action": "ui_accept", "pressed": false, "wait_ms": 200,
		"assert": {"expression": "game_state", "expected": "playing",
			"description": "second round starts from the title state"}
	})
	steps.append({"action": "move_right", "pressed": true, "wait_frames": 90})
	steps.append({
		"action": "move_right", "pressed": false, "wait_ms": 300,
		"assert": {"expression": "coins_collected == COINS_TO_WIN and game_state == \"win\"", "expected": true,
			"description": "second round: full win achieved again after restart"}
	})
	return steps

## 敌人腿（评测 P3 内容深度）：敌人巡逻位置随时间可解算（正弦往返）→
## 断言敌人确实在动；穿越敌人巡逻带 → 断言死亡计数与重生回原点。
## 返回 {steps, sample, assertions}：巡逻证明用 **range 指标**（采样窗内
## 敌人 x 的最大-最小差）——任意相位下"在动"的稳健证明（点评估
## |x-300|>10 在相位踩零点时 ~8% 闪断，真机 11 轮复现；96 帧窗口对
## 调参后速度 78 的最差相位 range ≥ 41px，对 120 必含峰/谷 ≥ 80px）。
func _enemy_play_legs() -> Dictionary:
	return {
		"steps": [
			{"wait_frames": 96},
			{"action": "move_right", "pressed": true, "wait_frames": 96},
			{
				"action": "move_right", "pressed": false, "wait_frames": 18,
				"assert": {"expression": "deaths_count", "operator": "gt", "expected": 0,
					"description": "touching the enemy killed the player"}
			},
			{
				"assert": {"expression": "position.x", "operator": "lt", "expected": 220,
					"description": "the player respawned left of the enemy band after death"}
			},
		],
		"sample": [{"label": "ex", "expression": "_enemy.position.x"}],
		"assertions": [{
			"metric": "ex", "aggregate": "range", "operator": "gt", "expected": 20,
			"description": "the enemy patrols (x range > 20px across the sampled window)"
		}],
	}

## 存档腿（评测 N3）：右移制造非平凡状态 → 按 save_game（F5）→ 断言写盘
## 成功（蓝图暴露 last_save_ok 作为可轮询证据）。
func _save_play_steps() -> Array:
	var steps: Array = []
	# 位移先自证（帧步进 24 帧 = 恰好 104px，确定性）——保证写入磁盘的
	# 状态非平凡，恢复腿的断言才有意义。
	steps.append({
		"action": "move_right", "pressed": true, "wait_frames": 24,
		"assert": {"expression": "position.x", "operator": "gt", "expected": 40,
			"description": "player moved right, creating non-trivial state to save"}
	})
	steps.append({"action": "move_right", "pressed": false, "wait_ms": 80})
	steps.append({
		"action": "save_game", "pressed": true, "wait_ms": 300, "screenshot": true,
		"assert": {"expression": "last_save_ok", "expected": true,
			"description": "save_game wrote the state to disk"}
	})
	steps.append({"action": "save_game", "pressed": false, "wait_ms": 80})
	return steps

## 恢复腿（评测 N3）：全新进程 _ready 自动读档 → 位置从磁盘恢复；
## last_save_ok 仍为 false 证明这是全新会话——状态来自磁盘而非本次保存。
func _restore_play_steps() -> Array:
	var steps: Array = []
	steps.append({
		"wait_ms": 900,
		"assert": {"expression": "position.x", "operator": "gt", "expected": 30,
			"description": "position restored from the save file after a full process restart"}
	})
	steps.append({
		"assert": {"expression": "last_save_ok", "expected": false,
			"description": "fresh session: the restored state came from disk, not this session's save"}
	})
	return steps

## 通用 play 门禁演练派生（非存档链步骤）：移动（位移断言）/ 暂停（暂停
## 恢复断言）按动词组合；存档目标暗含移动（蓝图口径）。都没有时退化为
## 启动等待窗口（此时门禁只证明"发起过运行"，启动期脚本错误仍会被捕获）。
func _derive_generic_play_steps(plan: Dictionary, task: Dictionary, _tool_name: String,
		arguments: Dictionary) -> void:
	var play_objective: String = String(plan.get("goal", ""))
	var wants_movement: bool = GoalBlueprintsScript._mentions(play_objective, GoalBlueprintsScript.MOVEMENT_KEYWORDS) \
		or GoalBlueprintsScript._mentions(play_objective, GoalBlueprintsScript.SAVE_KEYWORDS)
	var wants_pause: bool = GoalBlueprintsScript._mentions(play_objective, GoalBlueprintsScript.PAUSE_KEYWORDS)
	var remap_info: Dictionary = parse_remap_goal(play_objective)
	var rename_info: Dictionary = parse_rename_goal(play_objective)
	if not rename_info.is_empty():
		# 更名不改行为：门禁 = 更名产物可编译（verify_scripts 步骤）+
		# 行为回归演练（演练以真实按键驱动重命名后的控制器）。
		wants_movement = true
	if not remap_info.is_empty() and String(remap_info.get("new_key", "")) != "":
		arguments["steps"] = _remap_play_steps(
			String(remap_info["action"]),
			String(remap_info.get("old_key", "")),
			String(remap_info["new_key"]))
		task["derived_inputs"] = (task.get("derived_inputs", {}) if task.get("derived_inputs", {}) is Dictionary else {})
		task["derived_inputs"]["steps"] = "remap-exercise"
	else:
		var wants_collect: bool = GoalBlueprintsScript._mentions(play_objective, GoalBlueprintsScript.COLLECTIBLE_KEYWORDS) \
			or GoalBlueprintsScript._mentions(play_objective, GoalBlueprintsScript.WIN_KEYWORDS)
		var wants_enemy: bool = GoalBlueprintsScript._mentions(play_objective, GoalBlueprintsScript.ENEMY_KEYWORDS)
		var wants_state: bool = GoalBlueprintsScript._mentions(play_objective, GoalBlueprintsScript.STATE_MACHINE_KEYWORDS)
		var wants_audio: bool = GoalBlueprintsScript._mentions(play_objective, GoalBlueprintsScript.AUDIO_KEYWORDS)
		var wants_3d: bool = GoalBlueprintsScript._mentions(play_objective, GoalBlueprintsScript.THREE_D_KEYWORDS)
		if wants_audio:
			wants_collect = true
		if wants_movement or wants_pause or wants_collect or wants_enemy or wants_state:
			var play_steps: Array = []
			# 上下文感知：注册表已有 state_machine（或当前目标本身带状态机——
			# 完成前回归重推旧功能演练时，注册表还没记入本目标）时，游戏从
			# 标题屏（或上一轮演练留下的 win 态）启动——所有演练先双 Enter
			# 进入 playing 再执行（否则移动被门控空转）。
			var context_verbs: Dictionary = FeatureRegistryScript.registered_verbs()
			var context_has_state: bool = bool(context_verbs.get("state_machine", false)) \
				or GoalBlueprintsScript._mentions(play_objective, GoalBlueprintsScript.STATE_MACHINE_KEYWORDS)
			if context_has_state and not wants_state:
				play_steps.append({"action": "ui_accept", "pressed": true, "wait_ms": 300,
					"description": "enter playing state (win or title start)"})
				play_steps.append({"action": "ui_accept", "pressed": false, "wait_ms": 100})
				play_steps.append({"action": "ui_accept", "pressed": true, "wait_ms": 300})
				play_steps.append({"action": "ui_accept", "pressed": false, "wait_ms": 100})
			if wants_3d:
				play_steps.append({
					"action": "move_forward", "pressed": true, "wait_ms": 400,
					"assert": {"expression": "position.z", "displacement_max": -1.0,
						"description": "player moved forward in 3D"}
				})
				play_steps.append({"action": "move_forward", "pressed": false, "wait_ms": 80})
				play_steps.append({
					"action": "move_back", "pressed": true, "wait_ms": 400,
					"assert": {"expression": "position.z", "displacement_min": 0.5,
						"description": "player moved back in 3D"}
				})
				play_steps.append({"action": "move_back", "pressed": false, "wait_ms": 80})
				if wants_collect:
					play_steps.append_array(_collect_play_steps())
			elif wants_movement:
				play_steps.append_array(_movement_play_steps())
				# 手感预算：确定性采样 + 帧步进响应断言（只在移动目标激活）
				var feel: Dictionary = _movement_feel_legs()
				play_steps.append_array(feel["steps"])
				arguments["deterministic"] = true
				arguments["sample"] = feel["sample"]
				var feel_assertions: Array = arguments.get("assertions", [])
				if not (feel_assertions is Array):
					feel_assertions = []
				feel_assertions.append_array(feel["assertions"])
				arguments["assertions"] = feel_assertions
			if wants_state:
				play_steps.append_array(_state_play_steps())
			elif wants_collect:
				# 更名目标若改的就是计数字段，演练表达式跟随新符号名
				# （rename 已落盘，旧名不再存在——断言旧名必失败）。
				var coin_expression: String = "coins_collected"
				if not rename_info.is_empty() \
						and String(rename_info.get("symbol_name", "")) == "coins_collected":
					coin_expression = String(rename_info.get("new_name", "coins_collected"))
				play_steps.append_array(_collect_play_steps(coin_expression))
			if wants_enemy:
				var enemy_legs_generic: Dictionary = _enemy_play_legs()
				play_steps.append_array(enemy_legs_generic["steps"])
				arguments["deterministic"] = true
				var enemy_samples: Array = arguments.get("sample", [])
				if not (enemy_samples is Array):
					enemy_samples = []
				enemy_samples.append_array(enemy_legs_generic["sample"])
				arguments["sample"] = enemy_samples
				var enemy_assertions: Array = arguments.get("assertions", [])
				if not (enemy_assertions is Array):
					enemy_assertions = []
				enemy_assertions.append_array(enemy_legs_generic["assertions"])
				arguments["assertions"] = enemy_assertions
			if wants_pause:
				play_steps.append_array(_pause_play_steps())
			if wants_audio:
				play_steps.append_array(_audio_play_steps())
			arguments["steps"] = play_steps
			var labels: Array = []
			if wants_movement:
				labels.append("movement")
			if wants_state:
				labels.append("state")
			elif wants_collect:
				labels.append("collect")
			if wants_enemy:
				labels.append("enemy")
			if wants_pause:
				labels.append("pause")
			if wants_audio:
				labels.append("audio")
			task["derived_inputs"] = (task.get("derived_inputs", {}) if task.get("derived_inputs", {}) is Dictionary else {})
			task["derived_inputs"]["steps"] = "+".join(labels) + "-exercise"
		else:
			arguments["steps"] = [{"wait_ms": 600}]
			task["derived_inputs"] = (task.get("derived_inputs", {}) if task.get("derived_inputs", {}) is Dictionary else {})
			task["derived_inputs"]["steps"] = "boot-settle"

## journal 自动收口（R3）：仅当该工具最近一次提交写入按磁盘复判为
## complete_receipt、且不存在 pending 冲突时，把不确定步骤补回执收口。
## 返回收据（非空=已收口）；无证据/有冲突返回空，维持 fail-closed。
func _journal_autoclose(plan: Dictionary, uncertain_task: Dictionary) -> Dictionary:
	var tool_name: String = String(uncertain_task.get("tool_name", ""))
	if tool_name.is_empty():
		return {}
	var recovery: Dictionary = _change_journal_recovery(tool_name)
	for verdict_value in recovery.get("pending", []):
		if String((verdict_value as Dictionary).get("action", "")) == "conflict":
			return {}
	var latest: Dictionary = recovery.get("latest_committed", {})
	if latest.is_empty() or String(latest.get("phase", "")) != "committed" \
			or String(latest.get("verdict", "")) != "complete_receipt":
		return {}
	uncertain_task["status"] = "done"
	var receipt: Dictionary = _engine.append_receipt(plan, {
		"step_id": uncertain_task.get("id", ""),
		"tool_name": tool_name,
		"passed": true,
		"recovered": true,
		"journal_operation": String(latest.get("operation_id", "")),
		"summary": {"status": "success", "recovered_by": "change_journal",
			"journal_intent": String(latest.get("intent", ""))},
	})
	uncertain_task["receipt_digest"] = receipt.get("digest", "")
	uncertain_task["journal_autoclosed"] = true
	return receipt

## 合成授权（非计划步骤的 runner 内部调用）：invoke_planned_tool 校验
## 四字段非空且 authorized_tool 匹配——stale-stop 与完成前回归都不是计划
## 步骤，用合成 step_id 满足结构校验（不削弱任何实质权限：调用仍限定在
## runner 自身发起的 stop/play 上）。
func _synthetic_authorization(plan: Dictionary, step_id: String, tool_name: String) -> Dictionary:
	var workflow: Dictionary = plan.get("workflow", {})
	return {
		"kind": "game_workflow",
		"workflow_id": workflow.get("workflow_id", ""),
		"blueprint_hash": workflow.get("blueprint_hash", ""),
		"step_id": step_id,
		"authorized_tool": tool_name,
		"repair": false
	}

## 旧行为回归门禁（P1-4）：完成前对既往功能逐个重新推导并执行演练。
## 演练按"当前"语境重新推导（而非回放录制步骤）——更名/调参后的符号
## 与阈值变化不会让旧步骤失配；当前目标的动词被排除（新功能由本目标
## 的门禁覆盖）。游戏须可运行：先 run_project（已在运行则复用）。
## 任一旧功能失败 → {failed: true, reason} → 调用方阻止宣布完成。
func _run_prior_feature_regression(plan: Dictionary) -> Dictionary:
	var current_verbs: Dictionary = GoalBlueprintsScript.match_verbs(String(plan.get("goal", "")))
	var priors: Array = FeatureRegistryScript.prior_exercises(current_verbs)
	if priors.is_empty():
		return {}
	# 先停再启（新鲜会话）：直接 run_project 会复用残留游戏——旧场景/旧
	# 控制器 + 可能卡住的输入（真机复现：回归在 x=4782 的陈旧会话上执行，
	# 金币"永不拾取"）。stop→run 保证回归测的是当前场景与最新控制器。
	var stop_discard: Variant = await _server_core.invoke_planned_tool("stop_project",
		{"allow_window": true}, _synthetic_authorization(plan, "prior_regression_stop", "stop_project"))
	var run_discard: Variant = await _server_core.invoke_planned_tool("run_project",
		{"allow_window": true}, _synthetic_authorization(plan, "prior_regression", "run_project"))
	# stop/run 结果不判断：启动失败时首个演练自然报错（fail-closed）——
	# 但把 run 的启动错误留档，失败时并入诊断（区分"游戏没起来"与"演练失败"）。
	var run_startup_error: String = ""
	if run_discard is Dictionary and (run_discard as Dictionary).has("error"):
		run_startup_error = String((run_discard as Dictionary)["error"])
	var checked: Array = []
	const MAX_REGRESSION_FEATURES: int = 8
	# 解锁前缀依据 = 注册表 ∪ 当前目标动词（门禁执行时本目标尚未注册——
	# 真机复现：goal 09 的移动重验在标题门控下空转，前缀没注入）。
	var context_has_state: bool = bool(FeatureRegistryScript.registered_verbs().get("state_machine", false)) \
		or bool(current_verbs.get("state_machine", false))
	for prior_value in priors:
		if checked.size() >= MAX_REGRESSION_FEATURES:
			break
		var prior: Dictionary = prior_value
		var prior_goal: String = String(prior.get("goal", ""))
		if prior_goal.is_empty():
			continue
		var exercise_args: Dictionary = {}
		_derive_generic_play_steps({"goal": prior_goal}, {}, "play_and_verify", exercise_args)
		var steps: Array = exercise_args.get("steps", [])
		if steps.is_empty():
			continue
		# 引导稳定（冷启动）：回归门禁每次 stop→run 全新会话——冷游戏的
		# 前几百毫秒物理帧稀疏，位移断言会闪断（真机复现：04/05 的完成
		# 回归在冷游戏上丢帧）。先等 800ms 让物理稳定再执行演练。
		steps = [{"wait_ms": 800}] + steps
		# 合并控制器含状态机而旧功能自身不含时，先双 Enter 进入 playing
		# （win→title→playing / title→playing；playing 态 Enter 无副作用）。
		if context_has_state \
				and not GoalBlueprintsScript._mentions(prior_goal, GoalBlueprintsScript.STATE_MACHINE_KEYWORDS):
			steps += [
				{"action": "ui_accept", "pressed": true, "wait_ms": 300,
					"description": "regression: enter playing state"},
				{"action": "ui_accept", "pressed": false, "wait_ms": 100},
				{"action": "ui_accept", "pressed": true, "wait_ms": 300},
				{"action": "ui_accept", "pressed": false, "wait_ms": 100},
			]
		var play_args: Dictionary = {"steps": steps}
		for extra_key in ["deterministic", "sample", "assertions"]:
			if exercise_args.has(extra_key):
				play_args[extra_key] = exercise_args[extra_key]
		var result: Variant = await _server_core.invoke_planned_tool("play_and_verify",
			play_args, _synthetic_authorization(plan, "prior_regression", "play_and_verify"))
		var passed: bool = result is Dictionary and not (result as Dictionary).has("error") \
			and bool((result as Dictionary).get("passed", false))
		checked.append({"feature_id": prior.get("feature_id", ""), "goal": prior_goal, "passed": passed})
		if not passed:
			var reason: String = "prior feature '%s' (%s) failed re-verification" % [
				String(prior.get("feature_id", "")), prior_goal]
			if not run_startup_error.is_empty():
				reason += " [game startup: %s]" % run_startup_error
			if result is Dictionary:
				if (result as Dictionary).has("error"):
					reason += ": %s" % String((result as Dictionary)["error"])
				else:
					for assertion_value in (result as Dictionary).get("assertions", []):
						var assertion: Dictionary = assertion_value
						if not bool(assertion.get("passed", true)):
							reason += ": %s (expected %s, got %s%s)" % [
								String(assertion.get("description", "assertion failed")),
								str(assertion.get("expected", "?")),
								str(assertion.get("actual", "?")),
								(" at " + String(assertion.get("context", ""))) if assertion.has("context") else ""]
							break
			return {"failed": true, "reason": reason, "checked": checked}
	return {"failed": false, "checked": checked}

## 从 tune_apply 的 modify_script 参数解析计划值（runner 记入工件，
## 敌速/磁吸半径验证步断言新值在运行中的游戏里生效）。
func _parse_planned_tune(arguments: Dictionary) -> Dictionary:
	var content: String = String(arguments.get("content", ""))
	var old_text: String = String(arguments.get("old_text", ""))
	var regex: RegEx = RegEx.new()
	if regex.compile("const ([A-Z_]+): float = ([\\d.]+)") != OK:
		return {}
	var new_match: RegExMatch = regex.search(content)
	var old_match: RegExMatch = regex.search(old_text)
	if new_match == null or old_match == null:
		return {}
	return {
		"param": new_match.get_string(1),
		"old": float(old_match.get_string(2)),
		"new": float(new_match.get_string(2)),
	}

## 变更日志恢复处方：pending 操作逐条分类 + 该工具最近提交记录的磁盘
## 复判。recommended 汇总最保守的下一步（conflict 优先）。
## Q1 账本重验：既往目标的工件脚本是否仍存在（存在性检查——
## 编译由 verify_scripts 全项目覆盖，这里确认账本里的脚本没被删）。
func _verify_ledger_scripts(plan: Dictionary) -> Dictionary:
	var ledger_path: String = "res://.mcp/goal_ledger.json"
	if not FileAccess.file_exists(ledger_path):
		return {}
	var file: FileAccess = FileAccess.open(ledger_path, FileAccess.READ)
	if file == null:
		return {}
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	file.close()
	if not (parsed is Dictionary):
		return {}
	var goals: Array = (parsed as Dictionary).get("goals", [])
	if goals.size() <= 1:
		return {}  # 首个目标无需回归
	var missing: Array = []
	var orphaned: Array = []
	# 合并语义（差距分析明示）：旧功能合并进新脚本是合法实现——累积模式下
	# create_script 的碰撞后缀必然让旧脚本脱离场景引用。"孤儿"只有在当前
	# 游戏模型的脚本也不被场景引用（功能确实无人承载）时才是回归；旧功能
	# 的行为由完成前回归门禁逐个重验，不靠文件引用关系推断。
	var model_script: String = ""
	var model: Dictionary = GameModelStoreScript.load_model()
	model_script = String(model.get("script_path", ""))
	var current_script_referenced: bool = true
	if not model_script.is_empty():
		var model_scene: String = String((plan.get("workflow", {}) as Dictionary).get("artifacts", {}).get("scene", ""))
		if not model_scene.is_empty() and FileAccess.file_exists(model_scene):
			var model_scene_text: String = FileAccess.get_file_as_string(model_scene)
			current_script_referenced = model_scene_text.contains(model_script.get_file())
	for goal_value in goals:
		var goal_entry: Dictionary = goal_value
		var artifacts: Dictionary = goal_entry.get("artifacts", {})
		var script_path: String = String(artifacts.get("script", ""))
		if not script_path.is_empty() and not FileAccess.file_exists(script_path):
			missing.append({"goal": goal_entry.get("goal", ""), "missing_script": script_path})
		# 脚本存在但场景不引用：仅当功能无人承载（当前模型脚本也脱钩）时
		# 记为孤儿回归；合并前身的脱离是合法演化，仅作信息记录。
		if not script_path.is_empty() and FileAccess.file_exists(script_path) \
				and not current_script_referenced:
			var scene_path: String = String(artifacts.get("scene", ""))
			if not scene_path.is_empty() and FileAccess.file_exists(scene_path):
				var scene_text: String = FileAccess.get_file_as_string(scene_path)
				var script_file_name: String = script_path.get_file()
				if not scene_text.contains(script_file_name):
					orphaned.append({"goal": goal_entry.get("goal", ""),
						"orphaned_script": script_path,
						"scene": scene_path,
						"note": "script exists but scene does not reference it"})
	return {
		"prior_goals": goals.size(),
		"missing_scripts": missing,
		"orphaned_scripts": orphaned,
		"regression_clean": missing.is_empty(),
	}

## 跨目标账本：res://.mcp/goal_ledger.json 累积每个已完成目标的
## {goal, completed_at, artifacts, scripts}。轻量 v1——只记录与读回；
## 回归演练（重跑既往目标的行为断言）是下一片。
func _append_goal_ledger(plan: Dictionary) -> Dictionary:
	var ledger_path: String = "res://.mcp/goal_ledger.json"
	var ledger: Dictionary = {"goals": []}
	if FileAccess.file_exists(ledger_path):
		var read_file: FileAccess = FileAccess.open(ledger_path, FileAccess.READ)
		if read_file:
			var parsed: Variant = JSON.parse_string(read_file.get_as_text())
			read_file.close()
			if parsed is Dictionary and (parsed as Dictionary).get("goals") is Array:
				ledger = parsed
	var workflow: Dictionary = plan.get("workflow", {})
	var artifacts: Dictionary = workflow.get("artifacts", {}) if workflow.get("artifacts") is Dictionary else {}
	var entry: Dictionary = {
		"goal": plan.get("goal", ""),
		"completed_at": Time.get_datetime_string_from_system(true, true),
		"artifacts": artifacts.duplicate(true),
	}
	(ledger["goals"] as Array).append(entry)
	var save_file: FileAccess = FileAccess.open(ledger_path, FileAccess.WRITE)
	if save_file == null:
		return {}
	save_file.store_string(JSON.stringify(ledger, "\t"))
	save_file.close()
	return {"recorded_goals": (ledger["goals"] as Array).size()}

func _change_journal_recovery(tool_name: String) -> Dictionary:
	var out: Dictionary = {}
	var pending_verdicts: Array = []
	for operation in ChangeJournalScript.pending_operations():
		pending_verdicts.append(ChangeJournalScript.classify_operation(operation))
	if not pending_verdicts.is_empty():
		out["pending"] = pending_verdicts
	var latest: Dictionary = ChangeJournalScript.latest_operation_by_tool(tool_name)
	if not latest.is_empty():
		var verdict: Dictionary = ChangeJournalScript.classify_operation(latest)
		out["latest_committed"] = {
			"operation_id": latest.get("operation_id", ""),
			"intent": latest.get("intent", ""),
			"phase": latest.get("phase", ""),
			"verdict": verdict.get("action", ""),
			"files": verdict.get("files", []),
		}
	var recommended: String = ""
	if not pending_verdicts.is_empty():
		var has_conflict: bool = false
		for verdict_entry in pending_verdicts:
			if String((verdict_entry as Dictionary).get("action", "")) == "conflict":
				has_conflict = true
				break
		recommended = "resolve manual-edit conflicts first" if has_conflict else "pending writes classify clean — replay is safe"
	elif out.has("latest_committed"):
		recommended = "latest committed write %s on disk — the write happened; %s" % [
			"matches" if String(out["latest_committed"]["verdict"]) == "complete_receipt" else "does NOT match",
			"no replay needed" if String(out["latest_committed"]["verdict"]) == "complete_receipt" else "inspect diverged files"]
	if not recommended.is_empty():
		out["recommended"] = recommended
	return out

func _derive_visual_baseline_path(tool_name: String, arguments: Dictionary,
		artifacts: Dictionary, derived: Dictionary, workflow_id: String = "") -> void:
	if tool_name != "assert_visual_baseline":
		return
	var screenshot: String = String(artifacts.get("screenshot", ""))
	if screenshot.is_empty():
		return
	if not arguments.has("candidate_path"):
		arguments["candidate_path"] = screenshot
		derived["candidate_path"] = screenshot
	if not arguments.has("baseline_path"):
		# 基线按 workflow 隔离：截图文件名全目标相同（mcp_runtime_capture.jpg），
		# 共用一个基线会让目标 B 拿目标 A 的图当金标准、或跨目标串基线。
		var baseline: String = "user://visual_baselines/%s_%s" % [workflow_id, screenshot.get_file()] \
			if not workflow_id.is_empty() else "user://visual_baselines/" + screenshot.get_file()
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

static func _normalize_command(command: String) -> String:
	var normalized: String = command.strip_edges().to_lower()
	for separator in ["\t", "\r", "\n"]:
		normalized = normalized.replace(separator, " ")
	return " ".join(normalized.split(" ", false))

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
