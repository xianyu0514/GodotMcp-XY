extends "res://addons/gut/test.gd"

const SupervisorScript = preload("res://addons/godot_mcp/native_mcp/mcp_tunnel_supervisor.gd")

func test_parse_user_args_preserves_paths_with_spaces_and_equals() -> void:
	var parsed: Dictionary = SupervisorScript.parse_user_args(PackedStringArray([
		"--mcp-tunnel-binary=C:/Program Files/cloudflared/cloudflared.exe",
		"--mcp-tunnel-log=C:/Users/Test/AppData/GodotMcp-XY/a=b/cloudflared.log",
		"--mcp-tunnel-port=9080",
		"--mcp-tunnel-proxy=http://127.0.0.1:7890",
		"--unrelated=value",
	]))
	assert_eq(parsed.get("binary", ""), "C:/Program Files/cloudflared/cloudflared.exe")
	assert_eq(parsed.get("log", ""), "C:/Users/Test/AppData/GodotMcp-XY/a=b/cloudflared.log")
	assert_eq(parsed.get("port", ""), "9080")
	assert_eq(parsed.get("proxy", ""), "http://127.0.0.1:7890")
	assert_false(parsed.has("unrelated"), "Supervisor must ignore unrelated project arguments")

func test_proxy_environment_exports_proxy_and_loopback_bypass() -> void:
	assert_eq(SupervisorScript.proxy_environment(""), {})
	var env: Dictionary = SupervisorScript.proxy_environment("http://127.0.0.1:7890")
	assert_eq(env.get("HTTPS_PROXY", ""), "http://127.0.0.1:7890")
	assert_eq(env.get("HTTP_PROXY", ""), "http://127.0.0.1:7890")
	assert_eq(env.get("ALL_PROXY", ""), "http://127.0.0.1:7890")
	assert_true(String(env.get("NO_PROXY", "")).contains("127.0.0.1"))
	assert_true(String(env.get("NO_PROXY", "")).contains("localhost"))

func test_cloudflared_args_restore_known_working_pipe_launch() -> void:
	var args: PackedStringArray = SupervisorScript.build_cloudflared_args(9080)
	assert_eq(args[0], "tunnel")
	assert_true(args.has("--no-autoupdate"), "A persisted child must not replace its own PID")
	assert_eq(args[args.find("--url") + 1], "http://localhost:9080")
	assert_eq(args[args.find("--protocol") + 1], "http2", "TCP fallback should work on networks that block QUIC/UDP")
	assert_false(args.has("--logfile"), "The supervisor owns the combined durable output file")

func test_url_detection_rejects_cloudflare_service_hostnames_in_errors() -> void:
	assert_eq(
		SupervisorScript.extract_tunnel_url(
			"Your quick Tunnel has been created! Visit https://happy-tree.trycloudflare.com"
		),
		"https://happy-tree.trycloudflare.com",
		"An allocated public hostname must be detected"
	)
	assert_eq(
		SupervisorScript.extract_tunnel_url("lookup api.trycloudflare.com: no such host"),
		"",
		"A DNS error hostname must not disable pre-URL recovery"
	)
	assert_eq(
		SupervisorScript.extract_tunnel_url(
			"failed to request quick Tunnel from https://api.trycloudflare.com"
		),
		"",
		"Only an allocated public hostname proves that startup succeeded"
	)

func test_extract_tunnel_url_returns_the_allocated_hostname() -> void:
	assert_eq(
		SupervisorScript.extract_tunnel_url(
			"INF |  https://toolbox-several-ceiling-earlier.trycloudflare.com  |"
		),
		"https://toolbox-several-ceiling-earlier.trycloudflare.com",
		"The exact public URL must be extractable from the cloudflared banner"
	)
	assert_eq(
		SupervisorScript.extract_tunnel_url("lookup api.trycloudflare.com: no such host"),
		"",
		"Cloudflare's allocation API must not be mistaken for the public URL"
	)

func test_write_runtime_state_persists_public_url_sidecar() -> void:
	var tmp_root: String = ProjectSettings.globalize_path(
		"user://.tmp_supervisor_sidecar_%d_%d" % [Time.get_ticks_usec(), randi() % 100000]
	)
	DirAccess.make_dir_recursive_absolute(tmp_root)
	var runtime_path: String = tmp_root.path_join("runtime.json")
	var config: Dictionary = {
		"runtime": runtime_path,
		"session": "sidecar-session",
	}
	assert_eq(
		SupervisorScript.write_runtime_state(config, 43210, "https://sidecar-url.trycloudflare.com"),
		OK,
		"The URL sidecar must be written successfully"
	)
	var runtime: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(runtime_path))
	assert_eq(int(runtime.get("schema_version", 0)), 1)
	assert_eq(runtime.get("session", ""), "sidecar-session")
	assert_eq(int(runtime.get("cloudflared_pid", -1)), 43210)
	assert_eq(runtime.get("public_url", ""), "https://sidecar-url.trycloudflare.com")
	assert_eq(
		SupervisorScript.write_runtime_state({}, 1, ""),
		ERR_INVALID_PARAMETER,
		"Missing runtime/session paths must be rejected"
	)
	_remove_recursive(tmp_root)

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

func test_only_pre_url_failures_are_retried_with_a_bound() -> void:
	assert_true(SupervisorScript.should_retry_quick_tunnel(false, 1, 3))
	assert_true(SupervisorScript.should_retry_quick_tunnel(false, 2, 3))
	assert_false(SupervisorScript.should_retry_quick_tunnel(false, 3, 3), "Retry count must be bounded")
	assert_false(SupervisorScript.should_retry_quick_tunnel(true, 1, 3), "A dead published URL must not be silently replaced")

func test_only_a_pre_url_stalled_child_reaches_the_restart_deadline() -> void:
	assert_false(
		SupervisorScript.should_restart_stalled_start(false, 1000, 20999, 20000),
		"A progressing startup keeps its full attempt window"
	)
	assert_true(
		SupervisorScript.should_restart_stalled_start(false, 1000, 21000, 20000),
		"A child that publishes no URL by the deadline should be replaced"
	)
	assert_false(
		SupervisorScript.should_restart_stalled_start(true, 1000, 999999, 20000),
		"A published tunnel is persistent and must never be timed out"
	)

func test_validate_config_requires_every_ownership_path() -> void:
	var valid: Dictionary = {
		"binary": "/opt/cloudflared",
		"log": "/tmp/cloudflared.log",
		"runtime": "/tmp/runtime.json",
		"stop": "/tmp/stop.request",
		"session": "abc123",
		"port": "9080",
	}
	assert_eq(SupervisorScript.validate_config(valid), OK)
	for required_key in ["binary", "log", "runtime", "stop", "session"]:
		var missing: Dictionary = valid.duplicate()
		missing.erase(required_key)
		assert_eq(
			SupervisorScript.validate_config(missing),
			ERR_INVALID_PARAMETER,
			"Missing %s must reject startup" % required_key
		)
	var invalid_port: Dictionary = valid.duplicate()
	invalid_port["port"] = "0"
	assert_eq(SupervisorScript.validate_config(invalid_port), ERR_INVALID_PARAMETER)
	var with_proxy: Dictionary = valid.duplicate()
	with_proxy["proxy"] = "http://127.0.0.1:7890"
	assert_eq(SupervisorScript.validate_config(with_proxy), OK, "An optional proxy must not break validation")
