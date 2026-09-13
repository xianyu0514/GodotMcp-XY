# Goal blueprint: minimal playable controller.
extends CharacterBody2D

signal coins_changed(collected: int)

const SPEED: float = 260.0

var coins_collected: int = 0

func _ready() -> void:
	var body_shape := CollisionShape2D.new()
	var body_circle := CircleShape2D.new()
	body_circle.radius = 8
	body_shape.shape = body_circle
	add_child(body_shape)

func _physics_process(_delta: float) -> void:
	var direction := Input.get_vector("move_left", "move_right", "move_up", "move_down")
	if direction == Vector2.ZERO:
		direction = Vector2(
			Input.get_axis("ui_left", "ui_right"),
			Input.get_axis("ui_up", "ui_down"))
	velocity = direction * SPEED
	move_and_slide()
