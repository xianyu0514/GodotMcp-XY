@tool
class_name MCPCustomToolsRegistry
extends RefCounted

## 第三方工具注册表：让其他编辑器插件把自己的能力注册进 godot_mcp 的 MCP 面。
##
## 定位（对照 godot-ai 的 custom_* 生态）：251+ 内置工具是封闭集合，长尾需求
## （地形、DCC 管线、内部工具链）永远追不上——本注册表把工具面变成开放底座。
##
## 第三方接入（两种等价方式）：
##   1. 直接调用全局类：MCPCustomToolsRegistry.register_tool("custom_terrain_sculpt",
##      "Sculpt the heightmap terrain.", {"type": "object", "properties": {}},
##      Callable(self, "_on_sculpt"))
##   2. 弱依赖（不想 preload 插件路径时）：
##      if Engine.has_meta("GodotMCPCustomTools"):
##          Engine.get_meta("GodotMCPCustomTools").register_tool(...)
##      插件缺席时优雅降级（跳过注册即可）。
##
## 契约与护栏：
## - 工具名必须以 "custom_" 开头（命名空间，杜绝与内置工具冲突/伪装 core）。
## - category 固定为 "supplementary"、group 固定为 "Custom"：默认禁用、走既有
##   目录/搜索/enable_tools/预设机制，第三方无法把自己注册成 core/meta。
## - 注册的是 dispatcher 包装（Callable 绑定本表），注册方插件重载导致原
##   Callable 失效时，调用返回自愈报错而不是崩溃。
## - 重注册同名 = 替换（幂等，服务方插件重载场景）。
## - 信任边界：注册即编辑器内任意 GDScript 执行权——与安装任何 Godot 插件
##   同级信任，这不是沙箱边界（诚实声明，不假装是安全机制）。

const TOOL_PREFIX: String = "custom_"
const CATEGORY: String = "supplementary"
const GROUP: String = "Custom"

## name -> {"definition": {...}, "callable": Callable}
static var _registered: Dictionary = {}
## 已应用过注册的 server_core 弱引用（RefCounted 不能 weakref 强存导致永生；
## 用 Array 弱引用包一层，失效即重挂）。static var 在插件重载时重置——这正是
## 期望行为：重载后服务方重新走 _ready 注册，队列自然重建。
static var _applied_cores: Array = []


## 第三方注册入口。同名重注册 = 替换。返回 {"ok": true} 或 {"error": "..."}。
static func register_tool(tool_name: String, description: String,
		input_schema: Dictionary, handler: Callable,
		output_schema: Dictionary = {}) -> Dictionary:
	if not tool_name.begins_with(TOOL_PREFIX):
		return {"error": "Custom tool names must start with '%s' (namespace contract; got '%s')." % [TOOL_PREFIX, tool_name]}
	if tool_name.strip_edges() != tool_name or tool_name.is_empty():
		return {"error": "Custom tool name must be non-empty and trimmed."}
	if description.strip_edges().is_empty():
		return {"error": "Custom tool description must not be empty."}
	if not handler.is_valid():
		return {"error": "Custom tool handler callable is invalid (method missing or object freed)."}
	_registered[tool_name] = {
		"definition": {
			"name": tool_name,
			"description": description,
			"input_schema": input_schema if input_schema is Dictionary and not input_schema.is_empty() else {"type": "object", "properties": {}},
			"output_schema": output_schema,
		},
		"callable": handler,
	}
	_apply_one_to_cores(tool_name)
	return {"ok": true, "tool": tool_name, "registered": _registered.size()}


## 取消注册（服务方插件退出/禁用时）。未知名静默成功（幂等）。
static func unregister_tool(tool_name: String) -> Dictionary:
	var existed: bool = _registered.erase(tool_name)
	for core_ref in _applied_cores.duplicate():
		var core: RefCounted = core_ref.get_ref() if core_ref is WeakRef else core_ref
		if core == null:
			_applied_cores.erase(core_ref)
			continue
		if core.has_method("unregister_tool"):
			core.unregister_tool(tool_name)
	return {"ok": true, "existed": existed, "registered": _registered.size()}


## server 启动时全量挂载（mcp_server_native._start_native_server 调用）。
static func apply_to(server_core: RefCounted) -> void:
	if server_core == null:
		return
	var already: bool = false
	for core_ref in _applied_cores:
		var core: RefCounted = core_ref.get_ref() if core_ref is WeakRef else core_ref
		if core == server_core:
			already = true
			break
	if not already:
		_applied_cores.append(weakref(server_core))
	for tool_name in _registered:
		_apply_one(server_core, tool_name)
	# 引擎 meta 弱依赖通道不在此时挂载：apply_to 可能在引擎的
	# update_scripts_classes（全局类注册）阶段被执行（import 时插件
	# auto_start 路径），该阶段调 Engine.set_meta 实测触发引擎段错误
	# （exit 139，CI 导入门禁 3/3 复现）。改由 server_started 回调
	#（attach_engine_meta）在运行期挂载。


## 目录查询（custom_manage 的数据源）。
static func list_registered() -> Array:
	var out: Array = []
	for tool_name in _registered:
		var entry: Dictionary = _registered[tool_name]
		var definition: Dictionary = entry["definition"]
		out.append({
			"name": tool_name,
			"description": definition["description"],
			"input_schema": definition["input_schema"],
			"handler_valid": (entry["callable"] as Callable).is_valid(),
		})
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return String(a["name"]) < String(b["name"])
	)
	return out


static func count() -> int:
	return _registered.size()


## dispatcher：注册进 server_core 的是这个包装（绑定 tool_name），失效原
## callable 时返回自愈报错。参数序：call(arguments) 在前、bind(tool_name)
## 在后（Godot 4 bind 语义：绑定参数追加于调用参数之后）。
static func _dispatch(params: Dictionary, tool_name: String) -> Dictionary:
	var entry: Dictionary = _registered.get(tool_name, {})
	if entry.is_empty():
		return {"error": "Custom tool '%s' is not registered anymore (the providing addon may have been reloaded or disabled). Call custom_manage {\"op\": \"list\"} to see the current custom toolset." % tool_name}
	var handler: Callable = entry["callable"]
	if not handler.is_valid():
		return {"error": "Custom tool '%s' handler became invalid (the providing addon was reloaded or freed). The addon should re-register on its _ready; retry after that." % tool_name}
	return handler.call(params)


static func _apply_one_to_cores(tool_name: String) -> void:
	for core_ref in _applied_cores.duplicate():
		var core: RefCounted = core_ref.get_ref() if core_ref is WeakRef else core_ref
		if core == null:
			_applied_cores.erase(core_ref)
			continue
		_apply_one(core, tool_name)


static func _apply_one(server_core: RefCounted, tool_name: String) -> void:
	if not server_core.has_method("register_tool"):
		return
	var entry: Dictionary = _registered.get(tool_name, {})
	if entry.is_empty():
		return
	var definition: Dictionary = entry["definition"]
	# Callable 必须绑实例（实例上调用 static 方法合法）：Callable(类名, "static")
	# 在运行期 .call() 会报错使调用方协程中止（实测），绑哨兵实例则稳定。
	server_core.register_tool(
		definition["name"],
		definition["description"] + " [custom tool — provided by a third-party addon]",
		definition["input_schema"],
		Callable(_registry_proxy(), "_dispatch").bind(tool_name),
		definition["output_schema"],
		{"readOnlyHint": false, "destructiveHint": false, "idempotentHint": false, "openWorldHint": false},
		CATEGORY,
		GROUP
	)


## Engine meta 需要一个实例；静态上下文直接 `.new()` 会在引擎的
## update_scripts_classes（全局类注册）阶段自建实例，实测触发引擎段错误
## （exit 139，CI 导入门禁 3/3 复现）——必须惰性创建，运行期首次使用才实例化。
static func _registry_proxy() -> RefCounted:
	if _proxy_instance == null:
		_proxy_instance = MCPCustomToolsRegistry.new()
	return _proxy_instance


## 弱依赖通道挂载（运行期调用——server_started 回调），见 apply_to 内注释。
static func attach_engine_meta() -> void:
	Engine.set_meta("GodotMCPCustomTools", _registry_proxy())

static var _proxy_instance: RefCounted = null
