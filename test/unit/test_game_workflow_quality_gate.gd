extends "res://addons/gut/test.gd"

const EngineScript = preload("res://addons/godot_mcp/native_mcp/game_workflow_engine.gd")
const ManifestScript = preload("res://addons/godot_mcp/native_mcp/tools_manifest.gd")

const CASES: Array[Dictionary] = [
	{"goal": "Create player movement and collision gameplay", "profiles": ["gameplay_feature"], "tools": ["create_script", "upsert_project_input_action", "play_and_verify"]},
	{"goal": "创建玩家移动、输入和碰撞玩法", "profiles": ["gameplay_feature"], "tools": ["create_scene", "verify_scripts", "assert_no_runtime_errors"]},
	{"goal": "Build a polished pause UI menu and verify its visuals", "profiles": ["ui_screen"], "tools": ["create_theme", "set_anchor_preset", "assert_visual_baseline"]},
	{"goal": "制作暂停菜单界面并验证视觉效果", "profiles": ["ui_screen"], "tools": ["create_node", "get_runtime_screenshot", "assert_visual_baseline"]},
	{"goal": "Fix GDScript compile errors", "profiles": ["script_repair"], "tools": ["detect_broken_scripts", "modify_script", "verify_scripts"]},
	{"goal": "修复脚本错误和编译错误", "profiles": ["script_repair"], "tools": ["read_script", "modify_script", "run_project_tests"]},
	{"goal": "Import and validate a GLTF asset model", "profiles": ["asset_pipeline"], "tools": ["get_import_status", "inspect_gltf_asset", "scan_missing_resource_dependencies"]},
	{"goal": "导入模型资源并检查依赖", "profiles": ["asset_pipeline"], "tools": ["list_project_resources", "reimport_resources", "scan_missing_resource_dependencies"]},
	{"goal": "Create an animation with audio and music", "profiles": ["animation_audio"], "tools": ["create_animation", "update_runtime_audio_bus", "get_runtime_animation_state"]},
	{"goal": "创建角色动画和音效", "profiles": ["animation_audio"], "tools": ["insert_animation_keys", "list_runtime_audio_buses", "assert_no_runtime_errors"]},
	{"goal": "Design a TileMap level with a TileSet", "profiles": ["level_design"], "tools": ["create_tileset", "set_tilemap_layer_cells", "audit_scene_node_persistence"]},
	{"goal": "制作瓦片地图关卡并验证场景布局", "profiles": ["level_design"], "tools": ["configure_tileset_layers", "save_scene", "assert_visual_baseline"]},
	{"goal": "Debug a runtime crash and inspect the scene tree", "profiles": ["runtime_debug"], "tools": ["get_debugger_messages", "get_runtime_scene_tree", "assert_no_runtime_errors"]},
	{"goal": "调试运行时崩溃和异常", "profiles": ["runtime_debug"], "tools": ["get_debug_output", "get_runtime_info", "assert_no_runtime_errors"]},
	{"goal": "Add localization and language translations", "profiles": ["localization"], "tools": ["manage_localization"]},
	{"goal": "实现本地化和多语言翻译", "profiles": ["localization"], "tools": ["manage_localization"]},
	{"goal": "Optimize performance, FPS and memory", "profiles": ["performance"], "tools": ["get_runtime_memory_trend", "modify_script", "assert_performance_budget"]},
	{"goal": "优化性能、帧率和内存", "profiles": ["performance"], "tools": ["get_runtime_performance_snapshot", "verify_scripts", "assert_performance_budget"]},
	{"goal": "Run project tests and verify quality", "profiles": ["quality_assurance"], "tools": ["list_project_tests", "verify_scripts", "run_project_tests"]},
	{"goal": "运行项目测试和质量回归", "profiles": ["quality_assurance"], "tools": ["run_project_tests"]},
	{"goal": "Audit project health, dependencies and migration", "profiles": ["project_health"], "tools": ["audit_project_health", "scan_migration_compatibility", "scan_cyclic_resource_dependencies"]},
	{"goal": "审计项目健康、依赖和迁移问题", "profiles": ["project_health"], "tools": ["detect_broken_scripts", "scan_missing_resource_dependencies"]},
	{"goal": "Export and smoke test a Linux release build", "profiles": ["release_export"], "tools": ["validate_export_preset", "run_export", "smoke_test_export"]},
	{"goal": "导出并验证 Android 发布构建", "profiles": ["release_export"], "tools": ["configure_android_export", "validate_export_preset", "smoke_test_export"]},
	{"goal": "Create player gameplay, a pause UI menu, and run project tests", "profiles": ["gameplay_feature", "quality_assurance", "ui_screen"], "tools": ["create_script", "create_theme", "play_and_verify", "run_project_tests"]}
]

func _tool_names(plan: Dictionary) -> Array[String]:
	var names: Array[String] = []
	for task_value in plan.get("tasks", []):
		var name: String = String((task_value as Dictionary).get("tool_name", ""))
		if not name in names:
			names.append(name)
	return names

func test_bilingual_complete_game_goals_have_full_declared_recall_without_unrelated_profiles() -> void:
	var engine: RefCounted = EngineScript.new()
	var available: Array[String] = ManifestScript.tool_names()
	var expected_count: int = 0
	var matched_count: int = 0
	var profile_hits: Dictionary = {}
	var timings: Array[int] = []
	for case_value in CASES:
		var case: Dictionary = case_value
		var started: int = Time.get_ticks_usec()
		var result: Dictionary = engine.compile(String(case["goal"]), {}, available)
		timings.append(Time.get_ticks_usec() - started)
		assert_false(result.has("error"), "%s: %s" % [case["goal"], result.get("error", "")])
		if result.has("error"):
			continue
		var plan: Dictionary = result["plan"]
		var actual_profiles: Array = plan["workflow"]["goal_contract"]["profiles"]
		assert_eq(actual_profiles, case["profiles"], "Profile routing must be precise for: " + String(case["goal"]))
		for profile_value in case["profiles"]:
			profile_hits[String(profile_value)] = true
		var tools: Array[String] = _tool_names(plan)
		for expected_tool_value in case["tools"]:
			expected_count += 1
			if String(expected_tool_value) in tools:
				matched_count += 1
			else:
				fail_test("Missing %s for goal: %s" % [expected_tool_value, case["goal"]])
	assert_eq(profile_hits.size(), EngineScript.PROFILE_IDS.size(), "All 12 workflow profiles must be exercised")
	assert_eq(matched_count, expected_count, "Declared profile/capability recall must remain 100%")
	timings.sort()
	var p95_index: int = mini(timings.size() - 1, int(ceil(float(timings.size()) * 0.95)) - 1)
	var p95_ms: float = float(timings[p95_index]) / 1000.0
	print("[GameWorkflowQuality] goals=%d capability_recall=100%% profile_recall=100%% p95=%.3fms" % [CASES.size(), p95_ms])
	assert_lt(p95_ms, 5.0, "Uncached local workflow compilation P95 must stay below 5ms")
