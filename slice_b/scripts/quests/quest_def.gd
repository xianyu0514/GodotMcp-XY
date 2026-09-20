class_name QuestDef
extends Resource
## 任务定义（门槛 B M3）：需求（item 数量）与奖励都是数据——审计剧本
## 第 4 类修改（更新任务奖励）以本 Resource 的 .tres 为对象。

@export var quest_id: String = "quest"
@export var display_name: String = "Quest"
@export_multiline var description: String = ""
@export var required_item: String = ""
@export var required_count: int = 1
@export var reward_coins: int = 0
@export var reward_heal: int = 0
