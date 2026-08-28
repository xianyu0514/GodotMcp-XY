extends "res://addons/gut/test.gd"

const EngineScript = preload("res://addons/godot_mcp/native_mcp/game_workflow_engine.gd")
const ManifestScript = preload("res://addons/godot_mcp/native_mcp/tools_manifest.gd")

var _engine: RefCounted
var _available: Array[String]

func before_each() -> void:
	_engine = EngineScript.new()
	_available = ManifestScript.tool_names()

func _compile(objective: String, profiles: Array = [], extra: Dictionary = {}) -> Dictionary:
	var options: Dictionary = extra.duplicate(true)
	if not profiles.is_empty():
		options["profiles"] = profiles
	return _engine.compile(objective, options, _available)

func _task_for_tool(plan: Dictionary, tool_name: String) -> Dictionary:
	for task_value in plan.get("tasks", []):
		var task: Dictionary = task_value
		if String(task.get("tool_name", "")) == tool_name:
			return task
	return {}

func _tool_names(plan: Dictionary) -> Array[String]:
	var names: Array[String] = []
	for task_value in plan.get("tasks", []):
		names.append(String((task_value as Dictionary).get("tool_name", "")))
	return names

func _first_capabilities(count: int) -> Array[String]:
	var capabilities: Array[String] = []
	for tool_name in _available:
		if tool_name in EngineScript.FORBIDDEN_NESTED_CAPABILITIES:
			continue
		capabilities.append(tool_name)
		if capabilities.size() >= count:
			break
	return capabilities

func test_composable_profiles_build_a_persistent_dag_beyond_discovery_budget() -> void:
	var result: Dictionary = _compile(
		"Create a playable controller and polished pause menu, then test it",
		["gameplay_feature", "ui_screen", "quality_assurance"])
	assert_false(result.has("error"), str(result.get("error", "")))
	var plan: Dictionary = result.get("plan", {})
	assert_gt((plan.get("tasks", []) as Array).size(), 10,
		"A complete workflow may exceed the per-turn 8/10 discovery budget")
	assert_eq(plan.get("goal", ""), "Create a playable controller and polished pause menu, then test it")
	assert_eq((plan.get("workflow", {}) as Dictionary).get("state", ""), "planned")
	assert_gt(((plan.get("workflow", {}) as Dictionary).get("objective_gate_ids", []) as Array).size(), 0)
	var create_scene_tasks: Array[Dictionary] = []
	for task_value in plan.get("tasks", []):
		var task: Dictionary = task_value
		if String(task.get("tool_name", "")) == "create_scene":
			create_scene_tasks.append(task)
	assert_eq(create_scene_tasks.size(), 2,
		"Gameplay and UI scenes are distinct writes and must never be deduplicated")
	assert_eq(create_scene_tasks[0].get("profile", ""), "gameplay_feature")
	assert_eq(create_scene_tasks[1].get("profile", ""), "ui_screen")
	assert_ne(create_scene_tasks[0].get("step_key", ""), create_scene_tasks[1].get("step_key", ""))
	var tool_sequence: Array[String] = _tool_names(plan)
	assert_lt(tool_sequence.find("attach_script"), tool_sequence.rfind("create_scene"),
		"Gameplay scene mutations stay together before the UI scene changes editor context")

func test_large_supported_goals_are_not_capped_by_tool_or_task_count() -> void:
	for requested_size in [20, 50, 100]:
		var result: Dictionary = _compile(
			"Run project tests with every explicitly required capability",
			["quality_assurance"],
			{"required_capabilities": _first_capabilities(requested_size)})
		assert_false(result.has("error"), str(result.get("error", "")))
		assert_gte((result["plan"].get("tasks", []) as Array).size(), requested_size,
			"A supported goal must retain every required capability")
		assert_eq(_engine.validate_integrity(result["plan"], _available).get("status", ""), "ok")

func test_ready_step_limit_is_a_caller_slice_not_a_four_step_ceiling() -> void:
	var plan: Dictionary = {"tasks": []}
	for index in range(100):
		plan["tasks"].append({
			"id": "scale_%03d" % index,
			"status": "pending",
			"depends_on": []
		})
	assert_eq(_engine.ready_steps(plan, 100).size(), 100,
		"The engine must not silently clamp a requested execution slice to four")

func test_adaptive_metrics_upgrade_an_existing_schema_v1_plan_in_place() -> void:
	var plan: Dictionary = _compile("Run all project tests", ["quality_assurance"])["plan"]
	(plan["workflow"] as Dictionary).erase("metrics")
	var metrics: Dictionary = _engine.workflow_metrics(plan)
	metrics["rounds"] = 2
	assert_eq(int((plan["workflow"]["metrics"] as Dictionary).get("rounds", 0)), 2,
		"Lazy metrics must remain attached so the next checkpoint persists them")
	assert_gt(_engine.recommended_step_budget(plan), 0)

func test_unknown_objective_requests_clarification_instead_of_guessing() -> void:
	var result: Dictionary = _compile("Make the mysterious thing exactly right")
	assert_true(result.has("error"), "An unclassified objective must not silently become gameplay")
	assert_eq(result.get("status", ""), "needs_clarification")
	assert_true(result.has("supported_profiles"))

func test_missing_requested_capability_blocks_planning() -> void:
	var available: Array[String] = _available.duplicate()
	available.erase("create_script")
	var result: Dictionary = _engine.compile("Create player movement", {
		"profiles": ["gameplay_feature"],
		"required_capabilities": ["create_script"]
	}, available)
	assert_true(result.has("error"))
	assert_true("create_script" in result.get("missing_capabilities", []))

func test_every_atomic_capability_can_be_a_complete_capability_only_goal() -> void:
	for tool_name in _available:
		if tool_name in EngineScript.FORBIDDEN_NESTED_CAPABILITIES:
			continue
		var result: Dictionary = _engine.compile(tool_name, {
			"required_capabilities": [tool_name]
		}, _available)
		assert_false(result.has("error"), "Atomic goal must compile: %s" % tool_name)
		if result.has("error"):
			continue
		var plan: Dictionary = result["plan"]
		assert_true(tool_name in _tool_names(plan), "Atomic goal must retain: %s" % tool_name)
		assert_gt(((plan["workflow"] as Dictionary).get("objective_gate_ids", []) as Array).size(), 0,
			"Capability-only goals need direct objective evidence: %s" % tool_name)

func test_explicit_capability_is_a_gate_even_when_a_profile_already_contains_it() -> void:
	var plan: Dictionary = _engine.compile("find_deprecated_api_usage", {
		"required_capabilities": ["find_deprecated_api_usage"]
	}, _available)["plan"]
	var scan: Dictionary = _task_for_tool(plan, "find_deprecated_api_usage")
	assert_true(bool(scan.get("objective_gate", false)),
		"A broad project-health gate must not replace explicitly requested evidence")

func test_runtime_tools_depend_on_probe_and_running_project() -> void:
	var result: Dictionary = _compile("Debug the running player and prove there are no errors", ["runtime_debug"])
	assert_false(result.has("error"), str(result.get("error", "")))
	var plan: Dictionary = result["plan"]
	var probe: Dictionary = _task_for_tool(plan, "install_runtime_probe")
	var run: Dictionary = _task_for_tool(plan, "run_project")
	assert_false(probe.is_empty())
	assert_false(run.is_empty())
	assert_true(String(probe.get("id", "")) in run.get("depends_on", []))
	for task_value in plan.get("tasks", []):
		var task: Dictionary = task_value
		if String(task.get("stage", "")).begins_with("runtime_") and String(task.get("tool_name", "")) not in ["install_runtime_probe", "run_project"]:
			assert_true(String(run.get("id", "")) in task.get("depends_on", []),
				"Live runtime reads/actions must wait for run_project")

func test_pending_result_waits_without_consuming_retry_or_creating_repair() -> void:
	var result: Dictionary = _compile("Run all project tests", ["quality_assurance"])
	var plan: Dictionary = result["plan"]
	var task: Dictionary = _task_for_tool(plan, "run_project_tests")
	var step_id: String = String(task.get("id", ""))
	var pending: Dictionary = _engine.record_step_result(plan, step_id, {"status": "pending"})
	assert_eq(pending.get("status", ""), "waiting")
	task = _engine.get_task(plan, step_id)
	assert_eq(task.get("status", ""), "pending")
	assert_eq(int(task.get("attempts", -1)), 0)
	assert_eq(int(task.get("pending_polls", 0)), 1)
	assert_eq((plan.get("tasks", []) as Array).size(), (result["plan"].get("tasks", []) as Array).size())
	var passed: Dictionary = _engine.record_step_result(plan, step_id, {
		"status": "passed", "total_count": 3, "failed_count": 0
	})
	assert_eq(passed.get("status", ""), "completed")
	assert_eq(_engine.get_task(plan, step_id).get("status", ""), "done")

func test_long_async_wait_yields_without_blocking_or_wasting_receipts() -> void:
	var result: Dictionary = _compile("Run all project tests", ["quality_assurance"])
	var plan: Dictionary = result["plan"]
	var task: Dictionary = _task_for_tool(plan, "run_project_tests")
	var step_id: String = String(task.get("id", ""))
	var verdict: Dictionary = {}
	for poll_index in range(EngineScript.PENDING_POLL_WINDOW + 5):
		verdict = _engine.record_step_result(plan, step_id, {"status": "pending", "job_id": "same-job"})
	assert_eq(verdict.get("status", ""), "waiting")
	assert_ne((plan.get("workflow", {}) as Dictionary).get("state", ""), "blocked")
	assert_eq((_engine.get_task(plan, step_id)).get("status", ""), "pending")
	assert_eq(((plan.get("workflow", {}) as Dictionary).get("receipts", []) as Array).size(), 1,
		"Identical pending polls should aggregate instead of growing plan tokens")
	assert_eq(int((((plan["workflow"]["receipts"] as Array)[0]) as Dictionary).get("occurrences", 0)),
		EngineScript.PENDING_POLL_WINDOW + 5)

func test_empty_or_failed_verification_evidence_never_passes() -> void:
	assert_false(_engine.result_passed("assert_no_runtime_errors", {}))
	assert_false(_engine.result_passed("assert_no_runtime_errors", {"status": "ok"}))
	assert_false(_engine.result_passed("verify_scripts", {
		"status": "ok", "total_checked": 5, "failed": 1
	}))
	assert_false(_engine.result_passed("run_project_tests", {
		"status": "passed", "total_count": 0, "failed_count": 0
	}))
	assert_false(_engine.result_passed("audit_project_health", {
		"status": "unconfigured", "summary": {}
	}))
	assert_true(_engine.result_passed("verify_scripts", {
		"status": "passed", "total_checked": 5, "failed": 0
	}))

func test_repairs_respect_goal_scope_and_export_platform() -> void:
	var audit: Dictionary = _compile("Audit project health only", ["project_health"])["plan"]
	assert_false("apply_migration_fixes" in _tool_names(audit),
		"Read-only audit intent must not authorize automatic migration writes")
	var repair: Dictionary = _compile("Fix migration compatibility issues", ["project_health"])["plan"]
	assert_true("apply_migration_fixes" in _tool_names(repair))
	var linux: Dictionary = _compile("Export and smoke test a Linux build", ["release_export"], {
		"platform": "linux"
	})["plan"]
	assert_false("configure_android_export" in _tool_names(linux))
	var android: Dictionary = _compile("Configure, export and smoke test Android", ["release_export"], {
		"platform": "android"
	})["plan"]
	assert_true("configure_android_export" in _tool_names(android))

func test_integrity_rejects_gate_removal_and_dependency_weakening() -> void:
	var plan: Dictionary = _compile("Create and test player movement", ["gameplay_feature"])["plan"]
	var gate_ids: Array = (plan["workflow"] as Dictionary)["objective_gate_ids"]
	gate_ids.pop_back()
	assert_true(_engine.validate_integrity(plan, _available).has("error"))
	plan = _compile("Create and test player movement", ["gameplay_feature"])["plan"]
	var last_task: Dictionary = (plan.get("tasks", []) as Array).back()
	last_task["depends_on"] = []
	assert_true(_engine.validate_integrity(plan, _available).has("error"))

func test_protected_path_check_resolves_traversal_before_comparison() -> void:
	var plan: Dictionary = _compile("Create player movement", ["gameplay_feature"])["plan"]
	assert_false(_engine.path_allowed(plan, "res://scenes/../addons/godot_mcp/secret.gd"))
	assert_false(_engine.path_allowed(plan, "res://.mcp/task_plan.json"))
	assert_true(_engine.path_allowed(plan, "res://scenes/player.tscn"))

func test_fake_done_flags_without_passing_receipts_cannot_complete_objective() -> void:
	var plan: Dictionary = _compile("Run all project tests", ["quality_assurance"])["plan"]
	for task_value in plan.get("tasks", []):
		(task_value as Dictionary)["status"] = "done"
	assert_false(_engine.workflow_completed(plan),
		"Objective gates need engine-issued passing receipt digests")

func test_adaptive_repairs_use_progress_not_a_low_global_attempt_ceiling() -> void:
	var plan: Dictionary = _compile("Run all project tests", ["quality_assurance"])["plan"]
	assert_eq(int(plan["workflow"]["goal_contract"].get("max_repair_attempts", -1)), 0,
		"Zero means adaptive repair rather than zero repairs")
	var gate: Dictionary = _task_for_tool(plan, "verify_scripts")
	var step_id: String = String(gate.get("id", ""))
	var verdict: Dictionary = {}
	for attempt in range(EngineScript.SAME_FAILURE_REPLAN_THRESHOLD):
		verdict = _engine.record_step_result(plan, step_id, {
			"status": "failed", "total_checked": 2, "failed": 1,
			"errors": [{"line": 10, "message": "same parse error"}]
		})
		if verdict.get("status", "") == "replan_required":
			break
		assert_eq(verdict.get("status", ""), "repair_required")
		var repaired: Dictionary = _engine.record_repair_result(plan, step_id, {"status": "ok"})
		assert_eq(repaired.get("status", ""), "repaired")
	assert_eq(verdict.get("status", ""), "replan_required",
		"Repeated identical evidence should request a different plan, not burn infinite compute")
	assert_ne((plan.get("workflow", {}) as Dictionary).get("state", ""), "completed")

func test_adaptive_repairs_may_continue_when_diagnostic_evidence_changes() -> void:
	var plan: Dictionary = _compile("Run all project tests", ["quality_assurance"])["plan"]
	var gate: Dictionary = _task_for_tool(plan, "verify_scripts")
	var step_id: String = String(gate.get("id", ""))
	for attempt in range(EngineScript.SAME_FAILURE_REPLAN_THRESHOLD + 2):
		var verdict: Dictionary = _engine.record_step_result(plan, step_id, {
			"status": "failed", "total_checked": 2, "failed": 1,
			"elapsed_ms": attempt * 10,
			"errors": [{"line": 10 + attempt, "message": "new diagnostic evidence"}]
		})
		assert_eq(verdict.get("status", ""), "repair_required",
			"Changed diagnostic evidence is progress and must not hit the identical-failure guard")
		assert_eq(_engine.record_repair_result(plan, step_id, {"status": "ok"}).get("status", ""), "repaired")

func test_transient_repair_failures_back_off_without_consuming_explicit_budget() -> void:
	var plan: Dictionary = _compile("Run all project tests", ["quality_assurance"], {
		"max_repair_attempts": 1
	})["plan"]
	var gate: Dictionary = _task_for_tool(plan, "verify_scripts")
	var step_id: String = String(gate.get("id", ""))
	assert_eq(_engine.record_step_result(plan, step_id, {
		"status": "failed", "total_checked": 1, "failed": 1
	}).get("status", ""), "repair_required")
	var first: Dictionary = _engine.record_repair_result(plan, step_id, {
		"error": "Service temporarily unavailable (503)"
	})
	var second: Dictionary = _engine.record_repair_result(plan, step_id, {
		"error": "Service temporarily unavailable (503)"
	})
	assert_eq(first.get("status", ""), "retry_required")
	assert_eq(int(first.get("retry_after_ms", 0)), 1000)
	assert_eq(int(second.get("retry_after_ms", 0)), 2000)
	assert_eq(int(gate.get("repair_attempts", -1)), 0,
		"Infrastructure outages are not failed repair logic attempts")
	assert_eq((plan["workflow"] as Dictionary).get("state", ""), "waiting")

func test_explicit_repair_policy_requests_replan_when_real_attempt_is_exhausted() -> void:
	var plan: Dictionary = _compile("Run all project tests", ["quality_assurance"], {
		"max_repair_attempts": 1
	})["plan"]
	var gate: Dictionary = _task_for_tool(plan, "verify_scripts")
	var step_id: String = String(gate.get("id", ""))
	assert_eq(_engine.record_step_result(plan, step_id, {
		"status": "failed", "total_checked": 1, "failed": 1
	}).get("status", ""), "repair_required")
	var verdict: Dictionary = _engine.record_repair_result(plan, step_id, {
		"status": "failed", "error": "Patch did not resolve the diagnostic"
	})
	assert_eq(verdict.get("status", ""), "replan_required")
	assert_eq((plan["workflow"] as Dictionary).get("state", ""), "replan_required")
	assert_false(bool(gate.get("repair_pending", true)))

func test_blueprint_is_deterministic_and_receipts_preserve_all_semantic_evidence() -> void:
	var first: Dictionary = _compile("Create player movement", ["gameplay_feature"])["plan"]
	var second: Dictionary = _compile("Create player movement", ["gameplay_feature"])["plan"]
	assert_eq(first["workflow"]["blueprint_hash"], second["workflow"]["blueprint_hash"])
	for i in range(300):
		_engine.append_receipt(first, {"step_id": "probe", "passed": true, "n": i})
	assert_eq((first["workflow"]["receipts"] as Array).size(), 300,
		"Distinct completion evidence must never be discarded to meet a storage budget")
