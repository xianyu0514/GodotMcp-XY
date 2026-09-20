extends CharacterBody2D
## 切片玩家：四向移动 + 受击（伤害/击退/无敌帧/死亡重生到出生点）。
## 数值规则全部经 CombatRules（纯函数、单测覆盖），节点层只做状态机。

const SPEED: float = 260.0
const MAX_HP: int = 100
const INVULN_SECONDS: float = 0.8

var hp: int = MAX_HP
var _invuln_left: float = 0.0
var _knockback_velocity: Vector2 = Vector2.ZERO
var _respawn_at: Vector2 = Vector2.ZERO

func _ready() -> void:
	_respawn_at = global_position

func _physics_process(delta: float) -> void:
	if _invuln_left > 0.0:
		_invuln_left = maxf(0.0, _invuln_left - delta)
	var direction: Vector2 = Input.get_vector(
		"move_left", "move_right", "move_up", "move_down")
	velocity = direction * SPEED + _knockback_velocity
	_knockback_velocity = _knockback_velocity.move_toward(Vector2.ZERO, delta * 900.0)
	move_and_slide()
	if GameSave != null:
		GameSave.record_player_position(global_position)

func take_hit(damage: int, knockback: Vector2) -> void:
	var effective: int = CombatRules.damage_after_invuln(damage, _invuln_left > 0.0)
	if effective <= 0:
		return
	var verdict: Dictionary = CombatRules.apply_hit(hp, effective)
	hp = int(verdict["hp"])
	_invuln_left = INVULN_SECONDS
	_knockback_velocity = knockback
	if bool(verdict["dead"]):
		global_position = _respawn_at
		hp = MAX_HP
		_knockback_velocity = Vector2.ZERO
		_invuln_left = 0.0
