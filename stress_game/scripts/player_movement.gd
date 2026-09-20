extends CharacterBody2D
## S01 热身走廊：移动 + 边界 + 冲刺（含冷却）。四个状态全部可从运行时
## 表达式观察，验收流（test_stress_s01_flow.py）只依赖这些方法与常量。

const SPEED := 220.0
const DASH_SPEED := 640.0
const DASH_FRAMES := 12
const DASH_COOLDOWN_FRAMES := 36

var _dash_remaining := 0
var _dash_cooldown := 0


func _physics_process(_delta: float) -> void:
	var direction: float = Input.get_axis("move_left", "move_right")
	var velocity_x: float = direction * SPEED
	if _dash_remaining > 0:
		velocity_x = signf(direction if direction != 0.0 else 1.0) * DASH_SPEED
		_dash_remaining -= 1
	elif direction != 0.0 and _dash_cooldown == 0 and Input.is_action_just_pressed("dash"):
		_dash_remaining = DASH_FRAMES
		_dash_cooldown = DASH_COOLDOWN_FRAMES
	if _dash_cooldown > 0:
		_dash_cooldown -= 1
	velocity = Vector2(velocity_x, 0.0)
	move_and_slide()


func is_dashing() -> bool:
	return _dash_remaining > 0


func dash_cooldown_remaining() -> int:
	return _dash_cooldown
