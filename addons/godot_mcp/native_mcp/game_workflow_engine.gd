class_name GameWorkflowEngine
extends RefCounted

## Pure, deterministic orchestration for complete Godot production loops.
##
## The engine composes a small set of reusable profiles into a durable task DAG.
## It never executes arbitrary tool names: every executable step is regenerated
## from the persisted goal contract and checked against the immutable registry.
## The MCP-facing adapter owns persistence and execution; this class owns plan
## compilation, structural integrity, evidence verdicts and evidence-aware recovery.

const TaskPlanStoreScript = preload("res://addons/godot_mcp/tools/task_plan_store.gd")
const TokenEstimatorScript = preload("res://addons/godot_mcp/utils/token_estimator.gd")
const GoalBlueprintsScript = preload("res://addons/godot_mcp/native_mcp/goal_blueprints.gd")

const SCHEMA_VERSION: int = 1
const DEFAULT_STEPS_PER_RUN: int = 4
# Zero is the adaptive default: repairs may continue while their evidence changes.
# A positive value is an explicit caller policy, not a server-wide ceiling.
const DEFAULT_REPAIR_ATTEMPTS: int = 0
const PENDING_POLL_WINDOW: int = 120
const SAME_FAILURE_REPLAN_THRESHOLD: int = 3
const READY_PREVIEW_LIMIT: int = 4

const PROFILE_IDS: Array[String] = [
	"gameplay_feature",
	"ui_screen",
	"script_repair",
	"asset_pipeline",
	"animation_audio",
	"level_design",
	"runtime_debug",
	"localization",
	"performance",
	"quality_assurance",
	"project_health",
	"release_export"
]

# Build mutations from different profiles stay in production order so
# editor-current-scene operations remain adjacent. Inspection and verification
# still share their global phases, where duplicate computation is absorbed by
# the normal revision-aware result cache instead of deleting semantic steps.
const PROFILE_COMPOSITION_ORDER: Array[String] = [
	"asset_pipeline",
	"level_design",
	"gameplay_feature",
	"ui_screen",
	"animation_audio",
	"localization",
	"script_repair",
	"project_health",
	"performance",
	"quality_assurance",
	"runtime_debug",
	"release_export"
]

const PROFILE_KEYWORDS: Dictionary = {
	# gameplay_feature 词表刻意收录 platformer/jump/coin/collect/victory 等动词：
	# 插件自带 prompt 示例 "2D platformer vertical slice" 若只命中 ui_screen
	# （"screen"），规划会漏掉玩家/金币/胜利逻辑——这正是本 profile 存在的意义。
	# 注意避免误触：不用裸 "platform"（会命中 cross-platform export 类目标）。
	"gameplay_feature": ["gameplay", "player", "movement", "controller", "mechanic", "collision",
		"platformer", "jump", "coin", "collect", "collectible", "pickup", "playable",
		"victory", "win screen", "win label", "win condition",
		"enemy", "enemies", "monster", "chase", "patrol",
		"shoot", "shooter", "bullet", "projectile", "score", "scoring",
		"玩家", "移动", "控制", "玩法", "游戏机制", "碰撞", "平台跳跃", "跳跃", "金币", "收集", "拾取", "胜利", "通关", "可玩",
		"敌人", "怪物", "追击", "巡逻", "射击", "子弹", "计分", "得分"],
	"ui_screen": [" ui ", "menu", "hud", "pause", "button", "interface", "screen", "界面", "菜单", "暂停", "按钮", "主题", "屏幕"],
	"script_repair": ["script error", "fix script", "compile error", "gdscript", "c#", "脚本错误", "修复脚本", "编译错误", "代码错误"],
	"asset_pipeline": ["asset", "import", "texture", "model", "sprite", "gltf", "资源", "导入", "贴图", "模型", "精灵"],
	"animation_audio": ["animation", "audio", "sound", "music", "动画", "音频", "音效", "音乐"],
	"level_design": ["level", "tilemap", "tileset", "map", "关卡", "地图", "瓦片", "场景布局"],
	"runtime_debug": ["debug", "runtime", "crash", "stack trace", "调试", "运行时", "崩溃", "异常"],
	"localization": ["localization", "translation", "language", "locale", "本地化", "翻译", "多语言", "语言"],
	"performance": ["performance", "optimize", "fps", "frame time", "memory", "性能", "优化", "帧率", "内存"],
	"quality_assurance": ["project test", "run tests", "test suite", "quality assurance", "regression", "项目测试", "运行测试", "测试套件", "质量回归", "回归测试"],
	"project_health": ["audit", "migration", "dependency audit", "cyclic dependency", "deprecated", "project health", "审计", "迁移", "依赖审计", "循环依赖", "废弃", "项目健康"],
	"release_export": ["export", "release", "ship", "release build", "export build", "android", "linux", "windows", "导出", "发布", "出货", "发布构建", "导出构建", "打包"]
}

const STAGE_RANK: Dictionary = {
	"offline_inspect": 10,
	"build_create": 20,
	"build_configure": 20,
	"build_save": 20,
	"qa_inspect": 25,
	"static_verify": 30,
	"runtime_probe": 40,
	"runtime_run": 45,
	"runtime_inspect": 50,
	"runtime_action": 60,
	"runtime_evidence": 70,
	"release_inspect": 80,
	"release_prepare": 85,
	"release_validate": 90,
	"release_build": 95,
	"release_evidence": 100
}

const DEFAULT_PROTECTED_PATHS: Array[String] = [
	"res://addons/godot_mcp",
	"res://.mcp"
]

const PENDING_STATUSES: Array[String] = [
	"pending", "running", "queued", "accepted", "in_progress", "processing"
]

const NEGATIVE_STATUSES: Array[String] = [
	"failed", "failing", "error", "invalid", "blocked", "cancelled",
	"canceled", "timeout", "timed_out", "unconfigured", "partial",
	"skipped", "stale", "aborted", "missing", "unsupported"
]

# Mutation tools legitimately report these completion statuses; without them a
# real success such as create_project_smoke_test's "created" falls through the
# generic whitelist and is misjudged as a verification failure.
const SUCCESS_STATUSES: Array[String] = [
	"ok", "passed", "success", "completed", "healthy", "warning", "ready",
	"created", "saved", "written", "extracted", "imported", "exported",
	"recovered", "prepared", "updated", "removed", "deleted", "unchanged",
	"no_changes", "reused", "repaired"
]

const TRANSIENT_FAILURE_TERMS: Array[String] = [
	"temporarily unavailable", "temporary failure", "try again", "retry",
	"rate limit", "too many requests", "server busy", "connection reset",
	"connection refused", "connection closed", "network error", "timed out",
	"timeout", "http 429", "http 502", "http 503", "http 504", "(429)",
	"(502)", "(503)", "(504)"
]

# Creation tools register their produced resources as workflow artifacts so
# later steps can derive required inputs (script_path/scene_path/...) instead
# of stalling on needs_input or making the caller repeat every path.
const ARTIFACT_KIND_BY_TOOL: Dictionary = {
	"create_scene": "scene",
	"open_scene": "scene",
	"save_scene": "scene",
	"create_script": "script",
	"create_theme": "theme",
	"create_tileset": "tileset",
	"create_animation": "animation",
	"get_runtime_screenshot": "screenshot",
	"generate_3d_asset": "model",
	"run_export": "export_artifact",
	"ensure_project_directory": "test_dir",
	"create_project_smoke_test": "smoke_test"
}

const ARTIFACT_PATH_KEYS: Array[String] = [
	"scene_path", "script_path", "theme_path", "tileset_path",
	"animation_path", "test_path", "save_path", "saved_path",
	"resource_path", "output_path", "path"
]

const VOLATILE_FAILURE_KEYS: Array[String] = [
	"at", "last_at", "timestamp", "elapsed_ms", "duration_ms", "progress",
	"request_id", "trace_id",
	# 视觉门禁对活游戏重截图，diff 数值每轮必变：不剥离会让
	# SAME_FAILURE_REPLAN_THRESHOLD 永不触发（每轮都是"新失败"），
	# 修复循环在自适应模式下无界打转。
	"diff_pixel_count", "diff_ratio", "rmse", "max_channel_delta"
]

const FORBIDDEN_NESTED_CAPABILITIES: Array[String] = [
	"plan_game_workflow", "run_game_workflow", "manage_task_plan",
	"list_tool_catalog", "search_tools", "get_tool_details", "enable_tools"
]

# Goals frequently name a capability only to exclude it ("Android 不适用" /
# "3D not applicable"). Treating every literal mention as affirmative intent
# selected wrong platforms and wrong gates, so intent detection must skip
# occurrences that carry a nearby negation marker.
const NEGATION_MARKERS: Array[String] = [
	"不适用", "无需", "不要", "不需要", "不支持", "禁止", "排除", "不含",
	"not ", "without", "unsupported", "unneeded", "no need", "exclude",
	"except", "avoid", "don't", "doesn't", "n/a"
]

## True when `term` is mentioned in `text` at least once WITHOUT a nearby
## negation marker. All-negated mentions mean the goal excludes the term.
func has_affirmative_mention(text: String, term: String) -> bool:
	var lower: String = text.to_lower()
	var needle: String = term.to_lower()
	if needle.is_empty():
		return false
	var search_from: int = 0
	while true:
		var hit: int = lower.find(needle, search_from)
		if hit < 0:
			return false
		var window_start: int = maxi(0, hit - 16)
		var window_end: int = mini(lower.length(), hit + needle.length() + 16)
		var window: String = lower.substr(window_start, window_end - window_start)
		var negated: bool = false
		for marker in NEGATION_MARKERS:
			if window.contains(marker):
				negated = true
				break
		if not negated:
			return true
		search_from = hit + needle.length()
	return false

func compile(objective: String, options: Dictionary, available_tools: Array[String]) -> Dictionary:
	var clean_objective: String = objective.strip_edges()
	if clean_objective.is_empty():
		return _clarification_error("objective is required")

	var required_capabilities: Array[String] = []
	if options.get("required_capabilities") is Array:
		for capability_value in options["required_capabilities"]:
			var capability: String = String(capability_value).strip_edges()
			if not capability.is_empty() and not capability in required_capabilities:
				required_capabilities.append(capability)
		required_capabilities.sort()

	var profile_result: Dictionary = _select_profiles(clean_objective, options.get("profiles", []))
	if profile_result.has("error") and required_capabilities.is_empty():
		return profile_result
	var profiles: Array[String] = []
	if not profile_result.has("error"):
		for profile_value in profile_result.get("profiles", []):
			profiles.append(String(profile_value))
	var platform: String = _normalize_platform(String(options.get("platform", "")), clean_objective)
	var repair_attempts: int = maxi(
		int(options.get("max_repair_attempts", DEFAULT_REPAIR_ATTEMPTS)), 0)
	# expect_fail maps gate step keys (for example {"verify_scripts": true}) to
	# inverted verdicts so fault-injection loops can prove detectors actually fail.
	var expect_fail: Dictionary = options.get("expect_fail", {}) \
		if options.get("expect_fail", {}) is Dictionary else {}
	var protected_paths: Array[String] = DEFAULT_PROTECTED_PATHS.duplicate()
	if options.get("protected_paths") is Array:
		for path_value in options["protected_paths"]:
			var protected_path: String = String(path_value).strip_edges()
			if not protected_path.is_empty() and not protected_path in protected_paths:
				protected_paths.append(protected_path)
	protected_paths.sort()

	var specs: Array[Dictionary] = []
	var ordered_profiles: Array[String] = []
	for known_profile in PROFILE_COMPOSITION_ORDER:
		if known_profile in profiles:
			ordered_profiles.append(known_profile)
	for profile_id in ordered_profiles:
		for spec_value in _profile_specs(profile_id, clean_objective, platform):
			var profile_spec: Dictionary = (spec_value as Dictionary).duplicate(true)
			profile_spec["profile"] = profile_id
			specs.append(profile_spec)
	for capability in required_capabilities:
		if capability in FORBIDDEN_NESTED_CAPABILITIES:
			return {
				"error": "Capability '%s' cannot be nested inside a game workflow" % capability,
				"status": "blocked",
				"missing_capabilities": [capability]
			}
		if _specs_contain_tool(specs, capability):
			# Explicit atomic intent is objective evidence even when profile
			# classification already contributed the same tool. Otherwise a broad
			# profile gate could complete while the named capability was skipped.
			for spec_index in range(specs.size()):
				if String(specs[spec_index].get("tool_name", "")) == capability:
					specs[spec_index]["objective_gate"] = true
		else:
			# Every explicitly selected atomic result is objective evidence,
			# including an extra capability appended to a recognized profile; a
			# broad profile gate can never stand in for the user's named operation.
			var required_spec: Dictionary = _spec(
				capability, capability, _infer_stage(capability), true)
			required_spec["profile"] = "required_capability"
			specs.append(required_spec)
	if _specs_need_runtime(specs):
		if not _specs_contain_tool(specs, "install_runtime_probe"):
			var probe_spec: Dictionary = _spec("runtime_probe", "install_runtime_probe", "runtime_probe")
			probe_spec["profile"] = "runtime_prerequisite"
			specs.append(probe_spec)
		if not _specs_contain_tool(specs, "run_project"):
			var run_spec: Dictionary = _spec("runtime_run", "run_project", "runtime_run")
			run_spec["profile"] = "runtime_prerequisite"
			specs.append(run_spec)
	for index in range(specs.size()):
		specs[index]["_compose_order"] = index
	specs = _sort_specs(specs)

	var missing: Array[String] = []
	for spec_value in specs:
		var tool_name: String = String((spec_value as Dictionary).get("tool_name", ""))
		if not tool_name in available_tools and not tool_name in missing:
			missing.append(tool_name)
	for capability in required_capabilities:
		if not capability in available_tools and not capability in missing:
			missing.append(capability)
	missing.sort()
	if not missing.is_empty():
		return {
			"error": "Required workflow capabilities are not registered: %s" % ", ".join(missing),
			"status": "blocked",
			"missing_capabilities": missing,
			"profiles": profiles
		}

	var contract: Dictionary = {
		"objective": clean_objective,
		"profiles": profiles,
		"required_capabilities": required_capabilities,
		"platform": platform,
		"max_repair_attempts": repair_attempts,
		"protected_paths": protected_paths,
		"expect_fail": expect_fail.duplicate(true)
	}
	var plan: Dictionary = _build_plan(contract, specs)
	return {
		"status": "planned",
		"plan": plan,
		"workflow": summarize(plan)
	}

func _clarification_error(message: String) -> Dictionary:
	return {
		"error": message,
		"status": "needs_clarification",
		"supported_profiles": PROFILE_IDS
	}

func classify_profiles(objective: String, requested: Array = []) -> Dictionary:
	return _select_profiles(objective, requested)

func _select_profiles(objective: String, requested) -> Dictionary:
	var selected: Array[String] = []
	if requested is Array and not (requested as Array).is_empty():
		for value in requested:
			var profile_id: String = String(value).strip_edges()
			if not profile_id in PROFILE_IDS:
				return _clarification_error("Unknown workflow profile '%s'" % profile_id)
			if not profile_id in selected:
				selected.append(profile_id)
	else:
		var normalized: String = " " + objective.to_lower().replace("_", " ").replace("-", " ") + " "
		for profile_id in PROFILE_IDS:
			for keyword_value in PROFILE_KEYWORDS.get(profile_id, []):
				if normalized.contains(String(keyword_value)):
					selected.append(profile_id)
					break
	if selected.is_empty():
		return _clarification_error(
			"Objective does not identify a supported production workflow; provide profiles explicitly")
	selected.sort()
	return {"profiles": selected}

func _normalize_platform(platform: String, objective: String) -> String:
	var normalized: String = platform.strip_edges().to_lower()
	if not normalized.is_empty():
		return normalized
	var goal: String = objective.to_lower()
	for candidate in ["android", "linux", "windows", "macos", "web", "ios"]:
		if has_affirmative_mention(goal, candidate):
			return candidate
	return ""

func _spec(key: String, tool_name: String, stage: String, objective_gate: bool = false,
		arguments: Dictionary = {}, repair_tool: String = "") -> Dictionary:
	return {
		"key": key,
		"tool_name": tool_name,
		"stage": stage,
		"objective_gate": objective_gate,
		"arguments": arguments,
		"repair_tool": repair_tool
	}


## 蓝图控制器用到的四个移动动作（方向键 + WASD 双绑定）。
## upsert_project_input_action 的事件载荷直接使用引擎键码常量。
func _movement_input_actions() -> Array[Dictionary]:
	return [
		{
			"action_name": "move_left",
			"deadzone": 0.2,
			"events": [
				{"type": "key", "keycode": KEY_LEFT},
				{"type": "key", "keycode": KEY_A}
			]
		},
		{
			"action_name": "move_right",
			"deadzone": 0.2,
			"events": [
				{"type": "key", "keycode": KEY_RIGHT},
				{"type": "key", "keycode": KEY_D}
			]
		},
		{
			"action_name": "move_up",
			"deadzone": 0.2,
			"events": [
				{"type": "key", "keycode": KEY_UP},
				{"type": "key", "keycode": KEY_W}
			]
		},
		{
			"action_name": "move_down",
			"deadzone": 0.2,
			"events": [
				{"type": "key", "keycode": KEY_DOWN},
				{"type": "key", "keycode": KEY_S}
			]
		}
	]

## 横版跳跃目标的输入动作：只有左右移动 + 跳跃（Space/上方向键）。
## 俯视四方向里 upsert move_up/move_down 对跳跃蓝图是无意义动作。
func _sideview_input_actions() -> Array[Dictionary]:
	return [
		{
			"action_name": "move_left",
			"deadzone": 0.2,
			"events": [
				{"type": "key", "keycode": KEY_LEFT},
				{"type": "key", "keycode": KEY_A}
			]
		},
		{
			"action_name": "move_right",
			"deadzone": 0.2,
			"events": [
				{"type": "key", "keycode": KEY_RIGHT},
				{"type": "key", "keycode": KEY_D}
			]
		},
		{
			"action_name": "jump",
			"deadzone": 0.2,
			"events": [
				{"type": "key", "keycode": KEY_SPACE},
				{"type": "key", "keycode": KEY_UP}
			]
		}
	]

func _profile_specs(profile_id: String, objective: String, platform: String) -> Array[Dictionary]:
	var goal: String = objective.to_lower()
	match profile_id:
		"gameplay_feature":
			var gameplay_specs: Array[Dictionary] = [
				_spec("project_info", "get_project_info", "offline_inspect"),
				_spec("input_actions", "list_project_input_actions", "offline_inspect"),
				_spec("create_scene", "create_scene", "build_create"),
				_spec("create_script", "create_script", "build_create"),
				_spec("attach_script", "attach_script", "build_configure"),
				_spec("upsert_input", "upsert_project_input_action", "build_configure"),
				_spec("save_scene", "save_scene", "build_save"),
				_spec("verify_scripts", "verify_scripts", "static_verify", true, {}, "modify_script"),
				_spec("play_verify", "play_and_verify", "runtime_evidence", true, {}, "modify_script"),
				_spec("runtime_errors", "assert_no_runtime_errors", "runtime_evidence", true, {}, "modify_script")
			]
			# 移动类目标：蓝图控制器读取 move_left/right/up/down 四个动作。
			# 单个默认 upsert 只注册 move_up，get_vector 会因其余动作缺失而退化
			# 为 ui_* 回退——这里按目标词表补全四个方向动作（方向键 + WASD）。
			# 跳跃目标例外：横版蓝图只读左右轴 + jump（见 _sideview_input_actions），
			# 注册 move_up/move_down 反而制造与跳跃语义冲突的无用动作。
			if GoalBlueprintsScript._mentions(goal, GoalBlueprintsScript.MOVEMENT_KEYWORDS):
				var index: int = gameplay_specs.find_custom(func(spec: Dictionary) -> bool:
					return String(spec.get("key", "")) == "upsert_input")
				if index >= 0:
					gameplay_specs.remove_at(index)
				var movement_actions: Array[Dictionary] = _movement_input_actions()
				if GoalBlueprintsScript._mentions(goal, GoalBlueprintsScript.JUMP_KEYWORDS):
					movement_actions = _sideview_input_actions()
				for direction in movement_actions:
					gameplay_specs.insert(2, _spec(
						"input_%s" % direction.get("action_name", "").replace("move_", ""),
						"upsert_project_input_action", "build_configure", false, direction))
			# 蓝图脚本永远 extends CharacterBody2D（金币/胜利蓝图同样依赖物理体），
			# 根节点类型直接写进 create_scene 的 spec 参数——引擎直出的计划即
			# 自包含，适配器无需再派生。
			if GoalBlueprintsScript.has_any_verb(GoalBlueprintsScript.match_verbs(goal)):
				for spec_value in gameplay_specs:
					var spec: Dictionary = spec_value
					if String(spec.get("tool_name", "")) == "create_scene":
						var scene_args: Dictionary = spec.get("arguments", {})
						if not scene_args.has("root_node_type"):
							scene_args["root_node_type"] = "CharacterBody2D"
							spec["arguments"] = scene_args
						break
				# 目标语义证据：命中动词的目标额外生成一个 McpGameTestSuite
				# （内容在适配器按目标与场景工件派生），并作为 objective gate
				# 执行——completed 从"没有报错"升级为"目标行为真的发生"。
				# 置于 static_verify 而非 runtime_* 阶段：子进程自起 headless
				# 引擎，不需要探针/运行中项目的自动前置。
				gameplay_specs.append(_spec("semantic_test", "create_script", "build_save", false,
					{"script_path": "res://tests/game/gameplay_semantic.gd"}))
				gameplay_specs.append(_spec("game_semantics", "run_game_tests", "static_verify", true,
					{"test_paths": ["res://tests/game/gameplay_semantic.gd"], "timeout_ms": 240000},
					"modify_script"))
			return gameplay_specs
		"ui_screen":
			return [
				_spec("current_scene", "get_current_scene", "offline_inspect"),
				_spec("create_theme", "create_theme", "build_create"),
				_spec("ui_scene", "create_scene", "build_create"),
				_spec("ui_node", "create_node", "build_create"),
				_spec("ui_anchor", "set_anchor_preset", "build_configure"),
				_spec("ui_save", "save_scene", "build_save"),
				_spec("runtime_screenshot", "get_runtime_screenshot", "runtime_inspect"),
				_spec("visual_gate", "assert_visual_baseline", "runtime_evidence", true, {}, "batch_update_node_properties")
			]
		"script_repair":
			return [
				_spec("list_scripts", "list_project_scripts", "offline_inspect"),
				_spec("broken_scripts", "detect_broken_scripts", "offline_inspect"),
				_spec("read_script", "read_script", "offline_inspect"),
				_spec("modify_script", "modify_script", "build_configure"),
				_spec("verify_scripts", "verify_scripts", "static_verify", true, {}, "modify_script"),
				_spec("project_tests", "run_project_tests", "static_verify", true, {}, "modify_script")
			]
		"asset_pipeline":
			var asset_specs: Array[Dictionary] = [
				_spec("project_resources", "list_project_resources", "offline_inspect"),
				_spec("import_status", "get_import_status", "offline_inspect"),
				_spec("reimport", "reimport_resources", "build_configure"),
				_spec("missing_dependencies", "scan_missing_resource_dependencies", "static_verify", true)
			]
			if has_affirmative_mention(goal, "gltf") or has_affirmative_mention(goal, "3d") \
					or has_affirmative_mention(goal, "模型"):
				asset_specs.append(_spec("inspect_gltf", "inspect_gltf_asset", "static_verify", true))
			return asset_specs
		"animation_audio":
			var media_specs: Array[Dictionary] = [
				# 运行时链需要真实载体：自己的场景 + AnimationPlayer + 接线后的
				# 保存，否则 list/play 动画步骤无目标可查。
				_spec("media_scene", "create_scene", "build_create"),
				_spec("anim_player", "create_node", "build_create", false,
					{"parent_path": "/root", "node_type": "AnimationPlayer", "node_name": "AnimPlayer"}),
				_spec("create_animation", "create_animation", "build_create"),
				_spec("animation_keys", "insert_animation_keys", "build_configure"),
				_spec("media_save", "save_scene", "build_save"),
				_spec("runtime_animations", "list_runtime_animations", "runtime_inspect"),
				_spec("play_animation", "play_runtime_animation", "runtime_action"),
				_spec("animation_state", "get_runtime_animation_state", "runtime_evidence", true),
				_spec("media_runtime_errors", "assert_no_runtime_errors", "runtime_evidence", true, {}, "modify_script")
			]
			if goal.contains("audio") or goal.contains("sound") or goal.contains("music") or goal.contains("音频") or goal.contains("音效") or goal.contains("音乐"):
				media_specs.append(_spec("audio_buses", "list_runtime_audio_buses", "runtime_inspect"))
				media_specs.append(_spec("audio_bus", "get_runtime_audio_bus", "runtime_inspect"))
				media_specs.append(_spec("update_audio_bus", "update_runtime_audio_bus", "runtime_action"))
			return media_specs
		"level_design":
			return [
				_spec("project_scenes", "list_project_scenes", "offline_inspect"),
				_spec("level_scene", "create_scene", "build_create"),
				_spec("tileset", "create_tileset", "build_create"),
				_spec("tileset_layers", "configure_tileset_layers", "build_configure"),
				# TileMapLayer 节点是 set_tilemap_layer_cells 的写入目标，
				# 缺这一步整个 profile 在新场景上无从落笔。
				_spec("map_node", "create_node", "build_create", false,
					{"parent_path": "/root", "node_type": "TileMapLayer", "node_name": "LevelTiles"}),
				_spec("tilemap_cells", "set_tilemap_layer_cells", "build_configure"),
				_spec("level_save", "save_scene", "build_save"),
				_spec("persistence_gate", "audit_scene_node_persistence", "static_verify", true),
				_spec("level_screenshot", "get_runtime_screenshot", "runtime_inspect"),
				_spec("level_visual_gate", "assert_visual_baseline", "runtime_evidence", true, {}, "batch_scene_node_edits")
			]
		"runtime_debug":
			return [
				_spec("editor_logs", "get_editor_logs", "offline_inspect"),
				_spec("debug_broken_scripts", "detect_broken_scripts", "offline_inspect"),
				_spec("runtime_info", "get_runtime_info", "runtime_inspect"),
				_spec("debug_output", "get_debug_output", "runtime_inspect"),
				_spec("debugger_messages", "get_debugger_messages", "runtime_inspect"),
				_spec("runtime_tree", "get_runtime_scene_tree", "runtime_inspect"),
				_spec("runtime_error_gate", "assert_no_runtime_errors", "runtime_evidence", true, {}, "modify_script")
			]
		"localization":
			return [
				_spec("localization_list", "manage_localization", "offline_inspect", false, {"action": "list"}),
				_spec("localization_extract", "manage_localization", "build_create", false, {"action": "extract"}),
				_spec("localization_import", "manage_localization", "build_configure", true, {"action": "import"})
			]
		"performance":
			var perf_specs: Array[Dictionary] = [
				_spec("performance_snapshot", "get_runtime_performance_snapshot", "runtime_inspect"),
				_spec("memory_trend", "get_runtime_memory_trend", "runtime_inspect"),
				_spec("performance_gate", "assert_performance_budget", "runtime_evidence", true, {}, "modify_script"),
				_spec("performance_errors", "assert_no_runtime_errors", "runtime_evidence", true, {}, "modify_script")
			]
			if goal.contains("optimiz") or goal.contains("优化") or goal.contains("improve") or goal.contains("降低"):
				perf_specs.append(_spec("performance_scripts", "list_project_scripts", "offline_inspect"))
				perf_specs.append(_spec("performance_read", "read_script", "offline_inspect"))
				perf_specs.append(_spec("performance_modify", "modify_script", "build_configure"))
				perf_specs.append(_spec("performance_verify_scripts", "verify_scripts", "static_verify", true, {}, "modify_script"))
			return perf_specs
		"quality_assurance":
			return [
				_spec("test_env", "prepare_project_test_environment", "offline_inspect"),
				_spec("test_dir", "ensure_project_directory", "build_configure", false, {"path": "res://test"}),
				_spec("test_discovery", "list_project_tests", "qa_inspect", true, {}, "create_project_smoke_test"),
				_spec("qa_1_verify_scripts", "verify_scripts", "static_verify", true, {}, "modify_script"),
				_spec("qa_2_tests", "run_project_tests", "static_verify", true, {}, "modify_script")
			]
		"project_health":
			var fix_migration: bool = _goal_authorizes_fix(goal) and (goal.contains("migration") or goal.contains("迁移"))
			var full_health_gate: bool = goal.contains("audit") or goal.contains("project health") or goal.contains("审计") or goal.contains("项目健康")
			var health_specs: Array[Dictionary] = [
				_spec("health_audit_initial", "audit_project_health", "offline_inspect"),
				_spec("migration_scan", "scan_migration_compatibility", "offline_inspect"),
				_spec("dependency_scan", "scan_missing_resource_dependencies", "offline_inspect"),
				_spec("cycle_scan", "scan_cyclic_resource_dependencies", "offline_inspect"),
				_spec("deprecated_scan", "find_deprecated_api_usage", "offline_inspect"),
				_spec("health_broken_scripts", "detect_broken_scripts", "offline_inspect")
			]
			if fix_migration:
				health_specs.append(_spec("migration_fix", "apply_migration_fixes", "build_configure", false, {"dry_run": false}))
				health_specs.append(_spec("migration_verify", "scan_migration_compatibility", "static_verify", true, {"target_version": "4.7"}))
				health_specs.append(_spec("migration_scripts", "verify_scripts", "static_verify", true, {}, "modify_script"))
			if full_health_gate:
				health_specs.append(_spec("health_audit_gate", "audit_project_health", "static_verify", true, {"include_warnings": true}))
			return health_specs
		"release_export":
			# 预设按目标推断的平台生成（此前硬编码 Windows Desktop："export
			# for web" 会静默产出 game.exe 且整链 completed）。validate/run/
			# smoke 的派生与这里共用 export_preset_for_platform，保证同名同源。
			var export_preset: Dictionary = export_preset_for_platform(platform)
			var release_specs: Array[Dictionary] = [
				_spec("export_presets", "list_export_presets", "release_inspect"),
				_spec("export_templates", "inspect_export_templates", "release_inspect"),
				# 全新项目没有导出预设：先建目标平台的预设，validate/run_export
				# 链才有目标。if_exists="reuse" 保证 replan 重放时已存在的预设是
				# 幂等成功而非报错（否则无 repair_tool 的步骤会永久卡在
				# replan_required）；重名但平台/产物路径不符时会被纠偏对齐。
				_spec("release_preset", "create_export_preset", "release_prepare", false,
					{"name": export_preset["name"], "platform": export_preset["platform"],
					 "export_path": export_preset["export_path"], "if_exists": "reuse"})
			]
			if platform == "android":
				release_specs.append(_spec("android_config", "configure_android_export",
					"release_prepare", false, {"preset": export_preset["name"]}))
			release_specs.append(_spec("validate_export", "validate_export_preset", "release_validate", true))
			release_specs.append(_spec("run_export", "run_export", "release_build"))
			release_specs.append(_spec("smoke_export", "smoke_test_export", "release_evidence", true))
			return release_specs
	return []

## 平台 → 导出预设三要素（名称/平台/产物路径）。引擎与 runner 的派生共用
## 此表，保证"建预设/校验/导出/冒烟"链上的预设名一源同出。
const EXPORT_PLATFORM_PRESETS: Dictionary = {
	"windows": {"name": "Windows Desktop", "platform": "Windows Desktop",
		"export_path": "res://build/game.exe"},
	"linux": {"name": "Linux/X11", "platform": "Linux/X11",
		"export_path": "res://build/game.x86_64"},
	"macos": {"name": "macOS", "platform": "macOS",
		"export_path": "res://build/game.zip"},
	"web": {"name": "Web", "platform": "Web",
		"export_path": "res://build/web/index.html"},
	"android": {"name": "Android", "platform": "Android",
		"export_path": "res://build/game.apk"},
	"ios": {"name": "iOS", "platform": "iOS",
		"export_path": "res://build/game.ipa"},
}

static func export_preset_for_platform(platform: String) -> Dictionary:
	var preset: Dictionary = EXPORT_PLATFORM_PRESETS.get(platform, {})
	if preset.is_empty():
		return EXPORT_PLATFORM_PRESETS["windows"].duplicate(true)
	return preset.duplicate(true)

func _goal_authorizes_fix(goal: String) -> bool:
	for word in ["fix", "repair", "apply", "resolve", "修复", "处理", "应用"]:
		if goal.contains(word):
			return true
	return false

func _infer_stage(tool_name: String) -> String:
	if tool_name == "install_runtime_probe":
		return "runtime_probe"
	if tool_name == "run_project":
		return "runtime_run"
	if tool_name.begins_with("get_runtime_") or tool_name.begins_with("list_runtime_") or tool_name == "inspect_runtime_node":
		return "runtime_inspect"
	if tool_name.begins_with("assert_") or tool_name == "play_and_verify":
		return "runtime_evidence"
	if tool_name.begins_with("get_") or tool_name.begins_with("list_") or tool_name.begins_with("scan_") or tool_name.begins_with("find_") or tool_name.begins_with("audit_") or tool_name.begins_with("detect_") or tool_name.begins_with("inspect_") or tool_name.begins_with("read_"):
		return "offline_inspect"
	if tool_name.begins_with("verify_") or tool_name.begins_with("validate_") or tool_name.begins_with("run_project_test"):
		return "static_verify"
	return "build_configure"

func _specs_contain_tool(specs: Array[Dictionary], tool_name: String) -> bool:
	for value in specs:
		if String((value as Dictionary).get("tool_name", "")) == tool_name:
			return true
	return false

func _specs_need_runtime(specs: Array[Dictionary]) -> bool:
	for value in specs:
		var stage: String = String((value as Dictionary).get("stage", ""))
		if stage.begins_with("runtime_") and stage not in ["runtime_probe", "runtime_run"]:
			return true
	return false

func _sort_specs(specs: Array[Dictionary]) -> Array[Dictionary]:
	var result: Array[Dictionary] = specs.duplicate(true)
	result.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var ar: int = int(STAGE_RANK.get(String(a.get("stage", "")), 999))
		var br: int = int(STAGE_RANK.get(String(b.get("stage", "")), 999))
		if ar != br:
			return ar < br
		var ao: int = int(a.get("_compose_order", 0))
		var bo: int = int(b.get("_compose_order", 0))
		if ao != bo:
			return ao < bo
		return String(a.get("key", "")) < String(b.get("key", ""))
	)
	return result

func _build_plan(contract: Dictionary, specs: Array[Dictionary]) -> Dictionary:
	var plan: Dictionary = TaskPlanStoreScript.new_plan(String(contract.get("objective", "")))
	var tasks: Array[Dictionary] = []
	var objective_gate_ids: Array[String] = []
	var prior_ids: Array[String] = []
	var blueprint_tasks: Array[Dictionary] = []
	var max_attempts: int = int(contract.get("max_repair_attempts", DEFAULT_REPAIR_ATTEMPTS))
	var expect_fail: Dictionary = contract.get("expect_fail", {}) \
		if contract.get("expect_fail", {}) is Dictionary else {}
	for index in range(specs.size()):
		var spec: Dictionary = specs[index]
		var step_id: String = "wf_%03d" % (index + 1)
		var is_gate: bool = bool(spec.get("objective_gate", false))
		var repair_tool: String = String(spec.get("repair_tool", ""))
		var task: Dictionary = {
			"id": step_id,
			"title": "%s / %s: %s" % [String(spec.get("profile", "")), String(spec.get("stage", "")), String(spec.get("tool_name", ""))],
			"description": "Execute the plan-authorized atomic MCP capability and retain compact evidence.",
			"status": "pending",
			"depends_on": prior_ids.duplicate(),
			"dod": [{"criterion": "Objective evidence accepted", "met": false, "evidence": ""}] if is_gate else [],
			"tags": ["game_workflow", String(spec.get("stage", ""))],
			"journal": [],
			"created_at": plan.get("created_at", ""),
			"updated_at": plan.get("created_at", ""),
			"tool_name": String(spec.get("tool_name", "")),
			"profile": String(spec.get("profile", "")),
			"step_key": String(spec.get("key", "")),
			"stage": String(spec.get("stage", "")),
			"arguments": (spec.get("arguments", {}) as Dictionary).duplicate(true),
			"objective_gate": is_gate,
			"repair_tool": repair_tool,
			"max_repair_attempts": max_attempts,
			"attempts": 0,
			"repair_attempts": 0,
			"pending_polls": 0,
			"receipt_digest": ""
		}
		if is_gate and bool(expect_fail.get(String(spec.get("key", "")), false)):
			task["expect"] = "fail"
		tasks.append(task)
		if is_gate:
			objective_gate_ids.append(step_id)
		blueprint_tasks.append(_task_blueprint(task))
		prior_ids.append(step_id)
	var blueprint_hash: String = _sha256(JSON.stringify({
		"contract": contract,
		"tasks": blueprint_tasks,
		"objective_gate_ids": objective_gate_ids
	}))
	var workflow_id: String = _sha256(
		String(contract.get("objective", "")) + blueprint_hash + str(Time.get_ticks_usec())).substr(0, 24)
	plan["tasks"] = tasks
	plan["workflow"] = {
		"schema_version": SCHEMA_VERSION,
		"workflow_id": workflow_id,
		"blueprint_hash": blueprint_hash,
		"state": "planned",
		"blocked_reason": "",
		"goal_contract": contract.duplicate(true),
		"objective_gate_ids": objective_gate_ids,
		"artifacts": {},
		"receipts": [],
		"metrics": {
			"rounds": 0, "atomic_calls": 0, "yield_count": 0,
			"safe_recoveries": 0, "transient_retries": 0
		}
	}
	return plan

func _task_blueprint(task: Dictionary) -> Dictionary:
	return {
		"id": String(task.get("id", "")),
		"tool_name": String(task.get("tool_name", "")),
		"profile": String(task.get("profile", "")),
		"step_key": String(task.get("step_key", "")),
		"stage": String(task.get("stage", "")),
		"depends_on": (task.get("depends_on", []) as Array).duplicate(),
		"arguments": _canonical_numbers(task.get("arguments", {})),
		"objective_gate": bool(task.get("objective_gate", false)),
		"repair_tool": String(task.get("repair_tool", "")),
		"max_repair_attempts": int(task.get("max_repair_attempts", 0))
	}


## JSON round-trips turn integer literals (keycodes, indexes) into floats
## (4194322 -> 4194322.0). Canonicalize numeric leaf values so a persisted
## plan's blueprint still equals the freshly compiled one; real fractional
## values (deadzone 0.2) are preserved.
static func _canonical_numbers(value: Variant) -> Variant:
	if value is float:
		var as_float: float = value
		if is_equal_approx(as_float, roundf(as_float)) and absf(as_float) < 9007199254740992.0:
			return int(roundf(as_float))
		return value
	if value is Dictionary:
		var result_dict: Dictionary = {}
		for key in value:
			result_dict[key] = _canonical_numbers(value[key])
		return result_dict
	if value is Array:
		var result_array: Array = []
		for item in value:
			result_array.append(_canonical_numbers(item))
		return result_array
	return value

func validate_integrity(plan: Dictionary, available_tools: Array[String]) -> Dictionary:
	if not (plan.get("workflow") is Dictionary):
		return {"error": "workflow metadata is missing"}
	var workflow: Dictionary = plan["workflow"]
	if int(workflow.get("schema_version", -1)) != SCHEMA_VERSION:
		return {"error": "unsupported workflow schema version"}
	if not (workflow.get("goal_contract") is Dictionary):
		return {"error": "goal contract is missing"}
	var contract: Dictionary = workflow["goal_contract"]
	if String(plan.get("goal", "")) != String(contract.get("objective", "")):
		return {"error": "persisted goal no longer matches the workflow contract"}
	var options: Dictionary = {
		"profiles": contract.get("profiles", []),
		"required_capabilities": contract.get("required_capabilities", []),
		"platform": contract.get("platform", ""),
		"max_repair_attempts": contract.get("max_repair_attempts", DEFAULT_REPAIR_ATTEMPTS),
		"protected_paths": contract.get("protected_paths", [])
	}
	# Do not feed the built-in protected paths back as user additions twice; the
	# compiler deduplicates them, keeping the regenerated contract deterministic.
	var rebuilt_result: Dictionary = compile(String(contract.get("objective", "")), options, available_tools)
	if rebuilt_result.has("error"):
		return {"error": "workflow contract can no longer be compiled: %s" % rebuilt_result["error"]}
	var expected: Dictionary = rebuilt_result["plan"]
	var expected_workflow: Dictionary = expected["workflow"]
	if String(workflow.get("blueprint_hash", "")) != String(expected_workflow.get("blueprint_hash", "")):
		return {"error": "workflow blueprint hash does not match its goal contract"}
	if workflow.get("objective_gate_ids", []) != expected_workflow.get("objective_gate_ids", []):
		return {"error": "objective gate set was changed"}
	var tasks = plan.get("tasks", [])
	var expected_tasks = expected.get("tasks", [])
	if not (tasks is Array) or (tasks as Array).size() != (expected_tasks as Array).size():
		return {"error": "workflow task count was changed"}
	for index in range((expected_tasks as Array).size()):
		var actual_task: Dictionary = tasks[index]
		var expected_task: Dictionary = expected_tasks[index]
		if _task_blueprint(actual_task) != _task_blueprint(expected_task):
			return {"error": "workflow step '%s' no longer matches the authorized blueprint" % expected_task.get("id", index)}
		if not String(actual_task.get("tool_name", "")) in available_tools:
			return {"error": "workflow capability is no longer registered: %s" % actual_task.get("tool_name", "")}
	return {"status": "ok", "blueprint_hash": workflow.get("blueprint_hash", "")}

func get_task(plan: Dictionary, step_id: String) -> Dictionary:
	for value in plan.get("tasks", []):
		var task: Dictionary = value
		if String(task.get("id", "")) == step_id:
			return task
	return {}

func ready_steps(plan: Dictionary, limit: int = DEFAULT_STEPS_PER_RUN) -> Array[Dictionary]:
	var ready: Array[Dictionary] = []
	var bounded_limit: int = maxi(limit, 1)
	for value in plan.get("tasks", []):
		var task: Dictionary = value
		if String(task.get("status", "pending")) != "pending":
			continue
		var dependencies_met: bool = true
		for dependency_value in task.get("depends_on", []):
			var dependency: Dictionary = get_task(plan, String(dependency_value))
			if dependency.is_empty() or String(dependency.get("status", "")) != "done":
				dependencies_met = false
				break
		if dependencies_met:
			ready.append(task)
			if ready.size() >= bounded_limit:
				break
	return ready

func workflow_metrics(plan: Dictionary) -> Dictionary:
	# Schema v1 plans created before adaptive execution did not persist metrics.
	# Attach defaults lazily so an existing durable workflow resumes without a
	# migration, and all increments are retained by the caller's next save.
	if not (plan.get("workflow") is Dictionary):
		plan["workflow"] = {}
	var workflow: Dictionary = plan["workflow"]
	if not (workflow.get("metrics") is Dictionary):
		workflow["metrics"] = {}
	var metrics: Dictionary = workflow["metrics"]
	for key in ["rounds", "atomic_calls", "yield_count", "safe_recoveries", "transient_retries"]:
		if not metrics.has(key):
			metrics[key] = 0
	return metrics

func recommended_step_budget(plan: Dictionary, requested: int = 0) -> int:
	if requested > 0:
		return requested
	var remaining: int = 0
	for task_value in plan.get("tasks", []):
		var task: Dictionary = task_value
		if String(task.get("status", "pending")) != "done":
			remaining += 1
	if remaining <= DEFAULT_STEPS_PER_RUN:
		return maxi(remaining, 1)
	var rounds: int = int(workflow_metrics(plan).get("rounds", 0))
	if remaining <= 16 and rounds == 0:
		return 8
	if remaining <= 64 or rounds < 3:
		return mini(16, remaining)
	# Large goals get a wider execution slice after several checkpoints. This is
	# still only a yield boundary; it never removes remaining tasks.
	return mini(32, remaining)

func is_pending_result(result: Variant) -> bool:
	if not (result is Dictionary):
		return false
	return String((result as Dictionary).get("status", "")).strip_edges().to_lower() in PENDING_STATUSES

func is_transient_failure(result: Variant) -> bool:
	if not (result is Dictionary):
		return false
	var data: Dictionary = result
	var status: String = String(data.get("status", "")).strip_edges().to_lower()
	if status in ["timeout", "timed_out", "busy", "retry", "retrying", "unavailable"]:
		return true
	var message: String = String(data.get("error", data.get("message", ""))).to_lower()
	for term in TRANSIENT_FAILURE_TERMS:
		if message.contains(term):
			return true
	return false

func result_passed(tool_name: String, result: Variant) -> bool:
	if not (result is Dictionary) or (result as Dictionary).is_empty():
		return false
	var data: Dictionary = result
	# 工具有携带空 error 字段的习惯；空字符串不是失败。
	if data.has("error") and not String(data["error"]).strip_edges().is_empty():
		return false
	# 探针超时回退会把缓存载荷包装成 status=success + stale/from_cache：
	# 这是"上次观测"而不是"本次证据"，任何门禁都不得据此通过。
	if bool(data.get("stale", false)) or bool(data.get("from_cache", false)):
		return false
	for verdict_key in ["passed", "success", "valid"]:
		if data.has(verdict_key) and not bool(data[verdict_key]):
			return false
	var status: String = String(data.get("status", "")).strip_edges().to_lower()
	if status in PENDING_STATUSES or status in NEGATIVE_STATUSES:
		return false
	for counter in ["failed", "failed_count", "error_count", "errors_count", "invalid_count"]:
		if data.has(counter) and int(data[counter]) > 0:
			return false
	match tool_name:
		"assert_no_runtime_errors":
			var measured: bool = data.has("error_count") or data.get("errors") is Array
			var errors: int = -1
			if data.has("error_count"):
				errors = int(data["error_count"])
			elif data.get("errors") is Array:
				errors = (data["errors"] as Array).size()
			return bool(data.get("passed", false)) and measured and errors >= 0
		"assert_performance_budget":
			return bool(data.get("passed", false)) and data.get("checks") is Array and not (data["checks"] as Array).is_empty()
		"assert_visual_baseline":
			return bool(data.get("passed", false)) and (data.has("diff_pixel_count") or data.has("diff_ratio"))
		"audit_project_health":
			return status in ["healthy", "warning"] and data.get("summary") is Dictionary and not (data["summary"] as Dictionary).is_empty()
		"play_and_verify":
			return bool(data.get("passed", false)) and data.get("runtime_info") is Dictionary and not (data["runtime_info"] as Dictionary).is_empty()
		"inspect_gltf_asset":
			# 目标提到 gltf/3d/模型时，零网格的资产（生成失败/空壳）不算达成——
			# 处理器对空资产仍回 status=success，泛化规则会放行（重言式）。
			return String(data.get("status", "")) == "success" and int(data.get("mesh_count", 0)) > 0
		"get_runtime_animation_state":
			# 作为 objective gate 时必须证明动画真的在播：is_playing 缺席/false
			# 或 current_animation 为空都算未达成——否则 play_runtime_animation
			# 失败了这个门禁也照样通过（重言式）。
			return bool(data.get("is_playing", false)) and not String(data.get("current_animation", "")).is_empty()
		"list_project_tests":
			return int(data.get("count", 0)) > 0 and not data.has("error") and status not in ["unconfigured", "missing", "blocked"]
		"run_project_test", "run_project_tests":
			return status == "passed" and int(data.get("total_count", 0)) > 0 and int(data.get("failed_count", 0)) == 0
		"smoke_test_export":
			return bool(data.get("success", false)) and bool(data.get("artifact_exists", false))
		"validate_export_preset":
			return bool(data.get("valid", false))
		"modify_script":
			# 修复成功的前提是修复产物能编译：validation.error_count>0 说明
			# 修复本身引入/保留了语法错误，不能当证据。
			if data.get("validation") is Dictionary:
				return int((data["validation"] as Dictionary).get("error_count", 0)) == 0
			return true
		"validate_script", "validate_shader":
			return bool(data.get("valid", false)) or (status == "passed" and bool(data.get("passed", true)))
		"verify_scripts":
			# truncated=true 表示超过 max_scripts 的脚本根本没被检查：
			# 截断的验证不能当通过（第 101 个脚本可能就是坏的）。
			return int(data.get("total_checked", 0)) > 0 and int(data.get("failed", -1)) == 0 \
				and not bool(data.get("truncated", false)) \
				and (status.is_empty() or status in ["ok", "passed", "success", "completed"])
		"audit_scene_node_persistence":
			return int(data.get("total_nodes", 0)) > 0 and int(data.get("issue_count", -1)) == 0
		"scan_missing_resource_dependencies", "scan_cyclic_resource_dependencies":
			return data.has("issue_count") and int(data.get("issue_count", -1)) == 0
		"scan_migration_compatibility":
			return data.has("must_fix_count") and int(data.get("must_fix_count", -1)) == 0
		"detect_broken_scripts":
			return data.has("broken_count") and int(data.get("broken_count", -1)) == 0
		"manage_localization":
			# Tools may report success with only an explicit boolean and no status
			# field; requiring the status vocabulary here misjudged real successes.
			if bool(data.get("success", false)) and not data.has("error"):
				return true
			return status in ["ok", "success", "completed"] and (
				data.has("written") or data.has("translations") or data.has("key_count"))
	if data.has("passed"):
		return bool(data["passed"])
	if data.has("success"):
		return bool(data["success"])
	if data.has("valid"):
		return bool(data["valid"])
	if not status.is_empty():
		return status in SUCCESS_STATUSES
	# Inspection tools frequently return structured data without a status field.
	# Non-empty, error-free evidence is sufficient for non-objective steps.
	return data.size() > 0

func record_step_result(plan: Dictionary, step_id: String, result: Variant) -> Dictionary:
	var task: Dictionary = get_task(plan, step_id)
	if task.is_empty():
		return {"error": "workflow step '%s' not found" % step_id}
	var workflow: Dictionary = plan.get("workflow", {})
	if is_pending_result(result):
		task["status"] = "pending"
		task["pending_polls"] = int(task.get("pending_polls", 0)) + 1
		var pending_receipt: Dictionary = append_receipt(plan, {
			"step_id": step_id,
			"tool_name": task.get("tool_name", ""),
			"passed": false,
			"pending": true,
			"status": (result as Dictionary).get("status", "pending")
		})
		workflow["state"] = "waiting"
		workflow["blocked_reason"] = ""
		var pending_result: Dictionary = {
			"status": "waiting", "step_id": step_id, "receipt": pending_receipt,
			"workflow": summarize(plan)
		}
		if int(task["pending_polls"]) % PENDING_POLL_WINDOW == 0:
			pending_result["yield_reason"] = "pending_poll_window_complete"
			pending_result["resume_safe"] = true
		return pending_result

	task["attempts"] = int(task.get("attempts", 0)) + 1
	task["pending_polls"] = 0
	# 预创建巡检的良性空态：全新项目里 get_current_scene 在建场景步骤之前
	# 运行，"No scene is currently open" 是正常状态而非失败证据。
	if not bool(task.get("objective_gate", false)) \
			and String(task.get("tool_name", "")) == "get_current_scene" \
			and result is Dictionary and (result as Dictionary).has("error") \
			and String((result as Dictionary).get("error", "")).contains("No scene is currently open"):
		result = {
			"status": "ok",
			"open": false,
			"note": "benign empty state before scene creation",
		}
	var expect_failure: bool = bool(task.get("objective_gate", false)) \
		and String(task.get("expect", "pass")) == "fail"
	var evidence_passed: bool = result_passed(String(task.get("tool_name", "")), result) \
		if bool(task.get("objective_gate", false)) else _non_gate_result_usable(result)
	# A negative gate passes when the detector FAILS: fault-injection loops are
	# proving the guardrail fires, so the observed verdict is inverted.
	# 基础设施错误（如 "Debugger bridge is not available"）不是探测器触发：
	# 带非空 error 的负结果不得翻转成通过，否则故障注入循环会在探测器
	# 从未运行的情况下"证明"它工作。
	var passed: bool = evidence_passed
	if expect_failure:
		var well_formed_negative: bool = not evidence_passed
		if result is Dictionary \
				and not String((result as Dictionary).get("error", "")).strip_edges().is_empty():
			well_formed_negative = false
		passed = well_formed_negative
	var receipt: Dictionary = append_receipt(plan, {
		"step_id": step_id,
		"tool_name": task.get("tool_name", ""),
		"passed": passed,
		"pending": false,
		"expected_failure": expect_failure,
		"summary": _compact_result_summary(result, String(task.get("tool_name", "")))
	})
	if passed:
		task["status"] = "done"
		task["receipt_digest"] = receipt.get("digest", "")
		if not expect_failure and evidence_passed:
			_record_artifacts(plan, String(task.get("tool_name", "")), result,
				String(task.get("profile", "")))
		_clear_failure_tracking(task, "verification")
		_clear_failure_tracking(task, "transient")
		if bool(task.get("objective_gate", false)):
			var dod: Array = task.get("dod", [])
			if not dod.is_empty():
				dod[0]["met"] = true
				dod[0]["evidence"] = "workflow-receipt:%s" % receipt.get("digest", "")
		if workflow_completed(plan):
			workflow["state"] = "completed"
		else:
			workflow["state"] = "running"
		workflow["blocked_reason"] = ""
		return {"status": "completed", "step_id": step_id, "receipt": receipt, "workflow": summarize(plan)}

	if is_transient_failure(result):
		task["status"] = "pending"
		var transient_count: int = _track_failure(
			task, "transient", String(task.get("tool_name", "")), result)
		var retry_after_ms: int = mini(
			30000, 1000 * (1 << mini(transient_count - 1, 5)))
		workflow["state"] = "waiting"
		workflow["blocked_reason"] = "Transient tool failure; checkpoint retained for retry"
		var metrics: Dictionary = workflow_metrics(plan)
		metrics["transient_retries"] = int(metrics.get("transient_retries", 0)) + 1
		return {
			"status": "waiting", "step_id": step_id, "retryable": true,
			"retry_reason": "transient_failure", "retry_after_ms": retry_after_ms,
			"failure_fingerprint": task.get("transient_failure_fingerprint", ""),
			"receipt": receipt,
			"workflow": summarize(plan)
		}

	var repair_tool: String = String(task.get("repair_tool", ""))
	var repair_attempts: int = int(task.get("repair_attempts", 0))
	var repair_limit: int = int(task.get("max_repair_attempts", DEFAULT_REPAIR_ATTEMPTS))
	var same_failure_count: int = _track_failure(
		task, "verification", String(task.get("tool_name", "")), result)
	if same_failure_count >= SAME_FAILURE_REPLAN_THRESHOLD:
		task["status"] = "blocked"
		task["repair_pending"] = false
		workflow["state"] = "replan_required"
		workflow["blocked_reason"] = "Repeated identical verification failure; replan with different inputs or capabilities"
		return {
			"status": "replan_required", "step_id": step_id,
			"failure_fingerprint": task.get("verification_failure_fingerprint", ""),
			"receipt": receipt, "workflow": summarize(plan)
		}
	var has_repair_budget: bool = repair_limit <= 0 or repair_attempts < repair_limit
	if not repair_tool.is_empty() and has_repair_budget:
		task["status"] = "blocked"
		task["repair_pending"] = true
		workflow["state"] = "repairing"
		workflow["blocked_reason"] = "Verification failed; evidence-aware repair is ready"
		return {
			"status": "repair_required",
			"step_id": step_id,
			"repair_tool": repair_tool,
			"repair_attempt": repair_attempts + 1,
			"receipt": receipt,
			"workflow": summarize(plan)
		}
	task["status"] = "blocked"
	task["repair_pending"] = false
	workflow["state"] = "replan_required"
	workflow["blocked_reason"] = (
		"Explicit repair budget was exhausted; replan without dropping objective evidence"
		if not repair_tool.is_empty() else
		"Step failed without acceptable evidence; different inputs or capabilities are required")
	return {"status": "replan_required", "step_id": step_id, "receipt": receipt, "workflow": summarize(plan)}

func _non_gate_result_usable(result: Variant) -> bool:
	if not (result is Dictionary) or (result as Dictionary).is_empty():
		return false
	var data: Dictionary = result
	# 空字符串 error 字段不构成失败（部分工具习惯性携带）。
	if data.has("error") and not String(data["error"]).strip_edges().is_empty():
		return false
	for verdict_key in ["passed", "success", "valid"]:
		if data.has(verdict_key) and not bool(data[verdict_key]):
			return false
	var status: String = String(data.get("status", "")).strip_edges().to_lower()
	if status in PENDING_STATUSES:
		return false
	if status == "unsupported":
		# 工具明确表示无法执行被要求的操作（环境/平台不支持）：
		# 不是可用证据，也不是可恢复缺口——需要的补救是换能力而非修复环境。
		return false
	if status in ["unconfigured", "missing"]:
		# An inspection that reports a recoverable environment gap is usable
		# evidence: the dedicated gate/repair steps then perform the recovery.
		return bool(data.get("recoverable", false))
	return not status in ["error", "invalid", "blocked", "cancelled", "canceled", "timeout", "timed_out", "stale", "aborted"]

func record_repair_result(plan: Dictionary, step_id: String, result: Variant) -> Dictionary:
	var task: Dictionary = get_task(plan, step_id)
	if task.is_empty() or not bool(task.get("repair_pending", false)):
		return {"error": "step '%s' has no authorized repair pending" % step_id}
	var repair_tool: String = String(task.get("repair_tool", ""))
	var transient: bool = is_transient_failure(result)
	if not transient:
		task["repair_attempts"] = int(task.get("repair_attempts", 0)) + 1
	var passed: bool = result_passed(repair_tool, result)
	var receipt: Dictionary = append_receipt(plan, {
		"step_id": step_id,
		"tool_name": repair_tool,
		"repair": true,
		"passed": passed,
		"summary": _compact_result_summary(result, repair_tool)
	})
	var workflow: Dictionary = plan.get("workflow", {})
	if passed:
		task["status"] = "pending"
		task["repair_pending"] = false
		_clear_failure_tracking(task, "repair")
		_clear_failure_tracking(task, "repair_transient")
		# Repairs can create resources too (for example the QA smoke test), so
		# their outputs must feed the artifact registry like normal steps.
		_record_artifacts(plan, repair_tool, result, String(task.get("profile", "")))
		workflow["state"] = "running"
		workflow["blocked_reason"] = ""
		return {"status": "repaired", "step_id": step_id, "receipt": receipt, "workflow": summarize(plan)}
	if transient:
		var transient_count: int = _track_failure(task, "repair_transient", repair_tool, result)
		var retry_after_ms: int = mini(
			30000, 1000 * (1 << mini(transient_count - 1, 5)))
		task["status"] = "blocked"
		task["repair_pending"] = true
		workflow["state"] = "waiting"
		workflow["blocked_reason"] = "Transient repair failure; checkpoint retained for retry"
		var metrics: Dictionary = workflow_metrics(plan)
		metrics["transient_retries"] = int(metrics.get("transient_retries", 0)) + 1
		return {
			"status": "retry_required", "step_id": step_id,
			"retryable": true, "retry_after_ms": retry_after_ms,
			"failure_fingerprint": task.get("repair_transient_failure_fingerprint", ""),
			"receipt": receipt, "workflow": summarize(plan)
		}
	var same_failure_count: int = _track_failure(task, "repair", repair_tool, result)
	task["status"] = "blocked"
	var repair_limit: int = int(task.get("max_repair_attempts", DEFAULT_REPAIR_ATTEMPTS))
	if repair_limit > 0 and int(task.get("repair_attempts", 0)) >= repair_limit:
		task["repair_pending"] = false
		workflow["state"] = "replan_required"
		workflow["blocked_reason"] = "Explicit repair budget was exhausted; replan with different inputs or capabilities"
		return {
			"status": "replan_required", "step_id": step_id,
			"receipt": receipt, "workflow": summarize(plan)
		}
	if same_failure_count < SAME_FAILURE_REPLAN_THRESHOLD:
		task["repair_pending"] = true
		workflow["state"] = "repairing"
		workflow["blocked_reason"] = "Repair did not succeed; checkpoint retained for another input or retry"
		return {
			"status": "retry_required", "step_id": step_id,
			"retryable": false, "receipt": receipt,
			"workflow": summarize(plan)
		}
	task["repair_pending"] = false
	workflow["state"] = "replan_required"
	workflow["blocked_reason"] = "Repeated identical repair failure; replan with different inputs or capabilities"
	return {
		"status": "replan_required", "step_id": step_id,
		"failure_fingerprint": task.get("repair_failure_fingerprint", ""),
		"receipt": receipt, "workflow": summarize(plan)
	}

func _track_failure(task: Dictionary, prefix: String, tool_name: String, result: Variant) -> int:
	var fingerprint: String = _sha256(TokenEstimatorScript.canonical_json({
		"tool_name": tool_name,
		"evidence": _stable_failure_evidence(result)
	}))
	var fingerprint_key: String = prefix + "_failure_fingerprint"
	var count_key: String = prefix + "_same_failure_count"
	if String(task.get(fingerprint_key, "")) == fingerprint:
		task[count_key] = int(task.get(count_key, 0)) + 1
	else:
		task[fingerprint_key] = fingerprint
		task[count_key] = 1
	return int(task[count_key])

func _stable_failure_evidence(value: Variant) -> Variant:
	if value is Dictionary:
		var dict_result: Dictionary = {}
		for key_value in (value as Dictionary).keys():
			var key: String = String(key_value)
			if key in VOLATILE_FAILURE_KEYS:
				continue
			dict_result[key] = _stable_failure_evidence((value as Dictionary)[key_value])
		return dict_result
	if value is Array:
		var array_result: Array = []
		for item in value:
			array_result.append(_stable_failure_evidence(item))
		return array_result
	return value

func _clear_failure_tracking(task: Dictionary, prefix: String) -> void:
	task.erase(prefix + "_failure_fingerprint")
	task.erase(prefix + "_same_failure_count")

# 门禁工具的定量证据字段：收据除状态外保留这些数值，重规划/审计时才能看出
# "具体哪条指标过了/没过"，而不是只有一个 completed。
const GATE_EVIDENCE_KEYS: Dictionary = {
	"assert_performance_budget": ["fps", "avg_fps", "p1_fps", "p95_frame_time_ms", "frame_time_ms"],
	"assert_visual_baseline": ["diff_pixel_count", "diff_ratio", "width", "height"],
	"verify_scripts": ["verified", "broken_count"],
	"run_project_tests": ["passed_count", "total_count"],
	"run_project_test": ["passed", "total_count"],
	"assert_no_runtime_errors": ["error_count"],
	"smoke_test_export": ["exit_code"],
	"play_and_verify": ["error_count"],
}

func _compact_result_summary(result: Variant, tool_name: String = "") -> Dictionary:
	if not (result is Dictionary):
		return {"type": typeof(result)}
	var data: Dictionary = result
	var summary: Dictionary = {}
	for key in ["status", "passed", "success", "valid", "total_count", "failed_count", "total_checked", "failed", "error_count", "issue_count", "artifact_exists"]:
		if data.has(key):
			summary[key] = data[key]
	if data.has("error"):
		summary["error"] = String(data["error"]).substr(0, 512)
	# 导出失败必须携带原因（首条错误行），否则证据只剩 success:false。
	if tool_name == "run_export" and not bool(data.get("success", true)):
		var export_errors: Array = data.get("errors", [])
		if not export_errors.is_empty():
			summary["first_error"] = String(export_errors[0]).substr(0, 200)
		elif data.has("exit_code"):
			summary["first_error"] = "exit_code=%s" % str(data["exit_code"])
	var evidence_keys: Array = GATE_EVIDENCE_KEYS.get(tool_name, []) if tool_name != "" else []
	if not evidence_keys.is_empty():
		var evidence: Dictionary = {}
		for evidence_key in evidence_keys:
			var value: Variant = data.get(evidence_key, null)
			if value != null and not (value is Dictionary) and not (value is Array):
				evidence[evidence_key] = value
		if not evidence.is_empty():
			summary["evidence"] = evidence
	return summary

## Register paths a successful creation step produced into the workflow's
## artifact registry (scene/script/theme/tileset/animation/screenshot +
## last_path). Scene-scoped kinds also register a per-profile alias
## ("scene:<profile>") so multi-scene workflows address the right scene.
func _record_artifacts(plan: Dictionary, tool_name: String, result: Variant,
		profile: String = "") -> void:
	if not (result is Dictionary):
		return
	var data: Dictionary = result
	var workflow: Dictionary = plan.get("workflow", {})
	var artifacts_value: Variant = workflow.get("artifacts", {})
	var artifacts: Dictionary = artifacts_value if artifacts_value is Dictionary else {}
	var kind: String = String(ARTIFACT_KIND_BY_TOOL.get(tool_name, ""))
	for key in ARTIFACT_PATH_KEYS:
		if not data.has(key):
			continue
		var value: String = String(data[key]).strip_edges()
		if not (value.begins_with("res://") or value.begins_with("user://")):
			continue
		if not kind.is_empty() and not artifacts.has(kind):
			artifacts[kind] = value
			if not profile.is_empty():
				artifacts[kind + ":" + profile] = value
		artifacts["last_path"] = value
	if data.has("animation_name"):
		var animation_name: String = String(data["animation_name"]).strip_edges()
		if not animation_name.is_empty():
			artifacts["animation_name"] = animation_name
	workflow["artifacts"] = artifacts

## Resolve "$artifact_key" string references inside step arguments against the
## workflow's recorded artifacts (for example "$scene" -> last created scene).
func resolve_argument_references(value: Variant, artifacts: Dictionary) -> Variant:
	if value is String:
		var text: String = value
		if text.length() > 1 and text.begins_with("$"):
			var reference: String = text.substr(1)
			if artifacts.has(reference):
				return artifacts[reference]
		return value
	if value is Dictionary:
		var resolved_dictionary: Dictionary = {}
		for key in value:
			resolved_dictionary[key] = resolve_argument_references(value[key], artifacts)
		return resolved_dictionary
	if value is Array:
		var resolved_array: Array = []
		for item in value:
			resolved_array.append(resolve_argument_references(item, artifacts))
		return resolved_array
	return value

func append_receipt(plan: Dictionary, receipt_fields: Dictionary) -> Dictionary:
	var workflow: Dictionary = plan.get("workflow", {})
	if not (workflow.get("receipts") is Array):
		workflow["receipts"] = []
	var semantic_receipt: Dictionary = receipt_fields.duplicate(true)
	var digest: String = _sha256(TokenEstimatorScript.canonical_json(semantic_receipt))
	var receipts: Array = workflow["receipts"]
	for existing_value in receipts:
		var existing: Dictionary = existing_value
		if String(existing.get("digest", "")) == digest:
			existing["occurrences"] = int(existing.get("occurrences", 1)) + 1
			existing["last_at"] = TaskPlanStoreScript._now()
			return existing
	var receipt: Dictionary = semantic_receipt
	receipt["at"] = TaskPlanStoreScript._now()
	receipt["last_at"] = receipt["at"]
	receipt["occurrences"] = 1
	receipt["digest"] = digest
	receipts.append(receipt)
	return receipt

func workflow_completed(plan: Dictionary) -> bool:
	var workflow: Dictionary = plan.get("workflow", {})
	var receipts = workflow.get("receipts", [])
	if not (receipts is Array):
		return false
	var passing_digests: Dictionary = {}
	for receipt_value in receipts:
		var receipt: Dictionary = receipt_value
		if bool(receipt.get("passed", false)) and not bool(receipt.get("repair", false)):
			passing_digests[String(receipt.get("digest", ""))] = true
	for task_value in plan.get("tasks", []):
		var task: Dictionary = task_value
		if String(task.get("status", "")) != "done":
			return false
	for gate_id_value in workflow.get("objective_gate_ids", []):
		var gate_task: Dictionary = get_task(plan, String(gate_id_value))
		if gate_task.is_empty() or not bool(gate_task.get("objective_gate", false)):
			return false
		var digest: String = String(gate_task.get("receipt_digest", ""))
		if digest.is_empty() or not passing_digests.has(digest):
			return false
		var dod: Array = gate_task.get("dod", [])
		if dod.is_empty() or not bool((dod[0] as Dictionary).get("met", false)):
			return false
	return not (workflow.get("objective_gate_ids", []) as Array).is_empty()

func summarize(plan: Dictionary) -> Dictionary:
	var workflow: Dictionary = plan.get("workflow", {})
	var counts: Dictionary = {"pending": 0, "done": 0, "blocked": 0, "in_progress": 0}
	var needs_input: Array[Dictionary] = []
	for task_value in plan.get("tasks", []):
		var task: Dictionary = task_value
		var status: String = String(task.get("status", "pending"))
		if counts.has(status):
			counts[status] = int(counts[status]) + 1
		if bool(task.get("needs_input", false)):
			needs_input.append({"step_id": task.get("id", ""), "tool_name": task.get("tool_name", ""), "missing": task.get("missing_inputs", [])})
	var ready_preview: Array[Dictionary] = []
	for ready_value in ready_steps(plan, READY_PREVIEW_LIMIT):
		var ready_task: Dictionary = ready_value
		ready_preview.append({
			"step_id": ready_task.get("id", ""),
			"tool_name": ready_task.get("tool_name", ""),
			"stage": ready_task.get("stage", "")
		})
	return {
		"workflow_id": workflow.get("workflow_id", ""),
		"state": workflow.get("state", ""),
		"objective": plan.get("goal", ""),
		"profiles": (workflow.get("goal_contract", {}) as Dictionary).get("profiles", []),
		"progress": counts,
		"ready": ready_preview,
		"needs_input": needs_input,
		"blocked_reason": workflow.get("blocked_reason", ""),
		"blueprint_hash": workflow.get("blueprint_hash", ""),
		"next_step_budget": recommended_step_budget(plan),
		"metrics": workflow_metrics(plan).duplicate(true)
	}

func path_allowed(plan: Dictionary, candidate_path: String) -> bool:
	var clean_candidate: String = candidate_path.strip_edges()
	if clean_candidate.is_empty():
		return true
	var candidate_absolute: String = _canonical_path(clean_candidate)
	if candidate_absolute.is_empty():
		return false
	var contract: Dictionary = (plan.get("workflow", {}) as Dictionary).get("goal_contract", {})
	for protected_value in contract.get("protected_paths", DEFAULT_PROTECTED_PATHS):
		var protected_absolute: String = _canonical_path(String(protected_value))
		if protected_absolute.is_empty():
			continue
		var protected_prefix: String = protected_absolute.trim_suffix("/") + "/"
		if candidate_absolute == protected_absolute.trim_suffix("/") or candidate_absolute.begins_with(protected_prefix):
			return false
	return true

func arguments_allowed(plan: Dictionary, arguments: Dictionary) -> Dictionary:
	var rejected: Array[String] = []
	_collect_rejected_paths(plan, arguments, "", rejected)
	if not rejected.is_empty():
		return {"error": "Workflow arguments target protected paths", "protected_paths": rejected}
	return {"status": "ok"}

func _collect_rejected_paths(plan: Dictionary, value: Variant, key_path: String, rejected: Array[String]) -> void:
	if value is Dictionary:
		for key_value in (value as Dictionary).keys():
			var key: String = String(key_value)
			_collect_rejected_paths(plan, value[key_value], key_path + "." + key, rejected)
	elif value is Array:
		for item in value:
			_collect_rejected_paths(plan, item, key_path, rejected)
	elif value is String:
		var text: String = String(value).strip_edges()
		var normalized_key: String = key_path.to_lower()
		if (text.begins_with("res://") or text.begins_with("user://")) and (
			"path" in normalized_key or "file" in normalized_key or "dir" in normalized_key):
			if not path_allowed(plan, text) and not text in rejected:
				rejected.append(text)

func _canonical_path(path: String) -> String:
	var clean: String = path.strip_edges()
	if clean.begins_with("res://") or clean.begins_with("user://"):
		return ProjectSettings.globalize_path(clean).simplify_path()
	if clean.is_absolute_path():
		return clean.simplify_path()
	return ""

static func _sha256(text: String) -> String:
	var context: HashingContext = HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(text.to_utf8_buffer())
	return context.finish().hex_encode()
