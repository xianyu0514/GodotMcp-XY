class_name MCPToolClassifier
extends RefCounted

const CORE_MAX_COUNT: int = 30
const ToolDomainsScript = preload("res://addons/godot_mcp/native_mcp/mcp_tool_domains.gd")

var _tool_classifications: Dictionary = {}

func _init() -> void:
	_build_classifications()

func _build_classifications() -> void:
	# 分类/分组从单一数据表 MCPToolsManifest.TOOLS 生成（单一真相）：
	# 新增/调整工具分类只改 tools_manifest.gd，本方法不再手写条目。
	# 一致性由 test/unit/test_mcp_tool_classifier.gd 的 manifest 测试强制。
	for tool_name in MCPToolsManifest.TOOLS:
		var entry: Dictionary = MCPToolsManifest.TOOLS[tool_name]
		_tool_classifications[tool_name] = {
			"category": entry["category"],
			"group": entry["group"]
		}

func get_tool_category(tool_name: String) -> String:
	if _tool_classifications.has(tool_name):
		return _tool_classifications[tool_name]["category"]
	return "core"

func get_tool_group(tool_name: String) -> String:
	if _tool_classifications.has(tool_name):
		return _tool_classifications[tool_name]["group"]
	return ""

func get_all_groups() -> Array[String]:
	var groups: Array[String] = []
	for tool_name in _tool_classifications:
		var group: String = _tool_classifications[tool_name]["group"]
		if not group in groups and not group.is_empty():
			groups.append(group)
	return groups

func get_group_tools(group_name: String) -> Array[String]:
	var tools: Array[String] = []
	for tool_name in _tool_classifications:
		if _tool_classifications[tool_name]["group"] == group_name:
			tools.append(tool_name)
	return tools

func get_core_tools() -> Array[String]:
	var tools: Array[String] = []
	for tool_name in _tool_classifications:
		if _tool_classifications[tool_name]["category"] == "core":
			tools.append(tool_name)
	return tools

func get_supplementary_tools() -> Array[String]:
	var tools: Array[String] = []
	for tool_name in _tool_classifications:
		if _tool_classifications[tool_name]["category"] == "supplementary":
			tools.append(tool_name)
	return tools

func get_core_max_count() -> int:
	return CORE_MAX_COUNT

func is_core_tool(tool_name: String) -> bool:
	return get_tool_category(tool_name) == "core"

func is_supplementary_tool(tool_name: String) -> bool:
	return get_tool_category(tool_name) == "supplementary"

func is_meta_tool(tool_name: String) -> bool:
	return get_tool_category(tool_name) == "meta"

func get_meta_tools() -> Array[String]:
	var tools: Array[String] = []
	for tool_name in _tool_classifications:
		if _tool_classifications[tool_name]["category"] == "meta":
			tools.append(tool_name)
	return tools

func get_all_tools() -> Array:
	return _tool_classifications.keys()

func get_all_categories() -> Array[String]:
	var categories: Array[String] = []
	for tool_name in _tool_classifications:
		var cat: String = _tool_classifications[tool_name]["category"]
		if not cat in categories:
			categories.append(cat)
	return categories

func get_all_domains() -> Array[String]:
	return ToolDomainsScript.get_all_domains()

func get_domain_tools(domain_name: String) -> Array[String]:
	return ToolDomainsScript.get_tools(domain_name, _tool_classifications)
