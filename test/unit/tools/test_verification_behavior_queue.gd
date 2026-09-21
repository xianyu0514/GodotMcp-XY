extends "res://addons/gut/test.gd"

## F1 原生行为验收（单测层）：behavior_check 项的 create 校验、执行器注入、
## native_run 证据形状、strict 队列拒绝外部声明、非 strict 的外部回填标记
## external_claim。真实运行编排由集成测试（test_verification_behavior_flow.py）
## 覆盖——这里通过 _behavior_run_override 注入避免依赖编辑器/运行时。

const ToolsScript = preload("res://addons/godot_mcp/tools/verification_queue_tools.gd")

const TMP: String = "res://.tmp_vq_behavior"
const STORE: String = TMP + "/queues.json"
const WATCH: String = TMP + "/game.gd"

var _tools: RefCounted

func before_each() -> void:
	DirAccess.make_dir_recursive_absolute(TMP)
	_write(WATCH, "extends Node\nvar speed := 10\n")
	_tools = ToolsScript.new()
	_tools._store_path = STORE

func after_each() -> void:
	_tools = null
	_remove_tree(TMP)

func test_create_rejects_behavior_check_without_steps() -> void:
	var result: Dictionary = await _tools._tool_run_verification_queue({
		"command": "create", "goal": "dash keeps collision",
		"items": [{"kind": "behavior_check", "label": "no steps"}]})
	assert_has(result, "error")
	assert_true(str(result["error"]).contains("steps"), "error must name the missing steps")

func test_behavior_check_executes_and_records_native_evidence() -> void:
	_tools._behavior_run_override = func(detail: Dictionary) -> Dictionary:
		return {"passed": true, "evidence": {
			"evidence_level": "native_run",
			"scene_path": String(detail.get("scene_path", "")),
			"assertions_passed": 2, "assertions_total": 2}}
	var result: Dictionary = await _tools._tool_run_verification_queue({
		"command": "create", "goal": "dash keeps collision",
		"items": [{"kind": "behavior_check", "label": "movement suite",
			"detail": {"scene_path": "res://scenes/arena.tscn", "steps": [
				{"action": "move_right", "pressed": true, "wait_ms": 300}]}}],
		"watch_paths": [WATCH]})
	assert_false(result.has("error"), str(result))
	assert_eq(int(result["passed_count"]), 1, "injected native run passes")
	assert_eq(String(result["outcome"]), "completed")
	var items: Array = _stored_items(String(result["queue_id"]))
	assert_eq(items.size(), 1)
	var evidence: Dictionary = items[0].get("evidence", {})
	assert_eq(String(evidence.get("evidence_level", "")), "native_run",
		"native execution must be distinguishable from external claims")
	assert_eq(String(evidence.get("scene_path", "")), "res://scenes/arena.tscn")

func test_behavior_check_failure_fails_the_queue() -> void:
	_tools._behavior_run_override = func(_detail: Dictionary) -> Dictionary:
		return {"passed": false, "evidence": {
			"evidence_level": "native_run",
			"assertions": [{"description": "wall blocks", "passed": false, "actual": 999.0}]}}
	var result: Dictionary = await _tools._tool_run_verification_queue({
		"command": "create", "goal": "wall must block",
		"items": [{"kind": "behavior_check", "label": "wall",
			"detail": {"steps": [{"action": "move_right", "pressed": true}]}}]})
	assert_eq(int(result["failed_count"]), 1, "a failing native run fails the queue")
	assert_eq(String(result["outcome"]), "failed")

func test_strict_queue_rejects_external_verdicts() -> void:
	var result: Dictionary = await _tools._tool_run_verification_queue({
		"command": "create", "goal": "strict gate",
		"items": [{"kind": "external", "label": "claimed", "detail": {}}],
		"strict": true, "defer_first_slice": true})
	assert_false(result.has("error"), str(result))
	var item_id: String = String(result["items"][0]["id"])
	var recorded: Dictionary = await _tools._tool_run_verification_queue({
		"command": "record", "queue_id": String(result["queue_id"]),
		"item_id": item_id, "passed": true, "evidence": {"claim": "trust me"}})
	assert_has(recorded, "error", "strict queue must refuse external claims")
	assert_true(str(recorded["error"]).contains("strict"), "error must explain the strict rule")

func test_non_strict_external_record_marks_evidence_level() -> void:
	var result: Dictionary = await _tools._tool_run_verification_queue({
		"command": "create", "goal": "compat gate",
		"items": [{"kind": "external", "label": "claimed", "detail": {}}],
		"defer_first_slice": true})
	var item_id: String = String(result["items"][0]["id"])
	var recorded: Dictionary = await _tools._tool_run_verification_queue({
		"command": "record", "queue_id": String(result["queue_id"]),
		"item_id": item_id, "passed": true, "evidence": {"claim": "ok"}})
	assert_false(recorded.has("error"), str(recorded))
	assert_eq(String(recorded["outcome"]), "completed", "non-strict keeps legacy completion")
	var stored: Array = _stored_items(String(result["queue_id"]))
	var evidence: Dictionary = stored[0].get("evidence", {})
	assert_eq(String(evidence.get("evidence_level", "")), "external_claim",
		"external verdicts must be visibly distinguishable from native runs")

func _write(path: String, content: String) -> void:
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	file.store_string(content)
	file.close()

func _remove_tree(path: String) -> void:
	for sub_name: String in DirAccess.get_directories_at(path):
		if sub_name == "." or sub_name == "..":
			continue
		_remove_tree(path.path_join(sub_name))
	for file_name: String in DirAccess.get_files_at(path):
		DirAccess.remove_absolute(path.path_join(file_name))
	DirAccess.remove_absolute(path)

func _stored_items(queue_id: String) -> Array:
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(STORE))
	if not (parsed is Dictionary):
		return []
	var queues: Variant = (parsed as Dictionary).get("queues", [])
	if not (queues is Array):
		return []
	for queue_value in queues:
		if not (queue_value is Dictionary):
			continue
		if String((queue_value as Dictionary).get("queue_id", "")) == queue_id:
			var items: Variant = (queue_value as Dictionary).get("items", [])
			return items if items is Array else []
	return []

func test_queue_summary_carries_evidence_summary() -> void:
	_tools._behavior_run_override = func(_detail: Dictionary) -> Dictionary:
		return {"passed": false, "evidence": {
			"evidence_level": "native_run",
			"assertions_passed": 1, "assertions_total": 2,
			"assertions": [
				{"description": "ok one", "passed": true},
				{"description": "the failing one", "passed": false}],
			"steps_executed": 3}}
	var result: Dictionary = await _tools._tool_run_verification_queue({
		"command": "create", "goal": "summary evidence",
		"items": [{"kind": "behavior_check", "label": "sum",
			"detail": {"steps": [{"action": "x"}]}}]})
	assert_eq(String(result["items"][0].get("evidence_level", "")), "native_run",
		"summary items expose the evidence level inline")
	assert_eq(int(result["items"][0].get("assertions_passed", -1)), 1)
	assert_eq(int(result["items"][0].get("assertions_total", -1)), 2)
	assert_eq(String(result["items"][0].get("first_failure", "")), "the failing one",
		"first failure description travels with the response")

func test_strict_queue_rejects_assertionless_behavior_check() -> void:
	# 包②：零断言的 behavior_check 是冒烟结果，不能进严格队列充当完成证据。
	var result: Dictionary = await _tools._tool_run_verification_queue({
		"command": "create", "goal": "smoke cannot pass strict",
		"strict": True,
		"items": [{"kind": "behavior_check", "label": "no assertions",
			"detail": {"steps": [{"action": "move_right", "pressed": True}]}}]})
	assert_has(result, "error", "strict create must refuse assertion-less items")
	assert_true(str(result["error"]).contains("no assertions"),
		"error must name the smoke-vs-strict rule")

func test_item_summaries_carry_verification_labels() -> void:
	_tools._behavior_run_override = func(_detail: Dictionary) -> Dictionary:
		return {"passed": True, "evidence": {
			"evidence_level": "native_run",
			"assertions_passed": 2, "assertions_total": 2,
			"assertions": [{"description": "a", "passed": true},
				{"description": "b", "passed": true}]}}
	var result: Dictionary = await _tools._tool_run_verification_queue({
		"command": "create", "goal": "labels",
		"items": [{"kind": "behavior_check", "label": "l",
			"detail": {"steps": [{"wait_ms": 50,
				"assert": {"expression": "1", "expected": 1}}]}}]})
	assert_eq(String(result["items"][0].get("verification", "")), "verified",
		"native run with assertions labels as verified")
