extends "res://addons/gut/test.gd"

const WorkflowRouterScript = preload("res://addons/godot_mcp/native_mcp/workflow_router.gd")
const ManifestScript = preload("res://addons/godot_mcp/native_mcp/tools_manifest.gd")

var _router: RefCounted
var _registered: Array

func before_each() -> void:
	_router = WorkflowRouterScript.new()
	_registered = []
	var names: Array = ManifestScript.TOOLS.keys()
	names.sort()
	for name_value in names:
		var name: String = String(name_value)
		var manifest: Dictionary = ManifestScript.TOOLS[name]
		_registered.append({
			"name": name,
			"description": name.replace("_", " "),
			"enabled": String(manifest.get("category", "")) in ["core", "meta"],
			"category": String(manifest.get("category", "")),
			"group": String(manifest.get("group", ""))
		})

func after_each() -> void:
	_router = null
	_registered = []

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
		var route: Dictionary = _router.route(name, _registered, 1)
		assert_true(name in _flatten_tools(route),
			"Exact intent must route atomic tool: " + name)

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
