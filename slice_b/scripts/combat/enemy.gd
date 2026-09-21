extends Area2D
## 共享敌人节点（门槛 B M2）：巡逻 + 接触伤害。行为完全由注入的
## EnemyStats 驱动——grunt 与 boss 是同一实现的不同数据。

@export var stats: EnemyStats
@export var knockback_impulse: float = 220.0

var _time: float = 0.0
var _origin_x: float = 0.0

var _hp: int = 0
var _dead: bool = false

func _ready() -> void:
	add_to_group("enemies")
	_hp = stats.max_hp if stats != null else 30
	_origin_x = global_position.x
	body_entered.connect(_on_body_entered)


## 受击入口（包03，玩家攻击调用）：扣血 + 闪白 + 击退视觉位移（巡逻自然
## 回归）+ 死亡闪橙后移除。每击只经 CombatRules 判定一次。
func take_damage(amount: int, knockback: Vector2) -> void:
	if stats == null or _dead:
		return
	var verdict: Dictionary = CombatRules.apply_hit(_hp, maxi(0, amount))
	_hp = int(verdict["hp"])
	var visual: CanvasItem = get_node_or_null("Body")
	if visual:
		visual.modulate = Color(3.0, 3.0, 3.0)
		var tween: Tween = create_tween()
		tween.tween_property(visual, "modulate", Color(1, 1, 1, 1), 0.18)
	var resistance: float = CombatRules.clamp_resistance(stats.knockback_resistance)
	_origin_x += CombatRules.knockback_displacement(knockback, resistance).x * 0.2
	if bool(verdict["dead"]):
		_dead = true
		set_physics_process(false)
		var brain := get_node_or_null("MeleeBrain")
		if brain and brain.has_method("notify_death"):
			brain.notify_death()
		if visual:
			visual.modulate = Color(4.0, 1.6, 0.4)
		var die_tween: Tween = create_tween()
		die_tween.tween_interval(0.22)
		die_tween.tween_callback(queue_free)

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
