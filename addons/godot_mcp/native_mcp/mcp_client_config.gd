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
## the server as a child process. Mirrors the headless launch flags the plugin
## parses: `--mcp-server --mcp-transport=stdio` passed as user args after `--`.
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
