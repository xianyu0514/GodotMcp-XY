extends "res://addons/gut/test.gd"

## M3 slice 2 测试：观察式单文件写入记录（场景/资源保存）、create/modify
## 分类语义、恢复处方桥（pending 分类 + 最近提交记录磁盘复判）。

const ChangeJournal = preload("res://addons/godot_mcp/tools/change_journal.gd")
const WorkflowTools = preload("res://addons/godot_mcp/tools/game_workflow_tools.gd")
const ResourceTools = preload("res://addons/godot_mcp/tools/project_resources_tools.gd")

const TEMP_DIR: String = "res://.tmp_journal_writes"
const TOOL_JOURNAL: String = "res://.mcp/change_journal.json"

func before_each() -> void:
	DirAccess.make_dir_recursive_absolute(TEMP_DIR)
	_reset_journal()

func after_each() -> void:
	_reset_journal()
	for file_name: String in DirAccess.get_files_at(TEMP_DIR):
		DirAccess.remove_absolute(TEMP_DIR.path_join(file_name))
	DirAccess.remove_absolute(TEMP_DIR)

func _reset_journal() -> void:
	if FileAccess.file_exists(TOOL_JOURNAL):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(TOOL_JOURNAL))

func _write(path: String, content: String) -> void:
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	file.store_string(content)
	file.close()

# ============================================================================
# record_write_operation + kind 感知分类
# ============================================================================

func test_record_write_operation_committed_modify_matches_disk() -> void:
	var path: String = TEMP_DIR + "/scene.tscn"
	_write(path, "v1")
	var before: String = "v1".sha256_text()
	_write(path, "v2")
	var result: Dictionary = ChangeJournal.record_write_operation(
		"save_scene " + path, path, before, "v2".sha256_text(), true)
	assert_false(result.has("error"), str(result.get("error", "")))
	assert_eq(String(result["operation"]["phase"]), "committed")

	var latest: Dictionary = ChangeJournal.latest_operation_by_tool("save_scene")
	assert_eq(String(latest.get("intent", "")), "save_scene " + path)
	var verdict: Dictionary = ChangeJournal.classify_operation(latest)
	assert_eq(String(verdict["action"]), "complete_receipt",
		"disk matches the recorded after-hash — the write demonstrably happened")

func test_create_kind_missing_file_is_untouched_not_conflict() -> void:
	var path: String = TEMP_DIR + "/new.tres"
	_write(path, "content")
	ChangeJournal.record_write_operation("create_resource " + path, path,
		"", "content".sha256_text(), true)
	assert_eq(String(ChangeJournal.classify_operation(
		ChangeJournal.latest_operation_by_tool("create_resource"))["action"]),
		"complete_receipt")
	# 文件被外部删除：create 类 = 未发生（re_prepare），不是冲突
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	assert_eq(String(ChangeJournal.classify_operation(
		ChangeJournal.latest_operation_by_tool("create_resource"))["action"]),
		"re_prepare", "create-kind: deleted target means it never happened")

func test_modify_kind_missing_file_still_conflicts() -> void:
	var path: String = TEMP_DIR + "/scene.tscn"
	_write(path, "v1")
	_write(path, "v2")
	ChangeJournal.record_write_operation("save_scene " + path, path,
		"v1".sha256_text(), "v2".sha256_text(), true)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	assert_eq(String(ChangeJournal.classify_operation(
		ChangeJournal.latest_operation_by_tool("save_scene"))["action"]),
		"conflict", "modify-kind: deleted original is a conflict")

func test_pending_operations_lists_only_unfinished() -> void:
	var path: String = TEMP_DIR + "/scene.tscn"
	_write(path, "v1")
	_write(path, "v2")
	ChangeJournal.record_write_operation("save_scene " + path, path,
		"v1".sha256_text(), "v2".sha256_text(), true)
	assert_eq(ChangeJournal.pending_operations().size(), 0,
		"committed operations are not pending")
	ChangeJournal.begin_operation("interrupted rename", [
		{"path": path, "before_hash": "x", "after_hash": "y", "replacement_count": 1},
	])
	assert_eq(ChangeJournal.pending_operations().size(), 1)

# ============================================================================
# 资源工具接线
# ============================================================================

func test_create_resource_records_journal_entry() -> void:
	var tools: RefCounted = ResourceTools.new()
	var path: String = TEMP_DIR + "/grad.tres"
	var result: Dictionary = tools._tool_create_resource({
		"resource_path": path,
		"resource_type": "Gradient",
		"properties": {},
	})
	assert_false(result.has("error"), str(result.get("error", "")))
	var latest: Dictionary = ChangeJournal.latest_operation_by_tool("create_resource")
	assert_eq(String(latest.get("intent", "")), "create_resource " + path)
	assert_eq(String(latest.get("phase", "")), "committed")
	assert_eq(String(ChangeJournal.classify_operation(latest)["action"]), "complete_receipt")

func test_update_resource_properties_records_journal_entry() -> void:
	var tools: RefCounted = ResourceTools.new()
	var path: String = TEMP_DIR + "/curve.tres"
	assert_false(tools._tool_create_resource({
		"resource_path": path, "resource_type": "Curve", "properties": {},
	}).has("error"))
	var updated: Dictionary = tools._tool_update_resource_properties({
		"resource_path": path,
		"properties": {"min_value": 0.25},
	})
	assert_false(updated.has("error"), str(updated.get("error", "")))
	var latest: Dictionary = ChangeJournal.latest_operation_by_tool("update_resource_properties")
	assert_eq(String(latest.get("intent", "")), "update_resource_properties " + path)
	assert_eq(String(ChangeJournal.classify_operation(latest)["action"]), "complete_receipt")

# ============================================================================
# 恢复处方桥
# ============================================================================

func test_recovery_bridge_empty_journal_returns_empty() -> void:
	var bridge: Dictionary = WorkflowTools.new()._change_journal_recovery("save_scene")
	assert_true(bridge.is_empty(), "no journal knowledge → no prescription")

func test_recovery_bridge_committed_match_says_no_replay_needed() -> void:
	var path: String = TEMP_DIR + "/scene.tscn"
	_write(path, "v1")
	_write(path, "v2")
	ChangeJournal.record_write_operation("save_scene " + path, path,
		"v1".sha256_text(), "v2".sha256_text(), true)
	var bridge: Dictionary = WorkflowTools.new()._change_journal_recovery("save_scene")
	assert_eq(String(bridge.get("latest_committed", {}).get("verdict", "")), "complete_receipt")
	assert_true(String(bridge.get("recommended", "")).contains("no replay needed"),
		str(bridge.get("recommended", "")))

func test_recovery_bridge_pending_conflict_recommends_resolution() -> void:
	var path: String = TEMP_DIR + "/scene.tscn"
	_write(path, "manual edit")
	ChangeJournal.begin_operation("interrupted rename", [
		{"path": path, "before_hash": "old".sha256_text(),
		 "after_hash": "new".sha256_text(), "replacement_count": 1},
	])
	var bridge: Dictionary = WorkflowTools.new()._change_journal_recovery("rename_script_symbol")
	assert_gt((bridge.get("pending", []) as Array).size(), 0)
	assert_eq(String((bridge["pending"][0] as Dictionary).get("action", "")), "conflict")
	assert_true(String(bridge.get("recommended", "")).contains("conflicts"),
		str(bridge.get("recommended", "")))

# ============================================================================
# journal 自动收口（R3：回执丢失后按磁盘证据补回执）
# ============================================================================

func test_autoclose_closes_uncertain_step_on_committed_disk_match() -> void:
	var path: String = TEMP_DIR + "/scene.tscn"
	_write(path, "v1")
	_write(path, "v2")
	ChangeJournal.record_write_operation("save_scene " + path, path,
		"v1".sha256_text(), "v2".sha256_text(), true)
	var tools: RefCounted = WorkflowTools.new()
	var task: Dictionary = {"id": "wf_010", "tool_name": "save_scene", "status": "in_progress"}
	var receipt: Dictionary = tools._journal_autoclose({}, task)
	assert_false(receipt.is_empty(), "committed disk match closes the step")
	assert_eq(String(task.get("status", "")), "done")
	assert_true(bool(task.get("journal_autoclosed", false)))
	assert_true(str(receipt.get("summary", {}).get("recovered_by", "")) == "change_journal")

func test_autoclose_refuses_without_evidence_or_on_conflict() -> void:
	var tools: RefCounted = WorkflowTools.new()
	# 无 journal 记录 → 不收口（维持 fail-closed）
	assert_true(tools._journal_autoclose({}, {"id": "wf_1", "tool_name": "create_theme"}).is_empty())
	# 磁盘与记录分歧（手工修改）→ 不收口
	var path: String = TEMP_DIR + "/scene2.tscn"
	_write(path, "v1")
	_write(path, "v2")
	ChangeJournal.record_write_operation("save_scene " + path, path,
		"v1".sha256_text(), "v2".sha256_text(), true)
	_write(path, "hand-edited")
	assert_true(tools._journal_autoclose({}, {"id": "wf_2", "tool_name": "save_scene"}).is_empty())
	# pending 冲突存在 → 不收口
	ChangeJournal.begin_operation("interrupted rename", [
		{"path": path, "before_hash": "x", "after_hash": "y", "replacement_count": 1},
	])
	assert_true(tools._journal_autoclose({}, {"id": "wf_3", "tool_name": "save_scene"}).is_empty())
