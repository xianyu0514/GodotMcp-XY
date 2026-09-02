class_name MCPClientConfig
extends RefCounted

## Builds ready-to-paste MCP client configuration snippets for this server.
##
## 为各类 MCP 客户端（Claude / Cursor / Cline 等）生成可直接粘贴的连接配置。
## 全部为纯静态字符串生成，便于在编辑器之外做单元测试。

const SERVER_KEY: String = "godot-mcp"
const DEFAULT_PORT: int = 9080

## HTTP / SSE transport — for clients that accept a server URL
## (Cursor, Cline, and other generic MCP clients).
static func http_config(port: int, auth_token: String = "") -> String:
	var effective_port: int = port if port > 0 else DEFAULT_PORT
	var server: Dictionary = {
		"url": "http://127.0.0.1:%d/mcp" % effective_port,
	}
	var token: String = auth_token.strip_edges()
	if not token.is_empty():
		server["headers"] = {"Authorization": "Bearer " + token}
	var root: Dictionary = {"mcpServers": {SERVER_KEY: server}}
	return JSON.stringify(root, "\t", false)

## stdio transport — for command-based clients (e.g. Claude Desktop) that launch
## the server as a child process. Mirrors the launch flags the plugin parses:
## `--mcp-server --mcp-transport=stdio` passed as user args after `--`.
## `--editor` is required: the server is an EditorPlugin whose _enter_tree()
## (where --mcp-server is detected) only runs when the editor is loaded.
static func stdio_config(godot_executable: String, project_path: String) -> String:
	var exe: String = godot_executable.strip_edges()
	if exe.is_empty():
		exe = "godot"
	var proj: String = project_path.strip_edges()
	if proj.is_empty():
		proj = "/absolute/path/to/your/godot/project"
	var server: Dictionary = {
		"command": exe,
		"args": [
			"--editor",
			"--headless",
			"--path",
			proj,
			"--",
			"--mcp-server",
			"--mcp-transport=stdio",
		],
	}
	var root: Dictionary = {"mcpServers": {SERVER_KEY: server}}
	return JSON.stringify(root, "\t", false)

## Normalizes a public base URL: trims whitespace and any trailing slashes so
## the `/mcp` endpoint can be appended cleanly.
static func _normalize_base_url(base_url: String) -> String:
	var base: String = base_url.strip_edges()
	while base.ends_with("/"):
		base = base.substr(0, base.length() - 1)
	if base.is_empty():
		base = "https://your-tunnel.example.com"
	return base

## Public MCP endpoint URL for a tunnel base URL: normalized base + `/mcp`.
## Used by the panel to show a directly usable public address once a tunnel is up.
static func public_mcp_endpoint(base_url: String) -> String:
	return _normalize_base_url(base_url) + "/mcp"

## Local MCP endpoint URL for the loopback HTTP server on the given port.
static func local_mcp_endpoint(port: int) -> String:
	var effective_port: int = port if port > 0 else DEFAULT_PORT
	return "http://127.0.0.1:%d/mcp" % effective_port

## Remote HTTP / SSE transport — same shape as http_config but pointed at a
## public base URL (e.g. a Cloudflare/Tailscale tunnel) instead of 127.0.0.1.
## For URL-capable clients (Cursor, Cline, …). Append `/mcp` to the base URL.
static func remote_http_config(base_url: String, auth_token: String = "") -> String:
	var base: String = _normalize_base_url(base_url)
	var server: Dictionary = {
		"url": base + "/mcp",
	}
	var token: String = auth_token.strip_edges()
	if not token.is_empty():
		server["headers"] = {"Authorization": "Bearer " + token}
	var root: Dictionary = {"mcpServers": {SERVER_KEY: server}}
	return JSON.stringify(root, "\t", false)

## Remote bridge config for stdio-only clients (e.g. Claude Desktop) that cannot
## open an HTTP MCP connection directly. Uses the `mcp-remote` npm bridge to
## tunnel stdio <-> the remote HTTP endpoint, forwarding the auth header.
static func remote_stdio_bridge_config(base_url: String, auth_token: String = "") -> String:
	var base: String = _normalize_base_url(base_url)
	var args: Array = ["-y", "mcp-remote", base + "/mcp"]
	var token: String = auth_token.strip_edges()
	if not token.is_empty():
		args.append("--header")
		args.append("Authorization: Bearer " + token)
	var server: Dictionary = {
		"command": "npx",
		"args": args,
	}
	var root: Dictionary = {"mcpServers": {SERVER_KEY: server}}
	return JSON.stringify(root, "\t", false)

## Suggested zero-config Cloudflare Quick Tunnel command that exposes the local
## HTTP server publicly over HTTPS (no account required).
static func cloudflared_command(port: int) -> String:
	var effective_port: int = port if port > 0 else DEFAULT_PORT
	return "cloudflared tunnel --url http://localhost:%d" % effective_port

## 常见 MCP 客户端注册表：配置文件落点与偏好传输形态。
## transport: "url" = 接受 HTTP 端点（http_config 形态）；"command" = 以子进程
## 启动服务器（stdio_config 形态）；"manual" = 配置为 TOML/嵌入 JSON 等特殊
## 形态，给出标准片段 + 落点说明由用户粘贴。
const CLIENTS: Array[Dictionary] = [
	{"id": "claude-desktop", "name": "Claude Desktop", "transport": "command",
		"paths": {"windows": "{APPDATA}/Claude/claude_desktop_config.json",
			"macos": "~/Library/Application Support/Claude/claude_desktop_config.json",
			"linux": "~/.config/Claude/claude_desktop_config.json"}},
	{"id": "claude-code", "name": "Claude Code", "transport": "url",
		"paths": {"windows": "{USERPROFILE}/.claude.json",
			"macos": "~/.claude.json", "linux": "~/.claude.json"}},
	{"id": "cursor", "name": "Cursor", "transport": "url",
		"paths": {"windows": "{USERPROFILE}/.cursor/mcp.json",
			"macos": "~/.cursor/mcp.json", "linux": "~/.cursor/mcp.json"}},
	{"id": "windsurf", "name": "Windsurf", "transport": "url",
		"paths": {"windows": "{USERPROFILE}/.codeium/windsurf/mcp_config.json",
			"macos": "~/.codeium/windsurf/mcp_config.json",
			"linux": "~/.codeium/windsurf/mcp_config.json"}},
	{"id": "cline", "name": "Cline (VS Code)", "transport": "url",
		"paths": {"windows": "{APPDATA}/Code/User/globalStorage/saoudrizwan.claude-dev/settings/cline_mcp_settings.json",
			"macos": "~/Library/Application Support/Code/User/globalStorage/saoudrizwan.claude-dev/settings/cline_mcp_settings.json",
			"linux": "~/.config/Code/User/globalStorage/saoudrizwan.claude-dev/settings/cline_mcp_settings.json"}},
	{"id": "vscode", "name": "VS Code (native MCP)", "transport": "url",
		"note": "VS Code 的 mcp.json 使用 servers 键与 type 字段：把片段里的对象改写为 {\"type\": \"http\", \"url\": ...}。",
		"paths": {"windows": "{APPDATA}/Code/User/mcp.json",
			"macos": "~/Library/Application Support/Code/User/mcp.json",
			"linux": "~/.config/Code/User/mcp.json"}},
	{"id": "codex", "name": "Codex CLI", "transport": "manual",
		"note": "config.toml 为 TOML：[mcp_servers.godot-mcp] url = \"...\"（HTTP）或 command/args（stdio）。",
		"paths": {"windows": "{USERPROFILE}/.codex/config.toml",
			"macos": "~/.codex/config.toml", "linux": "~/.codex/config.toml"}},
	{"id": "zed", "name": "Zed", "transport": "manual",
		"note": "settings.json 的 context_servers 键内嵌配置：复制片段中的 server 对象改写为 Zed 的形态。",
		"paths": {"windows": "{APPDATA}/Zed/settings.json",
			"macos": "~/.config/zed/settings.json", "linux": "~/.config/zed/settings.json"}},
]

## 展开 {APPDATA}/{USERPROFILE}/~ 占位符为当前机器的绝对路径。
static func expand_client_path(path_template: String) -> String:
	var path: String = path_template
	var appdata: String = OS.get_environment("APPDATA")
	var userprofile: String = OS.get_environment("USERPROFILE")
	var home: String = OS.get_environment("HOME") if not OS.get_environment("HOME").is_empty() else userprofile
	if not appdata.is_empty():
		path = path.replace("{APPDATA}", appdata.replace("\\", "/"))
	if not userprofile.is_empty():
		path = path.replace("{USERPROFILE}", userprofile.replace("\\", "/"))
	if path.begins_with("~/") and not home.is_empty():
		path = home.replace("\\", "/") + path.substr(1)
	return path

## 按当前操作系统取客户端配置文件路径；未知客户端/OS 返回空串。
static func client_config_path(client_id: String) -> String:
	var client: Dictionary = client_by_id(client_id)
	if client.is_empty():
		return ""
	var paths: Dictionary = client.get("paths", {})
	var os_key: String = "linux"
	if OS.has_feature("windows"):
		os_key = "windows"
	elif OS.has_feature("macos"):
		os_key = "macos"
	var template: String = String(paths.get(os_key, ""))
	if template.is_empty():
		return ""
	return expand_client_path(template)

static func client_by_id(client_id: String) -> Dictionary:
	for client in CLIENTS:
		if String(client.get("id", "")) == client_id:
			return client
	return {}

## 检测本机已安装的客户端（配置文件或其父目录已存在即视为安装）。
## 返回 [{id, name, transport, config_path, ready(bool)}]，按注册表顺序。
static func detected_clients() -> Array[Dictionary]:
	var detected: Array[Dictionary] = []
	for client in CLIENTS:
		var config_path: String = client_config_path(String(client.get("id", "")))
		if config_path.is_empty():
			continue
		var parent: String = config_path.get_base_dir()
		var installed: bool = FileAccess.file_exists(config_path) \
			or DirAccess.dir_exists_absolute(parent)
		if not installed:
			continue
		detected.append({
			"id": client.get("id", ""),
			"name": client.get("name", ""),
			"transport": client.get("transport", ""),
			"config_path": config_path,
			"ready": FileAccess.file_exists(config_path),
		})
	return detected

## 为指定客户端生成可粘贴片段：url 形态返回 http_config，command 形态返回
## stdio_config，manual 形态返回 http 片段 + 落点说明。未知名返回错误字典。
static func config_snippet_for_client(client_id: String, port: int,
		auth_token: String = "", godot_executable: String = "",
		project_path: String = "") -> Dictionary:
	var client: Dictionary = client_by_id(client_id)
	if client.is_empty():
		return {"error": "Unknown client id: " + client_id}
	var transport: String = String(client.get("transport", "url"))
	var snippet: String = http_config(port, auth_token)
	if transport == "command":
		snippet = stdio_config(godot_executable, project_path)
	var result: Dictionary = {
		"client": client.get("name", client_id),
		"transport": transport,
		"config_path": client_config_path(client_id),
		"snippet": snippet,
	}
	var note: String = String(client.get("note", ""))
	if not note.is_empty():
		result["note"] = note
	return result

## 面板摘要：已检测客户端名列表（逗号分隔）；空串表示未检测到。
static func detected_clients_summary() -> String:
	var names: Array[String] = []
	for client in detected_clients():
		names.append(String(client.get("name", "")))
	return ", ".join(names)
