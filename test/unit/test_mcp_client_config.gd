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
	assert_true("--mcp-server" in args, "args should enable MCP server mode")
	assert_true("--mcp-transport=stdio" in args, "args should select stdio transport")
	assert_true("/home/dev/project" in args, "args should include the project path")

func test_stdio_config_uses_placeholders_when_empty():
	var text: String = MCPClientConfigScript.stdio_config("", "")
	var data: Dictionary = _parse(text)
	var server: Dictionary = data["mcpServers"]["godot-mcp"]
	assert_eq(server["command"], "godot", "Empty executable should fall back to 'godot'")
	assert_true("/absolute/path/to/your/godot/project" in server["args"], "Empty project path should use a placeholder")
