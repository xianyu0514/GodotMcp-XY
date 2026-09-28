extends "res://addons/gut/test.gd"

# custom tools API：第三方注册表 + custom_manage + server 挂载链路。
# static 注册表必须测试间清零（泄漏会污染其他测试的目录计数断言）。

const RegistryScript = preload("res://addons/godot_mcp/tools/custom_tools_registry.gd")
const ServerCoreScript = preload("res://addons/godot_mcp/native_mcp/mcp_server_core.gd")
const MetaToolsScript = preload("res://addons/godot_mcp/tools/meta_tools_native.gd")

var _received_params: Dictionary = {}
var _handler_calls: int = 0

func _handler(params: Dictionary) -> Dictionary:
	_handler_calls += 1
	_received_params = params
	return {"status": "ok", "echo": params.get("value", null)}

func before_each() -> void:
	_received_params = {}
	_handler_calls = 0
	_reset_registry()

func after_each() -> void:
	_reset_registry()

func _reset_registry() -> void:
	RegistryScript._registered.clear()
	RegistryScript._applied_cores.clear()
	if Engine.has_meta("GodotMCPCustomTools"):
		Engine.remove_meta("GodotMCPCustomTools")

# --- 注册契约 ---

func test_register_requires_custom_prefix():
	var result: Dictionary = RegistryScript.register_tool(
		"terrain_sculpt", "Sculpt terrain.", {"type": "object"}, Callable(self, "_handler"))
	assert_true(result.has("error"), "裸名必须被命名空间契约拒绝")
	assert_true(str(result["error"]).contains("custom_"))

func test_empty_description_and_dead_callable_rejected():
	assert_true(RegistryScript.register_tool("custom_x", "  ", {}, Callable(self, "_handler")).has("error"))
	var victim: Node = Node.new()
	var dead: Callable = Callable(victim, "get_name")
	victim.free()
	assert_true(RegistryScript.register_tool("custom_x", "desc", {}, dead).has("error"),
		"失效 callable 必须在注册时被拒")

func test_register_and_list_roundtrip():
	var result: Dictionary = RegistryScript.register_tool(
		"custom_terrain_sculpt", "Sculpt the heightmap terrain.",
		{"type": "object", "properties": {"radius": {"type": "integer"}}},
		Callable(self, "_handler"))
	assert_true(result.has("ok"), str(result))
	var listed: Array = RegistryScript.list_registered()
	assert_eq(listed.size(), 1)
	assert_eq(String(listed[0]["name"]), "custom_terrain_sculpt")
	assert_true(String(listed[0]["description"]).contains("heightmap"))
	assert_true(bool(listed[0]["handler_valid"]))
	assert_true((listed[0]["input_schema"] as Dictionary).get("properties", {}).has("radius"))

func test_reregister_replaces_and_unregister_removes():
	RegistryScript.register_tool("custom_a", "first", {}, Callable(self, "_handler"))
	RegistryScript.register_tool("custom_a", "second", {}, Callable(self, "_handler"))
	assert_eq(RegistryScript.count(), 1, "同名重注册=替换不是追加")
	assert_true(str(RegistryScript.list_registered()[0]["description"]).contains("second"))
	var removed: Dictionary = RegistryScript.unregister_tool("custom_a")
	assert_true(bool(removed["existed"]))
	assert_eq(RegistryScript.count(), 0)
	assert_true(RegistryScript.unregister_tool("custom_a")["ok"], "未知名注销幂等")

# --- 调度与失效安全 ---

func test_dispatch_routes_params_and_collects_result():
	RegistryScript.register_tool("custom_echo", "Echo.", {}, Callable(self, "_handler"))
	var result: Dictionary = RegistryScript._dispatch({"value": 42}, "custom_echo")
	assert_eq(_handler_calls, 1)
	assert_eq(_received_params.get("value"), 42, "参数必须透传给注册方")
	assert_eq(int(result["echo"]), 42, "返回值必须原样回传")

func test_dead_handler_returns_self_healing_error():
	var owner: Node = Node.new()
	owner.set_script(null)
	# 用一个真实可调方法注册，然后 free owner 模拟注册方插件被重载/卸载。
	RegistryScript.register_tool("custom_doomed", "Doomed.", {}, Callable(self, "_handler"))
	# 直接替换为持有外部对象的 callable
	var victim: Node = Node.new()
	RegistryScript._registered["custom_doomed"]["callable"] = Callable(victim, "get_name")
	victim.free()
	var result: Dictionary = RegistryScript._dispatch({}, "custom_doomed")
	assert_true(result.has("error"), "失效 handler 必须返回错误而不是崩溃")
	assert_true(str(result["error"]).contains("re-register"), "错误须给出重注册自愈指引")

func test_dispatch_unknown_tool_self_heals():
	var result: Dictionary = RegistryScript._dispatch({}, "custom_ghost")
	assert_true(result.has("error"))
	assert_true(str(result["error"]).contains("custom_manage"), "未注册工具须指向发现入口")

# --- server 挂载链路（真 core）---

func test_apply_to_core_registers_into_catalog() -> void:
	var core: RefCounted = ServerCoreScript.new()
	RegistryScript.register_tool("custom_probe", "Probe.", {"type": "object"}, Callable(self, "_handler"))
	RegistryScript.apply_to(core)
	assert_true(core.has_tool("custom_probe"), "apply_to 后工具进入 server 注册表")
	var tool = core.get_tool("custom_probe")
	assert_eq(String(tool.category), "supplementary", "custom 工具类别锁定 supplementary（默认禁用）")
	assert_eq(String(tool.group), "Custom")
	assert_true(String(tool.description).contains("[custom tool"), "描述须带第三方来源标记")
	assert_false(tool.enabled, "custom 工具默认禁用，走 enable_tools 显式启用")
	# 经 core 的工具调用通道走 dispatcher
	core.set_tool_enabled("custom_probe", true)
	var call_result: Dictionary = await core._handle_tool_call({
		"id": 1, "params": {"name": "custom_probe", "arguments": {"value": 7}}})
	assert_false(Engine.has_meta("GodotMCPCustomTools"),
		"apply_to（可能在类注册阶段执行）不得触碰 Engine.set_meta")

func test_register_after_apply_reaches_live_core():
	var core: RefCounted = ServerCoreScript.new()
	RegistryScript.apply_to(core)
	RegistryScript.register_tool("custom_late", "Late.", {}, Callable(self, "_handler"))
	assert_true(core.has_tool("custom_late"), "server 运行中注册须即时生效（第三方 _ready 场景）")

func test_engine_meta_channel_attaches_late() -> void:
	# meta 挂载必须在运行期（server_started 回调）而非 apply_to：
	# 类注册阶段的 set_meta 实测段错误（CI 导入门禁 3/3）。
	var core: RefCounted = ServerCoreScript.new()
	RegistryScript.register_tool("custom_meta_probe", "Probe.", {}, Callable(self, "_handler"))
	RegistryScript.apply_to(core)
	RegistryScript.attach_engine_meta()
	assert_true(Engine.has_meta("GodotMCPCustomTools"), "运行期显式挂载后弱依赖通道就位")
	var proxy: Object = Engine.get_meta("GodotMCPCustomTools")
	var via_proxy: Dictionary = proxy.register_tool(
		"custom_via_proxy", "Registered via the weak-dependency channel.", {}, Callable(self, "_handler"))
	assert_true(via_proxy.has("ok"), "proxy 实例上的静态调用必须可用: " + str(via_proxy))

# --- custom_manage 工具 ---

func test_custom_manage_list_inspect_and_hints():
	var meta_tools: RefCounted = MetaToolsScript.new()
	var empty: Dictionary = meta_tools._tool_custom_manage({})
	assert_eq(int(empty["count"]), 0)
	assert_true(str(empty.get("hint", "")).contains("register_tool"), "空态须给出注册指引")

	RegistryScript.register_tool("custom_shiny", "Shiny tool.", {"type": "object"}, Callable(self, "_handler"))
	var listed: Dictionary = meta_tools._tool_custom_manage({"op": "list"})
	assert_eq(int(listed["count"]), 1)
	assert_eq(String((listed["tools"] as Array)[0]["name"]), "custom_shiny")

	var inspected: Dictionary = meta_tools._tool_custom_manage({"op": "inspect", "name": "custom_shiny"})
	assert_eq(String(inspected["name"]), "custom_shiny")
	assert_true(inspected.has("input_schema"))

	var missing: Dictionary = meta_tools._tool_custom_manage({"op": "inspect", "name": "custom_none"})
	assert_true(missing.has("error"))
	assert_true(str(missing["error"]).contains("op=list"), "未知名须指向发现入口")
