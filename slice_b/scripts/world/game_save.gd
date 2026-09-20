extends Node
## 版本化存档（门槛 B / P2 交付的存档演进骨架）。
##
## v1 只记录跨地图的部分进度：当前地图、玩家位置、访问过的地图。
## 迁移链（v1 -> v2 -> ...）在 M5 落地：save() 永远写当前 SCHEMA_VERSION，
## load() 对旧版本逐级迁移；损坏存档回退 .bak 备份后从新档开始。

const SCHEMA_VERSION: int = 1
const SAVE_PATH: String = "user://slice_b_save.json"
const BACKUP_PATH: String = "user://slice_b_save.json.bak"

signal save_loaded(data: Dictionary)
signal save_written(data: Dictionary)

var current: Dictionary = _fresh()

func _ready() -> void:
	load_save()

func _fresh() -> Dictionary:
	return {
		"schema_version": SCHEMA_VERSION,
		"visited_maps": [],
		"last_map": "",
		"player_position": {"x": 0.0, "y": 0.0},
		"items": {},
		"quests": {},
	}

## 读取 + 迁移 + 损坏回退。返回实际生效的数据（新档也算成功路径）。
func load_save() -> Dictionary:
	var parsed: Variant = _read_json(SAVE_PATH)
	if parsed is Dictionary and (parsed as Dictionary).has("schema_version"):
		var migrated: Dictionary = _migrate(parsed as Dictionary)
		if not migrated.is_empty():
			current = migrated
			save_loaded.emit(current)
			return current
	# 损坏或缺失：尝试备份，再不行从新档开始（游戏永不因存档崩溃）。
	if FileAccess.file_exists(BACKUP_PATH):
		var backup: Variant = _read_json(BACKUP_PATH)
		if backup is Dictionary and (backup as Dictionary).has("schema_version"):
			current = _migrate(backup as Dictionary)
			save_loaded.emit(current)
			return current
	current = _fresh()
	save_loaded.emit(current)
	return current

func save() -> void:
	# 写前备份当前一代：损坏回退的最近点。
	if FileAccess.file_exists(SAVE_PATH):
		DirAccess.copy_absolute(ProjectSettings.globalize_path(SAVE_PATH),
			ProjectSettings.globalize_path(BACKUP_PATH))
	current["schema_version"] = SCHEMA_VERSION
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

## 迁移链入口：旧版本逐级升到 SCHEMA_VERSION。未知未来版本返回空
## （视为损坏走备份/新档——绝不猜未来格式的语义）。
func _migrate(data: Dictionary) -> Dictionary:
	var version: int = int(data.get("schema_version", 0))
	if version > SCHEMA_VERSION:
		return {}
	while version < SCHEMA_VERSION:
		match version:
			_:
				break
		version += 1
	return data

static func _read_json(path: String) -> Variant:
	if not FileAccess.file_exists(path):
		return null
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		return null
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	file.close()
	return parsed
