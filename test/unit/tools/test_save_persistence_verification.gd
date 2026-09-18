extends "res://addons/gut/test.gd"

## M7 存档跨进程（评测 N3）测试：蓝图 save 动词、引擎跨进程证据链、
## 演练派生（存档腿/恢复腿）。

const BlueprintsScript = preload("res://addons/godot_mcp/native_mcp/goal_blueprints.gd")
const EngineScript = preload("res://addons/godot_mcp/native_mcp/game_workflow_engine.gd")
const ManifestScript = preload("res://addons/godot_mcp/native_mcp/tools_manifest.gd")
const WorkflowToolsScript = preload("res://addons/godot_mcp/tools/game_workflow_tools.gd")

# ============================================================================
# 蓝图：save 动词
# ============================================================================

func test_save_keywords_match_bilingually() -> void:
	assert_true(BlueprintsScript._mentions("add save/load for the score", BlueprintsScript.SAVE_KEYWORDS))
	assert_true(BlueprintsScript._mentions("加存档和读档", BlueprintsScript.SAVE_KEYWORDS))
	assert_false(BlueprintsScript._mentions("jump and collect coins", BlueprintsScript.SAVE_KEYWORDS))

func test_save_goal_generates_save_load_and_auto_restore() -> void:
	var source: String = BlueprintsScript.controller_script("加存档：关闭游戏再打开进度还在")
	assert_false(source.is_empty())
	assert_true(source.contains("func save_game() -> bool"), "save_game exists")
	assert_true(source.contains("func load_game() -> bool"), "load_game exists")
	assert_true(source.contains("user://save_game.json"), "deterministic save path")
	assert_true(source.contains("\tload_game()\n"), "auto-restore runs in _ready (N3 semantics)")
	assert_true(source.contains("last_save_ok"), "observable save evidence flag")
	assert_true(source.contains("save_game\")"), "save triggered by the save_game action")
	# 存档暗含移动：位移是被持久化的非平凡状态
	assert_true(source.contains("_physics_process"), "save implies movement (state worth persisting)")
	assert_true(source.contains("move_and_slide()"), "movement code present for save-only goals")

func test_save_and_pause_and_movement_combine() -> void:
	var source: String = BlueprintsScript.controller_script("arrow-key movement with pause menu and save/load")
	assert_true(source.contains("set_paused"))
	assert_true(source.contains("save_game()"))
	assert_true(source.contains("_physics_process"))

# ============================================================================
# 引擎：跨进程证据链
# ============================================================================

func _compile_save_goal() -> Dictionary:
	var available: Array[String] = []
	for tool_name in ManifestScript.TOOLS.keys():
		available.append(tool_name)
	var engine: RefCounted = EngineScript.new()
	return engine.compile("Add save/load: score persists after closing and relaunching",
		{"profiles": ["gameplay_feature"]}, available)

func test_save_goal_plan_contains_cross_process_chain() -> void:
	var result: Dictionary = _compile_save_goal()
	assert_false(result.has("error"), str(result.get("error", "")))
	var keys: Array[String] = []
	for task_value in result["plan"].get("tasks", []):
		keys.append(String((task_value as Dictionary).get("step_key", "")))
	# 链条顺序：save_play → stop_game → rerun_game → restore_play，且都在
	# runtime_errors 之前（错误门禁仍是最后一步）。
	var chain: Array[String] = ["save_play", "stop_game", "rerun_game", "restore_play"]
	var last_index: int = -1
	for chain_key in chain:
		var index: int = keys.find(chain_key)
		assert_gt(index, -1, "plan contains %s" % chain_key)
		assert_gt(index, last_index, "%s comes after the previous chain step" % chain_key)
		last_index = index
	assert_lt(last_index, keys.find("runtime_errors"), "cross-process chain runs before the error gate")
	assert_true(keys.has("input_save"), "save_game action gets registered (F5)")

# ============================================================================
# 演练派生（纯函数级）
# ============================================================================

func test_save_play_steps_shape() -> void:
	var steps: Array = WorkflowToolsScript.new()._save_play_steps()
	var actions: Array = []
	for step_value in steps:
		var step: Dictionary = step_value
		if bool(step.get("pressed", false)):
			actions.append(step.get("action"))
	# 锚定腿（safe-save 修复链）在前：left 锚到左墙 → save。**存档必须
	# coins=0 且远离金币窗**——在金币区内存档会毒化一切下游全新启动
	# （恢复位置就在拾取窗内 → 开机自动拾取 → 计数/关卡状态全错）。
	assert_eq(actions, ["move_left", "save_game"], "anchor at the wall, then save coin-free")
	var save_step: Dictionary = steps[2]
	assert_true(save_step.has("assert"), "save press asserts write success")
	assert_eq(str((save_step["assert"] as Dictionary).get("expression", "")),
		"last_save_ok and coins_collected == 0", "the saved state is coin-free")

func test_restore_play_steps_assert_disk_state_and_fresh_session() -> void:
	var steps: Array = WorkflowToolsScript.new()._restore_play_steps()
	assert_eq(str(((steps[0] as Dictionary).get("assert", {}) as Dictionary).get("expression", "")),
		"position.x", "restored position asserted")
	assert_eq(str(((steps[0] as Dictionary).get("assert", {}) as Dictionary).get("operator", "")), "lt",
		"the restore lands at the saved wall pin")
	assert_eq(str(((steps[1] as Dictionary).get("assert", {}) as Dictionary).get("expression", "")),
		"last_save_ok", "fresh-session proof asserted")
	assert_eq((steps[1] as Dictionary).get("assert", {}).get("expected"), false)
