extends "res://addons/gut/test.gd"

const MCPClientConfigScript = preload("res://addons/godot_mcp/native_mcp/mcp_client_config.gd")

func _parse(text: String) -> Dictionary:
	var parsed = JSON.parse_string(text)
	assert_eq(typeof(parsed), TYPE_DICTIONARY, "Generated config should be valid JSON object")
	return parsed if typeof(parsed) == TYPE_DICTIONARY else {}

func test_http_config_is_valid_json_with_server_entry():
	var text: String = MCPClientConfigScript.http_config(9080)
	var data: Dictionary = _parse(text)
	assert_true(data.has("mcpServers"), "Config should have mcpServers root")
	assert_true(data["mcpServers"].has("godot-mcp"), "Config should register godot-mcp server")

func test_http_config_uses_given_port():
	var text: String = MCPClientConfigScript.http_config(12345)
	var data: Dictionary = _parse(text)
	var url: String = data["mcpServers"]["godot-mcp"]["url"]
	assert_eq(url, "http://127.0.0.1:12345/mcp", "URL should embed the given port and /mcp path")

func test_http_config_falls_back_to_default_port():
	var text: String = MCPClientConfigScript.http_config(0)
	var data: Dictionary = _parse(text)
	var url: String = data["mcpServers"]["godot-mcp"]["url"]
	assert_eq(url, "http://127.0.0.1:9080/mcp", "Non-positive port should fall back to default 9080")

func test_http_config_without_token_omits_headers():
	var text: String = MCPClientConfigScript.http_config(9080, "")
	var data: Dictionary = _parse(text)
	assert_false(data["mcpServers"]["godot-mcp"].has("headers"), "No auth token should omit headers")

func test_http_config_with_token_adds_bearer_header():
	var text: String = MCPClientConfigScript.http_config(9080, "secret123")
	var data: Dictionary = _parse(text)
	var server: Dictionary = data["mcpServers"]["godot-mcp"]
	assert_true(server.has("headers"), "Auth token should add headers")
	assert_eq(server["headers"]["Authorization"], "Bearer secret123", "Header should be a Bearer token")

func test_stdio_config_contains_launch_flags():
	var text: String = MCPClientConfigScript.stdio_config("/usr/bin/godot", "/home/dev/project")
	var data: Dictionary = _parse(text)
	var server: Dictionary = data["mcpServers"]["godot-mcp"]
	assert_eq(server["command"], "/usr/bin/godot", "command should be the godot executable")
	var args: Array = server["args"]
	assert_true("--editor" in args, "args must include --editor so the EditorPlugin loads and detects --mcp-server")
	assert_true("--mcp-server" in args, "args should enable MCP server mode")
	assert_true("--mcp-transport=stdio" in args, "args should select stdio transport")
	assert_true("/home/dev/project" in args, "args should include the project path")

func test_stdio_config_uses_placeholders_when_empty():
	var text: String = MCPClientConfigScript.stdio_config("", "")
	var data: Dictionary = _parse(text)
	var server: Dictionary = data["mcpServers"]["godot-mcp"]
	assert_eq(server["command"], "godot", "Empty executable should fall back to 'godot'")
	assert_true("/absolute/path/to/your/godot/project" in server["args"], "Empty project path should use a placeholder")

func test_remote_http_config_appends_mcp_to_base_url():
	var text: String = MCPClientConfigScript.remote_http_config("https://abc.trycloudflare.com")
	var data: Dictionary = _parse(text)
	var url: String = data["mcpServers"]["godot-mcp"]["url"]
	assert_eq(url, "https://abc.trycloudflare.com/mcp", "Remote URL should be base + /mcp")

func test_remote_http_config_trims_trailing_slash():
	var text: String = MCPClientConfigScript.remote_http_config("https://abc.trycloudflare.com/")
	var data: Dictionary = _parse(text)
	var url: String = data["mcpServers"]["godot-mcp"]["url"]
	assert_eq(url, "https://abc.trycloudflare.com/mcp", "Trailing slash should not double up before /mcp")

func test_remote_http_config_with_token_adds_bearer_header():
	var text: String = MCPClientConfigScript.remote_http_config("https://abc.trycloudflare.com", "tok42")
	var data: Dictionary = _parse(text)
	var server: Dictionary = data["mcpServers"]["godot-mcp"]
	assert_true(server.has("headers"), "Auth token should add headers")
	assert_eq(server["headers"]["Authorization"], "Bearer tok42", "Header should be a Bearer token")

func test_remote_stdio_bridge_uses_npx_mcp_remote():
	var text: String = MCPClientConfigScript.remote_stdio_bridge_config("https://abc.trycloudflare.com")
	var data: Dictionary = _parse(text)
	var server: Dictionary = data["mcpServers"]["godot-mcp"]
	assert_eq(server["command"], "npx", "Bridge command should be npx")
	var args: Array = server["args"]
	assert_true("mcp-remote" in args, "args should invoke the mcp-remote bridge")
	assert_true("https://abc.trycloudflare.com/mcp" in args, "args should target the remote /mcp endpoint")

func test_remote_stdio_bridge_with_token_forwards_header():
	var text: String = MCPClientConfigScript.remote_stdio_bridge_config("https://abc.trycloudflare.com", "tok42")
	var data: Dictionary = _parse(text)
	var args: Array = data["mcpServers"]["godot-mcp"]["args"]
	assert_true("--header" in args, "args should pass a --header flag when a token is set")
	assert_true("Authorization: Bearer tok42" in args, "args should forward the Bearer token header")

func test_remote_stdio_bridge_without_token_omits_header():
	var text: String = MCPClientConfigScript.remote_stdio_bridge_config("https://abc.trycloudflare.com", "")
	var data: Dictionary = _parse(text)
	var args: Array = data["mcpServers"]["godot-mcp"]["args"]
	assert_false("--header" in args, "No token should omit the --header flag")

func test_cloudflared_command_uses_port():
	var cmd: String = MCPClientConfigScript.cloudflared_command(9080)
	assert_eq(cmd, "cloudflared tunnel --url http://localhost:9080", "Command should expose the local HTTP port")

func test_cloudflared_command_falls_back_to_default_port():
	var cmd: String = MCPClientConfigScript.cloudflared_command(0)
	assert_eq(cmd, "cloudflared tunnel --url http://localhost:9080", "Non-positive port should fall back to default 9080")
