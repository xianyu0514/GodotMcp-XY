extends Area2D
## 地图门：接触即切场景并把访问记入存档（跨地图部分进度）。

@export var target_scene: String = ""
@export var target_spawn: Vector2 = Vector2(120, 280)

func _ready() -> void:
	body_entered.connect(_on_body_entered)

func _on_body_entered(body: Node2D) -> void:
	if not body.is_in_group("player"):
		return
	if target_scene.is_empty() or not ResourceLoader.exists(target_scene):
		push_warning("Door target missing: " + target_scene)
		return
	if SoundBus != null:
		SoundBus.play_sfx(SoundBus.SFX_DOOR)
	# 出生点先入存档（change_scene 只是排队到帧末，同帧内先写先得）。
	GameSave.current["pending_spawn"] = {"x": target_spawn.x, "y": target_spawn.y}
	GameSave.record_map_visit(target_scene)
	get_tree().change_scene_to_file(target_scene)
