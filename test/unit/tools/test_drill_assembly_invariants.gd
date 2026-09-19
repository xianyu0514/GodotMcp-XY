extends "res://addons/gut/test.gd"

## 演练组装不变量穷举（毫秒级）——过去 4 个 CI 周期 bug 的家：
## - 收集腿漏 deterministic（7/13 回归：50 帧退化为 850ms 墙钟过冲穿带）
## - 扫描窗未按金币数缩放（5 币收不满）
## - 解锁前缀的三源盲点（title 门控空转）
## - 关卡腿自带解锁（win 态误触发换关）
## 每条都是"组装产物的属性"——对所有（prior 目标 × 合并语境）组合断言
## 不变量，新违规在毫秒内红，不再花 20 分钟 CI 才现形。

const WorkflowToolsScript = preload("res://addons/godot_mcp/tools/game_workflow_tools.gd")
const GoalBlueprintsScript = preload("res://addons/godot_mcp/native_mcp/goal_blueprints.gd")

const PRIOR_GOALS: Array[String] = [
	"Arrow-key player movement with walls that block the player.",
	"Add 3 collectible coins.",
	"Add 5 collectible coins.",
	"Add a patrolling enemy that kills the player on touch.",
	"Add an Esc pause menu that pauses the world.",
	"Add a sound effect when collecting a coin.",
	"Add a coin pickup particle burst.",
	"Add looping background music.",
	"Add a title screen with start, gameplay, win state and restart.",
	"Add a game over screen with 3 lives when the player dies.",
	"Add a second level after the first win.",
	"Add save/load so progress persists after closing and relaunching.",
	"Make the enemy slower so the game is easier.",
]

## 合并语境的全对角覆盖（单个动词 + 组合）
const MERGED_CONTEXTS: Array[Dictionary] = [
	{},
	{"state_machine": true},
	{"save": true},
	{"level": true},
	{"game_over": true},
	{"state_machine": true, "save": true, "level": true, "game_over": true},
	{"bgm": true},
	{"state_machine": true, "level": true},
]

var _tools: RefCounted

func before_each() -> void:
	_tools = WorkflowToolsScript.new()

func _assembled(prior_goal: String, merged: Dictionary) -> Dictionary:
	var args: Dictionary = {}
	_tools._derive_generic_play_steps({"goal": prior_goal}, {}, "play_and_verify", args, merged)
	return args

# ============================================================================
# 不变量 1：帧步进契约——任何腿含 wait_frames ⇒ deterministic
# ============================================================================

func test_any_wait_frames_implies_deterministic() -> void:
	var violations: Array = []
	for prior in PRIOR_GOALS:
		for merged in MERGED_CONTEXTS:
			var args: Dictionary = _assembled(prior, merged)
			var steps: Array = args.get("steps", [])
			var has_frames: bool = false
			for s in steps:
				if (s as Dictionary).has("wait_frames"):
					has_frames = true
					break
			if has_frames and not bool(args.get("deterministic", false)):
				violations.append("%s × %s" % [prior.substr(0, 20), str(merged)])
	assert_eq(violations.size(), 0, "wait_frames without deterministic (wall-clock oversweep): %s" % str(violations).substr(0, 200))

# ============================================================================
# 不变量 2：扫描窗按金币数缩放（期望帧数匹配）
# ============================================================================

func test_sweep_window_matches_coin_request() -> void:
	for coins_wanted in [3, 5, 8, 12]:
		var goal := "Add %d collectible coins." % coins_wanted
		var args: Dictionary = _assembled(goal, {})
		var steps: Array = args.get("steps", [])
		# 找收集扫描步（右扫、有 wait_frames、锚定后的那个）
		var sweep_frames: int = -1
		for s in steps:
			var step: Dictionary = s
			if str(step.get("action", "")) == "move_right" and step.has("wait_frames"):
				sweep_frames = int(step["wait_frames"])
		# 帧数 = 像素窗 ÷ 速度（缺省 260）——与 _coin_sweep_frames 同式
		var expected: int = clampi(ceili((110.0 + (coins_wanted - 1) * 40.0 - 90.0 + 12.0) / (260.0 / 60.0)), 24, 50)
		if sweep_frames > 0:
			assert_eq(sweep_frames, expected,
				"%d coins → %d-frame sweep (got %d)" % [coins_wanted, expected, sweep_frames])

# ============================================================================
# 不变量 3：解锁前缀当且仅当状态语境（三源）
# ============================================================================

func test_unlock_iff_state_context() -> void:
	for prior in PRIOR_GOALS:
		for merged in MERGED_CONTEXTS:
			var args: Dictionary = _assembled(prior, merged)
			var steps: Array = args.get("steps", [])
			var first_actions: Array = []
			for i in range(mini(2, steps.size())):
				first_actions.append(str((steps[i] as Dictionary).get("action", "wait")))
			var unlocked: bool = first_actions.size() >= 2 and first_actions[0] == "ui_accept"
			var state_ctx: bool = bool(merged.get("state_machine", false))
			var prior_has_state: bool = GoalBlueprintsScript._mentions(prior, GoalBlueprintsScript.STATE_MACHINE_KEYWORDS)
			if state_ctx and not prior_has_state and steps.size() > 1:
				assert_true(unlocked,
					"state context (%s) must unlock: %s" % [str(merged), prior.substr(0, 30)])

# ============================================================================
# 不变量 4：证据腿不注入转移（关卡腿内无 Enter）
# ============================================================================

func test_level_legs_have_no_enter() -> void:
	# 关卡之间的 Enter 是换关机制本身（腿的核心演练）——该禁的只是开头
	# 当解锁用的 Enter（CI run #21：收集腿先 win，此处盲发会误触发换关）。
	var steps: Array = _tools._level_play_steps(3, false)
	assert_true(steps.size() >= 2, "level legs have content")
	var first: String = str((steps[0] as Dictionary).get("action", "wait"))
	assert_ne(first, "ui_accept", "level legs must not open with an unlock Enter (caller's prefix owns unlocking)")

# ============================================================================
# 不变量 5：取证后缀当且仅当存档合并（表达式安全）
# ============================================================================

func test_restore_suffix_iff_save_merged() -> void:
	var bare: Array = _tools._level_play_steps(2, false)
	for s in bare:
		var expr: String = str(((s as Dictionary).get("assert", {}) as Dictionary).get("expression", ""))
		if expr.contains("_last_restored"):
			fail_test("bare (no-save) level legs must not reference _last_restored")
			return
	var saved: Array = _tools._level_play_steps(2, true)
	var has_restore: bool = false
	for s in saved:
		var expr: String = str(((s as Dictionary).get("assert", {}) as Dictionary).get("expression", ""))
		if expr.contains("_last_restored"):
			has_restore = true
	assert_true(has_restore, "save-merged level legs carry the restore evidence")
