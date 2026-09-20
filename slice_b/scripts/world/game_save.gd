extends Node
## 版本化存档（门槛 B M4/M5 交付 + 玩家全流程 P0-2 的"继续游戏"）。
##
## v1（M1）：visited_maps / last_map / player_position。
## v2（M4/M5）：hp / coins / 背包（items）/ 任务进度（quests）。
## v3（玩家全流程）：collected_item_ids（拾取物持久实例身份——重进地图
## 不重复出现）/ pending_resume（下次启动的地图与玩家状态恢复指令）。
##
## 迁移链：save() 永远写当前 SCHEMA_VERSION；load() 把旧版本逐级升上来；
## 未知未来版本视为损坏走备份/新档——绝不猜未来格式。写前备份当前一代，
## 损坏回退 .bak，再不行从新档开始（游戏永不因存档崩溃）。
##
## save() 的成败语义（P0-2 修复）：写入失败返回 false 且**不发**
## save_written——上层（HUD/演练）不能把失败当成功。

const SCHEMA_VERSION: int = 3
const SAVE_PATH: String = "user://slice_b_save.json"
const BACKUP_PATH: String = "user://slice_b_save.json.bak"

const InventoryScript = preload("res://scripts/items/inventory.gd")
const QuestLogScript = preload("res://scripts/quests/quest_log.gd")

signal save_loaded(data: Dictionary)
signal save_written(data: Dictionary)

var inventory: Inventory = InventoryScript.new()
var quest_log: QuestLog = QuestLogScript.new()
## 金币是高频读写成员（任务奖励/受击快照），与 current["coins"] 双向同步。
var coins: int = 0
var current: Dictionary = _fresh()
## 本次启动是否从存档恢复了世界（供地图/玩家决定放置方式）。
var resumed_from_save: bool = false

func _ready() -> void:
	load_save()

func _fresh() -> Dictionary:
	return {
		"schema_version": SCHEMA_VERSION,
		"visited_maps": [],
		"last_map": "",
		"player_position": {"x": 0.0, "y": 0.0},
		"hp": 100,
		"coins": 0,
		"items": {},
		"quests": {"active": {}, "completed": {}},
		"collected_item_ids": [],
		"pending_resume": {},
	}

## 读取 + 迁移 + 损坏回退。返回实际生效的数据。
func load_save() -> Dictionary:
	var parsed: Variant = _read_json(SAVE_PATH)
	if parsed is Dictionary and (parsed as Dictionary).has("schema_version"):
		var migrated: Dictionary = _migrate(parsed as Dictionary)
		if not migrated.is_empty():
			_apply(migrated)
			return current
	if FileAccess.file_exists(BACKUP_PATH):
		var backup: Variant = _read_json(BACKUP_PATH)
		if backup is Dictionary and (backup as Dictionary).has("schema_version"):
			var migrated_backup: Dictionary = _migrate(backup as Dictionary)
			if not migrated_backup.is_empty():
				_apply(migrated_backup)
				return current
	current = _fresh()
	_apply(current)
	save_loaded.emit(current)
	return current

## 写入成功才返回 true / 发 save_written；失败（目录不可写等）返回 false
## 且保持上一代文件不动（备份已先行）。调用方据此报告。
func save() -> bool:
	if FileAccess.file_exists(SAVE_PATH):
		DirAccess.copy_absolute(ProjectSettings.globalize_path(SAVE_PATH),
			ProjectSettings.globalize_path(BACKUP_PATH))
	current["schema_version"] = SCHEMA_VERSION
	# pending_resume 是本次会话的引导指令，不落盘——重启后的恢复由
	# begin_resume_if_any 依 last_map 重新装填（CI 实证：残留的 pending
	# 会让下一次启动恢复到半途状态）。
	current["pending_resume"] = {}
	current["coins"] = coins
	current["items"] = inventory.to_dict()
	current["quests"] = quest_log.to_dict()
	var file: FileAccess = FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if file == null:
		push_warning("GameSave: could not open %s for writing — save NOT written" % SAVE_PATH)
		return false
	file.store_string(JSON.stringify(current, "\t"))
	file.close()
	save_written.emit(current)
	return true

func record_map_visit(map_path: String) -> void:
	if not (current["visited_maps"] as Array).has(map_path):
		(current["visited_maps"] as Array).append(map_path)
	current["last_map"] = map_path

func record_player_position(position: Vector2) -> void:
	current["player_position"] = {"x": position.x, "y": position.y}

func record_combat_state(hp: int, coins_value: int) -> void:
	current["hp"] = hp
	current["coins"] = coins_value

## 拾取物持久身份：地图路径 + 节点名（场景内稳定且人类可读）。
static func item_id_for(map_path: String, node_name: String) -> String:
	return "%s#%s" % [map_path, node_name]

func is_item_collected(item_id: String) -> bool:
	return (current["collected_item_ids"] as Array).has(item_id)

func record_item_collected(item_id: String) -> void:
	if not is_item_collected(item_id):
		(current["collected_item_ids"] as Array).append(item_id)

## —— 继续游戏（P0-2）——
## 启动恢复：有真实进度（last_map 有效且访问过）→ 标记恢复态并切到
## 上次地图；地图侧读取 take_resume() 获取玩家位置/生命。无进度 →
## pending_resume 为空，正常新档（L1 + 出生点）。
func begin_resume_if_any(tree: SceneTree) -> bool:
	if tree == null:
		return false
	# 引导弹已装填（引导图设置过）→ 不重算：转场前的物理帧会污染共享
	# current 的 player_position（引导图玩家被墙推挤后每帧 record），
	# 重算会把污染值盖进恢复目标。弹只装一次，目标地图直接消费。
	if not (current.get("pending_resume", {}) as Dictionary).is_empty():
		return true
	var last_map: String = String(current.get("last_map", ""))
	var visited: Array = current.get("visited_maps", [])
	if last_map.is_empty() or not visited.has(last_map):
		return false
	resumed_from_save = true
	current["pending_resume"] = {
		"map": last_map,
		"position": current.get("player_position", {}),
		"hp": int(current.get("hp", 100)),
	}
	# 转场由调用方（map_root）执行：场景 _ready 期间 current_scene 尚未
	# 赋值（MCP run 实证——据此判定会静默跳过转场），调用方拿自己的
	# map_id 与恢复目标比较后自行 change_scene（deferred 安全）。
	return true

## 地图侧消费恢复指令（一次性）：返回 {position: Vector2?, hp: int?}；
## 空 = 无恢复（新档或已消费）。
func take_resume() -> Dictionary:
	var pending: Dictionary = current.get("pending_resume", {})
	if pending.is_empty():
		return {}
	current["pending_resume"] = {}
	return pending

## 迁移链：v1 -> v2 -> v3。未来版本回空。
## static：纯函数（不碰实例状态），编辑器侧验证可直接 load 调用。
static func _migrate(data: Dictionary) -> Dictionary:
	var version: int = int(data.get("schema_version", 0))
	if version > SCHEMA_VERSION:
		return {}
	if version < 2:
		data["hp"] = 100
		data["coins"] = 0
		data["items"] = {}
		data["quests"] = {"active": {}, "completed": {}}
	if version < 3:
		data["collected_item_ids"] = []
		data["pending_resume"] = {}
	return data

func _apply(data: Dictionary) -> void:
	current = data
	coins = int(data.get("coins", 0))
	inventory.load_dict(data.get("items", {}) if data.get("items", {}) is Dictionary else {})
	quest_log.load_dict(data.get("quests", {}) if data.get("quests", {}) is Dictionary else {})
	resumed_from_save = not String(data.get("last_map", "")).is_empty()
	save_loaded.emit(current)

static func _read_json(path: String) -> Variant:
	if not FileAccess.file_exists(path):
		return null
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		return null
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	file.close()
	return parsed
