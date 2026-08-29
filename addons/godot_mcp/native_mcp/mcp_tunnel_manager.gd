class_name MCPTunnelManager
extends RefCounted

## Launches and supervises a Cloudflare Quick Tunnel (`cloudflared`) so the panel
## can expose the local MCP server publicly with one click — no manual command.
##
## The tunnel is deliberately independent from the Godot/editor lifecycle.
## Session metadata and cloudflared's log live in a machine-local, project-scoped
## directory. A reloaded plugin or a new Godot process can therefore validate and
## adopt the existing supervisor PID/URL. Only stop() terminates it; detach()
## never does.

const TRYCLOUDFLARE_PATTERN: String = "https://([A-Za-z0-9._-]+)\\.trycloudflare\\.com"
const DEFAULT_PORT: int = 9080
const MAX_BUFFER: int = 16384
const MAX_LOG_READ_BYTES: int = 65536
const STATE_SCHEMA_VERSION: int = 2
const LEGACY_STATE_SCHEMA_VERSION: int = 1
const SHARED_APP_DIR: String = "GodotMcp-XY"
const SESSION_COMPONENT_DIR: String = "tunnels"
const STATE_FILE_NAME: String = "session.json"
const LOG_FILE_NAME: String = "cloudflared.log"
const RUNTIME_FILE_NAME: String = "runtime.json"
const STOP_FILE_NAME: String = "stop.request"
const SUPERVISOR_SCRIPT_PATH: String = "res://addons/godot_mcp/native_mcp/mcp_tunnel_supervisor.gd"
const STOP_GRACE_MSEC: int = 750

var _session_dir: String = ""
var _state_path: String = ""
var _log_path: String = ""
var _runtime_path: String = ""
var _stop_path: String = ""
var _session_id: String = ""
var _pid: int = -1
var _public_url: String = ""
var _binary_path: String = ""
var _supervisor_executable: String = ""
var _supervisor_script: String = ""
var _port: int = 0
var _line_buffer: String = ""
var _log_offset: int = 0
var _spawned_by_this_instance: bool = false
var _legacy_direct_process: bool = false

func _init(session_dir: String = "") -> void:
	_session_dir = session_dir.strip_edges()
	if _session_dir.is_empty():
		_session_dir = default_session_dir()
	_session_dir = _session_dir.simplify_path()
	_state_path = _session_dir.path_join(STATE_FILE_NAME)
	_log_path = _session_dir.path_join(LOG_FILE_NAME)
	_runtime_path = _session_dir.path_join(RUNTIME_FILE_NAME)
	_stop_path = _session_dir.path_join(STOP_FILE_NAME)
	_session_id = _state_path.sha256_text().substr(0, 32)

## Stable machine-local directory for the currently open project. Hashing the
## absolute project root avoids leaking paths in filenames and prevents two
## projects from adopting each other's tunnel.
static func default_session_dir(project_root: String = "") -> String:
	var root: String = project_root.strip_edges()
	if root.is_empty():
		root = ProjectSettings.globalize_path("res://")
	root = root.trim_suffix("/").trim_suffix("\\").simplify_path()
	if OS.get_name() == "Windows":
		root = root.to_lower()
	var project_key: String = root.sha256_text().substr(0, 24)
	return OS.get_data_dir().path_join(SHARED_APP_DIR).path_join(
		SESSION_COMPONENT_DIR
	).path_join(project_key).simplify_path()

## Normalizes a user/environment proxy value into an absolute proxy URL.
## Plain `host:port` entries are assumed to be HTTP CONNECT proxies.
static func normalize_proxy_url(raw: String) -> String:
	var value: String = raw.strip_edges()
	if value.is_empty():
		return ""
	if value.find("://") < 0:
		value = "http://" + value
	return value.trim_suffix("/")

## Picks the first usable proxy from a process environment dictionary. Go-style
## proxy tools honor several spellings, so all common variants are considered.
static func proxy_from_environment(env: Dictionary) -> String:
	for key in ["HTTPS_PROXY", "https_proxy", "HTTP_PROXY", "http_proxy", "ALL_PROXY", "all_proxy"]:
		var value: String = String(env.get(key, "")).strip_edges()
		if not value.is_empty():
			return normalize_proxy_url(value)
	return ""

## Reads the proxy-related variables of the current OS process into a dictionary
## and reuses the pure `proxy_from_environment` selection logic.
static func proxy_from_os_environment() -> String:
	var env: Dictionary = {}
	for key in ["HTTPS_PROXY", "https_proxy", "HTTP_PROXY", "http_proxy", "ALL_PROXY", "all_proxy"]:
		env[key] = OS.get_environment(key)
	return proxy_from_environment(env)

## Parses the Windows `ProxyServer` registry value. It is commonly either
## `host:port` or `https=host:port;http=host:port;...`. HTTPS is preferred for
## cloudflared's TLS edge connections, then HTTP, then SOCKS5.
static func parse_windows_proxy_server(raw: String) -> String:
	var value: String = raw.strip_edges()
	if value.is_empty():
		return ""
	var parts: PackedStringArray = value.split(";", false)
	for preferred_prefix in ["https=", "http=", "socks="]:
		for part in parts:
			var entry: String = part.strip_edges()
			if entry.begins_with(preferred_prefix):
				var address: String = entry.substr(preferred_prefix.length()).strip_edges()
				if address.is_empty():
					continue
				if address.find("://") >= 0:
					return normalize_proxy_url(address)
				var scheme: String = "socks5" if preferred_prefix == "socks=" else preferred_prefix.substr(0, preferred_prefix.length() - 1)
				return "%s://%s" % [scheme, address.trim_suffix("/")]
	return normalize_proxy_url(value)

## Resolves the proxy cloudflared should use, without network access:
## explicit environment variables first, then the Windows system proxy.
static func detect_system_proxy(os_name: String = "") -> String:
	var platform: String = os_name.strip_edges()
	if platform.is_empty():
		platform = OS.get_name()
	var from_env: String = proxy_from_os_environment()
	if not from_env.is_empty():
		return from_env
	if platform == "Windows":
		return windows_system_proxy()
	return ""

## Reads the Windows per-user system proxy from the registry. Returns "" when
## disabled, missing, or unreadable.
static func windows_system_proxy() -> String:
	var enabled: String = _read_registry_value("ProxyEnable")
	if enabled.strip_edges().to_lower() not in ["0x1", "1", "true"]:
		return ""
	var server: String = _read_registry_value("ProxyServer")
	if server.strip_edges().is_empty():
		return ""
	return parse_windows_proxy_server(server)

static func _read_registry_value(value_name: String) -> String:
	var output: Array = []
	var exit_code: int = OS.execute(
		"reg.exe",
		PackedStringArray([
			"query",
			"HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings",
			"/v",
			value_name,
		]),
		output,
		true
	)
	if exit_code != 0 or output.is_empty():
		return ""
	for line in output:
		var candidate: String = String(line).strip_edges()
		if candidate.is_empty() or not candidate.contains(value_name):
			continue
		var remainder: String = candidate.substr(
			candidate.find(value_name) + value_name.length()
		).strip_edges()
		for marker in ["REG_SZ", "REG_EXPAND_SZ", "REG_DWORD", "REG_QWORD"]:
			var marker_index: int = remainder.find(marker)
			if marker_index >= 0:
				return remainder.substr(marker_index + marker.length()).strip_edges()
		return remainder
	return ""

## Starts a separate headless Godot main loop that owns cloudflared's pipes.
## Every value is passed as one user argument so paths with spaces are preserved
## without shell quoting or platform-specific wrappers. `proxy` is forwarded so
## the supervisor can export it to the cloudflared child before launch.
static func build_supervisor_launch_args(project_root: String, supervisor_script: String,
		binary_path: String, port: int, log_path: String, runtime_path: String,
		stop_path: String, session_id: String, proxy: String = "") -> PackedStringArray:
	var effective_port: int = port if port > 0 else DEFAULT_PORT
	return PackedStringArray([
		"--headless",
		"--path",
		project_root,
		"--script",
		supervisor_script,
		"--",
		"--mcp-tunnel-binary=%s" % binary_path,
		"--mcp-tunnel-port=%d" % effective_port,
		"--mcp-tunnel-log=%s" % log_path,
		"--mcp-tunnel-runtime=%s" % runtime_path,
		"--mcp-tunnel-stop=%s" % stop_path,
		"--mcp-tunnel-session=%s" % session_id,
		"--mcp-tunnel-proxy=%s" % proxy.strip_edges(),
	])

## Extracts the first trycloudflare.com URL from a cloudflared log chunk.
static func extract_tunnel_url(text: String) -> String:
	var regex: RegEx = RegEx.new()
	if regex.compile(TRYCLOUDFLARE_PATTERN) != OK:
		return ""
	var search_offset: int = 0
	while search_offset < text.length():
		var result: RegExMatch = regex.search(text, search_offset)
		if result == null:
			return ""
		if result.get_string(1).to_lower() != "api":
			return result.get_string()
		search_offset = result.get_end()
	return ""

static func classify_startup_failure(log_text: String) -> String:
	var normalized: String = log_text.to_lower()
	if normalized.contains("no such host") or normalized.contains("temporary failure in name resolution"):
		return "dns"
	if normalized.contains("proxyconnect") or normalized.contains("proxy connection"):
		return "proxy"
	if normalized.contains("x509") or normalized.contains("tls handshake") or normalized.contains("certificate"):
		return "tls"
	if normalized.contains("429") or normalized.contains("too many requests") or normalized.contains("rate limit"):
		return "rate_limited"
	if normalized.contains("i/o timeout") or normalized.contains("context deadline exceeded") or normalized.contains("timed out"):
		return "timeout"
	if (
		normalized.contains("failed to request quick tunnel")
		or normalized.contains("status 502")
		or normalized.contains("status 503")
		or normalized.contains("service unavailable")
	):
		return "service"
	return "unknown"

## Verifies that a live PID still belongs to this exact managed session. The
## unique logfile argument protects against stale PID reuse after a reboot.
static func command_line_matches_session(command_line: String, binary_path: String,
		log_path: String, os_name: String = "") -> bool:
	var command: String = command_line.strip_edges()
	var expected_binary: String = binary_path.strip_edges()
	var binary_name: String = expected_binary.get_file()
	var expected_log: String = log_path.strip_edges()
	if command.is_empty() or binary_name.is_empty() or expected_log.is_empty():
		return false
	var platform: String = os_name if not os_name.is_empty() else OS.get_name()
	if platform == "Windows":
		command = command.replace("\\", "/").to_lower()
		expected_binary = expected_binary.replace("\\", "/").to_lower()
		binary_name = binary_name.to_lower()
		expected_log = expected_log.replace("\\", "/").to_lower()
	var executable_matches: bool = (
		command.begins_with(expected_binary + " ")
		or command.begins_with('"%s" ' % expected_binary)
		or command == expected_binary
		or command == '"%s"' % expected_binary
	)
	return (
		executable_matches
		and command.contains(binary_name)
		and command.contains("--logfile")
		and command.contains(expected_log)
	)

static func supervisor_command_matches_session(command_line: String, executable_path: String,
		supervisor_script: String, session_id: String, os_name: String = "") -> bool:
	var command: String = command_line.strip_edges()
	var expected_executable: String = executable_path.strip_edges()
	var expected_script: String = supervisor_script.strip_edges()
	var expected_session: String = session_id.strip_edges()
	if command.is_empty() or expected_executable.is_empty() or expected_script.is_empty() or expected_session.is_empty():
		return false
	var platform: String = os_name if not os_name.is_empty() else OS.get_name()
	if platform == "Windows":
		command = command.replace("\\", "/").to_lower()
		expected_executable = expected_executable.replace("\\", "/").to_lower()
		expected_script = expected_script.replace("\\", "/").to_lower()
		expected_session = expected_session.to_lower()
	var executable_matches: bool = (
		command.begins_with(expected_executable + " ")
		or command.begins_with('"%s" ' % expected_executable)
	)
	return (
		executable_matches
		and command.contains("--script")
		and command.contains(expected_script)
		and command.contains("--mcp-tunnel-session=%s" % expected_session)
	)

static func cloudflared_command_matches(command_line: String, binary_path: String,
		port: int, os_name: String = "") -> bool:
	var command: String = command_line.strip_edges()
	var expected_binary: String = binary_path.strip_edges()
	if command.is_empty() or expected_binary.is_empty() or port <= 0:
		return false
	var platform: String = os_name if not os_name.is_empty() else OS.get_name()
	if platform == "Windows":
		command = command.replace("\\", "/").to_lower()
		expected_binary = expected_binary.replace("\\", "/").to_lower()
	var executable_matches: bool = (
		command.begins_with(expected_binary + " ")
		or command.begins_with('"%s" ' % expected_binary)
	)
	# 兼容两种源站写法：新会话使用显式 127.0.0.1，历史持久化会话记录仍为
	# localhost（旧 cloudflared 进程仍按旧命令行运行，必须继续被识别/收养）。
	var origin_matches: bool = (
		command.contains("http://127.0.0.1:%d" % port)
		or command.contains("http://localhost:%d" % port)
	)
	return (
		executable_matches
		and command.contains("tunnel")
		and command.contains("--url")
		and origin_matches
	)

func is_running() -> bool:
	if _pid <= 0:
		return false
	if _spawned_by_this_instance:
		return _is_process_running(_pid)
	return _is_external_process_running(_pid)

func get_public_url() -> String:
	return _public_url

func get_pid() -> int:
	return _pid

func get_port() -> int:
	return _port

func get_state_path() -> String:
	return _state_path

func get_log_path() -> String:
	return _log_path

func get_startup_failure_code() -> String:
	if not FileAccess.file_exists(_log_path):
		return "unknown"
	return classify_startup_failure(FileAccess.get_file_as_string(_log_path))

## Adopts a tunnel started by an earlier plugin/editor instance. Returns false
## for missing, corrupt, stopped, or PID-reused sessions and removes stale state.
## The last URL is retained in memory on failure so the panel can clear a stale
## saved endpoint without touching a manually-entered URL.
func restore() -> bool:
	if is_running():
		return true
	var state: Dictionary = _load_state()
	if state.is_empty():
		return false
	_public_url = String(state.get("public_url", "")).strip_edges()
	if not _is_valid_state(state):
		_remove_state_file()
		_reset_runtime(true)
		return false
	_pid = int(state.get("pid", -1))
	_binary_path = String(state.get("binary_path", "")).strip_edges()
	_port = int(state.get("port", 0))
	_legacy_direct_process = int(state.get("schema_version", 0)) == LEGACY_STATE_SCHEMA_VERSION
	_supervisor_executable = String(state.get("supervisor_executable", "")).strip_edges()
	_supervisor_script = String(state.get("supervisor_script", "")).strip_edges()
	_spawned_by_this_instance = false
	_log_offset = 0
	_line_buffer = ""
	if not _is_external_process_running(_pid):
		_terminate_owned_cloudflared_child()
		_remove_state_file()
		_remove_file_if_present(_runtime_path)
		_remove_file_if_present(_stop_path)
		_reset_runtime(true)
		return false
	var command_line: String = _read_process_command_line(_pid)
	var owns_process: bool = command_line_matches_session(
		command_line, _binary_path, _log_path
	) if _legacy_direct_process else supervisor_command_matches_session(
		command_line, _supervisor_executable, _supervisor_script, _session_id
	)
	if not owns_process:
		_terminate_owned_cloudflared_child()
		_remove_state_file()
		_remove_file_if_present(_runtime_path)
		_remove_file_if_present(_stop_path)
		_reset_runtime(true)
		return false
	return true

## Starts a detached headless supervisor which owns cloudflared's live pipes.
## Existing persisted sessions are adopted first, preventing duplicate tunnels.
## `proxy_override` wins when provided; otherwise the system/environment proxy is
## detected automatically and forwarded to the supervisor.
func start(binary_path: String, port: int, proxy_override: String = "") -> Error:
	if is_running() or restore():
		return ERR_ALREADY_IN_USE
	var exe: String = binary_path.strip_edges()
	if exe.is_empty():
		return ERR_CANT_CREATE
	var effective_port: int = port if port > 0 else DEFAULT_PORT
	var proxy: String = proxy_override.strip_edges()
	if proxy.is_empty():
		proxy = detect_system_proxy()
	else:
		proxy = normalize_proxy_url(proxy)
	if DirAccess.make_dir_recursive_absolute(_session_dir) != OK:
		return ERR_CANT_CREATE
	_remove_file_if_present(_log_path)
	_remove_file_if_present(_runtime_path)
	_remove_file_if_present(_stop_path)
	_remove_state_file()
	_reset_runtime()

	var project_root: String = ProjectSettings.globalize_path("res://").trim_suffix("/").trim_suffix("\\")
	var supervisor_script: String = ProjectSettings.globalize_path(SUPERVISOR_SCRIPT_PATH).simplify_path()
	var supervisor_executable: String = OS.get_executable_path().simplify_path()
	if not FileAccess.file_exists(supervisor_script) or supervisor_executable.is_empty():
		return ERR_CANT_CREATE
	var args: PackedStringArray = build_supervisor_launch_args(
		project_root,
		supervisor_script,
		exe,
		effective_port,
		_log_path,
		_runtime_path,
		_stop_path,
		_session_id,
		proxy
	)
	var process_id: int = _spawn_process(supervisor_executable, args)
	if process_id <= 0:
		return ERR_CANT_CREATE
	_pid = process_id
	_binary_path = exe
	_supervisor_executable = supervisor_executable
	_supervisor_script = supervisor_script
	_port = effective_port
	_spawned_by_this_instance = true
	_legacy_direct_process = false
	var state_error: Error = _save_state()
	if state_error != OK:
		_terminate_process(_pid)
		_reset_runtime()
		return state_error
	return OK

## Reads newly appended log data without blocking and persists the public URL as
## soon as it appears. Returns the URL only on first discovery.
func poll() -> String:
	if not _public_url.is_empty():
		return ""
	var runtime_url: String = _read_runtime_public_url()
	if not runtime_url.is_empty():
		_public_url = runtime_url
		_line_buffer = ""
		_save_state()
		return runtime_url
	var chunk: String = _read_log_chunk()
	if chunk.is_empty():
		return ""
	_line_buffer += chunk
	var url: String = extract_tunnel_url(_line_buffer)
	if not url.is_empty():
		_public_url = url
		_line_buffer = ""
		_save_state()
		return url
	if _line_buffer.length() > MAX_BUFFER:
		_line_buffer = _line_buffer.substr(_line_buffer.length() - 4096)
	return ""

## Explicit user action: validate ownership once more, ask the supervisor to
## terminate cloudflared, and remove the resumable session. No lifecycle
## callback calls this method.
func stop() -> void:
	if is_running():
		var command_line: String = _read_process_command_line(_pid)
		if _legacy_direct_process:
			if command_line_matches_session(command_line, _binary_path, _log_path):
				_terminate_process(_pid)
		elif supervisor_command_matches_session(
				command_line, _supervisor_executable, _supervisor_script, _session_id
		):
			_write_stop_request()
			var deadline: int = Time.get_ticks_msec() + STOP_GRACE_MSEC
			while is_running() and Time.get_ticks_msec() < deadline:
				OS.delay_msec(25)
			if is_running():
				_terminate_owned_cloudflared_child()
				_terminate_process(_pid)
	else:
		_terminate_owned_cloudflared_child()
	_remove_state_file()
	_remove_file_if_present(_runtime_path)
	_remove_file_if_present(_stop_path)
	_reset_runtime()

## Releases only this Godot instance's in-memory handle. The external process,
## log, and state file intentionally survive project reload and editor shutdown.
func detach() -> void:
	_reset_runtime()

## Removes metadata for a process that has already exited unexpectedly.
func discard_stale_session() -> void:
	if is_running():
		return
	_terminate_owned_cloudflared_child()
	_remove_state_file()
	_remove_file_if_present(_runtime_path)
	_remove_file_if_present(_stop_path)
	_reset_runtime()

func _state_dictionary() -> Dictionary:
	return {
		"schema_version": STATE_SCHEMA_VERSION,
		"pid": _pid,
		"public_url": _public_url,
		"binary_path": _binary_path,
		"supervisor_executable": _supervisor_executable,
		"supervisor_script": _supervisor_script,
		"session_id": _session_id,
		"port": _port,
		"log_path": _log_path,
		"runtime_path": _runtime_path,
		"stop_path": _stop_path,
		"started_at_unix": int(Time.get_unix_time_from_system()),
	}

func _save_state() -> Error:
	if _pid <= 0:
		return ERR_INVALID_DATA
	if DirAccess.make_dir_recursive_absolute(_session_dir) != OK:
		return ERR_FILE_CANT_WRITE
	var temporary: String = "%s.tmp-%d" % [_state_path, OS.get_process_id()]
	_remove_file_if_present(temporary)
	var file: FileAccess = FileAccess.open(temporary, FileAccess.WRITE)
	if file == null:
		return ERR_FILE_CANT_WRITE
	file.store_string(JSON.stringify(_state_dictionary(), "\t"))
	file.flush()
	file.close()
	_remove_file_if_present(_state_path)
	var rename_error: Error = DirAccess.rename_absolute(temporary, _state_path)
	if rename_error != OK:
		_remove_file_if_present(temporary)
		return rename_error
	return OK

func _load_state() -> Dictionary:
	if not FileAccess.file_exists(_state_path):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(_state_path))
	if typeof(parsed) != TYPE_DICTIONARY:
		_remove_state_file()
		return {}
	return parsed as Dictionary

func _is_valid_state(state: Dictionary) -> bool:
	var schema_version: int = int(state.get("schema_version", 0))
	var common_valid: bool = (
		schema_version in [LEGACY_STATE_SCHEMA_VERSION, STATE_SCHEMA_VERSION]
		and int(state.get("pid", -1)) > 0
		and int(state.get("port", 0)) > 0
		and not String(state.get("binary_path", "")).strip_edges().is_empty()
		and String(state.get("log_path", "")).simplify_path() == _log_path
	)
	if not common_valid or schema_version == LEGACY_STATE_SCHEMA_VERSION:
		return common_valid
	return (
		not String(state.get("supervisor_executable", "")).strip_edges().is_empty()
		and String(state.get("supervisor_script", "")).simplify_path() == ProjectSettings.globalize_path(
			SUPERVISOR_SCRIPT_PATH
		).simplify_path()
		and String(state.get("session_id", "")) == _session_id
		and String(state.get("runtime_path", "")).simplify_path() == _runtime_path
		and String(state.get("stop_path", "")).simplify_path() == _stop_path
	)

func _read_log_chunk() -> String:
	if not FileAccess.file_exists(_log_path):
		return ""
	var file: FileAccess = FileAccess.open(_log_path, FileAccess.READ)
	if file == null:
		return ""
	var length: int = file.get_length()
	if _log_offset < 0 or _log_offset > length:
		_log_offset = 0
	if _log_offset >= length:
		file.close()
		return ""
	file.seek(_log_offset)
	var bytes_to_read: int = mini(length - _log_offset, MAX_LOG_READ_BYTES)
	var buffer: PackedByteArray = file.get_buffer(bytes_to_read)
	_log_offset = file.get_position()
	file.close()
	return buffer.get_string_from_utf8() if not buffer.is_empty() else ""

func _reset_runtime(preserve_url: bool = false) -> void:
	_pid = -1
	_binary_path = ""
	_supervisor_executable = ""
	_supervisor_script = ""
	_port = 0
	_spawned_by_this_instance = false
	_legacy_direct_process = false
	_line_buffer = ""
	_log_offset = 0
	if not preserve_url:
		_public_url = ""

func _remove_state_file() -> void:
	_remove_file_if_present(_state_path)

func _remove_file_if_present(path: String) -> void:
	if not path.is_empty() and FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)

func _load_runtime_state() -> Dictionary:
	if not FileAccess.file_exists(_runtime_path):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(_runtime_path))
	if typeof(parsed) != TYPE_DICTIONARY:
		return {}
	var runtime: Dictionary = parsed as Dictionary
	if (
		int(runtime.get("schema_version", 0)) != 1
		or String(runtime.get("session", "")) != _session_id
		or int(runtime.get("supervisor_pid", -1)) != _pid
		or int(runtime.get("cloudflared_pid", -1)) <= 0
	):
		return {}
	return runtime

## Reads the public URL the supervisor persisted into runtime.json as soon as its
## pipe captured it. This is a lock-free sidecar: the supervisor closes the file
## after every write, so the editor can read it while cloudflared.log stays open.
func _read_runtime_public_url() -> String:
	var runtime: Dictionary = _load_runtime_state()
	if runtime.is_empty():
		return ""
	var candidate: String = String(runtime.get("public_url", "")).strip_edges()
	if candidate.is_empty():
		return ""
	return candidate if extract_tunnel_url(candidate) == candidate else ""

func _write_stop_request() -> Error:
	var file: FileAccess = FileAccess.open(_stop_path, FileAccess.WRITE)
	if file == null:
		return ERR_FILE_CANT_WRITE
	file.store_string(_session_id)
	file.flush()
	file.close()
	return OK

func _terminate_owned_cloudflared_child() -> void:
	if _legacy_direct_process:
		return
	var runtime: Dictionary = _load_runtime_state()
	if runtime.is_empty():
		return
	var child_pid: int = int(runtime.get("cloudflared_pid", -1))
	if not _is_external_process_running(child_pid):
		return
	var command_line: String = _read_process_command_line(child_pid)
	if cloudflared_command_matches(command_line, _binary_path, _port):
		_terminate_process(child_pid)

## Process operations are wrappers so lifecycle behavior can be unit-tested
## without starting or killing a real executable.
func _spawn_process(binary_path: String, args: PackedStringArray) -> int:
	return OS.create_process(binary_path, args, false)

func _is_process_running(process_id: int) -> bool:
	return OS.is_process_running(process_id)

## OS.is_process_running() only accepts children created by the current Godot
## process on some platforms. Restored sessions need an OS-level existence check
## because their PID came from an earlier editor process.
func _is_external_process_running(process_id: int) -> bool:
	if process_id <= 0:
		return false
	var os_name: String = OS.get_name()
	if os_name == "Linux":
		if DirAccess.dir_exists_absolute("/proc/%d" % process_id):
			return true
		# Some sandboxed/editor environments make procfs entries invisible to
		# DirAccess even though the process is alive. Fall through to ps.
	if os_name == "Windows":
		var task_output: Array = []
		var task_code: int = OS.execute(
			"tasklist.exe",
			PackedStringArray(["/FI", "PID eq %d" % process_id, "/FO", "CSV", "/NH"]),
			task_output,
			true
		)
		return task_code == 0 and not task_output.is_empty() and String(
			task_output[0]
		).contains('"%d"' % process_id)
	var ps_output: Array = []
	var ps_code: int = OS.execute(
		"ps",
		PackedStringArray(["-p", str(process_id), "-o", "pid="]),
		ps_output,
		true
	)
	return ps_code == 0 and not ps_output.is_empty() and String(
		ps_output[0]
	).strip_edges() == str(process_id)

func _terminate_process(process_id: int) -> Error:
	return OS.kill(process_id)

func _read_process_command_line(process_id: int) -> String:
	if process_id <= 0:
		return ""
	var os_name: String = OS.get_name()
	if os_name == "Linux":
		var proc_path: String = "/proc/%d/cmdline" % process_id
		var proc_file: FileAccess = FileAccess.open(proc_path, FileAccess.READ)
		if proc_file != null:
			var command: String = proc_file.get_buffer(proc_file.get_length()).get_string_from_utf8()
			proc_file.close()
			return command.replace(String.chr(0), " ")
	if os_name == "Windows":
		var script: String = (
			"$p = Get-CimInstance Win32_Process -Filter 'ProcessId = %d'; "
			+ "if ($null -ne $p) { [Console]::Out.Write($p.CommandLine) }"
		) % process_id
		for shell in ["powershell.exe", "pwsh.exe"]:
			var windows_output: Array = []
			var windows_exit_code: int = OS.execute(
				String(shell),
				PackedStringArray(["-NoLogo", "-NoProfile", "-NonInteractive", "-Command", script]),
				windows_output,
				true
			)
			if windows_exit_code == 0 and not windows_output.is_empty():
				return String(windows_output[0]).strip_edges()
	var ps_output: Array = []
	var ps_exit_code: int = OS.execute(
		"ps",
		PackedStringArray(["-p", str(process_id), "-o", "command="]),
		ps_output,
		true
	)
	if ps_exit_code == 0 and not ps_output.is_empty():
		return String(ps_output[0]).strip_edges()
	return ""
