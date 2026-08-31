extends "res://addons/gut/test.gd"

## SceneContextGuard editor-independent branches. Scene activation itself
## needs a live editor and is covered by the workflow integration paths.

const GuardScript = preload("res://addons/godot_mcp/utils/scene_context.gd")

func test_empty_target_is_a_no_op() -> void:
	var verdict: Dictionary = await GuardScript.ensure_scene_active(null, "   ")
	assert_true(bool(verdict.get("ok", false)))
	assert_false(bool(verdict.get("switched", true)),
		"No target scene means nothing to activate")

func test_missing_editor_interface_fails_closed() -> void:
	var verdict: Dictionary = await GuardScript.ensure_scene_active(null, "res://main.tscn")
	assert_false(bool(verdict.get("ok", true)))
	assert_true(String(verdict.get("error", "")).length() > 0,
		"A named target without an editor must fail explicitly, not guess")

func test_missing_scene_file_fails_closed() -> void:
	# EditorInterface cannot be instantiated headless; the file-existence branch
	# is exercised through the same guard in scene tools during integration.
	pending("Scene activation paths need a live editor (headless)")
