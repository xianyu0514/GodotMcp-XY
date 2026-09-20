class_name ItemDef
extends Resource
## 道具定义（门槛 B M3）：道具是数据——属性改动走变更单改 .tres，
## 拾取/使用行为由通用 item_pickup 驱动。

@export var item_id: String = "item"
@export var display_name: String = "Item"
## 使用效果：heal_amount > 0 时拾取后立即治疗玩家（消耗品）。
@export var heal_amount: int = 0
## 是否任务物品（进背包计数、供任务提交），非任务物品拾取即生效不入包。
@export var quest_item: bool = false
