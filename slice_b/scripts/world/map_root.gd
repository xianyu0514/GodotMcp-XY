extends Node2D
## 地图骨架：把玩家放到出生点并记录访问（存档的"当前地图"语义）。

@export var map_id: String = ""

func _ready() -> void:
	if not map_id.is_empty():
		GameSave.record_map_visit(map_id)
	var spawn: Marker2D = get_node_or_null("SpawnMarker")
	var player: CharacterBody2D = get_node_or_null("Player")
	if spawn and player:
		player.global_position = spawn.resolve_spawn()
