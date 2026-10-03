extends "res://addons/gut/test.gd"

# 分帧工具注册的启动性能优化回归测试。
#
# EditorPlugin 是虚类，无法在 GUT CLI 进程实例化，因此运行时行为测试落在
# MCPToolRegistrationRunner（RefCounted，依赖注入可测）；插件侧接线（_enter_tree
# 调用顺序、完成回调续跑、启动排队守卫）沿用仓库既有源码断言风格。
#
# 实测依据：21 个工具模块同步 load 共 ~1.7s，其中 99% 是 GDScript 编译成本，
# 注册逻辑仅 ~13ms——分帧后编辑器启动不再被冻结。

const RUNNER_SCRIPT = preload("res://addons/godot_mcp/tools/tool_registration_runner.gd")
const PLUGIN_SCRIPT = preload("res://addons/godot_mcp/mcp_server_native.gd")

const MODULE_A := "res://test/unit/fixtures/runner_module_a.gd"
const MODULE_B := "res://test/unit/fixtures/runner_module_b.gd"


func _make_runner(paths: Dictionary) -> RefCounted:
	var runner: RefCounted = RUNNER_SCRIPT.new()
	runner.paths = paths
	return runner


func _counting_frame_wait(counter: Array) -> Callable:
	return func() -> void:
		counter[0] += 1


func test_runner_registers_every_module_in_order() -> void:
	var registered: Array = []
	var runner: RefCounted = _make_runner({"alpha": MODULE_A, "beta": MODULE_B})
	runner.register_module = func(module_name: String, instance: Variant) -> void:
		assert_ne(instance, null, "Fixture module must instantiate")
		registered.append(module_name)
	var completed: bool = await runner.run()
	assert_true(completed, "Runner should report full completion")
	assert_eq(registered, ["alpha", "beta"], "Modules register in declaration order")


func test_runner_yields_one_frame_between_modules() -> void:
	var frame_count: Array = [0]
	var runner: RefCounted = _make_runner({
		"alpha": MODULE_A, "beta": MODULE_B, "gamma": MODULE_A})
	runner.register_module = func(_module_name: String, _instance: Variant) -> void:
		pass
	runner.frame_wait = _counting_frame_wait(frame_count)
	await runner.run()
	# 每个模块之后各让出一帧——这正是把 ~1.7s 编译成本摊平到帧循环的机制。
	assert_eq(int(frame_count[0]), 3, "One frame yield per registered module")


func test_runner_aborts_without_completion_callback() -> void:
	var registered: Array = []
	var completed_callback: Array = [false]
	var runner: RefCounted = _make_runner({"alpha": MODULE_A, "beta": MODULE_B})
	runner.register_module = func(module_name: String, _instance: Variant) -> void:
		registered.append(module_name)
	runner.should_abort = func() -> bool:
		return registered.size() >= 1  # 首个模块注册后模拟插件退出
	var completed: bool = await runner.run(func() -> void:
		completed_callback[0] = true)
	assert_false(completed, "Aborted run must not report completion")
	assert_eq(registered, ["alpha"], "Run stops at the abort check")
	assert_false(completed_callback[0], "Completion callback must not fire after abort")


func test_runner_reports_missing_script_to_host() -> void:
	var failures: Array = []
	var runner: RefCounted = _make_runner({"ghost": "res://test/unit/fixtures/does_not_exist.gd"})
	runner.register_module = func(module_name: String, instance: Variant) -> void:
		if instance == null:
			failures.append(module_name)
	var completed: bool = await runner.run()
	assert_true(completed, "A missing module must not abort the remaining registration")
	assert_eq(failures, ["ghost"], "Host receives null instance for missing scripts")


func test_plugin_wires_deferred_registration_and_start_queue() -> void:
	# 插件接线源码契约（EditorPlugin 不可实例化，与既有源码断言风格一致）。
	var plugin_source: GDScript = PLUGIN_SCRIPT
	var source_code: String = plugin_source.source_code
	assert_true(source_code.contains("_register_all_tools_async(_on_all_tools_registered)"),
		"_register_all_tools should start the deferred coroutine with the completion callback")
	assert_true(source_code.contains("if not _tools_registration_complete:"),
		"_start_native_server must queue while registration is incomplete")
	assert_true(source_code.contains("_pending_start = true"),
		"Queued start flag must be set when registration is incomplete")
	assert_true(source_code.contains("var completed: bool = await runner.run(on_complete)"),
		"Plugin must await the runner and gate the completion flag on it")
	assert_true(source_code.contains("_maybe_auto_start_server()"),
		"Completion callback must run the auto-start decision")


func test_synchronous_registration_completes_without_frames() -> void:
	# --mcp-server 无头服务器模式：可服务性优先，注册同步跑完、回调同步触发
	# （集成测试在端口等待窗口内就期望 9080 可连；分帧会把启动推迟到全部
	# 模块编译后，实测整批 "Timed out waiting for MCP server on port 9080"）。
	var plugin: EditorPlugin = _make_plugin()
	autofree(plugin)
	var callback_fired: Array = [false]
	var done: Callable = func() -> void:
		callback_fired[0] = true
	# 同步调用（无 await 挂起点）：返回时必须已完成。
	plugin._register_all_tools_async(done, true)
	assert_eq(plugin._native_server.get_tools_count(), TOTAL_TOOLS,
		"Synchronous registration must complete before returning")
	assert_true(plugin._tools_registration_complete, "Completion flag set synchronously")
	assert_true(callback_fired[0], "Completion callback fired synchronously")


func test_server_mode_wires_synchronous_registration() -> void:
	# 源码契约：--mcp-server 参数走同步注册，编辑器交互模式保持分帧。
	var plugin_source: GDScript = PLUGIN_SCRIPT
	var source_code: String = plugin_source.source_code
	assert_true(source_code.contains('if "--mcp-server" in OS.get_cmdline_user_args():'),
		"Server mode must take the synchronous registration branch")
	assert_true(source_code.contains("_register_all_tools(true)"),
		"Server mode must pass synchronous=true")
