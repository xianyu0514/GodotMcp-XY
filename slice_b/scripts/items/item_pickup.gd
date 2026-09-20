extends Area2D
## 道具拾取节点（门槛 B M3）：接触即拾取——任务物品入背包并推进任务，
## 消耗品立即生效（治疗）。

@export var item: ItemDef

func _ready() -> void:
	body_entered.connect(_on_body_entered)

func _on_body_entered(body: Node2D) -> void:
	if item == null or not body.is_in_group("player"):
		return
	if SoundBus != null:
		SoundBus.play_sfx(SoundBus.SFX_PICKUP)
	if item.quest_item:
		if GameSave != null:
			GameSave.inventory.add(item.item_id)
			GameSave.quest_log.record_progress("quest_hearts", 1)
			GameSave.save()
		queue_free()
	elif item.heal_amount > 0 and body.has_method("heal"):
		body.heal(item.heal_amount)
		queue_free()
