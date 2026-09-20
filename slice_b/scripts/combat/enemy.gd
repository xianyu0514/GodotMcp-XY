extends Area2D
## 共享敌人节点（门槛 B M2）：巡逻 + 接触伤害。行为完全由注入的
## EnemyStats 驱动——grunt 与 boss 是同一实现的不同数据。

@export var stats: EnemyStats
@export var knockback_impulse: float = 220.0

var _time: float = 0.0
var _origin_x: float = 0.0

func _ready() -> void:
	_origin_x = global_position.x
	body_entered.connect(_on_body_entered)

func _physics_process(delta: float) -> void:
	if stats == null:
		return
	_time += delta
	global_position.x = _origin_x + sin(_time * stats.move_speed / 60.0) * stats.patrol_range

func _on_body_entered(body: Node2D) -> void:
	if stats == null or not body.is_in_group("player") or not body.has_method("take_hit"):
		return
	var away: Vector2 = (body.global_position - global_position).normalized()
	if away == Vector2.ZERO:
		away = Vector2.LEFT
	body.take_hit(stats.contact_damage, away * knockback_impulse)
