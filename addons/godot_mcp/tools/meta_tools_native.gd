# meta_tools_native.gd - Meta tools for on-demand tool discovery & activation
#
# 这些是"始终在线"的元工具（category = "meta"），即使切到 minimal_core 预设也不会被隐藏。
# 目的：让模型平时只暴露「核心 + 目录工具」，需要更多能力时先用 list_tool_catalog 查目录，
# 再用 enable_tools 动态启用对应工具/分组/预设，从而显著降低 tools/list 的 token 开销。

@tool
class_name MetaToolsNative
extends RefCounted

const PRESET_MANAGER_PATH: String = "res://addons/godot_mcp/native_mcp/mcp_tool_preset_manager.gd"

var _server_core: RefCounted = null
var _preset_manager: RefCounted = null

func initialize(_editor_interface: EditorInterface) -> void:
	pass

func register_tools(server_core: RefCounted) -> void:
	_server_core = server_core
	_register_list_tool_catalog(server_core)
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

# ============================================================================
# list_tool_catalog
# ============================================================================

func _register_list_tool_catalog(server_core: RefCounted) -> void:
	server_core.register_tool(
		"list_tool_catalog",
		"List the registered MCP tools grouped by category, with a one-line description and whether each is currently enabled (visible in tools/list). Use this to discover capabilities WITHOUT loading every full tool schema, then call enable_tools to switch on just what you need. Filter by group/query to keep the response small.",
		{
			"type": "object",
			"properties": {
				"group": {"type": "string", "description": "Filter to a single classifier group (e.g. 'Debug-Advanced'). Omit to list all groups."},
				"query": {"type": "string", "description": "Case-insensitive substring filter over tool name and description."},
				"enabled_only": {"type": "boolean", "default": false, "description": "Only include tools that are currently enabled (already visible in tools/list)."},
				"include_descriptions": {"type": "boolean", "default": true, "description": "Include a short one-line description per tool. Set false for an even more compact name-only listing."}
			}
		},
		Callable(self, "_tool_list_tool_catalog"),
		{"type": "object", "properties": {"groups": {"type": "object"}, "presets": {"type": "array"}, "total_registered": {"type": "integer"}, "total_matched": {"type": "integer"}, "enabled_count": {"type": "integer"}}},
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

	var registered: Array = _server_core.get_registered_tools()
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
			groups[group_key] = {"total": 0, "enabled": 0, "tools": []}
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

	return {
		"groups": groups,
		"presets": preset_ids,
		"total_registered": registered.size(),
		"total_matched": total_matched,
		"enabled_count": enabled_count
	}

# ============================================================================
# enable_tools
# ============================================================================

func _register_enable_tools(server_core: RefCounted) -> void:
	server_core.register_tool(
		"enable_tools",
		"Enable or disable MCP tools on demand so only the tools you need are visible in tools/list (saving context/compute). Pass 'tools' and/or 'groups' to toggle specific items, or 'preset' to apply a curated profile wholesale. Emits notifications/tools/list_changed so the client refreshes its tool list. Core and meta tools always stay enabled.",
		{
			"type": "object",
			"properties": {
				"tools": {"type": "array", "items": {"type": "string"}, "description": "Individual tool names to enable/disable."},
				"groups": {"type": "array", "items": {"type": "string"}, "description": "Classifier groups to enable/disable (e.g. 'Debug-Advanced', 'Scene-Advanced')."},
				"preset": {"type": "string", "description": "Apply a built-in preset wholesale (minimal_core, level_design, debugging, automation_qa, art_resources, all). When set, 'tools'/'groups'/'enabled'/'exclusive' are ignored."},
				"enabled": {"type": "boolean", "default": true, "description": "Whether to enable (true) or disable (false) the given tools/groups."},
				"exclusive": {"type": "boolean", "default": false, "description": "When enabling, first reset to the core-only baseline (disable every supplementary tool) so only the requested set plus the always-on core/meta tools remain."}
			}
		},
		Callable(self, "_tool_enable_tools"),
		{"type": "object", "properties": {"status": {"type": "string"}, "enabled_count": {"type": "integer"}, "total_registered": {"type": "integer"}, "enabled_tools": {"type": "array"}, "applied_preset": {"type": "string"}, "unknown_tools": {"type": "array"}, "unknown_groups": {"type": "array"}}},
		{"readOnlyHint": false, "destructiveHint": false, "idempotentHint": false, "openWorldHint": false},
		"meta", "Meta"
	)

func _tool_enable_tools(params: Dictionary) -> Dictionary:
	if _server_core == null or not _server_core.has_method("set_tool_enabled"):
		return {"error": "Server core is not available"}

	var all_names: Array = []
	for info in _server_core.get_registered_tools():
		all_names.append(String(info.get("name", "")))

	var classifier: RefCounted = _get_classifier()
	var applied_preset: String = ""
	var unknown_tools: Array = []
	var unknown_groups: Array = []

	var preset: String = String(params.get("preset", "")).strip_edges()
	if not preset.is_empty():
		var pm: RefCounted = _get_preset_manager()
		if pm == null or not pm.has_method("has_preset") or not pm.has_preset(preset):
			var valid_ids: Array = pm.get_preset_ids() if pm and pm.has_method("get_preset_ids") else []
			return {"error": "Unknown preset: '%s'. Valid presets: %s" % [preset, str(valid_ids)]}
		var states: Dictionary = pm.resolve_preset_states(preset, all_names)
		for tool_name in states:
			_server_core.set_tool_enabled(tool_name, bool(states[tool_name]))
		applied_preset = preset
	else:
		var enabled: bool = bool(params.get("enabled", true))
		var exclusive: bool = bool(params.get("exclusive", false))

		if exclusive and enabled:
			for info in _server_core.get_registered_tools():
				var n: String = String(info.get("name", ""))
				var cat: String = String(info.get("category", ""))
				_server_core.set_tool_enabled(n, cat == "core" or cat == "meta")

		var groups: Array = params.get("groups", []) if params.get("groups", []) is Array else []
		for group_name in groups:
			var group_str: String = String(group_name)
			if classifier and classifier.has_method("get_all_groups") and not (group_str in classifier.get_all_groups()):
				unknown_groups.append(group_str)
				continue
			if _server_core.has_method("set_group_enabled"):
				_server_core.set_group_enabled(group_str, enabled)

		var tools: Array = params.get("tools", []) if params.get("tools", []) is Array else []
		for tool_name in tools:
			var name_str: String = String(tool_name)
			if not (name_str in all_names):
				unknown_tools.append(name_str)
				continue
			_server_core.set_tool_enabled(name_str, enabled)

	# Always-on guard: meta tools must never be disabled, otherwise the agent
	# loses the ability to re-discover and re-enable tools.
	if classifier and classifier.has_method("get_meta_tools"):
		for meta_name in classifier.get_meta_tools():
			if meta_name in all_names:
				_server_core.set_tool_enabled(meta_name, true)

	if _server_core.has_method("notify_tool_list_changed"):
		_server_core.notify_tool_list_changed()

	var enabled_tools: Array = []
	for info in _server_core.get_registered_tools():
		if bool(info.get("enabled", false)):
			enabled_tools.append(String(info.get("name", "")))
	enabled_tools.sort()

	return {
		"status": "success",
		"enabled_count": enabled_tools.size(),
		"total_registered": all_names.size(),
		"enabled_tools": enabled_tools,
		"applied_preset": applied_preset,
		"unknown_tools": unknown_tools,
		"unknown_groups": unknown_groups
	}
