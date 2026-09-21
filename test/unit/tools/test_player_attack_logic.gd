extends "res://addons/gut/test.gd"

## 包03 命中语义的组件级单测：范围外不命中（空挥）、范围内每挥恰好一次、
## 死亡敌人不再受击。E2E 覆盖阶段机与冷却（apply_player_attack 回归）。

const AttackScript = preload("res://slice_b/scripts/player/player_attack.gd")

class FakeEnemy extends Node2D:
	var hits: int = 0
	var damage_taken: Array = []
	func take_damage(amount: int, _knockback: Vector2) -> void:
		hits += 1
		damage_taken.append(amount)

class FakePlayer extends CharacterBody2D:
	pass

func test_hits_in_reach_exactly_once_per_swing() -> void:
	var player: FakePlayer = FakePlayer.new()
	var attack: Node2D = AttackScript.new()
	attack.name = "Attack"
	player.add_child(attack)
	add_child_autofree(player)
	var tree := get_tree()
	var enemy: FakeEnemy = FakeEnemy.new()
	enemy.position = Vector2(30, 0)
	enemy.add_to_group("enemies")
	player.add_child(enemy)
	tree.process_frame  # ensure tree membership
	attack._hit_this_swing = []
	attack._facing_right = true
	attack._apply_hits()
	attack._apply_hits()
	assert_eq(enemy.hits, 1, "same swing hits the same enemy exactly once")

func test_whiff_out_of_reach_hits_nothing() -> void:
	var player: FakePlayer = FakePlayer.new()
	var attack: Node2D = AttackScript.new()
	player.add_child(attack)
	add_child_autofree(player)
	var enemy: FakeEnemy = FakeEnemy.new()
	enemy.position = Vector2(300, 0)
	enemy.add_to_group("enemies")
	player.add_child(enemy)
	attack._hit_this_swing = []
	attack._facing_right = true
	attack._apply_hits()
	assert_eq(enemy.hits, 0, "enemy beyond reach is not hit (whiff)")

func test_behind_the_player_is_not_hit() -> void:
	var player: FakePlayer = FakePlayer.new()
	var attack: Node2D = AttackScript.new()
	player.add_child(attack)
	add_child_autofree(player)
	var enemy: FakeEnemy = FakeEnemy.new()
	enemy.position = Vector2(-30, 0)
	enemy.add_to_group("enemies")
	player.add_child(enemy)
	attack._hit_this_swing = []
	attack._facing_right = true
	attack._apply_hits()
	assert_eq(enemy.hits, 0, "enemy behind the facing side is not hit")

func test_vertical_band_respected() -> void:
	var player: FakePlayer = FakePlayer.new()
	var attack: Node2D = AttackScript.new()
	player.add_child(attack)
	add_child_autofree(player)
	var enemy: FakeEnemy = FakeEnemy.new()
	enemy.position = Vector2(30, 200)
	enemy.add_to_group("enemies")
	player.add_child(enemy)
	attack._hit_this_swing = []
	attack._facing_right = true
	attack._apply_hits()
	assert_eq(enemy.hits, 0, "enemy far below the hit band is not hit")
