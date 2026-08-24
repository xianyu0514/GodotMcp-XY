extends "res://addons/gut/test.gd"

const MetaToolsScript = preload("res://addons/godot_mcp/tools/meta_tools_native.gd")
const ClassifierScript = preload("res://addons/godot_mcp/native_mcp/mcp_tool_classifier.gd")

# Minimal stand-in for MCPServerCore exposing only what the meta tools touch.
class FakeServerCore:
	extends RefCounted
	var tools: Dictionary = {}
	var classifier = null
	var notified: int = 0
	var bulk_apply_calls: int = 0
	var catalog_revision: int = 7
	var registry_revision: int = 0

	func _init() -> void:
		classifier = ClassifierScript.new()

	func seed(name: String, enabled: bool, category: String, group: String, description: String) -> void:
		tools[name] = {
			"name": name,
			"enabled": enabled,
			"category": category,
			"group": group,
			"description": description,
			"input_schema": {"type": "object", "properties": {"demo": {"type": "string"}}},
			"output_schema": {"type": "object", "properties": {"result": {"type": "string"}}},
			"annotations": {"readOnlyHint": true, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false}
		}
		registry_revision += 1

	func get_tool(name: String):
		return tools.get(name, null)

	func get_registered_tools() -> Array:
		var out: Array = []
		for n in tools:
			out.append({
				"name": n,
				"enabled": tools[n]["enabled"],
				"category": tools[n]["category"],
				"group": tools[n]["group"],
				"description": tools[n]["description"]
			})
		return out

	func set_tool_enabled(name: String, enabled: bool) -> void:
		if tools.has(name):
			tools[name]["enabled"] = enabled

	func set_group_enabled(group: String, enabled: bool) -> int:
		var changed: int = 0
		for n in tools:
			if tools[n]["group"] == group and tools[n]["enabled"] != enabled:
				tools[n]["enabled"] = enabled
				changed += 1
		return changed

	func apply_tool_states(states: Dictionary) -> Dictionary:
		bulk_apply_calls += 1
		var changed_tools: Array[String] = []
		var unknown_tools: Array[String] = []
		var names: Array = states.keys()
		names.sort()
		for name_value in names:
			var name: String = String(name_value)
			if not tools.has(name):
				unknown_tools.append(name)
				continue
			var target: bool = bool(states[name])
			if classifier.is_meta_tool(name):
				target = true
			if tools[name]["enabled"] == target:
				continue
			tools[name]["enabled"] = target
			changed_tools.append(name)
		if not changed_tools.is_empty():
			catalog_revision += 1
		return {
			"changed_count": changed_tools.size(),
			"changed_tools": changed_tools,
			"unknown_tools": unknown_tools,
			"catalog_revision": catalog_revision
		}

	func get_tool_catalog_revision() -> int:
		return catalog_revision

	func get_tool_registry_revision() -> int:
		return registry_revision

	func notify_tool_list_changed() -> void:
		notified += 1

	func get_classifier():
		return classifier

	func is_enabled(name: String) -> bool:
		return tools.has(name) and tools[name]["enabled"]

var _tool = null
var _core = null

func before_each():
	_tool = MetaToolsScript.new()
	_core = FakeServerCore.new()
	# A small but representative registry: core, meta, and supplementary tools.
	_core.seed("create_node", true, "core", "Node-Write", "Create a node.")
	_core.seed("list_tool_catalog", true, "meta", "Meta", "List the registered tools.")
	_core.seed("enable_tools", true, "meta", "Meta", "Enable or disable tools.")
	_core.seed("search_tools", true, "meta", "Meta", "Search the registered tools by keywords. Returns matching tool names.")
	_core.seed("get_tool_details", true, "meta", "Meta", "Get the full schema details of a single tool.")
	_core.seed("get_runtime_info", false, "supplementary", "Debug-Advanced", "Get runtime info from the running game. Returns fps and node count.")
	_core.seed("run_export", false, "supplementary", "Project-Advanced", "Run an export preset.")
	_tool._server_core = _core

func after_each():
	_tool = null
	_core = null

# --- list_tool_catalog ---

func test_catalog_lists_groups_and_counts():
	var result: Dictionary = _tool._tool_list_tool_catalog({})
	assert_has(result, "groups", "Catalog should return a groups map")
	assert_eq(result.get("total_registered", 0), 7, "Should report 7 registered tools")
	assert_eq(result.get("enabled_count", 0), 5, "create_node + 4 meta tools are enabled")
	assert_true(result["groups"].has("Debug-Advanced"), "Groups should include Debug-Advanced")

func test_catalog_group_filter():
	var result: Dictionary = _tool._tool_list_tool_catalog({"group": "Debug-Advanced"})
	assert_eq(result.get("total_matched", -1), 1, "Only one tool is in Debug-Advanced")
	assert_true(result["groups"].has("Debug-Advanced"), "Filtered group should be present")
	assert_false(result["groups"].has("Node-Write"), "Non-matching group should be excluded")

func test_catalog_enabled_only_filter():
	var result: Dictionary = _tool._tool_list_tool_catalog({"enabled_only": true})
	assert_false(result["groups"].has("Debug-Advanced"), "Disabled tool's group should be excluded")
	assert_true(result["groups"].has("Node-Write"), "Enabled core tool group should remain")

func test_catalog_truncates_long_description():
	var result: Dictionary = _tool._tool_list_tool_catalog({"group": "Debug-Advanced"})
	var entry: Dictionary = result["groups"]["Debug-Advanced"]["tools"][0]
	assert_true(entry["description"].length() <= 141, "Description should be trimmed to a short summary")

func test_catalog_summary_only_omits_per_tool_payloads():
	var result: Dictionary = _tool._tool_list_tool_catalog({"summary_only": true})
	assert_eq(result.get("total_matched", -1), 7, "Summary still counts every matching tool")
	assert_eq(result.get("groups", {}).get("Debug-Advanced", {}).get("total", -1), 1,
		"Summary retains group counts")
	assert_false(result.get("groups", {}).get("Debug-Advanced", {}).has("tools"),
		"Summary mode must omit per-tool arrays to minimize tokens")

func test_catalog_output_is_deterministic():
	var first: Dictionary = _tool._tool_list_tool_catalog({})
	var second: Dictionary = _tool._tool_list_tool_catalog({})
	assert_eq(first.get("groups", {}).keys(), second.get("groups", {}).keys(),
		"Repeated catalog calls must preserve group order for prompt caching")
	for group_name in first.get("groups", {}):
		var first_names: Array = []
		for entry in first["groups"][group_name].get("tools", []):
			first_names.append(entry.get("name", ""))
		var sorted_names: Array = first_names.duplicate()
		sorted_names.sort()
		assert_eq(first_names, sorted_names, "Tools inside each group must be sorted by name")

func test_catalog_known_revision_returns_minimal_not_modified_response():
	var result: Dictionary = _tool._tool_list_tool_catalog({"known_revision": 7})
	assert_eq(result, {"not_modified": true, "catalog_revision": 7},
		"A matching revision should avoid retransmitting the unchanged catalog")

func test_catalog_reports_compact_workflow_coverage():
	var result: Dictionary = _tool._tool_list_tool_catalog({"summary_only": true})
	var coverage: Dictionary = result.get("workflow_coverage", {})
	assert_eq(coverage.get("total_atomic", -1), 3,
		"Only non-meta tools count as workflow-routable atomic capabilities")
	assert_eq(coverage.get("coverage_ratio", 0.0), 1.0,
		"Adaptive routing covers every registered atomic tool")
	assert_false(coverage.has("tools"), "Coverage summary must not copy the tool catalog")

# --- enable_tools ---

func test_enable_tools_by_name():
	var result: Dictionary = _tool._tool_enable_tools({"tools": ["get_runtime_info"]})
	assert_eq(result.get("status", ""), "success", "Should succeed")
	assert_true(_core.is_enabled("get_runtime_info"), "Requested tool should be enabled")
	assert_eq(_core.notified, 1, "Should emit a tools/list_changed notification")
	assert_eq(_core.bulk_apply_calls, 1, "One request should use one bulk state transition")
	assert_eq(result.get("changed_tools", []), ["get_runtime_info"], "Response reports only changed tools")
	assert_false(result.has("enabled_tools"), "Compact response omits the full enabled list by default")

func test_enable_tools_can_include_full_enabled_list_on_request():
	var result: Dictionary = _tool._tool_enable_tools({
		"tools": ["get_runtime_info"],
		"include_enabled_tools": true
	})
	assert_true(result.has("enabled_tools"), "Full enabled list remains available for compatibility")
	assert_true("get_runtime_info" in result.get("enabled_tools", []), "Requested tool appears in full list")

func test_enable_tools_noop_does_not_notify():
	var result: Dictionary = _tool._tool_enable_tools({"tools": ["create_node"]})
	assert_eq(result.get("changed_count", -1), 0, "Already-enabled tools produce a no-op")
	assert_eq(_core.notified, 0, "No-op requests should not make clients reload tools/list")

func test_enable_tools_by_group():
	_tool._tool_enable_tools({"groups": ["Debug-Advanced"]})
	assert_true(_core.is_enabled("get_runtime_info"), "Group enable should turn on Debug-Advanced tools")

func test_disable_tools_by_name():
	_core.set_tool_enabled("get_runtime_info", true)
	_tool._tool_enable_tools({"tools": ["get_runtime_info"], "enabled": false})
	assert_false(_core.is_enabled("get_runtime_info"), "Tool should be disabled")

func test_exclusive_resets_to_core_plus_requested():
	_core.set_tool_enabled("run_export", true)
	_tool._tool_enable_tools({"groups": ["Debug-Advanced"], "exclusive": true})
	assert_true(_core.is_enabled("create_node"), "Core tool stays enabled in exclusive mode")
	assert_true(_core.is_enabled("get_runtime_info"), "Requested group is enabled")
	assert_false(_core.is_enabled("run_export"), "Unrelated supplementary tool is reset to disabled")

func test_meta_tools_cannot_be_disabled():
	_tool._tool_enable_tools({"tools": ["enable_tools", "list_tool_catalog"], "enabled": false})
	assert_true(_core.is_enabled("enable_tools"), "Meta enable_tools must stay enabled")
	assert_true(_core.is_enabled("list_tool_catalog"), "Meta list_tool_catalog must stay enabled")

func test_enable_tools_reports_unknown():
	var result: Dictionary = _tool._tool_enable_tools({"tools": ["ghost_tool"], "groups": ["Ghost-Group"]})
	assert_true("ghost_tool" in result.get("unknown_tools", []), "Unknown tool should be reported")
	assert_true("Ghost-Group" in result.get("unknown_groups", []), "Unknown group should be reported")

func test_enable_tools_applies_preset():
	_core.set_tool_enabled("get_runtime_info", true)
	_core.set_tool_enabled("run_export", true)
	var result: Dictionary = _tool._tool_enable_tools({"preset": "minimal_core"})
	assert_eq(result.get("applied_preset", ""), "minimal_core", "Preset name should be echoed back")
	assert_true(_core.is_enabled("create_node"), "Core tool enabled by minimal_core")
	assert_true(_core.is_enabled("enable_tools"), "Meta tool stays enabled under minimal_core")
	assert_false(_core.is_enabled("get_runtime_info"), "Supplementary tool disabled by minimal_core")
	assert_false(_core.is_enabled("run_export"), "Supplementary tool disabled by minimal_core")
	assert_eq(_core.bulk_apply_calls, 1, "A preset should apply all states in one batch")

func test_enable_tools_rejects_unknown_preset():
	var result: Dictionary = _tool._tool_enable_tools({"preset": "does_not_exist"})
	assert_has(result, "error", "Unknown preset should return an error")

func test_enable_tools_activates_exact_workflow_and_replaces_old_task_tools():
	_core.set_tool_enabled("run_export", true)
	var result: Dictionary = _tool._tool_enable_tools({"workflow_query": "get_runtime_info"})
	assert_eq(result.get("status", ""), "success", "A workflow intent activates in one call")
	assert_true(_core.is_enabled("get_runtime_info"), "The routed atomic tool becomes visible")
	assert_false(_core.is_enabled("run_export"), "Unrelated supplementary residue is removed by default")
	assert_true(_core.is_enabled("create_node"), "Core tools remain visible")
	assert_eq(result.get("workflow", {}).get("tool_count", 0), 1,
		"Exact atomic intent keeps the activated surface minimal")
	assert_eq(result.get("workflow_query", ""), "get_runtime_info", "The normalized task intent is echoed")
	assert_true(result.get("replaced_supplementary", false), "Response makes replacement semantics explicit")
	assert_eq(_core.bulk_apply_calls, 1, "Activation and stale-tool cleanup share one atomic transition")
	assert_eq(result.get("catalog_revision", 0), 8, "A multi-tool transition advances the catalog only once")
	assert_eq(_core.notified, 1, "The client receives one tools/list_changed notification")

func test_enable_tools_workflow_can_preserve_enabled_supplementary_tools():
	_core.set_tool_enabled("run_export", true)
	var result: Dictionary = _tool._tool_enable_tools({
		"workflow_query": "get_runtime_info",
		"replace_supplementary": false
	})
	assert_true(_core.is_enabled("get_runtime_info"), "The routed tool is enabled")
	assert_true(_core.is_enabled("run_export"), "Incremental mode preserves an earlier task tool")
	assert_false(result.get("replaced_supplementary", true), "Response reports incremental activation")
	assert_eq(_core.bulk_apply_calls, 1, "Incremental activation remains one bulk transition")

func test_enable_tools_repeated_workflow_keeps_catalog_revision_stable():
	_tool._tool_enable_tools({"workflow_query": "get_runtime_info"})
	var first_revision: int = _core.catalog_revision
	var repeated: Dictionary = _tool._tool_enable_tools({"workflow_query": "get_runtime_info"})
	assert_eq(repeated.get("changed_count", -1), 0, "The same task profile becomes a no-op")
	assert_eq(repeated.get("catalog_revision", 0), first_revision,
		"A repeated task must preserve the tools/list cache key")
	assert_eq(_core.notified, 1, "Only the first activation should refresh client schemas")
	var diagnostics: Dictionary = _tool._workflow_router.get_diagnostics()
	assert_eq(diagnostics.get("route_computations", -1), 1,
		"Repeated workflow activation must reuse the route computation")
	assert_eq(diagnostics.get("route_cache_hits", -1), 1,
		"Visibility changes must preserve the immutable workflow route cache")

func test_enable_tools_workflow_rejects_blank_intent():
	var result: Dictionary = _tool._tool_enable_tools({"workflow_query": "   "})
	assert_has(result, "error", "An explicitly blank workflow intent must fail closed")
	assert_eq(_core.bulk_apply_calls, 0, "Invalid intent must not mutate the catalog")

func test_enable_tools_workflow_rejects_conflicting_manual_selectors():
	var result: Dictionary = _tool._tool_enable_tools({
		"workflow_query": "get_runtime_info",
		"tools": ["run_export"]
	})
	assert_has(result, "error", "Automatic and manual selection cannot silently override each other")
	assert_eq(_core.bulk_apply_calls, 0, "Conflicting selection must not mutate the catalog")

# --- search_tools ---

func test_search_tools_requires_query():
	var result: Dictionary = _tool._tool_search_tools({})
	assert_has(result, "error", "Missing query is rejected")
	var result_blank: Dictionary = _tool._tool_search_tools({"query": "   "})
	assert_has(result_blank, "error", "Blank query is rejected")

func test_search_tools_multi_keyword_and():
	var result: Dictionary = _tool._tool_search_tools({"query": "runtime info"})
	assert_eq(result.get("total_matched", -1), 1, "Both keywords must match the same tool (AND)")
	var tools: Array = result.get("tools", [])
	assert_eq(tools.size(), 1, "One tool matches 'runtime info'")
	assert_eq(tools[0].get("name"), "get_runtime_info", "get_runtime_info matches both keywords")
	assert_eq(tools[0].get("group"), "Debug-Advanced", "Match carries its group")
	assert_eq(tools[0].get("category"), "supplementary", "Match carries its category")
	assert_eq(tools[0].get("enabled"), false, "Match carries its enabled state")
	assert_true(tools[0].has("description"), "Description included by default")

func test_search_tools_and_requires_all_keywords():
	var result: Dictionary = _tool._tool_search_tools({"query": "runtime export"})
	assert_eq(result.get("total_matched", -1), 0, "No single tool contains both keywords")

func test_search_tools_group_filter():
	var result: Dictionary = _tool._tool_search_tools({"query": "runtime", "group": "Debug-Advanced"})
	assert_eq(result.get("total_matched", -1), 1, "Group filter narrows to Debug-Advanced")
	var filtered: Dictionary = _tool._tool_search_tools({"query": "runtime", "group": "Project-Advanced"})
	assert_eq(filtered.get("total_matched", -1), 0, "No runtime match in Project-Advanced")

func test_search_tools_limit_truncates():
	var result: Dictionary = _tool._tool_search_tools({"query": "the", "limit": 2})
	assert_eq(result.get("total_matched", -1), 4, "total_matched reports all matches before truncation")
	assert_eq(result.get("tools", []).size(), 2, "limit caps the returned list")

func test_search_tools_enabled_only():
	var result: Dictionary = _tool._tool_search_tools({"query": "export"})
	assert_eq(result.get("total_matched", -1), 1, "run_export matches 'export'")
	var enabled_only: Dictionary = _tool._tool_search_tools({"query": "export", "enabled_only": true})
	assert_eq(enabled_only.get("total_matched", -1), 0, "Disabled run_export is excluded by enabled_only")

func test_search_tools_omit_descriptions():
	var result: Dictionary = _tool._tool_search_tools({"query": "runtime", "include_descriptions": false})
	var tools: Array = result.get("tools", [])
	assert_eq(tools.size(), 1, "Match still found")
	assert_false(tools[0].has("description"), "Description omitted when include_descriptions=false")

func test_search_tools_supports_chinese_intent_aliases():
	var result: Dictionary = _tool._tool_search_tools({"query": "运行时 信息"})
	assert_eq(result.get("total_matched", -1), 1, "Chinese intent terms should match English tool metadata")
	assert_eq(result.get("tools", [])[0].get("name", ""), "get_runtime_info",
		"Chinese runtime/info query should find get_runtime_info")
	assert_true(result.get("tools", [])[0].get("score", 0) > 0, "Ranked results expose a relevance score")
	var natural_result: Dictionary = _tool._tool_search_tools({"query": "查询运行时信息"})
	assert_eq(natural_result.get("tools", [])[0].get("name", ""), "get_runtime_info",
		"Chinese aliases should also be extracted from an unspaced natural phrase")

func test_search_tools_ranks_exact_normalized_name_first():
	_core.seed("inspect_runtime_info", false, "supplementary", "Debug-Advanced",
		"Inspect runtime info and diagnostics.")
	var result: Dictionary = _tool._tool_search_tools({"query": "get runtime info"})
	assert_eq(result.get("tools", [])[0].get("name", ""), "get_runtime_info",
		"An exact normalized tool name should outrank a description-only match")

func test_search_tools_clamps_large_limit():
	for index in range(60):
		_core.seed("demo_tool_%02d" % index, false, "supplementary", "Project-Advanced",
			"Demo utility for catalog limit testing.")
	var result: Dictionary = _tool._tool_search_tools({"query": "demo", "limit": 999})
	assert_eq(result.get("total_matched", -1), 60, "Full match count remains visible")
	assert_eq(result.get("tools", []).size(), 50, "Returned results are hard-capped to protect context")

func test_search_tools_workflow_mode_returns_only_bounded_stages():
	_core.seed("run_project", true, "core", "Editor", "Run the game project.")
	_core.seed("assert_no_runtime_errors", false, "supplementary", "Debug-Advanced",
		"Verify the running game has no runtime errors.")
	var result: Dictionary = _tool._tool_search_tools({
		"query": "创建 2D 游戏角色并验证运行",
		"mode": "workflow",
		"workflow_tool_budget": 3
	})
	assert_false(result.has("tools"), "Workflow mode avoids duplicating ranked tool entries")
	var workflow: Dictionary = result.get("workflow", {})
	assert_lte(workflow.get("tool_count", 99), 3, "Workflow respects the requested context budget")
	var routed_names: Array = []
	for stage in workflow.get("stages", []):
		routed_names.append_array(stage.get("tools", []))
	assert_true("run_project" in routed_names,
		"Multi-step run intent includes the executable run tool")

func test_search_tools_workflow_respects_enabled_only_filter():
	_core.seed("run_project", true, "core", "Editor", "Run the game project.")
	_core.seed("assert_no_runtime_errors", false, "supplementary", "Debug-Advanced",
		"Verify the running game has no runtime errors.")
	var result: Dictionary = _tool._tool_search_tools({
		"query": "创建 2D 游戏角色并验证运行",
		"mode": "workflow",
		"enabled_only": true
	})
	for stage in result.get("workflow", {}).get("stages", []):
		for tool_name in stage.get("tools", []):
			assert_true(_core.is_enabled(String(tool_name)),
				"enabled_only workflow must not reintroduce a filtered curated seed")

func test_search_tools_rejects_unknown_mode():
	var result: Dictionary = _tool._tool_search_tools({"query": "runtime", "mode": "huge_catalog"})
	assert_has(result, "error", "Unknown discovery modes are rejected instead of returning a large payload")

# --- get_tool_details ---

func test_get_tool_details_requires_name():
	var result: Dictionary = _tool._tool_get_tool_details({})
	assert_has(result, "error", "Missing name is rejected")

func test_get_tool_details_returns_full_schema():
	var result: Dictionary = _tool._tool_get_tool_details({"name": "get_runtime_info"})
	assert_eq(result.get("found"), true, "Registered tool is found")
	assert_eq(result.get("name"), "get_runtime_info", "Name echoed back")
	assert_eq(result.get("category"), "supplementary", "Category reported")
	assert_eq(result.get("group"), "Debug-Advanced", "Group reported")
	assert_eq(result.get("enabled"), false, "Enabled state reported")
	assert_true(result.has("description"), "Full description returned")
	assert_true(result.has("inputSchema"), "inputSchema returned")
	assert_true(result["inputSchema"].has("properties"), "inputSchema carries properties")
	assert_true(result.has("outputSchema"), "outputSchema returned")
	assert_true(result.has("annotations"), "annotations returned")

func test_get_tool_details_missing_returns_not_found():
	var result: Dictionary = _tool._tool_get_tool_details({"name": "ghost_tool"})
	assert_eq(result.get("found"), false, "Unknown tool reports found=false")
	assert_has(result, "hint", "Not-found response suggests how to search")
	assert_true(str(result.get("hint", "")).contains("list_tool_catalog"), "Hint points to the catalog")
