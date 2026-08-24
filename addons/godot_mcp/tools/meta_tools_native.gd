# meta_tools_native.gd - Meta tools for on-demand tool discovery & activation
#
# 这些是"始终在线"的元工具（category = "meta"），即使切到 minimal_core 预设也不会被隐藏。
# 目的：让模型平时只暴露「核心 + 目录工具」，需要更多能力时先用 list_tool_catalog 查目录，
# 再用 enable_tools 动态启用对应工具/分组/预设，从而显著降低 tools/list 的 token 开销。

@tool
class_name MetaToolsNative
extends RefCounted

const PRESET_MANAGER_PATH: String = "res://addons/godot_mcp/native_mcp/mcp_tool_preset_manager.gd"
const SEARCH_LIMIT_DEFAULT: int = 12
const SEARCH_LIMIT_MAX: int = 50

## Lightweight bilingual intent aliases. This keeps discovery local and
## deterministic: no embedding model, network call, or extra inference pass is
## needed for common Chinese Godot/game-development requests.
const SEARCH_ALIASES: Dictionary = {
	"场景": ["scene"], "节点": ["node"], "脚本": ["script"],
	"调试": ["debug", "runtime"], "运行时": ["runtime"], "运行": ["run", "runtime"],
	"信息": ["info", "status", "details"], "状态": ["status", "info"],
	"动画": ["animation"], "音频": ["audio"], "输入": ["input"],
	"导出": ["export"], "资源": ["resource", "asset"], "素材": ["asset", "resource"],
	"测试": ["test", "verify"], "验证": ["verify", "assert", "test"],
	"截图": ["screenshot"], "着色器": ["shader"], "瓦片": ["tile", "tilemap", "tileset"],
	"信号": ["signal"], "本地化": ["localization"], "翻译": ["translation", "localization"],
	"性能": ["performance"], "项目": ["project"], "界面": ["ui", "control"],
	"二维": ["2d"], "三维": ["3d"], "创建": ["create", "add"],
	"删除": ["delete", "remove"], "修改": ["update", "modify", "set"],
	"读取": ["get", "read", "list", "inspect"], "游戏": ["game", "runtime"]
}

var _server_core: RefCounted = null
var _preset_manager: RefCounted = null

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
	return value.strip_edges().to_lower().replace("_", " ").replace("-", " ").replace("\t", " ").replace("\n", " ")

func _build_query_terms(query_raw: String) -> Array:
	var terms: Array = []
	var alias_keys: Array = SEARCH_ALIASES.keys()
	alias_keys.sort_custom(func(a: String, b: String) -> bool:
		return a.length() > b.length()
	)
	for token_value in _normalize_search_text(query_raw).split(" ", false):
		var token: String = String(token_value).strip_edges()
		if token.is_empty():
			continue
		var matched_alias: bool = false
		for alias_key_value in alias_keys:
			var alias_key: String = String(alias_key_value)
			if not token.contains(alias_key):
				continue
			var variants: Array[String] = [alias_key]
			for alias_value in SEARCH_ALIASES[alias_key]:
				var alias: String = _normalize_search_text(String(alias_value))
				if not alias.is_empty() and alias not in variants:
					variants.append(alias)
			if variants not in terms:
				terms.append(variants)
			matched_alias = true
		if not matched_alias:
			terms.append([token])
	return terms

func _contains_search_token(haystack: String, needle: String) -> bool:
	return (" " + haystack + " ").contains(" " + needle + " ")

## BM25 would be unnecessary overhead for a 221-item in-memory catalog. This
## weighted lexical scorer captures the useful ordering properties with one
## cheap scan and deterministic tie-breaking.
func _score_tool_match(info: Dictionary, query_raw: String, terms: Array) -> int:
	var name: String = _normalize_search_text(String(info.get("name", "")))
	var group: String = _normalize_search_text(String(info.get("group", "")))
	var description: String = _normalize_search_text(String(info.get("description", "")))
	var normalized_query: String = _normalize_search_text(query_raw)
	var score: int = 0
	if name == normalized_query:
		score += 1000
	elif name.begins_with(normalized_query):
		score += 500

	for term_value in terms:
		var variants: Array = term_value
		var best_term_score: int = 0
		for variant_value in variants:
			var variant: String = String(variant_value)
			if name == variant:
				best_term_score = max(best_term_score, 300)
			elif _contains_search_token(name, variant):
				best_term_score = max(best_term_score, 160)
			elif name.contains(variant):
				best_term_score = max(best_term_score, 120)
			elif _contains_search_token(group, variant) or group.contains(variant):
				best_term_score = max(best_term_score, 50)
			elif description.contains(variant):
				best_term_score = max(best_term_score, 20)
		if best_term_score == 0:
			return -1
		score += best_term_score
	if bool(info.get("enabled", false)):
		score += 5
	return score

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
		{"type": "object", "properties": {"groups": {"type": "object"}, "presets": {"type": "array"}, "total_registered": {"type": "integer"}, "total_matched": {"type": "integer"}, "enabled_count": {"type": "integer"}, "catalog_revision": {"type": "integer"}, "not_modified": {"type": "boolean"}}},
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
		"not_modified": false
	}

# ============================================================================
# search_tools - 关键词检索工具目录（渐进发现第二层）
# ============================================================================

func _register_search_tools(server_core: RefCounted) -> void:
	server_core.register_tool(
		"search_tools",
		"Search and rank the registered MCP tool catalog from a short task intent in English or Chinese. Every space-separated intent term must match, while common Chinese Godot terms are expanded locally without embeddings or another model call. Enable exact result names and use the refreshed tools/list schema; call get_tool_details only when comparing candidates.",
		{
			"type": "object",
			"properties": {
				"query": {"type": "string", "description": "Required short task intent in English or Chinese. Space-separated terms use AND semantics; aliases such as 场景/节点/脚本/调试/动画/导出 are expanded locally."},
				"group": {"type": "string", "description": "Filter to a single classifier group (e.g. 'Script-Advanced')."},
				"enabled_only": {"type": "boolean", "default": false, "description": "Only include tools that are currently enabled (visible in tools/list)."},
				"include_descriptions": {"type": "boolean", "default": true, "description": "Include a one-line description per tool. Set false for a name-only listing."},
				"limit": {"type": "integer", "default": 12, "description": "Maximum ranked matches to return. Values are clamped to 1..50; total_matched reports the full count."}
			},
			"required": ["query"]
		},
		Callable(self, "_tool_search_tools"),
		{"type": "object", "properties": {"tools": {"type": "array", "items": {"type": "object"}}, "total_matched": {"type": "integer"}, "query": {"type": "string"}, "catalog_revision": {"type": "integer"}}},
		{"readOnlyHint": true, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false},
		"meta", "Meta"
	)

func _tool_search_tools(params: Dictionary) -> Dictionary:
	if _server_core == null or not _server_core.has_method("get_registered_tools"):
		return {"error": "Server core is not available"}

	var query_raw: String = String(params.get("query", "")).strip_edges()
	if query_raw.is_empty():
		return {"error": "Missing required parameter: query"}

	var terms: Array = _build_query_terms(query_raw)

	var group_filter: String = String(params.get("group", "")).strip_edges()
	var enabled_only: bool = bool(params.get("enabled_only", false))
	var include_descriptions: bool = bool(params.get("include_descriptions", true))
	var limit: int = clamp(int(params.get("limit", SEARCH_LIMIT_DEFAULT)), 1, SEARCH_LIMIT_MAX)

	var tools: Array = []
	for info in _sorted_registered_tools():
		var name: String = String(info.get("name", ""))
		var description: String = String(info.get("description", ""))
		if not group_filter.is_empty() and String(info.get("group", "")) != group_filter:
			continue
		if enabled_only and not bool(info.get("enabled", false)):
			continue

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
		"Enable or disable MCP tools on demand so only needed schemas are visible in tools/list. A request is applied as one atomic catalog transition and emits tools/list_changed only when something actually changed. Pass tools/groups or a focused preset; core and meta tools stay enabled. The compact response omits the full enabled list unless requested.",
		{
			"type": "object",
			"properties": {
				"tools": {"type": "array", "items": {"type": "string"}, "description": "Individual tool names to enable/disable."},
				"groups": {"type": "array", "items": {"type": "string"}, "description": "Classifier groups to enable/disable (e.g. 'Debug-Advanced', 'Scene-Advanced')."},
				"preset": {"type": "string", "description": "Apply a focused built-in preset wholesale: game_2d, game_3d, ui_localization, gameplay_scripting, animation_audio, release_export, level_design, debugging, automation_qa, art_resources, minimal_core, or all. Prefer a focused preset because 'all' has the highest context cost. When set, 'tools'/'groups'/'enabled'/'exclusive' are ignored."},
				"enabled": {"type": "boolean", "default": true, "description": "Whether to enable (true) or disable (false) the given tools/groups."},
				"exclusive": {"type": "boolean", "default": false, "description": "When enabling, first reset to the core-only baseline (disable every supplementary tool) so only the requested set plus the always-on core/meta tools remain."},
				"include_enabled_tools": {"type": "boolean", "default": false, "description": "Include the complete enabled tool-name list in the response. Leave false to minimize tokens; changed_tools and enabled_count are always returned."}
			}
		},
		Callable(self, "_tool_enable_tools"),
		{"type": "object", "properties": {"status": {"type": "string"}, "enabled_count": {"type": "integer"}, "total_registered": {"type": "integer"}, "enabled_tools": {"type": "array"}, "changed_count": {"type": "integer"}, "changed_tools": {"type": "array"}, "catalog_revision": {"type": "integer"}, "applied_preset": {"type": "string"}, "unknown_tools": {"type": "array"}, "unknown_groups": {"type": "array"}}},
		{"readOnlyHint": false, "destructiveHint": false, "idempotentHint": false, "openWorldHint": false},
		"meta", "Meta"
	)

func _tool_enable_tools(params: Dictionary) -> Dictionary:
	if _server_core == null or not _server_core.has_method("set_tool_enabled"):
		return {"error": "Server core is not available"}

	var registered: Array = _sorted_registered_tools()
	var all_names: Array = []
	var previous_states: Dictionary = {}
	for info in registered:
		var registered_name: String = String(info.get("name", ""))
		all_names.append(registered_name)
		previous_states[registered_name] = bool(info.get("enabled", false))

	var classifier: RefCounted = _get_classifier()
	var applied_preset: String = ""
	var unknown_tools: Array = []
	var unknown_groups: Array = []
	var desired_states: Dictionary = {}

	var preset: String = String(params.get("preset", "")).strip_edges()
	if not preset.is_empty():
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

		var groups: Array = params.get("groups", []) if params.get("groups", []) is Array else []
		for group_name in groups:
			var group_str: String = String(group_name)
			if classifier and classifier.has_method("get_all_groups") and not (group_str in classifier.get_all_groups()):
				unknown_groups.append(group_str)
				continue
			for info in registered:
				if String(info.get("group", "")) == group_str:
					desired_states[String(info.get("name", ""))] = enabled

		var tools: Array = params.get("tools", []) if params.get("tools", []) is Array else []
		for tool_name in tools:
			var name_str: String = String(tool_name)
			if not (name_str in all_names):
				unknown_tools.append(name_str)
				continue
			desired_states[name_str] = enabled

	# Always-on guard: meta tools must never be disabled, otherwise the agent
	# loses the ability to re-discover and re-enable tools.
	if classifier and classifier.has_method("get_meta_tools"):
		for meta_name in classifier.get_meta_tools():
			if meta_name in all_names:
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

	var enabled_tools: Array = []
	var changed_tools: Array = apply_result.get("changed_tools", [])
	var current_registered: Array = _sorted_registered_tools()
	if not _server_core.has_method("apply_tool_states"):
		changed_tools = []
		for info in current_registered:
			var current_name: String = String(info.get("name", ""))
			if previous_states.has(current_name) and bool(previous_states[current_name]) != bool(info.get("enabled", false)):
				changed_tools.append(current_name)
	changed_tools.sort()
	for info in current_registered:
		if bool(info.get("enabled", false)):
			enabled_tools.append(String(info.get("name", "")))
	enabled_tools.sort()

	if not changed_tools.is_empty() and _server_core.has_method("notify_tool_list_changed"):
		_server_core.notify_tool_list_changed()

	var response: Dictionary = {
		"status": "success",
		"enabled_count": enabled_tools.size(),
		"total_registered": all_names.size(),
		"changed_count": changed_tools.size(),
		"changed_tools": changed_tools,
		"catalog_revision": int(apply_result.get("catalog_revision", _get_catalog_revision())),
		"applied_preset": applied_preset,
		"unknown_tools": unknown_tools,
		"unknown_groups": unknown_groups
	}
	if bool(params.get("include_enabled_tools", false)):
		response["enabled_tools"] = enabled_tools
	return response
