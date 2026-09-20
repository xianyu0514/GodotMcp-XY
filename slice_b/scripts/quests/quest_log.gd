class_name QuestLog
extends RefCounted
## 任务进度纯逻辑（门槛 B M3）：状态机 pending(未接) 不存——只存进行中与
## 已完成；提交判定从背包计数推导。单测覆盖。

var _active: Dictionary = {}   # quest_id -> {"progress": int}
var _completed: Dictionary = {}  # quest_id -> true

func accept(quest_id: String) -> bool:
	if _active.has(quest_id) or _completed.has(quest_id):
		return false
	_active[quest_id] = {"progress": 0}
	return true

func record_progress(quest_id: String, amount: int = 1) -> void:
	if not _active.has(quest_id):
		return
	var entry: Dictionary = _active[quest_id]
	entry["progress"] = int(entry.get("progress", 0)) + amount

## 提交：背包满足需求则扣道具、记完成、返回奖励描述；否则空字典。
## def 的类型注解刻意省略（QuestDef）：宿主项目的单测会 preload 本脚本，
## 嵌套项目的全局类在那里不可解析——鸭子类型即可（quest_id 必须匹配）。
func try_turn_in(quest_id: String, def, inventory) -> Dictionary:
	if not _active.has(quest_id) or def == null or quest_id != def.quest_id:
		return {}
	if inventory.count(def.required_item) < def.required_count:
		return {}
	if not inventory.remove(def.required_item, def.required_count):
		return {}
	_active.erase(quest_id)
	_completed[quest_id] = true
	return {"reward_coins": def.reward_coins, "reward_heal": def.reward_heal}

func is_active(quest_id: String) -> bool:
	return _active.has(quest_id)

func is_completed(quest_id: String) -> bool:
	return _completed.has(quest_id)

func progress(quest_id: String) -> int:
	return int(_active.get(quest_id, {}).get("progress", 0)) if _active.has(quest_id) else -1

func active_ids() -> Array:
	return _active.keys()

func completed_ids() -> Array:
	return _completed.keys()

func to_dict() -> Dictionary:
	return {"active": _active.duplicate(true), "completed": _completed.duplicate(true)}

func load_dict(data: Dictionary) -> void:
	_active = (data.get("active", {}) as Dictionary).duplicate(true)
	_completed = (data.get("completed", {}) as Dictionary).duplicate(true)
