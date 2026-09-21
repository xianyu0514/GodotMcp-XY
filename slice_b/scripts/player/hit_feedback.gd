
extends Node2D
## 受击反馈 + 自审计（包①：每项用户要求独立证据）。子效果各自记录真值，
## 任何一项的通过不再替其他项背书；断言读审计字典，免疫探针往返延迟。
## 只负责表现：伤害/无敌/音效规则留在 player.gd。

@export var flash_color: Color = Color(4.0, 4.0, 4.0)
@export var flash_seconds: float = 0.22
@export var particle_amount: int = 26
@export var camera_shake_pixels: float = 8.0
@export var camera_shake_seconds: float = 0.22
@export var hitstop_seconds: float = 0.06
@export var hitstop_scale: float = 0.05

## 最近一次受击的自审计：每项子效果的独立真值（回归逐项断言这些键）。
var last_hit_audit: Dictionary = {}

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


func _reset_audit() -> void:
	last_hit_audit = {
		"flash_set": false, "flash_recovered": false,
		"hitstop_engaged": false, "hitstop_restored": false,
		"hitstop_time_scale_seen": 1.0, "hitstop_restored_to": 1.0,
		"shake_magnitude": 0.0, "shake_reset": false,
		"camera_was_created": false, "camera_existed": false,
		"particles_emitted": false, "particle_amount": 0,
	}


## hitstop：引擎时间短暂拉慢（顿帧）。计时器 ignore_time_scale 保证恢复准时。
func _do_hitstop() -> void:
	if hitstop_seconds <= 0.0 or _hitstop_active:
		return
	_hitstop_active = true
	var before: float = Engine.time_scale
	Engine.time_scale = maxf(hitstop_scale, 0.01)
	last_hit_audit["hitstop_engaged"] = true
	last_hit_audit["hitstop_time_scale_seen"] = Engine.time_scale
	await get_tree().create_timer(hitstop_seconds, true, false, true).timeout
	Engine.time_scale = before
	last_hit_audit["hitstop_restored"] = true
	last_hit_audit["hitstop_restored_to"] = Engine.time_scale
	_hitstop_active = false


func play_hit_feedback(_knockback: Vector2 = Vector2.ZERO) -> void:
	_reset_audit()
	if _tween:
		_tween.kill()
	var target: CanvasItem = get_parent().get_node_or_null("Skin") as CanvasItem
	if target == null:
		target = get_parent() as CanvasItem
	target.modulate = flash_color
	last_hit_audit["flash_set"] = true
	_tween = create_tween()
	_tween.tween_property(target, "modulate", Color(1, 1, 1, 1), maxf(flash_seconds, 0.01))
	_tween.finished.connect(func() -> void:
		last_hit_audit["flash_recovered"] = true)
	_particles.amount = particle_amount
	_particles.restart()
	last_hit_audit["particles_emitted"] = true
	last_hit_audit["particle_amount"] = particle_amount
	_do_hitstop()
	# 真随机镜头震：多步随机偏移线性衰减回原位。无相机则自动补一个挂玩家上
	# ——震屏绝不静默跳过（实测教训：slice_b 地图原本没有 Camera2D）。
	if camera_shake_pixels > 0.0:
		var camera: Camera2D = get_viewport().get_camera_2d()
		last_hit_audit["camera_existed"] = camera != null
		if camera == null:
			camera = Camera2D.new()
			camera.position_smoothing_enabled = false
			get_parent().add_child(camera)
			last_hit_audit["camera_was_created"] = true
		var steps: int = maxi(int(camera_shake_seconds / 0.033), 3)
		var original_offset: Vector2 = camera.offset
		for i in range(steps):
			var falloff: float = 1.0 - float(i) / float(steps)
			camera.offset = original_offset + Vector2(
				randf_range(-1.0, 1.0), randf_range(-1.0, 1.0)) * camera_shake_pixels * falloff
			last_hit_audit["shake_magnitude"] = maxf(
				float(last_hit_audit["shake_magnitude"]), camera.offset.length())
			await get_tree().process_frame
			await get_tree().process_frame
		camera.offset = original_offset
		last_hit_audit["shake_reset"] = camera.offset == original_offset


func is_flash_active() -> bool:
	var target: CanvasItem = get_parent().get_node_or_null("Skin") as CanvasItem
	if target == null:
		target = get_parent() as CanvasItem
	return target.modulate != Color(1, 1, 1, 1)
