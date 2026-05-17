extends "res://addons/gut/test.gd"

var _bridge: MCPDebuggerBridge = null
var _headless_skip: bool = false

func before_each():
	var script = load("res://addons/godot_mcp/native_mcp/mcp_debugger_bridge.gd")
	if not script:
		_headless_skip = true
		return
	_bridge = script.new()
	if not _bridge:
		_headless_skip = true

func after_each():
	_bridge = null
	_headless_skip = false

func test_get_sessions_info_empty_before_registered_with_editor():
	if _headless_skip:
		pending("EditorDebuggerPlugin not available in headless/CLI mode")
		return
	var sessions: Array = _bridge.get_sessions_info()
	assert_eq(sessions.size(), 0, "Unregistered bridge should have no debugger sessions")

func test_for_each_session_returns_no_sessions_when_unregistered():
	if _headless_skip:
		pending("EditorDebuggerPlugin not available in headless/CLI mode")
		return
	var result: Dictionary = _bridge.set_breakpoint("res://player.gd", 1, true)
	assert_eq(result.status, "no_sessions", "Unregistered bridge should report no sessions")
	assert_eq(result.sessions_updated, 0, "No sessions should be updated")

func test_capture_prefix_defaults_to_mcp():
	if _headless_skip:
		pending("EditorDebuggerPlugin not available in headless/CLI mode")
		return
	assert_true(_bridge._has_capture("mcp"), "Bridge should capture mcp-prefixed debugger messages by default")
	assert_false(_bridge._has_capture("other"), "Bridge should ignore unrelated prefixes by default")

func test_add_capture_prefix():
	if _headless_skip:
		pending("EditorDebuggerPlugin not available in headless/CLI mode")
		return
	_bridge.add_capture_prefix("ai")
	assert_true(_bridge._has_capture("ai"), "Added prefix should be captured")

func test_capture_stores_messages():
	if _headless_skip:
		pending("EditorDebuggerPlugin not available in headless/CLI mode")
		return
	var captured: bool = _bridge._capture("mcp:test", ["hello"], 2)
	assert_true(captured, "Capture should report handled")
	var result: Dictionary = _bridge.get_captured_messages(10, 0, "asc")
	assert_eq(result.count, 1, "Should return one captured message")
	assert_eq(result.messages[0].session_id, 2, "Should preserve session id")
	assert_eq(result.messages[0].message, "mcp:test", "Should preserve message name")

func test_stack_dump_signal_updates_latest_frames():
	if _headless_skip:
		pending("EditorDebuggerPlugin not available in headless/CLI mode")
		return
	var frames: Array = [{"frame": 0, "file": "res://player.gd", "function": "_ready", "line": 12}]
	_bridge._on_stack_dump(frames)
	assert_eq(_bridge.get_latest_stack_dump().size(), 1, "Should store latest stack frames")
	assert_eq(_bridge.get_latest_stack_dump()[0].file, "res://player.gd", "Should preserve stack frame data")

func test_stack_frame_var_decodes_variable_payload():
	if _headless_skip:
		pending("EditorDebuggerPlugin not available in headless/CLI mode")
		return
	_bridge._on_stack_frame_vars(1)
	_bridge._on_stack_frame_var(["speed", 0, TYPE_FLOAT, 12.5])
	var variables: Array = _bridge.get_latest_stack_variables(0)
	assert_eq(variables.size(), 1, "Should store latest stack variable")
	assert_eq(variables[0].name, "speed", "Should decode variable name")
	assert_eq(variables[0].scope, "local", "Should decode variable scope")
	assert_eq(variables[0].type, "float", "Should decode variable type")
	assert_eq(variables[0].value, 12.5, "Should preserve variable value")

func test_probe_ready_initially_false():
	if _headless_skip:
		pending("EditorDebuggerPlugin not available in headless/CLI mode")
		return
	assert_false(_bridge.is_probe_ready(0), "Probe should not be ready before probe_ready message")
	assert_false(_bridge.is_probe_ready(-1), "No session should have probe ready initially")

func test_probe_ready_after_capture():
	if _headless_skip:
		pending("EditorDebuggerPlugin not available in headless/CLI mode")
		return
	_bridge._capture("mcp:probe_ready", [{"status": "ok"}], 0)
	assert_true(_bridge.is_probe_ready(0), "Probe should be ready after probe_ready message on session 0")
	assert_false(_bridge.is_probe_ready(1), "Other session should not be affected")

func test_probe_ready_any_session():
	if _headless_skip:
		pending("EditorDebuggerPlugin not available in headless/CLI mode")
		return
	_bridge._capture("mcp:probe_ready", [{"status": "ok"}], 0)
	assert_true(_bridge.is_probe_ready(-1), "Any session check should be true when at least one session is ready")

func test_reset_probe_ready_specific_session():
	if _headless_skip:
		pending("EditorDebuggerPlugin not available in headless/CLI mode")
		return
	_bridge._capture("mcp:probe_ready", [{"status": "ok"}], 0)
	_bridge._capture("mcp:probe_ready", [{"status": "ok"}], 1)
	_bridge.reset_probe_ready(0)
	assert_false(_bridge.is_probe_ready(0), "Session 0 should be reset")
	assert_true(_bridge.is_probe_ready(1), "Session 1 should remain ready")

func test_reset_probe_ready_all_sessions():
	if _headless_skip:
		pending("EditorDebuggerPlugin not available in headless/CLI mode")
		return
	_bridge._capture("mcp:probe_ready", [{"status": "ok"}], 0)
	_bridge._capture("mcp:probe_ready", [{"status": "ok"}], 1)
	_bridge.reset_probe_ready(-1)
	assert_false(_bridge.is_probe_ready(0), "Session 0 should be reset")
	assert_false(_bridge.is_probe_ready(1), "Session 1 should be reset")
	assert_false(_bridge.is_probe_ready(-1), "No session should be ready after full reset")

func test_setup_session_resets_probe_ready():
	if _headless_skip:
		pending("EditorDebuggerPlugin not available in headless/CLI mode")
		return
	_bridge._capture("mcp:probe_ready", [{"status": "ok"}], 0)
	_bridge._setup_session(0)
	assert_false(_bridge.is_probe_ready(0), "Probe ready should be reset on session setup")

func test_wait_for_probe_ready_returns_immediately_when_ready():
	if _headless_skip:
		pending("EditorDebuggerPlugin not available in headless/CLI mode")
		return
	_bridge._capture("mcp:probe_ready", [{"status": "ok"}], 0)
	var result: bool = await _bridge.wait_for_probe_ready(0, 100)
	assert_true(result, "Should return true immediately when probe is already ready")

func test_wait_for_probe_ready_times_out_when_not_ready():
	if _headless_skip:
		pending("EditorDebuggerPlugin not available in headless/CLI mode")
		return
	var start_ms: int = Time.get_ticks_msec()
	var result: bool = await _bridge.wait_for_probe_ready(0, 200)
	var elapsed: int = Time.get_ticks_msec() - start_ms
	assert_false(result, "Should return false when probe never becomes ready")
	assert_true(elapsed >= 150, "Should have waited near timeout (elapsed=%d)" % elapsed)