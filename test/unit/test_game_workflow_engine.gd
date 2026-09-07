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

func test_integrity_recomputes_receipts_and_requires_one_for_every_done_step() -> void:
	var plan: Dictionary = _compile("get_project_info", [], {
		"required_capabilities": ["get_project_info"]
	})["plan"]
	assert_eq(int((plan["workflow"] as Dictionary).get("receipt_integrity_version", 0)), 1)
	var task: Dictionary = _task_for_tool(plan, "get_project_info")
	var verdict: Dictionary = _engine.record_step_result(plan, String(task.get("id", "")), {
		"status": "ok", "project_name": "ReceiptProof"
	})
	assert_eq(verdict.get("status", ""), "completed")
	assert_eq(_engine.validate_integrity(plan, _available).get("status", ""), "ok")
	var receipt: Dictionary = ((plan["workflow"]["receipts"] as Array)[0] as Dictionary)
	var original_passed: bool = bool(receipt.get("passed", false))
	receipt["passed"] = not original_passed
	var tampered_receipt: Dictionary = _engine.validate_integrity(plan, _available)
	assert_true(tampered_receipt.has("error"),
		"Changing receipt evidence without recomputing its digest must fail closed")
	receipt["passed"] = original_passed
	task["receipt_digest"] = "forged-or-missing"
	var missing_receipt: Dictionary = _engine.validate_integrity(plan, _available)
	assert_true(missing_receipt.has("error"),
		"A done step cannot survive recovery without its matching passing receipt")

func test_receipt_digest_survives_json_numeric_round_trip() -> void:
	var plan: Dictionary = _compile("get_project_info", [], {
		"required_capabilities": ["get_project_info"]
	})["plan"]
	var task: Dictionary = _task_for_tool(plan, "get_project_info")
	_engine.append_receipt(plan, {
		"step_id": task.get("id", ""),
		"tool_name": "get_project_info",
		"passed": false,
		"pending": true,
		"summary": {"total_count": 3, "ratio": 0.5}
	})
	var persisted: Dictionary = JSON.parse_string(JSON.stringify(plan))
	assert_eq(_engine.validate_integrity(persisted, _available).get("status", ""), "ok",
		"Receipt hashing must canonicalize integers changed to floats by JSON persistence")

func test_receipt_digest_does_not_collapse_near_integer_evidence() -> void:
	var plan: Dictionary = _compile("get_project_info", [], {
		"required_capabilities": ["get_project_info"]
	})["plan"]
	var task: Dictionary = _task_for_tool(plan, "get_project_info")
	_engine.append_receipt(plan, {
		"step_id": task.get("id", ""),
		"tool_name": "get_project_info",
		"passed": false,
		"pending": true,
		"summary": {"ratio": 1.0}
	})
	var receipt: Dictionary = ((plan["workflow"]["receipts"] as Array)[0] as Dictionary)
	(receipt["summary"] as Dictionary)["ratio"] = 1.000001
	assert_true(_engine.validate_integrity(plan, _available).has("error"),
		"Distinct fractional evidence must not retain the digest of an integer value")

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

func test_list_project_tests_requires_discovered_tests() -> void:
	assert_false(_engine.result_passed("list_project_tests", {
		"status": "ready", "count": 0, "tests": []
	}))
	assert_false(_engine.result_passed("list_project_tests", {
		"status": "unconfigured", "count": 0, "recoverable": true
	}))
	assert_true(_engine.result_passed("list_project_tests", {
		"status": "ready", "count": 2, "tests": [{"name": "a"}, {"name": "b"}]
	}))

func test_recoverable_environment_gap_is_usable_non_gate_evidence() -> void:
	assert_true(_engine._non_gate_result_usable({
		"status": "unconfigured", "recoverable": true, "reason": "test_directory_missing"
	}))
	assert_false(_engine._non_gate_result_usable({
		"status": "unconfigured", "recoverable": false
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

# --- Workflow reliability: evidence contract, negated intent, artifacts, negative gates ---

func test_localization_success_without_status_is_accepted_evidence() -> void:
	assert_true(_engine.result_passed("manage_localization", {"success": true}),
		"Explicit boolean success without a status vocabulary word is real success")
	assert_true(_engine.result_passed("manage_localization", {"status": "ok", "written": 2}),
		"Status-vocabulary successes keep passing")
	assert_false(_engine.result_passed("manage_localization", {"success": false}),
		"Explicit false still fails")

func test_mutation_completion_statuses_are_accepted_evidence() -> void:
	assert_true(_engine.result_passed("create_project_smoke_test", {
		"status": "created", "path": "res://test/test_project_smoke.gd"}),
		"'created' is a successful mutation completion, not a verification failure")
	assert_true(_engine.result_passed("ensure_project_directory", {
		"status": "unchanged", "path": "res://test"}),
		"Idempotent no-op completions ('unchanged') are successes")
	assert_false(_engine.result_passed("prepare_project_test_environment", {
		"status": "unconfigured", "recoverable": false}),
		"Negative statuses still fail")

func test_negated_platform_mentions_do_not_select_platform() -> void:
	var negated: Dictionary = _compile("2D stress game with flow fields; Android 不适用", ["gameplay_feature"])
	assert_false(negated.has("error"), str(negated.get("error", "")))
	var negated_contract: Dictionary = ((negated.get("plan", {}) as Dictionary).get("workflow", {}) as Dictionary).get("goal_contract", {})
	assert_eq(String((negated_contract as Dictionary).get("platform", "")), "",
		"'Android 不适用' must not select the android platform")
	var affirmative: Dictionary = _compile("Ship the release to Android", ["release_export"])
	var affirmative_contract: Dictionary = ((affirmative.get("plan", {}) as Dictionary).get("workflow", {}) as Dictionary).get("goal_contract", {})
	assert_eq(String((affirmative_contract as Dictionary).get("platform", "")), "android",
		"Affirmative Android intent still selects android")

func test_negated_3d_intent_does_not_add_gltf_gate() -> void:
	var negated: Dictionary = _compile("2D asset pipeline pass; 3D 不适用", ["asset_pipeline"])
	assert_false(negated.has("error"), str(negated.get("error", "")))
	assert_false("inspect_gltf_asset" in _tool_names(negated.get("plan", {})),
		"'3D 不适用' must not require the glTF inspector gate")
	var affirmative: Dictionary = _compile("Import gltf 模型 and validate imports", ["asset_pipeline"])
	assert_true("inspect_gltf_asset" in _tool_names(affirmative.get("plan", {})),
		"Affirmative glTF intent keeps the gate")

func test_successful_creation_steps_register_artifacts() -> void:
	var plan: Dictionary = _compile("Create player movement", ["gameplay_feature"])["plan"]
	var scene_task: Dictionary = _task_for_tool(plan, "create_scene")
	_engine.record_step_result(plan, String(scene_task.get("id", "")), {
		"success": true, "scene_path": "res://levels/main.tscn"})
	var script_task: Dictionary = _task_for_tool(plan, "create_script")
	_engine.record_step_result(plan, String(script_task.get("id", "")), {
		"success": true, "script_path": "res://scripts/player.gd"})
	var artifacts: Dictionary = ((plan.get("workflow", {}) as Dictionary).get("artifacts", {}) as Dictionary)
	assert_eq(String(artifacts.get("scene", "")), "res://levels/main.tscn",
		"Created scenes register as workflow artifacts")
	assert_eq(String(artifacts.get("script", "")), "res://scripts/player.gd",
		"Created scripts register as workflow artifacts")

func test_argument_references_resolve_from_artifacts() -> void:
	var artifacts: Dictionary = {"scene": "res://main.tscn", "script": "res://player.gd"}
	var resolved: Variant = _engine.resolve_argument_references(
		{"scene_path": "$scene", "nested": ["$script", "keep"], "n": 1}, artifacts)
	var resolved_dictionary: Dictionary = resolved
	assert_eq(String(resolved_dictionary["scene_path"]), "res://main.tscn")
	var nested: Array = resolved_dictionary["nested"]
	assert_eq(String(nested[0]), "res://player.gd")
	assert_eq(String(nested[1]), "keep",
		"Non-reference strings pass through unchanged")
	assert_eq(int(resolved_dictionary["n"]), 1,
		"Non-string values pass through unchanged")

func test_expect_fail_gate_passes_when_detector_fails() -> void:
	var plan: Dictionary = _compile("Fault-inject and verify detection", ["script_repair"], {
		"expect_fail": {"verify_scripts": true}})["plan"]
	var gate: Dictionary = _task_for_tool(plan, "verify_scripts")
	assert_eq(String(gate.get("expect", "")), "fail",
		"expect_fail marks the gate as a negative test")
	var step_id: String = String(gate.get("id", ""))
	var injected: Dictionary = _engine.record_step_result(plan, step_id, {
		"status": "failed", "total_checked": 1, "failed": 1})
	assert_eq(String(injected.get("status", "")), "completed",
		"A failing detector satisfies a negative gate")
	assert_eq(String(gate.get("status", "")), "done")
	var receipts: Array = ((plan.get("workflow", {}) as Dictionary).get("receipts", []) as Array)
	assert_true(bool((receipts.back() as Dictionary).get("expected_failure", false)),
		"Negative-gate receipts record the inverted expectation")

func test_expect_fail_gate_fails_when_detector_still_passes() -> void:
	var plan: Dictionary = _compile("Fault-inject and verify detection", ["script_repair"], {
		"expect_fail": {"verify_scripts": true}})["plan"]
	var gate: Dictionary = _task_for_tool(plan, "verify_scripts")
	var verdict: Dictionary = _engine.record_step_result(plan, String(gate.get("id", "")), {
		"status": "passed", "total_checked": 1, "failed": 0})
	assert_eq(String(verdict.get("status", "")), "repair_required",
		"A detector that ignores the injected fault fails the negative gate")

func test_run_project_session_reuse_result_is_usable_evidence() -> void:
	var plan: Dictionary = _compile("Create player movement", ["gameplay_feature"])["plan"]
	var run_task: Dictionary = _task_for_tool(plan, "run_project")
	var verdict: Dictionary = _engine.record_step_result(plan, String(run_task.get("id", "")), {
		"success": true, "already_running": true, "scene": "res://main.tscn"})
	assert_eq(String(verdict.get("status", "")), "completed",
		"Reusing a live runtime session is successful workflow evidence")

func test_scene_artifacts_register_per_profile_alias() -> void:
	var plan: Dictionary = _compile("Create player movement", ["gameplay_feature"])["plan"]
	var scene_task: Dictionary = _task_for_tool(plan, "create_scene")
	assert_eq(String(scene_task.get("profile", "")), "gameplay_feature")
	_engine.record_step_result(plan, String(scene_task.get("id", "")), {
		"success": true, "scene_path": "res://levels/gameplay.tscn"})
	var artifacts: Dictionary = ((plan.get("workflow", {}) as Dictionary).get("artifacts", {}) as Dictionary)
	assert_eq(String(artifacts.get("scene:gameplay_feature", "")), "res://levels/gameplay.tscn",
		"Multi-scene workflows address each profile's scene explicitly")

func test_runtime_screenshot_registers_screenshot_artifact() -> void:
	var plan: Dictionary = _compile("Polished pause menu", ["ui_screen"])["plan"]
	var shot_task: Dictionary = _task_for_tool(plan, "get_runtime_screenshot")
	assert_false(shot_task.is_empty(), "ui_screen profile captures a runtime screenshot")
	_engine.record_step_result(plan, String(shot_task.get("id", "")), {
		"status": "ok", "save_path": "user://mcp_runtime_capture.jpg"})
	var artifacts: Dictionary = ((plan.get("workflow", {}) as Dictionary).get("artifacts", {}) as Dictionary)
	assert_eq(String(artifacts.get("screenshot", "")), "user://mcp_runtime_capture.jpg",
		"Visual gates derive their candidate from the captured screenshot")

func test_platformer_goal_selects_gameplay_profile() -> void:
	# 插件自带 prompt 示例 "2D platformer vertical slice" 曾只命中 ui_screen
	# （"screen"）：词表缺 platformer/jump/coin 时规划漏掉玩家/金币/胜利逻辑。
	var result: Dictionary = _compile("Make a 2D platformer with coins and a win screen")
	assert_false(result.has("error"), str(result.get("error", "")))
	var contract: Dictionary = ((result.get("plan", {}) as Dictionary).get("workflow", {}) as Dictionary) 		.get("goal_contract", {})
	var profiles: Array = contract.get("profiles", [])
	assert_true("gameplay_feature" in profiles,
		"platformer+coins goal must select gameplay_feature (got: %s)" % str(profiles))

func test_movement_goal_expands_directional_input_actions() -> void:
	# 蓝图控制器读取 move_left/right/up/down；单个默认 upsert 只注册 move_up，
	# get_vector 会退化到 ui_* 回退。移动目标必须展开四个方向动作步骤。
	var plan: Dictionary = _compile(
		"Arrow-key platformer movement with jumping", ["gameplay_feature"])["plan"]
	var upserts: Array[Dictionary] = []
	for task_value in plan.get("tasks", []):
		var task: Dictionary = task_value
		if String(task.get("tool_name", "")) == "upsert_project_input_action":
			upserts.append(task)
	assert_eq(upserts.size(), 4, "Movement goal registers four directional actions (got %d)" % upserts.size())
	var action_names: Array[String] = []
	for task in upserts:
		var args: Dictionary = task.get("arguments", {})
		action_names.append(String(args.get("action_name", "")))
	for expected in ["move_left", "move_right", "move_up", "move_down"]:
		assert_true(expected in action_names, "Directional action %s registered" % expected)
		var matched: Dictionary = upserts[action_names.find(expected)]
		var events: Array = matched.get("arguments", {}).get("events", [])
		assert_gt(events.size(), 0, "%s binds at least one key event" % expected)

func test_collectible_only_goal_keeps_single_default_upsert() -> void:
	var plan: Dictionary = _compile(
		"Collect a coin and show a win label", ["gameplay_feature"])["plan"]
	var upsert_count: int = 0
	for task_value in plan.get("tasks", []):
		if String((task_value as Dictionary).get("tool_name", "")) == "upsert_project_input_action":
			upsert_count += 1
	assert_eq(upsert_count, 1,
		"Non-movement goals keep the single default upsert step (got %d)" % upsert_count)

func test_save_scene_result_registers_scene_artifact() -> void:
	# save_scene 返回 saved_path（不是 save_path）：键表缺它时产物映射是死代码，
	# 依赖 $scene 引用的后续步骤会卡在 needs_input。
	var plan: Dictionary = _compile("Create player movement", ["gameplay_feature"])["plan"]
	var save_task: Dictionary = _task_for_tool(plan, "save_scene")
	assert_false(save_task.is_empty(), "gameplay profile saves the scene")
	_engine.record_step_result(plan, String(save_task.get("id", "")), {
		"status": "saved", "saved_path": "res://scenes/gameplay-feature.tscn"})
	var artifacts: Dictionary = ((plan.get("workflow", {}) as Dictionary).get("artifacts", {}) as Dictionary)
	assert_eq(String(artifacts.get("scene", "")), "res://scenes/gameplay-feature.tscn",
		"save_scene result registers the scene artifact via saved_path")

func test_numeric_step_arguments_survive_json_round_trip() -> void:
	# JSON 往返把整型键码 4194322 变成 4194322.0：蓝图若不规范化数字，
	# 含数字参数的持久化计划在重启校验时会被误判为被篡改。
	var plan: Dictionary = _compile("Create player movement", ["gameplay_feature"])["plan"]
	var persisted: Dictionary = JSON.parse_string(JSON.stringify(plan))
	assert_false(persisted.is_empty(), "plan serializes to JSON")
	var integrity: Dictionary = _engine.validate_integrity(persisted, _available)
	assert_false(integrity.has("error"),
		"round-tripped plan still matches its blueprint (got: %s)" % str(integrity.get("error", "")))

func test_animation_state_gate_requires_playing_animation() -> void:
	# is_playing=false / current_animation 为空时门禁必须判失败：
	# 否则 play_runtime_animation 失败了门禁照样通过（重言式）。
	assert_false(_engine.result_passed("get_runtime_animation_state",
		{"status": "success", "is_playing": false, "current_animation": ""}),
		"idle animation state must fail the gate")
	assert_false(_engine.result_passed("get_runtime_animation_state",
		{"status": "success", "is_playing": false, "current_animation": "idle"}),
		"not-playing state must fail the gate")
	assert_true(_engine.result_passed("get_runtime_animation_state",
		{"status": "success", "is_playing": true, "current_animation": "idle"}),
		"genuinely playing animation passes")

func test_inspect_gltf_gate_requires_meshes() -> void:
	# 零网格的 gltf（生成失败/空壳）处理器仍回 success——泛化规则会放行；
	# 目标是"3d 模型"的门禁必须要求真的有网格。
	assert_false(_engine.result_passed("inspect_gltf_asset",
		{"status": "success", "mesh_count": 0, "warnings": ["no meshes"]}),
		"zero-mesh asset fails the gate")
	assert_true(_engine.result_passed("inspect_gltf_asset",
		{"status": "success", "mesh_count": 3, "warnings": []}),
		"mesh-bearing asset passes")

func test_generated_model_registers_artifact() -> void:
	# generate_3d_asset 的 resource_path 记为 model 工件，inspect_gltf_asset
	# 的必填 path 才能从工件推导（此前该链永远卡在 needs_input）。
	# generate_3d_asset 以显式能力进入计划（调用方 step_inputs 提供密钥参数），
	# 其 resource_path 结果注册为 model 工件。
	var plan: Dictionary = _compile("Import a gltf 3d model", ["asset_pipeline"],
		{"required_capabilities": ["generate_3d_asset"]})["plan"]
	var generate_task: Dictionary = _task_for_tool(plan, "generate_3d_asset")
	assert_false(generate_task.is_empty(), "explicit capability schedules generate_3d_asset")
	var inspect_task: Dictionary = _task_for_tool(plan, "inspect_gltf_asset")
	assert_false(inspect_task.is_empty(), "gltf goal schedules the inspect gate")
	var verdict: Dictionary = _engine.record_step_result(plan, String(generate_task.get("id", "")), {
		"status": "success", "resource_path": "res://models/hero.glb"})
	assert_false(verdict.has("error"), str(verdict.get("error", "")))
	var artifacts: Dictionary = ((plan.get("workflow", {}) as Dictionary).get("artifacts", {}) as Dictionary)
	assert_eq(String(artifacts.get("model", "")), "res://models/hero.glb",
		"generate_3d_asset result registers the model artifact via resource_path")

func test_unsupported_status_is_negative_evidence() -> void:
	# 工具回 "unsupported" = 无法执行被要求的操作：既不能过门禁，
	# 也不能当非门禁步骤的可用证据（此前两者都放行）。
	assert_false(_engine.result_passed("update_node_property", {"status": "unsupported"}),
		"unsupported never passes a gate")
	assert_false(_engine._non_gate_result_usable({"status": "unsupported"}),
		"unsupported is not usable non-gate evidence")

func test_stale_probe_fallback_never_passes_gates() -> void:
	# 探针超时回退把缓存载荷包成 status=success + stale/from_cache：
	# 这是"上次观测"，门禁据此通过即假 completed（游戏已崩/动画已停）。
	var stale_payload: Dictionary = {
		"status": "success", "from_cache": true, "stale": true,
		"is_playing": true, "current_animation": "idle"}
	assert_false(_engine.result_passed("get_runtime_animation_state", stale_payload),
		"stale cached animation state must fail the gate")
	assert_false(_engine.result_passed("play_and_verify", stale_payload.duplicate(true)),
		"stale payloads fail any gate")

func test_verify_scripts_truncation_fails_gate() -> void:
	# 超过 max_scripts 的脚本没被检查：截断的验证不能当通过。
	assert_false(_engine.result_passed("verify_scripts",
		{"total_checked": 100, "verified": 100, "failed": 0, "truncated": true}),
		"a truncated verification is not a passing verification")
	assert_true(_engine.result_passed("verify_scripts",
		{"total_checked": 100, "verified": 100, "failed": 0, "truncated": false}),
		"a complete verification still passes")

func test_modify_script_with_compile_errors_is_not_a_passing_repair() -> void:
	assert_false(_engine.result_passed("modify_script",
		{"status": "success", "validation": {"error_count": 2, "errors": []}}),
		"a repair that leaves the script uncompiling must not pass")
	assert_true(_engine.result_passed("modify_script",
		{"status": "success", "validation": {"error_count": 0}}),
		"a clean repair passes")

func test_expect_fail_rejects_infrastructure_errors() -> void:
	# 探测器基础设施故障（非空 error）不得翻转成"探测器按预期失败"。
	var plan: Dictionary = _compile("Run project tests", ["quality_assurance"],
		{"expect_fail": {"qa_2_tests": true}})["plan"]
	var gate_task: Dictionary = {}
	for task_value in plan.get("tasks", []):
		var task: Dictionary = task_value
		if String(task.get("step_key", "")) == "qa_2_tests":
			gate_task = task
			break
	assert_eq(String(gate_task.get("expect", "pass")), "fail",
		"expect_fail marks the gate")
	var verdict: Dictionary = _engine.record_step_result(plan, String(gate_task.get("id", "")),
		{"error": "Debugger bridge is not available"})
	assert_ne(String(verdict.get("status", "")), "completed",
		"infrastructure errors are not inverted into detector proof")
