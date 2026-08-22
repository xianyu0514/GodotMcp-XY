extends "res://addons/gut/test.gd"

const MetaToolsScript = preload("res://addons/godot_mcp/tools/meta_tools_native.gd")
const ClassifierScript = preload("res://addons/godot_mcp/native_mcp/mcp_tool_classifier.gd")

# Minimal stand-in for MCPServerCore exposing only what the meta tools touch.
class FakeServerCore:
	extends RefCounted
	var tools: Dictionary = {}
	var classifier = null
	var notified: int = 0

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

	func get_tool(name: String):
		return tools.get(name, null)

	func get_registered_tools() -> Array:
		var out: Array = []
		for n in tools:
			var annotations: Dictionary = tools[n].get("annotations", {})
			out.append({
				"name": n,
				"enabled": tools[n]["enabled"],
				"category": tools[n]["category"],
				"group": tools[n]["group"],
				"description": tools[n]["description"],
				"readOnlyHint": bool(annotations.get("readOnlyHint", false)),
				"destructiveHint": bool(annotations.get("destructiveHint", false)),
				"idempotentHint": bool(annotations.get("idempotentHint", false)),
				"openWorldHint": bool(annotations.get("openWorldHint", false))
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

func test_catalog_entries_carry_annotation_flags():
	var result: Dictionary = _tool._tool_list_tool_catalog({"group": "Debug-Advanced"})
	var entry: Dictionary = result["groups"]["Debug-Advanced"]["tools"][0]
	assert_eq(entry.get("readOnlyHint", false), true, "Catalog entry should carry readOnlyHint")
	assert_eq(entry.get("destructiveHint", true), false, "Catalog entry should carry destructiveHint")
	assert_eq(entry.get("idempotentHint", false), true, "Catalog entry should carry idempotentHint")
	assert_has(entry, "openWorldHint", "Catalog entry should carry openWorldHint")

func test_catalog_enabled_only_filter():
	var result: Dictionary = _tool._tool_list_tool_catalog({"enabled_only": true})
	assert_false(result["groups"].has("Debug-Advanced"), "Disabled tool's group should be excluded")
	assert_true(result["groups"].has("Node-Write"), "Enabled core tool group should remain")

func test_catalog_truncates_long_description():
	var result: Dictionary = _tool._tool_list_tool_catalog({"group": "Debug-Advanced"})
	var entry: Dictionary = result["groups"]["Debug-Advanced"]["tools"][0]
	assert_true(entry["description"].length() <= 141, "Description should be trimmed to a short summary")

# --- enable_tools ---

func test_enable_tools_by_name():
	var result: Dictionary = _tool._tool_enable_tools({"tools": ["get_runtime_info"]})
	assert_eq(result.get("status", ""), "success", "Should succeed")
	assert_true(_core.is_enabled("get_runtime_info"), "Requested tool should be enabled")
	assert_eq(_core.notified, 1, "Should emit a tools/list_changed notification")

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

func test_enable_tools_rejects_unknown_preset():
	var result: Dictionary = _tool._tool_enable_tools({"preset": "does_not_exist"})
	assert_has(result, "error", "Unknown preset should return an error")

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


func test_search_tools_results_carry_annotation_flags():
	var result: Dictionary = _tool._tool_search_tools({"query": "runtime info"})
	var tools: Array = result.get("tools", [])
	assert_eq(tools.size(), 1, "Expected exactly one match")
	assert_eq(tools[0].get("readOnlyHint", false), true, "Search result should carry readOnlyHint")
	assert_eq(tools[0].get("destructiveHint", true), false, "Search result should carry destructiveHint")
	assert_eq(tools[0].get("idempotentHint", false), true, "Search result should carry idempotentHint")
	assert_has(tools[0], "openWorldHint", "Search result should carry openWorldHint")
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
