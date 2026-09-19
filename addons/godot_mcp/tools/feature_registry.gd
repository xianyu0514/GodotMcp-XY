class_name FeatureRegistry
extends RefCounted

# Phase B 功能归属注册表：记录每个已完成功能的动词、行为验收步骤和
# 内容指纹。新目标完成前重跑受影响功能的验收（旧行为真实重验）。
#
# Persisted shape (res://.mcp/feature_registry.json):
# {
#   "features": [
#     {
#       "id": "movement",
#       "goal": "Arrow-key player movement",
#       "verbs": {"movement": true},
#       "play_exercise": [...steps that verified it...],
#       "script_fingerprint": "sha256 at completion",
#       "completed_at": "ISO8601"
#     }
#   ]
# }

const REGISTRY_PATH: String = "res://.mcp/feature_registry.json"

static func load_registry(path: String = REGISTRY_PATH) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {"features": []}
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {"features": []}
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	file.close()
	if parsed is Dictionary and (parsed as Dictionary).get("features") is Array:
		return parsed
	return {"features": []}

static func save_registry(registry: Dictionary, path: String = REGISTRY_PATH) -> Dictionary:
	var dir: String = path.get_base_dir()
	if not dir.is_empty() and not DirAccess.dir_exists_absolute(dir):
		DirAccess.make_dir_recursive_absolute(dir)
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return {"error": "could not write feature registry"}
	file.store_string(JSON.stringify(registry, "\t"))
	file.close()
	return {"saved": true}

## 记录一个已完成的功能。play_exercise 是验证它的 play_and_verify steps。
static func record_feature(goal: String, verbs: Dictionary,
		play_exercise: Array, script_fingerprint: String,
		path: String = REGISTRY_PATH) -> Dictionary:
	var registry: Dictionary = load_registry(path)
	if registry.has("error"):
		return registry
	# 同动词功能更新（重跑同一个功能不重复记录）
	var feature_id: String = _feature_id_from_verbs(verbs)
	for feature_value in registry["features"]:
		var feature: Dictionary = feature_value
		if String(feature.get("id", "")) == feature_id:
			feature["goal"] = goal
			feature["verbs"] = verbs
			feature["play_exercise"] = play_exercise
			feature["script_fingerprint"] = script_fingerprint
			feature["completed_at"] = Time.get_datetime_string_from_system(true, true)
			return save_registry(registry, path)
	registry["features"].append({
		"id": feature_id,
		"goal": goal,
		"verbs": verbs,
		"play_exercise": play_exercise,
		"script_fingerprint": script_fingerprint,
		"completed_at": Time.get_datetime_string_from_system(true, true),
	})
	return save_registry(registry, path)

## 已注册功能的动词集合（用于增量编辑时判断哪些功能已存在）。
static func registered_verbs(path: String = REGISTRY_PATH) -> Dictionary:
	var registry: Dictionary = load_registry(path)
	var combined: Dictionary = {}
	for feature_value in registry.get("features", []):
		var verbs: Dictionary = (feature_value as Dictionary).get("verbs", {})
		for verb_key in verbs.keys():
			if bool(verbs[verb_key]):
				combined[verb_key] = true
	return combined

## 既往功能的验收步骤（用于旧行为重验）。exclude_verbs 中的动词跳过
## （新目标正在修改的功能不重验自己）。返回携带原始 goal——完成前回归
## 按"当前"语境重新推导演练（而非回放录制步骤），更名/调参后的符号
## 变化不会让旧步骤失配。
static func prior_exercises(exclude_verbs: Dictionary = {},
		path: String = REGISTRY_PATH) -> Array:
	var registry: Dictionary = load_registry(path)
	var exercises: Array = []
	for feature_value in registry.get("features", []):
		var feature: Dictionary = feature_value
		var verbs: Dictionary = feature.get("verbs", {})
		var is_excluded: bool = false
		for verb_key in exclude_verbs.keys():
			if bool(verbs.get(verb_key, false)) and bool(exclude_verbs[verb_key]):
				is_excluded = true
				break
		if is_excluded:
			continue
		var exercise: Array = feature.get("play_exercise", [])
		if not exercise.is_empty():
			exercises.append({
				"feature_id": feature.get("id", ""),
				"goal": feature.get("goal", ""),
				"steps": exercise,
			})
	return exercises

static func _feature_id_from_verbs(verbs: Dictionary) -> String:
	var active: Array = []
	# 动词表必须与蓝图的 match_verbs 全集同步（CI 实证：juice/game_over/
	# level/bgm 缺席时，"金币拾取粒子爆闪"与"加 5 金币"塌缩成同一 id
	# "collectible"——后者覆盖前者的注册条目，币数查找拿到粒子句 → 3 币窗
	# → 5 币收不满的整个级联）。
	for verb_key in ["movement", "collectible", "win", "pause", "save", "enemy", "state_machine", "audio", "juice", "game_over", "level", "bgm", "wall", "three_d"]:
		if bool(verbs.get(verb_key, false)):
			active.append(verb_key)
	return "+".join(active) if not active.is_empty() else "unknown"
