# debug_verify_tools.gd - Debug verify/orchestration domain tools (split from debug_tools_native.gd)

@tool
class_name DebugVerifyTools
extends RefCounted

var _editor_interface: EditorInterface = null
var _server_core: RefCounted = null
var _runtime_tools: RefCounted = null

func initialize(editor_interface: EditorInterface) -> void:
	_editor_interface = editor_interface

func _get_editor_interface() -> EditorInterface:
	if _editor_interface:
		return _editor_interface
	if Engine.has_meta("GodotMCPPlugin"):
		var plugin = Engine.get_meta("GodotMCPPlugin")
		if plugin and plugin.has_method("get_editor_interface"):
			return plugin.get_editor_interface()
	return null

func _get_debugger_bridge() -> RefCounted:
	if Engine.has_meta("GodotMCPPlugin"):
		var plugin = Engine.get_meta("GodotMCPPlugin")
		if plugin and plugin.has_method("get_debugger_bridge"):
			return plugin.get_debugger_bridge()
	return null

## Resolves the DebugRuntimeTools module instance that play_and_verify delegates
## runtime sub-tools to (get_runtime_info / simulate_runtime_input_* /
## get_runtime_screenshot / assert_runtime_condition). Prefers a directly injected
## instance (unit tests), then the plugin's registered tool-module registry.
## Cached after the first successful resolution.
func _get_runtime_tools() -> RefCounted:
	if _runtime_tools == null and Engine.has_meta("GodotMCPPlugin"):
		var plugin: Variant = Engine.get_meta("GodotMCPPlugin")
		if plugin and plugin.get("_tool_instances") is Dictionary:
			var instances: Dictionary = plugin.get("_tool_instances")
			if instances.has("DebugRuntimeTools"):
				_runtime_tools = instances["DebugRuntimeTools"]
	return _runtime_tools

# ============================================================================
# Tool registration
# ============================================================================

func register_tools(server_core: RefCounted) -> void:
	_server_core = server_core
	_register_play_and_verify(server_core)
	_register_assert_performance_budget(server_core)
	_register_assert_no_runtime_errors(server_core)
	_register_verify_change_effect(server_core)
	_register_game_quality_report(server_core)
	_register_game_quality_ladder(server_core)
# ============================================================================
# Progress / 取消支持辅助（配合 mcp_server_core 的 progress 与 cancelled 支持）
# ============================================================================

## True when the client cancelled the currently executing tool call. Long-running
## tools poll this inside their loops and abort early when it flips.
func _tool_cancelled() -> bool:
	return _server_core != null and _server_core.has_method("is_current_tool_cancelled") and bool(_server_core.is_current_tool_cancelled())

## Best-effort progress notification; silently skipped when the client supplied
## no progress token or no transport is connected.
func _send_tool_progress(progress_token: Variant, progress: int, total: int = 0, message: String = "") -> void:
	if _server_core != null and _server_core.has_method("send_progress_notification"):
		_server_core.send_progress_notification(progress_token, progress, total, message)


func _register_play_and_verify(server_core: RefCounted) -> void:
	server_core.register_tool(
		"play_and_verify",
		"Drive the running game through scripted steps and assertions into one pass/fail report. Steps send actions/events with waits/screenshots and may carry an inline 'assert' (expression+expected) evaluated right after the step, proving mid-sequence behavior (paused after Esc, resumed after the second) in order. Final assertions check runtime expressions. deterministic=true frame-steps in-game; 'sample' builds per-label trajectories. Runtime errors fail by default; needs the game plus probe.",
		{
			"type": "object",
			"properties": {
				"steps": {
					"type": "array",
					"description": "Ordered steps; each may include action/event, waits, screenshot and an inline 'assert' ({expression, expected, ...}) evaluated right after it; assert.inert=true snapshots the expression before the step and asserts it unchanged (proof an input is unbound).",
					"items": {"type": "object"}
				},
				"assertions": {
					"type": "array",
					"description": "Runtime expression checks.",
					"items": {"type": "object"}
				},
				"deterministic": {"type": "boolean", "default": false, "description": "Frame-step waits in-game."},
				"timeline": {"type": "object", "description": "ONE round trip, frame-timed inputs (input_sequence-style): {events: [{frame, action, pressed, strength?}], settle_frames?, sample?: [{label, expression}] (per-frame), assertions?: [{label, expression, expected?, operator?}] (evaluated IN-GAME on the last frame, values returned once)}. When present, steps are ignored and the whole run replays deterministically in a single probe call."},
				"frame_type": {"type": "string", "enum": ["physics", "process"], "default": "physics"},
				"sample": {"type": "array", "items": {"type": "object"}, "description": "Per-frame expression samples."},
				"include_trajectory": {"type": "boolean", "default": true},
				"settle_ms": {"type": "integer", "default": 0},
				"settle_frames": {"type": "integer", "default": 0},
				"screenshot_dir": {"type": "string", "default": "user://mcp_play_and_verify"},
				"screenshot_format": {"type": "string", "enum": ["png", "jpg"], "default": "jpg"},
				"fail_on_runtime_error": {"type": "boolean", "default": true, "description": "Fail on runtime errors."},
				"runtime_error_categories": {"type": "array", "items": {"type": "string"}, "default": ["stderr"]},
				"session_id": {"type": "integer"},
				"timeout_ms": {"type": "integer", "default": 3000}
			}
		},
		Callable(self, "_tool_play_and_verify"),
		{"type": "object", "properties": {"status": {"type": "string"}, "passed": {"type": "boolean"}, "deterministic": {"type": "boolean"}, "steps_executed": {"type": "integer"}, "frames_advanced": {"type": "integer"}, "assertions_total": {"type": "integer"}, "assertions_passed": {"type": "integer"}, "assertions": {"type": "array"}, "trajectory": {"type": "array"}, "screenshots": {"type": "array"}, "errors": {"type": "array"}, "runtime_errors": {"type": "array"}, "runtime_info": {"type": "object"}}},
		{"readOnlyHint": false, "destructiveHint": false, "idempotentHint": false, "openWorldHint": true},
		"supplementary", "Debug-Advanced"
	)
func _tool_play_and_verify(params: Dictionary) -> Dictionary:
	var steps: Array = params.get("steps", []) if params.get("steps", []) is Array else []
	var assertions: Array = params.get("assertions", []) if params.get("assertions", []) is Array else []
	var deterministic: bool = bool(params.get("deterministic", false))
	var frame_type: String = "process" if String(params.get("frame_type", "physics")) == "process" else "physics"
	var sample_specs: Array = params.get("sample", []) if params.get("sample", []) is Array else []
	var include_trajectory: bool = bool(params.get("include_trajectory", true))
	var trajectory: Array = []
	var frame_cursor: int = 0
	var step_delta: float = 0.0
	var format: String = String(params.get("screenshot_format", "jpg")).to_lower()
	if not ["png", "jpg"].has(format):
		format = "jpg"
	var ext: String = "png" if format == "png" else "jpg"
	var screenshot_dir: String = String(params.get("screenshot_dir", "user://mcp_play_and_verify")).strip_edges()
	while screenshot_dir.ends_with("/"):
		screenshot_dir = screenshot_dir.substr(0, screenshot_dir.length() - 1)

	# Optional client progress token (arguments._meta.progressToken).
	var progress_token: Variant = null
	if params.has("_meta") and params["_meta"] is Dictionary:
		progress_token = (params["_meta"] as Dictionary).get("progressToken", null)

	var timeline: Dictionary = params.get("timeline", {}) if params.get("timeline", {}) is Dictionary else {}
	if not timeline.is_empty():
		return await _run_timeline_mode(params, timeline)

	# Verify a runtime session with the probe is reachable before doing anything.
	if _get_runtime_tools() == null:
		return {"error": "No running game with a runtime probe is reachable. Run the project and install_runtime_probe first."}
	var info: Dictionary = await _get_runtime_tools()._tool_get_runtime_info(_merge_runtime_params(params, {}))
	if info.has("error") or info.get("status", "") == "no_active_sessions":
		return {
			"error": "No running game with a runtime probe is reachable. Run the project and install_runtime_probe first.",
			"detail": info
		}

	# Snapshot the debugger output cursor so we only attribute errors emitted from
	# this point on (during the scripted run) to the report.
	var bridge: RefCounted = _get_debugger_bridge()
	var error_baseline_sequence: int = 0
	if bridge and bridge.has_method("get_message_sequence"):
		error_baseline_sequence = int(bridge.get_message_sequence())

	var errors: Array = []
	var screenshots: Array = []
	var executed: int = 0
	# 断言结果统一记账：步内 assert（按序紧跟该步求值）+ 末尾 assertions。
	var assertion_results: Array = []
	var passed_count: int = 0

	for i in steps.size():
		# 客户端取消检查：每一步都检查，取消则中止编排并返回 cancelled。
		if _tool_cancelled():
			return {"status": "cancelled", "error": "cancelled by client", "steps_executed": executed}
		var step: Dictionary = steps[i] if steps[i] is Dictionary else {}
		# inert 断言：发送本步输入前先读一次表达式值（快照），等待后断言
		# 值不变——证明"该输入已失效"（E1 旧键证明）。绝对阈值在非原点
		# 起步时不可用（真机 E2E 抓到），位移相对才是正确语义。
		var inert_pre_value: Variant = null
		var displacement_mode: String = ""
		if step.has("assert") and step["assert"] is Dictionary:
			if bool((step["assert"] as Dictionary).get("inert", false)):
				displacement_mode = "inert"
			elif (step["assert"] as Dictionary).has("displacement_min") \
					or (step["assert"] as Dictionary).has("displacement_max"):
				displacement_mode = "delta"
		if not displacement_mode.is_empty():
			# 快照用 await_condition 而非 assert_condition：快照只关心"读到了
			# 新鲜值"——表达式为假值（如原点 position.x == 0.0）是合法快照，
			# assert_condition 会把假值包装成 error（"not met"），守卫会误伤
			# （CI run 35346032733：每个位移腿在原点起步全部误判读取失败）。
			# await_condition 的 error 才是真读取失败（超时/无会话）。
			var pre_read: Dictionary = await _get_runtime_tools()._tool_await_runtime_condition(
				_merge_runtime_params(params, {
					"expression": String((step["assert"] as Dictionary).get("expression", "")),
					"single_sample": true,
					"timeout_ms": 3000}))
			# 快照必须新鲜：陈旧/超时的 last_value 会污染位移 delta
			# （CI run 35343562660："按右键左移 110px"实为陈旧 before 与
			# 新鲜 after 的差值——测量造假）。拿不到新鲜快照就大声失败。
			if pre_read.has("error") or bool(pre_read.get("stale", false)):
				errors.append({"step": i, "phase": "assert",
					"error": "displacement snapshot not fresh: %s" % str(pre_read.get("error", "stale cached value"))})
			else:
				inert_pre_value = pre_read.get("last_value", null)
		if step.has("action"):
			var input_params: Dictionary = _merge_runtime_params(params, {
				"action_name": String(step.get("action", "")),
				"pressed": bool(step.get("pressed", true))
			})
			if step.has("strength"):
				input_params["strength"] = float(step["strength"])
			var action_result: Dictionary = await _get_runtime_tools()._tool_simulate_runtime_input_action(input_params)
			# 非成功状态（timeout/no_active_sessions）以前被静默放过——输入
			# 步假完成，后续断言在错误状态下测量。非 success 一律记为步错误。
			if action_result.has("error") or String(action_result.get("status", "success")) != "success":
				errors.append({"step": i, "phase": "input",
					"error": str(action_result.get("error", "input step status: " + str(action_result.get("status", "")))) + _unbound_input_hint(String(step.get("action", "")))})
		elif step.has("event"):
			var event_params: Dictionary = _merge_runtime_params(params, {"event": step["event"]})
			var event_result: Dictionary = await _get_runtime_tools()._tool_simulate_runtime_input_event(event_params)
			if event_result.has("error") or String(event_result.get("status", "success")) != "success":
				errors.append({"step": i, "phase": "input", "error": str(event_result.get("error", "input step status: " + str(event_result.get("status", ""))))})

		var wait_ms: int = int(step.get("wait_ms", 0))
		if deterministic and step.has("wait_frames"):
			var step_frames: int = maxi(int(step["wait_frames"]), 0)
			if step_frames > 0:
				var adv: Dictionary = await _advance_runtime_frames(params, step_frames, frame_type, sample_specs)
				if adv.has("error"):
					errors.append({"step": i, "phase": "advance", "error": adv["error"]})
				else:
					step_delta = float(adv.get("step_delta", step_delta))
					frame_cursor = _append_trajectory(trajectory, adv.get("samples", []), frame_cursor)
			if wait_ms > 0:
				await _await_real_ms(wait_ms)
		else:
			if step.has("wait_frames"):
				wait_ms = maxi(wait_ms, int(step["wait_frames"]) * 17)
			if wait_ms > 0:
				await _await_real_ms(wait_ms)

		if bool(step.get("screenshot", false)):
			var save_path: String = "%s/step_%02d.%s" % [screenshot_dir, i, ext]
			var shot_params: Dictionary = _merge_runtime_params(params, {"save_path": save_path, "format": format})
			var shot_result: Dictionary = await _get_runtime_tools()._tool_get_runtime_screenshot(shot_params)
			if shot_result.has("error"):
				errors.append({"step": i, "phase": "screenshot", "error": shot_result["error"]})
			else:
				screenshots.append({"step": i, "save_path": save_path, "size": shot_result.get("size", "")})
		# 步内断言：紧跟本步求值（如 Esc 后世界应立即暂停），顺序即证据。
		if step.has("assert") and step["assert"] is Dictionary:
			var step_assert: Dictionary = step["assert"]
			if displacement_mode == "delta" and inert_pre_value != null:
				# 位移相对断言：步前快照 + 步后差值比较——起点无关（E4 校准
				# 实测：残留游戏从 x=+810 起步时原点绝对阈值必败）。
				# 同 pre-read：await_condition 语义（假值是合法读，error 才是失败）。
				var post_read: Dictionary = await _get_runtime_tools()._tool_await_runtime_condition(
					_merge_runtime_params(params, {
						"expression": String(step_assert.get("expression", "")),
						"single_sample": true,
						"timeout_ms": 3000}))
				if post_read.has("error") or bool(post_read.get("stale", false)):
					# 步后读同样必须新鲜——陈旧 after 配新鲜 before 是同一种
					# 测量造假。记失败断言（带证据描述），不静默跳过。
					assertion_results.append({
						"description": String(step_assert.get("description", step_assert.get("expression", ""))),
						"expression": String(step_assert.get("expression", "")),
						"passed": false,
						"error": "post-step snapshot not fresh: %s" % str(post_read.get("error", "stale cached value")),
						"step": i,
					})
				else:
					var post_value: float = float(post_read.get("last_value", inert_pre_value))
					var delta_value: float = post_value - float(inert_pre_value)
					var delta_passed: bool = true
					if step_assert.has("displacement_min"):
						delta_passed = delta_passed and delta_value >= float(step_assert["displacement_min"])
					if step_assert.has("displacement_max"):
						delta_passed = delta_passed and delta_value <= float(step_assert["displacement_max"])
					var delta_result: Dictionary = {
						"description": String(step_assert.get("description", step_assert.get("expression", ""))),
						"expression": String(step_assert.get("expression", "")),
						"passed": delta_passed,
						"before_value": inert_pre_value,
						"after_value": post_value,
						"displacement": delta_value,
						"step": i,
					}
					# 阈值随载荷下发：失败取证摘要需要（区分零位移 vs 部分位移）。
					if step_assert.has("displacement_min"):
						delta_result["displacement_min"] = float(step_assert["displacement_min"])
					if step_assert.has("displacement_max"):
						delta_result["displacement_max"] = float(step_assert["displacement_max"])
					if bool(delta_passed):
						passed_count += 1
					assertion_results.append(delta_result)
			elif displacement_mode == "delta" and inert_pre_value == null \
					and (step_assert.has("displacement_min") or step_assert.has("displacement_max")):
				# 快照不可用（前读失败已记步错误）——位移断言不得退化成
				# truthiness 求值（position.x 非零即"通过"的空洞）。
				assertion_results.append({
					"description": String(step_assert.get("description", step_assert.get("expression", ""))),
					"expression": String(step_assert.get("expression", "")),
					"passed": false,
					"error": "displacement assert skipped: pre-step snapshot unavailable",
					"step": i,
				})
			else:
				if displacement_mode == "inert" and inert_pre_value != null:
					step_assert = step_assert.duplicate()
					step_assert["expected"] = inert_pre_value
					step_assert.erase("inert")
				var step_result: Dictionary = await _evaluate_runtime_assertion(params, step_assert, "step %d" % i)
				step_result["step"] = i
				if bool(step_result.get("passed", false)):
					passed_count += 1
				assertion_results.append(step_result)
		executed += 1
		# 进度通知：step index -> progress（steps 为总进度）。
		_send_tool_progress(progress_token, executed, steps.size(), "step")

	if deterministic and int(params.get("settle_frames", 0)) > 0:
		var settle_adv: Dictionary = await _advance_runtime_frames(params, int(params["settle_frames"]), frame_type, sample_specs)
		if settle_adv.has("error"):
			errors.append({"phase": "settle", "error": settle_adv["error"]})
		else:
			step_delta = float(settle_adv.get("step_delta", step_delta))
			frame_cursor = _append_trajectory(trajectory, settle_adv.get("samples", []), frame_cursor)
	if int(params.get("settle_ms", 0)) > 0:
		await _await_real_ms(int(params["settle_ms"]))

	var metrics: Dictionary = _compute_trajectory_metrics(trajectory, step_delta)

	for i in assertions.size():
		# 断言阶段也可能耗时（每个断言都要轮询运行时探针），同样响应取消。
		if _tool_cancelled():
			return {"status": "cancelled", "error": "cancelled by client", "steps_executed": executed, "assertions_total": i + assertion_results.size(), "assertions_passed": passed_count}
		var spec: Dictionary = assertions[i] if assertions[i] is Dictionary else {}
		if spec.has("metric"):
			var metric_result: Dictionary = _evaluate_metric_assertion(spec, metrics)
			metric_result["index"] = i
			if bool(metric_result.get("passed", false)):
				passed_count += 1
			assertion_results.append(metric_result)
			continue
		var final_result: Dictionary = await _evaluate_runtime_assertion(params, spec, "")
		final_result["index"] = i
		if bool(final_result.get("passed", false)):
			passed_count += 1
		assertion_results.append(final_result)

	var end_info: Dictionary = await _get_runtime_tools()._tool_get_runtime_info(_merge_runtime_params(params, {}))

	# Pull any runtime errors the game emitted during the scripted run and fold
	# them into the verdict so an agent gets self-correction feedback.
	var error_categories: Array = params.get("runtime_error_categories", ["stderr"]) if params.get("runtime_error_categories", ["stderr"]) is Array else ["stderr"]
	var runtime_errors: Array = []
	if bridge and bridge.has_method("get_output_events"):
		var output_dump: Dictionary = bridge.get_output_events(500, 0, "asc", "")
		runtime_errors = _filter_runtime_error_events(output_dump.get("events", []), error_baseline_sequence, error_categories)
	var fail_on_runtime_error: bool = bool(params.get("fail_on_runtime_error", true))

	var all_passed: bool = errors.is_empty() and passed_count == assertion_results.size() and (not fail_on_runtime_error or runtime_errors.is_empty())
	var report: Dictionary = {
		"status": "success" if all_passed else "failed",
		"passed": all_passed,
		"deterministic": deterministic,
		"steps_executed": executed,
		"assertions_total": assertion_results.size(),
		"assertions_passed": passed_count,
		"assertions": assertion_results,
		"screenshots": screenshots,
		"errors": errors,
		"runtime_errors": runtime_errors,
		"runtime_info": {
			"fps": end_info.get("fps", null),
			"node_count": end_info.get("node_count", null),
			"current_scene": end_info.get("current_scene", "")
		}
	}
	if deterministic:
		report["frames_advanced"] = maxi(frame_cursor - 1, 0)
		report["metrics"] = metrics
		if include_trajectory:
			report["trajectory"] = trajectory
	return report

## 输入步失败的自愈提示（E-3 下沉#3）：未绑定的 action 是契约全灭的头号原因。
static func _unbound_input_hint(action_name: String) -> String:
	if action_name.is_empty():
		return ""
	return " — if '%s' is unbound, upsert_project_input_action('%s', ...) first" % [action_name, action_name]

## timeline 模式：一次探针往返执行帧定时输入时间线，末帧断言值随响应带回，
## 期望比对在编辑器侧完成（零额外往返）。报告形状与常规模式兼容。
func _run_timeline_mode(params: Dictionary, timeline: Dictionary) -> Dictionary:
	var events: Array = timeline.get("events", []) if timeline.get("events", []) is Array else []
	if events.is_empty():
		return {"error": "timeline requires a non-empty events array [{frame, action, pressed}]"}
	var sample_specs: Array = timeline.get("sample", []) if timeline.get("sample", []) is Array else []
	var assertion_specs: Array = timeline.get("assertions", []) if timeline.get("assertions", []) is Array else []
	var frame_type: String = "process" if String(params.get("frame_type", "physics")) == "process" else "physics"
	var needed_ms: int = timeline_total_frames(events, int(timeline.get("settle_frames", 0))) * 20 + 2000
	var probe_params: Dictionary = _merge_runtime_params(params, {})
	probe_params["timeout_ms"] = maxi(int(params.get("timeout_ms", 3000)), needed_ms)
	var run: Dictionary = await DebugToolsNative._request_runtime_probe_poll(
		"apply_timeline", [events, sample_specs, assertion_specs, frame_type,
			int(timeline.get("settle_frames", 0))],
		["mcp:timeline_applied"], probe_params)
	if run.has("error"):
		return {"status": "failed", "passed": false, "errors": [
			{"phase": "timeline", "error": str(run.get("error"))}],
			"assertions": [], "assertions_total": 0, "assertions_passed": 0}
	var finals: Dictionary = run.get("finals", {}) if run.get("finals", {}) is Dictionary else {}
	var assertion_results: Array = fold_timeline_assertions(assertion_specs, finals)
	var passed_count: int = 0
	for result_value in assertion_results:
		if result_value is Dictionary and bool((result_value as Dictionary).get("passed", false)):
			passed_count += 1
	var trajectory: Array = []
	var frame_cursor: int = 0
	for sample_value in run.get("samples", []) if run.get("samples", []) is Array else []:
		if frame_cursor > 0 and not trajectory.is_empty():
			pass  # 首样本为步前状态，与 advance 语义一致地保留全部帧样本
		trajectory.append({"frame_index": frame_cursor, "values": (sample_value as Dictionary).get("values", {}) if sample_value is Dictionary else {}})
		frame_cursor += 1
	var all_passed: bool = passed_count == assertion_results.size()
	return {
		"status": "success" if all_passed else "failed",
		"passed": all_passed,
		"deterministic": true,
		"mode": "timeline",
		"frames_advanced": maxi(frame_cursor - 1, 0),
		"events_applied": int(run.get("events_applied", 0)),
		"trajectory": trajectory,
		"steps_executed": 0,
		"assertions_total": assertion_results.size(),
		"assertions_passed": passed_count,
		"assertions": assertion_results,
		"errors": [],
		"runtime_errors": [],
	}

## 纯函数（可单测）：末帧值 + 断言规格 -> 断言结果（期望比对编辑器侧完成）。
static func fold_timeline_assertions(specs: Array, finals: Dictionary) -> Array:
	var results: Array = []
	for spec_value in specs:
		if not (spec_value is Dictionary):
			continue
		var spec: Dictionary = spec_value
		var label: String = String(spec.get("label", spec.get("description", spec.get("expression", ""))))
		var result: Dictionary = {
			"description": label,
			"expression": String(spec.get("expression", "")),
			"passed": false}
		if not finals.has(label):
			result["error"] = "no final value for '%s' (label mismatch or expression failed in-game)" % label
			results.append(result)
			continue
		var actual: Variant = finals[label]
		result["actual"] = actual
		if not spec.has("expected"):
			result["passed"] = bool(actual)
			results.append(result)
			continue
		result["expected"] = spec["expected"]
		result["operator"] = String(spec.get("operator", "eq"))
		result["passed"] = _timeline_value_matches(actual, spec["expected"], String(spec.get("operator", "eq")))
		results.append(result)
	return results

static func _timeline_value_matches(actual: Variant, expected: Variant, operator_name: String) -> bool:
	var a: float = float(actual) if actual is float or actual is int else 0.0
	var b: float = float(expected) if expected is float or expected is int else 0.0
	if not (actual is float or actual is int) or not (expected is float or expected is int):
		match operator_name:
			"ne":
				return str(actual) != str(expected)
			_:
				return str(actual) == str(expected)
	match operator_name:
		"ne":
			return not is_equal_approx(a, b)
		"gt":
			return a > b
		"gte":
			return a >= b
		"lt":
			return a < b
		"lte":
			return a <= b
		_:
			return is_equal_approx(a, b)

## 纯函数（可单测）：总帧数 = max(事件帧)+1+settle（与探针 compile_timeline 同口径）。
static func timeline_total_frames(events: Array, settle_frames: int) -> int:
	var last_frame: int = -1
	for event_value in events:
		if event_value is Dictionary:
			last_frame = maxi(last_frame, int((event_value as Dictionary).get("frame", 0)))
	return maxi(last_frame + 1 + maxi(settle_frames, 0), 1)

## 求值一条运行时表达式断言。步内 assert 与末尾 assertions 共用同一
## 求值路径，保证 mid-sequence 与 final 断言的语义完全一致。
## context 非空时标注求值时机（如 "step 3"）用于审计。
func _evaluate_runtime_assertion(params: Dictionary, spec: Dictionary, context: String) -> Dictionary:
	var expression: String = String(spec.get("expression", "")).strip_edges()
	if expression.is_empty():
		return {"passed": false, "error": "Missing 'expression' (or 'metric')"}
	var assert_params: Dictionary = _merge_runtime_params(params, {"expression": expression})
	assert_params["description"] = String(spec.get("description", spec.get("label", expression)))
	if spec.has("node_path"):
		assert_params["node_path"] = spec["node_path"]
	if spec.has("expected"):
		assert_params["expected"] = spec["expected"]
	if spec.has("operator"):
		assert_params["operator"] = spec["operator"]
	if spec.has("timeout_ms"):
		assert_params["timeout_ms"] = spec["timeout_ms"]
	var assert_result: Dictionary = await _get_runtime_tools()._tool_assert_runtime_condition(assert_params)
	var passed: bool
	if assert_result.has("error"):
		passed = false
	elif assert_result.has("passed"):
		passed = bool(assert_result["passed"])
	else:
		passed = assert_result.get("status", "") == "success"
	var result: Dictionary = {
		"description": assert_params["description"],
		"expression": expression,
		"passed": passed,
		"expected": assert_result.get("expected", null),
		"actual": assert_result.get("actual", null),
		"last_value": assert_result.get("last_value", null),
		"error": assert_result.get("error", null)
	}
	if not context.is_empty():
		result["context"] = context
	return result

## Deterministically advances the running game by `frames` frames, sampling
## `sample_specs` each frame, via the runtime probe's advance_frames command.
## Returns {samples, step_delta, ...} or {error}.
func _advance_runtime_frames(params: Dictionary, frames: int, frame_type: String, sample_specs: Array) -> Dictionary:
	frames = maxi(frames, 0)
	var ft: String = "process" if frame_type == "process" else "physics"
	var probe_params: Dictionary = _merge_runtime_params(params, {})
	# Each stepped frame costs ~1/60s; budget wall-clock time so the poll loop
	# does not give up before the in-game stepping coroutine finishes.
	var needed_ms: int = frames * 20 + 500
	probe_params["timeout_ms"] = maxi(int(params.get("timeout_ms", 3000)), needed_ms)
	return await DebugToolsNative._request_runtime_probe_poll(
		"advance_frames", [frames, ft, sample_specs], ["mcp:frames_advanced"], probe_params
	)

## Appends probe-returned per-frame samples to `trajectory` with a continuous
## global frame index. The first sample of each advance is the pre-step state,
## so it is skipped after the first advance to avoid duplicating the boundary
## frame. Returns the updated cursor (== trajectory length).
func _append_trajectory(trajectory: Array, samples: Array, cursor: int) -> int:
	for k in samples.size():
		if k == 0 and not trajectory.is_empty():
			continue
		var sample: Dictionary = samples[k] if samples[k] is Dictionary else {}
		trajectory.append({"frame_index": cursor, "values": sample.get("values", {})})
		cursor += 1
	return cursor

## Aggregates a frame-indexed trajectory into per-label metrics so game feel
## becomes measurable (e.g. jump height, time-to-apex). Only numeric sample
## values contribute. `step_delta` converts frame indices to seconds.
func _compute_trajectory_metrics(trajectory: Array, step_delta: float) -> Dictionary:
	var acc: Dictionary = {}
	for entry in trajectory:
		if not (entry is Dictionary):
			continue
		var frame_index: int = int(entry.get("frame_index", 0))
		var values: Dictionary = entry.get("values", {}) if entry.get("values", {}) is Dictionary else {}
		for label in values:
			var raw: Variant = values[label]
			if not (raw is int or raw is float):
				continue
			var value: float = float(raw)
			if not acc.has(label):
				acc[label] = {"min": value, "max": value, "first": value, "last": value, "min_frame": frame_index, "max_frame": frame_index, "samples": 0}
			var data: Dictionary = acc[label]
			if value < float(data["min"]):
				data["min"] = value
				data["min_frame"] = frame_index
			if value > float(data["max"]):
				data["max"] = value
				data["max_frame"] = frame_index
			data["last"] = value
			data["samples"] = int(data["samples"]) + 1
			acc[label] = data

	var metrics: Dictionary = {}
	for label in acc:
		var data: Dictionary = acc[label]
		var minimum: float = float(data["min"])
		var maximum: float = float(data["max"])
		var first_value: float = float(data["first"])
		var last_value: float = float(data["last"])
		var min_frame: int = int(data["min_frame"])
		var max_frame: int = int(data["max_frame"])
		metrics[label] = {
			"min": minimum,
			"max": maximum,
			"first": first_value,
			"last": last_value,
			"delta": last_value - first_value,
			"range": maximum - minimum,
			"min_frame": min_frame,
			"max_frame": max_frame,
			"min_time": float(min_frame) * step_delta,
			"max_time": float(max_frame) * step_delta,
			"samples": int(data["samples"])
		}
	return metrics

## Evaluates a trajectory metric assertion: {metric, aggregate?, operator?, expected?}.
func _evaluate_metric_assertion(spec: Dictionary, metrics: Dictionary) -> Dictionary:
	var label: String = String(spec.get("metric", "")).strip_edges()
	var aggregate: String = String(spec.get("aggregate", "max")).strip_edges().to_lower()
	var result: Dictionary = {
		"description": String(spec.get("description", spec.get("label", "%s.%s" % [label, aggregate]))),
		"metric": label,
		"aggregate": aggregate,
		"passed": false
	}
	if label.is_empty():
		result["error"] = "metric assertion requires a non-empty 'metric'"
		return result
	if not metrics.has(label):
		result["error"] = "metric '%s' not found in trajectory (set 'sample' and deterministic=true)" % label
		return result
	var label_metrics: Dictionary = metrics[label]
	if not label_metrics.has(aggregate):
		result["error"] = "unknown aggregate '%s' for metric '%s'" % [aggregate, label]
		return result
	var actual: Variant = label_metrics[aggregate]
	result["actual"] = actual
	if not spec.has("expected"):
		result["passed"] = bool(actual)
		return result
	var operator: String = String(spec.get("operator", "eq")).strip_edges().to_lower()
	if operator.is_empty():
		operator = "eq"
	result["operator"] = operator
	result["expected"] = spec["expected"]
	result["passed"] = _compare_metric_value(float(actual), float(spec["expected"]), operator)
	return result

func _compare_metric_value(actual: float, expected: float, operator: String) -> bool:
	match operator:
		"eq":
			return is_equal_approx(actual, expected)
		"ne":
			return not is_equal_approx(actual, expected)
		"gt":
			return actual > expected
		"gte":
			return actual >= expected
		"lt":
			return actual < expected
		"lte":
			return actual <= expected
	return false

## Filters debugger output events down to those newer than `baseline_sequence`
## whose category is in `categories`, normalizing the fields an agent needs to
## locate and fix a runtime error.
func _filter_runtime_error_events(events: Array, baseline_sequence: int, categories: Array) -> Array:
	var out: Array = []
	for entry in events:
		if not (entry is Dictionary):
			continue
		var seq: int = int(entry.get("sequence", 0))
		if seq <= baseline_sequence:
			continue
		var category: String = str(entry.get("category", ""))
		if not categories.is_empty() and not categories.has(category):
			continue
		out.append({
			"sequence": seq,
			"category": category,
			"message": str(entry.get("message", "")),
			"file": str(entry.get("file", "")),
			"line": int(entry.get("line", 0)),
			"function": str(entry.get("function", ""))
		})
	return out

const _PERF_BUDGET_RULES: Array = [
	{"key": "min_fps", "field": "fps", "comparator": "gte", "scale": 1.0},
	{"key": "max_frame_time_ms", "field": "frame_time_sec", "comparator": "lte", "scale": 1000.0},
	{"key": "max_physics_frame_time_ms", "field": "physics_frame_time_sec", "comparator": "lte", "scale": 1000.0},
	{"key": "max_object_count", "field": "object_count", "comparator": "lte", "scale": 1.0},
	{"key": "max_resource_count", "field": "resource_count", "comparator": "lte", "scale": 1.0},
	{"key": "max_rendered_objects", "field": "rendered_objects_in_frame", "comparator": "lte", "scale": 1.0},
	{"key": "max_memory_mb", "field": "memory_static_mb", "comparator": "lte", "scale": 1.0},
	{"key": "max_node_count", "field": "node_count", "comparator": "lte", "scale": 1.0},
	# 分位数指标：只有开启采样（sample_seconds > 0）时才有值。
	# min_fps 看的是"最后一瞬间的 fps"，一帧抖动就能让整条流水线红掉；
	# p1_fps / p95_frame_time_ms 看的是稳态分布，才是真正该卡的指标。
	{"key": "min_p1_fps", "field": "p1_fps", "comparator": "gte", "scale": 1.0},
	{"key": "max_p95_frame_time_ms", "field": "p95_frame_time_ms", "comparator": "lte", "scale": 1.0}
]

func _register_assert_performance_budget(server_core: RefCounted) -> void:
	server_core.register_tool(
		"assert_performance_budget",
		"Performance budget gate: check a live runtime snapshot (or a provided 'snapshot') against min_*/max_* thresholds (fps, frame_time_ms, physics_frame_time_ms, object/resource/node counts, memory_mb; percentile keys min_p1_fps / max_p95_frame_time_ms require sampling). sample_seconds>0 samples a window after warmup and gates on percentiles instead of one instantaneous reading. Needs the game running with the probe installed unless 'snapshot' is supplied.",
		{
			"type": "object",
			"properties": {
				"budget": {"type": "object", "description": "Threshold map; see tool description for valid keys."},
				"snapshot": {"type": "object", "description": "Optional pre-captured performance snapshot to evaluate instead of querying the game."},
				"warmup_seconds": {"type": "number", "description": "Seconds to wait before sampling (skips shader-compile/first-frame hitches); used when sample_seconds>0.", "default": 0},
				"sample_seconds": {"type": "number", "description": "Sampling window in seconds; 0 = single snapshot, >0 enables percentile metrics.", "default": 0},
				"sample_interval_ms": {"type": "integer", "description": "Delay between samples in ms. Default 100.", "default": 100},
				"percentile": {"type": "number", "description": "Tail percentile (default 95).", "default": 95},
				"session_id": {"type": "integer"},
				"timeout_ms": {"type": "integer", "default": 1500}
			},
			"required": ["budget"]
		},
		Callable(self, "_tool_assert_performance_budget"),
		{"type": "object", "properties": {"passed": {"type": "boolean"}, "checks": {"type": "array"}, "snapshot": {"type": "object"}, "budget": {"type": "object"}, "sampling": {"type": "object"}}},
		{"readOnlyHint": true, "destructiveHint": false, "idempotentHint": false, "openWorldHint": true},
		"supplementary", "Debug-Advanced"
	)

func _evaluate_performance_budget(snapshot: Dictionary, budget: Dictionary) -> Dictionary:
	var checks: Array = []
	var all_passed: bool = true
	for rule in _PERF_BUDGET_RULES:
		var key: String = str(rule["key"])
		if not budget.has(key):
			continue
		var field: String = str(rule["field"])
		var comparator: String = str(rule["comparator"])
		var scale: float = float(rule["scale"])
		var limit: float = float(budget[key])
		var check: Dictionary = {
			"metric": key,
			"field": field,
			"comparator": comparator,
			"limit": limit
		}
		if not snapshot.has(field):
			check["passed"] = false
			check["error"] = "Snapshot missing field: " + field
			all_passed = false
			checks.append(check)
			continue
		var actual: float = float(snapshot[field]) * scale
		check["actual"] = actual
		var ok: bool = (actual >= limit) if comparator == "gte" else (actual <= limit)
		check["passed"] = ok
		if not ok:
			all_passed = false
		checks.append(check)
	return {"passed": all_passed, "checks": checks}

func _tool_assert_performance_budget(params: Dictionary) -> Dictionary:
	var budget_raw: Variant = params.get("budget", {})
	if not (budget_raw is Dictionary):
		return {"error": "Parameter 'budget' must be an object"}
	var budget: Dictionary = budget_raw
	if budget.is_empty():
		return {"error": "Parameter 'budget' must define at least one threshold"}

	var valid_keys: Array = []
	for rule in _PERF_BUDGET_RULES:
		valid_keys.append(str(rule["key"]))
	for k in budget.keys():
		if not valid_keys.has(str(k)):
			return {"error": "Unknown budget key: " + str(k) + ". Valid keys: " + ", ".join(valid_keys)}

	var snapshot: Dictionary = {}
	var sampling: Dictionary = {"enabled": false}
	var provided: Variant = params.get("snapshot", null)
	if provided is Dictionary and not (provided as Dictionary).is_empty():
		snapshot = provided
	else:
		var rt: RefCounted = _get_runtime_tools()
		if rt == null:
			return {"error": "No running game with a runtime probe is reachable. Run the project and install_runtime_probe first."}

		var sample_seconds: float = float(params.get("sample_seconds", 0))
		var warmup_seconds: float = maxf(float(params.get("warmup_seconds", 0)), 0.0)
		if sample_seconds > 0.0:
			var sampled: Dictionary = await _collect_performance_samples(rt, params, warmup_seconds, sample_seconds)
			if sampled.has("error"):
				return sampled
			snapshot = sampled.get("snapshot", {})
			sampling = sampled.get("sampling", {})
		else:
			snapshot = await rt._tool_get_runtime_performance_snapshot(params)
		if snapshot.has("error"):
			return snapshot
		if not snapshot.has("fps"):
			return {"error": "No runtime performance snapshot available (game not running or probe not ready)", "status": str(snapshot.get("status", "")), "snapshot": snapshot}

	var evaluation: Dictionary = _evaluate_performance_budget(snapshot, budget)
	return {
		"passed": bool(evaluation["passed"]),
		"checks": evaluation["checks"],
		"snapshot": snapshot,
		"budget": budget,
		"sampling": sampling
	}


## 采样一段时间内的性能指标，给出稳态分位数。
##
## 单次瞬时快照拿到的 fps 极易被一帧抖动带偏：着色器编译、资源首次加载都会
## 让某一帧掉到个位数，于是"性能达标"被误判成"性能不达标"。这里先 warmup
## 掉冷启动开销，再在窗口内多次采样，用 p1（最差 1% 的 fps）和 p95（最差 5%
## 的帧时间）作为判定依据。
func _collect_performance_samples(runtime_tools: RefCounted, params: Dictionary,
		warmup_seconds: float, sample_seconds: float) -> Dictionary:
	var tree: SceneTree = Engine.get_main_loop() as SceneTree
	var interval_ms: int = maxi(int(params.get("sample_interval_ms", 100)), 16)
	var percentile: float = clampf(float(params.get("percentile", 95)), 1.0, 99.0)

	var warmup_deadline: int = Time.get_ticks_msec() + int(warmup_seconds * 1000.0)
	while Time.get_ticks_msec() < warmup_deadline:
		if tree == null:
			break
		await tree.process_frame

	var fps_samples: Array[float] = []
	var frame_time_samples: Array[float] = []
	var latest: Dictionary = {}
	var started_msec: int = Time.get_ticks_msec()
	var deadline: int = started_msec + int(sample_seconds * 1000.0)
	var next_sample_msec: int = started_msec
	while Time.get_ticks_msec() < deadline:
		if Time.get_ticks_msec() >= next_sample_msec:
			var raw: Variant = await runtime_tools._tool_get_runtime_performance_snapshot(params)
			if raw is Dictionary:
				var candidate: Dictionary = raw
				if not candidate.has("error") and candidate.has("fps"):
					latest = candidate
					fps_samples.append(float(candidate.get("fps", 0.0)))
					frame_time_samples.append(float(candidate.get("frame_time_sec", 0.0)) * 1000.0)
			next_sample_msec = Time.get_ticks_msec() + interval_ms
		if tree == null:
			break
		await tree.process_frame

	if latest.is_empty():
		return {"error": "No runtime performance samples could be collected (game not running or probe not ready)"}

	var tail: float = 100.0 - percentile
	var sorted_fps: Array[float] = fps_samples.duplicate()
	sorted_fps.sort()
	var sorted_frame: Array[float] = frame_time_samples.duplicate()
	sorted_frame.sort()
	var p1_fps: float = _percentile(sorted_fps, tail)
	var p95_frame_time_ms: float = _percentile(sorted_frame, percentile)

	var snapshot: Dictionary = latest.duplicate(true)
	snapshot["p1_fps"] = p1_fps
	snapshot["p95_frame_time_ms"] = p95_frame_time_ms
	snapshot["fps_samples"] = fps_samples
	snapshot["frame_time_ms_samples"] = frame_time_samples
	return {
		"snapshot": snapshot,
		"sampling": {
			"enabled": true,
			"sample_count": fps_samples.size(),
			"duration_ms": Time.get_ticks_msec() - started_msec,
			"warmup_seconds": warmup_seconds,
			"sample_seconds": sample_seconds,
			"sample_interval_ms": interval_ms,
			"percentile": percentile,
			"p1_fps": p1_fps,
			"p95_frame_time_ms": p95_frame_time_ms,
			"fps_min": sorted_fps[0] if not sorted_fps.is_empty() else 0.0,
			"fps_max": sorted_fps[-1] if not sorted_fps.is_empty() else 0.0,
			"fps_mean": _mean(fps_samples),
			"frame_time_ms_min": sorted_frame[0] if not sorted_frame.is_empty() else 0.0,
			"frame_time_ms_max": sorted_frame[-1] if not sorted_frame.is_empty() else 0.0,
			"frame_time_ms_mean": _mean(frame_time_samples)
		}
	}


## 最近秩（nearest-rank）分位数：取上界，宁可保守也不乐观。
static func _percentile(sorted_values: Array[float], percentile: float) -> float:
	if sorted_values.is_empty():
		return 0.0
	var rank: int = int(ceil(percentile / 100.0 * float(sorted_values.size())))
	rank = clampi(rank, 1, sorted_values.size())
	return sorted_values[rank - 1]


static func _mean(values: Array[float]) -> float:
	if values.is_empty():
		return 0.0
	var total: float = 0.0
	for value in values:
		total += value
	return total / float(values.size())

func _register_assert_no_runtime_errors(server_core: RefCounted) -> void:
	server_core.register_tool(
		"assert_no_runtime_errors",
		"Runtime-error hard gate: scan the categorized debugger output captured from the running game and fail if any error events are present. By default it inspects the 'stderr' category; pass 'categories' to widen or narrow it, and 'since_sequence' to only consider events newer than a previously recorded sequence number (so you can gate a specific window of a run). Returns passed=false with the captured error events when any are found.",
		{
			"type": "object",
			"properties": {
				"categories": {"type": "array", "description": "Output categories treated as errors. Default ['stderr'].", "items": {"type": "string"}},
				"since_sequence": {"type": "integer", "description": "Only consider events with sequence greater than this. Default 0.", "default": 0},
				"count": {"type": "integer", "description": "Maximum number of recent output events to scan. Default 500.", "default": 500}
			}
		},
		Callable(self, "_tool_assert_no_runtime_errors"),
		{"type": "object", "properties": {"passed": {"type": "boolean"}, "error_count": {"type": "integer"}, "errors": {"type": "array"}}},
		{"readOnlyHint": true, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false},
		"supplementary", "Debug-Advanced"
	)

func _tool_assert_no_runtime_errors(params: Dictionary) -> Dictionary:
	var bridge: RefCounted = _get_debugger_bridge()
	if not bridge:
		return {"error": "Debugger bridge is not available"}
	var categories: Array = []
	var categories_raw: Variant = params.get("categories", ["stderr"])
	if categories_raw is Array:
		for c in categories_raw:
			categories.append(str(c))
	if categories.is_empty():
		categories = ["stderr"]
	var since_sequence: int = int(params.get("since_sequence", 0))
	var count: int = maxi(int(params.get("count", 500)), 1)
	var output_dump: Dictionary = bridge.get_output_events(count, 0, "asc", "")
	var errors: Array = _filter_runtime_error_events(output_dump.get("events", []), since_sequence, categories)
	return {
		"passed": errors.is_empty(),
		"error_count": errors.size(),
		"errors": errors,
		"categories": categories,
		"since_sequence": since_sequence
	}

## Awaits roughly `ms` of real time by yielding editor frames, letting the
## separately-running game process advance while we wait.
func _await_real_ms(ms: int) -> void:
	var deadline_ms: int = Time.get_ticks_msec() + maxi(ms, 0)
	var tree: SceneTree = Engine.get_main_loop() as SceneTree
	while Time.get_ticks_msec() < deadline_ms:
		if tree:
			await tree.process_frame
		else:
			OS.delay_msec(16)

## Builds a params dict for a sub-tool, carrying over the shared session/timeout
## fields and applying any per-call overrides.
func _merge_runtime_params(params: Dictionary, extra: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	if params.has("session_id"):
		out["session_id"] = params["session_id"]
	if params.has("timeout_ms"):
		out["timeout_ms"] = params["timeout_ms"]
	for key in extra:
		out[key] = extra[key]
	return out

# ============================================================================
# verify_change_effect（P0-2 公共能力）：证明一次修改真的作用于正在玩的游戏
#
# "代码改了，玩起来没变化" 的四类真凶，逐项排查并给出证据：
#   1. target — 场景文件在磁盘上存在（运行入口锚定）。
#   2. entity — 节点真正使用的脚本：外部 .gd 引用 vs 场景内嵌 sub_resource
#      副本（attach_script 嵌入陷阱）；期望的外部脚本是否就是节点在跑的；
#      编辑器里是否有未保存缓冲（run_project 从磁盘启动，缓冲里的修改
#      永远到不了游戏）。
#   3. applied — FRESH 启动场景，运行时读回属性值与期望值比对。
#   4. behaved —（可选）按 play_and_verify 形状执行行为步骤+断言，证明
#      行为可测地变化；零断言的行为规格按冒烟拒绝。
#   5. persist —（默认开）第二次 FRESH 启动再读回：从磁盘加载，暴露
#      "只在内存里生效"的假象（插件内等价于外部驱动的重启编辑器层级）。
# 任一必需步骤 not_met => overall=not_effective，needs 给出精确的下一步调用。
# ============================================================================

## 单测注入点：有效时替代真实读回 / 行为编排（避免依赖编辑器与运行时）。
var _effect_readback_override: Callable = Callable()
var _effect_behavior_override: Callable = Callable()

const _EffectQueueScriptPath: String = "res://addons/godot_mcp/tools/verification_queue_tools.gd"
const ProjectToolsScript = preload("res://addons/godot_mcp/tools/project_tools_native.gd")

func _register_verify_change_effect(server_core: RefCounted) -> void:
	server_core.register_tool(
		"verify_change_effect",
		"Proof that a change actually reaches the game — the 'I edited it but nothing changed' chain, as one checklist. Resolves the node's REAL script from the scene file (external .gd reference vs an EMBEDDED copy — the classic silent killer where edits to the external file never reach the game), flags unsaved editor buffers (run_project boots the disk copy), boots the scene FRESH and reads the property back at runtime against expected_value, optionally runs behavior steps+assertions (play_and_verify shape) proving the behavior measurably moved (zero-assertion behavior specs are rejected as smoke), discovers which scenes INSTANCE this one and whether any host OVERRIDES the property on that node (running the host serves the override, masking the base value — the fix is named with the exact host scene and node), then boots once more to prove persistence (a second disk boot exposes in-memory-only illusions). Every step returns verified/not_met/skipped with evidence; overall=effective only when all non-skipped steps verified, and 'needs' names the exact next call for each failure.",
		{
			"type": "object",
			"properties": {
				"scene_path": {"type": "string", "description": "Scene file the node lives in, e.g. 'res://scenes/player.tscn'. Also the run entry for verification runs."},
				"node_path": {"type": "string", "description": "Scene-relative node path including the root, e.g. 'Player/Attack'."},
				"property": {"type": "string", "description": "Property name on that node, e.g. 'cooldown_seconds'."},
				"expected_value": {"description": "The value the change should have produced; the runtime readback is compared against it (numeric-tolerant)."},
				"script_path": {"type": "string", "description": "Optional external script the node SHOULD run (e.g. 'res://scripts/combat/melee_brain.gd'). When the scene carries an embedded copy instead, entity is not_met — attach_script + save_scene is the fix."},
				"behavior": {"type": "object", "description": "Optional {steps, assertions} in the play_and_verify shape; runs in a FRESH boot to prove the behavior measurably moved. At least one assertion required."},
				"check_persistence": {"type": "boolean", "default": true, "description": "Boot the scene a second time and read back again — proves the value comes from disk, not memory."},
				"host_scenes": {"type": "array", "items": {"type": "string"}, "description": "Optional pinned list of scenes that INSTANCE scene_path. When omitted, project .tscn files are scanned (addons/tooling excluded) to find hosts and any property override on the node."},
				"check_instance_hosts": {"type": "boolean", "default": true, "description": "Run the hosts step (discover instancing scenes and property overrides). Set false to skip the project scan when the scene is known standalone."},
				"timeout_ms": {"type": "integer", "default": 8000}
			},
			"required": ["scene_path", "node_path", "property", "expected_value"]
		},
		Callable(self, "_tool_verify_change_effect"),
		{"type": "object", "properties": {
			"status": {"type": "string"},
			"overall": {"type": "string", "description": "effective|not_effective"},
			"checklist": {"type": "array", "description": "[{step: target|entity|hosts|applied|behaved|persist, status: verified|not_met|skipped, evidence, ...}]"},
			"needs": {"type": "array", "items": {"type": "string"}},
			"resolved": {"type": "object"}}},
		{"readOnlyHint": false, "destructiveHint": false, "idempotentHint": false, "openWorldHint": true},
		"supplementary", "Debug-Advanced"
	)

func _tool_verify_change_effect(params: Dictionary) -> Dictionary:
	var scene_path: String = String(params.get("scene_path", "")).strip_edges()
	var node_path: String = String(params.get("node_path", "")).strip_edges()
	var property: String = String(params.get("property", "")).strip_edges()
	if scene_path.is_empty():
		return {"error": "scene_path is required (e.g. 'res://scenes/player.tscn')"}
	if node_path.is_empty():
		return {"error": "node_path is required (scene-relative, root included: 'Player/Attack')"}
	if property.is_empty():
		return {"error": "property is required (e.g. 'cooldown_seconds')"}
	if not property.is_valid_identifier():
		return {"error": "property '%s' is not a valid identifier — readback builds an expression from it" % property}
	if not params.has("expected_value"):
		return {"error": "expected_value is required — the value the change should have produced; the runtime readback is compared against it"}
	var expected: Variant = params["expected_value"]
	var script_path: String = String(params.get("script_path", "")).strip_edges()
	var behavior: Dictionary = params.get("behavior", {}) if params.get("behavior", {}) is Dictionary else {}
	var check_persistence: bool = bool(params.get("check_persistence", true))
	var host_scenes_pinned: Array = params.get("host_scenes", []) if params.get("host_scenes", []) is Array else []
	var timeout_ms: int = maxi(int(params.get("timeout_ms", 8000)), 1000)

	var checklist: Array = []
	var needs: Array = []
	var resolved: Dictionary = {
		"scene_path": scene_path, "node_path": node_path, "property": property,
		"expected_value": expected}

	# ---- step: target（磁盘上的场景文件存在；运行入口锚定）------------------
	var project_name: String = String(ProjectSettings.get_setting("application/config/name", ""))
	var scene_text: String = _effect_read_text(scene_path)
	if scene_text.is_empty() and not FileAccess.file_exists(scene_path):
		checklist.append({"step": "target", "status": "not_met",
			"evidence": "scene file not found: %s" % scene_path})
		needs.append("check the scene path (gather_task_context locates the scenes for a goal); instance overrides live in the INSTANCING scene, not the base scene file")
		return _effect_report(checklist, needs, resolved)
	checklist.append({"step": "target", "status": "verified",
		"evidence": "project '%s'; %s exists on disk (%d chars)" % [project_name, scene_path, scene_text.length()]})

	# ---- step: entity（节点真正使用的脚本 + 未保存缓冲风险）------------------
	var entity: Dictionary = _resolve_scene_entity(scene_text, node_path, property)
	var resolved_view: Dictionary = {}
	for key in ["found", "matched_path", "node_name", "script_mode", "script_path",
			"script_uid", "embedded_id", "embedded_extends", "has_property", "root_name"]:
		if entity.has(key):
			resolved_view[key] = entity[key]
	resolved["entity"] = resolved_view
	var entity_status: String = "verified"
	var entity_bits: Array = []
	if not bool(entity.get("found", false)):
		entity_status = "not_met"
		entity_bits.append("node '%s' not present in the scene file" % node_path)
		needs.append("node '%s' is not in %s — verify with get_scene_structure; the override may live in the scene that INSTANCES this one" % [node_path, scene_path])
	else:
		var script_mode: String = String(entity.get("script_mode", "none"))
		match script_mode:
			"external":
				var actual_script: String = String(entity.get("script_path", ""))
				if not script_path.is_empty() and script_path != actual_script:
					entity_status = "not_met"
					entity_bits.append("node runs a DIFFERENT external script: %s (expected %s)" % [actual_script, script_path])
					needs.append("the node's script is '%s', not '%s' — your edits went to a file the node never loads" % [actual_script, script_path])
				else:
					entity_bits.append("script is an external reference: %s" % actual_script)
			"embedded":
				if not script_path.is_empty():
					entity_status = "not_met"
					entity_bits.append("node runs an EMBEDDED copy (sub_resource %s, starts '%s') — edits to %s never reach the game" % [
						String(entity.get("embedded_id", "?")), String(entity.get("embedded_extends", "?")), script_path])
					needs.append("attach_script('%s', '%s') to switch the node to the external reference, then save_scene('%s')" % [node_path, script_path, scene_path])
				else:
					entity_bits.append("script is EMBEDDED in the scene (sub_resource %s) — edits to any external .gd will never reach it" % String(entity.get("embedded_id", "?")))
			_:
				if not script_path.is_empty():
					entity_status = "not_met"
					entity_bits.append("node carries no script in this scene")
					needs.append("node '%s' has no script in %s — the script may be attached in an instancing scene or missing entirely" % [node_path, scene_path])
				else:
					entity_bits.append("no script on the node (property must come from an ancestor or instance override)")
		if not bool(entity.get("has_property", false)):
			entity_bits.append("property '%s' is not serialized in the node section — its value comes from the script default or an instance override" % property)
	# 未保存缓冲：run_project 从磁盘启动，编辑器缓冲里的修改到不了游戏。
	var unsaved: Dictionary = _effect_unsaved_risk(scene_path, script_path)
	if unsaved.has("scene"):
		entity_status = "not_met"
		entity_bits.append("scene has UNSAVED editor edits")
		needs.append("save_scene('%s') — run_project boots the disk copy, unsaved editor edits never reach the game" % scene_path)
	elif unsaved.has("script"):
		entity_status = "not_met"
		entity_bits.append("script has UNSAVED editor edits")
		needs.append("save_all_scripts() — the running game loads scripts from disk")
	elif unsaved.has("unavailable"):
		entity_bits.append("unsaved-buffer check unavailable (headless)")
	checklist.append({"step": "entity", "status": entity_status,
		"evidence": "; ".join(entity_bits)})

	# ---- step: hosts（实例覆盖感知：谁实例化本场景、谁覆盖了目标属性）-------
	# 运行宿主场景时实例覆盖值胜过基场景值——直跑基场景全部通过的修改，
	# 在真实游戏里可能正被宿主覆盖挡住。这一步把"可能是实例覆盖"变成
	# 点名文件与节点的精确诊断 + 修复调用。
	var hosts_result: Dictionary
	if bool(params.get("check_instance_hosts", true)):
		hosts_result = _effect_hosts_step(scene_path, node_path, property, expected, host_scenes_pinned)
	else:
		hosts_result = {"entry": {"step": "hosts", "status": "skipped",
			"evidence": "instance-host check disabled (check_instance_hosts=false)"}}
	if hosts_result.has("hosts"):
		resolved["instance_hosts"] = hosts_result["hosts"]
	if hosts_result.has("scanned_files"):
		resolved["hosts_scanned_files"] = hosts_result["scanned_files"]
	checklist.append(hosts_result["entry"])
	for need_value in hosts_result.get("needs", []):
		needs.append(need_value)

	# ---- step: applied（FRESH 启动 + 运行时读回）-----------------------------
	var readback: Dictionary = await _effect_readback(scene_path, node_path, property, timeout_ms,
		String(resolved.get("entity", {}).get("root_name", "")) if resolved.get("entity", {}) is Dictionary else "")
	var applied_ok: bool = readback.has("value") and _values_match(readback.get("value", null), expected)
	if applied_ok:
		checklist.append({"step": "applied", "status": "verified",
			"evidence": "live value %s == expected %s (fresh boot readback)" % [str(readback.get("value", null)), str(expected)]})
	else:
		var applied_evidence: String = "readback failed: %s" % str(readback.get("error", "no value"))
		if readback.has("value"):
			applied_evidence = "live value %s != expected %s" % [str(readback.get("value", null)), str(expected)]
		checklist.append({"step": "applied", "status": "not_met", "evidence": applied_evidence,
			"live_value": readback.get("value", null)})
		needs.append("the running game does not serve the expected value — an instancing scene may override '%s', or the change was never saved; save_scene then re-run this check" % property)

	# ---- step: behaved（可选：行为可测地变化）--------------------------------
	if behavior.is_empty():
		checklist.append({"step": "behaved", "status": "skipped",
			"evidence": "no behavior spec supplied (optional)"})
	else:
		var behavior_status: String = "verified"
		var behavior_evidence: String = ""
		var steps: Array = behavior.get("steps", []) if behavior.get("steps", []) is Array else []
		var assertion_count: int = 0
		if behavior.has("assertions") and behavior.get("assertions", []) is Array:
			assertion_count += (behavior.get("assertions", []) as Array).size()
		for step_value in steps:
			if step_value is Dictionary and (step_value as Dictionary).has("assert"):
				assertion_count += 1
		if steps.is_empty() or assertion_count == 0:
			behavior_status = "not_met"
			behavior_evidence = "behavior spec carries %d steps and %d assertions — a smoke run cannot prove the change" % [steps.size(), assertion_count]
			needs.append("behavior needs at least one step and one assertion (step 'assert' or final 'assertions'); measured engine-side values are latency-immune evidence")
		else:
			var behaved: Dictionary = await _effect_behavior(behavior, scene_path, timeout_ms)
			var assertions_total: int = int(behaved.get("assertions_total", 0))
			var assertions_passed: int = int(behaved.get("assertions_passed", 0))
			if bool(behaved.get("passed", false)) and assertions_total > 0 and assertions_passed == assertions_total:
				behavior_evidence = "behavior run: %d/%d assertions passed" % [assertions_passed, assertions_total]
			else:
				behavior_status = "not_met"
				behavior_evidence = "behavior run: %s (%d/%d assertions passed) — %s" % [
					str(behaved.get("error", "assertions failed")), assertions_passed, assertions_total,
					str(behaved.get("first_failure", ""))]
				if not str(behaved.get("first_failure", "")).is_empty():
					needs.append("behavior assertion failed: %s — the change is written but the gameplay did not move" % str(behaved.get("first_failure", "")))
		checklist.append({"step": "behaved", "status": behavior_status, "evidence": behavior_evidence})

	# ---- step: persist（第二次 FRESH 启动：磁盘真相）-------------------------
	if not check_persistence:
		checklist.append({"step": "persist", "status": "skipped",
			"evidence": "persistence check disabled (check_persistence=false)"})
	else:
		var readback2: Dictionary = await _effect_readback(scene_path, node_path, property, timeout_ms,
			String(resolved.get("entity", {}).get("root_name", "")) if resolved.get("entity", {}) is Dictionary else "")
		var persist_ok: bool = readback2.has("value") and _values_match(readback2.get("value", null), expected)
		if persist_ok:
			checklist.append({"step": "persist", "status": "verified",
				"evidence": "second disk boot still serves %s — not an in-memory illusion" % str(expected)})
		else:
			checklist.append({"step": "persist", "status": "not_met",
				"evidence": "second boot readback %s != expected %s (%s)" % [str(readback2.get("value", null)), str(expected), str(readback2.get("error", "value drifted"))]})
			needs.append("the value reached the first run but not the second — the change was in-memory only; save_scene('%s') before re-running" % scene_path)

	return _effect_report(checklist, needs, resolved)

func _effect_report(checklist: Array, needs: Array, resolved: Dictionary) -> Dictionary:
	var overall: String = "effective"
	for entry_value in checklist:
		if entry_value is Dictionary and String((entry_value as Dictionary).get("status", "")) == "not_met":
			overall = "not_effective"
	return {
		"status": "success",
		"overall": overall,
		"checklist": checklist,
		"needs": needs,
		"resolved": resolved,
	}

## 读回一次运行时属性值（FRESH 启动 → 探针求值 → 停止）。真实路径复用验证
## 队列的原生编排（probe → run → 就绪等待 → play_and_verify → stop），
## 单测用 _effect_readback_override 替换。返回 {"value": v} 或 {"error": ...}。
func _effect_readback(scene_path: String, node_path: String, property: String, timeout_ms: int, root_name: String = "") -> Dictionary:
	if _effect_readback_override.is_valid():
		return await _effect_readback_override.call({
			"scene_path": scene_path, "node_path": node_path,
			"property": property, "timeout_ms": timeout_ms, "root_name": root_name})
	var expression: String = _build_readback_expression(node_path, property, root_name)
	var run: Dictionary = await _effect_queue_behavior_run({
		"scene_path": scene_path,
		"steps": [{"wait_ms": 1200}],
		"assertions": [{
			"expression": expression, "expected": null,
			"timeout_ms": timeout_ms, "description": "runtime readback"}],
	})
	if run.has("error"):
		return {"error": str(run.get("error"))}
	var evidence: Dictionary = run.get("evidence", {}) if run.get("evidence", {}) is Dictionary else {}
	var assertions: Array = evidence.get("assertions", []) if evidence.get("assertions", []) is Array else []
	if assertions.is_empty() or not (assertions[0] is Dictionary):
		return {"error": "readback produced no result: %s" % str(evidence.get("issue", "no assertions recorded"))}
	var first: Dictionary = assertions[0]
	var value: Variant = first.get("actual", null)
	if value == null:
		value = first.get("last_value", null)
	if value == null and not String(str(first.get("error", ""))).is_empty():
		return {"error": "readback expression failed: %s" % str(first.get("error"))}
	return {"value": value}

## 行为步骤编排：真实路径同样复用验证队列的原生执行器。
func _effect_behavior(behavior: Dictionary, scene_path: String, timeout_ms: int) -> Dictionary:
	if _effect_behavior_override.is_valid():
		return await _effect_behavior_override.call({
			"behavior": behavior, "scene_path": scene_path, "timeout_ms": timeout_ms})
	var detail: Dictionary = {
		"scene_path": scene_path,
		"steps": behavior.get("steps", []),
	}
	if behavior.has("assertions"):
		detail["assertions"] = behavior.get("assertions", [])
	detail["timeout_ms"] = timeout_ms
	var run: Dictionary = await _effect_queue_behavior_run(detail)
	if run.has("error"):
		return {"error": str(run.get("error"))}
	var evidence: Dictionary = run.get("evidence", {}) if run.get("evidence", {}) is Dictionary else {}
	var out: Dictionary = {
		"passed": bool(run.get("passed", false)) and int(evidence.get("assertions_total", 0)) > 0,
		"assertions_total": int(evidence.get("assertions_total", 0)),
		"assertions_passed": int(evidence.get("assertions_passed", 0)),
	}
	for assertion_value in evidence.get("assertions", []):
		if assertion_value is Dictionary and not bool((assertion_value as Dictionary).get("passed", true)):
			out["first_failure"] = String((assertion_value as Dictionary).get("description", ""))
			break
	return out

## 复用 VerificationQueueTools 的原生行为执行器（probe→run→verify→stop）。
## 优先取插件注册表里已 initialize 的实例；不可用时 load() 兜底（避免与
## verification_queue_tools.gd 的 preload 形成编译期循环引用）。
func _effect_queue_behavior_run(detail: Dictionary) -> Dictionary:
	var queue_tools: RefCounted = null
	if Engine.has_meta("GodotMCPPlugin"):
		var plugin: Variant = Engine.get_meta("GodotMCPPlugin")
		if plugin and plugin.get("_tool_instances") is Dictionary:
			var instances: Dictionary = plugin.get("_tool_instances")
			if instances.has("VerificationQueueTools") and instances["VerificationQueueTools"] is RefCounted:
				queue_tools = instances["VerificationQueueTools"]
	if queue_tools == null:
		var loaded: Resource = load(_EffectQueueScriptPath)
		if loaded is GDScript:
			queue_tools = (loaded as GDScript).new()
	if queue_tools == null:
		return {"error": "verification queue module unavailable"}
	return await queue_tools._behavior_run_impl(detail)

## 构造读回表达式：探针以 current_scene 为基点求值，一次表达式覆盖三种
## 运行时路径形态 —— 完整相对路径（被实例场景托管时）、去根路径（场景根
## 直跑时）、以及节点即根自身（self 兜底）。
## 实测铁律：Expression 类不支持三元 `x if c else y`（连 (1 if true else 2)
## 都是 parse error 31），也不支持 self。探针以 current_scene 为基点求值，
## 因此：节点即根（root_name 已知）=> 裸属性；否则 get_node('<去根相对路径>').属性。
static func _build_readback_expression(node_path: String, property: String, root_name: String = "") -> String:
	var full: String = node_path.strip_edges().trim_prefix("/").trim_suffix("/")
	if root_name != "" and full == root_name:
		return property
	var relative: String = full
	if root_name != "" and full.begins_with(root_name + "/"):
		relative = full.substr(root_name.length() + 1)
	return "get_node('%s').%s" % [relative, property]

## 数值宽容比较：浮点用 is_equal_approx（0.25 == 0.25 之类的 JSON 往返），
## 布尔精确相等，其余按字符串比较（"0.25" 与 0.25 视为相等）。
static func _values_match(a: Variant, b: Variant) -> bool:
	if a == null or b == null:
		return false
	if typeof(a) == TYPE_BOOL or typeof(b) == TYPE_BOOL:
		return bool(a) == bool(b) and typeof(a) == typeof(b)
	if (a is int or a is float) and (b is int or b is float):
		return is_equal_approx(float(a), float(b))
	return str(a) == str(b)

static func _effect_read_text(path: String) -> String:
	if not FileAccess.file_exists(path):
		return ""
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		return ""
	var content: String = file.get_as_text()
	file.close()
	return content

## 未保存缓冲风险：目标场景或目标脚本在编辑器里有未保存修改 => 命中即挡。
## 编辑器不可用（headless 单测）时返回 {unavailable: true}，不作为失败。
func _effect_unsaved_risk(scene_path: String, script_path: String) -> Dictionary:
	var editor_tools: RefCounted = null
	if Engine.has_meta("GodotMCPPlugin"):
		var plugin: Variant = Engine.get_meta("GodotMCPPlugin")
		if plugin and plugin.get("_tool_instances") is Dictionary:
			var instances: Dictionary = plugin.get("_tool_instances")
			if instances.has("EditorToolsNative") and instances["EditorToolsNative"] is RefCounted:
				editor_tools = instances["EditorToolsNative"]
	if editor_tools == null:
		return {"unavailable": true}
	var result: Dictionary = editor_tools._tool_get_unsaved_changes({})
	if result.has("error"):
		return {"unavailable": true}
	var scenes: Array = result.get("unsaved_scenes", []) if result.get("unsaved_scenes", []) is Array else []
	var scripts: Array = result.get("unsaved_scripts", []) if result.get("unsaved_scripts", []) is Array else []
	for candidate in scenes:
		if String(candidate) == scene_path:
			return {"scene": scene_path}
	for candidate in scripts:
		if not script_path.is_empty() and String(candidate) == script_path:
			return {"script": script_path}
	return {}

## hosts 步实现：发现实例化本场景的宿主，并检测宿主侧的属性覆盖。
## host_scenes_pinned 非空时只查指定宿主（省一次项目扫描）；否则收集
## res:// 下全部 .tscn（排除 addons/测试等工具目录）逐个解析。
func _effect_hosts_step(scene_path: String, node_path: String, property: String,
		expected: Variant, host_scenes_pinned: Array) -> Dictionary:
	var child_path: String = node_path.substr(node_path.find("/") + 1) if node_path.contains("/") else ""
	var candidates: Array = []
	var scanned_files: int = -1  # -1 = pinned（未扫描）
	if not host_scenes_pinned.is_empty():
		for host_value in host_scenes_pinned:
			candidates.append(String(host_value).strip_edges())
	else:
		var scene_files: Array[String] = []
		ProjectToolsScript._collect_resources("res://", [".tscn"], scene_files, false, false)
		scanned_files = scene_files.size()
		for scene_file in scene_files:
			if scene_file != scene_path:
				candidates.append(scene_file)

	var hosts: Array = []
	var masking: Array = []
	for host_value in candidates:
		var host_path: String = String(host_value)
		var host_text: String = _effect_read_text(host_path)
		if host_text.is_empty():
			continue
		var found: Dictionary = _effect_instance_overrides(host_text, scene_path, child_path, property)
		var instances: Array = found.get("instances", []) if found.get("instances", []) is Array else []
		if instances.is_empty():
			continue
		var host_entry: Dictionary = {"scene": host_path, "instances": instances}
		var overrides: Array = found.get("overrides", []) if found.get("overrides", []) is Array else []
		if not overrides.is_empty():
			host_entry["overrides"] = overrides
			for override_value in overrides:
				var override: Dictionary = override_value
				var override_parsed: Variant = str_to_var(String(override.get("value", "")))
				override["parsed_value"] = override_parsed
				if not _values_match(override_parsed, expected):
					masking.append({
						"host": host_path,
						"node": String(override.get("node", "")),
						"value": String(override.get("value", ""))})
		hosts.append(host_entry)

	var result: Dictionary = {"hosts": hosts}
	if scanned_files >= 0:
		result["scanned_files"] = scanned_files
	if hosts.is_empty():
		var skipped_evidence: String = "not instanced by any project scene"
		if scanned_files >= 0:
			skipped_evidence += " (scanned %d scene files, addons/tooling excluded)" % scanned_files
		else:
			skipped_evidence += " (none of the pinned host scenes instances it)"
		result["entry"] = {"step": "hosts", "status": "skipped", "evidence": skipped_evidence}
		return result
	if masking.is_empty():
		result["entry"] = {"step": "hosts", "status": "verified",
			"evidence": "instanced by %d scene(s); no override masks '%s' on %s" % [hosts.size(), property, node_path]}
		return result
	var mask_names: Array = []
	for mask_value in masking:
		var mask: Dictionary = mask_value
		mask_names.append("%s@%s:%s" % [String(mask.get("value", "")), String(mask.get("host", "")), String(mask.get("node", ""))])
	result["entry"] = {"step": "hosts", "status": "not_met",
		"evidence": "%d instance override(s) mask '%s' on %s: %s — running the HOST scene serves the override, not the base value" % [masking.size(), property, node_path, ", ".join(mask_names)]}
	var needs: Array = []
	for mask_value in masking:
		var mask: Dictionary = mask_value
		needs.append("the property is overridden to %s in %s at %s — running that host masks the base-scene change; update the override: batch_update_scene_files {scenes: ['%s'], edits: [{node: '%s', property: '%s', value: <wanted>, expect_current: %s}]}" % [
			String(mask.get("value", "")), String(mask.get("host", "")), String(mask.get("node", "")),
			String(mask.get("host", "")), String(mask.get("node", "")), property,
			String(mask.get("value", ""))])
	result["needs"] = needs
	return result

## 纯文本解析（可单测）：host_text 中实例化 base_scene_path 的节点段，
## 以及这些实例（或其子节点段）上对 property 的覆盖。
## child_path 为目标节点相对实例根的路径（"" 表示实例根本身）。
## 返回 {instances: [{node, path}], overrides: [{node, value}]}。
static func _effect_instance_overrides(host_text: String, base_scene_path: String,
		child_path: String, property: String) -> Dictionary:
	var out: Dictionary = {"instances": [], "overrides": []}
	var lines: PackedStringArray = host_text.split("\n")
	var ext_scenes: Dictionary = {}
	var sections: Array = []
	var root_name: String = ""
	var current: Dictionary = {}
	for i in lines.size():
		var line: String = lines[i].strip_edges()
		if line.begins_with("["):
			if not current.is_empty():
				current["end"] = i
				sections.append(current)
			current = {}
			if line.begins_with("[ext_resource"):
				var attrs: Dictionary = _parse_header_attrs(line)
				if String(attrs.get("type", "")) == "PackedScene":
					ext_scenes[String(attrs.get("id", ""))] = String(attrs.get("path", ""))
			elif line.begins_with("[node"):
				var node_attrs: Dictionary = _parse_header_attrs(line)
				current = {"attrs": node_attrs, "start": i + 1, "end": lines.size()}
				# instance=ExtResource("id") 的 id 前是 "("，键值正则匹配不到
				# ——必须从原始头部行直接提取，否则宿主实例永远识别不出。
				var instance_marker: String = "instance=ExtResource(\""
				var marker_at: int = line.find(instance_marker)
				if marker_at >= 0:
					current["instance_ext_id"] = line.substr(marker_at + instance_marker.length()).get_slice('"', 0)
				if not node_attrs.has("parent") and root_name.is_empty():
					root_name = String(node_attrs.get("name", ""))
	if not current.is_empty():
		current["end"] = lines.size()
		sections.append(current)

	# 每段的完整路径 + 实例引用解析（instance=ExtResource("id") -> 基场景）。
	var paths_by_section: Array = []
	for section_value in sections:
		var section: Dictionary = section_value
		var attrs: Dictionary = section.get("attrs", {})
		var name: String = String(attrs.get("name", ""))
		var full_path: String = name
		if attrs.has("parent"):
			var parent: String = String(attrs["parent"])
			full_path = root_name + "/" + name if parent == "." else root_name + "/" + parent + "/" + name
		var instances_base: bool = false
		var instance_ext_id: String = String(section.get("instance_ext_id", ""))
		if not instance_ext_id.is_empty():
			if String(ext_scenes.get(instance_ext_id, "")) == base_scene_path:
				instances_base = true
		paths_by_section.append({"section": section, "path": full_path, "instances_base": instances_base})

	var property_prefix: String = property + " ="
	for entry_value in paths_by_section:
		var entry: Dictionary = entry_value
		if not bool(entry.get("instances_base", false)):
			continue
		var instance_root: String = String(entry.get("path", ""))
		out["instances"].append({
			"node": instance_root.get_slice("/", instance_root.count("/")),
			"path": instance_root})
		# 覆盖目标：实例根本身（child_path 为空）或路径 == 实例根/子路径 的段。
		var wanted: String = instance_root if child_path.is_empty() else instance_root + "/" + child_path
		for candidate_value in paths_by_section:
			var candidate: Dictionary = candidate_value
			var candidate_path: String = String(candidate.get("path", ""))
			if candidate_path != wanted:
				continue
			var section: Dictionary = candidate.get("section", {})
			for i in range(int(section.get("start", 0)), int(section.get("end", 0))):
				var body_line: String = lines[i].strip_edges()
				if body_line.begins_with(property_prefix):
					out["overrides"].append({
						"node": candidate_path,
						"value": body_line.substr(property_prefix.length()).strip_edges()})
					break
	return out

# ----------------------------------------------------------------------------
# .tscn 实体解析（纯文本，可单测）：节点段 → 完整路径、脚本引用（外部 vs 内嵌）、
# 属性是否序列化。返回 {found, matched_path, node_name, script_mode, script_path,
# script_uid, embedded_id, embedded_extends, has_property, root_name}。
# ----------------------------------------------------------------------------

## 提取 GDScript sub_resource 段体的源码首行（.tscn 里源码以转义 \n 序列化）。
## 用显式传参而非 lambda 闭包：GDScript lambda 按值捕获局部变量，循环内的
## 状态变化对闭包不可见。
static func _effect_flush_sub_body(lines: PackedStringArray, start: int, end: int,
		kind: String, sub_id: String, embedded_scripts: Dictionary) -> void:
	if kind != "sub" or sub_id.is_empty() or not embedded_scripts.has(sub_id):
		return
	for i in range(start, mini(end, lines.size())):
		var body_line: String = lines[i].strip_edges()
		if body_line.begins_with("script/source = \""):
			var source: String = body_line.substr(len("script/source = \""))
			embedded_scripts[sub_id] = {
				"first_line": source.split("\\n")[0],
				"chars": source.length()}
			return

static func _resolve_scene_entity(scene_text: String, node_path: String, property: String) -> Dictionary:
	var result: Dictionary = {
		"found": false, "matched_path": "", "node_name": "",
		"script_mode": "none", "script_path": "", "script_uid": "",
		"embedded_id": "", "embedded_extends": "", "has_property": false,
		"root_name": ""}
	var lines: PackedStringArray = scene_text.split("\n")

	# 单遍扫描：ext_resource（Script）/ GDScript sub_resource 源首行 /
	# node 段（头部属性 + 段体行区间）。段体 = 本头与下一个 '[' 头之间。
	var ext_scripts: Dictionary = {}
	var embedded_scripts: Dictionary = {}
	var node_sections: Array = []
	var root_name: String = ""
	var current_kind: String = ""  # "" | "sub" | "node"
	var current_sub_id: String = ""
	var current_body_start: int = -1

	for i in lines.size():
		var line: String = lines[i].strip_edges()
		if line.begins_with("["):
			_effect_flush_sub_body(lines, current_body_start, i, current_kind,
				current_sub_id, embedded_scripts)
			current_kind = ""
			current_sub_id = ""
			current_body_start = -1
			if line.begins_with("[ext_resource"):
				var attrs: Dictionary = _parse_header_attrs(line)
				if String(attrs.get("type", "")) == "Script":
					ext_scripts[String(attrs.get("id", ""))] = {
						"path": String(attrs.get("path", "")),
						"uid": String(attrs.get("uid", ""))}
			elif line.begins_with("[sub_resource"):
				var sub_attrs: Dictionary = _parse_header_attrs(line)
				if String(sub_attrs.get("type", "")) == "GDScript":
					current_kind = "sub"
					current_sub_id = String(sub_attrs.get("id", ""))
					current_body_start = i + 1
					if not embedded_scripts.has(current_sub_id):
						embedded_scripts[current_sub_id] = {"first_line": "", "chars": 0}
			elif line.begins_with("[node"):
				var node_attrs: Dictionary = _parse_header_attrs(line)
				current_kind = "node"
				node_sections.append({"attrs": node_attrs, "start": i + 1, "end": lines.size()})
				if not node_attrs.has("parent") and root_name.is_empty():
					root_name = String(node_attrs.get("name", ""))
	_effect_flush_sub_body(lines, current_body_start, lines.size(), current_kind,
		current_sub_id, embedded_scripts)
	result["root_name"] = root_name

	# 节点完整路径：无 parent => 根；parent="." => 根/名；否则 parent/名。
	var target: String = node_path.strip_edges().trim_prefix("/").trim_suffix("/")
	var matched: Dictionary = {}
	for section_value in node_sections:
		var section: Dictionary = section_value
		var attrs: Dictionary = section.get("attrs", {})
		var name: String = String(attrs.get("name", ""))
		var full_path: String = name
		if attrs.has("parent"):
			var parent: String = String(attrs["parent"])
			full_path = root_name + "/" + name if parent == "." else root_name + "/" + parent + "/" + name
		if full_path == target:
			matched = {"section": section, "path": full_path, "by_name": false}
			break
		if matched.is_empty() and name == target:
			matched = {"section": section, "path": full_path, "by_name": true}
	if matched.is_empty():
		return result

	var section: Dictionary = matched["section"]
	var attrs: Dictionary = section.get("attrs", {})
	result["found"] = true
	result["matched_path"] = String(matched["path"])
	result["node_name"] = String(attrs.get("name", ""))
	result["matched_by_name"] = bool(matched["by_name"])
	# 段体：script 引用形态 + 目标属性是否序列化在场景里。
	var script_prefix: String = "script = "
	var property_prefix: String = property + " ="
	for i in range(int(section.get("start", 0)), int(section.get("end", 0))):
		var line: String = lines[i].strip_edges()
		if line.begins_with(script_prefix):
			var ref: String = line.substr(script_prefix.length())
			if ref.begins_with("ExtResource("):
				var id: String = ref.get_slice('"', 1)
				if ext_scripts.has(id):
					result["script_mode"] = "external"
					result["script_path"] = String(ext_scripts[id]["path"])
					result["script_uid"] = String(ext_scripts[id]["uid"])
			elif ref.begins_with("SubResource("):
				var sub_id: String = ref.get_slice('"', 1)
				result["script_mode"] = "embedded"
				result["embedded_id"] = sub_id
				if embedded_scripts.has(sub_id):
					result["embedded_extends"] = String(embedded_scripts[sub_id]["first_line"])
		if not result["has_property"] and line.begins_with(property_prefix):
			result["has_property"] = true
	return result

## 解析资源头部的属性键值对：[ext_resource type="Script" path="..." id="..."]。
static func _parse_header_attrs(header: String) -> Dictionary:
	var attrs: Dictionary = {}
	var regex: RegEx = RegEx.new()
	regex.compile("([A-Za-z_]+)=\"([^\"]*)\"")
	for m in regex.search_all(header):
		attrs[String(m.get_string(1))] = m.get_string(2)
	return attrs

# ============================================================================
# game_quality_report（M4 优质硬门槛）：一次调用跑齐质量门禁，红绿灯报告，
# 每个红灯附 needs 式精确修复。scope=static（默认，无需运行游戏）聚合项目
# 健康/未验证需求/任务图/主场景/输入映射；scope=full 额外 FRESH 启动指定
# 场景跑运行时门禁（零报错 + 平台性能画像 + 关键画面截图）。
# ============================================================================

## 平台性能画像（assert_performance_budget 预算档）。
const QUALITY_PROFILE_DESKTOP: Dictionary = {
	"min_p1_fps": 55.0, "max_p95_frame_time_ms": 20.0, "max_node_count": 20000}
const QUALITY_PROFILE_MOBILE: Dictionary = {
	"min_p1_fps": 30.0, "max_p95_frame_time_ms": 50.0, "max_node_count": 8000}

## 单测注入点：替代 full 场景的运行时门禁编排（避免依赖编辑器/运行时）。
var _quality_runtime_gates_override: Callable = Callable()

func _register_game_quality_report(server_core: RefCounted) -> void:
	server_core.register_tool(
		"game_quality_report",
		"One call runs every quality gate and returns a red/green report with a needs-style fix per red light. scope='static' (default, no game run): project health (broken scripts, missing/cyclic deps, res:// write traps), unverified delivery requirements named one by one, task-plan state, main-scene and input-map sanity. scope='full' additionally boots the scene FRESH and gates on zero runtime errors, a platform performance profile (desktop/mobile: p1 fps + p95 frame time + node budget) and a key-screen screenshot, then stops. verdict=green only when every check is green; warnings never fake green.",
		{
			"type": "object",
			"properties": {
				"scope": {"type": "string", "enum": ["static", "full"], "default": "static"},
				"scene_path": {"type": "string", "description": "full only: the scene to boot for runtime gates."},
				"platform": {"type": "string", "enum": ["desktop", "mobile"], "default": "desktop",
					"description": "full only: performance profile tier."},
				"sample_seconds": {"type": "number", "default": 2.0, "description": "full only: performance sampling window (percentiles need it)."}
			}
		},
		Callable(self, "_tool_game_quality_report"),
		{"type": "object", "properties": {
			"status": {"type": "string"},
			"scope": {"type": "string"},
			"verdict": {"type": "string", "description": "green|red"},
			"checks": {"type": "array"},
			"needs": {"type": "array", "items": {"type": "string"}}}},
		{"readOnlyHint": true, "destructiveHint": false, "idempotentHint": true, "openWorldHint": true},
		"supplementary", "Debug-Advanced"
	)

func _tool_game_quality_report(params: Dictionary) -> Dictionary:
	var scope: String = String(params.get("scope", "static"))
	if scope != "static" and scope != "full":
		return {"error": "scope must be 'static' or 'full'"}
	var scene_path: String = String(params.get("scene_path", "")).strip_edges()
	if scope == "full" and scene_path.is_empty():
		return {"error": "scope='full' requires scene_path (the scene to boot)"}
	var platform: String = "mobile" if String(params.get("platform", "desktop")) == "mobile" else "desktop"

	var checks: Array = []
	var needs: Array = []

	# ---- static 门禁 ---------------------------------------------------------
	var health: Dictionary = _quality_static_health_check()
	checks.append(health["check"])
	for need_value in health.get("needs", []):
		needs.append(need_value)

	var brief: Dictionary = _quality_brief()
	checks.append(_quality_check_unverified(brief, needs))
	checks.append(_quality_check_plan(brief, needs))
	checks.append(_quality_check_config(needs))

	# ---- full：运行时门禁（FRESH 启动 → 零报错 + 性能画像 + 截图 → 停止）----
	if scope == "full":
		if _quality_runtime_gates_override.is_valid():
			var gates: Dictionary = await _quality_runtime_gates_override.call({
				"scene_path": scene_path, "platform": platform,
				"sample_seconds": float(params.get("sample_seconds", 2.0))})
			for check_value in gates.get("checks", []):
				checks.append(check_value)
			for need_value in gates.get("needs", []):
				needs.append(need_value)
		else:
			var runtime_gates: Dictionary = await _quality_runtime_gates(
				scene_path, platform, float(params.get("sample_seconds", 2.0)))
			for check_value in runtime_gates.get("checks", []):
				checks.append(check_value)
			for need_value in runtime_gates.get("needs", []):
				needs.append(need_value)

	var verdict: String = "green"
	for check_value in checks:
		if String((check_value as Dictionary).get("status", "")) != "green":
			verdict = "red"
	return {
		"status": "success",
		"scope": scope,
		"platform": platform if scope == "full" else "",
		"verdict": verdict,
		"checks": checks,
		"needs": needs,
	}

## 项目健康门禁（组合既有审计：坏脚本/缺失依赖/循环依赖/res:// 写入）。
func _quality_static_health_check() -> Dictionary:
	var resources_tools: RefCounted = _quality_module("ProjectResourcesTools")
	if resources_tools == null or not resources_tools.has_method("_tool_audit_project_health"):
		return {"check": {"id": "project_health", "status": "red",
			"detail": "audit module unavailable"}}
	var audit: Dictionary = resources_tools._tool_audit_project_health({})
	if audit.has("error"):
		return {"check": {"id": "project_health", "status": "red",
			"detail": str(audit.get("error"))}}
	var summary: Dictionary = audit.get("summary", {}) if audit.get("summary", {}) is Dictionary else {}
	var status: String = "green"
	if String(audit.get("status", "")) == "failing":
		status = "red"
	elif String(audit.get("status", "")) == "warning":
		status = "red"  # 质量门禁不放过 warning：res:// 写入也是发布级缺陷
	var check: Dictionary = {"id": "project_health", "status": status, "detail": summary}
	var needs: Array = []
	if int(summary.get("broken_scripts", 0)) > 0:
		needs.append("%d broken scripts — run detect_broken_scripts for the exact list" % int(summary.get("broken_scripts", 0)))
	if int(summary.get("missing_dependencies", 0)) > 0:
		needs.append("%d missing resource dependencies — scan_missing_resource_dependencies names them" % int(summary.get("missing_dependencies", 0)))
	if int(summary.get("res_write_paths", 0)) > 0:
		needs.append("%d scripts write res:// (read-only after export) — save under user://" % int(summary.get("res_write_paths", 0)))
	return {"check": check, "needs": needs}

## 复用会话简报的队列/任务图读数（同源同口径，不另起炉灶）。
func _quality_brief() -> Dictionary:
	var project_tools: RefCounted = _quality_module("ProjectToolsNative")
	if project_tools != null and project_tools.has_method("_tool_get_game_project_brief"):
		return project_tools._tool_get_game_project_brief({})
	return {}

func _quality_module(class_key: String) -> RefCounted:
	if Engine.has_meta("GodotMCPPlugin"):
		var plugin: Variant = Engine.get_meta("GodotMCPPlugin")
		if plugin and plugin.get("_tool_instances") is Dictionary:
			var instances: Dictionary = plugin.get("_tool_instances")
			if instances.has(class_key) and instances[class_key] is RefCounted:
				return instances[class_key]
	return null

func _quality_check_unverified(brief: Dictionary, needs: Array) -> Dictionary:
	var verification: Array = brief.get("verification", []) if brief.get("verification", []) is Array else []
	var unverified_total: int = 0
	var first_gap: String = ""
	for entry_value in verification:
		var entry: Dictionary = entry_value
		var unverified: Array = entry.get("unverified", []) if entry.get("unverified", []) is Array else []
		unverified_total += unverified.size()
		if unverified.size() > 0 and first_gap.is_empty():
			first_gap = "'%s': %s" % [String(entry.get("goal", "")), ", ".join(unverified)]
	var status: String = "red" if unverified_total > 0 else "green"
	if unverified_total > 0:
		needs.append("close the delivery gap — %s (run_verification_queue advance)" % first_gap)
	return {"id": "unverified_requirements", "status": status,
		"detail": {"count": unverified_total}}

func _quality_check_plan(brief: Dictionary, needs: Array) -> Dictionary:
	var plan: Dictionary = brief.get("task_plan", {}) if brief.get("task_plan", {}) is Dictionary else {}
	if not bool(plan.get("exists", false)):
		needs.append("no durable task plan — plan_game_feature makes progress survive sessions")
		return {"id": "task_plan", "status": "red", "detail": {"exists": false}}
	var by_status: Dictionary = plan.get("by_status", {}) if plan.get("by_status", {}) is Dictionary else {}
	var status: String = "green"
	if int(by_status.get("blocked", 0)) > 0:
		status = "red"
		needs.append("%d blocked tasks — manage_task_plan to unblock or replan" % int(by_status.get("blocked", 0)))
	return {"id": "task_plan", "status": status, "detail": by_status}

func _quality_check_config(needs: Array) -> Dictionary:
	var main_scene: String = String(ProjectSettings.get_setting("application/run/main_scene", ""))
	var input_count: int = 0
	for setting in ProjectSettings.get_property_list():
		if String(setting.get("name", "")).begins_with("input/"):
			input_count += 1
	var status: String = "green"
	if main_scene.is_empty():
		status = "red"
		needs.append("no main scene set — set_project_setting('application/run/main_scene', <scene>)")
	if input_count == 0:
		status = "red"
		needs.append("no input actions — the input map is the first thing make_first_game builds for a reason")
	return {"id": "project_config", "status": status,
		"detail": {"main_scene": main_scene, "input_actions": input_count}}

## 运行时编排所需模块：注册表优先，load() 兜底（跨模块协作既有模式）。
func _quality_runtime_module(class_key: String, script_path: String) -> RefCounted:
	if Engine.has_meta("GodotMCPPlugin"):
		var plugin: Variant = Engine.get_meta("GodotMCPPlugin")
		if plugin and plugin.get("_tool_instances") is Dictionary:
			var instances: Dictionary = plugin.get("_tool_instances")
			if instances.has(class_key) and instances[class_key] is RefCounted:
				return instances[class_key]
	var loaded: Resource = load(script_path)
	if loaded is GDScript:
		return (loaded as GDScript).new()
	return null

## full 场景运行时门禁：探针 → FRESH 启动 → 就绪 → 零报错 + 性能画像 + 截图 → 停止。
func _quality_runtime_gates(scene_path: String, platform: String, sample_seconds: float) -> Dictionary:
	var checks: Array = []
	var needs: Array = []
	var editor_tools: RefCounted = _quality_runtime_module("EditorToolsNative",
		"res://addons/godot_mcp/tools/editor_tools_native.gd")
	var bridge_tools: RefCounted = _quality_runtime_module("DebugBridgeTools",
		"res://addons/godot_mcp/tools/debug_bridge_tools.gd")
	var runtime_tools: RefCounted = _get_runtime_tools()
	if runtime_tools == null:
		runtime_tools = _quality_runtime_module("DebugRuntimeTools",
			"res://addons/godot_mcp/tools/debug_runtime_tools.gd")

	var probe: Dictionary = await bridge_tools._tool_install_runtime_probe(
		{"node_name": "MCPRuntimeProbe", "persistent": true})
	if probe.has("error") and String(probe.get("status", "")) != "already_installed":
		checks.append({"id": "runtime_errors", "status": "red", "detail": "probe install failed: " + str(probe.get("error"))})
		return {"checks": checks, "needs": needs}
	var run: Dictionary = await editor_tools._tool_run_project({"scene_path": scene_path, "allow_window": true})
	if run.has("error") or String(run.get("status", "")) == "error":
		checks.append({"id": "runtime_errors", "status": "red",
			"detail": "run_project failed: " + str(run.get("error", run.get("game_status", "")))})
		return {"checks": checks, "needs": needs}
	# 就绪等待（与验证队列同模式）。
	var deadline_ms: int = Time.get_ticks_msec() + 20000
	var session_ready: bool = false
	while Time.get_ticks_msec() < deadline_ms:
		var sessions: Dictionary = await bridge_tools._tool_get_debugger_sessions({})
		var list: Array = sessions.get("sessions", []) if sessions.get("sessions", []) is Array else []
		for session_value in list:
			if session_value is Dictionary and bool((session_value as Dictionary).get("active", false)):
				var info: Dictionary = await runtime_tools._tool_get_runtime_info({"timeout_ms": 2000})
				if int(info.get("node_count", 0)) > 0:
					session_ready = true
				break
		if session_ready:
			break
		await Engine.get_main_loop().process_frame
	if not session_ready:
		await editor_tools._tool_stop_project({"allow_window": true})
		checks.append({"id": "runtime_errors", "status": "red", "detail": "runtime never became observable"})
		return {"checks": checks, "needs": needs}

	# 门禁 1：运行时零报错。
	var errors_gate: Dictionary = _tool_assert_no_runtime_errors({"count": 200})
	var error_count: int = int(errors_gate.get("error_count", 0))
	var error_status: String = "red" if error_count > 0 else "green"
	if error_count > 0:
		var first_error: String = ""
		var error_events: Array = errors_gate.get("errors", []) if errors_gate.get("errors", []) is Array else []
		if not error_events.is_empty() and (error_events[0] is Dictionary):
			first_error = (String((error_events[0] as Dictionary).get("message", ""))).substr(0, 120)
		needs.append("%d runtime errors — first: %s" % [error_count, first_error])
	checks.append({"id": "runtime_errors", "status": error_status, "detail": {"count": error_count}})

	# 门禁 2：平台性能画像（分位数需要采样窗口）。
	var profile: Dictionary = QUALITY_PROFILE_MOBILE if platform == "mobile" else QUALITY_PROFILE_DESKTOP
	var perf: Dictionary = await _tool_assert_performance_budget({
		"budget": profile, "sample_seconds": maxf(sample_seconds, 1.0)})
	var perf_status: String = "red" if not bool(perf.get("passed", false)) or perf.has("error") else "green"
	var perf_checks: Array = perf.get("checks", []) if perf.get("checks", []) is Array else []
	for perf_check_value in perf_checks:
		if perf_check_value is Dictionary and not bool((perf_check_value as Dictionary).get("passed", true)):
			needs.append("perf %s: actual %s vs limit %s" % [
				String((perf_check_value as Dictionary).get("metric", "")),
				str((perf_check_value as Dictionary).get("actual", "?")),
				str((perf_check_value as Dictionary).get("limit", "?"))])
	checks.append({"id": "performance", "status": perf_status,
		"detail": {"platform": platform, "budget": profile, "checks": perf_checks}})

	# 门禁 3：关键画面截图（存证，差异基线由 assert_visual_baseline 另行判定）。
	var shot: Dictionary = await runtime_tools._tool_get_runtime_screenshot({
		"save_path": "user://mcp_quality_report.%s" % ("png"),
		"format": "png"})
	var shot_status: String = "green" if not shot.has("error") else "red"
	if shot.has("error"):
		needs.append("key-screen screenshot failed: " + str(shot.get("error")))
	checks.append({"id": "key_screen", "status": shot_status,
		"detail": {"save_path": String(shot.get("save_path", ""))}})

	await editor_tools._tool_stop_project({"allow_window": true})
	return {"checks": checks, "needs": needs}

# ============================================================================
# game_quality_ladder（§8.8 WP2）：一次调用测齐 R1-R4 全部 M 项并给出天梯状态。
# R1/性能/报错/截图复用 game_quality_report full；R2 延迟由 movement hint 驱动的
# 帧定时时间线实测（轨迹首变帧）；R3/R4 的公平性/覆盖/密度等 M 项由调用方以
# behavior_check 形状供给（extra_items，按 rung 归类）；A 项一律 awaiting_review。
# rung_reached = 自下而上首个非全绿之前的最高全绿级；豁免必须带理由。
# ============================================================================

## 单测注入点：替代 ladder 的运行时测量腿（延迟 + extra_items 执行）。
var _ladder_run_override: Callable = Callable()

func _register_game_quality_ladder(server_core: RefCounted) -> void:
	server_core.register_tool(
		"game_quality_ladder",
		"One call measures every MACHINE rung of the quality ladder (R1 playable / R2 solid / R3 polished / R4 perfect) and returns the ladder state. R1 + performance + runtime errors + key screen reuse game_quality_report full. R2 input LATENCY is measured from a movement hint: a frame-timed timeline presses the action at frame 0, samples the property per frame, and the first-changed-frame IS the latency (<=3 physics frames passes). R3/R4 machine items (fairness telegraph frames, feedback coverage, density — anything timeline-measurable) come as extra_items: behavior_check details labelled with their rung. Agent-judged dimensions are returned as awaiting_review (never faked green). rung_reached is the highest rung with all items green; waivers must carry a reason.",
		{
			"type": "object",
			"properties": {
				"scene_path": {"type": "string", "description": "The scene to boot and measure."},
				"movement": {"type": "object",
					"description": "R2 latency hint: {action, node, property (default 'global_position.x'), settle_frames (default 8)}. The timeline presses action at frame 0 and samples node.property per frame."},
				"extra_items": {"type": "array", "items": {"type": "object"},
					"description": "R3/R4 machine items: [{requirement, rung: 'r3'|'r4', detail: behavior_check detail (timeline or steps shape)}]."},
				"waivers": {"type": "array", "items": {"type": "object"},
					"description": "[{rung, id, reason}] — explicitly waived items keep their rung honest instead of silently passing."},
				"platform": {"type": "string", "enum": ["desktop", "mobile"], "default": "desktop"},
				"sample_seconds": {"type": "number", "default": 1.5}
			},
			"required": ["scene_path", "movement"]
		},
		Callable(self, "_tool_game_quality_ladder"),
		{"type": "object", "properties": {
			"status": {"type": "string"},
			"rung_reached": {"type": "string", "description": "r1|r2|r3|r4"},
			"ladder": {"type": "object"},
			"needs": {"type": "array", "items": {"type": "string"}}}},
		{"readOnlyHint": true, "destructiveHint": false, "idempotentHint": true, "openWorldHint": true},
		"supplementary", "Debug-Advanced"
	)

func _tool_game_quality_ladder(params: Dictionary) -> Dictionary:
	var scene_path: String = String(params.get("scene_path", "")).strip_edges()
	if scene_path.is_empty():
		return {"error": "scene_path is required (the scene to boot and measure)"}
	var movement: Dictionary = params.get("movement", {}) if params.get("movement", {}) is Dictionary else {}
	var action: String = String(movement.get("action", "")).strip_edges()
	var node: String = String(movement.get("node", "")).strip_edges()
	if action.is_empty() or node.is_empty():
		return {"error": "movement hint requires {action, node} for the latency measurement"}
	var extra_items: Array = []
	var extras_raw: Variant = params.get("extra_items", [])
	if extras_raw is Array:
		for item_value in extras_raw:
			if item_value is Dictionary:
				extra_items.append(item_value)
	var waivers: Array = []
	var waivers_raw: Variant = params.get("waivers", [])
	if waivers_raw is Array:
		for w_value in waivers_raw:
			if w_value is Dictionary:
				waivers.append(w_value)
	var property: String = String(movement.get("property", "global_position.x"))
	var settle_frames: int = clampi(int(movement.get("settle_frames", 8)), 2, 120)
	var platform: String = "mobile" if String(params.get("platform", "desktop")) == "mobile" else "desktop"

	# ---- R1 + 性能 + 报错 + 截图：复用 full 报告 ----
	var report: Dictionary = await _tool_game_quality_report({
		"scope": "full", "scene_path": scene_path, "platform": platform,
		"sample_seconds": float(params.get("sample_seconds", 1.5))})
	if report.has("error"):
		return {"error": "quality report leg failed: " + str(report.get("error"))}
	var by_id: Dictionary = {}
	for check_value in report.get("checks", []):
		if check_value is Dictionary:
			by_id[String((check_value as Dictionary).get("id", ""))] = check_value

	# ---- R2 延迟：movement hint -> 帧定时时间线 -> 轨迹首变帧 ----
	var latency_result: Dictionary
	if _ladder_run_override.is_valid():
		latency_result = await _ladder_run_override.call({
			"kind": "latency", "scene_path": scene_path, "action": action,
			"node": node, "property": property, "settle_frames": settle_frames})
	else:
		latency_result = await _ladder_run_latency(scene_path, action, node, property, settle_frames)
	var extra_results: Array = []
	for item_value in extra_items:
		var item: Dictionary = item_value
		var detail: Dictionary = item.get("detail", {}) if item.get("detail", {}) is Dictionary else {}
		var run_result: Dictionary
		if _ladder_run_override.is_valid():
			run_result = await _ladder_run_override.call({"kind": "extra", "item": item})
		else:
			run_result = await _effect_queue_behavior_run(detail)
		extra_results.append({
			"requirement": String(item.get("requirement", "")),
			"rung": String(item.get("rung", "r3")),
			"passed": bool(run_result.get("passed", false)) and not run_result.has("error"),
			"evidence": _ladder_compact_evidence(run_result.get("evidence", {}))})

	# ---- 组装天梯 ----
	var waivers_by_key: Dictionary = {}
	for w_value in waivers:
		var w: Dictionary = w_value
		waivers_by_key["%s|%s" % [String(w.get("rung", "")), String(w.get("id", ""))]] = String(w.get("reason", ""))
	var r3_items: Array = []
	var r4_items: Array = []
	for result_value in extra_results:
		var result: Dictionary = result_value
		var key: String = "%s|%s" % [String(result.get("rung", "")), String(result.get("requirement", ""))]
		if waivers_by_key.has(key):
			result["waived"] = true
			result["waiver_reason"] = waivers_by_key[key]
		if String(result.get("rung", "r3")) == "r4":
			r4_items.append(result)
		else:
			r3_items.append(result)

	var latency_frames: int = int(latency_result.get("latency_frames", -1))
	var latency_ok: bool = latency_frames >= 1 and latency_frames <= 3
	if waivers_by_key.has("r2|input_latency"):
		latency_ok = true

	var r1_green: bool = _check_green(by_id, "project_health") and _check_green(by_id, "project_config")
	var r2_green: bool = latency_ok and _check_green(by_id, "performance")
	var r3_green: bool = _check_green(by_id, "runtime_errors") and _check_green(by_id, "key_screen") \
		and _all_ok(r3_items)
	var r4_green: bool = _all_ok(r4_items)

	var rung_reached: String = "r1"
	if r1_green:
		rung_reached = "r2"
		if r2_green:
			rung_reached = "r3"
			if r3_green:
				rung_reached = "r4"

	var needs: Array = []
	if not r1_green:
		needs.append("R1: project health/config red — fix before anything else")
	if not latency_ok and latency_frames < 1:
		needs.append("R2: latency not measurable — check the movement hint (action bound? node path?)")
	elif not latency_ok:
		needs.append("R2: input latency %d frames > 3 — faster response path needed" % latency_frames)
	if not _check_green(by_id, "performance"):
		needs.append("R2: performance below the %s profile" % platform)
	if not _check_green(by_id, "runtime_errors"):
		needs.append("R3: runtime errors present")
	for result_value in r3_items:
		if not bool((result_value as Dictionary).get("passed", false)) and not bool((result_value as Dictionary).get("waived", false)):
			needs.append("R3: %s failed" % String((result_value as Dictionary).get("requirement", "?")))
	for result_value in r4_items:
		if not bool((result_value as Dictionary).get("passed", false)) and not bool((result_value as Dictionary).get("waived", false)):
			needs.append("R4: %s failed" % String((result_value as Dictionary).get("requirement", "?")))

	return {
		"status": "success",
		"rung_reached": rung_reached,
		"ladder": {
			"r1": {"status": "green" if r1_green else "red",
				"checks": [by_id.get("project_health", {}), by_id.get("project_config", {})]},
			"r2": {"status": "green" if r2_green else "red",
				"latency_frames": latency_frames,
				"latency_threshold": 3,
				"latency_waived": waivers_by_key.has("r2|input_latency"),
				"performance": by_id.get("performance", {})},
			"r3": {"status": "green" if r3_green else "red",
				"runtime_errors": by_id.get("runtime_errors", {}),
				"key_screen": by_id.get("key_screen", {}),
				"items": r3_items},
			"r4": {"status": "green" if r4_green else "red",
				"m_items": r4_items,
				"a_items_awaiting_review": [
					{"id": "visual_coherence", "evidence": "screenshots from key_screen"},
					{"id": "first_30_seconds", "evidence": "play via timelines, screenshot every 5s, judge controls+goal clarity"},
					{"id": "balance", "evidence": "multiple runs, look for dominant strategy"},
					{"id": "stakes", "evidence": "review death cost and victory payoff"}]},
		},
		"needs": needs,
	}

## 延迟测量腿：帧定时时间线（frame0 按下）+ 每帧采样 -> 首变帧。
func _ladder_run_latency(scene_path: String, action: String, node: String,
		property: String, settle_frames: int) -> Dictionary:
	var expression: String = "get_node('%s').%s" % [node, property]
	var run: Dictionary = await _effect_queue_behavior_run({
		"scene_path": scene_path,
		"timeline": {
			"events": [{"frame": 0, "action": action, "pressed": true}],
			"settle_frames": settle_frames,
			"sample": [{"label": "p", "expression": expression}],
			"assertions": [{"label": "p", "expression": expression,
				"expected": 1, "operator": "gt",
				"description": "movement observed in the window"}]}})
	if run.has("error"):
		return {"latency_frames": -1, "issue": str(run.get("error"))}
	var evidence: Dictionary = run.get("evidence", {}) if run.get("evidence", {}) is Dictionary else {}
	var trajectory: Array = evidence.get("trajectory", []) if evidence.get("trajectory", []) is Array else []
	return {"latency_frames": ladder_latency_frames(trajectory), "passed": bool(run.get("passed", false))}

## 纯函数（可单测）：轨迹 + 标签 -> 首变帧序号（从未变化返回 -1）。
## 首样本是步前状态；样本 i 与样本 0 的差 > 0.5 视为"已变"。
static func ladder_latency_frames(trajectory: Array) -> int:
	if trajectory.is_empty():
		return -1
	var first_value: Variant = null
	for entry_value in trajectory:
		if entry_value is Dictionary and (entry_value as Dictionary).get("values", {}) is Dictionary:
			var values: Dictionary = (entry_value as Dictionary).get("values", {})
			if values.has("p"):
				first_value = values["p"]
				break
	if first_value == null or not (first_value is float or first_value is int):
		return -1
	var base: float = float(first_value)
	for entry_value in trajectory:
		if not (entry_value is Dictionary):
			continue
		var values: Dictionary = (entry_value as Dictionary).get("values", {}) if (entry_value as Dictionary).get("values", {}) is Dictionary else {}
		if not values.has("p"):
			continue
		if absf(float(values["p"]) - base) > 0.5:
			return int((entry_value as Dictionary).get("frame_index", 0))
	return -1

static func _ladder_compact_evidence(evidence: Dictionary) -> Dictionary:
	var compact: Dictionary = {
		"evidence_level": String(evidence.get("evidence_level", "")),
		"assertions_passed": int(evidence.get("assertions_passed", 0)),
		"assertions_total": int(evidence.get("assertions_total", 0))}
	return compact

static func _check_green(by_id: Dictionary, id: String) -> bool:
	return by_id.has(id) and String((by_id.get(id) as Dictionary).get("status", "")) == "green"

static func _all_ok(items: Array) -> bool:
	for item_value in items:
		if not (bool((item_value as Dictionary).get("passed", false)) or bool((item_value as Dictionary).get("waived", false))):
			return false
	return true
