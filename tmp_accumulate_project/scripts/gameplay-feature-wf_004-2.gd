# Goal blueprint: minimal playable controller.
extends CharacterBody2D

signal coins_changed(collected: int)

const SPEED: float = 260.0

var coins_collected: int = 0
var _pause_label: Label

func _ready() -> void:
	var body_shape := CollisionShape2D.new()
	var body_circle := CircleShape2D.new()
	body_circle.radius = 8
	body_shape.shape = body_circle
	add_child(body_shape)
	process_mode = Node.PROCESS_MODE_ALWAYS
	# 运行期生成暂停菜单层：CanvasLayer + PauseLabel，默认隐藏。
	var pause_layer := CanvasLayer.new()
	pause_layer.name = "PauseLayer"
	pause_layer.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(pause_layer)
	_pause_label = Label.new()
	_pause_label.name = "PauseLabel"
	_pause_label.text = "Paused - press Esc to resume"
	_pause_label.position = Vector2(40, 60)
	_pause_label.visible = false
	pause_layer.add_child(_pause_label)

func _physics_process(_delta: float) -> void:
	if Input.is_action_just_pressed("ui_cancel"):
		set_paused(not get_tree().paused)
	if get_tree().paused:
		return

func set_paused(value: bool) -> void:
	get_tree().paused = value
	if _pause_label != null:
		_pause_label.visible = value
