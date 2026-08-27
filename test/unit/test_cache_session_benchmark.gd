extends "res://addons/gut/test.gd"

# Deterministic offline replay of a representative Agent session. The trace
# crosses inspect -> edit -> run -> debug -> verify and measures every cache
# layer without starting an editor, adding an MCP tool, or changing tool schemas.

const CORE_SCRIPT = preload("res://addons/godot_mcp/native_mcp/mcp_server_core.gd")
const ROUTER_SCRIPT = preload("res://addons/godot_mcp/native_mcp/workflow_router.gd")
const TRACE_PATH: String = "res://test/unit/fixtures/cache_session_trace.json"

var _core = null
var _handler_calls: Dictionary = {}


func before_each() -> void:
	_core = CORE_SCRIPT.new()
	_handler_calls = {}


func after_each() -> void:
	_core = null


func _load_trace() -> Dictionary:
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(TRACE_PATH))
	return parsed if parsed is Dictionary else {}


func _read_handler(arguments: Dictionary) -> Dictionary:
	var key: String = String(arguments.get("key", arguments.get("script_path", "read")))
	_handler_calls[key] = int(_handler_calls.get(key, 0)) + 1
	return {"key": key, "version": _handler_calls[key]}


func _write_handler(_arguments: Dictionary) -> Dictionary:
	return {"status": "success"}


func _call(tool_name: String, arguments: Dictionary = {}) -> Dictionary:
	return {
		"jsonrpc": "2.0",
		"id": 1,
		"method": "tools/call",
		"params": {"name": tool_name, "arguments": arguments}
	}


func _register_trace_tools(trace: Dictionary) -> Array:
	var catalog: Array = []
	var registered: Dictionary = {}
	for operation_value in trace.get("operations", []):
		var operation: Dictionary = operation_value
		var tool_name: String = String(operation.get("tool", ""))
		if tool_name.is_empty() or registered.has(tool_name):
			continue
		registered[tool_name] = true
		var is_read: bool = String(operation.get("kind", "")) == "read"
		var annotations: Dictionary = MCPTypes.MCPTool.create_annotations(
			is_read, not is_read, true, false)
		var handler: Callable = Callable(self, "_read_handler") if is_read else Callable(self, "_write_handler")
		_core.register_tool(tool_name, "Trace capability " + tool_name,
			{"type": "object"}, handler, {}, annotations, "core",
			String(operation.get("group", "")))
		catalog.append({
			"name": tool_name,
			"description": "Trace capability " + tool_name,
			"schema_tokens": 128,
			"enabled": true,
			"category": "core",
			"group": String(operation.get("group", ""))
		})
	return catalog


func _operation_arguments(operation: Dictionary) -> Dictionary:
	var arguments: Dictionary = {}
	for key_value in operation:
		var key: String = String(key_value)
		if key not in ["kind", "tool", "group", "repeat"]:
			arguments[key] = operation[key_value]
	return arguments


func test_real_session_trace_meets_cache_efficiency_gate() -> void:
	var trace: Dictionary = _load_trace()
	assert_false(trace.is_empty(), "The real-session trace fixture must parse")
	var catalog: Array = _register_trace_tools(trace)
	var router: RefCounted = ROUTER_SCRIPT.new()
	_core.reset_cache_diagnostics()
	router.reset_diagnostics()

	# A real client requests tools/list as its task changes and commonly repeats a
	# normalized goal while planning or retrying the same phase.
	var request_id: int = 100
	for phase_value in trace.get("phases", []):
		var phase: Dictionary = phase_value
		_core._handle_tools_list({"id": request_id, "method": "tools/list"})
		request_id += 1
		router.route(String(phase.get("goal", "")), catalog, 8, 17, {})
		router.route(String(phase.get("repeat_goal", "")), catalog, 8, 17, {})

	for operation_value in trace.get("operations", []):
		var operation: Dictionary = operation_value
		var repeat_count: int = int(operation.get("repeat", 1))
		for _repeat_index in range(repeat_count):
			await _core._handle_tool_call(_call(
				String(operation.get("tool", "")), _operation_arguments(operation)))

	# Five resource-list pages share one full scan snapshot.
	var scan_count: Array = [0]
	var producer: Callable = func() -> Dictionary:
		scan_count[0] += 1
		return {"resources": range(0, 500), "scan": scan_count[0]}
	for _page in range(5):
		_core.get_or_compute_read_snapshot(
			"list_project_resources", {"search_path": "res://"}, producer)

	# One large immutable result is written once and reused on its repeat.
	var spill_bytes: PackedByteArray = JSON.stringify({"payload": "s".repeat(60000)}).to_utf8_buffer()
	var spill_sha: String = _core._hash_bytes(spill_bytes)
	var spill_path: String = _core.SPILL_OUTPUT_DIR + "/" + spill_sha + ".json"
	if FileAccess.file_exists(spill_path):
		DirAccess.remove_absolute(spill_path)
	_core._spill_result_to_disk(spill_bytes, spill_sha)
	_core._spill_result_to_disk(spill_bytes, spill_sha)

	var cache_diag: Dictionary = _core.get_cache_diagnostics()
	var result_diag: Dictionary = cache_diag.get("result_cache", {})
	var tool_list_diag: Dictionary = cache_diag.get("tool_list_cache", {})
	var snapshot_diag: Dictionary = cache_diag.get("read_snapshot_cache", {})
	var spill_diag: Dictionary = cache_diag.get("spill", {})
	var route_diag: Dictionary = router.get_diagnostics()
	var thresholds: Dictionary = trace.get("thresholds", {})

	assert_eq(int(_handler_calls.get("scene", 0)), 1,
		"Script editing must preserve the unrelated scene read")
	assert_eq(int(_handler_calls.get("project", 0)), 1,
		"Editor-only run and script edits must preserve project-info reads")
	assert_eq(int(_handler_calls.get("script", 0)), 2,
		"The modified script is recomputed exactly once and never served stale")
	assert_eq(int(result_diag.get("stale_evictions", -1)), 1,
		"Only the related script entry becomes stale")
	assert_eq(scan_count[0], 1, "Five pages perform one resource scan")
	assert_gte(float(result_diag.get("reuse_rate", 0.0)),
		float(thresholds.get("minimum_result_reuse_rate", 1.0)))
	assert_gte(float(route_diag.get("route_cache_hit_rate", 0.0)),
		float(thresholds.get("minimum_route_hit_rate", 1.0)))
	assert_gte(float(tool_list_diag.get("hit_rate", 0.0)),
		float(thresholds.get("minimum_tool_list_hit_rate", 1.0)))
	assert_gte(float(snapshot_diag.get("hit_rate", 0.0)),
		float(thresholds.get("minimum_snapshot_hit_rate", 1.0)))
	assert_gte(float(spill_diag.get("reuse_rate", 0.0)),
		float(thresholds.get("minimum_spill_reuse_rate", 1.0)))
	assert_lte(int(result_diag.get("bytes", 999999999)),
		int(result_diag.get("capacity_bytes", 0)), "Session cache stays within its byte budget")

	print("[CacheSession] trace=%s result_reuse=%.2f%% route_hit=%.2f%% tools_hit=%.2f%% snapshot_hit=%.2f%% spill_reuse=%.2f%% handler_exec=%d" % [
		String(trace.get("name", "unnamed")),
		float(result_diag.get("reuse_rate", 0.0)) * 100.0,
		float(route_diag.get("route_cache_hit_rate", 0.0)) * 100.0,
		float(tool_list_diag.get("hit_rate", 0.0)) * 100.0,
		float(snapshot_diag.get("hit_rate", 0.0)) * 100.0,
		float(spill_diag.get("reuse_rate", 0.0)) * 100.0,
		int(result_diag.get("handler_executions", -1))])

	if FileAccess.file_exists(spill_path):
		DirAccess.remove_absolute(spill_path)
