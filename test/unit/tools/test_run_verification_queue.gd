extends "res://addons/gut/test.gd"

## run_verification_queue（M5 第三交付）工具级测试：create 校验、
## script_check 内置执行、external defer + record 回填、分片续跑、
## 指纹漂移经 inspect 打回、终态保护。

const ToolsScript = preload("res://addons/godot_mcp/tools/verification_queue_tools.gd")
const StoreScript = preload("res://addons/godot_mcp/tools/verification_queue_store.gd")

const TMP: String = "res://.tmp_vq_tool"
const STORE: String = TMP + "/queues.json"
const WATCH: String = TMP + "/game.gd"

var _tools: RefCounted

func before_each() -> void:
	DirAccess.make_dir_recursive_absolute(TMP)
	_write(WATCH, "extends Node\nvar speed := 10\n")
	_tools = ToolsScript.new()
	_tools._store_path = STORE

func after_each() -> void:
	_tools = null
	_remove_tree(TMP)

# ============================================================================
# create 与校验
# ============================================================================

func test_create_validates_input() -> void:
	assert_has(await _tools._tool_run_verification_queue({"command": "create"}), "error")
	assert_has(await _tools._tool_run_verification_queue({
		"command": "create", "goal": "x"}), "error")
	assert_has(await _tools._tool_run_verification_queue({
		"command": "create", "goal": "x", "items": [{"kind": "mystery"}]}), "error")
	assert_has(await _tools._tool_run_verification_queue({"command": "wat"}), "error")

func test_create_runs_first_slice_of_script_checks() -> void:
	var result: Dictionary = await _tools._tool_run_verification_queue({
		"command": "create", "goal": "compile health",
		"items": [
			{"kind": "script_check", "label": "game compiles",
				"detail": {"scripts": [WATCH]}},
		],
		"watch_paths": [WATCH], "budget": 4,
	})
	assert_false(result.has("error"), str(result))
	assert_eq(int(result["passed_count"]), 1, "a good script passes the built-in executor")
	assert_eq(String(result["outcome"]), "completed")

func test_missing_script_fails_the_check() -> void:
	var result: Dictionary = await _tools._tool_run_verification_queue({
		"command": "create", "goal": "compile health",
		"items": [
			{"kind": "script_check", "label": "gone",
				"detail": {"scripts": ["res://.tmp_vq_tool/nope.gd"]}},
		],
	})
	assert_eq(String(result["outcome"]), "failed", "a missing file is a failed check")

# ============================================================================
# external defer + record 回填
# ============================================================================

func test_external_items_defer_and_complete_via_record() -> void:
	var result: Dictionary = await _tools._tool_run_verification_queue({
		"command": "create", "goal": "mixed verification",
		"items": [
			{"kind": "script_check", "label": "compiles",
				"detail": {"scripts": [WATCH]}},
			{"kind": "external", "label": "movement regression",
				"detail": {"steps_hint": "run play_and_verify"}},
		],
	})
	# script_check 已执行；external 保持 pending（defer 不消耗预算）。
	assert_eq(int(result["passed_count"]), 1)
	assert_eq(int(result["pending_count"]), 1, "external item awaits its out-of-band runner")
	assert_eq(String(result["outcome"]), "pending_more", "uncollected evidence is not completed")

	var queue_id: String = String(result["queue_id"])
	var recorded: Dictionary = await _tools._tool_run_verification_queue({
		"command": "record", "queue_id": queue_id, "item_id": "item_2",
		"passed": true, "evidence": {"runner": "play_and_verify", "assertions": 3},
	})
	assert_eq(String(recorded["outcome"]), "completed", str(recorded))
	assert_eq(int(recorded["passed_count"]), 2)

	# 已有判定的项不能再改。
	assert_has(await _tools._tool_run_verification_queue({
		"command": "record", "queue_id": queue_id, "item_id": "item_2", "passed": false,
	}), "error")

# ============================================================================
# 分片续跑与漂移
# ============================================================================

func test_advance_resumes_slices() -> void:
	var items: Array = []
	for index in 5:
		items.append({"kind": "script_check", "label": "c%d" % index,
			"detail": {"scripts": [WATCH]}})
	var created: Dictionary = await _tools._tool_run_verification_queue({
		"command": "create", "goal": "five", "items": items, "budget": 2,
	})
	assert_eq(int(created["processed"]), 2)
	assert_true(bool(created["has_more"]))

	var advanced: Dictionary = await _tools._tool_run_verification_queue({
		"command": "advance", "queue_id": created["queue_id"], "budget": 2,
	})
	assert_eq(int(advanced["processed"]), 2)
	var last: Dictionary = await _tools._tool_run_verification_queue({
		"command": "advance", "queue_id": created["queue_id"], "budget": 2,
	})
	assert_eq(String(last["outcome"]), "completed")

func test_inspect_invalidates_stale_evidence_on_drift() -> void:
	var created: Dictionary = await _tools._tool_run_verification_queue({
		"command": "create", "goal": "drift watch",
		"items": [{"kind": "script_check", "label": "c",
			"detail": {"scripts": [WATCH]}}],
		"watch_paths": [WATCH],
	})
	assert_eq(String(created["outcome"]), "completed")

	_write(WATCH, "extends Node\nvar speed := 99\n")
	var inspected: Dictionary = await _tools._tool_run_verification_queue({
		"command": "inspect", "queue_id": created["queue_id"],
	})
	assert_gt(int(inspected["stale_refreshed"]), 0, "drift pushes the verdict back to pending")
	assert_eq(int(inspected["pending_count"]), 1)
	assert_eq(String(inspected["outcome"]), "open")

func test_abandon_then_advance_refuses() -> void:
	var created: Dictionary = await _tools._tool_run_verification_queue({
		"command": "create", "goal": "x",
		"items": [{"kind": "external", "label": "e", "detail": {}}],
		"defer_first_slice": true,
	})
	var abandoned: Dictionary = await _tools._tool_run_verification_queue({
		"command": "abandon", "queue_id": created["queue_id"],
	})
	assert_eq(String(abandoned["outcome"]), "abandoned")
	assert_has(await _tools._tool_run_verification_queue({
		"command": "advance", "queue_id": created["queue_id"],
	}), "error")

# ============================================================================
# 夹具
# ============================================================================

func _write(path: String, content: String) -> void:
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	file.store_string(content)
	file.close()

func _remove_tree(path: String) -> void:
	if not DirAccess.dir_exists_absolute(path):
		return
	for sub_name: String in DirAccess.get_directories_at(path):
		if sub_name == "." or sub_name == "..":
			continue
		_remove_tree(path.path_join(sub_name))
	for file_name: String in DirAccess.get_files_at(path):
		DirAccess.remove_absolute(path.path_join(file_name))
	DirAccess.remove_absolute(path)
