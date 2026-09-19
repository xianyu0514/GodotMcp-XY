@tool
class_name VerificationQueueTools
extends RefCounted

# run_verification_queue（M5 第三交付工具层）：把持久化分片验证队列暴露
# 为 MCP 工具。队列是编排枢纽——分片、证据指纹与完成判定统一在这里，
# 执行体可插拔：
# - kind="script_check"：内置执行器，逐文件 GDScript 编译检查（口径与
#   detect_broken_scripts 一致：reload() 错误码）。
# - kind="external"：不在本工具内执行——play_and_verify、GUT 等外部执行
#   器跑完后用 command="record" 回填单项判定；回填同样走指纹与完成契约。
#
# 诚实契约（审计 #3 验收）：
# - completed 只在 pending==0 且 failed==0 时出现；
# - advance 超预算的项留在队列（has_more/pending_count 如实报告）；
# - inspect/advance 前先 refresh_stale：被观察文件漂移后，旧证据打回
#   pending 重验，绝不把陈旧证据当有效覆盖。

const StoreScript = preload("res://addons/godot_mcp/tools/verification_queue_store.gd")

var _editor_interface: EditorInterface = null
## 存储位置。生产固定默认（res://.mcp/verification_queues.json）；
## 测试注入临时路径。
var _store_path: String = ""

func initialize(editor_interface: EditorInterface) -> void:
	_editor_interface = editor_interface

func register_tools(server_core: RefCounted) -> void:
	_register_run_verification_queue(server_core)

# ============================================================================
# run_verification_queue
# ============================================================================

func _register_run_verification_queue(server_core: RefCounted) -> void:
	var tool_name: String = "run_verification_queue"
	var description: String = "Create, advance, inspect, record into, or abandon a persistent sliced verification queue. The queue keeps required checks as durable items: each advance consumes at most `budget` pending items (the rest are retained, never dropped), evidence is fingerprinted against watch_paths (file drift pushes stale verdicts back to pending), and `completed` only appears when every item passed. kind=script_check items run the built-in GDScript compile check; kind=external items are executed out-of-band (play_and_verify, GUT...) and their verdicts are recorded back with command=record. Restart-safe: queues persist across editor restarts and resume from remaining items."

	var input_schema: Dictionary = {
		"type": "object",
		"properties": {
			"command": {
				"type": "string",
				"enum": ["create", "advance", "inspect", "record", "abandon"],
				"description": "create: new queue (+first slice); advance: run the next budget slice; inspect: statuses without running; record: backfill one external item's verdict; abandon: terminal-abandon an open queue."
			},
			"goal": {
				"type": "string",
				"description": "create only: what this verification queue covers (recorded for recovery)."
			},
			"items": {
				"type": "array",
				"items": {"type": "object"},
				"description": "create only: [{id?, kind: 'script_check'|'external', label, detail}]. script_check detail: {scripts: [res://...]}; external detail is free-form context for the out-of-band runner."
			},
			"watch_paths": {
				"type": "array",
				"items": {"type": "string"},
				"description": "create only: files whose content fingerprints guard the evidence — any drift invalidates recorded verdicts back to pending."
			},
			"budget": {
				"type": "integer",
				"description": "Maximum pending items to run per create/advance slice. Default 4.",
				"default": 4
			},
			"queue_id": {
				"type": "string",
				"description": "advance/inspect/record/abandon: target queue id."
			},
			"item_id": {
				"type": "string",
				"description": "record only: the item receiving the verdict."
			},
			"passed": {
				"type": "boolean",
				"description": "record only: the external runner's verdict."
			},
			"evidence": {
				"type": "object",
				"description": "record only: evidence payload from the external runner (assertions, logs...)."
			}
		},
		"required": ["command"]
	}

	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"queue_id": {"type": "string"},
			"command": {"type": "string"},
			"outcome": {"type": "string", "description": "completed|failed|pending_more|open|abandoned"},
			"processed": {"type": "integer"},
			"passed_count": {"type": "integer"},
			"failed_count": {"type": "integer"},
			"pending_count": {"type": "integer"},
			"has_more": {"type": "boolean"},
			"stale_refreshed": {"type": "integer"},
			"items": {"type": "array"}
		}
	}

	var annotations: Dictionary = {
		"readOnlyHint": false,
		"destructiveHint": false,
		"idempotentHint": true,
		"openWorldHint": false
	}

	server_core.register_tool(tool_name, description, input_schema,
		Callable(self, "_tool_run_verification_queue"),
		output_schema, annotations,
		"supplementary", "Project-Advanced")

func _tool_run_verification_queue(params: Dictionary) -> Dictionary:
	var command: String = str(params.get("command", "")).strip_edges()
	match command:
		"create":
			return await _command_create(params)
		"advance":
			return await _command_advance(params)
		"inspect":
			return _command_inspect(params)
		"record":
			return _command_record(params)
		"abandon":
			return _command_abandon(params)
	return {"error": "Unknown command: " + command}

func _command_create(params: Dictionary) -> Dictionary:
	var goal: String = str(params.get("goal", "")).strip_edges()
	if goal.is_empty():
		return {"error": "create requires a non-empty goal"}
	var items: Variant = params.get("items", [])
	if not (items is Array) or (items as Array).is_empty():
		return {"error": "create requires a non-empty items array"}
	for item_value in items:
		if not (item_value is Dictionary):
			return {"error": "each queue item must be an object"}
		var kind: String = str((item_value as Dictionary).get("kind", ""))
		if kind != "script_check" and kind != "external":
			return {"error": "queue item kind must be 'script_check' or 'external' (got '%s')" % kind}

	var store: Dictionary = StoreScript.load_store(_resolved_store_path())
	if store.has("error"):
		return store
	var created: Dictionary = StoreScript.create_queue(goal, items,
		params.get("watch_paths", []), store)
	if created.has("error"):
		return created
	var queue: Dictionary = created["queue"]
	var save_result: Dictionary = StoreScript.save_store(store, _resolved_store_path())
	if save_result.has("error"):
		return save_result

	var response: Dictionary = _queue_summary(queue, "open")
	response["command"] = "create"
	if not bool(params.get("defer_first_slice", false)):
		var advanced: Dictionary = await _advance_and_save(store, queue, int(params.get("budget", 4)))
		for key in advanced:
			response[key] = advanced[key]
	return response

func _command_advance(params: Dictionary) -> Dictionary:
	var queue_ref: Dictionary = _open_queue_or_error(params)
	if queue_ref.has("error"):
		return queue_ref
	var store: Dictionary = queue_ref["store"]
	var queue: Dictionary = queue_ref["queue"]
	var advanced: Dictionary = await _advance_and_save(store, queue, int(params.get("budget", 4)))
	advanced["command"] = "advance"
	advanced["queue_id"] = String(queue.get("queue_id", ""))
	return advanced

func _command_inspect(params: Dictionary) -> Dictionary:
	var queue_ref: Dictionary = _queue_or_error(params)
	if queue_ref.has("error"):
		return queue_ref
	var store: Dictionary = queue_ref["store"]
	var queue: Dictionary = queue_ref["queue"]
	var staled: int = StoreScript.refresh_stale(queue)
	if staled > 0:
		var save_result: Dictionary = StoreScript.save_store(store, _resolved_store_path())
		if save_result.has("error"):
			return save_result
	var summary: Dictionary = _queue_summary(queue, String(queue.get("phase", "open")))
	summary["command"] = "inspect"
	summary["stale_refreshed"] = staled
	return summary

func _command_record(params: Dictionary) -> Dictionary:
	var queue_ref: Dictionary = _open_queue_or_error(params)
	if queue_ref.has("error"):
		return queue_ref
	var store: Dictionary = queue_ref["store"]
	var queue: Dictionary = queue_ref["queue"]
	var item_id: String = str(params.get("item_id", "")).strip_edges()
	if item_id.is_empty():
		return {"error": "record requires item_id"}
	var passed: bool = bool(params.get("passed", false))
	var evidence: Dictionary = params.get("evidence", {}) if params.get("evidence", {}) is Dictionary else {}

	var target: Dictionary = {}
	for item_value in queue.get("items", []):
		var item: Dictionary = item_value
		if String(item.get("id", "")) == item_id:
			target = item
			break
	if target.is_empty():
		return {"error": "queue '%s' has no item '%s'" % [String(queue.get("queue_id", "")), item_id]}
	if String(target.get("status", "")) != "pending":
		return {"error": "item '%s' already has a recorded verdict (%s); stale refresh or a new queue is required to change it" % [item_id, String(target.get("status", ""))]}
	target["status"] = "passed" if passed else "failed"
	target["evidence"] = evidence
	target["checked_at"] = StoreScript._now()

	# 回填后重算完成契约（与 advance 同一口径）。
	var pending_count: int = StoreScript._count_status(queue, "pending")
	var failed_count: int = StoreScript._count_status(queue, "failed")
	var outcome: String = String(queue.get("phase", "open"))
	if pending_count == 0 and failed_count == 0:
		outcome = "completed"
		queue["phase"] = "completed"
	elif failed_count > 0 and pending_count == 0:
		outcome = "failed"
		queue["phase"] = "failed"
	queue["updated_at"] = StoreScript._now()
	var save_result: Dictionary = StoreScript.save_store(store, _resolved_store_path())
	if save_result.has("error"):
		return save_result
	var summary: Dictionary = _queue_summary(queue, outcome)
	summary["command"] = "record"
	summary["stale_refreshed"] = 0
	return summary

func _command_abandon(params: Dictionary) -> Dictionary:
	var queue_ref: Dictionary = _open_queue_or_error(params)
	if queue_ref.has("error"):
		return queue_ref
	var store: Dictionary = queue_ref["store"]
	var queue: Dictionary = queue_ref["queue"]
	queue["phase"] = "abandoned"
	queue["updated_at"] = StoreScript._now()
	var save_result: Dictionary = StoreScript.save_store(store, _resolved_store_path())
	if save_result.has("error"):
		return save_result
	var summary: Dictionary = _queue_summary(queue, "abandoned")
	summary["command"] = "abandon"
	summary["stale_refreshed"] = 0
	return summary

# ============================================================================
# 内部：执行器 / 汇总
# ============================================================================

func _advance_and_save(store: Dictionary, queue: Dictionary, budget: int) -> Dictionary:
	var staled: int = StoreScript.refresh_stale(queue)
	var advanced: Dictionary = await StoreScript.advance(queue, maxi(0, budget),
		func(item: Dictionary) -> Dictionary: return _execute_item(item))
	var save_result: Dictionary = StoreScript.save_store(store, _resolved_store_path())
	if save_result.has("error"):
		return save_result
	advanced["stale_refreshed"] = staled
	return advanced

## 内置执行器：script_check 走 GDScript 编译检查；external 项 defer——
## 保持 pending、不消耗预算，等待外部执行器用 record 回填判定。
func _execute_item(item: Dictionary) -> Dictionary:
	var kind: String = String(item.get("kind", ""))
	var detail: Dictionary = item.get("detail", {}) if item.get("detail", {}) is Dictionary else {}
	if kind == "script_check":
		return _check_scripts(detail)
	return {"defer": true}

func _resolved_store_path() -> String:
	return _store_path if not _store_path.is_empty() else StoreScript.DEFAULT_STORE_PATH

func _check_scripts(detail: Dictionary) -> Dictionary:
	var scripts: Variant = detail.get("scripts", [])
	if not (scripts is Array) or (scripts as Array).is_empty():
		return {"passed": false, "evidence": {"issue": "script_check detail needs a non-empty scripts array"}}
	var checks: Array = []
	var all_passed: bool = true
	for script_value in scripts:
		var script_path: String = str(script_value)
		var check: Dictionary = _compile_check(script_path)
		checks.append(check)
		if not bool(check["passed"]):
			all_passed = false
	return {"passed": all_passed, "evidence": {"checks": checks}}

static func _compile_check(script_path: String) -> Dictionary:
	if not FileAccess.file_exists(script_path):
		return {"path": script_path, "passed": false, "issue": "file not found"}
	var file: FileAccess = FileAccess.open(script_path, FileAccess.READ)
	if file == null:
		return {"path": script_path, "passed": false, "issue": "could not open for reading"}
	var content: String = file.get_as_text()
	file.close()
	var test_script: GDScript = GDScript.new()
	test_script.source_code = content
	var reload_error: Error = test_script.reload()
	return {
		"path": script_path,
		"passed": reload_error == OK,
		"compile_error": "" if reload_error == OK else error_string(reload_error),
	}

func _queue_summary(queue: Dictionary, outcome: String) -> Dictionary:
	var items: Array = []
	for item_value in queue.get("items", []):
		var item: Dictionary = item_value
		items.append({
			"id": String(item.get("id", "")),
			"kind": String(item.get("kind", "")),
			"label": String(item.get("label", "")),
			"status": String(item.get("status", "")),
			"checked_at": String(item.get("checked_at", "")),
		})
	return {
		"queue_id": String(queue.get("queue_id", "")),
		"goal": String(queue.get("goal", "")),
		"outcome": outcome,
		"processed": 0,
		"passed_count": StoreScript._count_status(queue, "passed"),
		"failed_count": StoreScript._count_status(queue, "failed"),
		"pending_count": StoreScript._count_status(queue, "pending"),
		"has_more": StoreScript._count_status(queue, "pending") > 0,
		"items": items,
	}

func _queue_or_error(params: Dictionary) -> Dictionary:
	var queue_id: String = str(params.get("queue_id", "")).strip_edges()
	if queue_id.is_empty():
		return {"error": "queue_id is required for this command"}
	var store: Dictionary = StoreScript.load_store(_resolved_store_path())
	if store.has("error"):
		return store
	var queue: Dictionary = StoreScript.get_queue(store, queue_id)
	if queue.is_empty():
		return {"error": "verification queue '%s' not found" % queue_id}
	return {"store": store, "queue": queue}

func _open_queue_or_error(params: Dictionary) -> Dictionary:
	var queue_ref: Dictionary = _queue_or_error(params)
	if queue_ref.has("error"):
		return queue_ref
	var queue: Dictionary = queue_ref["queue"]
	if String(queue.get("phase", "")) in StoreScript.FINAL_PHASES:
		return {"error": "queue '%s' is in terminal phase '%s'" % [String(queue.get("queue_id", "")), String(queue.get("phase", ""))]}
	return queue_ref

