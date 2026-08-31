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

func test_create_export_preset_if_exists_modes() -> void:
	# 工作流引擎 replan 会重放 create 步骤：if_exists="reuse" 必须幂等成功
	# （status=reused），默认 "error" 保持显式创建的严格语义。
	var first: Dictionary = _tools._tool_create_export_preset({
		"name": "Windows Desktop", "platform": "Windows Desktop",
		"export_path": "../build/game.exe"})
	assert_eq(String(first.get("status", "")), "created", str(first.get("error", "")))
	var strict: Dictionary = _tools._tool_create_export_preset({
		"name": "Windows Desktop", "platform": "Windows Desktop",
		"export_path": "../build/game.exe"})
	assert_true(strict.has("error"), "Default mode errors on duplicate name")
	var reuse: Dictionary = _tools._tool_create_export_preset({
		"name": "Windows Desktop", "platform": "Windows Desktop",
		"export_path": "../build/game.exe", "if_exists": "reuse"})
	assert_false(reuse.has("error"), "reuse mode treats duplicate as idempotent success")
	assert_eq(String(reuse.get("status", "")), "reused")
	assert_true(bool(reuse.get("existing", false)), "reuse response marks the preset as existing")
	assert_eq(_tools._tool_inspect_export_presets({}).get("presets", []).size(), 1,
		"reuse must not append a second preset")

func test_create_export_preset_reuse_reconciles_mismatched_platform() -> void:
	# reuse 曾原样返回陈旧错配预设（重名但平台/路径错），目标平台的导出链
	# 会一直用错预设。请求方参数是权威值，必须纠偏。
	var first: Dictionary = _tools._tool_create_export_preset({
		"name": "Web", "platform": "Windows Desktop", "export_path": "res://build/game.exe"})
	assert_eq(String(first.get("status", "")), "created", str(first.get("error", "")))
	var reuse: Dictionary = _tools._tool_create_export_preset({
		"name": "Web", "platform": "Web",
		"export_path": "res://build/web/index.html", "if_exists": "reuse"})
	assert_eq(String(reuse.get("status", "")), "reused")
	var reconciled: Dictionary = reuse.get("reconciled", {})
	assert_true(reconciled.has("platform") and reconciled.has("export_path"),
		"mismatched fields are reported as reconciled: " + str(reconciled))
	var presets: Array = _tools._tool_inspect_export_presets({}).get("presets", [])
	assert_eq(String(presets[0].get("platform", "")), "Web",
		"the stored preset now targets the requested platform")
	assert_eq(String(presets[0].get("export_path", "")), "res://build/web/index.html")
	# 一致后再次 reuse 不再报 reconciled（幂等稳定）。
	var stable: Dictionary = _tools._tool_create_export_preset({
		"name": "Web", "platform": "Web",
		"export_path": "res://build/web/index.html", "if_exists": "reuse"})
	assert_false(stable.get("reconciled", {}).has("platform"),
		"matching reuse is a pure no-op")
