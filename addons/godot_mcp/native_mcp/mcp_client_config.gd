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
