extends "res://addons/gut/test.gd"

# Unit tests for smoke_test_export (ship-loop gate ⑦). Covers the pure verdict
# function _evaluate_smoke_result and the offline guard paths of the tool
# (missing artifact resolution, run_export without a preset). The real
# export/launch flow needs a configured preset + export templates and is not
# exercised here.

var _tools: RefCounted = null

func before_each() -> void:
	_tools = load("res://addons/godot_mcp/tools/editor_tools_native.gd").new()

func after_each() -> void:
	_tools = null

# --- _evaluate_smoke_result (pure) ----------------------------------------

func test_pass_when_exists_and_exit_matches():
	var v: Dictionary = _tools._evaluate_smoke_result(true, true, 0, 0)
	assert_true(bool(v["success"]), "exists + exit 0 == expected 0 -> pass")
	assert_eq((v["reasons"] as Array).size(), 0, "no reasons on pass")

func test_fail_when_artifact_missing():
	var v: Dictionary = _tools._evaluate_smoke_result(false, false, -1, 0)
	assert_false(bool(v["success"]), "missing artifact -> fail")
	assert_true((v["reasons"] as Array).size() >= 1, "reason recorded for missing artifact")

func test_fail_when_exit_code_mismatch():
	var v: Dictionary = _tools._evaluate_smoke_result(true, true, 1, 0)
	assert_false(bool(v["success"]), "exit 1 != expected 0 -> fail")

func test_exit_code_ignored_when_not_launched():
	var v: Dictionary = _tools._evaluate_smoke_result(true, false, -1, 0)
	assert_true(bool(v["success"]), "no launch -> exit code not checked")

func test_custom_expected_exit_code():
	var v: Dictionary = _tools._evaluate_smoke_result(true, true, 42, 42)
	assert_true(bool(v["success"]), "matching custom expected exit code -> pass")

# --- tool guard paths -----------------------------------------------------

func test_run_export_without_preset_errors():
	var r: Dictionary = _tools._tool_smoke_test_export({"run_export": true})
	assert_true(r.has("error"), "run_export without preset errors")

func test_no_artifact_and_no_preset_errors():
	var r: Dictionary = _tools._tool_smoke_test_export({"launch": false})
	assert_true(r.has("error"), "no artifact_path and no preset -> error")

func test_missing_artifact_reports_not_exists():
	var r: Dictionary = _tools._tool_smoke_test_export({
		"artifact_path": "/tmp/__definitely_missing_godot_smoke_artifact__.bin",
		"launch": false
	})
	assert_false(bool(r.get("success", true)), "missing artifact -> not success")
	assert_false(bool(r.get("artifact_exists", true)), "artifact_exists is false")
