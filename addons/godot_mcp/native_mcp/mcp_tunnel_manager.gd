class_name MCPTunnelManager
extends RefCounted

## Launches and supervises a Cloudflare Quick Tunnel (`cloudflared`) so the panel
## can expose the local MCP server publicly with one click — no manual command.
##
## 用插件直接拉起 / 关闭 Cloudflare 免费隧道（cloudflared 子进程），实时解析公网地址。
## 进程通过 OS.execute_with_pipe(非阻塞) 启动；URL 解析为纯静态方法，便于单元测试。

## Quick Tunnel hostnames look like https://<words>.trycloudflare.com.
const TRYCLOUDFLARE_PATTERN: String = "https://[A-Za-z0-9._-]+\\.trycloudflare\\.com"
const MAX_BUFFER: int = 16384

var _pid: int = -1
var _stdio: FileAccess = null
var _stderr: FileAccess = null
var _public_url: String = ""
var _line_buffer: String = ""

## Extracts the first trycloudflare.com URL from a chunk of cloudflared output.
## Returns "" when none is present. Pure/static so it can be unit-tested.
static func extract_tunnel_url(text: String) -> String:
	var regex: RegEx = RegEx.new()
	if regex.compile(TRYCLOUDFLARE_PATTERN) != OK:
		return ""
	var result: RegExMatch = regex.search(text)
	if result == null:
		return ""
	return result.get_string()

func is_running() -> bool:
	return _pid > 0 and OS.is_process_running(_pid)

func get_public_url() -> String:
	return _public_url

func get_pid() -> int:
	return _pid

## Starts `<binary> tunnel --url http://localhost:<port>` with non-blocking pipes.
## Returns OK on launch, ERR_ALREADY_IN_USE if a tunnel is running, or
## ERR_CANT_CREATE if the process could not be started.
func start(binary_path: String, port: int) -> Error:
	if is_running():
		return ERR_ALREADY_IN_USE
	var exe: String = binary_path.strip_edges()
	if exe.is_empty():
		return ERR_CANT_CREATE
	var effective_port: int = port if port > 0 else 9080
	var args: PackedStringArray = PackedStringArray([
		"tunnel",
		"--url",
		"http://localhost:%d" % effective_port,
	])
	var pipe: Dictionary = OS.execute_with_pipe(exe, args, false)
	if pipe.is_empty():
		return ERR_CANT_CREATE
	_pid = int(pipe.get("pid", -1))
	_stdio = pipe.get("stdio", null)
	_stderr = pipe.get("stderr", null)
	_public_url = ""
	_line_buffer = ""
	if _pid <= 0:
		return ERR_CANT_CREATE
	return OK

## Reads any pending output without blocking and scans it for the public URL.
## Returns the URL the first time it is detected, otherwise "". Call periodically
## (e.g. from a Timer) while the tunnel is running.
func poll() -> String:
	if not _public_url.is_empty():
		return ""
	var chunk: String = _read_pipe(_stderr) + _read_pipe(_stdio)
	if chunk.is_empty():
		return ""
	_line_buffer += chunk
	var url: String = extract_tunnel_url(_line_buffer)
	if not url.is_empty():
		_public_url = url
		_line_buffer = ""
		return url
	# Keep the buffer bounded; the URL banner appears within the first lines.
	if _line_buffer.length() > MAX_BUFFER:
		_line_buffer = _line_buffer.substr(_line_buffer.length() - 4096)
	return ""

func _read_pipe(pipe: FileAccess) -> String:
	if pipe == null or not pipe.is_open():
		return ""
	var buffer: PackedByteArray = PackedByteArray()
	while true:
		buffer.append_array(pipe.get_buffer(2048))
		if pipe.get_error() != OK:
			break
	if buffer.is_empty():
		return ""
	return buffer.get_string_from_utf8()

## Terminates the tunnel process and releases the pipes.
func stop() -> void:
	if _pid > 0 and OS.is_process_running(_pid):
		OS.kill(_pid)
	_pid = -1
	_public_url = ""
	_line_buffer = ""
	if _stdio != null and _stdio.is_open():
		_stdio.close()
	if _stderr != null and _stderr.is_open():
		_stderr.close()
	_stdio = null
	_stderr = null
