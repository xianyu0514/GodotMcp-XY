class_name MCPToolPresetManager
extends RefCounted

## Built-in tool presets ("profiles") so a team can enable a curated set of tools
## with one click instead of toggling 200+ tools individually.
##
## 工具预设档：让团队一键启用某个场景所需的工具集合，免去逐个勾选 200+ 工具。
## 每个预设 = 全部核心工具(core) + 该场景附加的分类组(groups)；
## "all" 启用全部工具，"minimal_core" 只启用核心工具。
##
## 导出/导入为 JSON 文件，便于团队负责人统一下发同一套工具配置。

const PRESET_IDS: Array[String] = [
	"minimal_core",
	"level_design",
	"debugging",
	"automation_qa",
	"art_resources",
	"all",
]

const PRESET_EXPORT_VERSION: int = 1

# Extra (non-core) classifier groups enabled by each preset. Core tools are always
# included on top of these (except "all", which enables every registered tool).
const PRESET_GROUPS: Dictionary = {
	"minimal_core": [],
	"level_design": ["Node-Write-Advanced", "Node-Advanced", "Scene-Advanced", "Editor-Advanced"],
	"debugging": ["Debug-Advanced"],
	"automation_qa": ["Debug-Advanced", "Project-Advanced"],
	"art_resources": ["Project-Advanced", "Scene-Advanced", "Node-Write-Advanced"],
	"all": [],
}

var _classifier = null

func _init() -> void:
	_classifier = load("res://addons/godot_mcp/native_mcp/mcp_tool_classifier.gd").new()

func get_preset_ids() -> Array:
	return PRESET_IDS.duplicate()

func has_preset(preset_id: String) -> bool:
	return preset_id in PRESET_IDS

## Returns an enabled-state map {tool_name: bool} covering every name in
## all_tool_names. Tools not part of the preset are explicitly set to false so
## callers can apply the result wholesale.
func resolve_preset_states(preset_id: String, all_tool_names: Array) -> Dictionary:
	var states: Dictionary = {}
	for tool_name in all_tool_names:
		states[tool_name] = false
	if not has_preset(preset_id):
		return states
	if preset_id == "all":
		for tool_name in all_tool_names:
			states[tool_name] = true
		return states

	var enabled: Dictionary = {}
	if _classifier:
		for tool_name in _classifier.get_core_tools():
			enabled[tool_name] = true
		# Always-on meta tools (discovery/activation) survive every preset so the
		# agent can re-enable other tools after switching to a minimal profile.
		if _classifier.has_method("get_meta_tools"):
			for tool_name in _classifier.get_meta_tools():
				enabled[tool_name] = true
		for group_name in PRESET_GROUPS.get(preset_id, []):
			for tool_name in _classifier.get_group_tools(group_name):
				enabled[tool_name] = true
	for tool_name in all_tool_names:
		if enabled.has(tool_name):
			states[tool_name] = true
	return states

## Serialize an enabled-state map to a shareable JSON string.
static func states_to_json(states: Dictionary) -> String:
	var enabled_list: Array = []
	for tool_name in states:
		if states[tool_name]:
			enabled_list.append(tool_name)
	enabled_list.sort()
	var root: Dictionary = {
		"version": PRESET_EXPORT_VERSION,
		"enabled_tools": enabled_list,
	}
	return JSON.stringify(root, "\t", false)

## Parse a JSON string into an enabled-state map restricted to all_tool_names.
## Returns {"ok": bool, "states": Dictionary, "error": String}.
static func states_from_json(text: String, all_tool_names: Array) -> Dictionary:
	var parsed = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY or not parsed.has("enabled_tools"):
		return {"ok": false, "states": {}, "error": "Invalid preset format: missing 'enabled_tools'"}
	if typeof(parsed["enabled_tools"]) != TYPE_ARRAY:
		return {"ok": false, "states": {}, "error": "Invalid preset format: 'enabled_tools' must be an array"}
	var enabled_set: Dictionary = {}
	for tool_name in parsed["enabled_tools"]:
		enabled_set[tool_name] = true
	var states: Dictionary = {}
	for tool_name in all_tool_names:
		states[tool_name] = enabled_set.has(tool_name)
	return {"ok": true, "states": states, "error": ""}

static func export_states_to_file(states: Dictionary, path: String) -> bool:
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return false
	file.store_string(states_to_json(states))
	file.close()
	return true

static func import_states_from_file(path: String, all_tool_names: Array) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {"ok": false, "states": {}, "error": "File not found: " + path}
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {"ok": false, "states": {}, "error": "Cannot open file: " + path}
	var text: String = file.get_as_text()
	file.close()
	return states_from_json(text, all_tool_names)
