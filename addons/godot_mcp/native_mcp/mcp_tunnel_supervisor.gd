extends MainLoop

## Independent, low-overhead owner for one Cloudflare Quick Tunnel.
##
## The editor starts this script as a separate headless Godot process. It keeps
## cloudflared's non-blocking stdout/stderr pipes alive, mirrors both streams to
## a durable project-scoped log, and watches a stop-request file. The supervisor
## therefore survives editor/project reloads while preserving the pipe-based URL
## capture behavior that is reliable across cloudflared versions.

const ARG_PREFIX: String = "--mcp-tunnel-"
const TRYCLOUDFLARE_PATTERN: String = "https://([A-Za-z0-9._-]+)\\.trycloudflare\\.com"
const READ_CHUNK_BYTES: int = 4096
const MAX_START_ATTEMPTS: int = 3
const MAX_SCAN_BUFFER: int = 16384
const STARTUP_ATTEMPT_TIMEOUT_MSEC: int = 20000

var _config: Dictionary = {}
var _stdio: FileAccess = null
var _stderr: FileAccess = null
var _log_file: FileAccess = null
var _child_pid: int = -1
var _initialized_ok: bool = false
var _attempt_count: int = 0
var _attempt_started_msec: int = 0
var _retry_at_msec: int = 0
var _url_seen: bool = false
var _url_persisted: bool = false
var _public_url: String = ""
var _scan_buffer: String = ""

static func parse_user_args(args: PackedStringArray) -> Dictionary:
	var parsed: Dictionary = {}
	for raw_argument in args:
		var argument: String = String(raw_argument)
		if not argument.begins_with(ARG_PREFIX):
			continue
		var separator_index: int = argument.find("=")
		if separator_index <= ARG_PREFIX.length():
			continue
		var key: String = argument.substr(ARG_PREFIX.length(), separator_index - ARG_PREFIX.length())
		var value: String = argument.substr(separator_index + 1)
		parsed[key] = value
	return parsed

static func validate_config(config: Dictionary) -> Error:
	for required_key in ["binary", "log", "runtime", "stop", "session"]:
		if String(config.get(required_key, "")).strip_edges().is_empty():
			return ERR_INVALID_PARAMETER
	var port_text: String = String(config.get("port", ""))
	if not port_text.is_valid_int() or int(port_text) <= 0 or int(port_text) > 65535:
		return ERR_INVALID_PARAMETER
	return OK

static func build_cloudflared_args(port: int) -> PackedStringArray:
	return PackedStringArray([
		"tunnel",
		"--no-autoupdate",
		"--protocol",
		"http2",
		"--url",
		"http://localhost:%d" % port,
	])

## Extracts the first allocated trycloudflare.com URL, ignoring Cloudflare's own
## api.trycloudflare.com hostname that may appear in error messages. This lets the
## supervisor persist the exact public URL instead of only signaling its presence.
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

static func should_retry_quick_tunnel(url_seen: bool, attempts: int, max_attempts: int) -> bool:
	return not url_seen and attempts < max_attempts

static func should_restart_stalled_start(url_seen: bool, started_msec: int,
		now_msec: int, timeout_msec: int) -> bool:
	return (
		not url_seen
		and started_msec > 0
		and timeout_msec > 0
		and now_msec - started_msec >= timeout_msec
	)

func _initialize() -> void:
	Engine.max_fps = 20
	_config = parse_user_args(OS.get_cmdline_user_args())
	if validate_config(_config) != OK:
		return
	var log_path: String = String(_config["log"])
	if DirAccess.make_dir_recursive_absolute(log_path.get_base_dir()) != OK:
		return
	_log_file = FileAccess.open(log_path, FileAccess.WRITE)
	if _log_file == null:
		return
	_append_text("[GodotMcp-XY] Tunnel supervisor %d starting cloudflared.\n" % OS.get_process_id())
	_initialized_ok = true
	if not _start_child():
		_schedule_retry()

func _start_child() -> bool:
	_close_pipes()
	_attempt_count += 1
	_append_text("[GodotMcp-XY] Starting cloudflared attempt %d/%d.\n" % [
		_attempt_count, MAX_START_ATTEMPTS,
	])
	var pipe: Dictionary = OS.execute_with_pipe(
		String(_config["binary"]),
		build_cloudflared_args(int(String(_config["port"]))),
		false
	)
	_child_pid = int(pipe.get("pid", -1))
	_stdio = pipe.get("stdio", null) as FileAccess
	_stderr = pipe.get("stderr", null) as FileAccess
	if _child_pid <= 0:
		_append_text("[GodotMcp-XY] ERROR: Could not start cloudflared attempt %d.\n" % _attempt_count)
		_close_pipes()
		return false
	if _write_runtime_state() != OK:
		_append_text("[GodotMcp-XY] ERROR: Could not persist supervisor runtime state.\n")
		OS.kill(_child_pid)
		_close_pipes()
		_child_pid = -1
		_initialized_ok = false
		return false
	_attempt_started_msec = Time.get_ticks_msec()
	_append_text("[GodotMcp-XY] cloudflared child PID %d started.\n" % _child_pid)
	return true

func _process(_delta: float) -> bool:
	if not _initialized_ok:
		return true
	_drain_output()
	if FileAccess.file_exists(String(_config["stop"])):
		_append_text("[GodotMcp-XY] Stop requested by the user.\n")
		_stop_child()
		return true
	if _child_pid > 0 and OS.is_process_running(_child_pid):
		if should_restart_stalled_start(
			_url_seen,
			_attempt_started_msec,
			Time.get_ticks_msec(),
			STARTUP_ATTEMPT_TIMEOUT_MSEC
		):
			_append_text(
				"[GodotMcp-XY] ERROR: Quick Tunnel URL timed out after %.1f seconds; restarting the pre-URL child.\n" % (
					STARTUP_ATTEMPT_TIMEOUT_MSEC / 1000.0
				)
			)
			_stop_child()
			_close_pipes()
			_remove_file_if_present(String(_config["runtime"]))
			_attempt_started_msec = 0
			if should_retry_quick_tunnel(_url_seen, _attempt_count, MAX_START_ATTEMPTS):
				_schedule_retry()
				return false
			_append_text("[GodotMcp-XY] Startup attempts exhausted; no more automatic retries.\n")
			return true
		return false
	if _child_pid > 0:
		_drain_output()
		_append_text("[GodotMcp-XY] cloudflared attempt %d exited.\n" % _attempt_count)
		_child_pid = -1
		_attempt_started_msec = 0
		_close_pipes()
		_remove_file_if_present(String(_config["runtime"]))
		if not should_retry_quick_tunnel(_url_seen, _attempt_count, MAX_START_ATTEMPTS):
			_append_text("[GodotMcp-XY] cloudflared exited; no more automatic retries.\n")
			return true
		_schedule_retry()
	if _retry_at_msec > 0 and Time.get_ticks_msec() >= _retry_at_msec:
		_retry_at_msec = 0
		if not _start_child():
			if should_retry_quick_tunnel(_url_seen, _attempt_count, MAX_START_ATTEMPTS):
				_schedule_retry()
			else:
				return true
	return false

func _finalize() -> void:
	if _child_pid > 0 and OS.is_process_running(_child_pid):
		OS.kill(_child_pid)
	_close_pipes()
	_remove_file_if_present(String(_config.get("runtime", "")))
	if _log_file != null and _log_file.is_open():
		_log_file.flush()
		_log_file.close()
	_log_file = null

func _drain_output() -> void:
	_append_bytes(_read_pipe(_stderr))
	_append_bytes(_read_pipe(_stdio))

func _read_pipe(pipe: FileAccess) -> PackedByteArray:
	var output: PackedByteArray = PackedByteArray()
	if pipe == null or not pipe.is_open():
		return output
	while true:
		output.append_array(pipe.get_buffer(READ_CHUNK_BYTES))
		if pipe.get_error() != OK:
			break
	return output

func _append_bytes(bytes: PackedByteArray) -> void:
	if bytes.is_empty() or _log_file == null or not _log_file.is_open():
		return
	_scan_buffer += bytes.get_string_from_utf8()
	if not _url_seen:
		var detected: String = extract_tunnel_url(_scan_buffer)
		if not detected.is_empty():
			_url_seen = true
			_public_url = detected
	if _url_seen and not _url_persisted:
		# Persist the URL in a small, atomically-rewritten sidecar file so the
		# editor-side manager can discover it even on Windows, where reading the
		# still-open cloudflared.log may fail until the supervisor closes it.
		_url_persisted = _write_runtime_state() == OK
	if _scan_buffer.length() > MAX_SCAN_BUFFER:
		_scan_buffer = _scan_buffer.substr(_scan_buffer.length() - 4096)
	_log_file.store_buffer(bytes)
	_log_file.flush()

func _append_text(text: String) -> void:
	if _log_file == null or not _log_file.is_open():
		return
	_log_file.store_string(text)
	_log_file.flush()

func _stop_child() -> void:
	if _child_pid > 0 and OS.is_process_running(_child_pid):
		OS.kill(_child_pid)
	_child_pid = -1
	_drain_output()

func _schedule_retry() -> void:
	var delay_msec: int = mini(4000, 500 * (1 << maxi(_attempt_count - 1, 0)))
	_retry_at_msec = Time.get_ticks_msec() + delay_msec
	_append_text("[GodotMcp-XY] Retrying cloudflared in %.1f seconds.\n" % (delay_msec / 1000.0))

func _close_pipe(pipe: FileAccess) -> void:
	if pipe != null and pipe.is_open():
		pipe.close()

func _close_pipes() -> void:
	_close_pipe(_stdio)
	_close_pipe(_stderr)
	_stdio = null
	_stderr = null

func _write_runtime_state() -> Error:
	return write_runtime_state(_config, _child_pid, _public_url)

## Atomically writes the supervisor's ownership + URL sidecar. Static so the
## file-writing behavior (including the public URL) is directly unit-testable
## without constructing a MainLoop instance.
static func write_runtime_state(config: Dictionary, child_pid: int, public_url: String) -> Error:
	var runtime_path: String = String(config.get("runtime", "")).strip_edges()
	if runtime_path.is_empty() or String(config.get("session", "")).strip_edges().is_empty():
		return ERR_INVALID_PARAMETER
	var temporary_path: String = "%s.tmp-%d" % [runtime_path, OS.get_process_id()]
	_remove_file_if_present(temporary_path)
	var file: FileAccess = FileAccess.open(temporary_path, FileAccess.WRITE)
	if file == null:
		return ERR_FILE_CANT_WRITE
	file.store_string(JSON.stringify({
		"schema_version": 1,
		"session": String(config["session"]),
		"supervisor_pid": OS.get_process_id(),
		"cloudflared_pid": child_pid,
		"public_url": public_url,
	}, "\t"))
	file.flush()
	file.close()
	_remove_file_if_present(runtime_path)
	var rename_error: Error = DirAccess.rename_absolute(temporary_path, runtime_path)
	if rename_error != OK:
		_remove_file_if_present(temporary_path)
	return rename_error

static func _remove_file_if_present(path: String) -> void:
	if not path.is_empty() and FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)
