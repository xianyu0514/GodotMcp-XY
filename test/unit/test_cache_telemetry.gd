extends "res://addons/gut/test.gd"

# 缓存持续量化（内部测试计数器）回归测试。
#
# 不新增 MCP 工具：所有计数经 mcp_server_core.get_cache_diagnostics() 与
# workflow_router.get_diagnostics() 暴露，供单元测试直接断言。覆盖六个核心
# 计数器 —— hit / miss / eviction / stale / single-flight / oversized-reject，
# 以及验收目标：重复只读命中率、大小写空白等价路线命中率、分页单次扫描、
# spill 复用率、无关写保留率、内存上限、失效不返回陈旧数据。

const CORE_SCRIPT = preload("res://addons/godot_mcp/native_mcp/mcp_server_core.gd")
const ROUTER_SCRIPT = preload("res://addons/godot_mcp/native_mcp/workflow_router.gd")

var _core = null
var _calls: Dictionary = {}


func before_each() -> void:
	_core = CORE_SCRIPT.new()
	_calls = {}


func after_each() -> void:
	_core = null


func _read_handler(args: Dictionary) -> Dictionary:
	var key: String = str(args.get("key", args.get("script_path", "default")))
	_calls[key] = int(_calls.get(key, 0)) + 1
	return {"key": key, "calls": _calls[key]}


func _write_handler(_args: Dictionary) -> Dictionary:
	return {"status": "success"}


func _register_read(name: String, group: String = "Project") -> void:
	_core.register_tool(name, "Read", {"type": "object"}, Callable(self, "_read_handler"), {},
		MCPTypes.MCPTool.create_annotations(true, false, true, false), "core", group)


func _register_write(name: String, group: String) -> void:
	_core.register_tool(name, "Write", {"type": "object"}, Callable(self, "_write_handler"), {},
		MCPTypes.MCPTool.create_annotations(false, false, true, false), "core", group)


func _register_plain(name: String, category: String = "core", group: String = "") -> void:
	_core.register_tool(name, "Tool " + name, {"type": "object"}, func(_args): return {"ok": true},
		{}, {}, category, group)


func _call(name: String, args: Dictionary = {}) -> Dictionary:
	return {
		"jsonrpc": "2.0", "id": 1, "method": "tools/call",
		"params": {"name": name, "arguments": args}
	}


func _result_text(response: Dictionary) -> Dictionary:
	var text: String = str(response.get("result", {}).get("content", [{}])[0].get("text", "{}"))
	var parsed: Variant = JSON.parse_string(text)
	return parsed if parsed is Dictionary else {}


# ============================================================================
# 计数器语义
# ============================================================================

func test_result_cache_hit_and_miss_counters() -> void:
	_register_read("get_scene_structure", "Scene")
	_core.reset_cache_diagnostics()
	await _core._handle_tool_call(_call("get_scene_structure", {"key": "hot"}))
	await _core._handle_tool_call(_call("get_scene_structure", {"key": "hot"}))
	var diag: Dictionary = _core.get_cache_diagnostics()["result_cache"]
	assert_eq(diag.get("misses", -1), 1, "First call must be a miss")
	assert_eq(diag.get("hits", -1), 1, "Repeat call must be a hit")
	assert_eq(diag.get("entries", -1), 1, "One distinct entry stays resident")


func test_repeated_read_only_calls_hit_100pct_after_first() -> void:
	_register_read("get_scene_structure", "Scene")
	_core.reset_cache_diagnostics()
	for _index in range(10):
		await _core._handle_tool_call(_call("get_scene_structure", {"key": "hot"}))
	var diag: Dictionary = _core.get_cache_diagnostics()["result_cache"]
	assert_eq(_calls.get("hot", 0), 1, "Handler must execute exactly once")
	assert_eq(diag.get("misses", -1), 1, "Only the first call misses")
	assert_eq(diag.get("hits", -1), 9, "Every call after the first must hit")
	assert_true(abs(float(diag.get("hit_rate", 0.0)) - 0.9) < 0.0001,
		"Overall hit rate covers the one priming miss; post-first rate is 9/9 = 100%")


func test_tool_list_cache_hit_and_miss_counters() -> void:
	_register_plain("zeta_tool")
	_register_plain("alpha_tool")
	_core.reset_cache_diagnostics()
	_core._handle_tools_list({"id": 1, "method": "tools/list"})
	_core._handle_tools_list({"id": 2, "method": "tools/list"})
	var diag: Dictionary = _core.get_cache_diagnostics()["tool_list_cache"]
	assert_eq(diag.get("misses", -1), 1, "First tools/list rebuilds the definition cache")
	assert_eq(diag.get("hits", -1), 1, "Unchanged tools/list reuses the sorted cache")
	_register_plain("beta_tool")
	_core._handle_tools_list({"id": 3, "method": "tools/list"})
	diag = _core.get_cache_diagnostics()["tool_list_cache"]
	assert_eq(diag.get("misses", -1), 2, "Registration invalidates the definition cache")


func test_eviction_counter_increments_on_lru_capacity() -> void:
	_register_read("get_scene_structure", "Scene")
	_core.reset_cache_diagnostics()
	for index in range(_core.RESULT_CACHE_MAX + 5):
		await _core._handle_tool_call(_call("get_scene_structure", {"key": "k-%d" % index}))
	var diag: Dictionary = _core.get_cache_diagnostics()["result_cache"]
	assert_eq(diag.get("evictions", -1), 5, "Five insertions beyond capacity evict five LRU tails")
	assert_lte(diag.get("entries", 999999), _core.RESULT_CACHE_MAX, "Entries stay hard-capped")


func test_stale_counter_on_revision_invalidation_and_no_stale_return() -> void:
	_register_read("get_scene_structure", "Scene")
	_register_write("create_node", "Node-Write")
	await _core._handle_tool_call(_call("get_scene_structure", {"key": "s"}))
	await _core._handle_tool_call(_call("get_scene_structure", {"key": "s"}))
	assert_eq(_calls.get("s", 0), 1, "Repeat read is cached before mutation")
	_core.reset_cache_diagnostics()
	await _core._handle_tool_call(_call("create_node"))
	var response: Dictionary = await _core._handle_tool_call(_call("get_scene_structure", {"key": "s"}))
	var diag: Dictionary = _core.get_cache_diagnostics()["result_cache"]
	assert_eq(diag.get("stale_evictions", -1), 1, "Lazy invalidation drops exactly one stale entry")
	assert_eq(diag.get("misses", -1), 1, "Stale entry is recomputed, never served")
	assert_eq(_calls.get("s", 0), 2, "Handler recomputes after the mutation")
	assert_eq(int(_result_text(response).get("calls", -1)), 2, "Response carries fresh data, not the stale payload")


func test_stale_counter_on_ttl_expiry() -> void:
	_register_read("get_scene_structure", "Scene")
	await _core._handle_tool_call(_call("get_scene_structure", {"key": "ttl"}))
	var cache_key: String = "get_scene_structure:" + _core._canonical_json({"key": "ttl"})
	_core._result_cache[cache_key]["last_access"] = Time.get_ticks_msec() - _core.RESULT_CACHE_TTL_MS - 1000
	_core.reset_cache_diagnostics()
	await _core._handle_tool_call(_call("get_scene_structure", {"key": "ttl"}))
	var diag: Dictionary = _core.get_cache_diagnostics()["result_cache"]
	assert_eq(diag.get("stale_evictions", -1), 1, "TTL expiry drops the entry as stale")
	assert_eq(diag.get("misses", -1), 1, "Expired entry recomputes")
	assert_eq(_calls.get("ttl", 0), 2, "No stale payload is served after TTL expiry")


func test_single_flight_merges_concurrent_duplicate() -> void:
	var execution_count: Array = [0]
	_core.register_tool("get_scene_structure", "Slow scene read", {"type": "object"},
		func(_args):
			execution_count[0] += 1
			await get_tree().process_frame
			return {"value": execution_count[0]},
		{}, MCPTypes.MCPTool.create_annotations(true, false, true, false), "core", "Scene")
	var msg: Dictionary = _call("get_scene_structure", {"key": "slow"})
	var results: Array = [{}, {}]
	var first: Callable = func(): results[0] = await _core._handle_tool_call(msg)
	var second: Callable = func(): results[1] = await _core._handle_tool_call(msg)
	_core.reset_cache_diagnostics()
	first.call()
	second.call()
	for _index in range(4):
		await get_tree().process_frame
	var diag: Dictionary = _core.get_cache_diagnostics()["result_cache"]
	assert_eq(execution_count[0], 1, "Concurrent duplicates must share one handler execution")
	assert_eq(diag.get("single_flight_serves", -1), 1, "In-flight twin serve is counted separately")
	assert_eq(diag.get("misses", -1), 1, "Only the first twin is a real miss")
	assert_eq(diag.get("hits", -1), 0, "Single-flight serve is distinct from a sequential hit")
	assert_eq(JSON.stringify(results[0]), JSON.stringify(results[1]), "Both callers get the identical payload")


# ============================================================================
# 分页扫描快照
# ============================================================================

func test_pagination_n_pages_run_one_full_scan() -> void:
	var scans: Array = [0]
	var producer: Callable = func() -> Dictionary:
		scans[0] += 1
		return {"items": range(0, 300), "scan": scans[0]}
	_core.reset_cache_diagnostics()
	for _page in range(5):
		var snapshot: Dictionary = _core.get_or_compute_read_snapshot(
			"list_project_resources", {"search_path": "res://"}, producer)
		assert_eq(int(snapshot.get("scan", -1)), 1, "Every page view sees the same snapshot")
	var diag: Dictionary = _core.get_cache_diagnostics()["read_snapshot_cache"]
	assert_eq(scans[0], 1, "N pages must run exactly one full scan")
	assert_eq(diag.get("misses", -1), 1, "Snapshot miss runs the producer once")
	assert_eq(diag.get("hits", -1), 4, "Remaining page views hit the retained snapshot")


func test_oversized_snapshot_counted_and_never_retained() -> void:
	var scans: Array = [0]
	var oversized_payload: String = "x".repeat(_core.READ_SNAPSHOT_MAX_BYTES)
	var producer: Callable = func() -> Dictionary:
		scans[0] += 1
		return {"payload": oversized_payload, "scan": scans[0]}
	_core.reset_cache_diagnostics()
	var first: Dictionary = _core.get_or_compute_read_snapshot(
		"list_project_resources", {"search_path": "res://big"}, producer)
	var second: Dictionary = _core.get_or_compute_read_snapshot(
		"list_project_resources", {"search_path": "res://big"}, producer)
	assert_eq(String(first.get("payload", "")).length(), _core.READ_SNAPSHOT_MAX_BYTES,
		"Oversized result is still returned fully usable")
	assert_eq(String(second.get("payload", "")).length(), _core.READ_SNAPSHOT_MAX_BYTES,
		"Oversized follow-up is recomputed instead of truncated")
	var diag: Dictionary = _core.get_cache_diagnostics()["read_snapshot_cache"]
	assert_eq(diag.get("oversized_rejects", -1), 2, "Each oversized attempt is counted as a reject")
	assert_eq(diag.get("misses", -1), 2, "Oversized snapshots are not retained")
	assert_eq(diag.get("hits", -1), 0, "No in-memory hit for a rejected snapshot")
	assert_eq(diag.get("entries", -1), 0, "Rejected snapshot never occupies the LRU")


# ============================================================================
# spill 复用
# ============================================================================

func test_identical_large_result_reuses_spill_file_100pct() -> void:
	var big_value: Dictionary = {"items": []}
	for index in range(1400):
		big_value["items"].append({"index": index, "payload": "y".repeat(40)})
	_core.register_tool("big_result_tool", "Big result", {"type": "object"},
		func(_args): return big_value,
		{}, {"readOnlyHint": true})
	_core.reset_cache_diagnostics()
	var first_response: Dictionary = await _core._handle_tool_call(_call("big_result_tool"))
	var second_response: Dictionary = await _core._handle_tool_call(_call("big_result_tool"))
	var diag: Dictionary = _core.get_cache_diagnostics()["spill"]
	assert_eq(diag.get("writes", -1), 1, "First identical spill writes one immutable file")
	assert_eq(diag.get("reuses", -1), 1, "Second identical spill reuses the content-addressed file")
	assert_true(abs(float(diag.get("reuse_rate", 0.0)) - 1.0) < 0.0001,
		"After the priming write, identical content reuses 100%")
	var first_uri: String = str(_result_text(first_response).get("resource_uri", ""))
	var second_uri: String = str(_result_text(second_response).get("resource_uri", ""))
	assert_eq(first_uri, second_uri, "Identical content shares one deterministic resource URI")
	var path: String = str(_result_text(first_response).get("path", ""))
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)


# ============================================================================
# 无关写保留率与内存上限
# ============================================================================

func test_unrelated_write_preserves_read_only_cache_retention() -> void:
	_register_read("get_scene_structure", "Scene")
	_register_write("set_project_setting", "Project-Advanced")
	for index in range(10):
		await _core._handle_tool_call(_call("get_scene_structure", {"key": "scene-%d" % index}))
	var entries_before: int = _core._result_cache.size()
	await _core._handle_tool_call(_call("set_project_setting"))
	var entries_after: int = _core._result_cache.size()
	assert_eq(entries_before, 10, "All ten read entries are primed")
	assert_eq(entries_after, 10, "An unrelated project-setting write must not evict scene reads")
	assert_gte(float(entries_after) / float(max(1, entries_before)), 0.9,
		"Unrelated writes keep at least 90% of read-only cache entries resident")
	_core.reset_cache_diagnostics()
	for index in range(10):
		await _core._handle_tool_call(_call("get_scene_structure", {"key": "scene-%d" % index}))
	var diag: Dictionary = _core.get_cache_diagnostics()["result_cache"]
	assert_eq(diag.get("hits", -1), 10, "Preserved entries still serve hits")
	assert_eq(diag.get("misses", -1), 0, "No recomputation after an unrelated write")


func test_cache_memory_stays_within_fixed_bounds() -> void:
	_register_read("get_scene_structure", "Scene")
	for index in range(_core.RESULT_CACHE_MAX + 5):
		await _core._handle_tool_call(_call("get_scene_structure", {"key": "m-%d" % index}))
	var diag: Dictionary = _core.get_cache_diagnostics()["result_cache"]
	assert_lte(_core._result_cache.size(), _core.RESULT_CACHE_MAX, "Value map is hard-capped")
	assert_lte(_core._result_cache_order.size(), _core.RESULT_CACHE_MAX, "LRU order is hard-capped")
	assert_lte(int(diag.get("entries", 999999)), int(diag.get("capacity", 0)), "Diagnostics mirror the cap")
	# 扫描快照有独立更小的预算，不能随分页请求无限增长。
	for index in range(_core.READ_SNAPSHOT_CACHE_MAX + 3):
		_core.get_or_compute_read_snapshot(
			"list_project_resources", {"search_path": "res://s-%d" % index},
			func() -> Dictionary: return {"resources": []})
	var snapshot_entries: int = 0
	for key_value in _core._result_cache:
		if _core._is_read_snapshot_cache_key(String(key_value)):
			snapshot_entries += 1
	assert_lte(snapshot_entries, _core.READ_SNAPSHOT_CACHE_MAX, "Snapshot cache is hard-capped")


# ============================================================================
# 路线缓存（大小写/空白等价命中）
# ============================================================================

func test_route_cache_case_and_whitespace_equivalence_hits_100pct() -> void:
	var router: RefCounted = ROUTER_SCRIPT.new()
	var catalog: Array = [
		{"name": "get_editor_logs", "description": "Read editor debug logs.", "schema_tokens": 128,
			"enabled": true, "category": "core", "group": "Debug"},
		{"name": "get_scene_structure", "description": "Read scene structure.", "schema_tokens": 128,
			"enabled": true, "category": "core", "group": "Scene"}
	]
	router.reset_diagnostics()
	var first: Dictionary = router.route("get_editor_logs", catalog, 1, 7, {})
	var second: Dictionary = router.route("  GET_EDITOR_LOGS\t ", catalog, 1, 7, {})
	assert_eq(first, second, "Case/whitespace variants share the normalized route key")
	var diag: Dictionary = router.get_diagnostics()
	assert_eq(diag.get("route_cache_misses", -1), 1, "Only the first variant computes the route")
	assert_eq(diag.get("route_cache_hits", -1), 1, "Case/whitespace variant hits the route cache")
	assert_eq(diag.get("route_computations", -1), 1, "Repeated route avoids recomputation")


func test_route_cache_eviction_counter_and_hard_cap() -> void:
	var router: RefCounted = ROUTER_SCRIPT.new()
	var catalog: Array = [
		{"name": "get_scene_structure", "description": "Read scene structure.", "schema_tokens": 128,
			"enabled": true, "category": "core", "group": "Scene"}
	]
	router.reset_diagnostics()
	for index in range(router.ROUTE_CACHE_MAX + 10):
		router.route("unique route %d" % index, catalog, 1, 7, {})
	var diag: Dictionary = router.get_diagnostics()
	assert_lte(int(diag.get("route_cache_entries", 999999)), int(diag.get("route_cache_capacity", 0)),
		"Route LRU is hard-capped")
	assert_eq(diag.get("route_cache_evictions", -1), 10, "Ten insertions beyond capacity evict ten oldest routes")
