extends Area2D
## 道具拾取节点（门槛 B M3 + 玩家全流程 P0-2 的持久身份）：
## 接触即拾取——任务物品入背包并推进任务，消耗品立即生效（治疗）。
## 每个实例有稳定 ID（地图路径#节点名）：收集记录进存档，重进地图/
## 重启后已收集的不再出现——背包不重复、任务不重复推进。

@export var item: ItemDef

func _ready() -> void:
	# 已收集（存档记录）→ 本实例直接退场，不重复给奖励。
	if GameSave != null and GameSave.is_item_collected(persistent_id()):
		queue_free()
		return
	body_entered.connect(_on_body_entered)

## 稳定实例身份：本地图的 map_id + 场景内节点名。
func persistent_id() -> String:
	var map: Node = owner
	var map_id: String = String(map.get("map_id")) if map != null else ""
	return GameSave.item_id_for(map_id, name) if GameSave != null else ""

func _on_body_entered(body: Node2D) -> void:
		if item == null or not body.is_in_group("player"):
			return
		if SoundBus != null:
			SoundBus.play_sfx(SoundBus.SFX_PICKUP)
		var collected_id: String = persistent_id()
		if item.quest_item:
			if GameSave != null:
				# 双保险：并发/重复接触下已记录则不再发放。
				if GameSave.is_item_collected(collected_id):
					queue_free()
					return
				GameSave.record_item_collected(collected_id)
				GameSave.inventory.add(item.item_id)
				GameSave.quest_log.record_progress("quest_hearts", 1)
				GameSave.save()
			queue_free()
		elif item.heal_amount > 0 and body.has_method("heal"):
			if GameSave != null:
				if GameSave.is_item_collected(collected_id):
					queue_free()
					return
				GameSave.record_item_collected(collected_id)
			body.heal(item.heal_amount)
			queue_free()
