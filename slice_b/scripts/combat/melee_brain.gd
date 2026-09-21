extends Node
## 近战敌人大脑（P1）：巡逻 → 警戒（进入发现范围）→ 追击 → 攻击前摇
## （预警色闪烁）→ 命中（一次判定）→ 恢复 → 回巡逻。受击/死亡走宿主的
## take_damage；死亡时掉落一枚硬币（恰好一次）。参数全部 @export。

@export var detect_range: float = 180.0
@export var chase_range: float = 320.0
@export var chase_speed: float = 140.0
@export var patrol_speed: float = 60.0
@export var attack_range: float = 46.0
@export var windup_seconds: float = 0.35
@export var hit_damage: int = 12
@export var hit_knockback: float = 260.0
@export var recover_seconds: float = 0.5
@export var attack_cooldown: float = 0.9

var _state: String = "patrol"
var _state_left: float = 0.0
var _cooldown_left: float = 0.0
var _direction: float = 1.0
var _origin_x: float = 0.0
var _hit_done: bool = false
var attacks_landed: int = 0
var drops_spawned: int = 0
var state_log: Array = []


func _ready() -> void:
	_origin_x = get_parent().global_position.x
	set_physics_process(true)


func state() -> String:
	return _state


func _physics_process(delta: float) -> void:
	var enemy: Node2D = get_parent()
	if not enemy is Area2D:
		return
	if _cooldown_left > 0.0:
		_cooldown_left = maxf(0.0, _cooldown_left - delta)
	match _state:
		"patrol":
			_patrol(delta, enemy)
		"chase":
			_chase(delta, enemy)
		"windup":
			_state_left -= delta
			enemy.global_position.x += _direction * 10.0 * delta
			if _state_left <= 0.0:
				_hit(enemy)
				_state = "recover"
				_state_left = recover_seconds
				_log("recover")
		"recover":
			_state_left -= delta
			if _state_left <= 0.0:
				_state = "patrol"
				_cooldown_left = attack_cooldown
				_log("patrol")


func _patrol(delta: float, enemy: Node2D) -> void:
	var player: Node2D = _player()
	if player and enemy.global_position.distance_to(player.global_position) <= detect_range:
		_state = "chase"
		_log("chase")
		return
	var patrol_range: float = 90.0
	var target_x: float = _origin_x + _direction * patrol_range
	enemy.global_position.x = move_toward(enemy.global_position.x, target_x, patrol_speed * delta)
	if absf(enemy.global_position.x - target_x) < 2.0:
		_direction = -_direction


func _chase(delta: float, enemy: Node2D) -> void:
	var player: Node2D = _player()
	if player == null or enemy.global_position.distance_to(player.global_position) > chase_range:
		_state = "patrol"
		_log("patrol")
		return
	var dx: float = player.global_position.x - enemy.global_position.x
	_direction = 1.0 if dx > 0.0 else -1.0
	if absf(dx) <= attack_range and _cooldown_left <= 0.0:
		_state = "windup"
		_state_left = windup_seconds
		_hit_done = false
		_flash_windup(enemy)
		_log("windup")
		return
	enemy.global_position.x += _direction * chase_speed * delta


func _flash_windup(enemy: Node2D) -> void:
	var visual: CanvasItem = enemy.get_node_or_null("Body")
	if visual == null:
		return
	visual.modulate = Color(1.8, 0.7, 0.3)
	var tween: Tween = enemy.create_tween()
	tween.tween_property(visual, "modulate", Color(1, 1, 1, 1), windup_seconds)


func _hit(enemy: Node2D) -> void:
	if _hit_done:
		return
	_hit_done = true
	var player: Node2D = _player()
	if player == null:
		return
	var dx: float = player.global_position.x - enemy.global_position.x
	if signf(dx) != _direction and absf(dx) > 8.0:
		return
	if absf(dx) > attack_range + 22.0:
		return
	if player.has_method("take_hit"):
		attacks_landed += 1
		player.take_hit(hit_damage, Vector2(_direction * hit_knockback, 0.0))


func _player() -> Node2D:
	var players := get_tree().get_nodes_in_group("player")
	return players[0] if not players.is_empty() else null


func _log(entry: String) -> void:
	state_log.append(entry)


## 死亡掉落（由宿主 take_damage 死亡路径调用或外接）：恰好一次。
func notify_death() -> void:
	if drops_spawned > 0:
		return
	drops_spawned += 1
	var coin := Area2D.new()
	coin.name = "DropCoin%d" % drops_spawned
	coin.add_to_group("coins")
	coin.position = Vector2(0, 0)
	var shape := CollisionShape2D.new()
	var circle := CircleShape2D.new()
	circle.radius = 10.0
	shape.shape = circle
	coin.add_child(shape)
	var visual := ColorRect.new()
	visual.size = Vector2(14, 14)
	visual.position = Vector2(-7, -7)
	visual.color = Color(0.98, 0.8, 0.1)
	coin.add_child(visual)
	var parent: Node2D = get_parent()
	var spawn_at: Node = parent.get_parent() if parent.get_parent() else parent
	spawn_at.add_child(coin)
	coin.global_position = parent.global_position
	if coin.has_signal("body_entered"):
		coin.body_entered.connect(func(body: Node2D) -> void:
			if body.is_in_group("player"):
				coin.queue_free())
