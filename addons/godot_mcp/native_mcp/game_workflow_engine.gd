class_name GameWorkflowEngine
extends RefCounted

## Pure, deterministic orchestration for complete Godot production loops.
##
## The engine composes a small set of reusable profiles into a durable task DAG.
## It never executes arbitrary tool names: every executable step is regenerated
## from the persisted goal contract and checked against the immutable registry.
## The MCP-facing adapter owns persistence and execution; this class owns plan
## compilation, structural integrity, evidence verdicts and bounded recovery.

const TaskPlanStoreScript = preload("res://addons/godot_mcp/tools/task_plan_store.gd")

const SCHEMA_VERSION: int = 1
const MAX_STEPS_PER_RUN: int = 4
const DEFAULT_REPAIR_ATTEMPTS: int = 2
const MAX_REPAIR_ATTEMPTS: int = 3
const MAX_PENDING_POLLS: int = 120
const MAX_RECEIPTS: int = 256

const PROFILE_IDS: Array[String] = [
	"gameplay_feature",
	"ui_screen",
	"script_repair",
	"asset_pipeline",
	"animation_audio",
	"level_design",
	"runtime_debug",
	"localization",
	"performance",
	"quality_assurance",
	"project_health",
	"release_export"
]

const PROFILE_KEYWORDS: Dictionary = {
	"gameplay_feature": ["gameplay", "player", "movement", "controller", "mechanic", "collision", "玩家", "移动", "控制", "玩法", "游戏机制", "碰撞"],
	"ui_screen": [" ui ", "menu", "hud", "pause", "button", "interface", "screen", "界面", "菜单", "暂停", "按钮", "主题", "屏幕"],
	"script_repair": ["script error", "fix script", "compile error", "gdscript", "c#", "脚本错误", "修复脚本", "编译错误", "代码错误"],
	"asset_pipeline": ["asset", "import", "texture", "model", "sprite", "gltf", "资源", "导入", "贴图", "模型", "精灵"],
	"animation_audio": ["animation", "audio", "sound", "music", "动画", "音频", "音效", "音乐"],
	"level_design": ["level", "tilemap", "tileset", "map", "关卡", "地图", "瓦片", "场景布局"],
	"runtime_debug": ["debug", "runtime", "crash", "stack trace", "调试", "运行时", "崩溃", "异常"],
	"localization": ["localization", "translation", "language", "locale", "本地化", "翻译", "多语言", "语言"],
	"performance": ["performance", "optimize", "fps", "frame time", "memory", "性能", "优化", "帧率", "内存"],
	"quality_assurance": ["project test", "run tests", "test suite", "quality assurance", "regression", "项目测试", "运行测试", "测试套件", "质量回归", "回归测试"],
	"project_health": ["audit", "migration", "dependency", "deprecated", "project health", "审计", "迁移", "依赖", "废弃", "项目健康"],
	"release_export": ["export", "release", "ship", "build", "android", "linux", "windows", "导出", "发布", "出货", "构建", "打包"]
}

const STAGE_RANK: Dictionary = {
	"offline_inspect": 10,
	"build_create": 20,
	"build_configure": 22,
	"build_save": 25,
	"static_verify": 30,
	"runtime_probe": 40,
	"runtime_run": 45,
	"runtime_inspect": 50,
	"runtime_action": 60,
	"runtime_evidence": 70,
	"release_inspect": 80,
	"release_prepare": 85,
	"release_validate": 90,
	"release_build": 95,
	"release_evidence": 100
}

const DEFAULT_PROTECTED_PATHS: Array[String] = [
	"res://addons/godot_mcp",
	"res://.mcp"
]

const PENDING_STATUSES: Array[String] = [
	"pending", "running", "queued", "accepted", "in_progress", "processing"
]

const NEGATIVE_STATUSES: Array[String] = [
	"failed", "failing", "error", "invalid", "blocked", "cancelled",
	"canceled", "timeout", "timed_out", "unconfigured", "partial",
	"skipped", "stale", "aborted", "missing"
]

const FORBIDDEN_NESTED_CAPABILITIES: Array[String] = [
	"plan_game_workflow", "run_game_workflow", "manage_task_plan",
	"list_tool_catalog", "search_tools", "get_tool_details", "enable_tools"
]

func compile(objective: String, options: Dictionary, available_tools: Array[String]) -> Dictionary:
	var clean_objective: String = objective.strip_edges()
	if clean_objective.is_empty():
		return _clarification_error("objective is required")

	var profile_result: Dictionary = _select_profiles(clean_objective, options.get("profiles", []))
	if profile_result.has("error"):
		return profile_result
	var profiles: Array[String] = profile_result.get("profiles", [])
	var platform: String = _normalize_platform(String(options.get("platform", "")), clean_objective)
	var repair_attempts: int = clampi(
		int(options.get("max_repair_attempts", DEFAULT_REPAIR_ATTEMPTS)),
		0, MAX_REPAIR_ATTEMPTS)
	var protected_paths: Array[String] = DEFAULT_PROTECTED_PATHS.duplicate()
	if options.get("protected_paths") is Array:
		for path_value in options["protected_paths"]:
			var protected_path: String = String(path_value).strip_edges()
			if not protected_path.is_empty() and not protected_path in protected_paths:
				protected_paths.append(protected_path)
	protected_paths.sort()

	var required_capabilities: Array[String] = []
	if options.get("required_capabilities") is Array:
		for capability_value in options["required_capabilities"]:
			var capability: String = String(capability_value).strip_edges()
			if not capability.is_empty() and not capability in required_capabilities:
				required_capabilities.append(capability)
	required_capabilities.sort()

	var specs: Array[Dictionary] = []
	for profile_id in profiles:
		for spec_value in _profile_specs(profile_id, clean_objective, platform):
			specs.append((spec_value as Dictionary).duplicate(true))
	for capability in required_capabilities:
		if capability in FORBIDDEN_NESTED_CAPABILITIES:
			return {
				"error": "Capability '%s' cannot be nested inside a game workflow" % capability,
				"status": "blocked",
				"missing_capabilities": [capability]
			}
		if not _specs_contain_tool(specs, capability):
			specs.append(_spec(capability, capability, _infer_stage(capability)))
	specs = _deduplicate_specs(specs)
	if _specs_need_runtime(specs):
		if not _specs_contain_tool(specs, "install_runtime_probe"):
			specs.append(_spec("runtime_probe", "install_runtime_probe", "runtime_probe"))
		if not _specs_contain_tool(specs, "run_project"):
			specs.append(_spec("runtime_run", "run_project", "runtime_run"))
	specs = _sort_specs(specs)

	var missing: Array[String] = []
	for spec_value in specs:
		var tool_name: String = String((spec_value as Dictionary).get("tool_name", ""))
		if not tool_name in available_tools and not tool_name in missing:
			missing.append(tool_name)
	for capability in required_capabilities:
		if not capability in available_tools and not capability in missing:
			missing.append(capability)
	missing.sort()
	if not missing.is_empty():
		return {
			"error": "Required workflow capabilities are not registered: %s" % ", ".join(missing),
			"status": "blocked",
			"missing_capabilities": missing,
			"profiles": profiles
		}

	var contract: Dictionary = {
		"objective": clean_objective,
		"profiles": profiles,
		"required_capabilities": required_capabilities,
		"platform": platform,
		"max_repair_attempts": repair_attempts,
		"protected_paths": protected_paths
	}
	var plan: Dictionary = _build_plan(contract, specs)
	return {
		"status": "planned",
		"plan": plan,
		"workflow": summarize(plan)
	}

func _clarification_error(message: String) -> Dictionary:
	return {
		"error": message,
		"status": "needs_clarification",
		"supported_profiles": PROFILE_IDS
	}

func _select_profiles(objective: String, requested) -> Dictionary:
	var selected: Array[String] = []
	if requested is Array and not (requested as Array).is_empty():
		for value in requested:
			var profile_id: String = String(value).strip_edges()
			if not profile_id in PROFILE_IDS:
				return _clarification_error("Unknown workflow profile '%s'" % profile_id)
			if not profile_id in selected:
				selected.append(profile_id)
	else:
		var normalized: String = " " + objective.to_lower().replace("_", " ").replace("-", " ") + " "
		for profile_id in PROFILE_IDS:
			for keyword_value in PROFILE_KEYWORDS.get(profile_id, []):
				if normalized.contains(String(keyword_value)):
					selected.append(profile_id)
					break
	if selected.is_empty():
		return _clarification_error(
			"Objective does not identify a supported production workflow; provide profiles explicitly")
	selected.sort()
	return {"profiles": selected}

func _normalize_platform(platform: String, objective: String) -> String:
	var normalized: String = platform.strip_edges().to_lower()
	if not normalized.is_empty():
		return normalized
	var goal: String = objective.to_lower()
	for candidate in ["android", "linux", "windows", "macos", "web", "ios"]:
		if goal.contains(candidate):
			return candidate
	return ""

func _spec(key: String, tool_name: String, stage: String, objective_gate: bool = false,
		arguments: Dictionary = {}, repair_tool: String = "") -> Dictionary:
	return {
		"key": key,
		"tool_name": tool_name,
		"stage": stage,
		"objective_gate": objective_gate,
		"arguments": arguments,
		"repair_tool": repair_tool
	}

func _profile_specs(profile_id: String, objective: String, platform: String) -> Array[Dictionary]:
	var goal: String = objective.to_lower()
	match profile_id:
		"gameplay_feature":
			return [
				_spec("project_info", "get_project_info", "offline_inspect"),
				_spec("input_actions", "list_project_input_actions", "offline_inspect"),
				_spec("create_scene", "create_scene", "build_create"),
				_spec("create_script", "create_script", "build_create"),
				_spec("attach_script", "attach_script", "build_configure"),
				_spec("upsert_input", "upsert_project_input_action", "build_configure"),
				_spec("save_scene", "save_scene", "build_save"),
				_spec("verify_scripts", "verify_scripts", "static_verify", true, {}, "modify_script"),
				_spec("play_verify", "play_and_verify", "runtime_evidence", true, {}, "modify_script"),
				_spec("runtime_errors", "assert_no_runtime_errors", "runtime_evidence", true, {}, "modify_script")
			]
		"ui_screen":
			return [
				_spec("current_scene", "get_current_scene", "offline_inspect"),
				_spec("create_theme", "create_theme", "build_create"),
				_spec("ui_scene", "create_scene", "build_create"),
				_spec("ui_node", "create_node", "build_create"),
				_spec("ui_anchor", "set_anchor_preset", "build_configure"),
				_spec("ui_save", "save_scene", "build_save"),
				_spec("runtime_screenshot", "get_runtime_screenshot", "runtime_inspect"),
				_spec("visual_gate", "assert_visual_baseline", "runtime_evidence", true, {}, "batch_update_node_properties")
			]
		"script_repair":
			return [
				_spec("list_scripts", "list_project_scripts", "offline_inspect"),
				_spec("broken_scripts", "detect_broken_scripts", "offline_inspect"),
				_spec("read_script", "read_script", "offline_inspect"),
				_spec("modify_script", "modify_script", "build_configure"),
				_spec("verify_scripts", "verify_scripts", "static_verify", true, {}, "modify_script"),
				_spec("project_tests", "run_project_tests", "static_verify", true, {}, "modify_script")
			]
		"asset_pipeline":
			var asset_specs: Array[Dictionary] = [
				_spec("project_resources", "list_project_resources", "offline_inspect"),
				_spec("import_status", "get_import_status", "offline_inspect"),
				_spec("reimport", "reimport_resources", "build_configure"),
				_spec("missing_dependencies", "scan_missing_resource_dependencies", "static_verify", true)
			]
			if goal.contains("gltf") or goal.contains("3d") or goal.contains("模型"):
				asset_specs.append(_spec("inspect_gltf", "inspect_gltf_asset", "static_verify", true))
			return asset_specs
		"animation_audio":
			var media_specs: Array[Dictionary] = [
				_spec("create_animation", "create_animation", "build_create"),
				_spec("animation_keys", "insert_animation_keys", "build_configure"),
				_spec("runtime_animations", "list_runtime_animations", "runtime_inspect"),
				_spec("play_animation", "play_runtime_animation", "runtime_action"),
				_spec("animation_state", "get_runtime_animation_state", "runtime_evidence", true),
				_spec("media_runtime_errors", "assert_no_runtime_errors", "runtime_evidence", true, {}, "modify_script")
			]
			if goal.contains("audio") or goal.contains("sound") or goal.contains("music") or goal.contains("音频") or goal.contains("音效") or goal.contains("音乐"):
				media_specs.append(_spec("audio_buses", "list_runtime_audio_buses", "runtime_inspect"))
				media_specs.append(_spec("audio_bus", "get_runtime_audio_bus", "runtime_inspect"))
				media_specs.append(_spec("update_audio_bus", "update_runtime_audio_bus", "runtime_action"))
			return media_specs
		"level_design":
			return [
				_spec("project_scenes", "list_project_scenes", "offline_inspect"),
				_spec("level_scene", "create_scene", "build_create"),
				_spec("tileset", "create_tileset", "build_create"),
				_spec("tileset_layers", "configure_tileset_layers", "build_configure"),
				_spec("tilemap_cells", "set_tilemap_layer_cells", "build_configure"),
				_spec("level_save", "save_scene", "build_save"),
				_spec("persistence_gate", "audit_scene_node_persistence", "static_verify", true),
				_spec("level_screenshot", "get_runtime_screenshot", "runtime_inspect"),
				_spec("level_visual_gate", "assert_visual_baseline", "runtime_evidence", true, {}, "batch_scene_node_edits")
			]
		"runtime_debug":
			return [
				_spec("editor_logs", "get_editor_logs", "offline_inspect"),
				_spec("debug_broken_scripts", "detect_broken_scripts", "offline_inspect"),
				_spec("runtime_info", "get_runtime_info", "runtime_inspect"),
				_spec("debug_output", "get_debug_output", "runtime_inspect"),
				_spec("debugger_messages", "get_debugger_messages", "runtime_inspect"),
				_spec("runtime_tree", "get_runtime_scene_tree", "runtime_inspect"),
				_spec("runtime_error_gate", "assert_no_runtime_errors", "runtime_evidence", true, {}, "modify_script")
			]
		"localization":
			return [
				_spec("localization_list", "manage_localization", "offline_inspect", false, {"action": "list"}),
				_spec("localization_extract", "manage_localization", "build_create", false, {"action": "extract"}),
				_spec("localization_import", "manage_localization", "build_configure", true, {"action": "import"})
			]
		"performance":
			var perf_specs: Array[Dictionary] = [
				_spec("performance_snapshot", "get_runtime_performance_snapshot", "runtime_inspect"),
				_spec("memory_trend", "get_runtime_memory_trend", "runtime_inspect"),
				_spec("performance_gate", "assert_performance_budget", "runtime_evidence", true, {}, "modify_script"),
				_spec("performance_errors", "assert_no_runtime_errors", "runtime_evidence", true, {}, "modify_script")
			]
			if goal.contains("optimiz") or goal.contains("优化") or goal.contains("improve") or goal.contains("降低"):
				perf_specs.append(_spec("performance_scripts", "list_project_scripts", "offline_inspect"))
				perf_specs.append(_spec("performance_read", "read_script", "offline_inspect"))
				perf_specs.append(_spec("performance_modify", "modify_script", "build_configure"))
				perf_specs.append(_spec("performance_verify_scripts", "verify_scripts", "static_verify", true, {}, "modify_script"))
			return perf_specs
		"quality_assurance":
			return [
				_spec("list_tests", "list_project_tests", "offline_inspect"),
				_spec("qa_1_verify_scripts", "verify_scripts", "static_verify", true, {}, "modify_script"),
				_spec("qa_2_tests", "run_project_tests", "static_verify", true, {}, "modify_script")
			]
		"project_health":
			var fix_migration: bool = _goal_authorizes_fix(goal) and (goal.contains("migration") or goal.contains("迁移"))
			var full_health_gate: bool = goal.contains("audit") or goal.contains("project health") or goal.contains("审计") or goal.contains("项目健康")
			var health_specs: Array[Dictionary] = [
				_spec("health_audit_initial", "audit_project_health", "offline_inspect"),
				_spec("migration_scan", "scan_migration_compatibility", "offline_inspect"),
				_spec("dependency_scan", "scan_missing_resource_dependencies", "offline_inspect"),
				_spec("cycle_scan", "scan_cyclic_resource_dependencies", "offline_inspect"),
				_spec("deprecated_scan", "find_deprecated_api_usage", "offline_inspect"),
				_spec("health_broken_scripts", "detect_broken_scripts", "offline_inspect")
			]
			if fix_migration:
				health_specs.append(_spec("migration_fix", "apply_migration_fixes", "build_configure", false, {"dry_run": false}))
				health_specs.append(_spec("migration_verify", "scan_migration_compatibility", "static_verify", true, {"target_version": "4.7"}))
				health_specs.append(_spec("migration_scripts", "verify_scripts", "static_verify", true, {}, "modify_script"))
			if full_health_gate:
				health_specs.append(_spec("health_audit_gate", "audit_project_health", "static_verify", true, {"include_warnings": true}))
			return health_specs
		"release_export":
			var release_specs: Array[Dictionary] = [
				_spec("export_presets", "list_export_presets", "release_inspect"),
				_spec("export_templates", "inspect_export_templates", "release_inspect")
			]
			if platform == "android":
				release_specs.append(_spec("android_config", "configure_android_export", "release_prepare"))
			release_specs.append(_spec("validate_export", "validate_export_preset", "release_validate", true))
			release_specs.append(_spec("run_export", "run_export", "release_build"))
			release_specs.append(_spec("smoke_export", "smoke_test_export", "release_evidence", true))
			return release_specs
	return []

func _goal_authorizes_fix(goal: String) -> bool:
	for word in ["fix", "repair", "apply", "resolve", "修复", "处理", "应用"]:
		if goal.contains(word):
			return true
	return false

func _infer_stage(tool_name: String) -> String:
	if tool_name == "install_runtime_probe":
		return "runtime_probe"
	if tool_name == "run_project":
		return "runtime_run"
	if tool_name.begins_with("get_runtime_") or tool_name.begins_with("list_runtime_") or tool_name == "inspect_runtime_node":
		return "runtime_inspect"
	if tool_name.begins_with("assert_") or tool_name == "play_and_verify":
		return "runtime_evidence"
	if tool_name.begins_with("get_") or tool_name.begins_with("list_") or tool_name.begins_with("scan_") or tool_name.begins_with("find_") or tool_name.begins_with("audit_") or tool_name.begins_with("detect_") or tool_name.begins_with("inspect_") or tool_name.begins_with("read_"):
		return "offline_inspect"
	if tool_name.begins_with("verify_") or tool_name.begins_with("validate_") or tool_name.begins_with("run_project_test"):
		return "static_verify"
	return "build_configure"

func _specs_contain_tool(specs: Array[Dictionary], tool_name: String) -> bool:
	for value in specs:
		if String((value as Dictionary).get("tool_name", "")) == tool_name:
			return true
	return false

func _specs_need_runtime(specs: Array[Dictionary]) -> bool:
	for value in specs:
		var stage: String = String((value as Dictionary).get("stage", ""))
		if stage.begins_with("runtime_") and stage not in ["runtime_probe", "runtime_run"]:
			return true
	return false

func _deduplicate_specs(specs: Array[Dictionary]) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var by_identity: Dictionary = {}
	for value in specs:
		var spec: Dictionary = value
		var arguments: Dictionary = spec.get("arguments", {})
		var identity: String = String(spec.get("tool_name", "")) + ":" + JSON.stringify(arguments)
		if by_identity.has(identity):
			var index: int = int(by_identity[identity])
			if bool(spec.get("objective_gate", false)):
				result[index]["objective_gate"] = true
			if String(result[index].get("repair_tool", "")).is_empty():
				result[index]["repair_tool"] = String(spec.get("repair_tool", ""))
			continue
		by_identity[identity] = result.size()
		result.append(spec.duplicate(true))
	return result

func _sort_specs(specs: Array[Dictionary]) -> Array[Dictionary]:
	var result: Array[Dictionary] = specs.duplicate(true)
	result.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var ar: int = int(STAGE_RANK.get(String(a.get("stage", "")), 999))
		var br: int = int(STAGE_RANK.get(String(b.get("stage", "")), 999))
		if ar != br:
			return ar < br
		return String(a.get("key", "")) < String(b.get("key", ""))
	)
	return result

func _build_plan(contract: Dictionary, specs: Array[Dictionary]) -> Dictionary:
	var plan: Dictionary = TaskPlanStoreScript.new_plan(String(contract.get("objective", "")))
	var tasks: Array[Dictionary] = []
	var objective_gate_ids: Array[String] = []
	var prior_ids: Array[String] = []
	var blueprint_tasks: Array[Dictionary] = []
	var max_attempts: int = int(contract.get("max_repair_attempts", DEFAULT_REPAIR_ATTEMPTS))
	for index in range(specs.size()):
		var spec: Dictionary = specs[index]
		var step_id: String = "wf_%03d" % (index + 1)
		var is_gate: bool = bool(spec.get("objective_gate", false))
		var repair_tool: String = String(spec.get("repair_tool", ""))
		var task: Dictionary = {
			"id": step_id,
			"title": "%s: %s" % [String(spec.get("stage", "")), String(spec.get("tool_name", ""))],
			"description": "Execute the plan-authorized atomic MCP capability and retain compact evidence.",
			"status": "pending",
			"depends_on": prior_ids.duplicate(),
			"dod": [{"criterion": "Objective evidence accepted", "met": false, "evidence": ""}] if is_gate else [],
			"tags": ["game_workflow", String(spec.get("stage", ""))],
			"journal": [],
			"created_at": plan.get("created_at", ""),
			"updated_at": plan.get("created_at", ""),
			"tool_name": String(spec.get("tool_name", "")),
			"stage": String(spec.get("stage", "")),
			"arguments": (spec.get("arguments", {}) as Dictionary).duplicate(true),
			"objective_gate": is_gate,
			"repair_tool": repair_tool,
			"max_repair_attempts": max_attempts,
			"attempts": 0,
			"repair_attempts": 0,
			"pending_polls": 0,
			"receipt_digest": ""
		}
		tasks.append(task)
		if is_gate:
			objective_gate_ids.append(step_id)
		blueprint_tasks.append(_task_blueprint(task))
		prior_ids.append(step_id)
	var blueprint_hash: String = _sha256(JSON.stringify({
		"contract": contract,
		"tasks": blueprint_tasks,
		"objective_gate_ids": objective_gate_ids
	}))
	var workflow_id: String = _sha256(
		String(contract.get("objective", "")) + blueprint_hash + str(Time.get_ticks_usec())).substr(0, 24)
	plan["tasks"] = tasks
	plan["workflow"] = {
		"schema_version": SCHEMA_VERSION,
		"workflow_id": workflow_id,
		"blueprint_hash": blueprint_hash,
		"state": "planned",
		"blocked_reason": "",
		"goal_contract": contract.duplicate(true),
		"objective_gate_ids": objective_gate_ids,
		"receipts": []
	}
	return plan

func _task_blueprint(task: Dictionary) -> Dictionary:
	return {
		"id": String(task.get("id", "")),
		"tool_name": String(task.get("tool_name", "")),
		"stage": String(task.get("stage", "")),
		"depends_on": (task.get("depends_on", []) as Array).duplicate(),
		"arguments": (task.get("arguments", {}) as Dictionary).duplicate(true),
		"objective_gate": bool(task.get("objective_gate", false)),
		"repair_tool": String(task.get("repair_tool", "")),
		"max_repair_attempts": int(task.get("max_repair_attempts", 0))
	}

func validate_integrity(plan: Dictionary, available_tools: Array[String]) -> Dictionary:
	if not (plan.get("workflow") is Dictionary):
		return {"error": "workflow metadata is missing"}
	var workflow: Dictionary = plan["workflow"]
	if int(workflow.get("schema_version", -1)) != SCHEMA_VERSION:
		return {"error": "unsupported workflow schema version"}
	if not (workflow.get("goal_contract") is Dictionary):
		return {"error": "goal contract is missing"}
	var contract: Dictionary = workflow["goal_contract"]
	if String(plan.get("goal", "")) != String(contract.get("objective", "")):
		return {"error": "persisted goal no longer matches the workflow contract"}
	var options: Dictionary = {
		"profiles": contract.get("profiles", []),
		"required_capabilities": contract.get("required_capabilities", []),
		"platform": contract.get("platform", ""),
		"max_repair_attempts": contract.get("max_repair_attempts", DEFAULT_REPAIR_ATTEMPTS),
		"protected_paths": contract.get("protected_paths", [])
	}
	# Do not feed the built-in protected paths back as user additions twice; the
	# compiler deduplicates them, keeping the regenerated contract deterministic.
	var rebuilt_result: Dictionary = compile(String(contract.get("objective", "")), options, available_tools)
	if rebuilt_result.has("error"):
		return {"error": "workflow contract can no longer be compiled: %s" % rebuilt_result["error"]}
	var expected: Dictionary = rebuilt_result["plan"]
	var expected_workflow: Dictionary = expected["workflow"]
	if String(workflow.get("blueprint_hash", "")) != String(expected_workflow.get("blueprint_hash", "")):
		return {"error": "workflow blueprint hash does not match its goal contract"}
	if workflow.get("objective_gate_ids", []) != expected_workflow.get("objective_gate_ids", []):
		return {"error": "objective gate set was changed"}
	var tasks = plan.get("tasks", [])
	var expected_tasks = expected.get("tasks", [])
	if not (tasks is Array) or (tasks as Array).size() != (expected_tasks as Array).size():
		return {"error": "workflow task count was changed"}
	for index in range((expected_tasks as Array).size()):
		var actual_task: Dictionary = tasks[index]
		var expected_task: Dictionary = expected_tasks[index]
		if _task_blueprint(actual_task) != _task_blueprint(expected_task):
			return {"error": "workflow step '%s' no longer matches the authorized blueprint" % expected_task.get("id", index)}
		if not String(actual_task.get("tool_name", "")) in available_tools:
			return {"error": "workflow capability is no longer registered: %s" % actual_task.get("tool_name", "")}
	return {"status": "ok", "blueprint_hash": workflow.get("blueprint_hash", "")}

func get_task(plan: Dictionary, step_id: String) -> Dictionary:
	for value in plan.get("tasks", []):
		var task: Dictionary = value
		if String(task.get("id", "")) == step_id:
			return task
	return {}

func ready_steps(plan: Dictionary, limit: int = MAX_STEPS_PER_RUN) -> Array[Dictionary]:
	var ready: Array[Dictionary] = []
	var bounded_limit: int = clampi(limit, 1, MAX_STEPS_PER_RUN)
	for value in plan.get("tasks", []):
		var task: Dictionary = value
		if String(task.get("status", "pending")) != "pending":
			continue
		var dependencies_met: bool = true
		for dependency_value in task.get("depends_on", []):
			var dependency: Dictionary = get_task(plan, String(dependency_value))
			if dependency.is_empty() or String(dependency.get("status", "")) != "done":
				dependencies_met = false
				break
		if dependencies_met:
			ready.append(task)
			if ready.size() >= bounded_limit:
				break
	return ready

func is_pending_result(result: Variant) -> bool:
	if not (result is Dictionary):
		return false
	return String((result as Dictionary).get("status", "")).strip_edges().to_lower() in PENDING_STATUSES

func result_passed(tool_name: String, result: Variant) -> bool:
	if not (result is Dictionary) or (result as Dictionary).is_empty():
		return false
	var data: Dictionary = result
	if data.has("error"):
		return false
	for verdict_key in ["passed", "success", "valid"]:
		if data.has(verdict_key) and not bool(data[verdict_key]):
			return false
	var status: String = String(data.get("status", "")).strip_edges().to_lower()
	if status in PENDING_STATUSES or status in NEGATIVE_STATUSES:
		return false
	for counter in ["failed", "failed_count", "error_count", "errors_count", "invalid_count"]:
		if data.has(counter) and int(data[counter]) > 0:
			return false
	match tool_name:
		"assert_no_runtime_errors":
			var measured: bool = data.has("error_count") or data.get("errors") is Array
			var errors: int = -1
			if data.has("error_count"):
				errors = int(data["error_count"])
			elif data.get("errors") is Array:
				errors = (data["errors"] as Array).size()
			return bool(data.get("passed", false)) and measured and errors >= 0
		"assert_performance_budget":
			return bool(data.get("passed", false)) and data.get("checks") is Array and not (data["checks"] as Array).is_empty()
		"assert_visual_baseline":
			return bool(data.get("passed", false)) and (data.has("diff_pixel_count") or data.has("diff_ratio"))
		"audit_project_health":
			return status in ["healthy", "warning"] and data.get("summary") is Dictionary and not (data["summary"] as Dictionary).is_empty()
		"play_and_verify":
			return bool(data.get("passed", false)) and data.get("runtime_info") is Dictionary and not (data["runtime_info"] as Dictionary).is_empty()
		"run_project_test", "run_project_tests":
			return status == "passed" and int(data.get("total_count", 0)) > 0 and int(data.get("failed_count", 0)) == 0
		"smoke_test_export":
			return bool(data.get("success", false)) and bool(data.get("artifact_exists", false))
		"validate_export_preset":
			return bool(data.get("valid", false))
		"validate_script", "validate_shader":
			return bool(data.get("valid", false)) or (status == "passed" and bool(data.get("passed", true)))
		"verify_scripts":
			return int(data.get("total_checked", 0)) > 0 and int(data.get("failed", -1)) == 0 and (status.is_empty() or status in ["ok", "passed", "success", "completed"])
		"audit_scene_node_persistence":
			return int(data.get("total_nodes", 0)) > 0 and int(data.get("issue_count", -1)) == 0
		"scan_missing_resource_dependencies", "scan_cyclic_resource_dependencies":
			return data.has("issue_count") and int(data.get("issue_count", -1)) == 0
		"scan_migration_compatibility":
			return data.has("must_fix_count") and int(data.get("must_fix_count", -1)) == 0
		"detect_broken_scripts":
			return data.has("broken_count") and int(data.get("broken_count", -1)) == 0
		"manage_localization":
			return status in ["ok", "success", "completed"] and (
				data.has("written") or data.has("translations") or data.has("key_count"))
	if data.has("passed"):
		return bool(data["passed"])
	if data.has("success"):
		return bool(data["success"])
	if data.has("valid"):
		return bool(data["valid"])
	if not status.is_empty():
		return status in ["ok", "passed", "success", "completed", "healthy", "warning", "ready"]
	# Inspection tools frequently return structured data without a status field.
	# Non-empty, error-free evidence is sufficient for non-objective steps.
	return data.size() > 0

func record_step_result(plan: Dictionary, step_id: String, result: Variant) -> Dictionary:
	var task: Dictionary = get_task(plan, step_id)
	if task.is_empty():
		return {"error": "workflow step '%s' not found" % step_id}
	var workflow: Dictionary = plan.get("workflow", {})
	if is_pending_result(result):
		task["status"] = "pending"
		task["pending_polls"] = int(task.get("pending_polls", 0)) + 1
		var pending_receipt: Dictionary = append_receipt(plan, {
			"step_id": step_id,
			"tool_name": task.get("tool_name", ""),
			"passed": false,
			"pending": true,
			"status": (result as Dictionary).get("status", "pending")
		})
		if int(task["pending_polls"]) > MAX_PENDING_POLLS:
			task["status"] = "blocked"
			workflow["state"] = "blocked"
			workflow["blocked_reason"] = "Async step exceeded %d polls" % MAX_PENDING_POLLS
			return {"status": "blocked", "step_id": step_id, "receipt": pending_receipt, "workflow": summarize(plan)}
		workflow["state"] = "waiting"
		return {"status": "waiting", "step_id": step_id, "receipt": pending_receipt, "workflow": summarize(plan)}

	task["attempts"] = int(task.get("attempts", 0)) + 1
	task["pending_polls"] = 0
	var passed: bool = result_passed(String(task.get("tool_name", "")), result) if bool(task.get("objective_gate", false)) else _non_gate_result_usable(result)
	var receipt: Dictionary = append_receipt(plan, {
		"step_id": step_id,
		"tool_name": task.get("tool_name", ""),
		"passed": passed,
		"pending": false,
		"summary": _compact_result_summary(result)
	})
	if passed:
		task["status"] = "done"
		task["receipt_digest"] = receipt.get("digest", "")
		if bool(task.get("objective_gate", false)):
			var dod: Array = task.get("dod", [])
			if not dod.is_empty():
				dod[0]["met"] = true
				dod[0]["evidence"] = "workflow-receipt:%s" % receipt.get("digest", "")
		if workflow_completed(plan):
			workflow["state"] = "completed"
		else:
			workflow["state"] = "running"
		workflow["blocked_reason"] = ""
		return {"status": "completed", "step_id": step_id, "receipt": receipt, "workflow": summarize(plan)}

	var repair_tool: String = String(task.get("repair_tool", ""))
	var repair_attempts: int = int(task.get("repair_attempts", 0))
	var repair_limit: int = int(task.get("max_repair_attempts", DEFAULT_REPAIR_ATTEMPTS))
	if not repair_tool.is_empty() and repair_attempts < repair_limit:
		task["status"] = "blocked"
		task["repair_pending"] = true
		workflow["state"] = "repairing"
		workflow["blocked_reason"] = "Verification failed; bounded repair is ready"
		return {
			"status": "repair_required",
			"step_id": step_id,
			"repair_tool": repair_tool,
			"repair_attempt": repair_attempts + 1,
			"receipt": receipt,
			"workflow": summarize(plan)
		}
	task["status"] = "blocked"
	task["repair_pending"] = false
	workflow["state"] = "blocked"
	workflow["blocked_reason"] = "Step failed without acceptable evidence or exhausted its repair budget"
	return {"status": "blocked", "step_id": step_id, "receipt": receipt, "workflow": summarize(plan)}

func _non_gate_result_usable(result: Variant) -> bool:
	if not (result is Dictionary) or (result as Dictionary).is_empty():
		return false
	var data: Dictionary = result
	if data.has("error"):
		return false
	for verdict_key in ["passed", "success", "valid"]:
		if data.has(verdict_key) and not bool(data[verdict_key]):
			return false
	var status: String = String(data.get("status", "")).strip_edges().to_lower()
	if status in PENDING_STATUSES:
		return false
	return not status in ["error", "invalid", "blocked", "cancelled", "canceled", "timeout", "timed_out", "unconfigured", "stale", "aborted", "missing"]

func record_repair_result(plan: Dictionary, step_id: String, result: Variant) -> Dictionary:
	var task: Dictionary = get_task(plan, step_id)
	if task.is_empty() or not bool(task.get("repair_pending", false)):
		return {"error": "step '%s' has no authorized repair pending" % step_id}
	var repair_tool: String = String(task.get("repair_tool", ""))
	task["repair_attempts"] = int(task.get("repair_attempts", 0)) + 1
	var passed: bool = result_passed(repair_tool, result)
	var receipt: Dictionary = append_receipt(plan, {
		"step_id": step_id,
		"tool_name": repair_tool,
		"repair": true,
		"passed": passed,
		"summary": _compact_result_summary(result)
	})
	var workflow: Dictionary = plan.get("workflow", {})
	if passed:
		task["status"] = "pending"
		task["repair_pending"] = false
		workflow["state"] = "running"
		workflow["blocked_reason"] = ""
		return {"status": "repaired", "step_id": step_id, "receipt": receipt, "workflow": summarize(plan)}
	task["status"] = "blocked"
	task["repair_pending"] = false
	workflow["state"] = "blocked"
	workflow["blocked_reason"] = "Authorized repair failed"
	return {"status": "blocked", "step_id": step_id, "receipt": receipt, "workflow": summarize(plan)}

func _compact_result_summary(result: Variant) -> Dictionary:
	if not (result is Dictionary):
		return {"type": typeof(result)}
	var data: Dictionary = result
	var summary: Dictionary = {}
	for key in ["status", "passed", "success", "valid", "total_count", "failed_count", "total_checked", "failed", "error_count", "issue_count", "artifact_exists"]:
		if data.has(key):
			summary[key] = data[key]
	if data.has("error"):
		summary["error"] = String(data["error"]).substr(0, 512)
	return summary

func append_receipt(plan: Dictionary, receipt_fields: Dictionary) -> Dictionary:
	var workflow: Dictionary = plan.get("workflow", {})
	if not (workflow.get("receipts") is Array):
		workflow["receipts"] = []
	var receipt: Dictionary = receipt_fields.duplicate(true)
	receipt["at"] = TaskPlanStoreScript._now()
	receipt["digest"] = _sha256(JSON.stringify(receipt))
	var receipts: Array = workflow["receipts"]
	for existing_value in receipts:
		if String((existing_value as Dictionary).get("digest", "")) == String(receipt["digest"]):
			return existing_value
	receipts.append(receipt)
	while receipts.size() > MAX_RECEIPTS:
		receipts.pop_front()
	return receipt

func workflow_completed(plan: Dictionary) -> bool:
	var workflow: Dictionary = plan.get("workflow", {})
	var receipts = workflow.get("receipts", [])
	if not (receipts is Array):
		return false
	var passing_digests: Dictionary = {}
	for receipt_value in receipts:
		var receipt: Dictionary = receipt_value
		if bool(receipt.get("passed", false)) and not bool(receipt.get("repair", false)):
			passing_digests[String(receipt.get("digest", ""))] = true
	for task_value in plan.get("tasks", []):
		var task: Dictionary = task_value
		if String(task.get("status", "")) != "done":
			return false
	for gate_id_value in workflow.get("objective_gate_ids", []):
		var gate_task: Dictionary = get_task(plan, String(gate_id_value))
		if gate_task.is_empty() or not bool(gate_task.get("objective_gate", false)):
			return false
		var digest: String = String(gate_task.get("receipt_digest", ""))
		if digest.is_empty() or not passing_digests.has(digest):
			return false
		var dod: Array = gate_task.get("dod", [])
		if dod.is_empty() or not bool((dod[0] as Dictionary).get("met", false)):
			return false
	return not (workflow.get("objective_gate_ids", []) as Array).is_empty()

func summarize(plan: Dictionary) -> Dictionary:
	var workflow: Dictionary = plan.get("workflow", {})
	var counts: Dictionary = {"pending": 0, "done": 0, "blocked": 0, "in_progress": 0}
	var needs_input: Array[Dictionary] = []
	for task_value in plan.get("tasks", []):
		var task: Dictionary = task_value
		var status: String = String(task.get("status", "pending"))
		if counts.has(status):
			counts[status] = int(counts[status]) + 1
		if bool(task.get("needs_input", false)):
			needs_input.append({"step_id": task.get("id", ""), "tool_name": task.get("tool_name", ""), "missing": task.get("missing_inputs", [])})
	return {
		"workflow_id": workflow.get("workflow_id", ""),
		"state": workflow.get("state", ""),
		"objective": plan.get("goal", ""),
		"profiles": (workflow.get("goal_contract", {}) as Dictionary).get("profiles", []),
		"progress": counts,
		"ready": ready_steps(plan),
		"needs_input": needs_input,
		"blocked_reason": workflow.get("blocked_reason", ""),
		"blueprint_hash": workflow.get("blueprint_hash", "")
	}

func path_allowed(plan: Dictionary, candidate_path: String) -> bool:
	var clean_candidate: String = candidate_path.strip_edges()
	if clean_candidate.is_empty():
		return true
	var candidate_absolute: String = _canonical_path(clean_candidate)
	if candidate_absolute.is_empty():
		return false
	var contract: Dictionary = (plan.get("workflow", {}) as Dictionary).get("goal_contract", {})
	for protected_value in contract.get("protected_paths", DEFAULT_PROTECTED_PATHS):
		var protected_absolute: String = _canonical_path(String(protected_value))
		if protected_absolute.is_empty():
			continue
		var protected_prefix: String = protected_absolute.trim_suffix("/") + "/"
		if candidate_absolute == protected_absolute.trim_suffix("/") or candidate_absolute.begins_with(protected_prefix):
			return false
	return true

func arguments_allowed(plan: Dictionary, arguments: Dictionary) -> Dictionary:
	var rejected: Array[String] = []
	_collect_rejected_paths(plan, arguments, "", rejected)
	if not rejected.is_empty():
		return {"error": "Workflow arguments target protected paths", "protected_paths": rejected}
	return {"status": "ok"}

func _collect_rejected_paths(plan: Dictionary, value: Variant, key_path: String, rejected: Array[String]) -> void:
	if value is Dictionary:
		for key_value in (value as Dictionary).keys():
			var key: String = String(key_value)
			_collect_rejected_paths(plan, value[key_value], key_path + "." + key, rejected)
	elif value is Array:
		for item in value:
			_collect_rejected_paths(plan, item, key_path, rejected)
	elif value is String:
		var text: String = String(value).strip_edges()
		var normalized_key: String = key_path.to_lower()
		if (text.begins_with("res://") or text.begins_with("user://")) and (
			"path" in normalized_key or "file" in normalized_key or "dir" in normalized_key):
			if not path_allowed(plan, text) and not text in rejected:
				rejected.append(text)

func _canonical_path(path: String) -> String:
	var clean: String = path.strip_edges()
	if clean.begins_with("res://") or clean.begins_with("user://"):
		return ProjectSettings.globalize_path(clean).simplify_path()
	if clean.is_absolute_path():
		return clean.simplify_path()
	return ""

static func _sha256(text: String) -> String:
	var context: HashingContext = HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(text.to_utf8_buffer())
	return context.finish().hex_encode()
