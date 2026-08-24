# meta_tools_native.gd - Meta tools for on-demand tool discovery & activation
#
# 这些是"始终在线"的元工具（category = "meta"），即使切到 minimal_core 预设也不会被隐藏。
# 目的：让模型平时只暴露「核心 + 目录工具」，需要更多能力时先用 list_tool_catalog 查目录，
# 再用 enable_tools 动态启用对应工具/分组/预设，从而显著降低 tools/list 的 token 开销。

@tool
class_name MetaToolsNative
extends RefCounted

const PRESET_MANAGER_PATH: String = "res://addons/godot_mcp/native_mcp/mcp_tool_preset_manager.gd"
const WorkflowRouterScript = preload("res://addons/godot_mcp/native_mcp/workflow_router.gd")
const SEARCH_LIMIT_DEFAULT: int = 12
const SEARCH_LIMIT_MAX: int = 50

var _server_core: RefCounted = null
var _preset_manager: RefCounted = null
var _workflow_router: RefCounted = WorkflowRouterScript.new()

func initialize(_editor_interface: EditorInterface) -> void:
	pass

func register_tools(server_core: RefCounted) -> void:
	_server_core = server_core
	_register_list_tool_catalog(server_core)
	_register_search_tools(server_core)
	_register_get_tool_details(server_core)
	_register_enable_tools(server_core)

func _get_preset_manager() -> RefCounted:
	if _preset_manager == null:
		_preset_manager = load(PRESET_MANAGER_PATH).new()
	return _preset_manager

func _get_classifier() -> RefCounted:
	if _server_core and _server_core.has_method("get_classifier"):
		return _server_core.get_classifier()
	return null

## Trim a tool description down to a compact, single-line summary so the catalog
## stays token-cheap. Keeps the first sentence (up to max_len characters).
func _short_description(description: String, max_len: int = 140) -> String:
	var text: String = description.strip_edges().replace("\n", " ")
	var dot: int = text.find(". ")
	if dot != -1 and dot + 1 <= max_len:
		return text.substr(0, dot + 1)
	if text.length() > max_len:
		return text.substr(0, max_len).strip_edges() + "…"
	return text

func _get_catalog_revision() -> int:
	if _server_core and _server_core.has_method("get_tool_catalog_revision"):
		return int(_server_core.get_tool_catalog_revision())
	return 0

func _sorted_registered_tools() -> Array:
	var registered: Array = _server_core.get_registered_tools()
	registered.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return String(a.get("name", "")) < String(b.get("name", ""))
	)
	return registered

func _normalize_search_text(value: String) -> String:
	return _workflow_router.normalize_search_text(value)

func _build_query_terms(query_raw: String) -> Array:
	return _workflow_router.build_query_terms(query_raw)

## BM25 would be unnecessary overhead for a 221-item in-memory catalog. This
## weighted lexical scorer captures the useful ordering properties with one
## cheap scan and deterministic tie-breaking.
func _score_tool_match(info: Dictionary, query_raw: String, terms: Array) -> int:
	return _workflow_router.score_tool_match(info, query_raw, terms)

# ============================================================================
# list_tool_catalog
# ============================================================================

func _register_list_tool_catalog(server_core: RefCounted) -> void:
	server_core.register_tool(
		"list_tool_catalog",
		"Browse registered MCP tool groups without loading every schema. Start with summary_only=true for token-cheap group counts; for a task lookup prefer search_tools. Filter by group/query for per-tool entries, and send a previous catalog_revision as known_revision to receive a minimal not_modified response when nothing changed.",
		{
			"type": "object",
			"properties": {
				"group": {"type": "string", "description": "Filter to a single classifier group (e.g. 'Debug-Advanced'). Omit to list all groups."},
				"query": {"type": "string", "description": "Case-insensitive substring filter over tool name and description."},
				"enabled_only": {"type": "boolean", "default": false, "description": "Only include tools that are currently enabled (already visible in tools/list)."},
				"include_descriptions": {"type": "boolean", "default": true, "description": "Include a short one-line description per tool. Set false for an even more compact name-only listing."},
				"summary_only": {"type": "boolean", "default": false, "description": "Return only deterministic group counts and omit all per-tool arrays. Use this first when browsing the catalog to minimize tokens."},
				"known_revision": {"type": "integer", "description": "A catalog_revision returned by an earlier call. When unchanged, the server returns only not_modified=true and the revision."}
			}
		},
		Callable(self, "_tool_list_tool_catalog"),
		{"type": "object", "properties": {"groups": {"type": "object"}, "presets": {"type": "array"}, "total_registered": {"type": "integer"}, "total_matched": {"type": "integer"}, "enabled_count": {"type": "integer"}, "catalog_revision": {"type": "integer"}, "not_modified": {"type": "boolean"}, "workflow_coverage": {"type": "object"}}},
		{"readOnlyHint": true, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false},
		"meta", "Meta"
	)

func _tool_list_tool_catalog(params: Dictionary) -> Dictionary:
	if _server_core == null or not _server_core.has_method("get_registered_tools"):
		return {"error": "Server core is not available"}

	var group_filter: String = String(params.get("group", "")).strip_edges()
	var query: String = String(params.get("query", "")).strip_edges().to_lower()
	var enabled_only: bool = bool(params.get("enabled_only", false))
	var include_descriptions: bool = bool(params.get("include_descriptions", true))
	var summary_only: bool = bool(params.get("summary_only", false))
	var catalog_revision: int = _get_catalog_revision()
	var known_revision: int = int(params.get("known_revision", -1))
	if known_revision >= 0 and known_revision == catalog_revision:
		return {"not_modified": true, "catalog_revision": catalog_revision}

	var registered: Array = _sorted_registered_tools()
	var groups: Dictionary = {}
	var total_matched: int = 0
	var enabled_count: int = 0

	for info in registered:
		var name: String = String(info.get("name", ""))
		var enabled: bool = bool(info.get("enabled", false))
		var category: String = String(info.get("category", ""))
		var group: String = String(info.get("group", ""))
		var description: String = String(info.get("description", ""))
		if enabled:
			enabled_count += 1
		if not group_filter.is_empty() and group != group_filter:
			continue
		if enabled_only and not enabled:
			continue
		if not query.is_empty() and not (name.to_lower().contains(query) or description.to_lower().contains(query)):
			continue

		var group_key: String = group if not group.is_empty() else "(ungrouped)"
		if not groups.has(group_key):
			groups[group_key] = {"total": 0, "enabled": 0}
			if not summary_only:
				groups[group_key]["tools"] = []
		if not summary_only:
			var entry: Dictionary = {"name": name, "enabled": enabled, "category": category}
			if include_descriptions:
				entry["description"] = _short_description(description)
			groups[group_key]["tools"].append(entry)
		groups[group_key]["total"] = int(groups[group_key]["total"]) + 1
		if enabled:
			groups[group_key]["enabled"] = int(groups[group_key]["enabled"]) + 1
		total_matched += 1

	var preset_ids: Array = []
	var pm: RefCounted = _get_preset_manager()
	if pm and pm.has_method("get_preset_ids"):
		preset_ids = pm.get_preset_ids()
		preset_ids.sort()

	var ordered_groups: Dictionary = {}
	var group_names: Array = groups.keys()
	group_names.sort()
	for group_name in group_names:
		ordered_groups[group_name] = groups[group_name]

	return {
		"groups": ordered_groups,
		"presets": preset_ids,
		"total_registered": registered.size(),
		"total_matched": total_matched,
		"enabled_count": enabled_count,
		"catalog_revision": catalog_revision,
		"not_modified": false,
		"workflow_coverage": _workflow_router.get_coverage_report(registered)
	}

# ============================================================================
# search_tools - 关键词检索工具目录（渐进发现第二层）
# ============================================================================

func _register_search_tools(server_core: RefCounted) -> void:
	server_core.register_tool(
		"search_tools",
		"Find tools locally from an English or Chinese intent. mode='tools' ranks single capabilities; mode='workflow' returns at most 10 schema-free names grouped as inspect/execute/verify and can route every non-meta atomic tool. Enable returned names in one call.",
		{
			"type": "object",
			"properties": {
				"query": {"type": "string", "description": "Required English or Chinese task intent."},
				"mode": {"type": "string", "enum": ["tools", "workflow"], "default": "tools", "description": "One capability or a compact multi-stage route."},
				"group": {"type": "string", "description": "Optional exact classifier group."},
				"enabled_only": {"type": "boolean", "default": false, "description": "Restrict results to enabled tools."},
				"include_descriptions": {"type": "boolean", "default": true, "description": "tools mode: include one-line descriptions."},
				"limit": {"type": "integer", "default": 12, "description": "tools mode: result limit, clamped to 1..50."},
				"workflow_tool_budget": {"type": "integer", "default": 8, "description": "workflow mode: tool limit, clamped to 1..10."}
			},
			"required": ["query"]
		},
		Callable(self, "_tool_search_tools"),
		{"type": "object", "properties": {"tools": {"type": "array", "items": {"type": "object"}}, "workflow": {"type": "object"}, "total_matched": {"type": "integer"}, "query": {"type": "string"}, "catalog_revision": {"type": "integer"}}},
		{"readOnlyHint": true, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false},
		"meta", "Meta"
	)

func _tool_search_tools(params: Dictionary) -> Dictionary:
	if _server_core == null or not _server_core.has_method("get_registered_tools"):
		return {"error": "Server core is not available"}

	var query_raw: String = String(params.get("query", "")).strip_edges()
	if query_raw.is_empty():
		return {"error": "Missing required parameter: query"}
	var mode: String = String(params.get("mode", "tools")).strip_edges().to_lower()
	if mode not in ["tools", "workflow"]:
		return {"error": "Unknown search mode: '%s'. Use 'tools' or 'workflow'." % mode}

	var group_filter: String = String(params.get("group", "")).strip_edges()
	var enabled_only: bool = bool(params.get("enabled_only", false))
	var registered: Array = []
	for info_value in _sorted_registered_tools():
		var info: Dictionary = info_value
		if not group_filter.is_empty() and String(info.get("group", "")) != group_filter:
			continue
		if enabled_only and not bool(info.get("enabled", false)):
			continue
		registered.append(info)
	if mode == "workflow":
		var workflow_budget: int = int(params.get("workflow_tool_budget", 8))
		return {
			"workflow": _workflow_router.route(query_raw, registered, workflow_budget),
			"query": query_raw,
			"catalog_revision": _get_catalog_revision()
		}

	var terms: Array = _build_query_terms(query_raw)
	var include_descriptions: bool = bool(params.get("include_descriptions", true))
	var limit: int = clamp(int(params.get("limit", SEARCH_LIMIT_DEFAULT)), 1, SEARCH_LIMIT_MAX)

	var tools: Array = []
	for info in registered:
		var name: String = String(info.get("name", ""))
		var description: String = String(info.get("description", ""))

		var score: int = _score_tool_match(info, query_raw, terms)
		if score < 0:
			continue

		var entry: Dictionary = {
			"name": name,
			"group": String(info.get("group", "")),
			"category": String(info.get("category", "")),
			"enabled": bool(info.get("enabled", false)),
			"score": score
		}
		if include_descriptions:
			entry["description"] = _short_description(description)
		tools.append(entry)

	tools.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var score_a: int = int(a.get("score", 0))
		var score_b: int = int(b.get("score", 0))
		if score_a == score_b:
			return String(a.get("name", "")) < String(b.get("name", ""))
		return score_a > score_b
	)
	var total_matched: int = tools.size()
	if tools.size() > limit:
		tools.resize(limit)

	return {
		"tools": tools,
		"total_matched": total_matched,
		"query": query_raw,
		"catalog_revision": _get_catalog_revision()
	}

# ============================================================================
# get_tool_details - 单个工具完整 schema（渐进发现第三层）
# ============================================================================

func _register_get_tool_details(server_core: RefCounted) -> void:
	server_core.register_tool(
		"get_tool_details",
		"Return the full registration record for one MCP tool — complete description, inputSchema, outputSchema, annotations, category, group and enabled state — so a client can fetch the exact schema before calling a tool without loading every tool. Use list_tool_catalog or search_tools to discover tool names first. Returns found=false with a hint when the name is not registered.",
		{
			"type": "object",
			"properties": {
				"name": {"type": "string", "description": "Exact registered tool name, e.g. 'modify_script'."}
			},
			"required": ["name"]
		},
		Callable(self, "_tool_get_tool_details"),
		{"type": "object", "properties": {"name": {"type": "string"}, "description": {"type": "string"}, "inputSchema": {"type": "object"}, "outputSchema": {"type": "object"}, "annotations": {"type": "object"}, "category": {"type": "string"}, "group": {"type": "string"}, "enabled": {"type": "boolean"}, "found": {"type": "boolean"}}},
		{"readOnlyHint": true, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false},
		"meta", "Meta"
	)

func _tool_get_tool_details(params: Dictionary) -> Dictionary:
	if _server_core == null or not _server_core.has_method("get_tool"):
		return {"error": "Server core is not available"}

	var tool_name: String = String(params.get("name", "")).strip_edges()
	if tool_name.is_empty():
		return {"error": "Missing required parameter: name"}

	var tool = _server_core.get_tool(tool_name)
	if tool == null:
		return {
			"name": tool_name,
			"found": false,
			"hint": "Tool not found. Use list_tool_catalog or search_tools to discover registered tool names."
		}

	var details: Dictionary = {
		"name": tool.name,
		"description": tool.description,
		"inputSchema": tool.input_schema,
		"category": tool.category,
		"group": tool.group,
		"enabled": tool.enabled,
		"found": true
	}
	if not tool.output_schema.is_empty():
		details["outputSchema"] = tool.output_schema
	if not tool.annotations.is_empty():
		details["annotations"] = tool.annotations
	return details

# ============================================================================
# enable_tools
# ============================================================================

func _register_enable_tools(server_core: RefCounted) -> void:
	server_core.register_tool(
		"enable_tools",
		"Route and activate the minimum tools for workflow_query in one call, replacing old supplementary task tools by default. Or change explicit tools, groups or a preset. Core/meta stay on; the response is compact.",
		{
			"type": "object",
			"properties": {
				"workflow_query": {"type": "string", "description": "English/Chinese goal. Locally routes to at most 8 inspect/execute/verify tools; exclusive with tools/groups/preset."},
				"replace_supplementary": {"type": "boolean", "default": true, "description": "workflow_query only. Replace old supplementary task tools; false adds."},
				"tools": {"type": "array", "items": {"type": "string"}, "description": "Individual tool names to enable/disable."},
				"groups": {"type": "array", "items": {"type": "string"}, "description": "Groups to enable/disable."},
				"preset": {"type": "string", "description": "Focused preset ID; 'all' costs most context. Overrides manual selection."},
				"enabled": {"type": "boolean", "default": true, "description": "Enable or disable manual tools/groups."},
				"exclusive": {"type": "boolean", "default": false, "description": "When manually enabling, disable all supplementary tools first."},
				"include_enabled_tools": {"type": "boolean", "default": false, "description": "Return all enabled names; false returns only changes/counts."}
			}
		},
		Callable(self, "_tool_enable_tools"),
		{"type": "object", "properties": {"status": {"type": "string"}, "enabled_count": {"type": "integer"}, "total_registered": {"type": "integer"}, "enabled_tools": {"type": "array"}, "changed_count": {"type": "integer"}, "changed_tools": {"type": "array"}, "catalog_revision": {"type": "integer"}, "applied_preset": {"type": "string"}, "workflow_query": {"type": "string"}, "workflow": {"type": "object"}, "replaced_supplementary": {"type": "boolean"}, "unknown_tools": {"type": "array"}, "unknown_groups": {"type": "array"}}},
		{"readOnlyHint": false, "destructiveHint": false, "idempotentHint": false, "openWorldHint": false},
		"meta", "Meta"
	)

func _tool_enable_tools(params: Dictionary) -> Dictionary:
	if _server_core == null or not _server_core.has_method("set_tool_enabled"):
		return {"error": "Server core is not available"}

	var registered: Array = _sorted_registered_tools()
	var all_names: Array = []
	var known_names: Dictionary = {}
	var previous_states: Dictionary = {}
	for info in registered:
		var registered_name: String = String(info.get("name", ""))
		all_names.append(registered_name)
		known_names[registered_name] = true
		previous_states[registered_name] = bool(info.get("enabled", false))

	var classifier: RefCounted = _get_classifier()
	var applied_preset: String = ""
	var workflow: Dictionary = {}
	var workflow_query: String = String(params.get("workflow_query", "")).strip_edges()
	var has_workflow_query: bool = params.has("workflow_query")
	var replaced_supplementary: bool = false
	var unknown_tools: Array = []
	var unknown_groups: Array = []
	var desired_states: Dictionary = {}

	var preset: String = String(params.get("preset", "")).strip_edges()
	var requested_groups: Array = params.get("groups", []) if params.get("groups", []) is Array else []
	var requested_tools: Array = params.get("tools", []) if params.get("tools", []) is Array else []
	if has_workflow_query:
		if workflow_query.is_empty():
			return {"error": "workflow_query must not be blank"}
		if not preset.is_empty() or not requested_groups.is_empty() or not requested_tools.is_empty():
			return {"error": "workflow_query cannot be combined with tools, groups, or preset"}
		if bool(params.get("exclusive", false)) or (params.has("enabled") and not bool(params.get("enabled", true))):
			return {"error": "workflow_query cannot be combined with exclusive=true or enabled=false"}
		workflow = _workflow_router.route(workflow_query, registered)
		if workflow.has("error"):
			return {"error": String(workflow.get("error", "Unable to route workflow intent"))}
		var routed_tools: Array[String] = []
		for stage_value in workflow.get("stages", []):
			var stage: Dictionary = stage_value
			for tool_name_value in stage.get("tools", []):
				var routed_name: String = String(tool_name_value)
				if not routed_name.is_empty() and routed_name not in routed_tools:
					routed_tools.append(routed_name)
		if routed_tools.is_empty():
			return {"error": "No registered tools matched workflow_query"}
		replaced_supplementary = bool(params.get("replace_supplementary", true))
		if replaced_supplementary:
			for info in registered:
				if String(info.get("category", "")) == "supplementary" and bool(info.get("enabled", false)):
					desired_states[String(info.get("name", ""))] = false
		for routed_name in routed_tools:
			desired_states[routed_name] = true
	elif not preset.is_empty():
		var pm: RefCounted = _get_preset_manager()
		if pm == null or not pm.has_method("has_preset") or not pm.has_preset(preset):
			var valid_ids: Array = pm.get_preset_ids() if pm and pm.has_method("get_preset_ids") else []
			return {"error": "Unknown preset: '%s'. Valid presets: %s" % [preset, str(valid_ids)]}
		desired_states = pm.resolve_preset_states(preset, all_names)
		applied_preset = preset
	else:
		var enabled: bool = bool(params.get("enabled", true))
		var exclusive: bool = bool(params.get("exclusive", false))

		if exclusive and enabled:
			for info in registered:
				var n: String = String(info.get("name", ""))
				var cat: String = String(info.get("category", ""))
				desired_states[n] = cat == "core" or cat == "meta"

		for group_name in requested_groups:
			var group_str: String = String(group_name)
			if classifier and classifier.has_method("get_all_groups") and not (group_str in classifier.get_all_groups()):
				unknown_groups.append(group_str)
				continue
			for info in registered:
				if String(info.get("group", "")) == group_str:
					desired_states[String(info.get("name", ""))] = enabled

		for tool_name in requested_tools:
			var name_str: String = String(tool_name)
			if not known_names.has(name_str):
				unknown_tools.append(name_str)
				continue
			desired_states[name_str] = enabled

	# Always-on guard: meta tools must never be disabled, otherwise the agent
	# loses the ability to re-discover and re-enable tools.
	if classifier and classifier.has_method("get_meta_tools"):
		for meta_name in classifier.get_meta_tools():
			if known_names.has(meta_name):
				desired_states[meta_name] = true

	var apply_result: Dictionary = {}
	if _server_core.has_method("apply_tool_states"):
		apply_result = _server_core.apply_tool_states(desired_states)
	else:
		for tool_name in desired_states:
			_server_core.set_tool_enabled(String(tool_name), bool(desired_states[tool_name]))

	for unknown_name in apply_result.get("unknown_tools", []):
		var unknown_str: String = String(unknown_name)
		if unknown_str not in unknown_tools:
			unknown_tools.append(unknown_str)
	unknown_tools.sort()
	unknown_groups.sort()

	var include_enabled_tools: bool = bool(params.get("include_enabled_tools", false))
	var enabled_tools: Array = []
	var enabled_count: int = 0
	var changed_tools: Array = apply_result.get("changed_tools", [])
	var current_registered: Array = _server_core.get_registered_tools()
	if not _server_core.has_method("apply_tool_states"):
		changed_tools = []
		for info in current_registered:
			var current_name: String = String(info.get("name", ""))
			if previous_states.has(current_name) and bool(previous_states[current_name]) != bool(info.get("enabled", false)):
				changed_tools.append(current_name)
	changed_tools.sort()
	for info in current_registered:
		if bool(info.get("enabled", false)):
			enabled_count += 1
			if include_enabled_tools:
				enabled_tools.append(String(info.get("name", "")))
	if include_enabled_tools:
		enabled_tools.sort()

	if not changed_tools.is_empty() and _server_core.has_method("notify_tool_list_changed"):
		_server_core.notify_tool_list_changed()

	var response: Dictionary = {
		"status": "success",
		"enabled_count": enabled_count,
		"total_registered": all_names.size(),
		"changed_count": changed_tools.size(),
		"changed_tools": changed_tools,
		"catalog_revision": int(apply_result.get("catalog_revision", _get_catalog_revision())),
		"applied_preset": applied_preset,
		"unknown_tools": unknown_tools,
		"unknown_groups": unknown_groups
	}
	if has_workflow_query:
		response["workflow_query"] = workflow_query
		response["workflow"] = workflow
		response["replaced_supplementary"] = replaced_supplementary
	if include_enabled_tools:
		response["enabled_tools"] = enabled_tools
	return response
