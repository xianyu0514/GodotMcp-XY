extends "res://addons/gut/test.gd"

const MCPTunnelManagerScript = preload("res://addons/godot_mcp/native_mcp/mcp_tunnel_manager.gd")

var _tmp_root: String = ""

class FakeTunnelManager extends MCPTunnelManager:
	var fake_pid: int = 424242
	var fake_running: bool = true
	var fake_child_running: bool = true
	var fake_command_line: String = ""
	var spawned_binary: String = ""
	var spawned_args: PackedStringArray = []
	var stop_requested: bool = false
	var killed_pid: int = -1

	func _spawn_process(binary_path: String, args: PackedStringArray) -> int:
		spawned_binary = binary_path
		spawned_args = args
		return fake_pid

	func _is_process_running(process_id: int) -> bool:
		return fake_running and fake_child_running and process_id == fake_pid

	func _is_external_process_running(process_id: int) -> bool:
		return fake_running and process_id == fake_pid

	func _read_process_command_line(process_id: int) -> String:
		if process_id != fake_pid:
			return ""
		if not fake_command_line.is_empty():
			return fake_command_line
		return '"%s" %s' % [spawned_binary, " ".join(spawned_args)]

	func _write_stop_request() -> Error:
		stop_requested = true
		fake_running = false
		return OK

	func _terminate_process(process_id: int) -> Error:
		killed_pid = process_id
		fake_running = false
		return OK

class SameProcessRestoreTunnelManager extends MCPTunnelManager:
	var expected_pid: int = -1
	var expected_command_line: String = ""

	func _is_external_process_running(process_id: int) -> bool:
		return process_id == expected_pid and OS.is_process_running(process_id)

	func _read_process_command_line(process_id: int) -> String:
		return expected_command_line if process_id == expected_pid else ""

func before_each() -> void:
	_tmp_root = ProjectSettings.globalize_path(
		"user://.tmp_tunnel_manager_%d_%d" % [Time.get_ticks_usec(), randi() % 100000]
	)
	DirAccess.make_dir_recursive_absolute(_tmp_root)

func after_each() -> void:
	_remove_recursive(_tmp_root)

func _remove_recursive(path: String) -> void:
	if path.is_empty() or not DirAccess.dir_exists_absolute(path):
		return
	var dir: DirAccess = DirAccess.open(path)
	if dir == null:
		return
	dir.list_dir_begin()
	var entry: String = dir.get_next()
	while not entry.is_empty():
		var full_path: String = path.path_join(entry)
		if dir.current_is_dir():
			_remove_recursive(full_path)
		else:
			DirAccess.remove_absolute(full_path)
		entry = dir.get_next()
	dir.list_dir_end()
	DirAccess.remove_absolute(path)

func _write_file(path: String, content: String) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	assert_not_null(file, "Test fixture should be writable")
	if file != null:
		file.store_string(content)
		file.close()

func test_extract_url_from_banner_line():
	var line: String = "2026-06-21T18:00:00Z INF +-----+\n|  https://happy-tree-1234.trycloudflare.com  |\n+-----+"
	var url: String = MCPTunnelManagerScript.extract_tunnel_url(line)
	assert_eq(url, "https://happy-tree-1234.trycloudflare.com", "Should pull the trycloudflare URL out of the log banner")

func test_extract_url_returns_empty_when_absent():
	var url: String = MCPTunnelManagerScript.extract_tunnel_url("INF Starting tunnel connection...")
	assert_eq(url, "", "No URL present should return an empty string")

func test_extract_url_ignores_other_hosts():
	var url: String = MCPTunnelManagerScript.extract_tunnel_url("see https://example.com/docs for help")
	assert_eq(url, "", "Only trycloudflare.com hosts should match")
	assert_eq(
		MCPTunnelManagerScript.extract_tunnel_url("request failed: https://api.trycloudflare.com"),
		"",
		"Cloudflare's allocation API is not the user's public tunnel"
	)

func test_extract_url_picks_first_match():
	var text: String = "https://api.trycloudflare.com then https://a-one.trycloudflare.com then https://b-two.trycloudflare.com"
	var url: String = MCPTunnelManagerScript.extract_tunnel_url(text)
	assert_eq(url, "https://a-one.trycloudflare.com", "Should return the first allocated public URL")

func test_startup_failure_classification_is_actionable_without_leaking_english_ui() -> void:
	assert_eq(MCPTunnelManagerScript.classify_startup_failure("lookup api.trycloudflare.com: no such host"), "dns")
	assert_eq(MCPTunnelManagerScript.classify_startup_failure("failed to request quick Tunnel: i/o timeout"), "timeout")
	assert_eq(MCPTunnelManagerScript.classify_startup_failure("x509: certificate signed by unknown authority"), "tls")
	assert_eq(MCPTunnelManagerScript.classify_startup_failure("proxyconnect tcp: connection refused"), "proxy")
	assert_eq(MCPTunnelManagerScript.classify_startup_failure("HTTP status 429 too many requests"), "rate_limited")
	assert_eq(MCPTunnelManagerScript.classify_startup_failure("failed to request quick Tunnel: status 503"), "service")
	assert_eq(MCPTunnelManagerScript.classify_startup_failure("unrecognized fatal line"), "unknown")

func test_normalize_proxy_url_adds_scheme_and_trims_slash() -> void:
	assert_eq(MCPTunnelManagerScript.normalize_proxy_url("127.0.0.1:7890"), "http://127.0.0.1:7890")
	assert_eq(MCPTunnelManagerScript.normalize_proxy_url("http://127.0.0.1:7890/"), "http://127.0.0.1:7890")
	assert_eq(MCPTunnelManagerScript.normalize_proxy_url("  "), "")

func test_proxy_from_environment_prefers_https() -> void:
	assert_eq(
		MCPTunnelManagerScript.proxy_from_environment({
			"HTTPS_PROXY": "http://127.0.0.1:7890",
			"HTTP_PROXY": "http://127.0.0.1:8080",
		}),
		"http://127.0.0.1:7890"
	)
	assert_eq(
		MCPTunnelManagerScript.proxy_from_environment({"http_proxy": "127.0.0.1:8080"}),
		"http://127.0.0.1:8080"
	)
	assert_eq(MCPTunnelManagerScript.proxy_from_environment({}), "")

func test_parse_windows_proxy_server_prefers_https() -> void:
	assert_eq(
		MCPTunnelManagerScript.parse_windows_proxy_server(
			"http=127.0.0.1:8080;https=127.0.0.1:7890;socks=127.0.0.1:1080"
		),
		"https://127.0.0.1:7890"
	)
	assert_eq(
		MCPTunnelManagerScript.parse_windows_proxy_server("127.0.0.1:7890"),
		"http://127.0.0.1:7890"
	)
	assert_eq(
		MCPTunnelManagerScript.parse_windows_proxy_server("socks=127.0.0.1:1080"),
		"socks5://127.0.0.1:1080"
	)

func test_new_manager_is_not_running():
	var mgr = MCPTunnelManagerScript.new()
	assert_false(mgr.is_running(), "A freshly created manager should not be running")
	assert_eq(mgr.get_public_url(), "", "A freshly created manager should expose no URL")

func test_start_with_blank_binary_fails():
	var mgr = MCPTunnelManagerScript.new(_tmp_root)
	var err: int = mgr.start("", 9080)
	assert_eq(err, ERR_CANT_CREATE, "Blank binary path should fail to start")

func test_supervisor_launch_args_preserve_all_paths_without_shell_quoting() -> void:
	var log_path: String = _tmp_root.path_join("cloudflared.log")
	var runtime_path: String = _tmp_root.path_join("runtime.json")
	var stop_path: String = _tmp_root.path_join("stop.request")
	var args: PackedStringArray = MCPTunnelManagerScript.build_supervisor_launch_args(
		"C:/My Game", "C:/My Game/addons/supervisor.gd", "C:/Program Files/cloudflared.exe",
		9080, log_path, runtime_path, stop_path, "session-123", "http://127.0.0.1:7890"
	)
	assert_eq(args[0], "--headless")
	assert_true(args.has("--script"))
	assert_true(args.has("--"), "Tunnel ownership values must be passed as Godot user arguments")
	assert_true(args.has("--mcp-tunnel-binary=C:/Program Files/cloudflared.exe"))
	assert_true(args.has("--mcp-tunnel-log=%s" % log_path))
	assert_true(args.has("--mcp-tunnel-runtime=%s" % runtime_path))
	assert_true(args.has("--mcp-tunnel-stop=%s" % stop_path))
	assert_true(args.has("--mcp-tunnel-session=session-123"))
	assert_true(args.has("--mcp-tunnel-proxy=http://127.0.0.1:7890"))

func test_project_session_directory_is_stable_and_project_scoped() -> void:
	var first: String = MCPTunnelManagerScript.default_session_dir("/work/game-a")
	assert_eq(first, MCPTunnelManagerScript.default_session_dir("/work/game-a"))
	assert_ne(first, MCPTunnelManagerScript.default_session_dir("/work/game-b"))
	assert_true(first.is_absolute_path(), "Session state must survive editor and project reloads")

func test_start_persists_url_and_detach_keeps_process_alive() -> void:
	var mgr := FakeTunnelManager.new(_tmp_root)
	assert_eq(mgr.start("/opt/cloudflared", 9080), OK)
	assert_eq(mgr.spawned_binary, OS.get_executable_path().simplify_path())
	assert_true(mgr.spawned_args.has("--mcp-tunnel-binary=/opt/cloudflared"))
	assert_true(FileAccess.file_exists(mgr.get_state_path()), "Launch should persist ownership metadata")

	var url: String = "https://persistent-session.trycloudflare.com"
	_write_file(mgr.get_log_path(), "INF Quick Tunnel: %s\n" % url)
	assert_eq(mgr.poll(), url, "Manager should discover the URL from the durable log")
	var state: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(mgr.get_state_path()))
	assert_eq(state.get("public_url", ""), url, "Discovered URL must survive a new Godot instance")

	mgr.detach()
	assert_true(mgr.fake_running, "Detaching the Godot panel must not terminate cloudflared")
	assert_eq(mgr.killed_pid, -1)
	assert_true(FileAccess.file_exists(mgr.get_state_path()), "Detach must preserve the resumable session")

func test_poll_reads_url_from_runtime_sidecar_without_log() -> void:
	var mgr := FakeTunnelManager.new(_tmp_root)
	assert_eq(mgr.start("/opt/cloudflared", 9080), OK)
	var session_id: String = mgr.get_state_path().sha256_text().substr(0, 32)
	var runtime_path: String = mgr.get_state_path().get_base_dir().path_join("runtime.json")
	var sidecar_url: String = "https://sidecar-only.trycloudflare.com"
	_write_file(runtime_path, JSON.stringify({
		"schema_version": 1,
		"session": session_id,
		"supervisor_pid": mgr.get_pid(),
		"cloudflared_pid": 777777,
		"public_url": sidecar_url,
	}, "\t"))
	assert_eq(
		mgr.poll(),
		sidecar_url,
		"Manager must discover the URL from the supervisor's lock-free sidecar"
	)
	var state: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(mgr.get_state_path()))
	assert_eq(state.get("public_url", ""), sidecar_url, "Sidecar URL must be persisted to resumable state")

func test_live_supervisor_captures_pipe_url_and_survives_detach() -> void:
	if OS.get_name() != "Linux":
		pending("Live supervisor fixture uses a POSIX executable and is covered by Linux CI")
		return
	var fake_cloudflared: String = _tmp_root.path_join("fake cloudflared")
	_write_file(fake_cloudflared, "#!/bin/sh\nprintf '%s\\n' 'https://pipe-only.trycloudflare.com' >&2\nwhile true; do sleep 1; done\n")
	assert_eq(OS.execute("chmod", PackedStringArray(["+x", fake_cloudflared])), 0)
	var first = MCPTunnelManagerScript.new(_tmp_root)
	assert_eq(first.start(fake_cloudflared, 9080), OK)
	var process_id: int = first.get_pid()
	var url: String = ""
	var deadline: int = Time.get_ticks_msec() + 5000
	while url.is_empty() and first.is_running() and Time.get_ticks_msec() < deadline:
		url = first.poll()
		if url.is_empty():
			OS.delay_msec(25)
	assert_eq(url, "https://pipe-only.trycloudflare.com", "URL must be captured even when it never reaches --logfile")
	first.detach()
	assert_true(OS.is_process_running(process_id), "Tunnel supervisor must remain alive after manager detach")

	var restored := SameProcessRestoreTunnelManager.new(_tmp_root)
	var persisted_state: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(restored.get_state_path()))
	restored.expected_pid = process_id
	restored.expected_command_line = '"%s" --headless --script "%s" -- --mcp-tunnel-session=%s' % [
		persisted_state.get("supervisor_executable", ""),
		persisted_state.get("supervisor_script", ""),
		persisted_state.get("session_id", ""),
	]
	assert_true(restored.restore(), "The independent pipe-launched process must remain adoptable")
	restored.stop()
	assert_false(FileAccess.file_exists(restored.get_state_path()), "Cleanup removes the live fixture session")
	assert_true(
		FileAccess.get_file_as_string(restored.get_log_path()).contains("Stop requested by the user"),
		"Supervisor must receive the explicit stop request and terminate its child"
	)

func test_live_supervisor_retries_transient_pre_url_failures() -> void:
	if OS.get_name() != "Linux":
		pending("Live retry fixture uses a POSIX executable and is covered by Linux CI")
		return
	var attempt_file: String = _tmp_root.path_join("attempt-count")
	var fake_cloudflared: String = _tmp_root.path_join("retrying cloudflared")
	_write_file(fake_cloudflared, "#!/bin/sh\nCOUNT_FILE='%s'\ncount=0\nif [ -f \"$COUNT_FILE\" ]; then count=$(cat \"$COUNT_FILE\"); fi\ncount=$((count + 1))\nprintf '%%s' \"$count\" > \"$COUNT_FILE\"\nif [ \"$count\" -lt 3 ]; then echo 'failed to request quick Tunnel: i/o timeout' >&2; exit 1; fi\necho 'https://retry-success.trycloudflare.com' >&2\nwhile true; do sleep 1; done\n" % attempt_file)
	assert_eq(OS.execute("chmod", PackedStringArray(["+x", fake_cloudflared])), 0)
	var manager = MCPTunnelManagerScript.new(_tmp_root)
	assert_eq(manager.start(fake_cloudflared, 9080), OK)
	var url: String = ""
	var deadline: int = Time.get_ticks_msec() + 8000
	while url.is_empty() and manager.is_running() and Time.get_ticks_msec() < deadline:
		url = manager.poll()
		if url.is_empty():
			OS.delay_msec(25)
	assert_eq(url, "https://retry-success.trycloudflare.com")
	assert_eq(FileAccess.get_file_as_string(attempt_file), "3", "Two transient failures should recover on the bounded third attempt")
	manager.stop()

func test_restore_adopts_same_process_and_explicit_stop_terminates_it() -> void:
	var first := FakeTunnelManager.new(_tmp_root)
	assert_eq(first.start("/opt/cloudflared", 9080), OK)
	var url: String = "https://reuse-me.trycloudflare.com"
	_write_file(first.get_log_path(), "INF %s\n" % url)
	assert_eq(first.poll(), url)
	first.detach()

	var restored := FakeTunnelManager.new(_tmp_root)
	var state: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(restored.get_state_path()))
	restored.fake_command_line = '"%s" --headless --script "%s" -- --mcp-tunnel-session=%s' % [
		state.get("supervisor_executable", ""),
		state.get("supervisor_script", ""),
		state.get("session_id", ""),
	]
	restored.fake_child_running = false
	assert_true(restored.restore(), "A new plugin instance should adopt the live detached tunnel")
	assert_true(restored.is_running())
	assert_eq(restored.get_public_url(), url)
	assert_eq(restored.get_port(), 9080)
	assert_eq(restored.start("/opt/cloudflared", 9080), ERR_ALREADY_IN_USE, "Restore prevents duplicate Quick Tunnels")

	# A restored PID belongs to the previous Godot process, so the child-only
	# process API may reject it even though the external process is still alive.
	restored.stop()
	assert_true(restored.stop_requested, "Only the explicit Stop action should ask the supervisor to kill the tunnel")
	assert_false(FileAccess.file_exists(restored.get_state_path()), "Explicit Stop removes resumable state")

func test_restore_keeps_legacy_direct_tunnel_sessions_compatible() -> void:
	var first := FakeTunnelManager.new(_tmp_root)
	assert_eq(first.start("/opt/cloudflared", 9080), OK)
	var state: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(first.get_state_path()))
	state["schema_version"] = MCPTunnelManagerScript.LEGACY_STATE_SCHEMA_VERSION
	for key in ["supervisor_executable", "supervisor_script", "session_id", "runtime_path", "stop_path"]:
		state.erase(key)
	_write_file(first.get_state_path(), JSON.stringify(state, "\t"))
	first.detach()

	var restored := FakeTunnelManager.new(_tmp_root)
	restored.fake_command_line = '"/opt/cloudflared" tunnel --logfile "%s" --url http://localhost:9080' % restored.get_log_path()
	assert_true(restored.restore(), "Updating the plugin must adopt a live schema-1 tunnel")
	restored.stop()
	assert_eq(restored.killed_pid, restored.fake_pid, "Explicit Stop still owns the legacy direct process")

func test_restore_rejects_pid_reuse_when_command_does_not_own_session_log() -> void:
	var first := FakeTunnelManager.new(_tmp_root)
	assert_eq(first.start("/opt/cloudflared", 9080), OK)
	first.detach()

	var stale := FakeTunnelManager.new(_tmp_root)
	stale.fake_command_line = "unrelated-program --pid 424242"
	assert_false(stale.restore(), "A reused PID must not be mistaken for the old cloudflared process")
	assert_eq(stale.killed_pid, -1, "Rejecting stale state must never kill the unrelated process")
	assert_false(FileAccess.file_exists(stale.get_state_path()), "Stale session metadata should be discarded")

func test_restore_discards_session_after_computer_shutdown() -> void:
	var first := FakeTunnelManager.new(_tmp_root)
	assert_eq(first.start("/opt/cloudflared", 9080), OK)
	first.detach()

	var after_reboot := FakeTunnelManager.new(_tmp_root)
	after_reboot.fake_running = false
	assert_false(after_reboot.restore(), "A stopped process must not be recreated automatically after reboot")
	assert_eq(after_reboot.killed_pid, -1)
	assert_false(FileAccess.file_exists(after_reboot.get_state_path()))

func test_command_line_identity_requires_cloudflared_and_exact_session_log() -> void:
	var log_path: String = "C:\\Users\\Tester\\GodotMcp-XY\\tunnels\\abc\\cloudflared.log"
	var binary_path: String = "C:\\Tools\\cloudflared.exe"
	var valid: String = '"%s" tunnel --logfile "%s" --url http://localhost:9080' % [binary_path, log_path]
	assert_true(MCPTunnelManagerScript.command_line_matches_session(valid, binary_path, log_path, "Windows"))
	assert_false(MCPTunnelManagerScript.command_line_matches_session(
		valid.replace(log_path, "C:\\Temp\\other.log"), binary_path, log_path, "Windows"
	))
	assert_false(MCPTunnelManagerScript.command_line_matches_session(
		'wrapper.exe --name "%s" tunnel --logfile "%s"' % [binary_path, log_path],
		binary_path,
		log_path,
		"Windows"
	), "Mentioning the binary and log as arguments must not prove process ownership")
	assert_false(MCPTunnelManagerScript.command_line_matches_session(
		valid.replace("cloudflared.exe", "unrelated.exe"), binary_path, log_path, "Windows"
	))

func test_supervisor_and_child_command_identity_are_session_scoped() -> void:
	var executable: String = "C:\\Godot\\Godot.exe"
	var script: String = "C:\\Game\\addons\\godot_mcp\\native_mcp\\mcp_tunnel_supervisor.gd"
	var session_id: String = "abc123"
	var supervisor_command: String = '"%s" --headless --script "%s" -- --mcp-tunnel-session=%s' % [
		executable, script, session_id,
	]
	assert_true(MCPTunnelManagerScript.supervisor_command_matches_session(
		supervisor_command, executable, script, session_id, "Windows"
	))
	assert_false(MCPTunnelManagerScript.supervisor_command_matches_session(
		supervisor_command, executable, script, "other-session", "Windows"
	))
	var child_command: String = '"C:\\Tools\\cloudflared.exe" tunnel --no-autoupdate --url http://localhost:9080'
	assert_true(MCPTunnelManagerScript.cloudflared_command_matches(
		child_command, "C:\\Tools\\cloudflared.exe", 9080, "Windows"
	))
	assert_false(MCPTunnelManagerScript.cloudflared_command_matches(
		child_command, "C:\\Tools\\cloudflared.exe", 9081, "Windows"
	))

func test_cloudflared_command_matches_accepts_both_origin_forms() -> void:
	var legacy: String = '"C:\\Tools\\cloudflared.exe" tunnel --no-autoupdate --url http://localhost:9080'
	assert_true(MCPTunnelManagerScript.cloudflared_command_matches(
		legacy, "C:\\Tools\\cloudflared.exe", 9080, "Windows"),
		"Persisted sessions from before the 127.0.0.1 switch must stay adoptable")
	var modern: String = '"C:\\Tools\\cloudflared.exe" tunnel --no-autoupdate --url http://127.0.0.1:9080'
	assert_true(MCPTunnelManagerScript.cloudflared_command_matches(
		modern, "C:\\Tools\\cloudflared.exe", 9080, "Windows"))
