class_name Inventory
extends RefCounted
## 背包纯逻辑（门槛 B M3）：只操作字典状态，序列化/存档由 GameSave 负责。
## 单测覆盖（test_slice_b_m3.gd）。

var _counts: Dictionary = {}

func add(item_id: String, amount: int = 1) -> void:
	if amount <= 0:
		return
	_counts[item_id] = int(_counts.get(item_id, 0)) + amount

func count(item_id: String) -> int:
	return int(_counts.get(item_id, 0))

func remove(item_id: String, amount: int = 1) -> bool:
	if count(item_id) < amount:
		return false
	_counts[item_id] = count(item_id) - amount
	if _counts[item_id] == 0:
		_counts.erase(item_id)
	return true

func to_dict() -> Dictionary:
	return _counts.duplicate()

func load_dict(data: Dictionary) -> void:
	_counts = data.duplicate()

func total_items() -> int:
	var total: int = 0
	for value in _counts.values():
		total += int(value)
	return total
