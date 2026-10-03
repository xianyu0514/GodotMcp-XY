extends RefCounted

## 逐模块分帧注册工具模块（启动性能优化）。经 preload 引用（与
## cache_revision_index.gd 等支持文件一致，不依赖全局类缓存）。
##
## 实测基线：21 个工具模块同步 load 共 ~1.7s，其中 99% 是 GDScript 编译成本
## （最大的单模块 456ms），注册逻辑本身仅 ~13ms——同步执行会把编辑器启动
## 冻结 1.7s。本 runner 每注册一个模块让出一帧，把编译成本摊平到启动后的
## 帧循环里；依赖注册完成的后续步骤由 on_complete 回调续跑。
##
## 依赖注入（而非直接引用插件）使其可在无编辑器进程的测试中运行：
##   - paths: module_name -> 脚本 res:// 路径
##   - register_module: (module_name: String, instance: Variant) -> void
##   - should_abort: () -> bool —— 每轮开头检查（插件退出/服务器已释放时终止）
##   - frame_wait: 每模块之间等待一帧的方式（默认 process_frame；测试注入
##     计数 Callable 即可瞬时验证分帧时序）

var paths: Dictionary = {}
var register_module: Callable = Callable()
var should_abort: Callable = Callable()
var frame_wait: Callable = Callable()
## true 时不让出帧、一次性同步注册完（--mcp-server 无头服务器模式：
## 可服务性优先，端口必须在集成测试的等待窗口内就绪；编辑器交互模式
## 保持默认 false 的分帧编译）。on_complete 仍会在注册完成后回调。
var synchronous: bool = false

## 每个模块一帧（默认实现；frame_wait 注入时被替换）。
var _default_frame_wait: Callable = Callable()


func _init() -> void:
	_default_frame_wait = func() -> void:
		var main_loop: SceneTree = Engine.get_main_loop() as SceneTree
		if main_loop:
			await main_loop.process_frame


## 加载并注册全部模块；返回 true 表示完整跑完（false = 中途 abort）。
## 加载失败的模块跳过并经 register_module 传 null，由宿主决定如何记日志。
func run(on_complete: Callable = Callable()) -> bool:
	for module_name in paths.keys():
		if should_abort.is_valid() and bool(should_abort.call()):
			return false
		var instance: Variant = null
		# 与插件原 _instantiate_script 相同的加载语义（热重载后强制替换缓存）；
		# 先查文件存在性，缺失的模块直接以 null 通知宿主，避免引擎 ERROR 噪声。
		var module_path: String = str(paths[module_name])
		if FileAccess.file_exists(module_path):
			var script: Script = ResourceLoader.load(module_path, "",
				ResourceLoader.CACHE_MODE_REPLACE)
			if script:
				instance = script.new()
		if register_module.is_valid():
			register_module.call(str(module_name), instance)
		if synchronous:
			pass
		elif frame_wait.is_valid():
			await frame_wait.call()
		else:
			await _default_frame_wait.call()
	if on_complete.is_valid():
		on_complete.call()
	return true
