extends "res://addons/gut/test.gd"

## 背景音乐目标族测试（质量维度：声音的另一半）：
## 1) 蓝图：bgm 动词（程序生成循环 PCM、LOOP_FORWARD、_ready 自动播放、
##    可听音量）；纯叠加层（不与任何计数器/状态语义交互）
## 2) 证据腿：正在播放、播放头前进、音量可听
## 3) 合并目标与规划路由；全合并编译

const BlueprintsScript = preload("res://addons/godot_mcp/native_mcp/goal_blueprints.gd")
const WorkflowToolsScript = preload("res://addons/godot_mcp/tools/game_workflow_tools.gd")

const BGM_GOAL := "Add looping background music."

func test_bgm_keywords_and_verb() -> void:
	assert_true(BlueprintsScript._mentions(BGM_GOAL, BlueprintsScript.BGM_KEYWORDS))
	assert_true(BlueprintsScript._mentions("加背景音乐", BlueprintsScript.BGM_KEYWORDS))
	assert_false(BlueprintsScript._mentions("Add a sound effect", BlueprintsScript.BGM_KEYWORDS),
		"sfx objectives stay audio-only (no bgm verb)")
	var verbs: Dictionary = BlueprintsScript.match_verbs(BGM_GOAL)
	assert_true(bool(verbs.get("bgm", false)), "objective matches the bgm verb")

func test_bgm_controller_wiring() -> void:
	var source: String = BlueprintsScript.controller_script(BGM_GOAL)
	assert_true(source.contains("BgmPlayer"), "bgm player node created")
	assert_true(source.contains("LOOP_FORWARD"), "the generated stream loops")
	assert_true(source.contains("_bgm_player.play()"), "music autoplays in _ready")
	assert_true(source.contains("bgm_pcm"), "the chiptune is generated programmatically")
	var script := GDScript.new()
	script.source_code = source
	assert_eq(script.reload(), OK, "the bgm-only controller compiles")

func test_bgm_is_a_pure_overlay() -> void:
	# 合并语义安全：bgm 不改任何计数器/状态机变量——与关卡/存档/反馈
	# 等值断言零交互（这是它作为维度的设计约束）。
	var with_bgm: String = BlueprintsScript.controller_script(
		"arrow-key movement, 3 collectible coins, background music")
	assert_true(with_bgm.contains("_bgm_player.play()"), "merged game keeps the music")
	assert_false(with_bgm.contains("current_level"), "bgm does not imply levels")
	var script := GDScript.new()
	script.source_code = with_bgm
	assert_eq(script.reload(), OK, "the merged game compiles")

func test_bgm_legs_assert_active_playback() -> void:
	var tools: RefCounted = WorkflowToolsScript.new()
	var steps: Array = tools._bgm_play_steps()
	var expressions: Array = []
	for step_value in steps:
		var leg: Dictionary = (step_value as Dictionary).get("assert", {})
		if not leg.is_empty():
			expressions.append(String(leg.get("expression", "")))
	assert_has(expressions, "_bgm_player.playing", "music is playing")
	assert_has(expressions, "_bgm_player.get_playback_position() > 0.05",
		"playback head advances (not stuck)")
	assert_has(expressions, "_bgm_player.volume_db > -60.0", "audible volume")

func test_merged_objective_includes_bgm_part() -> void:
	var tools: RefCounted = WorkflowToolsScript.new()
	var merged: String = tools._build_merged_objective(
		{"movement": true, "collectible": true, "bgm": true},
		"arrow-key movement with 3 collectible coins")
	assert_string_contains(merged, "background music", "merged objective keeps the bgm verb")

func test_bgm_objective_compiles_into_verifiable_plan() -> void:
	var EngineScriptT = preload("res://addons/godot_mcp/native_mcp/game_workflow_engine.gd")
	var ManifestScriptT = preload("res://addons/godot_mcp/native_mcp/tools_manifest.gd")
	var available: Array[String] = []
	for tool_name in ManifestScriptT.tool_names():
		available.append(tool_name)
	var result: Dictionary = EngineScriptT.new().compile(
		BGM_GOAL, {"profiles": ["gameplay_feature"]}, available)
	assert_false(result.has("error"), str(result.get("error", "")))
	var tool_names: Array = []
	for task_value in result["plan"].get("tasks", []):
		tool_names.append(String((task_value as Dictionary).get("tool_name", "")))
	assert_has(tool_names, "create_script", "bgm goal writes the controller")
	assert_has(tool_names, "play_and_verify", "bgm goal gates on runtime evidence")
