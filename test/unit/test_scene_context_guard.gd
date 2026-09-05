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

func test_current_scene_resolution_never_falls_back_to_an_arbitrary_open_tab() -> void:
	# EditorInterface.get_open_scene_roots() is an unordered collection of tabs,
	# not an active-scene API. Falling back to its first item can make a tool
	# report or mutate an old scene while get_edited_scene_root() is transitional.
	var consumers: Array[String] = [
		"res://addons/godot_mcp/tools/scene_tools_native.gd",
		"res://addons/godot_mcp/tools/node_tools_native.gd",
		"res://addons/godot_mcp/tools/editor_tools_native.gd",
		"res://addons/godot_mcp/tools/debug_runtime_tools.gd",
	]
	for path in consumers:
		var source: String = FileAccess.get_file_as_string(path)
		var function_start: int = source.find("func _get_user_scene_root()")
		assert_gte(function_start, 0, "%s must define the current-scene helper" % path)
		var function_end: int = source.find("\nfunc ", function_start + 1)
		if function_end < 0:
			function_end = source.length()
		var function_body: String = source.substr(function_start, function_end - function_start)
		assert_false(function_body.contains("get_open_scene_roots"),
			"%s must fail closed instead of choosing an arbitrary open tab" % path)

func test_scene_activation_requires_a_stable_edited_root() -> void:
	var source: String = FileAccess.get_file_as_string(
		"res://addons/godot_mcp/utils/scene_context.gd")
	assert_true(source.contains("ACTIVE_SCENE_STABILITY_FRAMES"),
		"scene activation must define an explicit stability window")
	assert_true(source.contains("stable_frames += 1"),
		"matching edited roots must accumulate consecutive stable frames")
	assert_true(source.contains("stable_frames = 0"),
		"a transitional mismatch must reset the stability window")

func test_scene_activation_retries_silent_editor_open_failures() -> void:
	var source: String = FileAccess.get_file_as_string(
		"res://addons/godot_mcp/utils/scene_context.gd")
	assert_true(source.contains("ACTIVE_SCENE_OPEN_ATTEMPTS"),
		"scene activation must bound explicit open retries")
	assert_true(source.contains("for _attempt in range(ACTIVE_SCENE_OPEN_ATTEMPTS)"),
		"silent open_scene_from_path failures must be retried")
	assert_true(source.contains("editor_fs.update_file(target_scene_path)"),
		"each retry must refresh the target's EditorFileSystem registration")
