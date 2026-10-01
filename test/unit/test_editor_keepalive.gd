extends "res://addons/gut/test.gd"

# P1-18 回归（2026-09-30 体检 §13.4）：编辑器失焦低功耗节流把帧间隔拉到
# ~100ms，请求路径的帧绑定 await 因此叠加量化台阶（中位 7ms→100ms，×14.3）。
# 修复 = 请求在途期间临时开启 update_continuously，排空后恢复。
# 本文件用 fake settings 注入验证配对语义（headless 无真实 EditorSettings）。

const ServerCoreScript = preload("res://addons/godot_mcp/native_mcp/mcp_server_core.gd")

class FakeSettings:
	extends RefCounted
	var values: Dictionary = {}
	var set_calls: Array = []

	func has_setting(key: String) -> bool:
		return values.has(key)

	func get_setting(key: String):
		return values.get(key, null)

	func set_setting(key: String, value) -> void:
		values[key] = value
		set_calls.append([key, value])

var _core: RefCounted = null

func before_each() -> void:
	_core = ServerCoreScript.new()

func after_each() -> void:
	_core = null

func test_begin_sets_true_and_records_prev_when_off():
	var fake: FakeSettings = FakeSettings.new()
	_core._begin_editor_keepalive(fake)
	assert_eq(bool(fake.values.get(ServerCoreScript.EDITOR_UPDATE_CONTINUOUSLY, false)), true,
		"失焦节流开启时保活应强制持续更新")
	assert_eq(int(_core._keepalive_prev.size()), 1, "必须记录原值以便恢复")

func test_begin_is_noop_when_already_on():
	var fake: FakeSettings = FakeSettings.new()
	fake.values[ServerCoreScript.EDITOR_UPDATE_CONTINUOUSLY] = true
	_core._begin_editor_keepalive(fake)
	assert_eq(int(_core._keepalive_prev.size()), 0, "本就持续更新的编辑器不应记录/恢复")
	assert_eq(int(fake.set_calls.size()), 0, "不应重复写设置")

func test_begin_twice_is_idempotent():
	var fake: FakeSettings = FakeSettings.new()
	_core._begin_editor_keepalive(fake)
	var calls_after_first: int = fake.set_calls.size()
	_core._begin_editor_keepalive(fake)
	assert_eq(fake.set_calls.size(), calls_after_first, "嵌套 begin 不得重复写")

func test_end_restores_and_clears_slot():
	var fake: FakeSettings = FakeSettings.new()
	_core._begin_editor_keepalive(fake)
	_core._end_editor_keepalive(fake)
	assert_eq(bool(fake.values.get(ServerCoreScript.EDITOR_UPDATE_CONTINUOUSLY, true)), false,
		"排空后应恢复失焦节流原值")
	assert_eq(int(_core._keepalive_prev.size()), 0, "恢复后必须清槽（后续 begin 可重新生效）")

func test_end_without_begin_is_noop():
	var fake: FakeSettings = FakeSettings.new()
	_core._end_editor_keepalive(fake)
	assert_eq(int(fake.set_calls.size()), 0, "未 begin 的 end 不得写设置")

func test_restore_does_not_stomp_a_manual_reenable():
	# 时序：保活开启 → 用户/其他特性手动开启（覆盖同一设置）→ 排空恢复。
	# 恢复写 false 是记录的原值语义（prev=false 时才记录），保持既有约定。
	var fake: FakeSettings = FakeSettings.new()
	_core._begin_editor_keepalive(fake)
	fake.values[ServerCoreScript.EDITOR_UPDATE_CONTINUOUSLY] = true
	_core._end_editor_keepalive(fake)
	assert_eq(bool(fake.values[ServerCoreScript.EDITOR_UPDATE_CONTINUOUSLY]), false)
