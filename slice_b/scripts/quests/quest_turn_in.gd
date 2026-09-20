extends Area2D
## 任务提交点（门槛 B M3）：接触即尝试提交——背包满足任务需求时发放
## 奖励（金币 + 治疗），否则提示需求。

@export var quest: QuestDef

var _last_hint_msec: int = 0

func _ready() -> void:
	body_entered.connect(_on_body_entered)

func _on_body_entered(body: Node2D) -> void:
	if quest == null or GameSave == null or not body.is_in_group("player"):
		return
	if not GameSave.quest_log.is_active(quest.quest_id):
		# 首次接触视为接取任务（简化：无独立 NPC 对话）。
		GameSave.quest_log.accept(quest.quest_id)
		GameSave.save()
		return
	var reward: Dictionary = GameSave.quest_log.try_turn_in(
		quest.quest_id, quest, GameSave.inventory)
	if reward.is_empty():
		return
	GameSave.coins += int(reward.get("reward_coins", 0))
	if body.has_method("heal"):
		body.heal(int(reward.get("reward_heal", 0)))
	GameSave.save()
