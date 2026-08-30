# mcp_server_native.gd - 原生MCP服务器插件主类
# 根据godot-dev-guide优化，添加完整的类型提示和@export变量

@tool
extends EditorPlugin

# ============================================================================
# 配置变量（根据godot-dev-guide使用@export）
# ============================================================================

@export var auto_start: bool = false:
	set(value):
		auto_start = value
		notify_property_list_changed()

@export var vibe_coding_mode: bool = true:
	set(value):
		vibe_coding_mode = value
		notify_property_list_changed()

@export var transport_mode: String = "http":
	set(value):
		if value == "stdio" or value == "http":
			transport_mode = value
			if _native_server:
				var type: int = MCPServerCore.TransportType.TRANSPORT_STDIO if value == "stdio" \
					else MCPServerCore.TransportType.TRANSPORT_HTTP
				_native_server.set_transport_type(type)
			notify_property_list_changed()
		else:
			_log_error("Invalid transport mode: " + value + ". Valid values are 'stdio' or 'http'")

@export var http_port: int = 9080:
	set(value):
		if value < 1024 or value > 65535:
			_log_error("Invalid port: " + str(value) + ". Please use a port between 1024 and 65535.")
			return
		http_port = value
		if _native_server and _native_server.has_method("set_http_port"):
			_native_server.set_http_port(value)
		notify_property_list_changed()

@export var auth_enabled: bool = false:
	set(value):
		auth_enabled = value
		notify_property_list_changed()

@export var auth_token: String = "":
	set(value):
		if value.length() < 16 and not value.is_empty():
			_log_warn("Auth token is too short. Please use at least 16 characters for security.")
		auth_token = value
		notify_property_list_changed()

@export_range(0, 3, 1) var log_level: int = 2:  # 0=ERROR, 1=WARN, 2=INFO, 3=DEBUG (默认2=INFO，便于测试)
	set(value):
		log_level = value
		if _native_server:
			_native_server.set_log_level(value)
		notify_property_list_changed()

@export var security_level: int = 1:  # 0=PERMISSIVE, 1=STRICT
	set(value):
		security_level = value
		if _native_server:
			_native_server.set_security_level(value)
		notify_property_list_changed()

@export var rate_limit: int = 1000:
	set(value):
		rate_limit = value
		if _native_server:
			_native_server.set_rate_limit(value)
		notify_property_list_changed()

@export var sse_enabled: bool = true:
	set(value):
		sse_enabled = value
		notify_property_list_changed()

@export var allow_remote: bool = false:
	set(value):
		allow_remote = value
		notify_property_list_changed()

@export var cors_origin: String = "":
	set(value):
		cors_origin = value
		notify_property_list_changed()

# ============================================================================
# 内部变量（使用完整类型提示 - 根据godot-dev-guide）
# ============================================================================

var _native_server: RefCounted = null
var _main_panel: Control = null
var _editor_interface: EditorInterface = null
var _mcp_server_mode: bool = false
var _tool_instances: Dictionary = {}
var _debugger_bridge: MCPDebuggerBridge = null
var _prompt_workflows: RefCounted = null  # prompt_workflows.gd 实例（MCP prompts 工作流模板）
var _cache_change_tracker: RefCounted = null
var _editor_filesystem: EditorFileSystem = null
var _cache_change_flush_pending: bool = false
var _cache_filesystem_snapshot_pending: bool = false
# 本次插件会话是否由 _ensure_runtime_probe_autoload() 新增了 runtime probe autoload。
# 若 project.godot 本来就声明了该 autoload（当前仓库正是如此），退出时不得删除它。
var _probe_autoload_added_this_session: bool = false

const CACHE_CHANGE_TRACKER_SCRIPT = preload(
	"res://addons/godot_mcp/native_mcp/cache_change_tracker.gd")

const TOOL_SCRIPT_PATHS: Dictionary = {
	"NodeToolsNative": "res://addons/godot_mcp/tools/node_tools_native.gd",
	"ScriptToolsNative": "res://addons/godot_mcp/tools/script_tools_native.gd",
	"SceneToolsNative": "res://addons/godot_mcp/tools/scene_tools_native.gd",
	"EditorToolsNative": "res://addons/godot_mcp/tools/editor_tools_native.gd",
	"DebugToolsNative": "res://addons/godot_mcp/tools/debug_tools_native.gd",
	# debug_tools_native.gd 按域拆分出的子模块（注册顺序与原文件分区顺序一致）
	"DebugBridgeTools": "res://addons/godot_mcp/tools/debug_bridge_tools.gd",
	"DebugRuntimeTools": "res://addons/godot_mcp/tools/debug_runtime_tools.gd",
	"DebugVerifyTools": "res://addons/godot_mcp/tools/debug_verify_tools.gd",
	"ProjectToolsNative": "res://addons/godot_mcp/tools/project_tools_native.gd",
	# project_tools_native.gd 按域拆分出的子模块（注册顺序与原文件分区顺序一致）
	"ProjectResourcesTools": "res://addons/godot_mcp/tools/project_resources_tools.gd",
	"ProjectAssetsTools": "res://addons/godot_mcp/tools/project_assets_tools.gd",
	"ProjectTilesetTools": "res://addons/godot_mcp/tools/project_tileset_tools.gd",
	"ProjectVerificationTools": "res://addons/godot_mcp/tools/project_verification_tools.gd",
	"ProjectWorkflowTools": "res://addons/godot_mcp/tools/project_workflow_tools.gd",
	"ExportPresetTools": "res://addons/godot_mcp/tools/export_preset_tools.gd",
	"GameWorkflowTools": "res://addons/godot_mcp/tools/game_workflow_tools.gd",
	"MetaToolsNative": "res://addons/godot_mcp/tools/meta_tools_native.gd"
}

# ============================================================================
# 生命周期方法
# ============================================================================

## 运行状态持久化：reload_project / 插件重载 / 编辑器重启后自动复活服务器。
## 与隧道守护同一哲学——用户点过 Start，就应在下次 enter_tree 时自动回来；
## 用户显式点 Stop 则写入 false，保持停止。文件是 user:// 级的轻量标记。
const SERVER_STATE_FILE: String = "user://mcp_server_running.json"

static func _write_server_running_state(running: bool) -> void:
	var file: FileAccess = FileAccess.open(SERVER_STATE_FILE, FileAccess.WRITE)
	if file:
		file.store_string(JSON.stringify({"running": running}))
		file.close()

# 自愈看门狗：reload_project 只重载资源与脚本（插件实例不重建、_enter_tree
# 不再触发，热重载还会重置成员并掐断服务器线程），因此复活必须由常驻
# _process 驱动：标记为运行而传输已死 -> 重新拉起。覆盖一切拆除路径。
var _resurrect_check_msec: int = 0
var _resurrect_backoff_until_msec: int = 0
# heartbeat==0 首次观测时间：热重载把新脚本套到僵尸实例上时，字段被重置为 0
# 且死线程永远不会再写，必须按"持续为零"判僵尸，否则端口占用永远无法自愈。
var _zero_heartbeat_since_msec: int = 0

func _process(_delta: float) -> void:
	var now: int = Time.get_ticks_msec()
	if now - _resurrect_check_msec < 2000:
		return
	_resurrect_check_msec = now
	if not _read_server_running_state():
		return
	if now < _resurrect_backoff_until_msec:
		return
	if is_server_running():
		# 僵尸检测：套接字与线程仍在、心跳停跳（热重载斩断回调链的典型残留，
		# 表现为端口监听但请求得到空响应）。心跳字段在 HTTP 传输层上；stdio 等
		# 无心跳概念的传输直接信任 is_running。
		var transport: Object = _native_server.get_transport()
		if transport == null or not ("last_heartbeat_msec" in transport):
			_zero_heartbeat_since_msec = 0
			return
		var heartbeat_msec: int = int(transport.get("last_heartbeat_msec"))
		var heartbeat_age: int = 0
		if heartbeat_msec > 0:
			_zero_heartbeat_since_msec = 0
			heartbeat_age = now - heartbeat_msec
			if heartbeat_age <= 10000:
				return
		else:
			# 热重载把新脚本套到僵尸实例上时字段被重置为 0 且死线程不再写：
			# 持续为零超过宽限期同样判僵尸。
			if _zero_heartbeat_since_msec == 0:
				_zero_heartbeat_since_msec = now
			heartbeat_age = now - _zero_heartbeat_since_msec
			if heartbeat_age <= 15000:
				return
		_zero_heartbeat_since_msec = 0
		_log_info("Watchdog: server heartbeat stale (%d ms); rebuilding zombie transport" % heartbeat_age)
		_native_server.stop()
		if is_server_running():
			return
	_log_info("Watchdog: server flag says running but transport is down; resurrecting")
	if not _start_native_server():
		# 拉起失败（端口被占等）退避 30s，避免每 2 秒风暴式重试。
		_resurrect_backoff_until_msec = now + 30000

static func _read_server_running_state() -> bool:
	if not FileAccess.file_exists(SERVER_STATE_FILE):
		return false
	var file: FileAccess = FileAccess.open(SERVER_STATE_FILE, FileAccess.READ)
	if file == null:
		return false
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	file.close()
	return parsed is Dictionary and bool((parsed as Dictionary).get("running", false))

func _enter_tree() -> void:
	_log_info("Godot Native MCP Plugin entering tree...")

	# Load persisted config (mcp_settings.cfg) onto the exported properties
	# before the server is created, so headless `--mcp-server` mode honors the
	# port/transport/auth set via the editor UI. The @export setters guard on
	# `_native_server` (still null here), so this only stores values; the
	# set_* calls below apply them to the server.
	#
	# Command-line overrides (--mcp-port / --mcp-transport) are NOT applied
	# here: the main-screen panel created below runs _load_settings() during
	# _enter_tree, which re-assigns the persisted port to the server through
	# the http_port setter and would clobber an override applied this early.
	# Overrides are applied last, inside _start_native_server(), right before
	# the port is bound. Precedence: @export default < persisted cfg < cmd line.
	_apply_persisted_settings()

	Engine.set_meta("GodotMCPPlugin", self)
	
	_editor_interface = get_editor_interface()
	if not _editor_interface:
		_log_error("Failed to get EditorInterface")
		return
	
	_native_server = _instantiate_script("res://addons/godot_mcp/native_mcp/mcp_server_core.gd")

	if not _native_server:
		_log_error("Failed to create MCP Server Core instance")
		return

	_debugger_bridge = load("res://addons/godot_mcp/native_mcp/mcp_debugger_bridge.gd").new()
	if not _debugger_bridge:
		_log_error("Failed to create debugger bridge instance")
		return
	add_debugger_plugin(_debugger_bridge)
	
	# 设置传输方式
	var type: int = MCPServerCore.TransportType.TRANSPORT_STDIO if transport_mode == "stdio" \
			else MCPServerCore.TransportType.TRANSPORT_HTTP
	_native_server.set_transport_type(type)
	_log_info("Transport type set to: " + transport_mode)
	
	# 设置 HTTP 端口
	_native_server.set_http_port(http_port)
	_log_info("HTTP port set to: " + str(http_port))
	
	# 按当前配置应用认证（创建或移除认证管理器）。
	# S2 修复：认证配置在服务器启动时重新评估，启动前在面板中开启认证也能生效。
	_apply_auth_config()
	
	# 配置 SSE 和远程访问（仅 HTTP 模式）
	if transport_mode == "http":
		if _native_server.has_method("set_sse_enabled"):
			_native_server.set_sse_enabled(sse_enabled)
			_log_info("SSE enabled: " + str(sse_enabled))
		
		if _native_server.has_method("set_remote_config"):
			_native_server.set_remote_config(allow_remote, cors_origin)
			_log_info("Remote config: allow_remote=" + str(allow_remote) + ", cors=" + cors_origin)
	
	# 配置服务器
	_native_server.set_log_level(log_level)
	_native_server.set_security_level(security_level)
	_native_server.set_rate_limit(rate_limit)
	
	# 连接信号（根据godot-dev-guide信号模式）
	_native_server.server_started.connect(_on_server_started)
	_native_server.server_stopped.connect(_on_server_stopped)
	_native_server.message_received.connect(_on_message_received)
	_native_server.response_sent.connect(_on_response_sent)
	_native_server.tool_execution_started.connect(_on_tool_started)
	_native_server.tool_execution_completed.connect(_on_tool_completed)
	_native_server.tool_execution_failed.connect(_on_tool_failed)
	_native_server.log_message.connect(_on_log_message)
	_connect_cache_change_signals()
	
	# 注册所有工具
	_register_all_tools()
	
	# Register MCPRuntimeProbe as autoload singleton for runtime debugger communication.
	# 只有本次会话真正新增的 autoload 才会在 _exit_tree() 中移除；project.godot
	# 静态声明的 autoload 必须保留，避免无头导入/编辑器退出时破坏项目配置。
	_probe_autoload_added_this_session = not ProjectSettings.has_setting("autoload/MCPRuntimeProbe")
	_ensure_runtime_probe_autoload()
	
	# 注册所有资源
	_register_all_resources()
	
	# 注册所有 prompts（真实工作流模板）
	_register_all_prompts()
	
	# 在UI创建前加载已保存的工具状态（确保UI显示正确的启用状态）
	if _native_server.has_method("load_tool_states"):
		_native_server.load_tool_states()
		_log_info("Loaded saved tool states before UI creation")
	
	# 创建UI面板
	_create_main_screen_panel()
	
	# 检测是否以MCP服务器模式启动
	_mcp_server_mode = "--mcp-server" in OS.get_cmdline_user_args()
	
	if _mcp_server_mode:
		_log_info("MCP server mode detected via --mcp-server argument")
		_start_native_server()
	elif auto_start:
		_log_info("Auto-start enabled, starting MCP server")
		_start_native_server()
	elif _read_server_running_state():
		_log_info("Resurrecting MCP server (it was running before reload/restart)")
		_start_native_server()
	else:
		_log_info("MCP server not auto-started. Use Start button or --mcp-server flag.")
	
	_log_info("Godot Native MCP Plugin initialized")

func _exit_tree() -> void:
	_log_info("Godot Native MCP Plugin exiting tree...")
	_disconnect_cache_change_signals()
	
	if _native_server and _native_server.is_running():
		_native_server.stop()
	
	if _main_panel:
		EditorInterface.get_editor_main_screen().remove_child(_main_panel)
		_main_panel.queue_free()
		_main_panel = null

	# 仅在本次插件会话真正新增了 autoload 时才移除；项目静态声明的
	# MCPRuntimeProbe autoload 属于 project.godot，退出时不得删除。
	if _probe_autoload_added_this_session:
		_remove_runtime_probe_autoload()

	if _debugger_bridge:
		remove_debugger_plugin(_debugger_bridge)
		_debugger_bridge = null
	
	_native_server = null
	
	_log_info("Godot Native MCP Plugin shutdown complete")


## Parse MCP command-line overrides from user args (the tokens after the `--`
## separator). Returns {"http_port": int, "transport_mode": String}. A port of
## -1 and an empty transport mean "no override given". Out-of-range ports and
## unknown transports are ignored, so a malformed argument can never break
## startup. Pure/static so it can be unit-tested without EditorInterface.
static func parse_mcp_overrides(args: PackedStringArray) -> Dictionary:
	var port: int = -1
	var transport: String = ""
	for arg in args:
		if arg.begins_with("--mcp-port="):
			var p: int = arg.substr(len("--mcp-port=")).to_int()
			if p >= 1024 and p <= 65535:
				port = p
		elif arg.begins_with("--mcp-transport="):
			var t: String = arg.substr(len("--mcp-transport="))
			if t == "http" or t == "stdio":
				transport = t
	return {"http_port": port, "transport_mode": transport}


## Load persisted settings (mcp_settings.cfg) onto the exported properties
## before the server is configured, so headless `--mcp-server` mode honors the
## port/transport/auth set via the editor UI. Mirrors the panel _load_settings.
## `user://` resolves under --user-data-dir, so each parallel instance reads its
## own config. @export setters guard on `_native_server` (still null here), so
## assigning is safe; the set_* calls later in _enter_tree apply the values.
func _apply_persisted_settings() -> void:
	var mgr: MCPSettingsManager = MCPSettingsManager.new()
	var s: Dictionary = mgr.load_settings()
	if s.is_empty():
		return
	if s.has("transport_mode"):
		transport_mode = s["transport_mode"]
	if s.has("http_port"):
		http_port = s["http_port"]
	if s.has("auth_enabled"):
		auth_enabled = s["auth_enabled"]
	if s.has("auth_token"):
		auth_token = s["auth_token"]
	if s.has("sse_enabled"):
		sse_enabled = s["sse_enabled"]
	if s.has("allow_remote"):
		allow_remote = s["allow_remote"]
	if s.has("cors_origin"):
		cors_origin = s["cors_origin"]
	if s.has("log_level"):
		log_level = s["log_level"]
	if s.has("security_level"):
		security_level = s["security_level"]
	if s.has("rate_limit"):
		rate_limit = s["rate_limit"]
	if s.has("auto_start"):
		auto_start = s["auto_start"]
	_log_info("Applied persisted settings: port=" + str(http_port) + " transport=" + transport_mode)


## Apply command-line overrides on top of persisted/exported settings. The
## command line wins, letting multiple MCP instances run with distinct ports
## (--mcp-port=N) regardless of the persisted config.
func _apply_cmdline_overrides() -> void:
	var o: Dictionary = parse_mcp_overrides(OS.get_cmdline_user_args())
	var port_override: int = int(o["http_port"])
	var transport_override: String = o["transport_mode"]
	if port_override >= 0:
		http_port = port_override
		_log_info("MCP port overridden via command line: " + str(http_port))
	if transport_override != "":
		transport_mode = transport_override
		_log_info("MCP transport overridden via command line: " + transport_mode)


## 判定认证配置是否应生效（纯逻辑，便于单元测试）。
## @param enabled: bool - 面板/配置中的认证开关
## @param transport: String - 当前传输模式（"http" / "stdio"）
## @returns: bool - 需要创建并挂载认证管理器
static func should_enable_auth(enabled: bool, transport: String) -> bool:
	return enabled and transport == "http"


## 按当前配置重建认证管理器（S2 修复）。
## 在服务器真正 start() 之前调用：若启用认证且为 HTTP 传输，则创建新的
## McpAuthManager（带上当前 token）并挂到服务器 core；否则置空，确保关闭认证
## 或切换传输后移除旧的认证管理器。必须在 _apply_cmdline_overrides() 之后调用，
## 以保证 transport_mode 已包含命令行覆盖（--mcp-transport）。
func _apply_auth_config() -> void:
	if not _native_server:
		return
	
	if should_enable_auth(auth_enabled, transport_mode):
		var auth_manager: McpAuthManager = McpAuthManager.new()
		auth_manager.set_token(auth_token)
		auth_manager.set_enabled(true)
		_native_server.set_auth_manager(auth_manager)
		_log_info("Auth manager created and enabled")
	else:
		_native_server.set_auth_manager(null)
		_log_info("Auth manager disabled or not applicable (transport=" + transport_mode + ")")

# ============================================================================
# 插件配置（根据godot-dev-guide优化）
# ============================================================================

func _has_main_screen() -> bool:
	return true

func _make_visible(visible: bool) -> void:
	if _main_panel:
		_main_panel.visible = visible

func _get_plugin_name() -> String:
	return "MCP"

func _get_plugin_icon() -> Texture2D:
	return preload("res://addons/godot_mcp/icon.svg")

func get_native_server() -> RefCounted:
	return _native_server

func get_debugger_bridge() -> MCPDebuggerBridge:
	return _debugger_bridge

func _has_settings() -> bool:
	return true

func _get_property_list() -> Array:
	var properties: Array = []
	
	properties.append({
		"name": "MCP Transport Settings",
		"type": TYPE_NIL,
		"hint_string": "MCP Transport Settings",
		"usage": PROPERTY_USAGE_CATEGORY
	})
	
	properties.append({
		"name": "transport_mode",
		"type": TYPE_STRING,
		"hint": PROPERTY_HINT_ENUM,
		"hint_string": "stdio,http",
		"usage": PROPERTY_USAGE_DEFAULT
	})
	
	properties.append({
		"name": "http_port",
		"type": TYPE_INT,
		"hint": PROPERTY_HINT_RANGE,
		"hint_string": "1024,65535,1",
		"usage": PROPERTY_USAGE_DEFAULT
	})
	
	properties.append({
		"name": "auth_enabled",
		"type": TYPE_BOOL,
		"usage": PROPERTY_USAGE_DEFAULT
	})
	
	properties.append({
		"name": "auth_token",
		"type": TYPE_STRING,
		"hint": PROPERTY_HINT_PASSWORD,
		"usage": PROPERTY_USAGE_DEFAULT
	})
	
	properties.append({
		"name": "sse_enabled",
		"type": TYPE_BOOL,
		"usage": PROPERTY_USAGE_DEFAULT
	})
	
	properties.append({
		"name": "allow_remote",
		"type": TYPE_BOOL,
		"usage": PROPERTY_USAGE_DEFAULT
	})
	
	properties.append({
		"name": "cors_origin",
		"type": TYPE_STRING,
		"usage": PROPERTY_USAGE_DEFAULT
	})
	
	# 添加属性分组（根据godot-dev-guide）
	properties.append({
		"name": "MCP Settings",
		"type": TYPE_NIL,
		"usage": PROPERTY_USAGE_CATEGORY
	})
	
	properties.append({
		"name": "auto_start",
		"type": TYPE_BOOL,
		"usage": PROPERTY_USAGE_DEFAULT
	})

	properties.append({
		"name": "vibe_coding_mode",
		"type": TYPE_BOOL,
		"usage": PROPERTY_USAGE_DEFAULT
	})
	
	properties.append({
		"name": "log_level",
		"type": TYPE_INT,
		"hint": PROPERTY_HINT_ENUM,
		"hint_string": "ERROR,WARN,INFO,DEBUG",
		"usage": PROPERTY_USAGE_DEFAULT
	})
	
	properties.append({
		"name": "security_level",
		"type": TYPE_INT,
		"hint": PROPERTY_HINT_ENUM,
		"hint_string": "PERMISSIVE,STRICT",
		"usage": PROPERTY_USAGE_DEFAULT
	})
	
	properties.append({
		"name": "rate_limit",
		"type": TYPE_INT,
		"hint": PROPERTY_HINT_RANGE,
		"hint_string": "10,1000,10",
		"usage": PROPERTY_USAGE_DEFAULT
	})
	
	return properties

# ============================================================================
# 公共API
# ============================================================================

func start_server() -> bool:
	return _start_native_server()

func stop_server() -> void:
	_stop_native_server()

func is_server_running() -> bool:
	if _native_server:
		return _native_server.is_running()
	return false

func get_server_status() -> Dictionary:
	if not _native_server:
		return {"status": "not_initialized"}
	
	return {
		"status": "running" if _native_server.is_running() else "stopped",
		"log_level": log_level,
		"security_level": security_level,
		"rate_limit": rate_limit,
		"tools_count": _get_tools_count(),
		"resources_count": _get_resources_count()
	}

# ============================================================================
# 私有方法 - 服务器管理
# ============================================================================

func _start_native_server() -> bool:
	if not _native_server:
		_log_error("MCP Server instance not available")
		return false
	
	if _native_server.is_running():
		_log_warn("MCP Server already running")
		return false

	# Apply command-line overrides (--mcp-port / --mcp-transport) last, right
	# before binding. The main-screen panel's _load_settings() runs during
	# _enter_tree and re-pushes the persisted port onto the server via the
	# http_port setter; applying the override here makes --mcp-port
	# authoritative at bind time, so parallel headless instances can coexist on
	# distinct ports regardless of mcp_settings.cfg. A pure no-op without
	# overrides (parse_mcp_overrides returns -1 / "").
	_apply_cmdline_overrides()

	# 在真正 start() 前按当前配置重建认证管理器（S2 修复）。
	# 必须在 _apply_cmdline_overrides() 之后执行，确保 transport_mode 已包含
	# 命令行覆盖。覆盖面板 Start 按钮与 --mcp-server / auto_start 两条启动路径。
	_apply_auth_config()

	_log_info("Starting native MCP server...")
	var success: bool = _native_server.start()
	
	if success:
		_log_info("Native MCP Server started - transport: " + transport_mode)
		_write_server_running_state(true)
	else:
		_log_error("Failed to start MCP Server")
	
	return success

func _stop_native_server() -> void:
	# 显式停止才落 false；_exit_tree 的被动停止不写状态，重载后据此复活。
	_write_server_running_state(false)
	if not _native_server:
		return
	
	if not _native_server.is_running():
		_log_warn("MCP Server not running")
		return
	
	_log_info("Stopping native MCP server...")
	_native_server.stop()
	_log_info("Native MCP Server stopped")

func _ensure_runtime_probe_autoload() -> void:
	# Register MCPRuntimeProbe as an Autoload singleton via ProjectSettings.
	# The "*" prefix marks it as a global singleton that survives scene changes.
	var autoload_key: String = "autoload/MCPRuntimeProbe"
	var autoload_path: String = "*res://addons/godot_mcp/runtime/mcp_runtime_probe.gd"
	if not ProjectSettings.has_setting(autoload_key):
		ProjectSettings.set_setting(autoload_key, autoload_path)
		ProjectSettings.save()
		_log_info("MCPRuntimeProbe autoload registered")

func _remove_runtime_probe_autoload() -> void:
	var autoload_key: String = "autoload/MCPRuntimeProbe"
	if ProjectSettings.has_setting(autoload_key):
		ProjectSettings.clear(autoload_key)
		ProjectSettings.save()
		_log_info("MCPRuntimeProbe autoload removed")

func _get_tools_count() -> int:
	if not _native_server:
		return 0
	# 这里需要添加一个方法到MCPServerCore来获取工具数量
	return _native_server.get_tools_count() if _native_server.has_method("get_tools_count") else 0

func _get_resources_count() -> int:
	if not _native_server:
		return 0
	# 这里需要添加一个方法到MCPServerCore来获取资源数量
	return _native_server.get_resources_count() if _native_server.has_method("get_resources_count") else 0

# ============================================================================
# 私有方法 - 工具注册（根据mcp-builder优化）
# ============================================================================

func _register_all_tools() -> void:
	_log_info("Registering all MCP tools...")
	
	if not _native_server:
		_log_error("MCP Server instance not available")
		return
	
	for module_name in TOOL_SCRIPT_PATHS.keys():
		var instance: Variant = _instantiate_script(str(TOOL_SCRIPT_PATHS[module_name]))
		if not instance:
			_log_error("Failed to instantiate tool module: " + str(module_name))
			continue
		_register_tool_module(str(module_name), instance)
	
	var total_tools: int = _native_server.get_tools_count()
	_log_info("All MCP tools registered successfully. Total: " + str(total_tools))

func _register_tool_module(module_name: String, instance: RefCounted) -> void:
	if not instance:
		return
	
	_tool_instances[module_name] = instance
	var tools_before: int = _native_server.get_tools_count() if _native_server and _native_server.has_method("get_tools_count") else -1
	_log_info("Registering tool module: %s (before=%d)" % [module_name, tools_before])
	
	if instance.has_method("initialize"):
		instance.initialize(_editor_interface)
	
	if instance.has_method("register_tools"):
		instance.register_tools(_native_server)
	var tools_after: int = _native_server.get_tools_count() if _native_server and _native_server.has_method("get_tools_count") else -1
	_log_info("Registered tool module: %s (after=%d, added=%d)" % [module_name, tools_after, tools_after - tools_before])

func _instantiate_script(script_path: String) -> Variant:
	var script: Script = ResourceLoader.load(script_path, "", ResourceLoader.CACHE_MODE_REPLACE)
	if not script:
		_log_error("Failed to load script: " + script_path)
		return null
	return script.new()

# ============================================================================
# 私有方法 - 资源注册（根据mcp-builder优化）
# ============================================================================

func _register_all_resources() -> void:
	_log_info("Registering all MCP resources...")
	
	if not _native_server:
		_log_error("MCP Server instance not available")
		return
	
	# 注册场景资源
	_register_scene_resources()
	
	# 注册脚本资源
	_register_script_resources()
	
	# 注册项目资源
	_register_project_resources()
	
	# 注册编辑器资源
	_register_editor_resources()
	
	_log_info("All MCP resources registered successfully")

# ============================================================================
# 私有方法 - Prompt 注册（真实工作流模板）
# ============================================================================

func _register_all_prompts() -> void:
	_log_info("Registering all MCP prompts...")
	
	if not _native_server:
		_log_error("MCP Server instance not available")
		return
	
	_prompt_workflows = _instantiate_script("res://addons/godot_mcp/native_mcp/prompt_workflows.gd")
	if not _prompt_workflows:
		_log_error("Failed to instantiate prompt workflows module")
		return
	
	var count: int = 0
	if _prompt_workflows.has_method("register_to_server"):
		count = int(_prompt_workflows.register_to_server(_native_server))
	_log_info("All MCP prompts registered successfully. Total: " + str(count))

func _register_scene_resources() -> void:
	# godot://scene/list
	_native_server.register_resource(
		"godot://scene/list",
		"Godot Scene List",
		"application/json",
		Callable(self, "_resource_scene_list"),
		"List of all .tscn scene files in the project"
	)
	
	# godot://scene/current
	_native_server.register_resource(
		"godot://scene/current",
		"Current Scene",
		"application/json",
		Callable(self, "_resource_scene_current"),
		"Structure of the currently open scene in the editor"
	)

func _register_script_resources() -> void:
	# godot://script/list
	_native_server.register_resource(
		"godot://script/list",
		"Godot Script List",
		"application/json",
		Callable(self, "_resource_script_list"),
		"List of all .gd script files in the project"
	)
	
	# godot://script/current
	_native_server.register_resource(
		"godot://script/current",
		"Current Script",
		"text/plain",
		Callable(self, "_resource_script_current"),
		"Content of the currently open script in the editor"
	)

func _register_project_resources() -> void:
	# godot://project/info
	_native_server.register_resource(
		"godot://project/info",
		"Project Info",
		"application/json",
		Callable(self, "_resource_project_info"),
		"Project name, version, and basic information"
	)
	
	# godot://project/settings
	_native_server.register_resource(
		"godot://project/settings",
		"Project Settings",
		"application/json",
		Callable(self, "_resource_project_settings"),
		"Project setting values and configuration"
	)

func _register_editor_resources() -> void:
	# godot://editor/state
	_native_server.register_resource(
		"godot://editor/state",
		"Editor State",
		"application/json",
		Callable(self, "_resource_editor_state"),
		"Current editor state and active tools"
	)

# ============================================================================
# 资源加载方法（实际实现）
# ============================================================================

func _resource_scene_list(params: Dictionary) -> Dictionary:
	var scenes: Array = []
	var dir = DirAccess.open("res://")

	if not dir:
		return {"contents": [{"uri": "godot://scene/list", "mimeType": "application/json", "text": "[]"}]}

	_find_files_recursive(dir, ".tscn", scenes)

	return {
		"contents": [{
			"uri": "godot://scene/list",
			"mimeType": "application/json",
			"text": JSON.stringify({
				"scenes": scenes,
				"count": scenes.size(),
				"timestamp": Time.get_unix_time_from_system()
			}, "\t", true)
		}]
	}

func _resource_scene_current(params: Dictionary) -> Dictionary:
	if not _editor_interface:
		return {"contents": [{"uri": "godot://scene/current", "mimeType": "application/json", "text": "{}"}]}

	var scene_root: Node = _editor_interface.get_edited_scene_root()
	if not scene_root:
		return {"contents": [{"uri": "godot://scene/current", "mimeType": "application/json", "text": "{}"}]}

	var scene_info: Dictionary = {
		"name": scene_root.name,
		"path": scene_root.scene_file_path,
		"type": scene_root.get_class(),
		"node_count": _count_nodes(scene_root),
		"children": _get_node_tree(scene_root, 2)
	}

	return {
		"contents": [{
			"uri": "godot://scene/current",
			"mimeType": "application/json",
			"text": JSON.stringify(scene_info, "\t", true)
		}]
	}

func _resource_script_list(params: Dictionary) -> Dictionary:
	var scripts: Array = []
	var dir = DirAccess.open("res://")

	if not dir:
		return {"contents": [{"uri": "godot://script/list", "mimeType": "application/json", "text": "[]"}]}

	_find_files_recursive(dir, ".gd", scripts)

	return {
		"contents": [{
			"uri": "godot://script/list",
			"mimeType": "application/json",
			"text": JSON.stringify({
				"scripts": scripts,
				"count": scripts.size(),
				"timestamp": Time.get_unix_time_from_system()
			}, "\t", true)
		}]
	}

func _resource_script_current(params: Dictionary) -> Dictionary:
	return {
		"contents": [{
			"uri": "godot://script/current",
			"mimeType": "text/plain",
			"text": "# Current script feature not yet implemented\n# Godot 4.x requires EditorPlugin or ScriptEditor to get current script"
		}]
	}

func _resource_project_info(params: Dictionary) -> Dictionary:
	var project_info: Dictionary = {
		"name": ProjectSettings.get_setting("application/config/name", "未命名项目"),
		"version": ProjectSettings.get_setting("application/config/version", "1.0"),
		"description": ProjectSettings.get_setting("application/config/description", ""),
		"author": ProjectSettings.get_setting("application/config/author", ""),
		"godot_version": _get_godot_version(),
		"timestamp": Time.get_unix_time_from_system()
	}

	return {
		"contents": [{
			"uri": "godot://project/info",
			"mimeType": "application/json",
			"text": JSON.stringify(project_info, "\t", true)
		}]
	}

func _resource_project_settings(params: Dictionary) -> Dictionary:
	var settings: Dictionary = {}
	var property_list: Array = ProjectSettings.get_property_list()

	# 只导出非内部的设置
	for property in property_list:
		var property_name: String = property.get("name", "")
		if property_name.begins_with("application/") or property_name.begins_with("display/") or property_name.begins_with("rendering/"):
			settings[property_name] = ProjectSettings.get_setting(property_name)

	return {
		"contents": [{
			"uri": "godot://project/settings",
			"mimeType": "application/json",
			"text": JSON.stringify({
				"settings": settings,
				"count": settings.size(),
				"timestamp": Time.get_unix_time_from_system()
			}, "\t", true)
		}]
	}

func _resource_editor_state(params: Dictionary) -> Dictionary:
	if not _editor_interface:
		return {"contents": [{"uri": "godot://editor/state", "mimeType": "application/json", "text": "{}"}]}

	var editor_state: Dictionary = {
		"current_scene": "",
		"selected_nodes": [],
		"timestamp": Time.get_unix_time_from_system()
	}

	var scene_root: Node = _editor_interface.get_edited_scene_root()
	if scene_root:
		editor_state["current_scene"] = scene_root.scene_file_path

	var selection = _editor_interface.get_selection()
	if selection:
		var selected_nodes: Array = selection.get_selected_nodes()
		for node in selected_nodes:
			editor_state["selected_nodes"].append(str(node.get_path()))

	return {
		"contents": [{
			"uri": "godot://editor/state",
			"mimeType": "application/json",
			"text": JSON.stringify(editor_state, "\t", true)
		}]
	}

# ============================================================================
# 资源加载辅助函数
# ============================================================================

static func _find_files_recursive(dir: DirAccess, extension: String, result: Array, base_path: String = "res://") -> void:
	dir.list_dir_begin()
	var file_name: String = dir.get_next()

	while file_name != "":
		var full_path: String = base_path.path_join(file_name)

		if dir.current_is_dir():
			var sub_dir: DirAccess = DirAccess.open(full_path + "/")
			if sub_dir:
				_find_files_recursive(sub_dir, extension, result, full_path + "/")
		elif file_name.ends_with(extension):
			# 找到匹配的文件
			result.append(full_path)

		file_name = dir.get_next()

	dir.list_dir_end()

static func _count_nodes(node: Node) -> int:
	var count: int = 1  # 当前节点

	for child in node.get_children():
		count += _count_nodes(child)

	return count

static func _get_node_tree(node: Node, max_depth: int, current_depth: int = 0) -> Array:
	if current_depth >= max_depth:
		return []

	var result: Array = []

	for child in node.get_children():
		var child_info: Dictionary = {
			"name": child.name,
			"type": child.get_class(),
			"children": _get_node_tree(child, max_depth, current_depth + 1)
		}
		result.append(child_info)

	return result

static func _get_godot_version() -> Dictionary:
	return {
		"version": Engine.get_version_info()["string"],
		"major": Engine.get_version_info()["major"],
		"minor": Engine.get_version_info()["minor"],
		"patch": Engine.get_version_info()["patch"]
	}

# ============================================================================
# 编辑器/外部文件变更 → 结果缓存 dependency revision
# ============================================================================

## Subscribe once to every path-bearing Godot 4.7 editor signal that can explain
## a changed file. Generic filesystem_changed events are paired with a recursive
## path-set diff; all signals are coalesced into one deferred batch per frame.
func _connect_cache_change_signals() -> void:
	if not _native_server or not _editor_interface:
		return
	_cache_change_tracker = CACHE_CHANGE_TRACKER_SCRIPT.new()
	_editor_filesystem = _editor_interface.get_resource_filesystem()
	if _editor_filesystem:
		_cache_change_tracker.seed_paths(_snapshot_editor_filesystem_paths())
		_connect_cache_signal(_editor_filesystem, &"filesystem_changed",
			Callable(self, "_on_cache_filesystem_changed"))
		_connect_cache_signal(_editor_filesystem, &"resources_reload",
			Callable(self, "_on_cache_resources_reload"))
		_connect_cache_signal(_editor_filesystem, &"resources_reimporting",
			Callable(self, "_on_cache_resources_reimporting"))
		_connect_cache_signal(_editor_filesystem, &"resources_reimported",
			Callable(self, "_on_cache_resources_reimported"))
		_connect_cache_signal(_editor_filesystem, &"script_classes_updated",
			Callable(self, "_on_cache_script_classes_updated"))
		_connect_cache_signal(_editor_filesystem, &"sources_changed",
			Callable(self, "_on_cache_sources_changed"))
	_connect_cache_signal(self, &"resource_saved", Callable(self, "_on_cache_resource_saved"))
	_connect_cache_signal(self, &"scene_saved", Callable(self, "_on_cache_scene_saved"))
	_connect_cache_signal(ProjectSettings, &"settings_changed",
		Callable(self, "_on_cache_project_settings_changed"))


func _disconnect_cache_change_signals() -> void:
	if _editor_filesystem:
		_disconnect_cache_signal(_editor_filesystem, &"filesystem_changed",
			Callable(self, "_on_cache_filesystem_changed"))
		_disconnect_cache_signal(_editor_filesystem, &"resources_reload",
			Callable(self, "_on_cache_resources_reload"))
		_disconnect_cache_signal(_editor_filesystem, &"resources_reimporting",
			Callable(self, "_on_cache_resources_reimporting"))
		_disconnect_cache_signal(_editor_filesystem, &"resources_reimported",
			Callable(self, "_on_cache_resources_reimported"))
		_disconnect_cache_signal(_editor_filesystem, &"script_classes_updated",
			Callable(self, "_on_cache_script_classes_updated"))
		_disconnect_cache_signal(_editor_filesystem, &"sources_changed",
			Callable(self, "_on_cache_sources_changed"))
	_disconnect_cache_signal(self, &"resource_saved", Callable(self, "_on_cache_resource_saved"))
	_disconnect_cache_signal(self, &"scene_saved", Callable(self, "_on_cache_scene_saved"))
	_disconnect_cache_signal(ProjectSettings, &"settings_changed",
		Callable(self, "_on_cache_project_settings_changed"))
	_cache_change_flush_pending = false
	_cache_filesystem_snapshot_pending = false
	_cache_change_tracker = null
	_editor_filesystem = null


func _connect_cache_signal(source: Object, signal_name: StringName, callback: Callable) -> void:
	if source and source.has_signal(signal_name) and not source.is_connected(signal_name, callback):
		source.connect(signal_name, callback)


func _disconnect_cache_signal(source: Object, signal_name: StringName, callback: Callable) -> void:
	if source and source.has_signal(signal_name) and source.is_connected(signal_name, callback):
		source.disconnect(signal_name, callback)


func _on_cache_filesystem_changed() -> void:
	if not _cache_change_tracker:
		return
	# Several EditorFileSystem signals can arrive in one process frame. Defer the
	# recursive path snapshot so even a burst walks the editor tree only once.
	_cache_filesystem_snapshot_pending = true
	_schedule_cache_change_flush()


func _on_cache_resources_reload(resources: PackedStringArray) -> void:
	if _cache_change_tracker:
		_cache_change_tracker.queue_paths(resources)
		_schedule_cache_change_flush()


func _on_cache_resources_reimporting(resources: PackedStringArray) -> void:
	if _cache_change_tracker:
		_cache_change_tracker.queue_paths(resources, true)
		_schedule_cache_change_flush()


func _on_cache_resources_reimported(resources: PackedStringArray) -> void:
	if _cache_change_tracker:
		_cache_change_tracker.queue_paths(resources, true)
		_schedule_cache_change_flush()


func _on_cache_script_classes_updated() -> void:
	if _cache_change_tracker:
		_cache_change_tracker.queue_script_classes_updated()
		_schedule_cache_change_flush()


func _on_cache_sources_changed(_exist: bool) -> void:
	if _cache_change_tracker:
		_cache_change_tracker.queue_sources_changed()
		_schedule_cache_change_flush()


func _on_cache_resource_saved(resource: Resource) -> void:
	if not _cache_change_tracker:
		return
	var path: String = resource.resource_path if resource else ""
	if not path.is_empty():
		_cache_change_tracker.queue_paths(PackedStringArray([path]))
		_schedule_cache_change_flush()


func _on_cache_scene_saved(filepath: String) -> void:
	if _cache_change_tracker and not filepath.is_empty():
		_cache_change_tracker.queue_paths(PackedStringArray([filepath]))
		_schedule_cache_change_flush()


func _on_cache_project_settings_changed() -> void:
	if _cache_change_tracker:
		_cache_change_tracker.queue_project_settings_changed()
		_schedule_cache_change_flush()


func _schedule_cache_change_flush() -> void:
	if _cache_change_flush_pending:
		return
	_cache_change_flush_pending = true
	call_deferred("_flush_cache_change_events")


func _flush_cache_change_events() -> void:
	_cache_change_flush_pending = false
	if not _cache_change_tracker or not _native_server:
		return
	if _cache_filesystem_snapshot_pending:
		_cache_filesystem_snapshot_pending = false
		_cache_change_tracker.queue_filesystem_snapshot(_snapshot_editor_filesystem_paths())
	var batch: Dictionary = _cache_change_tracker.flush()
	if not bool(batch.get("has_changes", false)):
		return
	var changed_paths: PackedStringArray = batch.get("paths", PackedStringArray())
	var tags: Array[String] = _native_server.notify_external_changes(batch)
	_log_debug("Coalesced editor cache invalidation: %d paths, %d tags%s" % [
		changed_paths.size(),
		tags.size(),
		" (fallback)" if bool(batch.get("filesystem_fallback", false)) else ""
	])


func _snapshot_editor_filesystem_paths() -> PackedStringArray:
	var paths: PackedStringArray = PackedStringArray()
	if _editor_filesystem:
		_collect_editor_filesystem_paths(_editor_filesystem.get_filesystem(), paths)
	# project.godot is not an imported resource but is cache-relevant and can be
	# changed outside the editor.
	if FileAccess.file_exists("res://project.godot"):
		paths.append("res://project.godot")
	paths.sort()
	return paths


static func _collect_editor_filesystem_paths(directory: EditorFileSystemDirectory,
		paths: PackedStringArray) -> void:
	if not directory:
		return
	for file_index in range(directory.get_file_count()):
		paths.append(directory.get_file_path(file_index))
	for directory_index in range(directory.get_subdir_count()):
		_collect_editor_filesystem_paths(directory.get_subdir(directory_index), paths)

# ============================================================================
# UI面板创建
# ============================================================================

func _create_main_screen_panel() -> void:
	_log_info("Creating main screen panel...")
	
	var panel_scene: PackedScene = load("res://addons/godot_mcp/ui/mcp_panel_native.tscn")
	if not panel_scene:
		_log_error("Failed to load MCP panel scene")
		return
	
	_main_panel = panel_scene.instantiate()
	if not _main_panel:
		_log_error("Failed to instantiate MCP panel")
		return
	
	EditorInterface.get_editor_main_screen().add_child(_main_panel)
	_make_visible(false)
	
	if _main_panel.has_method("set_plugin"):
		_main_panel.set_plugin(self)
		_log_info("Plugin reference set to panel")
	
	if _native_server and _main_panel.has_method("set_server_core"):
		_main_panel.set_server_core(_native_server)
		_log_info("Server core reference set to panel")
	
	_log_info("Main screen panel created successfully")

# ============================================================================
# 信号回调
# ============================================================================

func _on_server_started() -> void:
	_log_info("MCP Server started")
	if _main_panel and _main_panel.has_method("refresh"):
		if Thread.is_main_thread():
			_main_panel.refresh()
		else:
			_main_panel.call_deferred("refresh")

func _on_server_stopped() -> void:
	_log_info("MCP Server stopped")
	if _main_panel and _main_panel.has_method("refresh"):
		if Thread.is_main_thread():
			_main_panel.refresh()
		else:
			_main_panel.call_deferred("refresh")

func _on_message_received(message: Dictionary) -> void:
	_log_debug("Message received: " + JSON.stringify(message))
	if _main_panel and _main_panel.has_method("update_log"):
		_main_panel.update_log("[RECV] " + JSON.stringify(message))

func _on_response_sent(response: Dictionary) -> void:
	_log_debug("Response sent: " + JSON.stringify(response))
	if _main_panel and _main_panel.has_method("update_log"):
		_main_panel.update_log("[SENT] " + JSON.stringify(response))

func _on_tool_started(tool_name: String, params: Dictionary) -> void:
	_log_info("Tool started: " + tool_name)

func _on_tool_completed(tool_name: String, result: Dictionary) -> void:
	_log_info("Tool completed: " + tool_name)

func _on_tool_failed(tool_name: String, error: String) -> void:
	_log_error("Tool failed: " + tool_name + " - " + error)

func _on_log_message(level: String, message: String) -> void:
	if _main_panel and _main_panel.has_method("update_log"):
		_main_panel.update_log("[" + level + "] " + message)

# ============================================================================
# 日志方法（根据godot-dev-guide优化）
# ============================================================================

func _log_error(message: String) -> void:
	if log_level >= 0 and _native_server:
		_native_server._log_error(message)

func _log_warn(message: String) -> void:
	if log_level >= 1 and _native_server:
		_native_server._log_warn(message)

func _log_info(message: String) -> void:
	if log_level >= 2 and _native_server:
		_native_server._log_info(message)

func _log_debug(message: String) -> void:
	if log_level >= 3 and _native_server:
		_native_server._log_debug(message)

# ============================================================================
# 清理
# ============================================================================

func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		if _native_server and _native_server.is_running():
			_native_server.stop()
		_native_server = null
