extends "res://addons/gut/test.gd"

const WorkflowRouterScript = preload("res://addons/godot_mcp/native_mcp/workflow_router.gd")
const ManifestScript = preload("res://addons/godot_mcp/native_mcp/tools_manifest.gd")
const TranslationManagerScript = preload("res://addons/godot_mcp/native_mcp/translation_manager.gd")
const TOOL_DESCRIPTIONS_JSON: String = "res://addons/godot_mcp/translations/tool_descriptions.json"

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
