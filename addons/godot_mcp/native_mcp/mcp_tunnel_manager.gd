class_name MCPTunnelManager
extends RefCounted

## Launches and supervises a Cloudflare Quick Tunnel (`cloudflared`) so the panel
## can expose the local MCP server publicly with one click — no manual command.
##
## The tunnel is deliberately independent from the Godot/editor lifecycle.
## Session metadata and cloudflared's log live in a machine-local, project-scoped
## directory. A reloaded plugin or a new Godot process can therefore validate and
## adopt the existing PID/URL. Only stop() terminates it; detach() never does.

const TRYCLOUDFLARE_PATTERN: String = "https://[A-Za-z0-9._-]+\\.trycloudflare\\.com"
const DEFAULT_PORT: int = 9080
const MAX_BUFFER: int = 16384
const MAX_LOG_READ_BYTES: int = 65536
const STATE_SCHEMA_VERSION: int = 1
const SHARED_APP_DIR: String = "GodotMcp-XY"
const SESSION_COMPONENT_DIR: String = "tunnels"
const STATE_FILE_NAME: String = "session.json"
const LOG_FILE_NAME: String = "cloudflared.log"

var _session_dir: String = ""
var _state_path: String = ""
var _log_path: String = ""
var _pid: int = -1
var _public_url: String = ""
var _binary_path: String = ""
var _port: int = 0
var _line_buffer: String = ""
var _log_offset: int = 0
var _spawned_by_this_instance: bool = false

func _init(session_dir: String = "") -> void:
	_session_dir = session_dir.strip_edges()
	if _session_dir.is_empty():
		_session_dir = default_session_dir()
	_session_dir = _session_dir.simplify_path()
	_state_path = _session_dir.path_join(STATE_FILE_NAME)
	_log_path = _session_dir.path_join(LOG_FILE_NAME)

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

## cloudflared writes to a durable log so it never depends on pipes owned by
## Godot. OS.create_process() then keeps the process alive after Godot exits.
static func build_launch_args(port: int, log_path: String) -> PackedStringArray:
	var effective_port: int = port if port > 0 else DEFAULT_PORT
	return PackedStringArray([
		"tunnel",
		"--no-autoupdate",
		"--loglevel",
		"info",
		"--logfile",
		log_path,
		"--url",
		"http://localhost:%d" % effective_port,
	])

## Extracts the first trycloudflare.com URL from a cloudflared log chunk.
static func extract_tunnel_url(text: String) -> String:
	var regex: RegEx = RegEx.new()
	if regex.compile(TRYCLOUDFLARE_PATTERN) != OK:
		return ""
	var result: RegExMatch = regex.search(text)
	if result == null:
		return ""
	return result.get_string()

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
	_spawned_by_this_instance = false
	_log_offset = 0
	_line_buffer = ""
	if not _is_external_process_running(_pid):
		_remove_state_file()
		_reset_runtime(true)
		return false
	var command_line: String = _read_process_command_line(_pid)
	if not command_line_matches_session(command_line, _binary_path, _log_path):
		_remove_state_file()
		_reset_runtime(true)
		return false
	return true

## Starts a detached `<binary> tunnel --url http://localhost:<port>` process.
## Existing persisted sessions are adopted first, preventing duplicate tunnels.
func start(binary_path: String, port: int) -> Error:
	if is_running() or restore():
		return ERR_ALREADY_IN_USE
	var exe: String = binary_path.strip_edges()
	if exe.is_empty():
		return ERR_CANT_CREATE
	var effective_port: int = port if port > 0 else DEFAULT_PORT
	if DirAccess.make_dir_recursive_absolute(_session_dir) != OK:
		return ERR_CANT_CREATE
	_remove_file_if_present(_log_path)
	_remove_state_file()
	_reset_runtime()

	var args: PackedStringArray = build_launch_args(effective_port, _log_path)
	var process_id: int = _spawn_process(exe, args)
	if process_id <= 0:
		return ERR_CANT_CREATE
	_pid = process_id
	_binary_path = exe
	_port = effective_port
	_spawned_by_this_instance = true
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

## Explicit user action: validate ownership once more, terminate cloudflared,
## and remove the resumable session. No lifecycle callback calls this method.
func stop() -> void:
	if is_running():
		var command_line: String = _read_process_command_line(_pid)
		if command_line_matches_session(command_line, _binary_path, _log_path):
			_terminate_process(_pid)
	_remove_state_file()
	_reset_runtime()

## Releases only this Godot instance's in-memory handle. The external process,
## log, and state file intentionally survive project reload and editor shutdown.
func detach() -> void:
	_reset_runtime()

## Removes metadata for a process that has already exited unexpectedly.
func discard_stale_session() -> void:
	if is_running():
		return
	_remove_state_file()
	_reset_runtime()

func _state_dictionary() -> Dictionary:
	return {
		"schema_version": STATE_SCHEMA_VERSION,
		"pid": _pid,
		"public_url": _public_url,
		"binary_path": _binary_path,
		"port": _port,
		"log_path": _log_path,
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
	return (
		int(state.get("schema_version", 0)) == STATE_SCHEMA_VERSION
		and int(state.get("pid", -1)) > 0
		and int(state.get("port", 0)) > 0
		and not String(state.get("binary_path", "")).strip_edges().is_empty()
		and String(state.get("log_path", "")).simplify_path() == _log_path
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
	_port = 0
	_spawned_by_this_instance = false
	_line_buffer = ""
	_log_offset = 0
	if not preserve_url:
		_public_url = ""

func _remove_state_file() -> void:
	_remove_file_if_present(_state_path)

func _remove_file_if_present(path: String) -> void:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)

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
