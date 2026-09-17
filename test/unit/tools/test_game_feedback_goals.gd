extends "res://addons/gut/test.gd"

## 质量反馈目标族测试（音效强化 + 粒子 juice）：
## 1) 蓝图：juice 动词（粒子爆闪、世界坐标挂载、restart 触发、计数器）
## 2) 证据腿：至少一次 + 每拾取等值（跟随改名）
## 3) 重开重置：反馈计数器随回合清零（等值证据在重开后依然成立）
## 4) 合并目标：增量目标（给已有游戏加粒子/音效）经全量重生保留反馈接线

const BlueprintsScript = preload("res://addons/godot_mcp/native_mcp/goal_blueprints.gd")
const WorkflowToolsScript = preload("res://addons/godot_mcp/tools/game_workflow_tools.gd")

# ============================================================================
# 关键词与动词
# ============================================================================

func test_juice_keywords_match_bilingually() -> void:
	assert_true(BlueprintsScript._mentions("Add a coin pickup particle burst", BlueprintsScript.JUICE_KEYWORDS))
	assert_true(BlueprintsScript._mentions("加一个拾取粒子特效", BlueprintsScript.JUICE_KEYWORDS))
	# 消歧："sound effect" 是音频目标，不得误触发粒子动词
	assert_false(BlueprintsScript._mentions("Add a sound effect when collecting", BlueprintsScript.JUICE_KEYWORDS))

func test_match_verbs_registers_juice() -> void:
	var verbs: Dictionary = BlueprintsScript.match_verbs("coin pickup particle burst")
	assert_true(bool(verbs.get("juice", false)), "particle objective matches the juice verb")
	var sound_verbs: Dictionary = BlueprintsScript.match_verbs("a sound effect when collecting a coin")
	assert_false(bool(sound_verbs.get("juice", false)), "sound objectives stay audio-only")

# ============================================================================
# 蓝图：juice 控制器源码
# ============================================================================

func test_juice_goal_generates_burst_controller() -> void:
	var source: String = BlueprintsScript.controller_script("Add a coin pickup particle burst.")
	assert_false(source.is_empty(), "juice goals generate a real controller")
	assert_true(source.contains("CPUParticles2D"), "burst particle node created")
	assert_true(source.contains("one_shot = true"), "burst is one-shot (re-fired per pickup)")
	assert_true(source.contains("_burst_player.restart()"), "collection re-fires the burst")
	assert_true(source.contains("burst_count += 1"), "observable burst counter increments")
	assert_true(source.contains("coin.global_position"), "burst anchors at the pickup point, not the player")

func test_juice_implies_collectible_and_movement() -> void:
	var source: String = BlueprintsScript.controller_script("Add a coin pickup particle burst.")
	assert_true(source.contains("coins_collected"), "juice implies collectibles (something to burst for)")
	assert_true(source.contains("move_right"), "juice implies movement (a way to reach pickups)")

# ============================================================================
# 证据腿：等值断言 + 跟随改名
# ============================================================================

func test_juice_legs_assert_burst_and_per_pickup_equality() -> void:
	var tools: RefCounted = WorkflowToolsScript.new()
	var legs: Array = tools._juice_play_steps()
	assert_eq(legs.size(), 2, "at-least-once + per-pickup equality legs")
	var first: Dictionary = legs[0].get("assert", {})
	assert_eq(str(first.get("expression", "")), "burst_count", "first leg asserts a burst happened")
	var second: Dictionary = legs[1].get("assert", {})
	assert_eq(str(second.get("expression", "")), "burst_count == coins_collected",
		"second leg asserts every pickup burst")

func test_juice_legs_follow_rename() -> void:
	var tools: RefCounted = WorkflowToolsScript.new()
	var legs: Array = tools._juice_play_steps("gems_collected")
	var equality: Dictionary = legs[1].get("assert", {})
	assert_eq(str(equality.get("expression", "")), "burst_count == gems_collected",
		"renamed coin counters propagate into feedback legs")

func test_audio_legs_now_assert_per_pickup_equality() -> void:
	var tools: RefCounted = WorkflowToolsScript.new()
	var legs: Array = tools._audio_play_steps()
	assert_eq(legs.size(), 2, "at-least-once + per-pickup equality legs")
	var equality: Dictionary = legs[1].get("assert", {})
	assert_eq(str(equality.get("expression", "")), "sfx_played_count == coins_collected",
		"every pickup sounded (no silent collections)")

# ============================================================================
# 重开重置：反馈计数器随回合清零
# ============================================================================

func test_restart_resets_feedback_counters() -> void:
	# 状态机 + 音效 + 粒子的完整合并游戏：win→title 重置块必须同时清零
	# 两个反馈计数器——否则重开后 sfx_played_count == coins_collected 永假。
	var source: String = BlueprintsScript.controller_script(
		"arrow-key movement, 3 coins with sound effect and particle burst, " \
		+ "a title screen with start, gameplay, win state and restart")
	assert_true(source.contains("coins_collected = 0"), "coin counter resets on restart")
	var reset_pos: int = source.find("coins_collected = 0")
	assert_gt(reset_pos, -1, "reset block exists")
	var window: String = source.substr(reset_pos, 220)
	assert_true(window.contains("sfx_played_count = 0"), "sfx counter resets with the round")
	assert_true(window.contains("burst_count = 0"), "burst counter resets with the round")

# ============================================================================
# 合并目标：增量反馈目标经全量重生保留接线
# ============================================================================

func test_merged_objective_includes_feedback_parts() -> void:
	var tools: RefCounted = WorkflowToolsScript.new()
	var merged: String = tools._build_merged_objective(
		{"movement": true, "collectible": true, "audio": true, "juice": true},
		"arrow-key movement with 3 collectible coins")
	assert_string_contains(merged, "sound effect", "merged objective keeps the audio verb")
	assert_string_contains(merged, "particle burst", "merged objective keeps the juice verb")

func test_merged_feedback_objective_regenerates_full_wiring() -> void:
	# 真实增量路径：合并目标 → controller_script 全量重生（增量块机制已
	# 作为死代码删除）。重生源码必须同时带音效与粒子接线。
	var source: String = BlueprintsScript.controller_script(
		"arrow-key movement, 3 collectible coins, sound effect, coin pickup particle burst")
	assert_true(source.contains("AudioStreamWAV"), "regenerated source keeps sfx wiring")
	assert_true(source.contains("CPUParticles2D"), "regenerated source keeps burst wiring")
	assert_true(source.contains("_sfx_player.play()"), "pickup still triggers playback")
	assert_true(source.contains("_burst_player.restart()"), "pickup still triggers the burst")
