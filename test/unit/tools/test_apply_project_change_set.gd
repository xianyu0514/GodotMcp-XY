extends "res://addons/gut/test.gd"

const TEMP_PATH := "res://test/unit/.tmp_change_set_test.txt"
const SETTING_KEY := "godot_mcp/tests/change_set_value"

class FakeNodeTools:
	extends RefCounted
	var fail_apply: bool = false
	var apply_calls: int = 0

	func _tool_batch_update_node_properties(params: Dictionary) -> Dictionary:
		if bool(params.get("dry_run", false)):
			return {"status": "preview", "change_count": params.get("changes", []).size()}
		apply_calls += 1
		if fail_apply:
			return {"error": "simulated node failure"}
		return {"status": "success", "change_count": params.get("changes", []).size(), "changes": []}

var tools: ProjectWorkflowTools

func before_each() -> void:
	tools = ProjectWorkflowTools.new()
	_cleanup_state()

func after_each() -> void:
	_cleanup_state()
	tools = null

func _cleanup_state() -> void:
	if FileAccess.file_exists(TEMP_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(TEMP_PATH))
	if ProjectSettings.has_setting(SETTING_KEY):
		ProjectSettings.clear(SETTING_KEY)
	if ProjectSettings.has_setting(SETTING_KEY + "/other"):
		ProjectSettings.clear(SETTING_KEY + "/other")

func test_rejects_empty_change_set() -> void:
	var result: Dictionary = await tools._tool_apply_project_change_set({"changes": []})
	assert_has(result, "error")

func test_rejects_unknown_change_type_before_writing() -> void:
	var result: Dictionary = await tools._tool_apply_project_change_set({
		"changes": [{"type": "launch_missiles"}]
	})
	assert_has(result, "error")
	assert_false(FileAccess.file_exists(TEMP_PATH))

func test_dry_run_returns_revision_without_mutation() -> void:
	var result: Dictionary = await tools._tool_apply_project_change_set({
		"dry_run": true,
		"changes": [{"type": "file_write", "path": TEMP_PATH, "content": "preview"}]
	})
	assert_eq(result.get("status"), "preview")
	assert_false(str(result.get("revision", "")).is_empty())
	assert_eq(result.get("change_count"), 1)
	assert_false(FileAccess.file_exists(TEMP_PATH))

func test_expected_revision_conflict_writes_nothing() -> void:
	var result: Dictionary = await tools._tool_apply_project_change_set({
		"expected_revision": "stale",
		"changes": [{"type": "file_write", "path": TEMP_PATH, "content": "blocked"}]
	})
	assert_eq(result.get("stage"), "conflict")
	assert_false(FileAccess.file_exists(TEMP_PATH))

func test_duplicate_target_is_rejected_during_preflight() -> void:
	var result: Dictionary = await tools._tool_apply_project_change_set({
		"changes": [
			{"type": "file_write", "path": TEMP_PATH, "content": "one"},
			{"type": "file_write", "path": TEMP_PATH, "content": "two"}
		]
	})
	assert_eq(result.get("stage"), "preflight")
	assert_false(FileAccess.file_exists(TEMP_PATH))

func test_project_settings_reject_mixed_persistence_semantics() -> void:
	var result: Dictionary = await tools._tool_apply_project_change_set({
		"changes": [
			{"type": "project_setting", "setting": SETTING_KEY, "value": 1, "persist": false},
			{"type": "project_setting", "setting": SETTING_KEY + "/other", "value": 2, "persist": true}
		]
	})
	assert_eq(result.get("stage"), "preflight")
	assert_false(ProjectSettings.has_setting(SETTING_KEY))

func test_commits_file_and_project_setting_together() -> void:
	var preview: Dictionary = await tools._tool_apply_project_change_set({
		"dry_run": true,
		"changes": [
			{"type": "file_write", "path": TEMP_PATH, "content": "committed"},
			{"type": "project_setting", "setting": SETTING_KEY, "value": 42, "persist": false}
		]
	})
	var result: Dictionary = await tools._tool_apply_project_change_set({
		"expected_revision": preview.get("revision", ""),
		"changes": [
			{"type": "file_write", "path": TEMP_PATH, "content": "committed"},
			{"type": "project_setting", "setting": SETTING_KEY, "value": 42, "persist": false}
		]
	})
	assert_eq(result.get("status"), "success")
	assert_true(bool(result.get("verified", false)))
	assert_eq(FileAccess.get_file_as_string(TEMP_PATH), "committed")
	assert_eq(ProjectSettings.get_setting(SETTING_KEY), 42)

func test_late_failure_rolls_back_prior_file_write() -> void:
	var original := "before"
	var file := FileAccess.open(TEMP_PATH, FileAccess.WRITE)
	file.store_string(original)
	file.close()
	var fake_nodes := FakeNodeTools.new()
	fake_nodes.fail_apply = true
	tools._node_tools = fake_nodes
	var result: Dictionary = await tools._tool_apply_project_change_set({
		"changes": [
			{"type": "file_write", "path": TEMP_PATH, "content": "after"},
			{"type": "node_properties", "changes": [{"node_path": "/root/Main", "property_name": "name", "property_value": "Other"}]}
		]
	})
	assert_has(result, "error")
	assert_true(bool(result.get("rolled_back", false)))
	assert_eq(FileAccess.get_file_as_string(TEMP_PATH), original)
