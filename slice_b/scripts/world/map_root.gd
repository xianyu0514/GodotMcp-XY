extends Node2D
## 地图骨架（玩家全流程 P0-2 的"继续游戏"入口）：
## 启动时若有跨图恢复目标，主场景（L1）只做引导——立即转场、不落盘；
## 门转场（pending_spawn）优先用门指定出生点；其余情况按存档恢复
## 位置与生命，无恢复才用地图出生点。

@export var map_id: String = ""

func _ready() -> void:
	if GameSave == null:
		return

	# 1) 启动引导：有进度且指向别的地图 → 转场排队后立即让位（本图
	#    不记录访问、不落盘——否则会把 last_map 改写成引导图）。
	if GameSave.begin_resume_if_any(get_tree()):
		var target_map: String = String(GameSave.current.get("pending_resume", {}).get("map", ""))
		if target_map != map_id:
			# 引导图让位：延迟转场到目标地图（_ready 期间安全），本图不落盘。
			get_tree().change_scene_to_file(target_map)
			return

	# 2) 正常进入：记录访问 + BGM。
	if not map_id.is_empty():
		GameSave.record_map_visit(map_id)
	if SoundBus != null:
		SoundBus.play_bgm()

	var spawn: Marker2D = get_node_or_null("SpawnMarker")
	var player: CharacterBody2D = get_node_or_null("Player")
	if spawn == null or player == null:
		return

	# 3) 放置决策（优先级：门转场 > 跨图恢复 > 同图存档位置 > 出生点）。
	if GameSave.current.has("pending_spawn"):
		# 门刚转场进来：消费门指定的出生点（存档位置在此场景无意义）。
		player.global_position = spawn.resolve_spawn()
	elif _restore_from_resume(player, map_id) or _restore_from_same_map(player, map_id):
		pass
	else:
		player.global_position = spawn.resolve_spawn()

	# 3.5) 复活点在摆放之后捕获：Player._ready 先于本函数执行，彼时位置
	# 还是实例默认 (0,0)（墙内）——死亡会传送进墙永远卡死（实测）。
	if "_respawn_at" in player:
		player._respawn_at = player.global_position
	# 4) 进入即落一次盘（访问 + 位置基线 + 当前战斗态快照）。
	GameSave.record_player_position(player.global_position)
	GameSave.record_combat_state(int(player.hp) if "hp" in player else 100, GameSave.coins)
	GameSave.save()

## 跨图恢复：pending_resume（启动直入或转场带入）指向本地图。
func _restore_from_resume(player: CharacterBody2D, map_id: String) -> bool:
	var resume: Dictionary = GameSave.take_resume()
	if resume.is_empty() or String(resume.get("map", "")) != map_id:
		return false
	var pos_data: Dictionary = resume.get("position", {}) if resume.get("position", {}) is Dictionary else {}
	if pos_data.has("x") and pos_data.has("y"):
		player.global_position = Vector2(float(pos_data["x"]), float(pos_data["y"]))
	var hp: int = int(resume.get("hp", -1))
	if hp >= 0 and "hp" in player:
		player.hp = maxi(1, hp)
	return true

## 同图重进：无 pending（例：死亡重生流程之外的手动重载），且存档的
## last_map 就是本地图 → 用存档的最近位置/生命。
func _restore_from_same_map(player: CharacterBody2D, map_id: String) -> bool:
	if not GameSave.resumed_from_save:
		return false
	if String(GameSave.current.get("last_map", "")) != map_id:
		return false
	var saved: Dictionary = GameSave.current.get("player_position", {})
	if not (saved is Dictionary) or not saved.has("x") or not saved.has("y"):
		return false
	player.global_position = Vector2(float(saved["x"]), float(saved["y"]))
	var hp: int = int(GameSave.current.get("hp", -1))
	if hp >= 0 and "hp" in player:
		player.hp = maxi(1, hp)
	return true
