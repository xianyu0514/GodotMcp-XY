
extends Node2D
## 受击反馈（包02 + 打击感版）：闪白自恢复 + hitstop 顿帧 + 真随机镜头震
## + 一次性粒子。只负责表现：伤害/无敌/音效规则留在 player.gd。
## 参数全部 @export，可随时经 MCP 调整。

@export var flash_color: Color = Color(4.0, 4.0, 4.0)
@export var flash_seconds: float = 0.22
@export var particle_amount: int = 26
@export var camera_shake_pixels: float = 8.0
@export var camera_shake_seconds: float = 0.22
@export var hitstop_seconds: float = 0.06
@export var hitstop_scale: float = 0.05

var _particles: CPUParticles2D
var _tween: Tween
var _hitstop_active: bool = false


func _ready() -> void:
	_particles = CPUParticles2D.new()
	_particles.one_shot = true
	_particles.emitting = false
	_particles.amount = particle_amount
	_particles.lifetime = 0.45
	_particles.direction = Vector2(0, -1)
	_particles.spread = 180.0
	_particles.initial_velocity_min = 90.0
	_particles.initial_velocity_max = 220.0
	_particles.gravity = Vector2(0, 320)
	_particles.scale_amount_min = 0.8
	_particles.scale_amount_max = 2.2
	_particles.color = Color(1.0, 0.78, 0.3)
	add_child(_particles)
	set_physics_process(false)


## hitstop：把引擎时间 briefly 拉到极慢（顿帧）—— 打击感的核心一招。
## 计时器 ignore_time_scale，保证低速世界里的恢复准时发生。
func _do_hitstop() -> void:
	if hitstop_seconds <= 0.0 or _hitstop_active:
		return
	_hitstop_active = true
	Engine.time_scale = maxf(hitstop_scale, 0.01)
	await get_tree().create_timer(hitstop_seconds, true, false, true).timeout
	Engine.time_scale = 1.0
	_hitstop_active = false


func play_hit_feedback(_knockback: Vector2 = Vector2.ZERO) -> void:
	if _tween:
		_tween.kill()
	var target: CanvasItem = get_parent().get_node_or_null("Skin") as CanvasItem
	if target == null:
		target = get_parent() as CanvasItem
	target.modulate = flash_color
	_tween = create_tween()
	_tween.tween_property(target, "modulate", Color(1, 1, 1, 1), maxf(flash_seconds, 0.01))
	_particles.amount = particle_amount
	_particles.restart()
	_do_hitstop()
	# 真随机镜头震：多步随机偏移线性衰减到原位（连续受击 kill 重启不累积）。
	if camera_shake_pixels > 0.0:
		var camera: Camera2D = get_viewport().get_camera_2d()
		if camera:
			var steps: int = maxi(int(camera_shake_seconds / 0.033), 3)
			var original_offset: Vector2 = camera.offset
			for i in range(steps):
				var falloff: float = 1.0 - float(i) / float(steps)
				camera.offset = original_offset + Vector2(
					randf_range(-1.0, 1.0), randf_range(-1.0, 1.0)) * camera_shake_pixels * falloff
				await get_tree().process_frame
				await get_tree().process_frame
			camera.offset = original_offset


func is_flash_active() -> bool:
	var target: CanvasItem = get_parent().get_node_or_null("Skin") as CanvasItem
	if target == null:
		target = get_parent() as CanvasItem
	return target.modulate != Color(1, 1, 1, 1)
