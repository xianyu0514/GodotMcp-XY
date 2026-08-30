extends "res://addons/gut/test.gd"


func test_localization_extract_writes_importable_header_on_empty_project():
	var tools: RefCounted = load("res://addons/godot_mcp/tools/project_workflow_tools.gd").new()
	var csv: String = "user://i18n_extract_header_test.csv"
	var result: Dictionary = tools._tool_manage_localization({"action": "extract", "csv_path": csv})
	assert_false(result.has("error"), str(result.get("error", "")))
	var file: FileAccess = FileAccess.open(csv, FileAccess.READ)
	assert_not_null(file, "extract must write the CSV")
	if file:
		var header: PackedStringArray = file.get_csv_line()
		file.close()
		assert_gte(header.size(), 2,
			"Header must carry at least one locale column so import accepts it: " + str(header))
		assert_eq(str(header[0]), "keys", "First column stays 'keys'")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(csv))
