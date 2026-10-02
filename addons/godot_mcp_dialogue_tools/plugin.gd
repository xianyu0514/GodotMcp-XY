@tool
extends EditorPlugin

## 参考 addon：走通 godot_mcp custom tools API 的完整生命周期。
## 用途：① 第三方插件作者的活样板（docs/contributing.md 引用）；
## ② 工作室可直接用于对话系统工作流（验证/字数/本地化键提取）。

const DialogueTools := preload("res://addons/godot_mcp_dialogue_tools/dialogue_tools.gd")

var _provider: RefCounted = null

func _enter_tree() -> void:
	_provider = DialogueTools.new()
	if Engine.has_meta("GodotMCPCustomTools"):
		var registry: Variant = Engine.get_meta("GodotMCPCustomTools")
		if registry and registry.has_method("register_tool"):
			registry.register_tool("custom_dialogue_validate",
				"Validate a dialogue graph JSON file: checks node reachability, dangling link targets, and orphaned nodes. Expects a JSON with {nodes: [{id, text, next: [ids]}]}.",
				{"type": "object", "properties": {"path": {"type": "string", "description": "res:// path to the dialogue JSON."}}, "required": ["path"]},
				Callable(_provider, "validate_dialogue"))
			registry.register_tool("custom_dialogue_wordcount",
				"Count words per character in a dialogue graph JSON. Returns {character: word_count} for speaker-tagged entries and a total.",
				{"type": "object", "properties": {"path": {"type": "string"}}, "required": ["path"]},
				Callable(_provider, "wordcount_dialogue"))
			registry.register_tool("custom_dialogue_loc_keys",
				"Extract localization keys referenced in a dialogue graph. Returns {missing: [keys not found in the CSV], found: [keys present]}. Expects entries with loc_id fields.",
				{"type": "object", "properties": {"path": {"type": "string"}, "csv_path": {"type": "string", "description": "res:// path to the localization CSV."}}, "required": ["path"]},
				Callable(_provider, "loc_keys_dialogue"))

func _exit_tree() -> void:
	if Engine.has_meta("GodotMCPCustomTools"):
		var registry: Variant = Engine.get_meta("GodotMCPCustomTools")
		if registry and registry.has_method("unregister_tool"):
			for name in ["custom_dialogue_validate", "custom_dialogue_wordcount", "custom_dialogue_loc_keys"]:
				registry.unregister_tool(name)
