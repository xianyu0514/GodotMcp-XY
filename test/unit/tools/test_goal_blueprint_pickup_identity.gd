extends "res://addons/gut/test.gd"

## P0-3 金币拾取身份修复测试（差距分析复现的回归测试）：
## 多金币场景依次触发每枚 body_entered——每枚恰好释放一次、计数准确、
## 胜利触达；重复触发已释放的道具不得虚增计数（一次性守卫）。
## 同时覆盖：数量解析加宽、敌人计数参数化、金币聚簇几何、COIN_RADIUS。

const BlueprintsScript = preload("res://addons/godot_mcp/native_mcp/goal_blueprints.gd")

## 插件项目本身没有 move_* 输入动作（工作流会在目标项目里 upsert）——
## 运行级测试先注册四个动作，避免 _physics_process 每帧报
## "action doesn't exist"（GUT 会把引擎错误记为 Unexpected Errors）。
func _register_movement_actions() -> void:
	for action_name in ["move_left", "move_right", "move_up", "move_down"]:
		if not InputMap.has_action(action_name):
			InputMap.add_action(action_name)
			InputMap.action_add_event(action_name, InputEventKey.new())

func test_coin_count_parses_numbers_with_modifiers() -> void:
	assert_eq(BlueprintsScript._coin_count("Add 3 collectible coins."), 3,
		"'3 collectible coins' keeps the 3 (old regex swallowed it to 1)")
	assert_eq(BlueprintsScript._coin_count("再加 3 个金币"), 3, "Chinese count with 个")
	assert_eq(BlueprintsScript._coin_count("collect a coin"), 1, "no number defaults to 1")
	assert_eq(BlueprintsScript._coin_count("three coins"), 3, "English word number")
	assert_eq(BlueprintsScript._coin_count("win in 10 seconds"), 1,
		"unrelated numbers do not become coin counts")

func test_enemy_count_parses_numbers() -> void:
	assert_eq(BlueprintsScript._enemy_count("2 patrolling enemies"), 2)
	assert_eq(BlueprintsScript._enemy_count("两个敌人"), 2)
	assert_eq(BlueprintsScript._enemy_count("Add a patrolling enemy"), 1)

func test_additive_request_detection() -> void:
	assert_true(BlueprintsScript.is_additive_request("Add another patrolling enemy."),
		"'another' is additive (existing + 1)")
	assert_true(BlueprintsScript.is_additive_request("再加 3 个金币"), "'再加' is additive")
	assert_false(BlueprintsScript.is_additive_request("Add 3 collectible coins."),
		"a plain total request is not additive")

func test_multi_coin_source_has_identity_safe_pickup() -> void:
	var source: String = BlueprintsScript.controller_script("arrow-key movement, collect 3 coins, win label")
	assert_true(source.contains("const COINS_TO_WIN: int = 3"), "count flows into the constant")
	assert_true(source.contains("_on_coin_touched(body: Node, coin: Node)"),
		"handler carries the touched coin's identity")
	assert_true(source.contains("is_queued_for_deletion()"),
		"one-shot guard present")
	assert_true(source.contains("coin.queue_free()"),
		"the touched coin is freed, not the first coin member")
	assert_false(source.contains("_coin_area.queue_free()"),
		"the old free-the-first-coin bug is gone")
	assert_true(source.contains(".bind(extra_coin)"), "extra coins bind their own identity")
	assert_true(source.contains(".bind(_coin_area)"), "the first coin binds its identity")

func test_coins_cluster_before_the_enemy_band() -> void:
	var source: String = BlueprintsScript.controller_script("collect 3 coins with a patrolling enemy")
	assert_true(source.contains("Vector2(110.0, 0)"), "first coin at 110 (beyond the 98px spawn pickup range)")
	assert_true(source.contains("110.0 + coin_index * 40.0"), "extras cluster at +40 steps")
	# 聚簇上界：最后一枚（index 2）在 200，拾取窗最远 298 < 敌带下沿 220-16
	assert_false(source.contains("200 + coin_index * 180"),
		"old spread (200/380/560) put coins 2-3 inside the death band")

func test_enemy_count_constant_and_multi_enemies() -> void:
	var source: String = BlueprintsScript.controller_script("2 patrolling enemies kill the player")
	assert_true(source.contains("const ENEMY_COUNT: int = 2"), "enemy count constant")
	assert_true(source.contains("var _enemies: Array[Area2D] = []"), "enemy array member")
	assert_true(source.contains("Enemy%d\" % enemy_index"), "extras named Enemy1..N")
	assert_true(source.contains("for enemy_index in _enemies.size():"), "patrol updates every enemy")

func test_coin_radius_is_a_single_constant() -> void:
	var source: String = BlueprintsScript.controller_script("collect a coin")
	assert_true(source.contains("const COIN_RADIUS: float = 90.0"), "radius constant declared")
	assert_false(source.contains("radius = 90\n"), "no bare radius literals remain (tunable via one line)")

func test_runtime_multi_coin_pickup_identity() -> void:
	# 差距分析复现场景的运行级回归：三枚依次触发 → 各消失一次、
	# 计数到 3、胜利文案出现；重复触发已释放的道具不虚增计数。
	_register_movement_actions()
	var source: String = BlueprintsScript.controller_script("arrow-key movement, collect 3 coins, win label")
	var script: GDScript = GDScript.new()
	script.source_code = source
	assert_eq(script.reload(), OK, "generated source compiles")
	var player: CharacterBody2D = CharacterBody2D.new()
	player.set_script(script)
	var world: Node2D = Node2D.new()
	add_child(world)
	world.add_child(player)
	await get_tree().process_frame
	await get_tree().process_frame
	var coin_first: Area2D = world.get_node_or_null("Coin") as Area2D
	var coin_second: Area2D = world.get_node_or_null("Coin1") as Area2D
	var coin_third: Area2D = world.get_node_or_null("Coin2") as Area2D
	assert_not_null(coin_first, "first coin exists")
	assert_not_null(coin_second, "second coin exists")
	assert_not_null(coin_third, "third coin exists")
	# 依次触发每枚（信号直发，无需物理）；第二枚双发验证一次性守卫
	coin_first.body_entered.emit(player)
	coin_second.body_entered.emit(player)
	coin_second.body_entered.emit(player)
	coin_third.body_entered.emit(player)
	await get_tree().process_frame
	assert_eq(int(player.get("coins_collected")), 3,
		"each coin counted exactly once (double-fire did not inflate)")
	assert_false(is_instance_valid(coin_second), "the touched second coin is freed")
	assert_false(is_instance_valid(coin_third), "the touched third coin is freed")
	assert_eq(String((player.get("_win_label") as Label).text), "You Win!",
		"win label after the full collection")
	world.queue_free()

func test_runtime_respawn_recreates_clustered_coins() -> void:
	_register_movement_actions()
	var source: String = BlueprintsScript.controller_script(
		"title screen game flow restart with 3 coins")
	var script: GDScript = GDScript.new()
	script.source_code = source
	assert_eq(script.reload(), OK, "state+coins source compiles")
	var player: CharacterBody2D = CharacterBody2D.new()
	player.set_script(script)
	var world: Node2D = Node2D.new()
	add_child(world)
	world.add_child(player)
	await get_tree().process_frame
	await get_tree().process_frame
	# 模拟已全部收集后的重开路径：直接调用重生函数
	player.call("_respawn_coins")
	await get_tree().process_frame
	await get_tree().process_frame
	var respawned: int = 0
	for child in world.get_children():
		if String(child.name).begins_with("Coin"):
			respawned += 1
	assert_eq(respawned, 3, "restart respawns all three coins")
	assert_true(is_instance_valid(player.get("_coin_area") as Area2D),
		"the _coin_area member points at the fresh first coin")
	# 重生后的金币仍是身份安全的（bind 过）
	var fresh: Area2D = world.get_node_or_null("Coin2") as Area2D
	fresh.body_entered.emit(player)
	await get_tree().process_frame
	assert_false(is_instance_valid(fresh), "respawned coin frees itself on pickup")
	world.queue_free()
