extends Sprite2D
## 角色皮肤（包01）：精灵表 idle/move 动画 + 朝向翻转 + 支点对齐。
## 由 apply_character_visual 接入；参数全部 @export，可随时经 MCP 调整。

@export var idle_frames: int = 2
@export var move_frames: int = 4
@export var animation_fps: int = 8
@export var use_block_visual: bool = false:
	set(value):
		use_block_visual = value
		_body_visible = value
		_update_visibility()
@export var pixel_offset: Vector2 = Vector2.ZERO

var _frame_time: float = 0.0
var _frame: int = 0
var _facing_right: bool = true
var _body_visible: bool = false

@onready var _body: ColorRect = get_parent().get_node_or_null("Body")


func _ready() -> void:
	_update_visibility()


func _update_visibility() -> void:
	visible = not use_block_visual
	if _body:
		_body.visible = use_block_visual or not visible


func _physics_process(delta: float) -> void:
	var speed: float = get_parent().velocity.length()
	var count: int = move_frames if speed > 10.0 else idle_frames
	var row: int = 0 if speed <= 10.0 else 1
	var horizontal: float = get_parent().velocity.x
	if absf(horizontal) > 10.0:
		_facing_right = horizontal > 0.0
	_frame_time += delta
	if _frame_time >= 1.0 / maxf(animation_fps, 1.0):
		_frame_time = 0.0
		_frame = (_frame + 1) % maxi(count, 1)
	flip_h = not _facing_right
	frame_coords = Vector2i(_frame, row)
	offset = pixel_offset


func is_using_block_visual() -> bool:
	return use_block_visual


func set_block_visual(value: bool) -> bool:
	use_block_visual = value
	return use_block_visual
