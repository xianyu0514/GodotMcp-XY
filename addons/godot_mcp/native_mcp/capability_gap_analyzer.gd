# capability_gap_analyzer.gd — 能力缺口挖掘
#
# 背景：目标从来不该被工具限制卡住，正确路径是
#   Atomic Tool -> Composition -> Editor Script Fallback -> Safe Generated Code -> Capability Gap
# 但"哪次用了 fallback"过去没有任何记录，于是一个需要 7 个工具 + EditorScript
# 才能完成的操作可能重复几百次，却永远不会升级成正式原子工具。
#
# 本模块统计每次能力使用的证据，并给出是否值得新建工具的量化建议：
#   fallback_frequency / failure_frequency / tool_chain_length / token_cost / replan_count
#
# 关键区分（报告 #53）：能力缺口必须是一等公民状态 CAPABILITY_GAP，
# 既不是 FAIL，更不能伪装成 PASS。

class_name MCPCapabilityGapAnalyzer
extends RefCounted

## 缺口置信度阈值：达到即建议新增原子工具
const PROMOTE_SCORE_THRESHOLD: int = 60

## 统计窗口内最少样本数，避免一两次偶然就建议加工具
const MIN_FREQUENCY: int = 3

## 权重：各证据维度对"是否值得新增工具"的贡献
const WEIGHTS: Dictionary = {
	"fallback_ratio": 40,      # 有多大比例要靠 fallback 才能完成
	"failure_ratio": 25,       # 有多大比例最终失败
	"chain_length": 20,        # 平均需要多少个工具串联
	"replan_ratio": 10,        # 有多大比例触发重规划
	"token_cost": 5            # token 成本压力
}

## 平均工具链达到此长度即认为"组合过重"
const HEAVY_CHAIN_LENGTH: int = 4

## 平均 token 成本达到此值即认为"描述/上下文压力大"
const HEAVY_TOKEN_COST: int = 4000

const ANALYSIS_ROOT: String = "res://.mcp/capability_gaps"

var _usages: Array[Dictionary] = []
var _gaps: Dictionary = {}
var _recorded: int = 0


# ---------------------------------------------------------------------------
# 记录
# ---------------------------------------------------------------------------

## 记录一次能力使用。
##
## 字段：
##   capability: String        —— 目标所需能力的语义名（例如 "create_export_preset"）
##   goal: String              —— 触发它的目标（用于归因）
##   tool_chain: Array         —— 实际用到的工具序列
##   used_fallback: bool       —— 是否用了 EditorScript / 生成代码兜底
##   fallback_kind: String     —— editor_script | generated_code | composition | manual
##   success: bool
##   replan_count: int
##   token_cost: int
##   duration_ms: int
##   blocked_reason: String
func record_usage(entry: Dictionary) -> Dictionary:
	var capability: String = String(entry.get("capability", "")).strip_edges()
	if capability.is_empty():
		return {"error": "capability is required"}
	var record: Dictionary = {
		"capability": capability,
		"goal": String(entry.get("goal", "")).strip_edges(),
		"tool_chain": _string_array(entry.get("tool_chain", [])),
		"used_fallback": bool(entry.get("used_fallback", false)),
		"fallback_kind": String(entry.get("fallback_kind", "")).strip_edges(),
		"success": bool(entry.get("success", true)),
		"replan_count": maxi(0, int(entry.get("replan_count", 0))),
		"token_cost": maxi(0, int(entry.get("token_cost", 0))),
		"duration_ms": maxi(0, int(entry.get("duration_ms", 0))),
		"blocked_reason": String(entry.get("blocked_reason", "")).strip_edges(),
		"at": Time.get_datetime_string_from_system(true)
	}
	_usages.append(record)
	_recorded += 1
	if not _gaps.has(capability):
		_gaps[capability] = {
			"capability": capability,
			"samples": 0,
			"fallbacks": 0,
			"failures": 0,
			"replans": 0,
			"total_chain_length": 0,
			"total_token_cost": 0,
			"total_duration_ms": 0,
			"tool_frequency": {},
			"goals": [],
			"blocked_reasons": []
		}
	_absorb(_gaps[capability], record)
	return {"recorded": true, "capability": capability, "samples": int(_gaps[capability]["samples"])}


func record_many(entries: Array) -> Dictionary:
	var accepted: int = 0
	for entry_value in entries:
		if not (entry_value is Dictionary):
			continue
		if bool(record_usage(entry_value as Dictionary).get("recorded", false)):
			accepted += 1
	return {"accepted": accepted, "total": entries.size()}


# ---------------------------------------------------------------------------
# 分析
# ---------------------------------------------------------------------------

## 分析全部能力，输出按分数排序的建议。
##
## 每条建议：
## {
##   capability, samples, fallback_ratio, failure_ratio,
##   avg_chain_length, avg_token_cost, replan_ratio,
##   closest_tools, score, recommendation, reason
## }
func analyze(min_frequency: int = MIN_FREQUENCY) -> Dictionary:
	var suggestions: Array[Dictionary] = []
	for capability_value in _gaps:
		var capability: String = String(capability_value)
		var stats: Dictionary = _gaps[capability]
		var samples: int = int(stats.get("samples", 0))
		if samples < maxi(0, min_frequency):
			continue
		var fallback_ratio: float = float(stats.get("fallbacks", 0)) / float(samples)
		var failure_ratio: float = float(stats.get("failures", 0)) / float(samples)
		var replan_ratio: float = float(stats.get("replans", 0)) / float(samples)
		var avg_chain: float = float(stats.get("total_chain_length", 0)) / float(samples)
		var avg_tokens: int = int(stats.get("total_token_cost", 0)) / samples
		var score: int = _score(fallback_ratio, failure_ratio, avg_chain, replan_ratio, avg_tokens)
		var closest: Array[String] = closest_tools(capability)
		var recommendation: String = "add_atomic_tool" if score >= PROMOTE_SCORE_THRESHOLD \
			else "keep_fallback"
		suggestions.append({
			"capability": capability,
			"samples": samples,
			"fallback_ratio": _round3(fallback_ratio),
			"failure_ratio": _round3(failure_ratio),
			"replan_ratio": _round3(replan_ratio),
			"avg_chain_length": _round2(avg_chain),
			"avg_token_cost": avg_tokens,
			"avg_duration_ms": int(stats.get("total_duration_ms", 0)) / samples,
			"closest_tools": closest,
			"score": score,
			"recommendation": recommendation,
			"reason": _reason(score, fallback_ratio, failure_ratio, avg_chain, recommendation),
			"goals": (stats.get("goals", []) as Array).duplicate()
		})
	suggestions.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if int(a.get("score", 0)) != int(b.get("score", 0)):
			return int(a.get("score", 0)) > int(b.get("score", 0))
		return String(a.get("capability", "")) < String(b.get("capability", ""))
	)
	return {
		"analyzed": suggestions.size(),
		"threshold": PROMOTE_SCORE_THRESHOLD,
		"min_frequency": min_frequency,
		"total_usages": _usages.size(),
		"promote_candidates": _filter_recommendation(suggestions, "add_atomic_tool"),
		"suggestions": suggestions
	}


## 为单个能力给出建议（不要求达到最小样本数）
func analyze_capability(capability: String) -> Dictionary:
	if not _gaps.has(capability):
		return {
			"capability": capability,
			"samples": 0,
			"status": "CAPABILITY_GAP",
			"recommendation": "insufficient_evidence",
			"closest_tools": closest_tools(capability),
			"reason": "no recorded usage; treated as an explicit capability gap, not a failure"
		}
	var result: Dictionary = analyze(0)
	for suggestion_value in (result.get("suggestions", []) as Array):
		var suggestion: Dictionary = suggestion_value
		if String(suggestion.get("capability", "")) == capability:
			return suggestion
	return {"capability": capability, "samples": 0, "status": "CAPABILITY_GAP"}


## 已知能力名 -> 最接近的现成工具（供 fallback 与提示使用）
static func closest_tools(capability: String) -> Array[String]:
	var name: String = capability.strip_edges().to_lower()
	var matches: Array[String] = []
	var all_tools: Array[String] = []
	var manifest_tools: Array[String] = load(
		"res://addons/godot_mcp/native_mcp/tools_manifest.gd").tool_names()
	for tool_name in manifest_tools:
		all_tools.append(tool_name)
	# 直接包含关系优先
	for tool_name in all_tools:
		if name.contains(tool_name) or tool_name.contains(name):
			matches.append(tool_name)
	if not matches.is_empty():
		matches.sort()
		return _dedupe_front(matches, 8)
	# 退化为词元重叠打分
	var tokens: PackedStringArray = name.split("_", false)
	var scored: Array[Dictionary] = []
	for tool_name in all_tools:
		var score: int = 0
		for token in tokens:
			if token.length() >= 3 and tool_name.contains(token):
				score += 1
		if score > 0:
			scored.append({"tool_name": tool_name, "score": score})
	scored.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if int(a.get("score", 0)) != int(b.get("score", 0)):
			return int(a.get("score", 0)) > int(b.get("score", 0))
		return String(a.get("tool_name", "")) < String(b.get("tool_name", ""))
	)
	for entry_value in scored:
		matches.append(String((entry_value as Dictionary).get("tool_name", "")))
	return _dedupe_front(matches, 8)


func usage_count() -> int:
	return _usages.size()


func clear() -> void:
	_usages.clear()
	_gaps.clear()
	_recorded = 0


# ---------------------------------------------------------------------------
# 持久化
# ---------------------------------------------------------------------------

func save(path: String = "") -> Dictionary:
	var target: String = path.strip_edges()
	if target.is_empty():
		target = "%s/gaps_%s.json" % [
			ANALYSIS_ROOT,
			Time.get_datetime_string_from_system(true).replace(":", "-")]
	var payload: String = JSON.stringify({"usages": _usages, "analysis": analyze()}, "\t")
	if DirAccess.make_dir_recursive_absolute(target.get_base_dir()) != OK \
			and not DirAccess.dir_exists_absolute(target.get_base_dir()):
		return {"saved": false, "error": "cannot create directory"}
	var file: FileAccess = FileAccess.open(target, FileAccess.WRITE)
	if file == null:
		return {"saved": false, "error": "cannot open " + target}
	file.store_string(payload)
	file.close()
	return {"saved": true, "path": target, "bytes": payload.to_utf8_buffer().size()}


func load_report(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {"loaded": false, "error": "file not found: " + path}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not (parsed is Dictionary):
		return {"loaded": false, "error": "not a JSON object"}
	var data: Dictionary = parsed
	var usages: Variant = data.get("usages", [])
	if usages is Array:
		clear()
		record_many(usages as Array)
	return {"loaded": true, "usages": _usages.size()}


# ---------------------------------------------------------------------------
# 内部实现
# ---------------------------------------------------------------------------

func _absorb(stats: Dictionary, record: Dictionary) -> void:
	stats["samples"] = int(stats.get("samples", 0)) + 1
	if bool(record.get("used_fallback", false)):
		stats["fallbacks"] = int(stats.get("fallbacks", 0)) + 1
	if not bool(record.get("success", true)):
		stats["failures"] = int(stats.get("failures", 0)) + 1
	stats["replans"] = int(stats.get("replans", 0)) + int(record.get("replan_count", 0))
	stats["total_chain_length"] = int(stats.get("total_chain_length", 0)) \
		+ (record.get("tool_chain", []) as Array).size()
	stats["total_token_cost"] = int(stats.get("total_token_cost", 0)) + int(record.get("token_cost", 0))
	stats["total_duration_ms"] = int(stats.get("total_duration_ms", 0)) + int(record.get("duration_ms", 0))

	var frequency: Dictionary = stats["tool_frequency"]
	for tool_name in (record.get("tool_chain", []) as Array):
		var key: String = String(tool_name)
		frequency[key] = int(frequency.get(key, 0)) + 1

	var goal: String = String(record.get("goal", "")).strip_edges()
	if not goal.is_empty():
		var goals: Array = stats["goals"]
		if not goal in goals and goals.size() < 8:
			goals.append(goal)

	var blocked: String = String(record.get("blocked_reason", "")).strip_edges()
	if not blocked.is_empty():
		var reasons: Array = stats["blocked_reasons"]
		if not blocked in reasons and reasons.size() < 8:
			reasons.append(blocked)


static func _score(fallback_ratio: float, failure_ratio: float, avg_chain: float,
		replan_ratio: float, avg_tokens: int) -> int:
	var chain_factor: float = clampf(avg_chain / float(HEAVY_CHAIN_LENGTH), 0.0, 1.0)
	var token_factor: float = clampf(float(avg_tokens) / float(HEAVY_TOKEN_COST), 0.0, 1.0)
	var score: float = 0.0
	score += float(WEIGHTS["fallback_ratio"]) * clampf(fallback_ratio, 0.0, 1.0)
	score += float(WEIGHTS["failure_ratio"]) * clampf(failure_ratio, 0.0, 1.0)
	score += float(WEIGHTS["chain_length"]) * chain_factor
	score += float(WEIGHTS["replan_ratio"]) * clampf(replan_ratio, 0.0, 1.0)
	score += float(WEIGHTS["token_cost"]) * token_factor
	return int(roundf(score))


static func _reason(score: int, fallback_ratio: float, failure_ratio: float,
		avg_chain: float, recommendation: String) -> String:
	if recommendation == "add_atomic_tool":
		return "score %d >= %d: %.0f%% of uses needed a fallback, %.0f%% failed, avg %.1f tools chained — promote to an atomic tool" % [
			score, PROMOTE_SCORE_THRESHOLD, fallback_ratio * 100.0,
			failure_ratio * 100.0, avg_chain]
	return "score %d < %d: composition/fallback is still cheaper than a dedicated tool" % [
		score, PROMOTE_SCORE_THRESHOLD]


static func _filter_recommendation(suggestions: Array, recommendation: String) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for entry_value in suggestions:
		var entry: Dictionary = entry_value
		if String(entry.get("recommendation", "")) == recommendation:
			result.append(entry)
	return result


static func _dedupe_front(values: Array, limit: int) -> Array[String]:
	var result: Array[String] = []
	for value in values:
		var text: String = String(value)
		if not text in result:
			result.append(text)
		if result.size() >= limit:
			break
	return result


static func _round3(value: float) -> float:
	return roundf(value * 1000.0) / 1000.0


static func _round2(value: float) -> float:
	return roundf(value * 100.0) / 100.0


static func _string_array(value: Variant) -> Array[String]:
	var result: Array[String] = []
	if not (value is Array):
		return result
	for item in (value as Array):
		result.append(String(item))
	return result
