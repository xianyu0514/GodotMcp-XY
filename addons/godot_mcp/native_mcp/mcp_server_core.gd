# mcp_server_core.gd - MCP服务器核心实现
# 整合传输层、协议处理、工具注册、资源管理
# 根据godot-dev-guide添加完整的类型提示
# 根据mcp-builder添加outputSchema和annotations支持

class_name MCPServerCore
extends RefCounted

# ============================================================================
# 传输类型枚举
# ============================================================================

enum TransportType {
	TRANSPORT_STDIO,    # stdio 传输（默认）
	TRANSPORT_HTTP      # HTTP 传输
}

# ============================================================================
# 信号定义（使用信号解耦通信 - 根据godot-dev-guide）
# ============================================================================

signal server_started
signal server_stopped
signal message_received(message: Dictionary)
signal response_sent(response: Dictionary)
signal tool_execution_started(tool_name: String, params: Dictionary)
signal tool_execution_completed(tool_name: String, result: Dictionary)
signal tool_execution_failed(tool_name: String, error: String)
signal resource_requested(resource_uri: String, params: Dictionary)
signal resource_loaded(resource_uri: String, content: Dictionary)
signal log_message(level: String, message: String)

# ============================================================================
# 常量
# ============================================================================

const JSONRPC_VERSION: String = "2.0"
const PROTOCOL_VERSION: String = "2025-11-25"
const CACHE_REVISION_INDEX_SCRIPT = preload("res://addons/godot_mcp/native_mcp/cache_revision_index.gd")
const TOKEN_ESTIMATOR_SCRIPT = preload("res://addons/godot_mcp/utils/token_estimator.gd")

## Guidance returned in the MCP `initialize` result. Compatible clients inject this
## into the model's system context automatically, so the lazy-loading workflow is
## delivered on connect without the user pasting any rules.
const SERVER_INSTRUCTIONS: String = "Godot MCP starts with ~30 core tools plus four always-on meta tools so tools/list stays small. Most editing tasks work with the default set. For a multi-step goal or any missing capability, call enable_tools once with workflow_query='<English or Chinese goal>', then use the refreshed tools/list schemas. This fastest path routes locally across inspect/execute/verify, activates at most 8 schema-free names, and atomically replaces supplementary tools left by the previous task; set replace_supplementary=false only to extend the current task. Exact atomic tool names route to that tool alone. Every non-meta atomic tool is routable, so do not give up and do not load the full 221-tool catalog. Use search_tools only to preview/compare candidates, get_tool_details only when a client cannot refresh, and list_tool_catalog summary_only=true only to browse group counts and workflow coverage. Prefer focused presets (game_2d, game_3d, ui_localization, gameplay_scripting, animation_audio, release_export, level_design, debugging, automation_qa, art_resources, minimal_core); 'all' has the highest context cost. Reuse catalog_revision with known_revision to avoid downloading an unchanged catalog."

## Maximum number of pending requests buffered in the serial request queue.
## When multiple AI clients call concurrently, requests are queued and executed
## one at a time so the editor is not overloaded. Requests beyond this bound are
## rejected with a "server busy" error instead of growing memory without limit.
const MAX_REQUEST_QUEUE_SIZE: int = 256

## Maximum time (in seconds) an incoming request waits for a free queue slot
## before the server gives up and rejects it. When the queue is momentarily full,
## concurrent AI clients wait their turn instead of failing immediately; the
## bound prevents a request from hanging forever if the server stalls or stops.
const MAX_QUEUE_WAIT_SECONDS: float = 30.0

## Maximum number of requests that may simultaneously wait for a free queue slot.
## The serial queue is capped at MAX_REQUEST_QUEUE_SIZE, but each waiting request
## is a live coroutine holding its message/context; this second bound caps that
## coroutine overhead under sustained backpressure. When exceeded, the newest
## request is rejected immediately instead of adding yet another waiter.
const MAX_WAITING_REQUESTS: int = 256

## Read-only tools whose (potentially expensive) results are cached and served
## directly on a repeat call while their dependency revisions remain current. Keys
## are deterministic: tool name + canonical (key-sorted) JSON of the arguments,
## so identical calls share one cache entry regardless of argument insertion
## order. Limited to deterministic scene/project scans and path-scoped script or
## resource reads. MCP mutations advance only related revisions; the TTL bounds
## staleness from any out-of-band edit made outside the MCP server.
const CACHEABLE_READ_TOOLS: Array[String] = CACHE_REVISION_INDEX_SCRIPT.CACHEABLE_READ_TOOLS

## Discovery results depend on the registered tool catalog and enabled states,
## but project/scene reads do not. Catalog-only changes evict just these entries
## so toggling tools keeps expensive project read results hot.
const TOOL_DISCOVERY_CACHE_TOOLS: Array[String] = [
	"list_tool_catalog", "search_tools", "get_tool_details"
]

## Control-plane mutations change which tool schemas are visible, not project
## data. Their handlers perform targeted discovery-cache invalidation, so the
## generic post-call mutation path must preserve unrelated read entries.
const CACHE_PRESERVING_MUTATION_TOOLS: Array[String] = ["enable_tools"]

## Maximum number of tool results kept in the in-memory LRU result cache. When
## the cache would exceed this many entries, the least recently used entry is
## evicted.
const RESULT_CACHE_MAX: int = 64

## Full scan snapshots are shared by every limit/offset view of the same query.
## They live in the existing revision-aware LRU but have tighter count/size
## gates so improved cross-page hit rate cannot create unbounded memory use.
const READ_SNAPSHOT_CACHE_MAX: int = 8
const READ_SNAPSHOT_MAX_BYTES: int = 4 * 1024 * 1024

## TTL (ms) for cached tool results. Invalidation is primarily revision-driven
## (project mutations advance dependency tags; catalog mutations are targeted);
## this TTL is only a bounded-staleness
## backstop for out-of-band edits made outside the MCP server — deliberately
## much shorter than the old 5-minute scene-structure TTL.
const RESULT_CACHE_TTL_MS: int = 60000

## Results whose JSON serialization exceeds this many UTF-8 bytes are spilled to
## disk (res://.mcp/out/) and returned to the client as a truncated head/tail
## preview plus a resume hint, instead of being inlined into the response.
const MAX_INLINE_RESULT_BYTES: int = 50000

## Preview sizes (characters) returned inline for spilled results: the head and
## tail of the payload so the model can judge the content before reading the
## spill file for the full result.
const SPILL_PREVIEW_HEAD_CHARS: int = 4096
const SPILL_PREVIEW_TAIL_CHARS: int = 1024

## Directory (res:// path) where spilled large results are written.
const SPILL_OUTPUT_DIR: String = "res://.mcp/out"

## Standard MCP resource URI used to retrieve every byte of a spilled result.
## The content-addressed handle is a SHA-256 digest, so the URI is deterministic
## and cannot be used to escape SPILL_OUTPUT_DIR.
const RESULT_RESOURCE_URI_PREFIX: String = "godot-mcp://result/"
const RESULT_RESOURCE_HANDLE_LENGTH: int = 64

## Maximum raw UTF-8 bytes returned by one resources/read call. Pages are cut
## only on code-point boundaries; clients concatenate their text in URI order.
const RESULT_RESOURCE_PAGE_BYTES: int = 16384

## Tools whose results are never spilled: file-content/log readers where the
## spill file would merely duplicate the same text and re-reading it through the
## tool could ping-pong. These keep returning their content inline.
const SPILL_EXEMPT_TOOLS: Array[String] = ["read_script", "batch_read_scripts", "get_editor_logs"]

## TTL (ms) advertised in the `_meta` of list responses. The 2026-07-28 MCP spec
## adds `_meta.ttlMs`/`cacheScope` for list caching; Claude Code validates these
## fields and rejects list results that omit them.
const LIST_CACHE_TTL_MS: int = 30000
const TOOLS_LIST_CACHE_SCOPE: String = "toolSet"
const RESOURCES_LIST_CACHE_SCOPE: String = "resourceList"
const PROMPTS_LIST_CACHE_SCOPE: String = "promptList"

## Path to the plugin manifest whose `plugin/version` key is the single source
## of truth for the version reported in the `initialize` handshake.
const PLUGIN_CONFIG_PATH: String = "res://addons/godot_mcp/plugin.cfg"

# ============================================================================
# 状态变量（使用完整类型提示 - 根据godot-dev-guide）
# ============================================================================

var _active: bool = false

# 传输方式相关变量（新增 - 支持多种传输方式）
var _transport_type: TransportType = TransportType.TRANSPORT_STDIO
var _transport: McpTransportBase = null  # 传输层实例（使用基类类型）
var _auth_manager: McpAuthManager = null  # 认证管理器（HTTP 模式使用）
var _http_port: int = 9080  # HTTP 监听端口

# Serial request queue. Each element is {"message": Dictionary, "context": Variant}.
# When multiple AI clients call concurrently, requests are queued here and run one
# at a time by _drain_request_queue(), so many coroutines never execute at once and
# the editor stays responsive instead of spiking CPU/memory.
var _request_queue: Array[Dictionary] = []
var _is_processing_request: bool = false

# FIFO admission gate for requests that arrive while the queue is full. Each waiter
# appends a unique, monotonically increasing id; only the waiter at the front of
# _admission_waiters may enter the queue, so backpressured requests are admitted in
# arrival order rather than in nondeterministic coroutine-resume order.
var _admission_waiters: Array[int] = []
var _admission_waiter_seq: int = 0

# 工具和资源注册表
var _tools: Dictionary = {}  # String -> MCPTool
var _resources: Dictionary = {}  # String -> MCPResource
var _prompts: Dictionary = {}  # String -> MCPPrompt
var _resource_subscriptions: Dictionary = {}  # String (uri) -> true; active resource subscriptions
var _tool_list_dirty: bool = false  # 工具列表变更标记
# tools/list 服务端缓存：启用工具按名字排序后的 MCPTool.to_dict() 数组。
# 列表只在注册/注销/启用状态变化时重建；重复请求直接复用，避免每轮重建
# 30+ 个 schema Dictionary 并保证确定性排序（利于客户端 prompt cache）。
var _tool_list_cache: Array[Dictionary] = []
var _tool_list_cache_valid: bool = false
var _tool_catalog_revision: int = 0
# Definition-only revision for immutable routing/search indices. Unlike the
# catalog revision, visibility changes do not advance this value.
var _tool_registry_revision: int = 0
# Approximate tools/list token costs are computed once with the same canonical
# DSH-inspired estimator used by the schema budget gate. They guide relative
# route optimization only; they are never billing or protocol behavior.
var _tool_schema_token_costs: Dictionary = {}

var _classifier = null  # MCPToolClassifier (lazy-loaded for GUT CLI compat)
var _state_manager = null  # MCPToolStateManager (lazy-loaded for GUT CLI compat)

# 配置
var _log_level: int = MCPTypes.LogLevel.INFO
var _security_level: int = MCPTypes.SecurityLevel.STRICT
var _rate_limit: int = 1000  # Max requests per 60s window before throttling

## Version reported in the `initialize` handshake (`serverInfo.version`). The
## single source of truth is `plugin.cfg` (`plugin/version`), loaded by
## `_load_plugin_version()` in `start()`; defaults to "0.0.0" before that.
var _server_version: String = "0.0.0"

# 速率限制跟踪
var _request_count: Dictionary = {}  # String (client_id) -> int
var _request_timestamps: Dictionary = {}  # String (client_id) -> Array[int]

# 结果缓存（LRU + 依赖域 revision 懒失效）
# _result_cache: key -> {"value", "last_access", "revision_snapshot"}
var _result_cache: Dictionary = {}
# LRU 最近使用列表：下标 0 = 最常使用，与 _result_cache 的 key 一一对应
var _result_cache_order: Array[String] = []
# 单飞标记：正在执行的 key -> revision snapshot（同一 key 并发时合并执行）
var _cache_inflight: Dictionary = {}
# 缓存状态变更计数（兼容诊断/测试）；正确性由依赖 revision snapshot 保证。
var _cache_generation: int = 0
# Project/editor dependency revision index. Mutations advance a few tags in O(1)
# instead of scanning and clearing the full result cache.
var _cache_revision_index = CACHE_REVISION_INDEX_SCRIPT.new()

## Requests the client asked to cancel via `notifications/cancelled`
## (request id -> true). Long-running tools poll `is_request_cancelled()` /
## `is_current_tool_cancelled()` while they run and abort early when set.
var _cancelled_requests: Dictionary = {}

## Execution context of the currently running tool call (main thread only, the
## serial queue guarantees a single in-flight call): {"tool_name", "request_id",
## "progress_token"}. Set right before a tool callable runs and cleared after,
## so tools can correlate progress notifications and cancellation with the
## request that started them without the request id in their signature.
var _execution_context: Dictionary = {}

# JSONRPC实例（如需使用Godot内置JSONRPC处理，可取消注释）
# var _jsonrpc: JSONRPC = JSONRPC.new()

# ============================================================================
# 传输层接口方法（新增 - 支持多种传输方式）
# ============================================================================

## 设置传输方式（必须在服务器启动前调用）
## @param type: TransportType - 传输类型枚举
func set_transport_type(type: TransportType) -> void:
	if _active:
		_log_error("Cannot change transport type while server is running")
		return
	_transport_type = type
	_log_info("Transport type set to: " + str(_transport_type))

## 设置认证管理器（HTTP 模式使用）
## @param manager: McpAuthManager - 认证管理器实例
func set_auth_manager(manager: McpAuthManager) -> void:
	_auth_manager = manager
	_log_info("Auth manager set")

## 设置 HTTP 端口（HTTP 模式使用，必须在服务器启动前调用）
## @param port: int - 监听端口号
func set_http_port(port: int) -> void:
	if _transport and _transport.has_method("set_port"):
		_transport.set_port(port)
	_http_port = port
	_log_info("HTTP port set to: " + str(port))

func set_sse_enabled(enabled: bool) -> void:
	if _transport and _transport.has_method("set_sse_enabled"):
		_transport.set_sse_enabled(enabled)
	_log_info("SSE enabled: " + str(enabled))

func set_remote_config(allow_remote: bool, cors_origin: String) -> void:
	if _transport and _transport.has_method("set_remote_config"):
		_transport.set_remote_config(allow_remote, cors_origin)
	_log_info("Remote config - allow: " + str(allow_remote) + ", CORS: " + cors_origin)

## 初始化传输层（根据 _transport_type 创建对应实例）
## @returns: bool - 初始化成功返回 true，失败返回 false
func _init_transport() -> bool:
	match _transport_type:
		TransportType.TRANSPORT_STDIO:
			_transport = McpStdioServer.new()
			if _transport.has_method("set_log_callback"):
				_transport.set_log_callback(_log_transport_message)
			_log_info("Initialized stdio transport")
		
		TransportType.TRANSPORT_HTTP:
			_transport = McpHttpServer.new()
			_transport.set_port(_http_port)
			if _auth_manager:
				_transport.set_auth_manager(_auth_manager)
			if _transport.has_method("set_log_callback"):
				_transport.set_log_callback(_log_transport_message)
			_log_info("Initialized HTTP transport on port " + str(_http_port))
		
		_:
			_log_error("Unknown transport type: " + str(_transport_type))
			return false
	
	# 连接信号（使用 lambda 启动协程，支持异步工具执行）
	_transport.message_received.connect(func(message: Dictionary, context: Variant):
		_on_transport_message_received(message, context)
	)
	_transport.server_error.connect(_on_transport_error)
	_transport.server_started.connect(_on_transport_started)
	_transport.server_stopped.connect(_on_transport_stopped)
	
	_log_info("Transport layer initialized: " + str(_transport_type))
	return true

## 处理来自传输层的消息（异步协程，支持工具 await）
## @param message: Dictionary - JSON-RPC 消息
## @param context: Variant - 传输上下文（stdio: null, HTTP: StreamPeerTCP）
func _on_transport_message_received(message: Dictionary, context: Variant) -> void:
	# 验证消息格式
	if not message.has("jsonrpc"):
		_send_error(null, MCPTypes.ERROR_INVALID_REQUEST, 
				   "Missing 'jsonrpc' field. Please ensure the message is a valid JSON-RPC 2.0 message.", null, context)
		return
	
	if message["jsonrpc"] != JSONRPC_VERSION:
		_send_error(message.get("id"), MCPTypes.ERROR_INVALID_REQUEST, 
				   "Invalid JSON-RPC version. Expected '2.0', got: " + str(message["jsonrpc"]), null, context)
		return
	
	# 记录收到的消息
	message_received.emit(message)
	if _debug_enabled():
		_log_debug("Received message: " + JSON.stringify(message))
	
	# Only requests/notifications (carrying "method") are processed; ignore responses.
	if not message.has("method"):
		_log_warn("Received unexpected response message: " + JSON.stringify(message))
		return
	
	# Cancellation must be observed by an in-flight tool call, so it bypasses the
	# serial queue and marks the request immediately instead of waiting behind the
	# long-running call it cancels. All state touched here lives on the main
	# thread (transport marshals via call_deferred), so this is safe.
	if String(message.get("method", "")) == MCPTypes.METHOD_NOTIFICATIONS_CANCELLED:
		_handle_cancelled_notification(message)
		return
	
	# Backpressure: when the queue is full (or other requests are already waiting),
	# wait for a slot through a FIFO admission gate instead of rejecting immediately,
	# so concurrent AI clients are served in arrival order. Only reject if no slot
	# opens within MAX_QUEUE_WAIT_SECONDS, the server stops, or there are already too
	# many waiters — keeping both memory and live coroutines bounded.
	if _request_queue.size() >= MAX_REQUEST_QUEUE_SIZE or not _admission_waiters.is_empty():
		if _admission_waiters.size() >= MAX_WAITING_REQUESTS:
			_log_warn("Too many requests waiting (" + str(_admission_waiters.size()) + "), rejecting request")
			_send_error(message.get("id"), MCPTypes.ERROR_INTERNAL_ERROR, 
					   "Server busy: too many requests waiting. Please retry later.", null, context)
			return
		var slot_free: bool = await _await_queue_slot()
		if not slot_free:
			_log_warn("Request queue full after waiting " + str(MAX_QUEUE_WAIT_SECONDS) + "s, rejecting request")
			_send_error(message.get("id"), MCPTypes.ERROR_INTERNAL_ERROR, 
					   "Server busy: request queue is full. Please retry later.", null, context)
			return
	
	# Enqueue and kick the serial processor (concurrent calls queue up and run in order).
	_request_queue.append({"message": message, "context": context})
	_drain_request_queue()

## Wait in a FIFO line until this request may enter the queue. The caller takes a
## ticket at the back of _admission_waiters and is admitted only when it reaches the
## front AND a slot is free, preserving arrival order across concurrent waiters.
## Returns true if admitted, false if it timed out or the server stopped (caller
## then rejects). The ticket is always removed on exit so a timed-out waiter never
## blocks the requests behind it.
func _await_queue_slot() -> bool:
	var ticket: int = _admission_waiter_seq
	_admission_waiter_seq += 1
	_admission_waiters.append(ticket)

	var main_loop: SceneTree = Engine.get_main_loop() as SceneTree
	var deadline_ms: float = Time.get_ticks_msec() + MAX_QUEUE_WAIT_SECONDS * 1000.0
	var admitted: bool = false
	while _active:
		# Only the front-of-line ticket may take a free slot (FIFO admission).
		if _admission_waiters[0] == ticket and _request_queue.size() < MAX_REQUEST_QUEUE_SIZE:
			admitted = true
			break
		if Time.get_ticks_msec() >= deadline_ms or main_loop == null:
			break
		await main_loop.process_frame

	_admission_waiters.erase(ticket)
	return admitted and _active

## Process the request queue serially: run exactly one request at a time until empty.
## All access happens on the main thread (transport marshals via call_deferred), so no
## mutex is needed; _is_processing_request guarantees only one drain coroutine runs.
func _drain_request_queue() -> void:
	if _is_processing_request:
		return
	_is_processing_request = true
	
	var main_loop: SceneTree = Engine.get_main_loop() as SceneTree
	while _active and not _request_queue.is_empty():
		var item: Dictionary = _request_queue.pop_front()
		var message: Dictionary = item.get("message", {})
		var context: Variant = item.get("context", null)
		
		var response: Dictionary = await _handle_request(message)
		
		# Notifications produce an empty dict (falsy); only send real responses.
		if response:
			_send_response(response, context)
		
		# Yield a frame before the next request so the editor can render and handle
		# input between back-to-back tool calls, keeping it responsive under sustained
		# load. Skip the yield when this was the last request (nothing left to drain).
		if main_loop != null and not _request_queue.is_empty():
			await main_loop.process_frame
	
	_is_processing_request = false

## Number of requests currently waiting in the queue (for tests and monitoring).
func get_request_queue_depth() -> int:
	return _request_queue.size()

## 处理传输层错误
## @param error: String - 错误描述
func _on_transport_error(error: String) -> void:
	_log_error("Transport error: " + error)

## 处理传输层启动
func _on_transport_started() -> void:
	_log_info("Transport layer started")
	server_started.emit()

## 处理传输层停止
func _on_transport_stopped() -> void:
	_log_info("Transport layer stopped")
	server_stopped.emit()


# ============================================================================
# 生命周期方法
# ============================================================================

## 覆盖服务器版本（优先于 plugin.cfg 自动读取的值）。
## @param version: String - 版本号
func set_server_version(version: String) -> void:
	_server_version = version
	_log_info("Server version set to: " + version)

## 从 plugin.cfg 的 `plugin/version` 键读取插件版本，作为 serverInfo.version
## 的唯一来源。读取失败或键缺失时保持当前 _server_version（默认 "0.0.0"）。
func _load_plugin_version() -> void:
	var config: ConfigFile = ConfigFile.new()
	var err: Error = config.load(PLUGIN_CONFIG_PATH)
	if err != OK:
		_log_warn("Failed to load plugin config for server version: " + str(err))
		return
	var version: String = config.get_value("plugin", "version", "")
	if version.is_empty():
		_log_warn("plugin.cfg has no plugin/version key; keeping server version: " + _server_version)
		return
	_server_version = version
	_log_info("Server version loaded from plugin.cfg: " + version)

func start() -> bool:
	if _active:
		_log_warn("Server already running")
		return false
	
	_log_info("Starting MCP Server (transport: " + str(_transport_type) + ")...")
	
	# 初始化传输层
	if not _init_transport():
		_log_error("Failed to initialize transport layer")
		return false
	
	# 启动传输层
	var success: bool = _transport.start()
	
	if not success:
		_log_error("Failed to start transport layer")
		return false
	
	if _classifier == null:
		_classifier = load("res://addons/godot_mcp/native_mcp/mcp_tool_classifier.gd").new()
		_log_info("Tool classifier initialized")
	
	if _state_manager == null:
		_state_manager = load("res://addons/godot_mcp/native_mcp/tool_state_manager.gd").new()
		_log_info("Tool state manager initialized")
		var saved_states: Dictionary = _state_manager.load_state()
		if not saved_states.is_empty():
			_state_manager.apply_states_to_server(self, saved_states)
			_log_info("Applied saved tool states: " + str(saved_states.size()) + " tools")

	# 读取插件版本（plugin.cfg），使 initialize 握手报告与编辑器插件一致的版本。
	_load_plugin_version()

	_active = true
	_log_info("MCP Server started successfully (transport: " + str(_transport_type) + ")")
	
	return true

func stop() -> void:
	if not _active:
		return

	_log_info("Stopping MCP Server...")

	# Flush buffered tool logs before shutdown
	flush_tool_log()

	# 停止传输层
	if _transport:
		_transport.stop()
		_transport = null

	_active = false

	# Drop any queued-but-unprocessed requests (the drain loop exits on _active == false).
	_request_queue.clear()
	_is_processing_request = false
	# Waiting admission coroutines observe _active == false and exit on their next frame;
	# clear the line so a restarted server starts with no stale waiters.
	_admission_waiters.clear()
	# Resource subscriptions are per-session; drop them so a restarted server does
	# not emit resources/updated for resources the new client never subscribed to.
	_resource_subscriptions.clear()
	# Drop cancellation markers and the execution context so a restarted server
	# never carries stale cancellation state from the previous session.
	_cancelled_requests.clear()
	_execution_context = {}

	_log_info("MCP Server stopped")

func is_running() -> bool:
	if _transport:
		return _transport.is_running()
	return false

# ============================================================================
# 请求处理（根据mcp-builder优化）
# ============================================================================

func _handle_request(message: Dictionary) -> Dictionary:
	var method: String = message.get("method", "")
	var id: Variant = message.get("id", null)
	var params: Dictionary = message.get("params", {})
	
	# JSON-RPC 2.0: 通知（无 "id" 的消息）绝不产生响应。匹配已知通知方法处理
	# （如 notifications/initialized），未知通知也静默返回空字典 —— 空字典为假值，
	# _drain_request_queue 中的 `if response:` 判定为 false，因此永远不会发送响应。
	var is_notification: bool = not message.has("id")
	if is_notification:
		match method:
			MCPTypes.METHOD_NOTIFICATIONS_INITIALIZED:
				return _handle_initialized_notification(message)
			MCPTypes.METHOD_NOTIFICATIONS_CANCELLED:
				return _handle_cancelled_notification(message)
		# 未知通知：忽略，不发送任何响应
		_log_warn("Unknown notification ignored: " + method)
		return {}
	
	# 速率限制仅对请求（带 id）生效：通知不计数，也不因限流返回错误响应。
	if not _check_rate_limit("default"):
		return MCPTypes.create_error_response(id, MCPTypes.ERROR_INTERNAL_ERROR, "Rate limit exceeded")
	
	match method:
		MCPTypes.METHOD_INITIALIZE:
			return _handle_initialize(message)
		
		MCPTypes.METHOD_PING:
			# MCP 规范：ping 请求返回空 result
			return MCPTypes.create_response(id, {})
		
		MCPTypes.METHOD_TOOLS_LIST:
			return _handle_tools_list(message)
		
		MCPTypes.METHOD_TOOLS_CALL:
			return await _handle_tool_call(message)
		
		MCPTypes.METHOD_RESOURCES_LIST:
			return _handle_resources_list(message)
		
		MCPTypes.METHOD_RESOURCES_READ:
			return await _handle_resource_read(message)
		
		MCPTypes.METHOD_RESOURCES_SUBSCRIBE:
			return _handle_resource_subscribe(message)
		
		MCPTypes.METHOD_RESOURCES_UNSUBSCRIBE:
			return _handle_resource_unsubscribe(message)
		
		MCPTypes.METHOD_PROMPTS_LIST:
			return _handle_prompts_list(message)
		
		MCPTypes.METHOD_PROMPTS_GET:
			return await _handle_prompt_get(message)
		
		_:
			_log_warn("Method not found: " + method)
			return MCPTypes.create_error_response(id, MCPTypes.ERROR_METHOD_NOT_FOUND, "Method not found: " + method)

# ============================================================================
# MCP协议方法实现（完整版 - 根据mcp-builder）
# ============================================================================

func _handle_initialize(message: Dictionary) -> Dictionary:
	var id: Variant = message.get("id")
	var params: Dictionary = message.get("params", {})
	var client_capabilities: Dictionary = params.get("capabilities", {})
	var client_protocol_version: String = params.get("protocolVersion", PROTOCOL_VERSION)
	
	_log_info("Initialize request from client. Protocol: " + client_protocol_version)
	if _debug_enabled():
		_log_debug("Client capabilities: " + JSON.stringify(client_capabilities))
	
	var negotiated_version: String = _negotiate_protocol_version(client_protocol_version)
	
	# serverInfo.version 单一来源：start() 已从 plugin.cfg 读取；为空时回退 "0.0.0"。
	var server_version: String = "0.0.0" if _server_version.is_empty() else _server_version
	
	var result: Dictionary = {
		"protocolVersion": negotiated_version,
		"capabilities": MCPTypes.create_capabilities(true, true, true, true),
		"serverInfo": {
			"name": "godot-native-mcp",
			"version": server_version
		},
		"instructions": SERVER_INSTRUCTIONS
	}
	
	var response: Dictionary = MCPTypes.create_response(id, result)
	if _debug_enabled():
		_log_debug("Initialize response: " + JSON.stringify(response))
	
	return response

func _negotiate_protocol_version(client_version: String) -> String:
	var supported_versions: PackedStringArray = [
		"2025-11-25",
		"2025-06-18",
		"2025-03-26",
		"2024-11-05",
	]
	
	if client_version in supported_versions:
		return client_version
	
	for version in supported_versions:
		if version == PROTOCOL_VERSION:
			return version
	
	return supported_versions[0]

func _handle_initialized_notification(message: Dictionary) -> Dictionary:
	_log_info("Client initialized notification received")
	# 这是一个通知，不需要返回响应
	return {}

## Handle a `notifications/cancelled` notification: mark the referenced request
## id so the running tool call can observe it via `is_request_cancelled()` /
## `is_current_tool_cancelled()` and abort early. Notifications never produce a
## response, so an empty dict is returned (falsy -> nothing is sent).
func _handle_cancelled_notification(message: Dictionary) -> Dictionary:
	var params: Dictionary = message.get("params", {})
	var request_id: Variant = params.get("requestId", null)
	if request_id != null:
		_cancelled_requests[request_id] = true
		_log_info("Cancellation requested for request: " + str(request_id))
	else:
		_log_warn("Cancellation notification without a requestId; ignored")
	return {}

func _handle_tools_list(message: Dictionary) -> Dictionary:
	var id: Variant = message.get("id")
	
	if not _tool_list_cache_valid:
		_rebuild_tool_list_cache()
	
	var result: Dictionary = {"tools": _tool_list_cache}
	# 2026-07-28 MCP 规范：列表结果需带 _meta（ttlMs/cacheScope），Claude Code 缺失会拒绝。
	result["_meta"] = {
		"ttlMs": LIST_CACHE_TTL_MS,
		"cacheScope": TOOLS_LIST_CACHE_SCOPE
	}
	var response: Dictionary = MCPTypes.create_response(id, result)

	_log_info("Tools list requested. Available tools: " + str(_tool_list_cache.size()) + " (registered: " + str(_tools.size()) + ")")

	if _debug_enabled():
		_log_debug("Tools list response: " + JSON.stringify(response))

	return response

## Rebuild the cached tools/list payload: deterministic alphabetical order and
## reuse of MCPTool.to_dict() output for subsequent requests until invalidated.
func _rebuild_tool_list_cache() -> void:
	var names: Array[String] = []
	for tool_name in _tools:
		names.append(str(tool_name))
	names.sort()
	
	var tools_list: Array[Dictionary] = []
	for tool_name in names:
		var tool: MCPTypes.MCPTool = _tools[tool_name]
		if tool and tool.is_valid() and tool.enabled:
			tools_list.append(tool.to_dict())
	
	_tool_list_cache = tools_list
	_tool_list_cache_valid = true

## Drop the cached tools/list payload. Called whenever a registration,
## unregistration or enable/disable change makes the previous payload stale.
func _invalidate_tool_list_cache() -> void:
	if _tool_list_cache_valid or not _tool_list_cache.is_empty():
		_tool_list_cache_valid = false

func _handle_tool_call(message: Dictionary) -> Dictionary:
	var id: Variant = message.get("id")
	var params: Dictionary = message.get("params", {})
	var tool_name: String = params.get("name", "")
	var arguments: Dictionary = params.get("arguments", {})
	
	_log_info("Tool call: " + tool_name)
	if _debug_enabled():
		_log_debug("Tool arguments: " + JSON.stringify(arguments))
	
	# 检查工具是否存在
	if not _tools.has(tool_name):
		_log_error("Tool not found: " + tool_name)
		var error_result: Dictionary = {
			"content": [{
				"type": "text",
				"text": "Tool not found: " + tool_name
			}],
			"isError": true
		}
		return MCPTypes.create_response(id, error_result)
	
	var tool: MCPTypes.MCPTool = _tools[tool_name]
	
	if not tool.enabled:
		_log_error("Tool is disabled: " + tool_name)
		var error_result: Dictionary = {
			"content": [{
				"type": "text",
				"text": "Tool is disabled: " + tool_name
			}],
			"isError": true
		}
		return MCPTypes.create_response(id, error_result)
	
	# Read-through cache: serve a cached result for expensive read-only queries
	# instead of re-walking the scene tree / rescanning the project. Keys are
	# deterministic (canonical JSON of the arguments). Each entry captures only
	# the project revision tags it depends on; a hit validates those integers in
	# O(tags) without rescanning the cache. Single-flight dedupe: if the same key
	# is already executing, wait
	# a frame and reuse its result instead of running a duplicate (the serial
	# request queue already prevents most overlap; this covers direct concurrent
	# invocations).
	var is_cacheable_read: bool = tool_name in CACHEABLE_READ_TOOLS
	var cache_key: String = ""
	var cache_revision_snapshot_at_start: Dictionary = {}
	if is_cacheable_read:
		cache_key = tool_name + ":" + _canonical_json(arguments)
		var dependency_tags: Array[String] = CACHE_REVISION_INDEX_SCRIPT.read_tags(tool_name, arguments)
		cache_revision_snapshot_at_start = _cache_revision_index.snapshot(dependency_tags)
		var cached_formatted: Variant = _result_cache_get_formatted(cache_key)
		if cached_formatted is Dictionary:
			_log_info("Serving cached result for: " + tool_name)
			return MCPTypes.create_response(id, cached_formatted)
		var cached: Variant = _result_cache_get(cache_key)
		if cached != null:
			_log_info("Serving cached result (legacy entry) for: " + tool_name)
			return MCPTypes.create_response(id, _format_tool_result(cached, tool))
		if _cache_inflight.has(cache_key):
			var inflight_snapshot: Variant = _cache_inflight[cache_key]
			if inflight_snapshot is Dictionary and not _cache_revision_index.is_current(inflight_snapshot):
				_cache_inflight.erase(cache_key)
		if _cache_inflight.has(cache_key):
			var main_loop: SceneTree = Engine.get_main_loop() as SceneTree
			if main_loop:
				await main_loop.process_frame
			var retried_formatted: Variant = _result_cache_get_formatted(cache_key)
			if retried_formatted is Dictionary:
				_log_info("Serving result from in-flight twin for: " + tool_name)
				return MCPTypes.create_response(id, retried_formatted)
			var retried: Variant = _result_cache_get(cache_key)
			if retried != null:
				_log_info("Serving result from in-flight twin for: " + tool_name)
				return MCPTypes.create_response(id, _format_tool_result(retried, tool))
		_cache_inflight[cache_key] = cache_revision_snapshot_at_start
	
	# 发送开始信号
	tool_execution_started.emit(tool_name, arguments)
	
	# Capture the execution context (request id + optional progress token) so a
	# long-running tool can emit notifications/progress and observe
	# notifications/cancelled while it runs. The token is read from the
	# spec-compliant params._meta location first, then from arguments._meta for
	# clients that nest it inside the tool arguments.
	var progress_token: Variant = null
	var meta: Variant = params.get("_meta", null)
	if meta is Dictionary:
		progress_token = (meta as Dictionary).get("progressToken", null)
	if progress_token == null and arguments.has("_meta") and arguments["_meta"] is Dictionary:
		progress_token = (arguments["_meta"] as Dictionary).get("progressToken", null)
	_execution_context = {
		"tool_name": tool_name,
		"request_id": id,
		"progress_token": progress_token
	}
	
	# 执行工具
	var result: Variant = null
	var error: String = ""
	
	if tool.callable.is_valid():
		# 使用Callable调用工具（await 支持异步工具执行）
		result = await tool.callable.call(arguments)
	
	# Tool execution finished: drop this request's cancellation marker (if the
	# client cancelled mid-run) and the execution context so the next request
	# starts clean.
	if _cancelled_requests.has(id):
		_cancelled_requests.erase(id)
	_execution_context = {}
	
	# 处理执行结果
	if not error.is_empty():
		_log_error("Tool execution failed: " + tool_name + " - " + error)
		tool_execution_failed.emit(tool_name, error)
		var error_result: Dictionary = {
			"content": [{
				"type": "text",
				"text": error
			}],
			"isError": true
		}
		return MCPTypes.create_response(id, error_result)
	
	var has_error: bool = result is Dictionary and result.has("error")
	var response_result: Dictionary = _format_tool_result(result, tool)

	# Keep the result cache coherent: store successful cacheable reads together
	# with their formatted payload and dependency-revision snapshot. Mutations
	# advance only affected revisions; stale entries are discarded on access.
	# A read that overlapped a relevant mutation cannot repopulate the cache
	# because its captured snapshot no longer matches.
	if is_cacheable_read:
		if not has_error and result is Dictionary and _cache_revision_index.is_current(cache_revision_snapshot_at_start):
			_result_cache_put(cache_key, result, response_result, cache_revision_snapshot_at_start)
		else:
			_cache_inflight.erase(cache_key)
	elif not bool(tool.annotations.get("readOnlyHint", false)) and tool_name not in CACHE_PRESERVING_MUTATION_TOOLS:
		var mutation_tags: Array[String] = CACHE_REVISION_INDEX_SCRIPT.mutation_tags(
			tool_name, tool.group, arguments)
		_advance_result_cache_revisions(mutation_tags, tool_name)

	var response: Dictionary = MCPTypes.create_response(id, response_result)
	
	_append_tool_log(tool_name, result, error)
	
	# 发送完成信号
	tool_execution_completed.emit(tool_name, result)
	_log_info("Tool execution completed: " + tool_name)
	
	return response

## Wrap a tool's raw result into an MCP tool-call result payload. Shared by live
## execution and cache hits so both produce identical responses. Results whose
## JSON serialization exceeds MAX_INLINE_RESULT_BYTES are spilled to disk and
## returned as a truncated head/tail preview (never an error, per the DSH
## "spill, don't fail" principle); file-content tools in SPILL_EXEMPT_TOOLS keep
## returning inline content.
func _format_tool_result(result: Variant, tool: MCPTypes.MCPTool) -> Dictionary:
	var has_error: bool = result is Dictionary and result.has("error")
	var json_text: String = JSON.stringify(result)
	var spilled: Dictionary = {}
	if not has_error:
		spilled = _maybe_spill_result(json_text, tool)
		if not spilled.is_empty():
			json_text = JSON.stringify(spilled)
	var content_blocks: Array[Dictionary] = [{
			"type": "text",
			"text": json_text
		}]
	if not spilled.is_empty():
		content_blocks.append(_build_spilled_result_resource_link(spilled, tool))
	var response_result: Dictionary = {
		"content": content_blocks,
		"isError": has_error
	}
	# On a spill the full payload lives on disk; echoing it as structuredContent
	# would defeat the size limit, so it is omitted for spilled results only.
	if not has_error and tool.output_schema.size() > 0 and spilled.is_empty():
		response_result["structuredContent"] = result
	return response_result

func _handle_resources_list(message: Dictionary) -> Dictionary:
	var id: Variant = message.get("id")
	
	_log_info("Resources list requested. Available resources: " + str(_resources.size()))
	
	# 构建资源列表（根据mcp-builder，包含description）
	var resources_list: Array[Dictionary] = []
	
	for uri in _resources:
		var resource: MCPTypes.MCPResource = _resources[uri]
		if resource and resource.is_valid():
			resources_list.append(resource.to_dict())
	
	var result: Dictionary = {"resources": resources_list}
	# 2026-07-28 MCP 规范：列表结果需带 _meta（ttlMs/cacheScope）。
	result["_meta"] = {
		"ttlMs": LIST_CACHE_TTL_MS,
		"cacheScope": RESOURCES_LIST_CACHE_SCOPE
	}
	var response: Dictionary = MCPTypes.create_response(id, result)
	
	if _debug_enabled():
		_log_debug("Resources list response: " + JSON.stringify(response))
	
	return response

func _handle_resource_read(message: Dictionary) -> Dictionary:
	var id: Variant = message.get("id")
	var params: Dictionary = message.get("params", {})
	var uri: String = params.get("uri", "")
	
	_log_info("Resource read: " + uri)

	# Spilled tool results are content-addressed dynamic resources. They are
	# linked directly from CallToolResult and intentionally do not bloat
	# resources/list or tools/list.
	if uri.begins_with(RESULT_RESOURCE_URI_PREFIX):
		return _handle_spilled_result_resource_read(id, uri)
	
	# 检查资源是否存在
	if not _resources.has(uri):
		_log_error("Resource not found: " + uri)
		return MCPTypes.create_error_response(id, MCPTypes.ERROR_RESOURCE_NOT_FOUND, "Resource not found: " + uri)
	
	var resource: MCPTypes.MCPResource = _resources[uri]
	
	resource_requested.emit(uri, params)
	
	var content: Dictionary = {}
	
	if resource.load_callable.is_valid():
		content = await resource.load_callable.call(params)
	
	var result: Dictionary = {}
	
	if content.has("contents"):
		result = content
	else:
		result = {
			"contents": [{
				"uri": uri,
				"mimeType": resource.mime_type,
				"text": content.get("text", JSON.stringify(content))
			}]
		}
	
	var response: Dictionary = MCPTypes.create_response(id, result)
	
	# 发送资源加载信号
	resource_loaded.emit(uri, content)
	_log_info("Resource loaded: " + uri)
	
	return response

func _handle_resource_subscribe(message: Dictionary) -> Dictionary:
	var id: Variant = message.get("id")
	var params: Dictionary = message.get("params", {})
	var uri: String = params.get("uri", "")
	
	if uri.is_empty():
		return MCPTypes.create_error_response(id, MCPTypes.ERROR_INVALID_PARAMS, "Missing required parameter: uri")
	
	if not _resources.has(uri):
		_log_warn("Subscribe to unknown resource: " + uri)
		return MCPTypes.create_error_response(id, MCPTypes.ERROR_RESOURCE_NOT_FOUND, "Resource not found: " + uri)
	
	_resource_subscriptions[uri] = true
	_log_info("Resource subscribed: " + uri)
	
	# MCP spec: resources/subscribe returns an empty result on success.
	return MCPTypes.create_response(id, {})

func _handle_resource_unsubscribe(message: Dictionary) -> Dictionary:
	var id: Variant = message.get("id")
	var params: Dictionary = message.get("params", {})
	var uri: String = params.get("uri", "")
	
	if uri.is_empty():
		return MCPTypes.create_error_response(id, MCPTypes.ERROR_INVALID_PARAMS, "Missing required parameter: uri")
	
	if _resource_subscriptions.has(uri):
		_resource_subscriptions.erase(uri)
		_log_info("Resource unsubscribed: " + uri)
	
	# MCP spec: resources/unsubscribe returns an empty result on success.
	return MCPTypes.create_response(id, {})

## Whether a client currently holds a subscription to the given resource uri.
func is_resource_subscribed(uri: String) -> bool:
	return _resource_subscriptions.has(uri)

## List of resource uris that currently have an active subscription.
func get_resource_subscriptions() -> Array:
	return _resource_subscriptions.keys()

## Notify subscribed clients that a resource changed.
## Sends a `notifications/resources/updated` message for the uri if it has an
## active subscription and a transport is connected. Returns true if a
## notification was sent.
func notify_resource_updated(uri: String) -> bool:
	if not _resource_subscriptions.has(uri):
		return false
	var notification: Dictionary = {
		"jsonrpc": "2.0",
		"method": MCPTypes.NOTIFICATION_RESOURCES_UPDATED,
		"params": {"uri": uri}
	}
	if _transport and _transport.has_method("send_raw_message"):
		_transport.send_raw_message(notification)
		_log_debug("Sent resources/updated notification: " + uri)
		return true
	return false

# ============================================================================
# Progress 通知与取消支持（2025-03-26+ MCP 规范）
# ============================================================================

## Send a `notifications/progress` notification to the client. `progress_token`
## is the client-supplied `_meta.progressToken` of the tool call being reported
## on; when it is absent (client did not opt in) or no transport is connected,
## the notification is silently skipped. `total` and `message` are optional per
## the spec and omitted from the payload when empty.
func send_progress_notification(progress_token: Variant, progress: int, total: int = 0, message: String = "") -> void:
	if progress_token == null:
		return
	if not _transport or not _transport.has_method("send_raw_message"):
		return
	var params: Dictionary = {
		"progressToken": progress_token,
		"progress": progress
	}
	if total > 0:
		params["total"] = total
	if not message.is_empty():
		params["message"] = message
	var notification: Dictionary = {
		"jsonrpc": "2.0",
		"method": MCPTypes.NOTIFICATION_PROGRESS,
		"params": params
	}
	_transport.send_raw_message(notification)
	_log_debug("Sent progress notification (token=%s, progress=%d, total=%d)" % [str(progress_token), progress, total])

## Whether the client sent a `notifications/cancelled` for the given request id.
func is_request_cancelled(request_id: Variant) -> bool:
	return _cancelled_requests.has(request_id)

## Drop the cancellation marker for a request id (called after a tool finishes).
func clear_cancelled(request_id: Variant) -> void:
	if _cancelled_requests.has(request_id):
		_cancelled_requests.erase(request_id)

## Whether the currently executing tool call (see `_execution_context`) has been
## cancelled by the client. Tools cannot see their own request id, so they poll
## this while running and abort early when it returns true.
func is_current_tool_cancelled() -> bool:
	if _execution_context.is_empty():
		return false
	return _cancelled_requests.has(_execution_context.get("request_id", null))

## The progress token of the currently executing tool call, or null when the
## client did not supply one. Lets tools that did not see `_meta` in their
## arguments still report progress.
func get_current_progress_token() -> Variant:
	if _execution_context.is_empty():
		return null
	return _execution_context.get("progress_token", null)

func _handle_prompts_list(message: Dictionary) -> Dictionary:
	var id: Variant = message.get("id")
	
	_log_info("Prompts list requested")
	
	var prompts_list: Array[Dictionary] = []
	
	for prompt_name in _prompts:
		var prompt: MCPTypes.MCPPrompt = _prompts[prompt_name]
		if prompt and prompt.is_valid():
			prompts_list.append(prompt.to_dict())
	
	var result: Dictionary = {"prompts": prompts_list}
	# 2026-07-28 MCP 规范：列表结果需带 _meta（ttlMs/cacheScope）。
	result["_meta"] = {
		"ttlMs": LIST_CACHE_TTL_MS,
		"cacheScope": PROMPTS_LIST_CACHE_SCOPE
	}
	var response: Dictionary = MCPTypes.create_response(id, result)
	
	return response

func _handle_prompt_get(message: Dictionary) -> Dictionary:
	var id: Variant = message.get("id")
	var params: Dictionary = message.get("params", {})
	var prompt_name: String = params.get("name", "")
	var arguments: Dictionary = params.get("arguments", {})
	
	_log_info("Prompt get: " + prompt_name)
	
	if prompt_name.is_empty():
		return MCPTypes.create_error_response(id, MCPTypes.ERROR_INVALID_PARAMS, "Missing required parameter: name")
	
	if not _prompts.has(prompt_name):
		return MCPTypes.create_error_response(id, MCPTypes.ERROR_INVALID_PARAMS, "Prompt not found: " + prompt_name)
	
	var prompt: MCPTypes.MCPPrompt = _prompts[prompt_name]
	
	# Validate required arguments declared by the prompt are present.
	for arg in prompt.arguments:
		if arg.get("required", false) and not arguments.has(arg.get("name", "")):
			return MCPTypes.create_error_response(id, MCPTypes.ERROR_INVALID_PARAMS, "Missing required prompt argument: " + str(arg.get("name", "")))
	
	var result: Dictionary = {}
	if prompt.get_callable.is_valid():
		# await mirrors _handle_resource_read so prompt callables may be async;
		# awaiting a synchronous return value resolves immediately.
		var produced: Variant = await prompt.get_callable.call(arguments)
		if typeof(produced) != TYPE_DICTIONARY:
			_log_error("Prompt callable returned non-Dictionary for: " + prompt_name)
			return MCPTypes.create_error_response(id, MCPTypes.ERROR_INTERNAL_ERROR, "Prompt generation failed: " + prompt_name)
		result = produced
	
	# Normalize the result shape to {description, messages}.
	if not result.has("description"):
		result["description"] = prompt.description
	if not result.has("messages"):
		result["messages"] = []
	
	return MCPTypes.create_response(id, result)

# ============================================================================
# 工具注册API（优化版 - 根据mcp-builder）
# ============================================================================

func register_tool(name: String, description: String, 
				  input_schema: Dictionary, callable: Callable,
				  output_schema: Dictionary = {}, 
				  annotations: Dictionary = {},
				  category: String = "core",
				  group: String = "") -> void:
	var tool: MCPTypes.MCPTool = MCPTypes.MCPTool.new()
	tool.name = name
	tool.description = description
	tool.input_schema = input_schema
	tool.output_schema = output_schema
	tool.annotations = annotations
	tool.callable = callable
	tool.category = category
	tool.group = group
	tool.enabled = (category == "core" or category == "meta")
	
	if not tool.is_valid():
		var reason: String = "unknown"
		if name.is_empty():
			reason = "name is empty"
		elif description.is_empty():
			reason = "description is empty"
		elif not callable.is_valid():
			reason = "callable is invalid (method may not exist or object is freed)"
		_log_error("Invalid tool definition: " + name + " (reason: " + reason + ")")
		printerr("[MCP][DIAG] Tool '%s' rejected: callable.is_valid()=%s, callable=%s" % [name, str(callable.is_valid()), str(callable)])
		return
	
	_tools[name] = tool
	_tool_schema_token_costs[name] = _estimate_tool_schema_tokens(tool)
	_invalidate_tool_list_cache()
	_tool_catalog_revision += 1
	_tool_registry_revision += 1
	_invalidate_tool_discovery_cache(name)
	_log_info("Tool registered: " + name)

func unregister_tool(name: String) -> void:
	if _tools.has(name):
		_tools.erase(name)
		_tool_schema_token_costs.erase(name)
		_invalidate_tool_list_cache()
		_tool_catalog_revision += 1
		_tool_registry_revision += 1
		_invalidate_tool_discovery_cache(name)
		_log_info("Tool unregistered: " + name)

func get_tool(name: String) -> MCPTypes.MCPTool:
	return _tools.get(name, null)

func get_all_tools() -> Dictionary:
	return _tools.duplicate()

func get_tools_count() -> int:
	return _tools.size()

func get_resources_count() -> int:
	return _resources.size()

func get_registered_tools() -> Array:
	var tools_info: Array = []
	for tool_name in _tools:
		var tool: MCPTypes.MCPTool = _tools[tool_name]
		if tool and tool.is_valid():
			tools_info.append({
				"name": tool.name,
				"description": tool.description,
				"enabled": tool.enabled,
				"category": tool.category,
				"group": tool.group,
				"schema_tokens": int(_tool_schema_token_costs.get(tool_name, 1))
			})
	return tools_info

func _estimate_tool_schema_tokens(tool: MCPTypes.MCPTool) -> int:
	return TOKEN_ESTIMATOR_SCRIPT.estimate_tool_definition(
		tool.name, tool.description, tool.input_schema)

func set_tool_enabled(tool_name: String, enabled: bool) -> void:
	if not _tools.has(tool_name):
		if enabled:
			_log_warn("Cannot enable unregistered tool: " + tool_name)
		return

	var target_enabled: bool = enabled
	if not target_enabled and _is_always_on_tool(tool_name):
		target_enabled = true
		_log_debug("Ignoring request to disable always-on meta tool: " + tool_name)
	if _tools[tool_name].enabled == target_enabled:
		return

	_tools[tool_name].enabled = target_enabled
	_commit_tool_state_changes([tool_name])
	if target_enabled:
		_log_info("Tool enabled: " + tool_name)
	else:
		_log_info("Tool disabled: " + tool_name)

func _is_always_on_tool(tool_name: String) -> bool:
	var classifier = get_classifier()
	if classifier and classifier.has_method("is_meta_tool"):
		return classifier.is_meta_tool(tool_name)
	return false

func set_group_enabled(group_name: String, enabled: bool) -> int:
	if _classifier == null:
		_classifier = load("res://addons/godot_mcp/native_mcp/mcp_tool_classifier.gd").new()
	var group_tools: Array[String] = _classifier.get_group_tools(group_name)
	var states: Dictionary = {}
	for tool_name in group_tools:
		states[tool_name] = enabled
	var result: Dictionary = apply_tool_states(states)
	var changed_count: int = int(result.get("changed_count", 0))
	if changed_count > 0:
		_log_info("Group '" + group_name + "' " + ("enabled" if enabled else "disabled") + ": " + str(changed_count) + " tools affected")
	return changed_count

## Apply many visibility changes as one atomic catalog transition. This avoids
## rebuilding tools/list and invalidating discovery results once per tool when a
## preset changes dozens or hundreds of entries.
func apply_tool_states(states: Dictionary) -> Dictionary:
	var changed_tools: Array[String] = []
	var unknown_tools: Array[String] = []
	var state_names: Array = states.keys()
	state_names.sort()
	for name_value in state_names:
		var tool_name: String = String(name_value)
		if not _tools.has(tool_name):
			unknown_tools.append(tool_name)
			continue
		var target_enabled: bool = bool(states[name_value])
		if not target_enabled and _is_always_on_tool(tool_name):
			target_enabled = true
		if _tools[tool_name].enabled == target_enabled:
			continue
		_tools[tool_name].enabled = target_enabled
		changed_tools.append(tool_name)

	_commit_tool_state_changes(changed_tools)
	return {
		"changed_count": changed_tools.size(),
		"changed_tools": changed_tools,
		"unknown_tools": unknown_tools,
		"catalog_revision": _tool_catalog_revision
	}

func get_tool_catalog_revision() -> int:
	return _tool_catalog_revision

func get_tool_registry_revision() -> int:
	return _tool_registry_revision

func _commit_tool_state_changes(changed_tools: Array) -> void:
	if changed_tools.is_empty():
		return
	_tool_list_dirty = true
	_invalidate_tool_list_cache()
	_tool_catalog_revision += 1
	_invalidate_tool_discovery_cache()

func get_tool_list_dirty() -> bool:
	return _tool_list_dirty

func clear_tool_list_dirty() -> void:
	_tool_list_dirty = false

func notify_tool_list_changed() -> void:
	if not _tool_list_dirty:
		return
	var notification: Dictionary = {
		"jsonrpc": "2.0",
		"method": "notifications/tools/list_changed",
		"params": {}
	}
	if _transport and _transport.has_method("send_raw_message"):
		_transport.send_raw_message(notification)
	_tool_list_dirty = false

func get_classifier():
	if _classifier == null:
		_classifier = load("res://addons/godot_mcp/native_mcp/mcp_tool_classifier.gd").new()
	return _classifier

func get_state_manager():
	if _state_manager == null:
		_state_manager = load("res://addons/godot_mcp/native_mcp/tool_state_manager.gd").new()
	return _state_manager

func load_tool_states() -> int:
	if _state_manager == null:
		_state_manager = load("res://addons/godot_mcp/native_mcp/tool_state_manager.gd").new()
	var saved_states: Dictionary = _state_manager.load_state()
	if not saved_states.is_empty():
		_state_manager.apply_states_to_server(self, saved_states)
		_log_info("Loaded saved tool states: " + str(saved_states.size()) + " tools")
	return saved_states.size()

func save_tool_states() -> void:
	if _state_manager == null:
		_state_manager = load("res://addons/godot_mcp/native_mcp/tool_state_manager.gd").new()
	var states: Dictionary = _state_manager.capture_states_from_server(self)
	_state_manager.save_state(states)

func has_tool(name: String) -> bool:
	return _tools.has(name)

# ============================================================================
# 资源注册API（优化版 - 根据mcp-builder）
# ============================================================================

func register_resource(uri: String, name: String, 
					  mime_type: String, load_callable: Callable,
					  description: String = "") -> void:  # 新增description参数
	# 创建资源对象
	var resource: MCPTypes.MCPResource = MCPTypes.MCPResource.new()
	resource.uri = uri
	resource.name = name
	resource.description = description  # 新增（根据mcp-builder）
	resource.mime_type = mime_type
	resource.load_callable = load_callable
	
	# 验证资源定义
	if not resource.is_valid():
		_log_error("Invalid resource definition: " + uri)
		return
	
	_resources[uri] = resource
	_log_info("Resource registered: " + uri)

func unregister_resource(uri: String) -> void:
	if _resources.has(uri):
		_resources.erase(uri)
		_resource_subscriptions.erase(uri)
		_log_info("Resource unregistered: " + uri)

func get_resource(uri: String) -> MCPTypes.MCPResource:
	return _resources.get(uri, null)

func get_all_resources() -> Dictionary:
	return _resources.duplicate()

# ============================================================================
# Prompt注册API
# ============================================================================

func register_prompt(name: String, description: String, 
					 arguments: Array[Dictionary], 
					 get_callable: Callable) -> void:
	var prompt: MCPTypes.MCPPrompt = MCPTypes.MCPPrompt.new()
	prompt.name = name
	prompt.description = description
	prompt.arguments = arguments
	prompt.get_callable = get_callable
	
	_prompts[name] = prompt
	_log_info("Prompt registered: " + name)

# ============================================================================
# 响应发送
# ============================================================================

func _send_response(response: Dictionary, context: Variant = null) -> void:
	var json_string: String = JSON.stringify(response)
	
	if _transport_type == TransportType.TRANSPORT_STDIO:
		print(json_string)
	elif _transport_type == TransportType.TRANSPORT_HTTP:
		_transport.send_response(response, context)
	
	response_sent.emit(response)

func _send_error(id: Variant, code: int, message: String, data: Variant = null, context: Variant = null) -> void:
	var error_response: Dictionary = MCPTypes.create_error_response(id, code, message, data)
	_send_response(error_response, context)

# ============================================================================
# 速率限制（根据mcp-builder安全最佳实践）
# ============================================================================

func _check_rate_limit(client_id: String) -> bool:
	var current_time: int = Time.get_unix_time_from_system()
	
	if not _request_timestamps.has(client_id):
		var new_timestamps: Array[int] = []
		_request_timestamps[client_id] = new_timestamps
		_request_count[client_id] = 0
	
	var timestamps: Array[int] = _request_timestamps[client_id]
	
	# 移除60秒前的记录
	while not timestamps.is_empty() and current_time - timestamps[0] > 60:
		timestamps.pop_front()
		_request_count[client_id] -= 1
	
	# 检查是否超过限制
	if _request_count[client_id] >= _rate_limit:
		_log_warn("Rate limit exceeded for client: " + client_id)
		return false
	
	# 添加新记录
	timestamps.append(current_time)
	_request_count[client_id] += 1
	
	return true

# ============================================================================
# 结果缓存机制（LRU + 确定性 key + 依赖 revision 懒失效）
# ============================================================================

## Deterministic JSON serialization used to build cache keys: dictionary keys are
## sorted recursively so two argument dicts with identical content but different
## insertion order produce the same key. Scalars fall back to JSON.stringify.
static func _canonical_json(data: Variant) -> String:
	match typeof(data):
		TYPE_DICTIONARY:
			var keys: Array = (data as Dictionary).keys()
			var sorted_keys: Array[String] = []
			var key_lookup: Dictionary = {}  # stringified key -> original key
			for key in keys:
				var skey: String = str(key)
				sorted_keys.append(skey)
				key_lookup[skey] = key
			sorted_keys.sort()
			var parts: Array[String] = []
			for skey in sorted_keys:
				parts.append(JSON.stringify(skey) + ":" + _canonical_json(data[key_lookup[skey]]))
			return "{" + ",".join(parts) + "}"
		TYPE_ARRAY:
			var items: Array[String] = []
			for item in data:
				items.append(_canonical_json(item))
			return "[" + ",".join(items) + "]"
		_:
			var encoded: String = JSON.stringify(data)
			if encoded.is_empty():
				encoded = JSON.stringify(str(data))
			return encoded

## Fetch (and LRU-touch) a cache entry. Returns {} on miss, TTL expiry, or a
## dependency revision mismatch (stale entries are dropped immediately).
func _result_cache_get_entry(key: String) -> Dictionary:
	if not _result_cache.has(key):
		return {}
	var entry: Dictionary = _result_cache[key]
	if Time.get_ticks_msec() - int(entry.get("last_access", 0)) > RESULT_CACHE_TTL_MS:
		_erase_result_cache_key(key)
		return {}
	var revision_snapshot: Variant = entry.get("revision_snapshot", null)
	if revision_snapshot is Dictionary and not _cache_revision_index.is_current(revision_snapshot):
		_erase_result_cache_key(key)
		return {}
	entry["last_access"] = Time.get_ticks_msec()
	_result_cache_touch(key)
	return entry

## Read the raw cached tool result. Returns null on miss, on TTL expiry (the
## entry is dropped), or for entries evicted by the LRU policy.
func _result_cache_get(key: String) -> Variant:
	var entry: Dictionary = _result_cache_get_entry(key)
	if entry.is_empty():
		return null
	return entry.get("value", null)

## Read the cached, already-formatted MCP tool-call result payload. Returns
## null when the key is missing/expired or when the entry was stored by a legacy
## caller without a formatted payload.
func _result_cache_get_formatted(key: String) -> Variant:
	var entry: Dictionary = _result_cache_get_entry(key)
	if entry.is_empty():
		return null
	return entry.get("formatted", null)

## Store a result under key, refresh recency, and enforce the LRU capacity:
## beyond RESULT_CACHE_MAX the least recently used entry is evicted. The optional
## `formatted` payload is the exact response result produced by
## `_format_tool_result`; storing it lets cache hits skip JSON.stringify and
## spill re-checks.
func _result_cache_put(key: String, value: Variant, formatted: Variant = null,
		revision_snapshot: Dictionary = {}) -> void:
	if _result_cache.has(key):
		_erase_result_cache_key(key)
	var entry: Dictionary = {"value": value, "last_access": Time.get_ticks_msec()}
	if formatted != null:
		entry["formatted"] = formatted
	if not revision_snapshot.is_empty():
		entry["revision_snapshot"] = revision_snapshot.duplicate()
	_result_cache[key] = entry
	_cache_inflight.erase(key)
	_result_cache_order.push_front(key)
	while _result_cache_order.size() > RESULT_CACHE_MAX:
		var evicted_key: String = _result_cache_order.pop_back()
		_result_cache.erase(evicted_key)
		_cache_inflight.erase(evicted_key)

## Remove one entry from both the value map and the recency index.
func _erase_result_cache_key(key: String) -> void:
	_result_cache.erase(key)
	_result_cache_order.erase(key)
	_cache_inflight.erase(key)

## Move a key to the most-recently-used position (index 0) of the LRU order.
func _result_cache_touch(key: String) -> void:
	var idx: int = _result_cache_order.find(key)
	if idx > 0:
		_result_cache_order.remove_at(idx)
		_result_cache_order.push_front(key)

## Return one immutable, dependency-versioned scan snapshot for all pages of a
## read query. `arguments` must exclude presentation-only limit/offset fields.
## On a miss the producer runs once; oversized snapshots remain fully usable
## for this call but are not retained in memory.
func get_or_compute_read_snapshot(tool_name: String, arguments: Dictionary,
		producer: Callable) -> Dictionary:
	if not producer.is_valid():
		return {"error": "Invalid read snapshot producer"}
	if tool_name not in CACHEABLE_READ_TOOLS:
		var uncached: Variant = producer.call()
		return uncached if uncached is Dictionary else {}
	var key: String = tool_name + ":@snapshot:" + _canonical_json(arguments)
	var cached: Variant = _result_cache_get(key)
	if cached is Dictionary:
		return cached
	var dependency_tags: Array[String] = CACHE_REVISION_INDEX_SCRIPT.read_tags(
		tool_name, arguments)
	var revision_snapshot: Dictionary = _cache_revision_index.snapshot(dependency_tags)
	var produced: Variant = producer.call()
	if not (produced is Dictionary):
		return {}
	var result: Dictionary = produced
	if result.has("error") or not _cache_revision_index.is_current(revision_snapshot):
		return result
	var encoded: String = JSON.stringify(result)
	if encoded.to_utf8_buffer().size() > READ_SNAPSHOT_MAX_BYTES:
		return result
	_result_cache_put(key, result, null, revision_snapshot)
	_enforce_read_snapshot_cache_limit()
	return result

func _enforce_read_snapshot_cache_limit() -> void:
	var snapshot_keys: Array[String] = []
	for key in _result_cache_order:
		if _is_read_snapshot_cache_key(key):
			snapshot_keys.append(key)
	for index in range(READ_SNAPSHOT_CACHE_MAX, snapshot_keys.size()):
		_erase_result_cache_key(snapshot_keys[index])

static func _is_read_snapshot_cache_key(key: String) -> bool:
	var separator: int = key.find(":")
	return separator >= 0 and key.substr(separator).begins_with(":@snapshot:")

## Explicitly drop the whole result cache (public clear_cache compatibility).
## Normal tool mutations use dependency revisions instead.
func _invalidate_result_cache() -> void:
	_cache_generation += 1
	_cache_revision_index.advance([CACHE_REVISION_INDEX_SCRIPT.TAG_GLOBAL])
	if _result_cache.is_empty() and _cache_inflight.is_empty():
		return
	_result_cache.clear()
	_result_cache_order.clear()
	_cache_inflight.clear()
	_log_debug("Result cache invalidated")

## O(affected tags) mutation path. Cached values are not scanned: their snapshots
## are checked only if that key is requested again. At most the tiny in-flight
## set is pruned so a relevant concurrent read cannot be mistaken for reusable.
func _advance_result_cache_revisions(tags: Array[String], tool_name: String = "") -> void:
	if tags.is_empty():
		return
	_cache_generation += 1
	_cache_revision_index.advance(tags)
	for key_value in _cache_inflight.keys():
		var key: String = String(key_value)
		var inflight_snapshot: Variant = _cache_inflight[key_value]
		if inflight_snapshot is Dictionary and not _cache_revision_index.is_current(inflight_snapshot):
			_cache_inflight.erase(key)
	_log_debug("Advanced result-cache revisions for %s: %s" % [tool_name, ",".join(tags)])

## Evict cache entries produced by specific tools while retaining unrelated
## scene/project reads. The tool-catalog revision also advances so an in-flight
## discovery result cannot repopulate a stale entry afterward.
func _invalidate_result_cache_for_tools(tool_names: Array[String]) -> void:
	_cache_generation += 1
	_cache_revision_index.advance([CACHE_REVISION_INDEX_SCRIPT.TAG_TOOL_CATALOG])
	var targets: Dictionary = {}
	for tool_name in tool_names:
		targets[tool_name] = true
	var removed_count: int = 0
	for key_value in _result_cache.keys():
		var key: String = String(key_value)
		var separator: int = key.find(":")
		var cached_tool: String = key.substr(0, separator) if separator >= 0 else key
		if targets.has(cached_tool):
			_result_cache.erase(key)
			_result_cache_order.erase(key)
			removed_count += 1
	for inflight_key_value in _cache_inflight.keys():
		var inflight_key: String = String(inflight_key_value)
		var inflight_separator: int = inflight_key.find(":")
		var inflight_tool: String = inflight_key.substr(0, inflight_separator) if inflight_separator >= 0 else inflight_key
		if targets.has(inflight_tool):
			_cache_inflight.erase(inflight_key)
	if removed_count > 0:
		_log_debug("Selectively invalidated %d result cache entries" % removed_count)

func _invalidate_tool_discovery_cache(extra_tool_name: String = "") -> void:
	var targets: Array[String] = TOOL_DISCOVERY_CACHE_TOOLS.duplicate()
	if not extra_tool_name.is_empty() and extra_tool_name not in targets:
		targets.append(extra_tool_name)
	_invalidate_result_cache_for_tools(targets)

## Legacy scene-structure cache API, kept for backward compatibility as thin
## wrappers over the shared LRU result cache (keys are used as-is, not
## canonicalized).
func get_cached_scene_structure(scene_path: String) -> Dictionary:
	var value: Variant = _result_cache_get(scene_path)
	if value is Dictionary:
		return value
	return {}

func set_cached_scene_structure(scene_path: String, structure: Dictionary) -> void:
	_result_cache_put(scene_path, structure)

func clear_cache() -> void:
	_invalidate_result_cache()
	_log_info("Cache cleared")

# ============================================================================
# 结果体积控制（spill 落盘）
# ============================================================================

## If `json_text` exceeds MAX_INLINE_RESULT_BYTES (and the tool is not spill
## exempt), write it to res://.mcp/out/ and return the truncated preview payload.
## Returns {} when the result stays inline (small, exempt, or disk write failed —
## a failed spill falls back to inline, never to an error).
func _maybe_spill_result(json_text: String, tool: MCPTypes.MCPTool) -> Dictionary:
	if json_text.is_empty() or tool.name in SPILL_EXEMPT_TOOLS:
		return {}
	var json_bytes: PackedByteArray = json_text.to_utf8_buffer()
	var size_bytes: int = json_bytes.size()
	if size_bytes <= MAX_INLINE_RESULT_BYTES:
		return {}
	var content_sha256: String = _hash_bytes(json_bytes)
	if content_sha256.is_empty():
		return {}
	var path: String = _spill_result_to_disk(json_bytes, content_sha256)
	if path.is_empty():
		return {}
	var resource_uri: String = RESULT_RESOURCE_URI_PREFIX + content_sha256
	return {
		"truncated": true,
		"total_bytes": size_bytes,
		"path": path,
		"resource_uri": resource_uri,
		"page_bytes": RESULT_RESOURCE_PAGE_BYTES,
		"content_sha256": content_sha256,
		"head": json_text.substr(0, SPILL_PREVIEW_HEAD_CHARS),
		"tail": json_text.substr(maxi(0, json_text.length() - SPILL_PREVIEW_TAIL_CHARS)),
		"content_type": "application/json",
		"resume_hint": "Follow the resource_link with resources/read, then follow result._meta.nextUri while hasMore=true. Concatenating page text reconstructs the exact application/json payload. Legacy file: " + path
	}

func _build_spilled_result_resource_link(spilled: Dictionary, tool: MCPTypes.MCPTool) -> Dictionary:
	return {
		"type": "resource_link",
		"uri": String(spilled.get("resource_uri", "")),
		"name": tool.name + "-full-result.json",
		"title": "Full result from " + tool.name,
		"description": "Lossless paged JSON source. Read this URI, then follow result._meta.nextUri until hasMore is false; concatenate page text in order.",
		"mimeType": "text/plain; charset=utf-8",
		"size": int(spilled.get("total_bytes", 0)),
		"_meta": {
			"contentType": "application/json",
			"contentSha256": String(spilled.get("content_sha256", "")),
			"pageBytes": RESULT_RESOURCE_PAGE_BYTES
		}
	}

## Write `json_bytes` to <SPILL_OUTPUT_DIR>/<sha256>.json and return the path.
## Identical content reuses its existing immutable file without another write;
## returns "" on failure so callers can preserve the complete inline response.
func _spill_result_to_disk(json_bytes: PackedByteArray, content_sha256: String) -> String:
	var err: Error = DirAccess.make_dir_recursive_absolute(SPILL_OUTPUT_DIR)
	if err != OK:
		var root: DirAccess = DirAccess.open("res://")
		if root:
			err = root.make_dir_recursive(SPILL_OUTPUT_DIR.trim_prefix("res://"))
	if err != OK:
		_log_warn("Spill: failed to create output dir " + SPILL_OUTPUT_DIR + " (error " + str(err) + ")")
		return ""
	var path: String = SPILL_OUTPUT_DIR + "/" + content_sha256 + ".json"
	if FileAccess.file_exists(path):
		# Do not trust a same-sized file: project-local output can be edited out of
		# band. Reuse only when its digest still matches the content-addressed URI.
		if FileAccess.get_sha256(path) == content_sha256:
			return path
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if not file:
		_log_warn("Spill: failed to open " + path + " for writing; falling back to inline")
		return ""
	file.store_buffer(json_bytes)
	file.close()
	_log_info("Spilled large result (%d bytes) to %s" % [json_bytes.size(), path])
	return path

## Deterministic cryptographic content hash used for immutable result handles.
static func _hash_bytes(value: PackedByteArray) -> String:
	var context: HashingContext = HashingContext.new()
	if context.start(HashingContext.HASH_SHA256) != OK:
		return ""
	if context.update(value) != OK:
		return ""
	return context.finish().hex_encode()

static func _hash_string(value: String) -> String:
	return _hash_bytes(value.to_utf8_buffer())

func _handle_spilled_result_resource_read(id: Variant, uri: String) -> Dictionary:
	var parsed: Dictionary = _parse_result_resource_uri(uri)
	if parsed.has("error"):
		return MCPTypes.create_error_response(
			id, MCPTypes.ERROR_INVALID_PARAMS, String(parsed.get("error", "Invalid result resource URI")))
	var handle: String = String(parsed.get("handle", ""))
	var cursor: int = int(parsed.get("cursor", 0))
	var path: String = SPILL_OUTPUT_DIR + "/" + handle + ".json"
	if not FileAccess.file_exists(path):
		return MCPTypes.create_error_response(
			id, MCPTypes.ERROR_RESOURCE_NOT_FOUND, "Result resource is unavailable: " + handle)
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if not file:
		return MCPTypes.create_error_response(
			id, MCPTypes.ERROR_RESOURCE_NOT_FOUND, "Result resource could not be opened: " + handle)
	var total_bytes: int = file.get_length()
	if cursor < 0 or cursor > total_bytes:
		file.close()
		return MCPTypes.create_error_response(
			id, MCPTypes.ERROR_INVALID_PARAMS, "Result cursor is outside the payload")
	file.seek(cursor)
	# Read a few lookahead bytes so the page can back up to a UTF-8 boundary
	# without loading or decoding the complete spilled result.
	var read_size: int = mini(total_bytes - cursor, RESULT_RESOURCE_PAGE_BYTES + 4)
	var buffer: PackedByteArray = file.get_buffer(read_size)
	file.close()
	if cursor < total_bytes and not buffer.is_empty() and (int(buffer[0]) & 0xC0) == 0x80:
		return MCPTypes.create_error_response(
			id, MCPTypes.ERROR_INVALID_PARAMS, "Result cursor must come from an advertised nextUri")
	var page_size: int = mini(RESULT_RESOURCE_PAGE_BYTES, buffer.size())
	if cursor + page_size < total_bytes:
		while page_size > 0 and page_size < buffer.size() and (int(buffer[page_size]) & 0xC0) == 0x80:
			page_size -= 1
	if page_size == 0 and cursor < total_bytes:
		return MCPTypes.create_error_response(
			id, MCPTypes.ERROR_INTERNAL_ERROR, "Could not find a UTF-8 page boundary")
	var fragment_bytes: PackedByteArray = buffer.slice(0, page_size)
	var fragment: String = fragment_bytes.get_string_from_utf8()
	var next_cursor: int = cursor + page_size
	var has_more: bool = next_cursor < total_bytes
	var meta: Dictionary = {
		"contentType": "application/json",
		"contentSha256": handle,
		"cursor": str(cursor),
		"returnedBytes": page_size,
		"totalBytes": total_bytes,
		"pageBytes": RESULT_RESOURCE_PAGE_BYTES,
		"hasMore": has_more
	}
	if has_more:
		meta["nextCursor"] = str(next_cursor)
		meta["nextUri"] = RESULT_RESOURCE_URI_PREFIX + handle + "?cursor=" + str(next_cursor)
	var contents_meta: Dictionary = meta.duplicate(true)
	return MCPTypes.create_response(id, {
		"contents": [{
			"uri": uri,
			"mimeType": "text/plain; charset=utf-8",
			"text": fragment,
			"_meta": contents_meta
		}],
		"_meta": meta
	})

func _parse_result_resource_uri(uri: String) -> Dictionary:
	if not uri.begins_with(RESULT_RESOURCE_URI_PREFIX):
		return {"error": "Unsupported result resource URI"}
	var suffix: String = uri.trim_prefix(RESULT_RESOURCE_URI_PREFIX)
	var query_at: int = suffix.find("?")
	var handle: String = suffix if query_at < 0 else suffix.substr(0, query_at)
	if not _is_valid_result_handle(handle):
		return {"error": "Invalid result resource handle"}
	var cursor: int = 0
	if query_at >= 0:
		var query: String = suffix.substr(query_at + 1)
		if query.is_empty():
			return {"error": "Empty result resource query"}
		var cursor_seen: bool = false
		for pair_value in query.split("&", false):
			var pair: String = String(pair_value)
			var parts: PackedStringArray = pair.split("=", true, 1)
			if parts.size() != 2 or parts[0] != "cursor" or cursor_seen:
				return {"error": "Only one cursor query parameter is supported"}
			var cursor_text: String = parts[1]
			if not cursor_text.is_valid_int():
				return {"error": "Result cursor must be an integer"}
			cursor = int(cursor_text)
			cursor_seen = true
	return {"handle": handle, "cursor": cursor}

static func _is_valid_result_handle(handle: String) -> bool:
	if handle.length() != RESULT_RESOURCE_HANDLE_LENGTH:
		return false
	for index in range(handle.length()):
		var code: int = handle.unicode_at(index)
		if not (code >= 48 and code <= 57) and not (code >= 97 and code <= 102):
			return false
	return true

# ============================================================================
# 配置方法
# ============================================================================

func set_log_level(level: int) -> void:
	_log_level = level
	_log_info("Log level set to: " + str(level))

func set_security_level(level: int) -> void:
	_security_level = level
	_log_info("Security level set to: " + str(level))

func get_security_level() -> int:
	return _security_level

func set_rate_limit(limit: int) -> void:
	_rate_limit = limit
	_log_info("Rate limit set to: " + str(limit) + " requests/minute")

# ============================================================================
# 日志方法（根据godot-dev-guide优化）
# ============================================================================

func _log_error(message: String) -> void:
	if _log_level >= MCPTypes.LogLevel.ERROR:
		call_deferred("emit_signal", "log_message", "ERROR", message)

func _log_warn(message: String) -> void:
	if _log_level >= MCPTypes.LogLevel.WARN:
		call_deferred("emit_signal", "log_message", "WARN", message)

func _log_info(message: String) -> void:
	if _log_level >= MCPTypes.LogLevel.INFO:
		call_deferred("emit_signal", "log_message", "INFO", message)

func _log_debug(message: String) -> void:
	if _log_level >= MCPTypes.LogLevel.DEBUG:
		call_deferred("emit_signal", "log_message", "DEBUG", message)

## True when DEBUG logging is active. Guard expensive log-message construction
## (e.g. JSON.stringify of whole requests/responses) with this so it is skipped
## entirely at the default INFO level instead of being built then discarded.
func _debug_enabled() -> bool:
	return _log_level >= MCPTypes.LogLevel.DEBUG

# ============================================================================
# 清理
# ============================================================================

func cleanup() -> void:
	stop()

# ============================================================================
# 工具调用日志（用于批量验证）
# ============================================================================

var _tool_log_path: String = "user://mcp_tool_verification_log.json"

## In-memory log buffer to avoid per-call disk I/O.
var _tool_log_buffer: Array = []
## Maximum entries before auto-flushing to disk.
const TOOL_LOG_FLUSH_THRESHOLD: int = 20

func clear_tool_log() -> void:
	_tool_log_buffer.clear()
	var file: FileAccess = FileAccess.open(_tool_log_path, FileAccess.WRITE)
	if file:
		file.store_string("[]")
		file.close()

## Flush buffered tool log entries to disk.
func flush_tool_log() -> void:
	if _tool_log_buffer.is_empty():
		return
	var existing: Array = []
	if FileAccess.file_exists(_tool_log_path):
		var file: FileAccess = FileAccess.open(_tool_log_path, FileAccess.READ)
		if file:
			var json: JSON = JSON.new()
			if json.parse(file.get_as_text()) == OK:
				existing = json.get_data()
			file.close()
	existing.append_array(_tool_log_buffer)
	_tool_log_buffer.clear()
	var file: FileAccess = FileAccess.open(_tool_log_path, FileAccess.WRITE)
	if file:
		file.store_string(JSON.stringify(existing, "\t"))
		file.close()


# ============================================================================
# 传输层日志转发
# ============================================================================

## 传输层日志回调，将 printerr 替换为通过核心日志系统输出
## @param level: String - 日志级别（ERROR/WARN/INFO/DEBUG）
## @param message: String - 日志消息
func _log_transport_message(level: String, message: String) -> void:
	match level:
		"ERROR":
			_log_error(message)
		"WARN":
			_log_warn(message)
		"INFO":
			_log_info(message)
		"DEBUG":
			_log_debug(message)
		_:
			_log_info(message)

func _append_tool_log(tool_name: String, result: Variant, error: String) -> void:
	var log_entry: Dictionary = {
		"tool": tool_name,
		"timestamp": Time.get_unix_time_from_system(),
		"error": error,
		"result_type": str(typeof(result))
	}
	if result is Dictionary:
		if result.has("error"):
			log_entry["status"] = "error"
			log_entry["error_detail"] = str(result["error"])
		elif result.has("status"):
			log_entry["status"] = str(result["status"])
		else:
			log_entry["status"] = "ok"
		var result_keys: Array = result.keys()
		log_entry["result_keys"] = result_keys
		for key in result_keys:
			var val: Variant = result[key]
			if val is Array:
				log_entry["result_" + key + "_count"] = val.size()
			elif val is Dictionary:
				log_entry["result_" + key + "_keys"] = val.keys()
			else:
				var val_str: String = str(val)
				if val_str.length() > 200:
					val_str = val_str.substr(0, 200)
				log_entry["result_" + key] = val_str
	else:
		log_entry["status"] = "ok"
		var preview: String = str(result)
		if preview.length() > 200:
			preview = preview.substr(0, 200)
		log_entry["result_preview"] = preview

	# Buffer in memory; auto-flush when threshold reached.
	_tool_log_buffer.append(log_entry)
	if _tool_log_buffer.size() >= TOOL_LOG_FLUSH_THRESHOLD:
		flush_tool_log()
