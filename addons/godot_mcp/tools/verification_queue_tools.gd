@tool
class_name VerificationQueueTools
extends RefCounted

# F1 原生行为验收：behavior_check 项由队列本身驱动运行会话（探针→运行→
# 输入/断言→停止），产出绑定本次运行证据的判定；strict 队列拒绝外部声明。
const DebugVerifyToolsScript = preload("res://addons/godot_mcp/tools/debug_verify_tools.gd")
const DebugRuntimeToolsScript = preload("res://addons/godot_mcp/tools/debug_runtime_tools.gd")
const DebugBridgeToolsScript = preload("res://addons/godot_mcp/tools/debug_bridge_tools.gd")
const EditorToolsScript = preload("res://addons/godot_mcp/tools/editor_tools_native.gd")

## 测试注入点：有效时替代 _behavior_run_impl（避免单测依赖真实编辑器/运行时）。
var _behavior_run_override: Callable = Callable()

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
	var description: String = "Manage persistent sliced verification queues (create/advance/inspect/record/abandon). Each advance runs at most `budget` pending items (the rest retained), evidence is fingerprinted against watch_paths (drift re-opens passed items), completed requires all items passed. script_check = built-in GDScript compile check; behavior_check items each boot a FRESH run of the scene (full isolation - do not assume state from a previous item carries over; an item that needs a dead enemy must kill it itself); detail may carry a 'timeline' ({events, sample, assertions}) replayed frame-accurately in ONE probe round trip with in-game final assertions; the queue drives the session (probe -> run_project -> input steps/assertions via play_and_verify -> stop) and records native_run evidence (scene, per-assertion actual/expected, runtime errors, screenshots, session id); external verdicts come back via command=record and are marked external_claim. strict=true queues reject externally recorded verdicts — native evidence only. Restart-safe."

	var input_schema: Dictionary = {
		"type": "object",
		"properties": {
			"command": {
				"type": "string",
				"enum": ["create", "advance", "inspect", "record", "abandon"],
				"description": "create: new queue (+first slice); advance: next budget slice; inspect: statuses only; record: backfill one external verdict; abandon: terminal."
			},
			"goal": {
				"type": "string",
				"description": "create only: what this verification queue covers (recorded for recovery)."
			},
			"items": {
				"type": "array",
				"items": {"type": "object"},
				"description": "create only: [{id?, kind: 'script_check'|'external'|'behavior_check', label, detail}]. script_check detail: {scripts: [...]}; behavior_check detail: {scene_path?, steps: [...], assertions?: [...], deterministic?, timeout_ms?} (steps/assertions use the play_and_verify shape); external detail is free-form."
			},
			"watch_paths": {
				"type": "array",
				"items": {"type": "string"},
				"description": "create only: files whose fingerprints guard evidence — drift re-opens verdicts."
			},
			"strict": {
				"type": "boolean", "default": false,
				"description": "create only: strict queues reject externally recorded verdicts (command=record errors) — completion requires native execution evidence (script_check/behavior_check)."
			},
			"requirements": {
				"type": "array", "items": {"type": "string"},
				"description": "create only: required requirement ids (the delivery contract). Responses carry a checklist mapping every requirement to verified/smoke/partial/failed/unverified/external_claim; ANY requirement lacking verified evidence makes the overall outcome incomplete."
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
				"description": "record only: evidence payload from the external runner."
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
		if kind != "script_check" and kind != "external" and kind != "behavior_check":
			return {"error": "queue item kind must be 'script_check', 'external' or 'behavior_check' (got '%s')" % kind}
		if kind == "behavior_check":
			var detail: Variant = (item_value as Dictionary).get("detail", {})
			var steps: Variant = (detail as Dictionary).get("steps", []) if detail is Dictionary else []
			var timeline: Variant = (detail as Dictionary).get("timeline", {}) if detail is Dictionary else {}
			var has_timeline: bool = timeline is Dictionary and not (timeline as Dictionary).is_empty() 				and (timeline as Dictionary).get("events", []) is Array 				and not ((timeline as Dictionary).get("events", []) as Array).is_empty()
			if (not (steps is Array) or (steps as Array).is_empty()) and not has_timeline:
				return {"error": "behavior_check detail requires a non-empty steps array OR a timeline {events, assertions} (one probe round trip); optional scene_path, assertions, deterministic, timeout_ms"}
			# 严格完成门禁（包②）：零断言的 behavior_check 只是冒烟结果，
			# 不能充当严格队列的功能完成证据——建队即拒绝并点名缺断言的项。
			if bool(params.get("strict", false)):
				var assertion_count: int = 0
				for step_value in (steps as Array):
					if step_value is Dictionary and (step_value as Dictionary).has("assert"):
						assertion_count += 1
				var finals: Variant = (detail as Dictionary).get("assertions", []) if detail is Dictionary else []
				if finals is Array:
					assertion_count += (finals as Array).size()
				if has_timeline and (timeline as Dictionary).get("assertions", []) is Array:
					assertion_count += ((timeline as Dictionary).get("assertions", []) as Array).size()
				if assertion_count == 0:
					return {"error": "strict queue: behavior_check '%s' carries no assertions — a smoke run cannot satisfy strict completion; add step asserts, a final assertions list, or timeline assertions" % str((item_value as Dictionary).get("label", item_value.get("id", "?")))}

	var store: Dictionary = StoreScript.load_store(_resolved_store_path())
	if store.has("error"):
		return store
	var created: Dictionary = StoreScript.create_queue(goal, items,
		params.get("watch_paths", []), store)
	if created.has("error"):
		return created
	var queue: Dictionary = created["queue"]
	queue["strict"] = bool(params.get("strict", false))
	var requirements: Variant = params.get("requirements", [])
	if requirements is Array and not (requirements as Array).is_empty():
		var contract: Array = []
		for requirement_value in requirements:
			var requirement_id: String = str(requirement_value).strip_edges()
			if not requirement_id.is_empty() and not requirement_id in contract:
				contract.append(requirement_id)
		queue["requirements"] = contract
	var save_result: Dictionary = StoreScript.save_store(store, _resolved_store_path())
	if save_result.has("error"):
		return save_result

	var response: Dictionary = _queue_summary(queue, "open")
	response["command"] = "create"
	if queue.has("requirements"):
		response["checklist"] = _requirement_checklist(queue)
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
	if queue.has("requirements"):
		summary["checklist"] = _requirement_checklist(queue)
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
	if bool(queue.get("strict", false)):
		return {"error": "queue '%s' is strict: externally recorded verdicts cannot replace native run evidence. Replace the external item with a behavior_check/script_check item, or create a non-strict queue." % String(queue.get("queue_id", ""))}
	target["status"] = "passed" if passed else "failed"
	evidence["evidence_level"] = "external_claim"
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
	_enforce_requirement_contract(queue)
	var summary: Dictionary = _queue_summary(queue, String(queue.get("phase", outcome)))
	summary["command"] = "record"
	if queue.has("requirements"):
		summary["checklist"] = _requirement_checklist(queue)
		summary["outcome"] = String(queue.get("phase", outcome))
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
		func(item: Dictionary) -> Dictionary: return await _execute_item(item))
	_enforce_requirement_contract(queue)
	var save_result: Dictionary = StoreScript.save_store(store, _resolved_store_path())
	if save_result.has("error"):
		return save_result
	advanced["stale_refreshed"] = staled
	if queue.has("requirements"):
		advanced["checklist"] = _requirement_checklist(queue)
		advanced["outcome"] = String(queue.get("phase", advanced.get("outcome", "")))
	return advanced

## 内置执行器：script_check 走 GDScript 编译检查；external 项 defer——
## 保持 pending、不消耗预算，等待外部执行器用 record 回填判定。
func _execute_item(item: Dictionary) -> Dictionary:
	var kind: String = String(item.get("kind", ""))
	var detail: Dictionary = item.get("detail", {}) if item.get("detail", {}) is Dictionary else {}
	if kind == "script_check":
		return _check_scripts(detail)
	if kind == "behavior_check":
		return await _check_behavior(detail)
	return {"defer": true}

## behavior_check 原生执行器：验证 detail 形状 →（测试注入点）→ 真实编排
## 探针安装 → run_project(allow_window) → 会话就绪等待 → play_and_verify →
## stop_project。证据标记 evidence_level=native_run 并携带运行事实（场景、
## 步数、逐断言实际/期望、运行错误、截图路径、会话标识）。
func _check_behavior(detail: Dictionary) -> Dictionary:
	var steps: Variant = detail.get("steps", [])
	var steps_valid: bool = steps is Array and not (steps as Array).is_empty()
	var timeline: Variant = detail.get("timeline", {})
	var timeline_valid: bool = timeline is Dictionary and not (timeline as Dictionary).is_empty() 		and (timeline as Dictionary).get("events", []) is Array 		and not ((timeline as Dictionary).get("events", []) as Array).is_empty()
	if not steps_valid and not timeline_valid:
		return {"passed": false, "evidence": {
			"evidence_level": "native_run",
			"issue": "behavior_check detail needs a non-empty steps array OR a timeline {events, assertions}"}}
	if _behavior_run_override.is_valid():
		return await _behavior_run_override.call(detail)
	return await _behavior_run_impl(detail)

## 经插件注册表取已 initialize 的模块实例（跨模块协作的既有模式）；
## 注册表不可用时回退到 new()（meta 回退链自行解析编辑器接口）。
## 需求清单（P0① 公共能力）：每条需求独立状态 + 证据，缺项 => incomplete。
func _requirement_checklist(queue: Dictionary) -> Dictionary:
	var contract: Array = queue.get("requirements", []) if queue.get("requirements", []) is Array else []
	var entries: Array = []
	var by_requirement: Dictionary = {}
	for item_value in queue.get("items", []):
		var item: Dictionary = item_value if item_value is Dictionary else {}
		var requirement_id: String = str(item.get("requirement", ""))
		if requirement_id.is_empty():
			var label: String = str(item.get("label", ""))
			if label.begins_with("requirement:"):
				requirement_id = label.substr(len("requirement:"))
		if requirement_id.is_empty():
			continue
		var evidence: Dictionary = item.get("evidence", {}) if item.get("evidence", {}) is Dictionary else {}
		var status: String
		var item_status: String = str(item.get("status", "pending"))
		var assertions_total: int = int(evidence.get("assertions_total", 0))
		var assertions_passed: int = int(evidence.get("assertions_passed", 0))
		var level: String = String(evidence.get("evidence_level", ""))
		if String(queue.get("blocked_reason", "")) != "" and item_status == "pending":
			status = "blocked"
		elif item_status == "pending":
			status = "unverified"
		elif level == "external_claim":
			status = "external_claim"
		elif item_status == "passed" and assertions_total > 0:
			status = "verified"
		elif item_status == "passed":
			status = "smoke"
		elif assertions_passed > 0:
			status = "partial"
		else:
			status = "failed"
		by_requirement[requirement_id] = {
			"requirement": requirement_id,
			"status": status,
			"item_status": item_status,
			"assertions_passed": assertions_passed,
			"assertions_total": assertions_total,
			"evidence_level": level,
		}
	for requirement_id in contract:
		if by_requirement.has(requirement_id):
			entries.append(by_requirement[requirement_id])
		else:
			entries.append({
				"requirement": requirement_id, "status": "unverified",
				"item_status": "missing", "assertions_passed": 0,
				"assertions_total": 0, "evidence_level": "",
			})
	var unverified: Array = []
	for entry in entries:
		if str(entry.get("status", "")) != "verified":
			unverified.append(str(entry.get("requirement", "?")))
	return {
		"requirements": entries,
		"unverified": unverified,
		"overall": "complete" if (not contract.is_empty() and unverified.is_empty()) else "incomplete",
	}

func _enforce_requirement_contract(queue: Dictionary) -> void:
	var contract: Array = queue.get("requirements", []) if queue.get("requirements", []) is Array else []
	if contract.is_empty():
		return
	var checklist: Dictionary = _requirement_checklist(queue)
	if String(checklist.get("overall", "incomplete")) != "complete":
		if String(queue.get("phase", "")) == "completed":
			queue["phase"] = "incomplete"
		queue["blocked_reason"] = "requirements without verified evidence: " + ", ".join(checklist.get("unverified", []))

func _tool_instance(class_key: String, fallback_script: GDScript) -> RefCounted:
	if Engine.has_meta("GodotMCPPlugin"):
		var plugin: Variant = Engine.get_meta("GodotMCPPlugin")
		if plugin and plugin.get("_tool_instances") is Dictionary:
			var instances: Dictionary = plugin.get("_tool_instances")
			if instances.has(class_key) and instances[class_key] is RefCounted:
				return instances[class_key]
	return fallback_script.new()

func _behavior_run_impl(detail: Dictionary) -> Dictionary:
	var scene_path: String = str(detail.get("scene_path", ""))
	var runtime_tools: RefCounted = _tool_instance("DebugRuntimeTools", DebugRuntimeToolsScript)
	var verify_tools: RefCounted = _tool_instance("DebugVerifyTools", DebugVerifyToolsScript)
	var bridge_tools: RefCounted = _tool_instance("DebugBridgeTools", DebugBridgeToolsScript)
	var editor_tools: RefCounted = _tool_instance("EditorToolsNative", EditorToolsScript)
	var evidence: Dictionary = {"evidence_level": "native_run", "scene_path": scene_path}

	var probe: Dictionary = await bridge_tools._tool_install_runtime_probe(
		{"node_name": "MCPRuntimeProbe", "persistent": true})
	if probe.has("error") and String(probe.get("status", "")) != "already_installed":
		evidence["issue"] = "probe install failed: " + str(probe.get("error"))
		return {"passed": false, "evidence": evidence}

	var run_params: Dictionary = {"allow_window": true}
	if not scene_path.is_empty():
		run_params["scene_path"] = scene_path
	var run: Dictionary = await editor_tools._tool_run_project(run_params)
	if run.has("error") or String(run.get("status", "")) == "error":
		evidence["issue"] = "run_project failed: " + str(run.get("error", run.get("game_status", "")))
		return {"passed": false, "evidence": evidence}

	# 会话就绪：debugger session 激活 + 运行树可见（探针流验证过的模式）。
	var ready: Dictionary = await _await_behavior_session(bridge_tools, runtime_tools)
	if not bool(ready.get("ok", false)):
		await editor_tools._tool_stop_project({"allow_window": true})
		evidence["issue"] = "runtime never became observable: " + str(ready.get("detail", ""))
		return {"passed": false, "evidence": evidence}
	evidence["session"] = ready.get("session", {})

	var verify_params: Dictionary = {
		"steps": detail.get("steps", []),
		"assertions": detail.get("assertions", []),
		"deterministic": bool(detail.get("deterministic", false)),
	}
	# timeline 透传（M7）：契约项可用单次往返的帧定时时间线——每个需求
	# 的验证从 N 次网络往返降到 1 次，且免疫网络抖动。
	if detail.has("timeline") and detail.get("timeline", {}) is Dictionary:
		verify_params["timeline"] = detail.get("timeline", {})
	if detail.has("timeout_ms"):
		verify_params["timeout_ms"] = int(detail["timeout_ms"])
	var report: Dictionary = await verify_tools._tool_play_and_verify(verify_params)
	await editor_tools._tool_stop_project({"allow_window": true})

	if report.has("error"):
		evidence["issue"] = "play_and_verify failed to orchestrate: " + str(report.get("error"))
		return {"passed": false, "evidence": evidence}
	evidence["steps_executed"] = int(report.get("steps_executed", 0))
	evidence["assertions"] = report.get("assertions", [])
	evidence["assertions_passed"] = int(report.get("assertions_passed", 0))
	evidence["assertions_total"] = int(report.get("assertions_total", 0))
	evidence["runtime_errors"] = report.get("runtime_errors", [])
	evidence["screenshots"] = report.get("screenshots", [])
	evidence["runtime_info"] = report.get("runtime_info", {})
	return {"passed": bool(report.get("passed", false)), "evidence": evidence}

func _await_behavior_session(bridge_tools: RefCounted, runtime_tools: RefCounted) -> Dictionary:
	var deadline_ms: int = Time.get_ticks_msec() + 20000
	while Time.get_ticks_msec() < deadline_ms:
		var sessions: Dictionary = await bridge_tools._tool_get_debugger_sessions({})
		var list: Array = sessions.get("sessions", []) if sessions.get("sessions", []) is Array else []
		var active_session: Dictionary = {}
		for session_value in list:
			var session: Dictionary = session_value
			if bool(session.get("active", false)):
				active_session = session
				break
		if not active_session.is_empty():
			var info: Dictionary = await runtime_tools._tool_get_runtime_info({"timeout_ms": 2000})
			if int(info.get("node_count", 0)) > 0:
				# 会话结构来自 debugger bridge：{session_id, active, breaked, debuggable}。
				# 附上 attached_at（引擎侧时间）让证据可追溯到具体的运行窗口。
				return {"ok": true, "session": {
					"session_id": int(active_session.get("session_id", -1)),
					"breaked": bool(active_session.get("breaked", false)),
					"debuggable": bool(active_session.get("debuggable", false)),
					"attached_at": Time.get_datetime_string_from_system(true, true)}}
		await Engine.get_main_loop().process_frame
	return {"ok": false, "detail": "no active debugger session with a visible tree within 20s"}

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
		var entry: Dictionary = {
			"id": String(item.get("id", "")),
			"kind": String(item.get("kind", "")),
			"label": String(item.get("label", "")),
			"status": String(item.get("status", "")),
			"checked_at": String(item.get("checked_at", "")),
		}
		# Compact evidence summary so callers stop digging through the store
		# file: level, pass counts, first failure description, key metrics.
		var evidence: Dictionary = item.get("evidence", {}) if item.get("evidence", {}) is Dictionary else {}
		if not evidence.is_empty():
			entry["evidence_level"] = String(evidence.get("evidence_level", ""))
			# 判定标注（包②）：verified=原生运行且带断言；smoke=原生运行但零断言；
			# external_claim=外部声明。严格队列只认 verified。
			if String(evidence.get("evidence_level", "")) == "external_claim":
				entry["verification"] = "external_claim"
			elif int(evidence.get("assertions_total", 0)) > 0:
				entry["verification"] = "verified"
			else:
				entry["verification"] = "smoke"
			if evidence.has("assertions_total"):
				entry["assertions_passed"] = int(evidence.get("assertions_passed", 0))
				entry["assertions_total"] = int(evidence.get("assertions_total", 0))
			for assertion_value in evidence.get("assertions", []):
				if assertion_value is Dictionary and not bool((assertion_value as Dictionary).get("passed", true)):
					entry["first_failure"] = String((assertion_value as Dictionary).get("description", ""))
					break
			if evidence.has("steps_executed"):
				entry["steps_executed"] = int(evidence.get("steps_executed", 0))
		items.append(entry)
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

