# Goal blueprint: minimal playable controller.
extends CharacterBody2D

signal coins_changed(collected: int)

const SPEED: float = 260.0

var coins_collected: int = 0
var deaths_count: int = 0
var _enemy: Area2D
var _enemy_time: float = 0.0
const ENEMY_HOME_X: float = 300.0
const ENEMY_RANGE: float = 80.0
const ENEMY_SPEED: float = 120.0

func _ready() -> void:
	var body_shape := CollisionShape2D.new()
	var body_circle := CircleShape2D.new()
	body_circle.radius = 8
	body_shape.shape = body_circle
	add_child(body_shape)
	var enemy := Area2D.new()
	enemy.name = "Enemy"
	enemy.position = Vector2(ENEMY_HOME_X, 0.0)
	var enemy_collision := CollisionShape2D.new()
	var enemy_shape := RectangleShape2D.new()
	# 纵向高墙：任意纵向偏移的水平穿越都会触发（开环演练确定性）。
	enemy_shape.size = Vector2(16, 240)
	enemy_collision.shape = enemy_shape
	enemy.add_child(enemy_collision)
	# 同金币：挂到父节点，巡逻才是世界坐标。
	get_parent().add_child.call_deferred(enemy)
	enemy.body_entered.connect(_on_enemy_touched)
	_enemy = enemy

func _physics_process(_delta: float) -> void:
	# 敌人巡逻：相位从生成起累积（墙钟正弦会在整周期处过零，
	# 断言窗口踩到过零点会闪断——真机 E2E 抓到）。
	_enemy_time += _delta
	_enemy.position.x = ENEMY_HOME_X + sin(_enemy_time * (TAU / 6.0)) * ENEMY_RANGE
	var direction := Input.get_vector("move_left", "move_right", "move_up", "move_down")
	if direction == Vector2.ZERO:
		direction = Vector2(
			Input.get_axis("ui_left", "ui_right"),
			Input.get_axis("ui_up", "ui_down"))
	velocity = direction * SPEED
	move_and_slide()

func _on_enemy_touched(body: Node) -> void:
	if body != self:
		return
	deaths_count += 1
	position = Vector2.ZERO
