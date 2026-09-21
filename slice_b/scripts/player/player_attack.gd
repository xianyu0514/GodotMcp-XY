extends Node2D
## 玩家主动攻击（包03）：起手 -> 生效 -> 恢复 -> 冷却。每次挥击对每个
## 敌人恰好命中一次（hit set）；判定为面向侧的 reach 范围盒。参数全部
## @export，可随时经 MCP 调整（手感方案的组成部分）。

@export var startup_seconds: float = 0.08
@export var active_seconds: float = 0.12
@export var recovery_seconds: float = 0.18
@export var cooldown_seconds: float = 0.45
@export var damage: int = 15
@export var reach: float = 46.0
@export var hit_height: float = 34.0
@export var attack_action: String = "attack"

var _phase: String = "idle"
var _phase_left: float = 0.0
var _cooldown_left: float = 0.0
var swing_count: int = 0
var last_swing_started_ms: int = 0
## 每次挥击的开始毫秒日志（延迟免疫测量：按住攻击读取相邻差值）。
var swing_log_ms: Array = []
var _hit_this_swing: Array = []
var _slash: ColorRect
var _facing_right: bool = true


func _ready() -> void:
	_slash = ColorRect.new()
	_slash.name = "Slash"
	_slash.color = Color(1.0, 0.75, 0.2, 0.65)
	_slash.visible = false
	add_child(_slash)


func is_attacking() -> bool:
	return _phase != "idle"


func phase() -> String:
	return _phase


func cooldown_left() -> float:
	return _cooldown_left


## 供延迟免疫测量：当前引擎毫秒（表达式无法直接调 Time 单例）。
func now_ms() -> int:
	return Time.get_ticks_msec()


func _physics_process(delta: float) -> void:
	var player: Node = get_parent()
	var horizontal: float = player.velocity.x
	if absf(horizontal) > 10.0:
		_facing_right = horizontal > 0.0
	if _cooldown_left > 0.0:
		_cooldown_left = maxf(0.0, _cooldown_left - delta)
	if _phase == "idle":
		if _cooldown_left <= 0.0 and Input.is_action_just_pressed(attack_action):
			_phase = "startup"
			_phase_left = startup_seconds
			_hit_this_swing = []
			swing_count += 1
			last_swing_started_ms = Time.get_ticks_msec()
			swing_log_ms.append(last_swing_started_ms)
			_slash.visible = true
			_slash.color = Color(1.0, 0.9, 0.5, 0.35)
	_update_splash_box()
	if _phase == "idle":
		return
	_phase_left -= delta
	if _phase == "startup" and _phase_left <= 0.0:
		_phase = "active"
		_phase_left = active_seconds
		_slash.color = Color(1.0, 0.62, 0.15, 0.8)
		_apply_hits()
	elif _phase == "active" and _phase_left <= 0.0:
		_phase = "recovery"
		_phase_left = recovery_seconds
		_slash.visible = false
	elif _phase == "recovery" and _phase_left <= 0.0:
		_phase = "idle"
		_cooldown_left = cooldown_seconds


func _update_splash_box() -> void:
	var side: float = 1.0 if _facing_right else -1.0
	_slash.size = Vector2(reach, hit_height)
	_slash.position = Vector2(16.0 if _facing_right else -16.0 - reach, -hit_height / 2.0)
	_slash.scale.x = side if side < 0.0 else 1.0


func _apply_hits() -> void:
	var player: Node2D = get_parent()
	for enemy in get_tree().get_nodes_in_group("enemies"):
		if not enemy is Node2D or not enemy.has_method("take_damage"):
			continue
		if enemy in _hit_this_swing or not is_instance_valid(enemy):
			continue
		var offset: Vector2 = enemy.global_position - player.global_position
		if absf(offset.y) > hit_height:
			continue
		if absf(offset.x) > reach + 16.0:
			continue
		if signf(offset.x) != (1.0 if _facing_right else -1.0) and absf(offset.x) > 8.0:
			continue
		_hit_this_swing.append(enemy)
		var knockback: Vector2 = Vector2((220.0 if _facing_right else -220.0), 0.0)
		enemy.take_damage(damage, knockback)
