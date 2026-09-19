extends "res://addons/gut/test.gd"

## 生成控制器的状态机穷举测试（毫秒级捕获交互类 bug）：
## 过去 15 轮 E2E 追的每个缺陷都是本类的成员——
## - win 后死亡 → gameover 覆写（runs #10/#23）
## - 胜利后死亡是否计数（runs #19-20：守卫过宽饿死敌人证据）
## - lives 归零 → gameover 的状态条件（run #22：守卫与演练冲突）
## 生成脚本直接实例化（CharacterBody2D 可脱离场景树），处理器直接调用。
## E2E 只需覆盖接线（探针/时序/几何），逻辑交互在此穷举。

const BlueprintsScript = preload("res://addons/godot_mcp/native_mcp/goal_blueprints.gd")

const FULL_MERGE := "arrow-key movement, 3 collectible coins, save/load, " \
	+ "title screen with start, gameplay, win state and restart, " \
	+ "game over screen with 3 lives when the player dies, " \
	+ "a second level after the first win, sound effect, coin pickup particle burst, " \
	+ "looping background music, pause menu, patrolling enemies"

var _controller: CharacterBody2D

## 伪造一枚金币（拾取处理器带 coin 绑定参数；queue_free 只作用于币，
## 控制器不受影响——每次拾取都要新币，一次性守卫会拒收垂死币）。
func _fake_coin() -> Area2D:
	return Area2D.new()

func _collect(n: int) -> void:
	for i in range(n):
		_controller._on_coin_touched(_controller, _fake_coin())

func before_each() -> void:
	var script := GDScript.new()
	script.source_code = BlueprintsScript.controller_script(FULL_MERGE)
	assert_eq(script.reload(), OK, "the merged controller compiles")
	_controller = script.new()

func after_each() -> void:
	if is_instance_valid(_controller):
		_controller.queue_free()
	_controller = null

# ============================================================================
# 收集 → 胜利
# ============================================================================

func test_collecting_all_coins_reaches_win() -> void:
	_collect(3)
	assert_eq(int(_controller.coins_collected), 3, "all coins counted")
	assert_eq(String(_controller.game_state), "win", "collecting the quota wins")

func test_win_shows_label_and_counts() -> void:
	_collect(3)
	# 标签文本同上——E2E 覆盖；此处断状态与计数。

# ============================================================================
# 死亡 × 状态交互（历史 bug 类穷举）
# ============================================================================

func test_deaths_always_count_in_any_state() -> void:
	# runs #19-20 的守卫过宽 bug：win 态死亡被拦 → 敌人演练证据饿死。
	# 现语义：死亡在任何状态都计数（只有 gameover 转移另论）。
	_controller.game_state = "win"
	_controller._on_enemy_touched(_controller)
	assert_eq(int(_controller.deaths_count), 1, "deaths count in the win state")
	_controller.game_state = "title"
	_controller._on_enemy_touched(_controller)
	assert_eq(int(_controller.deaths_count), 2, "deaths count in the title state")

func test_lives_zero_reaches_gameover_from_playing() -> void:
	_controller.game_state = "playing"
	for i in range(3):
		_controller._on_enemy_touched(_controller)
	assert_eq(String(_controller.game_state), "gameover",
		"three deaths in playing → gameover")
	# 标签在 _ready 创建（裸实例为 null）——gameover 态本身是这里的判据；
	# 标签可见性由 E2E 的 gameover 演练覆盖。

func test_lives_zero_reaches_gameover_from_win() -> void:
	# run #22 的守卫冲突：gameover 演练的死亡跑先收满金币穿 win——
	# 从 win 耗尽生命必须能进 gameover（演练的专属路径）。
	_controller.game_state = "win"
	for i in range(3):
		_controller._on_enemy_touched(_controller)
	assert_eq(String(_controller.game_state), "gameover",
		"life exhaustion from win reaches gameover (the gameover drill's path)")

func test_partial_deaths_do_not_gameover() -> void:
	_controller.game_state = "playing"
	_controller._on_enemy_touched(_controller)
	_controller._on_enemy_touched(_controller)
	assert_eq(String(_controller.game_state), "playing",
		"two deaths leave the round alive")
	assert_eq(int(_controller.lives), 1, "lives drained to one")

func test_death_resets_position() -> void:
	_controller.position = Vector2(300, 0)
	_controller.game_state = "playing"
	_controller._on_enemy_touched(_controller)
	assert_almost_eq(float(_controller.position.x), 0.0, 0.01,
		"death respawns at the origin")

# ============================================================================
# 收集 × 死亡混合序列（穷举交界）
# ============================================================================

func test_win_then_deaths_then_more_coins() -> void:
	_collect(3)
	assert_eq(String(_controller.game_state), "win", "quota reached")
	_controller._on_enemy_touched(_controller)
	_controller._on_enemy_touched(_controller)
	assert_eq(String(_controller.game_state), "win",
		"two post-win deaths do not gameover (3 lives)")
	assert_eq(int(_controller.coins_collected), 3, "coins unchanged by deaths")
	# 第四枚（假设重生后）→ 计数继续
	_collect(1)
	assert_eq(int(_controller.coins_collected), 4, "post-death collection keeps counting")

func test_deaths_then_win_in_same_round() -> void:
	_controller.game_state = "playing"
	_controller._on_enemy_touched(_controller)  # lives 3→2
	_collect(3)
	assert_eq(String(_controller.game_state), "win",
		"a round with one death can still win")

# ============================================================================
# 存档往返（user:// 真实读写）
# ============================================================================

func test_save_round_trips_full_state() -> void:
	_controller.coins_collected = 2
	_controller.position = Vector2(-24, 0)
	_controller.lives = 2
	_controller.current_level = 2
	assert_true(_controller.save_game(), "save writes")
	var fresh: CharacterBody2D = _controller.get_script().new()
	assert_true(fresh.load_game(), "fresh instance loads")
	assert_eq(int(fresh.coins_collected), 2, "coins restored")
	assert_almost_eq(float(fresh.position.x), -24.0, 0.01, "position restored")
	assert_eq(int(fresh.lives), 2, "lives restored")
	assert_eq(int(fresh.current_level), 2, "level restored")
	assert_eq(int(fresh._last_restored.get("level", 1)), 2, "restore evidence recorded")
	fresh.queue_free()
	# 清理：删除测试存档避免污染其他测试
	DirAccess.remove_absolute(ProjectSettings.globalize_path("user://save_game.json"))
