extends "res://addons/gut/test.gd"

const SupervisorScript = preload("res://addons/godot_mcp/native_mcp/mcp_tunnel_supervisor.gd")

func test_parse_user_args_preserves_paths_with_spaces_and_equals() -> void:
	var parsed: Dictionary = SupervisorScript.parse_user_args(PackedStringArray([
		"--mcp-tunnel-binary=C:/Program Files/cloudflared/cloudflared.exe",
		"--mcp-tunnel-log=C:/Users/Test/AppData/GodotMcp-XY/a=b/cloudflared.log",
		"--mcp-tunnel-port=9080",
		"--unrelated=value",
	]))
	assert_eq(parsed.get("binary", ""), "C:/Program Files/cloudflared/cloudflared.exe")
	assert_eq(parsed.get("log", ""), "C:/Users/Test/AppData/GodotMcp-XY/a=b/cloudflared.log")
	assert_eq(parsed.get("port", ""), "9080")
	assert_false(parsed.has("unrelated"), "Supervisor must ignore unrelated project arguments")

func test_cloudflared_args_restore_known_working_pipe_launch() -> void:
	var args: PackedStringArray = SupervisorScript.build_cloudflared_args(9080)
	assert_eq(args[0], "tunnel")
	assert_true(args.has("--no-autoupdate"), "A persisted child must not replace its own PID")
	assert_eq(args[args.find("--url") + 1], "http://localhost:9080")
	assert_eq(args[args.find("--protocol") + 1], "http2", "TCP fallback should work on networks that block QUIC/UDP")
	assert_false(args.has("--logfile"), "The supervisor owns the combined durable output file")

func test_url_detection_rejects_cloudflare_service_hostnames_in_errors() -> void:
	assert_true(SupervisorScript.contains_quick_tunnel_url(
		"Your quick Tunnel has been created! Visit https://happy-tree.trycloudflare.com"
	))
	assert_false(SupervisorScript.contains_quick_tunnel_url(
		"lookup api.trycloudflare.com: no such host"
	), "A DNS error hostname must not disable pre-URL recovery")
	assert_false(SupervisorScript.contains_quick_tunnel_url(
		"failed to request quick Tunnel from https://api.trycloudflare.com"
	), "Only an allocated public hostname proves that startup succeeded")

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
