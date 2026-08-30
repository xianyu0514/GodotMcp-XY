# mcp-native-smoke-test
extends SceneTree

var _failures: Array[String] = []

func _initialize() -> void:
	_check_main_scene()
	_check_project_file()
	if _failures.is_empty():
		print("MCP_SMOKE_PASS")
		quit(0)
	else:
		for failure in _failures:
			push_error(failure)
		print("MCP_SMOKE_FAIL")
		quit(1)

func _check_main_scene() -> void:
	var main_scene: String = str(ProjectSettings.get_setting("application/run/main_scene", ""))
	if main_scene.is_empty():
		print("MCP_SMOKE_SKIP main_scene_not_configured")
		return
	var packed: PackedScene = load(main_scene) as PackedScene
	if packed == null:
		_failures.append("main scene failed to load: " + main_scene)
		return
	var instance: Node = packed.instantiate()
	if instance == null:
		_failures.append("main scene has no instantiable root: " + main_scene)
	else:
		instance.free()

func _check_project_file() -> void:
	if not FileAccess.file_exists("res://project.godot"):
		_failures.append("project.godot is missing")
