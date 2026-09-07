extends "res://addons/gut/test.gd"

const EDITOR_TOOLS = preload("res://addons/godot_mcp/tools/editor_tools_native.gd")

class FakeBridge extends RefCounted:
	var sessions: Array[Dictionary] = []
	var ready_ids: Array[int] = []
	var reset_count: int = 0
	func get_sessions_info() -> Array[Dictionary]:
		return sessions
	func is_probe_ready(session_id: int = -1) -> bool:
		return ready_ids.has(session_id) if session_id >= 0 else not ready_ids.is_empty()
	func reset_probe_ready(_session_id: int = -1) -> void:
		ready_ids.clear()
		reset_count += 1

class FakeEditor extends RefCounted:
	var playing: bool = false
	var stop_calls: int = 0
	var play_calls: int = 0
	var stop_immediately: bool = true
	var on_play: Callable
	func is_playing_scene() -> bool:
		return playing
	func stop_playing_scene() -> void:
		stop_calls += 1
		if stop_immediately:
			playing = false
	func play_custom_scene(_path: String) -> void:
		playing = true
		play_calls += 1
		if on_play.is_valid():
			on_play.call()
	func play_current_scene() -> void:
		play_custom_scene("")
	func play_main_scene() -> void:
		play_custom_scene("")

class Harness extends EDITOR_TOOLS:
	var bridge: FakeBridge = FakeBridge.new()
	var probe_installed: bool = true
	func _get_debugger_bridge() -> RefCounted:
		return bridge
	func _is_runtime_probe_installed() -> bool:
		return probe_installed
	func _get_user_scene_root() -> Node:
		return null

class CaptureCore extends RefCounted:
	var schemas: Dictionary = {}
	func register_tool(tool_name: String, _description: String, input_schema: Dictionary, _handler: Callable, output_schema: Dictionary, _annotations: Dictionary, _category: String, _group: String) -> void:
		schemas[tool_name] = {"input": input_schema, "output": output_schema}

var subject: Harness
var editor: FakeEditor

func before_each() -> void:
	subject = Harness.new()
	editor = FakeEditor.new()

func after_each() -> void:
	editor.on_play = Callable()
	editor = null
	subject = null

func _has_lifecycle_methods() -> bool:
	var supported: bool = subject.has_method("_run_project_with_interface") and subject.has_method("_stop_project_with_interface")
	assert_true(supported, "Lifecycle operations must support honest, shared status inspection")
	return supported

func _set_session(ready: bool = true, breaked: bool = false) -> void:
	editor.playing = true
	subject.bridge.sessions = [{"session_id": 1, "active": true, "breaked": breaked}]
	subject.bridge.ready_ids.assign([1] if ready else [])

func test_reused_live_session_returns_complete_status() -> void:
	if not _has_lifecycle_methods():
		return
	_set_session()
	var result: Dictionary = await subject._run_project_with_interface(editor, {"timeout_ms": 0})
	assert_true(result.get("success", false))
	assert_true(result.get("already_running", false))
	assert_eq(result.get("status"), "success")
	assert_eq(result.get("mode"), "playing")
	assert_eq(result.get("game_status", {}).get("state"), "live")
	assert_true(result.get("probe_ready", false))
	assert_eq(subject.bridge.reset_count, 0, "Reuse must preserve current probe readiness")
	assert_eq(editor.play_calls, 0)

func test_early_exit_during_startup_grace_is_not_success() -> void:
	var launched_editor: FakeEditor = editor
	editor.on_play = func() -> void:
		_set_session()
		get_tree().create_timer(0.03).timeout.connect(func() -> void: launched_editor.playing = false)
	var result: Dictionary = await subject._run_project_with_interface(editor, {"timeout_ms": 150})
	assert_false(result.get("success", true))
	assert_eq(result.get("status"), "started_but_exited")
	assert_eq(result.get("game_status", {}).get("state"), "stopped")

func test_debugger_disconnect_during_grace_retains_upstream_failure() -> void:
	var launched_bridge: FakeBridge = subject.bridge
	editor.on_play = func() -> void:
		_set_session()
		get_tree().create_timer(0.03).timeout.connect(func() -> void: launched_bridge.sessions.clear())
	var result: Dictionary = await subject._run_project_with_interface(editor, {"timeout_ms": 150})
	assert_false(result.get("success", true))
	assert_eq(result.get("status"), "started_but_exited")
	assert_has(result, "error")

func test_connected_session_without_ready_probe_is_pending() -> void:
	if not _has_lifecycle_methods():
		return
	_set_session(false)
	var result: Dictionary = await subject._run_project_with_interface(editor, {"timeout_ms": 0})
	assert_eq(result.get("status"), "pending")
	assert_false(result.get("success", true))
	assert_eq(result.get("game_status", {}).get("state"), "launching")
	assert_false(result.has("error"), "A slow startup is not evidence of a broken scene")

func test_uninstalled_probe_is_supported_but_not_reported_live() -> void:
	if not _has_lifecycle_methods():
		return
	_set_session(false)
	subject.probe_installed = false
	var result: Dictionary = await subject._run_project_with_interface(editor, {"timeout_ms": 0})
	assert_eq(result.get("status"), "success")
	assert_eq(result.get("game_status", {}).get("state"), "no_probe")
	assert_false(result.get("probe_ready", true))

func test_breakpoint_session_is_not_live_even_with_ready_probe() -> void:
	if not _has_lifecycle_methods():
		return
	_set_session(true, true)
	var result: Dictionary = await subject._run_project_with_interface(editor, {"timeout_ms": 0})
	assert_false(result.get("success", true))
	assert_eq(result.get("game_status", {}).get("state"), "break")
	assert_has(result, "error")

func test_inactive_session_ready_flag_cannot_validate_active_session() -> void:
	if not _has_lifecycle_methods():
		return
	_set_session(false)
	subject.bridge.sessions.append({"session_id": 0, "active": false, "breaked": false})
	subject.bridge.ready_ids = [0]
	var result: Dictionary = await subject._run_project_with_interface(editor, {"timeout_ms": 0})
	assert_eq(result.get("game_status", {}).get("state"), "launching")
	assert_false(result.get("probe_ready", true))

func test_invalid_scene_does_not_stop_existing_game() -> void:
	if not _has_lifecycle_methods():
		return
	_set_session()
	var result: Dictionary = await subject._run_project_with_interface(editor, {"scene_path": "res://missing_lifecycle_scene.tscn"})
	assert_has(result, "error")
	assert_eq(editor.stop_calls, 0)
	assert_true(editor.playing)

func test_non_scene_file_does_not_stop_existing_game() -> void:
	if not _has_lifecycle_methods():
		return
	_set_session()
	var result: Dictionary = await subject._run_project_with_interface(editor, {"scene_path": "res://project.godot"})
	assert_has(result, "error")
	assert_eq(editor.stop_calls, 0)

func test_new_launch_resets_stale_probe_and_waits_for_current_ready() -> void:
	if not _has_lifecycle_methods():
		return
	subject.bridge.ready_ids = [0]
	editor.on_play = func() -> void:
		subject.bridge.sessions = [{"session_id": 1, "active": true, "breaked": false}]
		_ready_on_next_frame.call_deferred()
	var result: Dictionary = await subject._run_project_with_interface(editor, {"timeout_ms": 1000})
	assert_eq(subject.bridge.reset_count, 1)
	assert_eq(result.get("game_status", {}).get("state"), "live")
	assert_eq(editor.play_calls, 1)

func _ready_on_next_frame() -> void:
	await get_tree().process_frame
	subject.bridge.ready_ids = [1]

func test_game_exit_during_probe_wait_returns_stopped() -> void:
	if not _has_lifecycle_methods():
		return
	_set_session(false)
	_stop_on_next_frame.call_deferred()
	var result: Dictionary = await subject._run_project_with_interface(editor, {"timeout_ms": 1000})
	assert_has(result, "error")
	assert_eq(result.get("game_status", {}).get("state"), "stopped")
	assert_false(result.get("session_active", true))

func _stop_on_next_frame() -> void:
	await get_tree().process_frame
	editor.playing = false
	subject.bridge.sessions.clear()

func test_stop_already_stopped_is_idempotent() -> void:
	if not _has_lifecycle_methods():
		return
	var result: Dictionary = await subject._stop_project_with_interface(editor, {"timeout_ms": 0})
	assert_eq(result.get("status"), "success")
	assert_eq(result.get("mode"), "editor")
	assert_eq(result.get("game_status", {}).get("state"), "stopped")
	assert_eq(result.get("stopped_after_ms"), 0)
	assert_eq(editor.stop_calls, 0)

func test_stop_yields_frames_until_editor_confirms_exit() -> void:
	if not _has_lifecycle_methods():
		return
	_set_session()
	editor.stop_immediately = false
	_stop_on_next_frame.call_deferred()
	var result: Dictionary = await subject._stop_project_with_interface(editor, {"timeout_ms": 1000})
	assert_eq(result.get("status"), "success")
	assert_eq(result.get("game_status", {}).get("state"), "stopped")
	assert_false(editor.playing)
	assert_eq(editor.stop_calls, 1)

func test_stop_timeout_reports_failure_and_preserves_scene() -> void:
	if not _has_lifecycle_methods():
		return
	_set_session()
	editor.stop_immediately = false
	subject._last_played_scene = "res://still_running.tscn"
	var result: Dictionary = await subject._stop_project_with_interface(editor, {"timeout_ms": 0})
	assert_has(result, "error")
	assert_eq(result.get("status"), "error")
	assert_eq(result.get("mode"), "playing")
	assert_eq(subject._last_played_scene, "res://still_running.tscn")

func test_switch_does_not_start_next_scene_when_stop_times_out() -> void:
	if not _has_lifecycle_methods():
		return
	_set_session()
	editor.stop_immediately = false
	var path: String = "res://test/fixtures/lifecycle_scene.tscn"
	var result: Dictionary = await subject._run_project_with_interface(editor, {"scene_path": path, "timeout_ms": 0})
	assert_has(result, "error")
	assert_eq(editor.play_calls, 0)
	assert_eq(editor.stop_calls, 1)

func test_lifecycle_rejects_invalid_timeout_before_editor_mutation() -> void:
	if not _has_lifecycle_methods():
		return
	for invalid in [-1, 60001, "soon", true, 1.5]:
		var run_result: Dictionary = await subject._run_project_with_interface(editor, {"timeout_ms": invalid})
		var stop_result: Dictionary = await subject._stop_project_with_interface(editor, {"timeout_ms": invalid})
		assert_has(run_result, "error")
		assert_has(stop_result, "error")
	assert_eq(editor.play_calls, 0)
	assert_eq(editor.stop_calls, 0)

func test_public_handlers_validate_timeout_before_editor_lookup() -> void:
	var run_result: Dictionary = await subject._tool_run_project({"allow_window": true, "timeout_ms": -1})
	var stop_result: Dictionary = await subject._tool_stop_project({"allow_window": true, "timeout_ms": "invalid"})
	assert_string_contains(run_result.get("error", ""), "timeout_ms")
	assert_string_contains(stop_result.get("error", ""), "timeout_ms")

func test_scene_path_type_is_validated_without_mutation() -> void:
	_set_session()
	var result: Dictionary = await subject._run_project_with_interface(editor, {"scene_path": 123})
	assert_string_contains(result.get("error", ""), "scene_path")
	assert_eq(editor.stop_calls, 0)
	assert_eq(editor.play_calls, 0)

func test_game_without_active_debugger_session_stays_pending() -> void:
	editor.playing = true
	var result: Dictionary = await subject._run_project_with_interface(editor, {"timeout_ms": 0})
	assert_eq(result.get("status"), "pending")
	assert_eq(result.get("game_status", {}).get("state"), "launching")
	assert_false(result.get("session_active", true))

func test_output_schemas_preserve_legacy_fields_and_expose_game_status() -> void:
	var core: CaptureCore = CaptureCore.new()
	subject._register_run_project(core)
	subject._register_stop_project(core)
	for tool_name in ["run_project", "stop_project"]:
		var output: Dictionary = core.schemas[tool_name]["output"]["properties"]
		for field in ["status", "success", "mode", "game_status"]:
			assert_has(output, field)
		var timeout: Dictionary = core.schemas[tool_name]["input"]["properties"]["timeout_ms"]
		assert_false(timeout.has("minimum"), "Keep schemas compatible with strict MCP clients")
		assert_true(String(timeout["description"]).contains("0-60000"))
	assert_has(core.schemas["run_project"]["output"]["properties"], "scene")
	assert_has(core.schemas["stop_project"]["output"]["properties"], "stopped_after_ms")
