class_name GameModelStore
extends RefCounted

# P1 持久游戏模型：记录"这个游戏现在有什么"——实体数量、当前参数值、
# 控制器脚本指纹与保护标记。三个消费方共用这一份真相：
#   1. 累积合并（_build_merged_objective）注入数量——"再加 3 个金币"
#      不再丢失数字；
#   2. 合并重生成后注入已调参数——调参成果不被后续目标的重生成覆盖；
#   3. 指纹漂移检测——用户手改过的脚本禁止被整脚本重生成覆盖。
#
# 刻意保持最小（数量 + 参数 + 指纹 + 动词）：不做通用语义场景图。
# 持久化形状 (res://.mcp/game_model.json)：
# {
#   "counts": {"coins": 3, "enemies": 2},
#   "params": {"SPEED": 260.0, "ENEMY_SPEED": 80.0, "COIN_RADIUS": 90.0},
#   "script_path": "res://scripts/gameplay-feature-01.gd",
#   "fingerprint": "sha256...",
#   "verbs": {"movement": true, ...},
#   "updated_at": "ISO8601",
#   "history": [{"goal": "...", "completed_at": "...", "counts": {...}}]  # 有界
# }

const MODEL_PATH: String = "res://.mcp/game_model.json"
const HISTORY_LIMIT: int = 12

## 蓝图默认参数值：apply_param_overrides 只在记录值与默认不同才改写
## （避免把默认值重复写回造成源码噪声）。
const BLUEPRINT_DEFAULT_PARAMS: Dictionary = {
	"SPEED": 260.0,
	"ENEMY_SPEED": 120.0,
	"COIN_RADIUS": 90.0,
}

static func load_model(path: String = MODEL_PATH) -> Dictionary:
	if not FileAccess.file_exists(path):
		return _empty_model()
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		return _empty_model()
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	file.close()
	if parsed is Dictionary:
		return parsed as Dictionary
	return _empty_model()

static func _empty_model() -> Dictionary:
	return {"counts": {}, "params": {}, "history": []}

static func save_model(model: Dictionary, path: String = MODEL_PATH) -> Dictionary:
	var dir: String = path.get_base_dir()
	if not dir.is_empty() and not DirAccess.dir_exists_absolute(dir):
		DirAccess.make_dir_recursive_absolute(dir)
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return {"error": "could not write game model"}
	file.store_string(JSON.stringify(model, "\t"))
	file.close()
	return {"saved": true}

## 文件内容 sha256（十六进制文本）。FileAccess.get_sha256 在文件不可读
## 时返回空串——调用方把空串当作"无法判定"而不是"指纹为零"。
static func file_fingerprint(path: String) -> String:
	if String(path).is_empty() or not FileAccess.file_exists(path):
		return ""
	return String(FileAccess.get_sha256(path))

## 从控制器源码解析事实（磁盘真相，而非目标语句）：数量与当前参数值。
## 未出现的常量不进结果——数量缺省由 merged_count 处理。
static func parse_script_facts(source: String) -> Dictionary:
	var counts: Dictionary = {}
	var params: Dictionary = {}
	var int_patterns: Dictionary = {
		"coins": "const COINS_TO_WIN: int = (\\d+)",
		"enemies": "const ENEMY_COUNT: int = (\\d+)",
	}
	for kind in int_patterns:
		var regex: RegEx = RegEx.new()
		if regex.compile(String(int_patterns[kind])) == OK:
			var match_result: RegExMatch = regex.search(source)
			if match_result:
				counts[kind] = int(match_result.get_string(1))
	var float_patterns: Dictionary = {
		"SPEED": "const SPEED: float = ([\\d.]+)",
		"ENEMY_SPEED": "const ENEMY_SPEED: float = ([\\d.]+)",
		"COIN_RADIUS": "const COIN_RADIUS: float = ([\\d.]+)",
	}
	for param in float_patterns:
		var regex_f: RegEx = RegEx.new()
		if regex_f.compile(String(float_patterns[param])) == OK:
			var match_f: RegExMatch = regex_f.search(source)
			if match_f:
				params[param] = float(match_f.get_string(1))
	return {"counts": counts, "params": params}

## 目标完成时调用：以磁盘上的控制器源码为准更新模型（数量/参数/指纹）。
## 调参与更名目标同样经过这里——指纹每次完成都刷新，用户手改检测的
## 基线始终是"插件最后一次确认写入"的内容。
static func apply_completion(goal: String, verbs: Dictionary,
		script_path: String, script_source: String,
		path: String = MODEL_PATH) -> Dictionary:
	if script_source.is_empty():
		return {"error": "empty script source; game model not updated"}
	var model: Dictionary = load_model(path)
	var facts: Dictionary = parse_script_facts(script_source)
	model["counts"] = facts["counts"]
	model["params"] = facts["params"]
	model["script_path"] = script_path
	model["fingerprint"] = file_fingerprint(script_path)
	model["verbs"] = verbs
	model["updated_at"] = Time.get_datetime_string_from_system(true, true)
	var history: Array = model.get("history", []) if model.get("history", []) is Array else []
	history.append({
		"goal": goal,
		"completed_at": model["updated_at"],
		"counts": (facts["counts"] as Dictionary).duplicate(true),
		"params": (facts["params"] as Dictionary).duplicate(true),
	})
	while history.size() > HISTORY_LIMIT:
		history.pop_front()
	model["history"] = history
	var save_result: Dictionary = save_model(model, path)
	if save_result.has("error"):
		return save_result
	return {
		"counts": (facts["counts"] as Dictionary).duplicate(true),
		"params": (facts["params"] as Dictionary).duplicate(true),
	}

## 合并数量：增量请求（"再加 N 个"）= existing + requested；
## 总量请求（"要 N 个"）= max(existing, requested)——数量只增不减，
## 已有成果不因新目标而丢失；**减量请求（"减少到 N 个"）= requested**
## （集合语义——用户明确要更少时，取最大等于无视指令，真机差距：
## "把三个敌人减少到一个"无法表达）。
static func merged_count(kind: String, requested: int,
		additive: bool, path: String = MODEL_PATH, reduce: bool = false) -> int:
	var model: Dictionary = load_model(path)
	var existing: int = int((model.get("counts", {}) as Dictionary).get(kind, 0))
	if reduce:
		return clampi(requested, 1, maxi(existing, 1))
	if additive:
		return existing + maxi(requested, 1)
	return maxi(existing, requested)

## 把记录的调参成果注入合并重生成的源码：调过的参数不再被蓝图默认值
## 覆盖（差距分析：调完敌速再加功能，重生成把 80 打回 120）。
## 只改写与蓝图默认不同的参数；格式化为 float 字面量保持源码风格。
static func apply_param_overrides(source: String, path: String = MODEL_PATH) -> String:
	var model: Dictionary = load_model(path)
	var params: Dictionary = model.get("params", {}) if model.get("params", {}) is Dictionary else {}
	for param in ["SPEED", "ENEMY_SPEED", "COIN_RADIUS"]:
		if not params.has(param):
			continue
		var recorded: float = float(params[param])
		if is_equal_approx(recorded, float(BLUEPRINT_DEFAULT_PARAMS.get(param, recorded))):
			continue
		var regex: RegEx = RegEx.new()
		if regex.compile("const %s: float = [\\d.]+" % String(param)) != OK:
			continue
		source = regex.sub(source, "const %s: float = %.1f" % [String(param), recorded], true)
	return source

## 用户手改检测：模型记录了指纹、脚本仍在磁盘上、内容与指纹不一致
## ——之间的差异不是插件写入的（每次目标完成都会刷新指纹），即用户手改。
## 无记录或文件缺失时返回 false（无从判定，不阻止）。
static func has_user_edits(script_path: String, path: String = MODEL_PATH) -> bool:
	if String(script_path).is_empty() or not FileAccess.file_exists(script_path):
		return false
	var model: Dictionary = load_model(path)
	if String(model.get("script_path", "")) != String(script_path):
		return false
	var recorded: String = String(model.get("fingerprint", ""))
	if recorded.is_empty():
		return false
	return file_fingerprint(script_path) != recorded

## 读取脚本中某参数的当前值（调参链按磁盘实况构造 modify_script 的
## old_text——不再假设固定基线，重复调参也能工作）。
static func current_param_value(script_source: String, param: String) -> float:
	var facts: Dictionary = parse_script_facts(script_source)
	var params: Dictionary = facts["params"]
	if params.has(param):
		return float(params[param])
	return float(BLUEPRINT_DEFAULT_PARAMS.get(param, 0.0))
