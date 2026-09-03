extends "res://addons/gut/test.gd"

## 项目状态账本回归：读写回环、损坏容错、语义套件登记、有界历史。

const LedgerScript = preload("res://addons/godot_mcp/native_mcp/project_state_ledger.gd")

const TEMP_LEDGER: String = "user://.tmp_test_project_state_ledger.json"


func before_each() -> void:
	var absolute: String = ProjectSettings.globalize_path(TEMP_LEDGER)
	if FileAccess.file_exists(absolute):
		DirAccess.remove_absolute(absolute)


func _completed_plan() -> Dictionary:
	return {
		"goal": "arrow-key movement with coins and a score counter",
		"workflow": {
			"workflow_id": "wf_test_001",
			"artifacts": {
				"scene": "res://scenes/gameplay-feature.tscn",
				"script": "res://scripts/gameplay-feature-wf_003.gd",
			},
		},
		"tasks": [
			{"tool_name": "create_scene", "status": "done"},
			{"tool_name": "run_game_tests", "status": "done",
				"arguments": {"test_paths": ["res://tests/game/gameplay_semantic.gd"]}},
			{"tool_name": "assert_no_runtime_errors", "status": "done"},
		],
	}


func test_ledger_roundtrip_and_iteration_context():
	assert_true(LedgerScript.load_ledger(TEMP_LEDGER).get("goals", []) is Array,
		"Missing ledger loads an empty skeleton without error")
	var saved: Dictionary = LedgerScript.record_completed_goal(_completed_plan(), TEMP_LEDGER)
	assert_false(saved.has("error"), str(saved.get("error", "")))
	var ledger: Dictionary = LedgerScript.load_ledger(TEMP_LEDGER)
	var artifacts: Dictionary = ledger.get("artifacts", {})
	assert_eq(String(artifacts.get("scene", "")), "res://scenes/gameplay-feature.tscn",
		"Scene artifact persisted")
	assert_eq(String(artifacts.get("script", "")), "res://scripts/gameplay-feature-wf_003.gd",
		"Script artifact persisted")
	assert_eq(String(ledger.get("semantic_suite", "")),
		"res://tests/game/gameplay_semantic.gd",
		"Completed run_game_tests gate registers the semantic suite")
	var goals: Array = ledger.get("goals", [])
	assert_eq(goals.size(), 1, "Goal history appended")
	assert_eq(String((goals[0] as Dictionary).get("workflow_id", "")), "wf_test_001",
		"History keeps the workflow identity")
	var iteration: Dictionary = LedgerScript.gameplay_iteration_context(ledger)
	assert_eq(String(iteration.get("scene", "")), "res://scenes/gameplay-feature.tscn",
		"Iteration context exposes the scene")
	assert_eq(String(iteration.get("semantic_suite", "")),
		"res://tests/game/gameplay_semantic.gd",
		"Iteration context exposes the regression suite")


func test_ledger_tolerates_corruption():
	var absolute: String = ProjectSettings.globalize_path(TEMP_LEDGER)
	var file: FileAccess = FileAccess.open(absolute, FileAccess.WRITE)
	file.store_string("{ this is not json")
	file.close()
	var ledger: Dictionary = LedgerScript.load_ledger(TEMP_LEDGER)
	assert_true(ledger.get("artifacts", {}) is Dictionary,
		"Corrupted ledger degrades to an empty skeleton, never an error")
	assert_true(LedgerScript.gameplay_iteration_context(ledger).is_empty(),
		"Corrupted ledger yields no iteration context")


func test_ledger_history_is_bounded():
	var absolute: String = ProjectSettings.globalize_path(TEMP_LEDGER)
	var plan: Dictionary = _completed_plan()
	for index in 55:
		(plan["workflow"] as Dictionary)["workflow_id"] = "wf_%03d" % index
		LedgerScript.record_completed_goal(plan, TEMP_LEDGER)
	var ledger: Dictionary = LedgerScript.load_ledger(TEMP_LEDGER)
	var goals: Array = ledger.get("goals", [])
	assert_eq(goals.size(), LedgerScript.MAX_GOAL_HISTORY,
		"History is capped instead of growing without bound")
	assert_eq(String((goals[goals.size() - 1] as Dictionary).get("workflow_id", "")),
		"wf_054", "The newest entries are kept")


func test_partial_artifacts_do_not_form_iteration_context():
	var ledger: Dictionary = {
		"artifacts": {"script": "res://scripts/only.gd"},
		"goals": [],
		"semantic_suite": "",
	}
	assert_true(LedgerScript.gameplay_iteration_context(ledger).is_empty(),
		"Scene+script are both required before iterating")
