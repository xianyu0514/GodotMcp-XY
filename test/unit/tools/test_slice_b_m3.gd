extends "res://addons/gut/test.gd"

## 门槛 B M3/M5 单元测试：背包与任务纯逻辑、道具/任务数据锚点。
## （存档迁移链在 slice_b 项目自己的上下文里验证——嵌套项目的 autoload
## 依赖在宿主项目不可加载，见 test_slice_b_m2_flow.py 的模式说明。）

const InventoryScript = preload("res://slice_b/scripts/items/inventory.gd")
const QuestLogScript = preload("res://slice_b/scripts/quests/quest_log.gd")
const QuestDefScript = preload("res://slice_b/scripts/quests/quest_def.gd")

# ============================================================================
# 背包
# ============================================================================

func test_inventory_add_count_remove() -> void:
	var inventory = InventoryScript.new()
	inventory.add("heart", 2)
	inventory.add("heart", 1)
	assert_eq(inventory.count("heart"), 3, "adds accumulate")
	assert_eq(inventory.count("gem"), 0, "unknown items count zero")
	assert_true(inventory.remove("heart", 2))
	assert_eq(inventory.count("heart"), 1)
	assert_false(inventory.remove("heart", 5), "over-removal is refused")
	assert_eq(inventory.count("heart"), 1, "refused removal changes nothing")
	inventory.remove("heart", 1)
	assert_eq(inventory.count("heart"), 0)
	assert_false(inventory.to_dict().has("heart"), "empty slots are erased")

func test_inventory_serialization_roundtrip() -> void:
	var inventory = InventoryScript.new()
	inventory.add("heart", 2)
	inventory.add("gem", 5)
	var restored = InventoryScript.new()
	restored.load_dict(inventory.to_dict())
	assert_eq(restored.count("heart"), 2)
	assert_eq(restored.count("gem"), 5)
	assert_eq(restored.total_items(), 7)

func test_inventory_rejects_nonpositive() -> void:
	var inventory = InventoryScript.new()
	inventory.add("heart", 0)
	inventory.add("heart", -3)
	assert_eq(inventory.count("heart"), 0, "zero/negative adds are ignored")

# ============================================================================
# 任务
# ============================================================================

func _quest_def():
	var def = QuestDefScript.new()
	def.quest_id = "quest_hearts"
	def.required_item = "heart"
	def.required_count = 2
	def.reward_coins = 5
	def.reward_heal = 10
	return def

func test_quest_accept_once_and_progress() -> void:
	var log = QuestLogScript.new()
	assert_true(log.accept("q1"))
	assert_false(log.accept("q1"), "double accept is refused")
	log.record_progress("q1", 2)
	assert_eq(log.progress("q1"), 2)
	assert_false(log.is_completed("q1"))
	assert_eq(log.progress("unknown"), -1, "unaccepted quests have no progress")

func test_quest_turn_in_requires_items_and_pays_once() -> void:
	var log = QuestLogScript.new()
	var inventory = InventoryScript.new()
	var def = _quest_def()
	log.accept(def.quest_id)
	assert_true(log.try_turn_in(def.quest_id, def, inventory).is_empty(),
		"turn-in without the items fails")
	inventory.add("heart", 2)
	var reward: Dictionary = log.try_turn_in(def.quest_id, def, inventory)
	assert_eq(int(reward.get("reward_coins", 0)), 5)
	assert_eq(int(reward.get("reward_heal", 0)), 10)
	assert_eq(inventory.count("heart"), 0, "required items are consumed")
	assert_true(log.is_completed(def.quest_id))
	assert_false(log.is_active(def.quest_id))
	assert_true(log.try_turn_in(def.quest_id, def, inventory).is_empty(),
		"completed quests never pay twice")

func test_quest_turn_in_rejects_mismatched_def() -> void:
	var log = QuestLogScript.new()
	var inventory = InventoryScript.new()
	inventory.add("heart", 9)
	var def = _quest_def()
	log.accept("other_quest")
	assert_true(log.try_turn_in("other_quest", def, inventory).is_empty(),
		"quest id must match the definition")

func test_quest_serialization_roundtrip() -> void:
	var log = QuestLogScript.new()
	log.accept("q1")
	log.record_progress("q1", 3)
	log.accept("q2")
	log.try_turn_in("q2", _quest_def(), InventoryScript.new()) # 不满足，仍 active
	var restored = QuestLogScript.new()
	restored.load_dict(log.to_dict())
	assert_true(restored.is_active("q1"))
	assert_eq(restored.progress("q1"), 3)
	assert_true(restored.is_active("q2"))

# ============================================================================
# 数据锚点（审计剧本第 3/4 类修改的对象基线）
# ============================================================================

func test_item_and_quest_data_anchors() -> void:
	var heart_text: String = FileAccess.get_file_as_string("res://slice_b/data/item_heart.tres")
	assert_true(heart_text.contains("heal_amount = 30"), "heart heals 30 (playbook edit target)")
	assert_true(heart_text.contains("quest_item = true"))
	var quest_text: String = FileAccess.get_file_as_string("res://slice_b/data/quest_hearts.tres")
	assert_true(quest_text.contains("reward_coins = 5"), "quest reward baseline (playbook edit target)")
	assert_true(quest_text.contains("required_count = 2"))
