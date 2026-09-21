extends Node2D
## 受击反馈（包02）：闪白（自动恢复）+ 一次性粒子 + 轻微镜头反馈。
## 只负责表现：伤害/无敌/音效规则留在 player.gd（SoundBus 已播 hit，
## 此处不重复播放）。参数全部 @export，可随时经 MCP 调整。

@export var flash_color: Color = Color(3.0, 3.0, 3.0)
@export var flash_seconds: float = 0.12
@export var particle_amount: int = 14
@export var camera_shake_pixels: float = 6.0
@export var camera_shake_seconds: float = 0.18

var _particles: CPUParticles2D
var _tween: Tween
var _camera_tween: Tween


func _ready() -> void:
	_particles = CPUParticles2D.new()
	_particles.one_shot = true
	_particles.emitting = false
	_particles.amount = particle_amount
	_particles.lifetime = 0.4
	_particles.speed_scale = 1.0
	_particles.direction = Vector2(0, -1)
	_particles.spread = 180.0
	_particles.initial_velocity_min = 60.0
	_particles.initial_velocity_max = 140.0
	_particles.gravity = Vector2(0, 240)
	_particles.scale_amount_min = 0.6
	_particles.scale_amount_max = 1.4
	_particles.color = Color(1.0, 0.85, 0.4)
	add_child(_particles)
	set_physics_process(false)


func play_hit_feedback(_knockback: Vector2 = Vector2.ZERO) -> void:
	# 闪白：kill 旧 tween 重启 —— 连续受击不会累积颜色或时间。
	if _tween:
		_tween.kill()
	var target: CanvasItem = get_parent().get_node_or_null("Skin") as CanvasItem
	if target == null:
		target = get_parent() as CanvasItem
	var original: Color = Color(1, 1, 1, 1)
	target.modulate = flash_color
	_tween = create_tween()
	_tween.tween_property(target, "modulate", original, maxf(flash_seconds, 0.01))
	# 粒子：one_shot 重发。
	_particles.amount = particle_amount
	_particles.restart()
	# 镜头：可配为 0（不改变伤害规则，纯表现）。
	if camera_shake_pixels > 0.0:
		var camera: Camera2D = get_viewport().get_camera_2d()
		if camera:
			if _camera_tween:
				_camera_tween.kill()
			var original_offset: Vector2 = camera.offset
			camera.offset = original_offset + Vector2(camera_shake_pixels, 0)
			_camera_tween = create_tween()
			_camera_tween.tween_property(camera, "offset", original_offset,
				maxf(camera_shake_seconds, 0.01))


func is_flash_active() -> bool:
	var target: CanvasItem = get_parent().get_node_or_null("Skin") as CanvasItem
	if target == null:
		target = get_parent() as CanvasItem
	return target.modulate != Color(1, 1, 1, 1)
