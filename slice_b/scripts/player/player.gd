extends CharacterBody2D
## 切片玩家：四向移动 + 简单墙碰撞。真实的独立模块脚本（非蓝图生成物）。

const SPEED: float = 260.0

func _physics_process(_delta: float) -> void:
	var direction: Vector2 = Input.get_vector(
		"move_left", "move_right", "move_up", "move_down")
	velocity = direction * SPEED
	move_and_slide()
	if GameSave != null:
		GameSave.record_player_position(global_position)
