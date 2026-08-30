extends "res://addons/gut/test.gd"

## 导出预设 CRUD 的端到端回环（真实 ConfigFile 读写，headless 可跑）。
## 项目根的 export_presets.cfg 被 .gitignore 忽略；测试前备份、测试后还原。

const ExportPresetToolsScript = preload("res://addons/godot_mcp/tools/export_preset_tools.gd")

var _tools: RefCounted = null
var _backup: String = ""

func before_each() -> void:
	_tools = ExportPresetToolsScript.new()
	var absolute: String = ProjectSettings.globalize_path(ExportPresetToolsScript.PRESET_FILE)
	if FileAccess.file_exists(absolute):
		_backup = "user://export_presets_backup.cfg"
		DirAccess.copy_absolute(absolute, ProjectSettings.globalize_path(_backup))
		DirAccess.remove_absolute(absolute)

func after_each() -> void:
	var absolute: String = ProjectSettings.globalize_path(ExportPresetToolsScript.PRESET_FILE)
	DirAccess.remove_absolute(absolute)
	if not _backup.is_empty():
		DirAccess.copy_absolute(ProjectSettings.globalize_path(_backup), absolute)
		DirAccess.remove_absolute(ProjectSettings.globalize_path(_backup))
		_backup = ""

func test_export_preset_crud_round_trip() -> void:
	var created: Dictionary = _tools._tool_create_export_preset({
		"name": "Windows Desktop", "platform": "Windows Desktop",
		"export_path": "../build/game.exe", "options": {"binary_format/architecture": "x86_64"}})
	assert_eq(String(created.get("error", "")), "", str(created.get("error", "ok")))
	assert_true(bool(created.get("verified", false)),
		"Creation re-reads the file and verifies the preset exists")

	var listed: Dictionary = _tools._tool_inspect_export_presets({})
	assert_false(listed.has("error"))
	var presets: Array = listed.get("presets", [])
	assert_eq(presets.size(), 1)
	assert_eq(String(presets[0].get("name", "")), "Windows Desktop")
	assert_eq(String(presets[0].get("export_path", "")), "../build/game.exe")

	var updated: Dictionary = _tools._tool_update_export_preset({
		"name": "Windows Desktop", "export_path": "../build/game_v2.exe"})
	assert_eq(String(updated.get("error", "")), "", str(updated.get("error", "ok")))
	var relisted: Array = _tools._tool_inspect_export_presets({}).get("presets", [])
	assert_eq(String(relisted[0].get("export_path", "")), "../build/game_v2.exe",
		"Only provided fields change")

	var duplicated: Dictionary = _tools._tool_duplicate_export_preset({
		"name": "Windows Desktop", "new_name": "Windows Beta"})
	assert_eq(String(duplicated.get("error", "")), "", str(duplicated.get("error", "ok")))
	assert_eq(_tools._tool_inspect_export_presets({}).get("presets", []).size(), 2)

	var removed: Dictionary = _tools._tool_remove_export_preset({"name": "Windows Beta"})
	assert_eq(String(removed.get("error", "")), "", str(removed.get("error", "ok")))
	var final_list: Array = _tools._tool_inspect_export_presets({}).get("presets", [])
	assert_eq(final_list.size(), 1)
	assert_eq(String(final_list[0].get("name", "")), "Windows Desktop")

func test_create_export_preset_requires_core_fields() -> void:
	var missing_name: Dictionary = _tools._tool_create_export_preset({
		"platform": "Windows Desktop", "export_path": "../build/game.exe"})
	assert_true(missing_name.has("error"), "A preset without a name must fail fast")
