extends "res://addons/gut/test.gd"

const MCPTunnelManagerScript = preload("res://addons/godot_mcp/native_mcp/mcp_tunnel_manager.gd")

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

func test_extract_url_picks_first_match():
	var text: String = "https://a-one.trycloudflare.com then https://b-two.trycloudflare.com"
	var url: String = MCPTunnelManagerScript.extract_tunnel_url(text)
	assert_eq(url, "https://a-one.trycloudflare.com", "Should return the first matched URL")

func test_new_manager_is_not_running():
	var mgr = MCPTunnelManagerScript.new()
	assert_false(mgr.is_running(), "A freshly created manager should not be running")
	assert_eq(mgr.get_public_url(), "", "A freshly created manager should expose no URL")

func test_start_with_blank_binary_fails():
	var mgr = MCPTunnelManagerScript.new()
	var err: int = mgr.start("", 9080)
	assert_eq(err, ERR_CANT_CREATE, "Blank binary path should fail to start")
