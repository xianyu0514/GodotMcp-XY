@tool
class_name MCPVibeCodingPolicy
extends RefCounted

const BLOCK_REASON: String = "vibe_coding_mode"

static func evaluate_editor_focus(vibe_coding_mode: bool, params: Dictionary) -> Dictionary:
	if not vibe_coding_mode:
		return {"blocked": false}
	if bool(params.get("allow_ui_focus", false)):
		return {"blocked": false}
	return {
		"blocked": true,
		"reason": BLOCK_REASON,
		"error": "Vibe Coding mode is enabled. This tool would change editor focus or selection. Pass allow_ui_focus=true on this call, or uncheck 'Vibe Coding mode' in the Godot MCP dock panel to disable it for all tools."
	}

static func evaluate_runtime_window(vibe_coding_mode: bool, params: Dictionary) -> Dictionary:
	if not vibe_coding_mode:
		return {"blocked": false}
	if bool(params.get("allow_window", false)):
		return {"blocked": false}
	# 自愈文案（2026-09-27 体检 P1-3）：必须给出精确的关闭位置，
	# 否则自动化调用方每轮都得试错。
	return {
		"blocked": true,
		"reason": BLOCK_REASON,
		"error": "Vibe Coding mode is enabled. This tool would open or control a runtime window. Pass allow_window=true on this call, or uncheck 'Vibe Coding mode' in the Godot MCP dock panel to disable it for all tools."
	}

static func should_grab_focus(vibe_coding_mode: bool, params: Dictionary, default_grab_focus: bool = true) -> bool:
	if vibe_coding_mode and not bool(params.get("allow_ui_focus", false)):
		return false
	return bool(params.get("grab_focus", default_grab_focus))
