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
		"Drive the running game through scripted input steps and runtime assertions into one pass/fail report. Steps send input actions/events with optional waits and screenshots; assertions check runtime expressions, optionally vs expected. deterministic=true frame-steps waits exactly in-game and 'sample' builds a trajectory with per-label metrics. Captured runtime errors fail by default. Requires the game running with the runtime probe installed.",
		{
			"type": "object",
			"properties": {
				"steps": {
					"type": "array",
					"description": "Ordered input steps.",
					"items": {"type": "object"}
				},
				"assertions": {
					"type": "array",
					"description": "Runtime expression checks.",
					"items": {"type": "object"}
				},
				"deterministic": {"type": "boolean", "default": false, "description": "Frame-step waits in-game."},
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

	for i in steps.size():
		# 客户端取消检查：每一步都检查，取消则中止编排并返回 cancelled。
		if _tool_cancelled():
			return {"status": "cancelled", "error": "cancelled by client", "steps_executed": executed}
		var step: Dictionary = steps[i] if steps[i] is Dictionary else {}
		if step.has("action"):
			var input_params: Dictionary = _merge_runtime_params(params, {
				"action_name": String(step.get("action", "")),
				"pressed": bool(step.get("pressed", true))
			})
			if step.has("strength"):
				input_params["strength"] = float(step["strength"])
			var action_result: Dictionary = await _get_runtime_tools()._tool_simulate_runtime_input_action(input_params)
			if action_result.has("error"):
				errors.append({"step": i, "phase": "input", "error": action_result["error"]})
		elif step.has("event"):
			var event_params: Dictionary = _merge_runtime_params(params, {"event": step["event"]})
			var event_result: Dictionary = await _get_runtime_tools()._tool_simulate_runtime_input_event(event_params)
			if event_result.has("error"):
				errors.append({"step": i, "phase": "input", "error": event_result["error"]})

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

	var assertion_results: Array = []
	var passed_count: int = 0
	for i in assertions.size():
		# 断言阶段也可能耗时（每个断言都要轮询运行时探针），同样响应取消。
		if _tool_cancelled():
			return {"status": "cancelled", "error": "cancelled by client", "steps_executed": executed, "assertions_total": i, "assertions_passed": passed_count}
		var spec: Dictionary = assertions[i] if assertions[i] is Dictionary else {}
		if spec.has("metric"):
			var metric_result: Dictionary = _evaluate_metric_assertion(spec, metrics)
			metric_result["index"] = i
			if bool(metric_result.get("passed", false)):
				passed_count += 1
			assertion_results.append(metric_result)
			continue
		var expression: String = String(spec.get("expression", "")).strip_edges()
		if expression.is_empty():
			assertion_results.append({"index": i, "passed": false, "error": "Missing 'expression' (or 'metric')"})
			continue
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
		if passed:
			passed_count += 1
		assertion_results.append({
			"index": i,
			"description": assert_params["description"],
			"expression": expression,
			"passed": passed,
			"expected": assert_result.get("expected", null),
			"actual": assert_result.get("actual", null),
			"last_value": assert_result.get("last_value", null),
			"error": assert_result.get("error", null)
		})

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
		"Performance budget gate: capture a runtime performance snapshot from the running game and check it against a budget, returning a pass/fail verdict plus a per-metric breakdown. Budget keys: min_fps, max_frame_time_ms, max_physics_frame_time_ms, max_object_count, max_resource_count, max_rendered_objects, max_memory_mb, max_node_count, min_p1_fps, max_p95_frame_time_ms (define only the ones to enforce; the two percentile keys require sampling). min_* checks actual >= limit; max_* checks actual <= limit. Set sample_seconds > 0 to sample over a window after warmup_seconds and gate on percentile metrics instead of a single instantaneous reading. Pass an explicit 'snapshot' object to evaluate a previously captured snapshot instead of querying the game. Requires the game to be running with the runtime probe installed (unless 'snapshot' is supplied).",
		{
			"type": "object",
			"properties": {
				"budget": {"type": "object", "description": "Threshold map; see tool description for valid keys."},
				"snapshot": {"type": "object", "description": "Optional pre-captured performance snapshot to evaluate instead of querying the game."},
				"warmup_seconds": {"type": "number", "description": "Seconds to wait before sampling, so shader compilation and first-frame hitches are excluded. Only used when sample_seconds > 0.", "default": 0},
				"sample_seconds": {"type": "number", "description": "Seconds to sample. 0 (default) means a single instantaneous snapshot. Greater than 0 enables percentile metrics (p1_fps, p95_frame_time_ms).", "default": 0},
				"sample_interval_ms": {"type": "integer", "description": "Delay between samples in milliseconds. Default 100. Only used when sample_seconds > 0.", "default": 100},
				"percentile": {"type": "number", "description": "Percentile used for the tail metrics: p1_fps uses (100 - percentile), p95_frame_time_ms uses percentile. Default 95.", "default": 95},
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
