extends "res://addons/gut/test.gd"

# ============================================================================
# test_goal_coverage_corpus.gd — 目标首过规划成功率门禁（北极星指标的尺子）
#
# 语料：test/unit/fixtures/goal_coverage_tasks.json（中英双语、覆盖 12 个
# production profile 与常见组合目标）。每个条目断言两件事：
#   1. 首过规划：engine.compile(goal, {}, available) 不返回 needs_clarification
#      ——真实用户的第一句话就能进计划，而不是被打回重述；
#   2. Profile 覆盖：分类出的 profiles ⊇ expect_profiles 关键项。
# 该指标衡量"一句自然语言目标 → completed"链路的第一道闸门；低于阈值即回归。
# ============================================================================

const EngineScript = preload("res://addons/godot_mcp/native_mcp/game_workflow_engine.gd")
const ManifestScript = preload("res://addons/godot_mcp/native_mcp/tools_manifest.gd")
const CORPUS_JSON: String = "res://test/unit/fixtures/goal_coverage_tasks.json"

# 首过规划成功率阈值：真实用户目标不进 needs_clarification 的比例。
# 2026-09-03 基线：40/40 = 100%（enemy/shoot/score 词表扩充后）。
# 阈值留 5% 余量容纳语料演进；大幅提升后应同步收紧。
const MIN_FIRST_PASS_RATE: float = 0.95

var _engine: RefCounted
var _available: Array[String]


func before_each() -> void:
	_engine = EngineScript.new()
	_available = ManifestScript.tool_names()


func _load_corpus() -> Array:
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(CORPUS_JSON))
	return parsed if parsed is Array else []


func test_corpus_covers_all_production_profiles() -> void:
	var corpus: Array = _load_corpus()
	assert_gt(corpus.size(), 35, "The corpus stays broad enough to be a meaningful gate")
	var covered: Dictionary = {}
	for entry_value in corpus:
		var entry: Dictionary = entry_value
		for profile_value in entry.get("expect_profiles", []):
			covered[String(profile_value)] = true
	for profile_id in EngineScript.PROFILE_IDS:
		assert_true(covered.has(profile_id),
			"Corpus must exercise every production profile: missing %s" % profile_id)


func test_real_goal_corpus_first_pass_planning_rate() -> void:
	var corpus: Array = _load_corpus()
	var planned: int = 0
	var failures: Array[String] = []
	for entry_value in corpus:
		var entry: Dictionary = entry_value
		var goal: String = String(entry.get("goal", ""))
		var compiled: Dictionary = _engine.compile(goal, {}, _available)
		if compiled.has("error"):
			failures.append("%s -> %s" % [goal, String(compiled.get("error", "")).substr(0, 90)])
			continue
		planned += 1
		var plan: Dictionary = compiled.get("plan", {})
		var got: Dictionary = {}
		for task_value in plan.get("tasks", []):
			var profile: String = String((task_value as Dictionary).get("profile", ""))
			if not profile.is_empty():
				got[profile] = true
		for expected_value in entry.get("expect_profiles", []):
			assert_true(got.has(String(expected_value)),
				"Profile coverage gap: '%s' must select %s" % [goal, String(expected_value)])
	var rate: float = float(planned) / float(corpus.size())
	assert_gte(rate, MIN_FIRST_PASS_RATE,
		"First-pass planning rate %.0f%% (%d/%d) fell below the %.0f%% gate. Clarification loops: %s" % [
			rate * 100.0, planned, corpus.size(), MIN_FIRST_PASS_RATE * 100.0,
			"; ".join(failures.slice(0, 5))])


func test_mixed_goals_compose_expected_profiles_without_clarification() -> void:
	# 组合目标是路由最容易漏的形态：语义子句必须分别落进对应 profile。
	var mixed: Array = _load_corpus().filter(func(entry: Dictionary) -> bool:
		return (entry.get("expect_profiles", []) as Array).size() > 1)
	assert_gt(mixed.size(), 3, "The corpus keeps composite goals in scope")
	for entry_value in mixed:
		var entry: Dictionary = entry_value
		var compiled: Dictionary = _engine.compile(String(entry.get("goal", "")), {}, _available)
		assert_false(compiled.has("error"),
			"Composite goal must plan without clarification: %s" % String(compiled.get("error", "")))
