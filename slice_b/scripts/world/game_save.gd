extends Node
## 版本化存档（门槛 B M4/M5 交付）。
##
## v1（M1）：visited_maps / last_map / player_position。
## v2（M4/M5）：hp / coins / 背包（items）/ 任务进度（quests）。
##
## 迁移链：save() 永远写当前 SCHEMA_VERSION；load() 把旧版本逐级升上来
## （v1 -> v2 补默认 hp/coins/空背包空任务）；未知未来版本视为损坏走
## 备份/新档——绝不猜未来格式。写前备份当前一代，损坏回退 .bak，再不
## 行从新档开始（游戏永不因存档崩溃）。

const SCHEMA_VERSION: int = 2
const SAVE_PATH: String = "user://slice_b_save.json"
const BACKUP_PATH: String = "user://slice_b_save.json.bak"

const InventoryScript = preload("res://scripts/items/inventory.gd")
const QuestLogScript = preload("res://scripts/quests/quest_log.gd")

signal save_loaded(data: Dictionary)
signal save_written(data: Dictionary)

var inventory: Inventory = InventoryScript.new()
var quest_log: QuestLog = QuestLogScript.new()
var current: Dictionary = _fresh()

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

func save() -> void:
	if FileAccess.file_exists(SAVE_PATH):
		DirAccess.copy_absolute(ProjectSettings.globalize_path(SAVE_PATH),
			ProjectSettings.globalize_path(BACKUP_PATH))
	current["schema_version"] = SCHEMA_VERSION
	current["items"] = inventory.to_dict()
	current["quests"] = quest_log.to_dict()
	var file: FileAccess = FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if file:
		file.store_string(JSON.stringify(current, "\t"))
		file.close()
	save_written.emit(current)

func record_map_visit(map_path: String) -> void:
	if not (current["visited_maps"] as Array).has(map_path):
		(current["visited_maps"] as Array).append(map_path)
	current["last_map"] = map_path
	save()

func record_player_position(position: Vector2) -> void:
	current["player_position"] = {"x": position.x, "y": position.y}

func record_combat_state(hp: int, coins_value: int) -> void:
	current["hp"] = hp
	current["coins"] = coins_value

## 迁移链：v1 -> v2（补 hp/coins/items/quests 默认）。未来版本回空。
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
	return data

func _apply(data: Dictionary) -> void:
	current = data
	inventory.load_dict(data.get("items", {}) if data.get("items", {}) is Dictionary else {})
	quest_log.load_dict(data.get("quests", {}) if data.get("quests", {}) is Dictionary else {})

static func _read_json(path: String) -> Variant:
	if not FileAccess.file_exists(path):
		return null
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		return null
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	file.close()
	return parsed
