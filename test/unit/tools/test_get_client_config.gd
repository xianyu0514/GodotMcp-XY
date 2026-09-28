extends "res://addons/gut/test.gd"

## get_client_config（M8）：代理可见的客户端连接配置生成——四种格式、
## 活端口默认、remote 缺 base_url 的自愈报错、未知格式拒绝。

const ToolsScript = preload("res://addons/godot_mcp/tools/editor_tools_native.gd")

var _tools: RefCounted

func before_each() -> void:
	_tools = ToolsScript.new()

func after_each() -> void:
	_tools = null

func test_http_format_uses_live_port_and_embeds_token() -> void:
	var r: Dictionary = _tools._tool_get_client_config({})
	assert_false(r.has("error"), str(r))
	assert_eq(String(r.get("format", "")), "http")
	assert_true(String(r.get("config_text", "")).contains("/mcp"), "URL endpoint present")
	assert_true(String(r.get("config_text", "")).contains("godot-mcp"), "server key present")
	assert_false(String(r.get("config_text", "")).contains("Authorization"), "no header without a token")
	assert_true(int(r.get("server", {}).get("http_port", -1)) > 0, "live port surfaced")
	var with_token: Dictionary = _tools._tool_get_client_config({"auth_token": "sekret"})
	assert_true(String(with_token.get("config_text", "")).contains("Bearer sekret"),
		"token embedded as Authorization header")

func test_http_format_honors_explicit_port() -> void:
	var r: Dictionary = _tools._tool_get_client_config({"format": "http", "port": 9123})
	assert_true(String(r.get("config_text", "")).contains("127.0.0.1:9123/mcp"),
		"explicit port wins over the live default")

func test_stdio_format_defaults_and_overrides() -> void:
	var r: Dictionary = _tools._tool_get_client_config({"format": "stdio"})
	assert_false(r.has("error"), str(r))
	var text: String = String(r.get("config_text", ""))
	assert_true(text.contains("--mcp-server") and text.contains("--mcp-transport=stdio"),
		"launch flags mirror what the plugin parses")
	assert_true(text.contains("--no-header"), "stdout stays clean for the JSON-RPC channel")
	assert_true(text.contains(OS.get_executable_path().replace("\\", "/"))
		or text.contains(OS.get_executable_path()), "defaults to the running editor executable")
	var overridden: Dictionary = _tools._tool_get_client_config({
		"format": "stdio", "godot_executable": "C:/godot/godot.exe", "project_path": "C:/proj"})
	assert_true(String(overridden.get("config_text", "")).contains("C:/proj"),
		"explicit project path lands in the args")

func test_remote_formats_require_base_url_with_self_healing_hint() -> void:
	var r: Dictionary = _tools._tool_get_client_config({"format": "remote_http"})
	assert_true(r.has("error"))
	assert_true(String(r["error"]).contains("base_url"), "error names the missing arg")
	assert_true(String(r["error"]).contains("cloudflared tunnel"),
		"error suggests the exact tunnel command to run next")
	var bridge: Dictionary = _tools._tool_get_client_config({"format": "remote_stdio_bridge"})
	assert_true(bridge.has("error") and String(bridge["error"]).contains("cloudflared"))

func test_remote_formats_with_base_url_build_configs() -> void:
	var r: Dictionary = _tools._tool_get_client_config({
		"format": "remote_http", "base_url": "https://tun.example.com/"})
	assert_false(r.has("error"), str(r))
	assert_true(String(r.get("config_text", "")).contains("https://tun.example.com/mcp"),
		"trailing slash normalized, /mcp appended")
	var bridge: Dictionary = _tools._tool_get_client_config({
		"format": "remote_stdio_bridge", "base_url": "https://tun.example.com"})
	assert_true(String(bridge.get("config_text", "")).contains("mcp-remote"),
		"stdio-only clients get the npm bridge")

func test_unknown_format_is_rejected_with_valid_options() -> void:
	var r: Dictionary = _tools._tool_get_client_config({"format": "carrier-pigeon"})
	assert_true(r.has("error"))
	assert_true(String(r["error"]).contains("http") and String(r["error"]).contains("stdio"),
		"error lists the valid formats")
