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

func test_public_mcp_endpoint_appends_mcp():
	var url: String = MCPClientConfigScript.public_mcp_endpoint("https://abc.trycloudflare.com")
	assert_eq(url, "https://abc.trycloudflare.com/mcp", "Public endpoint should be base + /mcp")

func test_public_mcp_endpoint_trims_trailing_slash():
	var url: String = MCPClientConfigScript.public_mcp_endpoint("https://abc.trycloudflare.com/")
	assert_eq(url, "https://abc.trycloudflare.com/mcp", "Trailing slash should not double up before /mcp")

func test_local_mcp_endpoint_uses_port():
	var url: String = MCPClientConfigScript.local_mcp_endpoint(12345)
	assert_eq(url, "http://127.0.0.1:12345/mcp", "Local endpoint should embed the given port and /mcp path")

func test_local_mcp_endpoint_falls_back_to_default_port():
	var url: String = MCPClientConfigScript.local_mcp_endpoint(0)
	assert_eq(url, "http://127.0.0.1:9080/mcp", "Non-positive port should fall back to default 9080")

func test_cloudflared_command_uses_port():
	var cmd: String = MCPClientConfigScript.cloudflared_command(9080)
	assert_eq(cmd, "cloudflared tunnel --url http://localhost:9080", "Command should expose the local HTTP port")

func test_cloudflared_command_falls_back_to_default_port():
	var cmd: String = MCPClientConfigScript.cloudflared_command(0)
	assert_eq(cmd, "cloudflared tunnel --url http://localhost:9080", "Non-positive port should fall back to default 9080")

# ---------------------------------------------------------------------------
# 客户端注册表
# ---------------------------------------------------------------------------

func test_client_registry_is_well_formed():
	var clients: Array = MCPClientConfigScript.CLIENTS
	assert_gt(clients.size(), 6, "Registry covers the common clients")
	var seen: Dictionary = {}
	for client in clients:
		var id: String = String(client.get("id", ""))
		assert_false(id.is_empty(), "Every client has an id")
		assert_false(seen.has(id), "Client ids are unique: " + id)
		seen[id] = true
		assert_false(String(client.get("name", "")).is_empty(), "Every client has a name")
		assert_true(["url", "command", "manual"].has(String(client.get("transport", ""))),
			"Transport is one of url/command/manual: " + id)
		var paths: Dictionary = client.get("paths", {})
		assert_true(paths.has("windows") and paths.has("macos") and paths.has("linux"),
			"Every client documents all three OS paths: " + id)

func test_client_config_path_expands_current_os():
	for client in MCPClientConfigScript.CLIENTS:
		var path: String = MCPClientConfigScript.client_config_path(String(client.get("id", "")))
		assert_false(path.is_empty(), "Path resolves on this OS: " + String(client.get("id", "")))
		assert_false(path.contains("{APPDATA}") or path.contains("{USERPROFILE}"),
			"Placeholders are expanded: " + path)
		assert_false(path.begins_with("~/"), "Home shorthand is expanded: " + path)
	assert_eq(MCPClientConfigScript.client_config_path("not-a-client"), "",
		"Unknown client resolves to an empty path")

func test_config_snippet_matches_transport_shape():
	var http_client: Dictionary = MCPClientConfigScript.config_snippet_for_client("cursor", 9080)
	assert_false(http_client.has("error"), str(http_client.get("error", "")))
	assert_eq(String(http_client.get("transport", "")), "url")
	assert_true(String(http_client.get("snippet", "")).contains("http://127.0.0.1:9080/mcp"),
		"URL clients get the HTTP endpoint snippet")
	assert_false(String(http_client.get("config_path", "")).is_empty(),
		"The snippet names the config file to edit")
	var command_client: Dictionary = MCPClientConfigScript.config_snippet_for_client(
		"claude-desktop", 9080, "", "godot", "res://")
	assert_eq(String(command_client.get("transport", "")), "command")
	assert_true(String(command_client.get("snippet", "")).contains("--mcp-transport=stdio"),
		"Command clients get the stdio launch snippet")
	var manual_client: Dictionary = MCPClientConfigScript.config_snippet_for_client("zed", 9080)
	assert_true(manual_client.has("note"),
		"Manual-shape clients carry a paste-location note")
	assert_true(MCPClientConfigScript.config_snippet_for_client("ghost", 9080).has("error"),
		"Unknown client ids error instead of guessing")

func test_detected_clients_only_reports_existing_locations():
	# 纯读检测：返回条目都必须指向本机真实存在的路径（文件或父目录）。
	for entry in MCPClientConfigScript.detected_clients():
		var config_path: String = String(entry.get("config_path", ""))
		var parent: String = config_path.get_base_dir()
		assert_true(FileAccess.file_exists(config_path) or DirAccess.dir_exists_absolute(parent),
			"Detected entries point at real locations: " + config_path)
		assert_eq(bool(entry.get("ready", false)), FileAccess.file_exists(config_path),
			"ready means the config file itself exists")
