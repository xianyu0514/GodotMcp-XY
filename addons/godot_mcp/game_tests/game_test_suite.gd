@tool
class_name McpGameTestSuite
extends RefCounted

## 面向用户游戏的行为测试基类（插件自带，零外部依赖）。
##
## AI 客户端或开发者在 res://tests/ 下编写继承本类的套件，用 run_game_tests
## 在真实引擎（headless 子进程）里执行：实例化游戏场景、逐帧推进、模拟输入、
## 断言节点状态——把"游戏应该怎样表现"变成可重复回归的引擎侧证据。
## 这是目标语义门禁的基础设施：completed 不再只证明"没有报错"，
## 而能证明"目标描述的行为真的发生了"。
##
## 约定：
##   - 每个以 test_ 开头的方法是一个测试（可以是协程，用 await 推进帧）。
##   - before_all/after_all 每套件执行一次；before_each/after_each 每测试一次。
##   - 断言失败不中断当前测试：失败信息汇总进结果（check_* 返回是否通过，
##     需要短路时用返回值自行 return）。
##   - _tree 由运行器注入；load_scene 会把游戏场景挂到根节点下，
##     每个测试结束后运行器自动清理。

var _tree: SceneTree = null
var _failures: Array[String] = []
var _check_count: int = 0
var _current_test: String = ""
var _spawned_roots: Array[Node] = []


## ------------------------------------------------------------------ 生命周期
## 子类按需覆盖。
func before_all() -> void:
	pass


func after_all() -> void:
	pass


func before_each() -> void:
	pass


func after_each() -> void:
	pass


## ------------------------------------------------------------------ 断言
func check(condition: bool, message: String = "") -> bool:
	_check_count += 1
	if condition:
		return true
	_failures.append(_message_or(message, "expected a true condition"))
	return false


func check_eq(actual: Variant, expected: Variant, message: String = "") -> bool:
	_check_count += 1
	if actual == expected:
		return true
	_failures.append(_message_or(message, "expected %s, got %s" % [str(expected), str(actual)]))
	return false


func check_ne(actual: Variant, unexpected: Variant, message: String = "") -> bool:
	_check_count += 1
	if actual != unexpected:
		return true
	_failures.append(_message_or(message, "expected anything but %s" % str(unexpected)))
	return false


func check_gt(actual: Variant, expected: Variant, message: String = "") -> bool:
	_check_count += 1
	if actual > expected:
		return true
	_failures.append(_message_or(message, "expected a value > %s, got %s" % [str(expected), str(actual)]))
	return false


func check_lt(actual: Variant, expected: Variant, message: String = "") -> bool:
	_check_count += 1
	if actual < expected:
		return true
	_failures.append(_message_or(message, "expected a value < %s, got %s" % [str(expected), str(actual)]))
	return false


func check_not_null(value: Variant, message: String = "") -> bool:
	_check_count += 1
	if value != null:
		return true
	_failures.append(_message_or(message, "expected a non-null value"))
	return false


func check_is_null(value: Variant, message: String = "") -> bool:
	_check_count += 1
	if value == null:
		return true
	_failures.append(_message_or(message, "expected null, got %s" % str(value)))
	return false


func fail(message: String) -> void:
	_check_count += 1
	_failures.append(_message_or(message, "explicit failure"))


## ------------------------------------------------------------------ 帧推进
## 推进 count 个渲染帧（触发 _process 与场景树常规更新）。
func step_frames(count: int = 1) -> void:
	if _tree == null:
		return
	for i in range(maxi(1, count)):
		await _tree.process_frame


## 推进 count 个物理帧（触发 _physics_process；移动类控制器依赖这里）。
func step_physics_frames(count: int = 1) -> void:
	if _tree == null:
		return
	for i in range(maxi(1, count)):
		await _tree.physics_frame


## 轮询等待条件成立；超时返回 false（配合 check 使用）。
func wait_until(predicate: Callable, timeout_ms: int = 2000, poll_frames: int = 5) -> bool:
	if _tree == null:
		return bool(predicate.call())
	var deadline_ms: int = Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline_ms:
		if bool(predicate.call()):
			return true
		await step_frames(poll_frames)
	return bool(predicate.call())


## ------------------------------------------------------------------ 场景辅助
## 实例化一个游戏场景并挂到根节点下（每个测试独立实例，结束自动清理）。
func load_scene(scene_path: String) -> Node:
	var packed: PackedScene = load(scene_path) as PackedScene
	if packed == null:
		fail("cannot load scene: %s" % scene_path)
		return null
	var root_node: Node = packed.instantiate()
	if root_node == null:
		fail("cannot instantiate scene: %s" % scene_path)
		return null
	if _tree != null:
		_tree.root.add_child(root_node)
	_spawned_roots.append(root_node)
	return root_node


## 场景树根（游戏世界所有节点的父级）。
func world_root() -> Node:
	return null if _tree == null else _tree.root


## 按绝对路径查找节点（例如 /root/MainScene/Player）。
func find_node(abs_path: String) -> Node:
	if world_root() == null:
		return null
	return world_root().get_node_or_null(abs_path)


## ------------------------------------------------------------------ 输入模拟
func press_action(action_name: String) -> void:
	Input.action_press(action_name)


func release_action(action_name: String) -> void:
	Input.action_release(action_name)


## 按住一个动作若干渲染帧后释放（协程）。
func hold_action(action_name: String, hold_frame_count: int = 10) -> void:
	press_action(action_name)
	await step_frames(hold_frame_count)
	release_action(action_name)


## ------------------------------------------------------------------ 运行器内部
func _reset_for_test(test_name: String) -> void:
	_current_test = test_name
	_failures.clear()
	_check_count = 0


func _cleanup_spawned() -> void:
	for node in _spawned_roots:
		if is_instance_valid(node):
			node.queue_free()
	_spawned_roots.clear()


func _message_or(message: String, fallback: String) -> String:
	var prefix: String = "" if _current_test.is_empty() else _current_test + ": "
	return prefix + (message if not message.is_empty() else fallback)
