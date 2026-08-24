extends "res://addons/gut/test.gd"

const WorkflowRouterScript = preload("res://addons/godot_mcp/native_mcp/workflow_router.gd")
const ManifestScript = preload("res://addons/godot_mcp/native_mcp/tools_manifest.gd")
const TranslationManagerScript = preload("res://addons/godot_mcp/native_mcp/translation_manager.gd")
const TOOL_DESCRIPTIONS_JSON: String = "res://addons/godot_mcp/translations/tool_descriptions.json"
const REAL_TASKS_JSON: String = "res://test/unit/fixtures/workflow_routing_tasks.json"
const REAL_TASK_TOOL_BUDGET: int = 8
const REAL_TASK_MIN_EXPECTATION_RECALL: float = 0.98
const REAL_TASK_MIN_SUCCESS_RATIO: float = 0.95
const REAL_TASK_MIN_VERIFY_RECALL: float = 0.95
const REAL_TASK_MIN_SCHEMA_SAVINGS: float = 0.97

var _router: RefCounted
var _registered: Array
var _routing_hints: Dictionary

func before_each() -> void:
	_router = WorkflowRouterScript.new()
	_registered = []
	var descriptions_value: Variant = JSON.parse_string(FileAccess.get_file_as_string(TOOL_DESCRIPTIONS_JSON))
	var descriptions: Dictionary = descriptions_value if descriptions_value is Dictionary else {}
	var translation_manager: RefCounted = TranslationManagerScript.new()
	_routing_hints = translation_manager.load_locale("zh")
	var names: Array = ManifestScript.TOOLS.keys()
	names.sort()
	for name_value in names:
		var name: String = String(name_value)
		var manifest: Dictionary = ManifestScript.TOOLS[name]
		_registered.append({
			"name": name,
			"description": String(descriptions.get(name, name.replace("_", " "))),
			"schema_tokens": 96 + name.length() * 2,
			"enabled": String(manifest.get("category", "")) in ["core", "meta"],
			"category": String(manifest.get("category", "")),
			"group": String(manifest.get("group", ""))
		})

func after_each() -> void:
	_router = null
	_registered = []
	_routing_hints = {}

func _flatten_tools(result: Dictionary) -> Array[String]:
	var names: Array[String] = []
	for stage_value in result.get("stages", []):
		var stage: Dictionary = stage_value
		for tool_value in stage.get("tools", []):
			var tool_name: String = String(tool_value)
			if tool_name not in names:
				names.append(tool_name)
	return names

func _load_real_tasks() -> Array:
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(REAL_TASKS_JSON))
	return parsed if parsed is Array else []

func _matches_required_group(names: Array[String], required_group: Array) -> bool:
	for tool_value in required_group:
		if String(tool_value) in names:
			return true
	return false

func _has_verify_stage(route: Dictionary) -> bool:
	for stage_value in route.get("stages", []):
		var stage: Dictionary = stage_value
		if String(stage.get("phase", "")) == "verify" and not stage.get("tools", []).is_empty():
			return true
	return false

func test_every_atomic_tool_is_routable_by_exact_name() -> void:
	for name_value in ManifestScript.TOOLS:
		var name: String = String(name_value)
		if String(ManifestScript.TOOLS[name].get("category", "")) == "meta":
			continue
		var route: Dictionary = _router.route(name, _registered, 1, 1, _routing_hints)
		assert_true(name in _flatten_tools(route),
			"Exact intent must route atomic tool: " + name)

func test_every_atomic_tool_is_routable_by_official_english_description() -> void:
	for info_value in _registered:
		var info: Dictionary = info_value
		if String(info.get("category", "")) == "meta":
			continue
		var name: String = String(info.get("name", ""))
		var route: Dictionary = _router.route(
			String(info.get("description", "")), _registered, 1, 1, _routing_hints)
		assert_true(name in _flatten_tools(route),
			"Official English intent must route atomic tool: " + name)

func test_every_atomic_tool_is_routable_by_official_chinese_description() -> void:
	for info_value in _registered:
		var info: Dictionary = info_value
		if String(info.get("category", "")) == "meta":
			continue
		var name: String = String(info.get("name", ""))
		var chinese_intent: String = String(_routing_hints.get(name, "")).strip_edges()
		assert_false(chinese_intent.is_empty(), "Chinese routing hint must exist: " + name)
		if chinese_intent.is_empty():
			continue
		var route: Dictionary = _router.route(chinese_intent, _registered, 1, 1, _routing_hints)
		assert_true(name in _flatten_tools(route),
			"Official Chinese intent must route atomic tool: " + name)

func test_coverage_report_is_complete_without_copying_schemas() -> void:
	var report: Dictionary = _router.get_coverage_report(_registered)
	assert_eq(report.get("routable_atomic", -1), report.get("total_atomic", -2),
		"Every non-meta tool participates in the adaptive workflow index")
	assert_eq(report.get("coverage_ratio", 0.0), 1.0,
		"Adaptive exact-name fallback provides complete atomic coverage")
	assert_eq(report.get("uncovered", []), [], "Coverage report should expose no gaps")

func test_curated_workflow_references_are_registered() -> void:
	assert_eq(_router.validate_curated_tool_references(_registered), [],
		"Curated workflow seeds must never drift from the registered tool catalog")

func test_real_game_task_corpus_meets_route_quality_gate() -> void:
	var tasks: Array = _load_real_tasks()
	assert_gte(tasks.size(), 48,
		"The route gate must cover a broad bilingual game-production corpus")
	var task_ids: Dictionary = {}
	var language_counts: Dictionary = {"en": 0, "zh": 0}
	var expectation_count: int = 0
	var expectation_hits: int = 0
	var successful_tasks: int = 0
	var verify_tasks: int = 0
	var verify_hits: int = 0
	var missing_by_task: Array[String] = []
	var forbidden_by_task: Array[String] = []
	var savings_total: float = 0.0
	var minimum_savings: float = 1.0
	for task_value in tasks:
		var task: Dictionary = task_value
		var task_id: String = String(task.get("id", "unnamed"))
		assert_false(task_ids.has(task_id), "Real-task corpus IDs must be unique: " + task_id)
		task_ids[task_id] = true
		var language: String = String(task.get("language", ""))
		language_counts[language] = int(language_counts.get(language, 0)) + 1
		var route: Dictionary = _router.route(
			String(task.get("goal", "")), _registered, REAL_TASK_TOOL_BUDGET,
			1, _routing_hints)
		var names: Array[String] = _flatten_tools(route)
		var task_missing: Array[String] = []
		for required_value in task.get("required", []):
			var required_group: Array = required_value
			expectation_count += 1
			if _matches_required_group(names, required_group):
				expectation_hits += 1
			else:
				task_missing.append("|".join(required_group))
		if task_missing.is_empty():
			successful_tasks += 1
		else:
			missing_by_task.append("%s -> %s (got: %s)" % [
				task_id, ", ".join(task_missing), ", ".join(names)])
		for forbidden_value in task.get("forbidden", []):
			var forbidden_name: String = String(forbidden_value)
			if forbidden_name in names:
				forbidden_by_task.append("%s -> %s" % [task_id, forbidden_name])
		if bool(task.get("requires_verify", false)):
			verify_tasks += 1
			if _has_verify_stage(route):
				verify_hits += 1
		var savings: float = float(route.get("estimated_token_savings_ratio", 0.0))
		savings_total += savings
		minimum_savings = min(minimum_savings, savings)
		assert_lte(names.size(), REAL_TASK_TOOL_BUDGET,
			"Real task route must respect the requested tool budget: " + task_id)
	var expectation_recall: float = float(expectation_hits) / float(max(1, expectation_count))
	var task_success_ratio: float = float(successful_tasks) / float(max(1, tasks.size()))
	var verify_recall: float = float(verify_hits) / float(max(1, verify_tasks))
	var average_savings: float = savings_total / float(max(1, tasks.size()))
	assert_gte(int(language_counts.get("en", 0)), 24,
		"The route gate must retain at least 24 English production tasks")
	assert_gte(int(language_counts.get("zh", 0)), 24,
		"The route gate must retain at least 24 Chinese production tasks")
	assert_gte(expectation_count, 170,
		"The route gate must retain broad multi-step atomic-tool expectations")
	assert_gte(expectation_recall, REAL_TASK_MIN_EXPECTATION_RECALL,
		"Recall@8 %.2f%% is below %.2f%%. Missing:\n%s" % [
			expectation_recall * 100.0, REAL_TASK_MIN_EXPECTATION_RECALL * 100.0,
			"\n".join(missing_by_task)])
	assert_gte(task_success_ratio, REAL_TASK_MIN_SUCCESS_RATIO,
		"Task success %.2f%% is below %.2f%%. Missing:\n%s" % [
			task_success_ratio * 100.0, REAL_TASK_MIN_SUCCESS_RATIO * 100.0,
			"\n".join(missing_by_task)])
	assert_gte(verify_recall, REAL_TASK_MIN_VERIFY_RECALL,
		"Write/execute tasks must retain a verification stage")
	assert_eq(forbidden_by_task, [],
		"Routes must not spend budget on known cross-domain distractors: " +
		", ".join(forbidden_by_task))
	assert_gte(average_savings, REAL_TASK_MIN_SCHEMA_SAVINGS,
		"The real-task corpus must avoid at least 97% of full-load schema tokens on average")
	assert_gte(minimum_savings, 0.90,
		"No complex route may trade away more than 10% of the full supplementary catalog")
	print("[WorkflowQuality] tasks=%d success=%.2f%% expectations=%d recall=%.2f%% verify=%.2f%% avg_savings=%.2f%% min_savings=%.2f%%" % [
		tasks.size(), task_success_ratio * 100.0, expectation_count,
		expectation_recall * 100.0, verify_recall * 100.0,
		average_savings * 100.0, minimum_savings * 100.0])

func test_multistep_chinese_goal_builds_small_phased_workflow() -> void:
	var route: Dictionary = _router.route("创建 2D 游戏角色并验证运行", _registered, 8)
	var names: Array[String] = _flatten_tools(route)
	assert_gt(names.size(), 1, "A multi-step goal should select a useful tool bundle")
	assert_lte(names.size(), 8, "Workflow output must respect the strict tool budget")
	assert_true("run_project" in names or "play_and_verify" in names,
		"A run/verify goal should include an execution verifier")
	assert_true(route.get("coverage_ratio", 0.0) > 0.0,
		"Route should report how much of the intent it covered")
	assert_false(route.has("schemas"), "Workflow route must never duplicate tool schemas")

func test_routing_is_deterministic_and_output_bounded() -> void:
	var first: Dictionary = _router.route("debug runtime error and verify performance", _registered, 999)
	var second: Dictionary = _router.route("debug runtime error and verify performance", _registered, 999)
	assert_eq(first, second, "Stable routing preserves result and prompt-cache reuse")
	assert_lte(_flatten_tools(first).size(), 10,
		"Even an excessive request is hard-capped to protect model context")

func test_cost_aware_selection_prefers_cheaper_equal_coverage() -> void:
	var catalog: Array = [
		{
			"name": "a_expensive_demo",
			"description": "Handle a demo capability.",
			"schema_tokens": 1200,
			"enabled": false,
			"category": "supplementary",
			"group": "Project-Advanced"
		},
		{
			"name": "z_cheap_demo",
			"description": "Handle a demo capability.",
			"schema_tokens": 40,
			"enabled": false,
			"category": "supplementary",
			"group": "Project-Advanced"
		}
	]
	var route: Dictionary = _router.route("demo", catalog, 1, 12)
	assert_eq(_flatten_tools(route), ["z_cheap_demo"],
		"Equal semantic coverage must choose the lower tools/list token cost")

func test_exact_atomic_intent_overrides_schema_cost() -> void:
	var catalog: Array = [
		{"name": "expensive_exact", "description": "Expensive exact.", "schema_tokens": 2000,
			"enabled": false, "category": "supplementary", "group": "Project-Advanced"},
		{"name": "cheap_exact_helper", "description": "Cheap exact helper.", "schema_tokens": 20,
			"enabled": false, "category": "supplementary", "group": "Project-Advanced"}
	]
	var route: Dictionary = _router.route("expensive_exact", catalog, 1, 13)
	assert_eq(_flatten_tools(route), ["expensive_exact"],
		"Cost optimization must never make an exact atomic capability unreachable")

func test_route_reports_compact_schema_token_savings() -> void:
	var route: Dictionary = _router.route(
		"debug runtime errors and verify performance", _registered, 8, 14, _routing_hints)
	var added_tokens: int = int(route.get("estimated_added_schema_tokens", -1))
	var full_tokens: int = int(route.get("estimated_full_load_schema_tokens", -1))
	var savings_ratio: float = float(route.get("estimated_token_savings_ratio", -1.0))
	assert_gte(added_tokens, 0, "Route reports supplementary schema tokens added to the baseline")
	assert_gt(full_tokens, added_tokens, "Bounded route must cost less than loading all supplementary schemas")
	assert_gte(savings_ratio, 0.90, "Typical route should avoid at least 90% of full-load schema tokens")
	assert_lte(savings_ratio, 1.0, "Savings ratio remains normalized")

func test_immutable_index_builds_once_per_registry_revision() -> void:
	_router.route("debug runtime errors", _registered, 8, 7, _routing_hints)
	_router.route("build a localized menu", _registered, 8, 7, _routing_hints)
	var diagnostics: Dictionary = _router.get_diagnostics()
	assert_eq(diagnostics.get("index_builds", 0), 1,
		"Different goals must reuse one normalized capability index")
	assert_eq(diagnostics.get("route_computations", 0), 2, "Unique goals compute separate routes")

func test_repeated_goal_hits_bounded_route_cache() -> void:
	var first: Dictionary = _router.route("debug runtime errors", _registered, 8, 7, _routing_hints)
	var second: Dictionary = _router.route("  DEBUG   runtime\terrors  ", _registered, 8, 7, _routing_hints)
	assert_eq(first, second, "Cached workflow must be byte-stable")
	var diagnostics: Dictionary = _router.get_diagnostics()
	assert_eq(diagnostics.get("route_computations", 0), 1, "Repeated goal avoids recomputation")
	assert_eq(diagnostics.get("route_cache_hits", 0), 1, "Repeated goal records a cache hit")

func test_visibility_changes_do_not_rebuild_or_change_workflow_route() -> void:
	var first: Dictionary = _router.route("debug runtime errors", _registered, 8, 7, _routing_hints)
	var toggled: Array = _registered.duplicate(true)
	for info_value in toggled:
		var info: Dictionary = info_value
		info["enabled"] = not bool(info.get("enabled", false))
	var second: Dictionary = _router.route("debug runtime errors", toggled, 8, 7, _routing_hints)
	assert_eq(first, second, "Visibility-only changes must preserve the task profile and cache key")
	var diagnostics: Dictionary = _router.get_diagnostics()
	assert_eq(diagnostics.get("index_builds", 0), 1, "Visibility changes do not rebuild semantic data")
	assert_eq(diagnostics.get("route_cache_hits", 0), 1, "Visibility changes reuse the immutable route")

func test_registry_revision_rebuilds_index_and_invalidates_routes() -> void:
	_router.route("debug runtime errors", _registered, 8, 7, _routing_hints)
	var extended: Array = _registered.duplicate(true)
	extended.append({
		"name": "inspect_demo_capability",
		"description": "Inspect a demo capability.",
		"enabled": false,
		"category": "supplementary",
		"group": "Project-Advanced"
	})
	_router.route("inspect demo capability", extended, 8, 8, _routing_hints)
	var diagnostics: Dictionary = _router.get_diagnostics()
	assert_eq(diagnostics.get("index_builds", 0), 2, "A definition change rebuilds the index once")
	assert_eq(diagnostics.get("route_cache_entries", 0), 1, "Old-revision routes are discarded")

func test_route_cache_is_hard_capped() -> void:
	for index in range(80):
		_router.route("unique workflow goal %d" % index, _registered, 8, 7, _routing_hints)
	assert_lte(_router.get_diagnostics().get("route_cache_entries", 999), 64,
		"Bounded LRU prevents long editor sessions from growing memory")

func test_uncached_route_p95_stays_below_five_milliseconds() -> void:
	var timings_usec: Array[int] = []
	for index in range(120):
		var started_usec: int = Time.get_ticks_usec()
		_router.route("performance workflow sample %d" % index, _registered, 8, 7, _routing_hints)
		timings_usec.append(Time.get_ticks_usec() - started_usec)
	timings_usec.sort()
	var p95_usec: int = timings_usec[int(floor(float(timings_usec.size() - 1) * 0.95))]
	print("[WorkflowPerf] uncached_p95_usec=%d" % p95_usec)
	assert_lt(p95_usec, 5000, "Uncached local routing P95 must stay below 5ms; got %dus" % p95_usec)

func test_natural_chinese_ui_goal_uses_curated_workflow() -> void:
	var route: Dictionary = _router.route("制作主菜单界面并检查主题", _registered, 6)
	assert_eq(route.get("matched_workflow", ""), "ui_screen",
		"A natural Chinese UI request should select the focused UI workflow seed")
	var names: Array[String] = _flatten_tools(route)
	assert_true("create_theme" in names or "set_theme_item" in names,
		"UI route should include a theme capability without loading the project catalog")

func test_empty_goal_returns_structured_error() -> void:
	var result: Dictionary = _router.route("   ", _registered, 8)
	assert_has(result, "error", "Blank workflow intent must be rejected")
