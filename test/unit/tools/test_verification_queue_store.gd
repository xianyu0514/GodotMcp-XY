extends "res://addons/gut/test.gd"

## VerificationQueueStore（M5 第三交付）单元测试：分片推进不丢项、
## 重启续跑、失败不产生 completed、文件指纹漂移打回重验、持久化往返。

const StoreScript = preload("res://addons/godot_mcp/tools/verification_queue_store.gd")

const TMP: String = "res://.tmp_vq_store"
const STORE: String = TMP + "/queues.json"
const WATCH: String = TMP + "/game.gd"

func before_each() -> void:
	DirAccess.make_dir_recursive_absolute(TMP)
	_write(WATCH, "extends Node\nvar speed := 10\n")

func after_each() -> void:
	_remove_tree(TMP)

func _items(count: int) -> Array:
	var items: Array = []
	for index in count:
		items.append({
			"kind": "prior_feature",
			"label": "feature %d" % index,
			"detail": {"goal": "goal %d" % index},
		})
	return items

func _pass_all(_detail: Dictionary) -> Dictionary:
	return {"passed": true, "evidence": {"runner": "fake"}}

func _fail_even(_detail: Dictionary) -> Dictionary:
	# label 为奇数序号的项失败（detail.goal 的尾号奇偶决定）。
	var goal: String = String(_detail.get("goal", ""))
	var suffix: String = goal.substr(goal.rfind(" ") + 1)
	return {"passed": int(suffix) % 2 == 0, "evidence": {"runner": "fake"}}

# ============================================================================
# 分片推进（超预算不丢失）
# ============================================================================

func test_advance_slices_without_losing_items() -> void:
	var store: Dictionary = StoreScript.load_store(STORE)
	var created: Dictionary = StoreScript.create_queue("twelve features", _items(12), [WATCH], store)
	assert_false(created.has("error"), str(created))
	var queue: Dictionary = created["queue"]

	var first: Dictionary = StoreScript.advance(queue, 5, _pass_all)
	assert_eq(int(first["processed"]), 5, "budget bounds the slice")
	assert_true(bool(first["has_more"]))
	assert_eq(String(first["outcome"]), "pending_more", "uncollected evidence is not completed")
	assert_eq(int(first["pending_count"]), 7, "the 7 items beyond the budget are retained")

	var second: Dictionary = StoreScript.advance(queue, 5, _pass_all)
	assert_eq(int(second["processed"]), 5)
	var third: Dictionary = StoreScript.advance(queue, 5, _pass_all)
	assert_eq(int(third["processed"]), 2, "only the remainder runs")
	assert_eq(String(third["outcome"]), "completed")
	assert_false(bool(third["has_more"]))

func test_zero_budget_advances_nothing() -> void:
	var store: Dictionary = StoreScript.load_store(STORE)
	var queue: Dictionary = StoreScript.create_queue("q", _items(3), [WATCH], store)["queue"]
	var result: Dictionary = StoreScript.advance(queue, 0, _pass_all)
	assert_eq(int(result["processed"]), 0)
	assert_eq(String(result["outcome"]), "pending_more")

# ============================================================================
# 失败不产生 completed
# ============================================================================

func test_failure_blocks_completion_but_keeps_collecting() -> void:
	var store: Dictionary = StoreScript.load_store(STORE)
	var queue: Dictionary = StoreScript.create_queue("mixed", _items(4), [WATCH], store)["queue"]
	var result: Dictionary = StoreScript.advance(queue, 4, _fail_even)
	assert_eq(int(result["processed"]), 4, "a failing item does not stop the slice")
	assert_eq(int(result["failed_count"]), 2)
	assert_eq(String(result["outcome"]), "failed", "failures never yield completed")
	assert_eq(String(queue["phase"]), "failed")

# ============================================================================
# 重启续跑（持久化往返）
# ============================================================================

func test_restart_resumes_from_persisted_state() -> void:
	var store: Dictionary = StoreScript.load_store(STORE)
	var queue: Dictionary = StoreScript.create_queue("resume me", _items(6), [WATCH], store)["queue"]
	StoreScript.advance(queue, 2, _pass_all)
	var saved: Dictionary = StoreScript.save_store(store, STORE)
	assert_false(saved.has("error"), str(saved))

	# 模拟重启：全新 load。
	var reloaded: Dictionary = StoreScript.load_store(STORE)
	assert_false(reloaded.has("error"), str(reloaded))
	var resumed_queue: Dictionary = StoreScript.get_queue(reloaded, queue["queue_id"])
	assert_false(resumed_queue.is_empty(), "queue survives the restart")
	assert_eq(int(StoreScript._count_status(resumed_queue, "passed")), 2,
		"collected evidence is retained")

	var resumed: Dictionary = StoreScript.advance(resumed_queue, 10, _pass_all)
	assert_eq(int(resumed["processed"]), 4, "only the remaining items run")
	assert_eq(String(resumed["outcome"]), "completed")

# ============================================================================
# 文件指纹漂移 → 证据失效重验
# ============================================================================

func test_watch_drift_invalidates_collected_evidence() -> void:
	var store: Dictionary = StoreScript.load_store(STORE)
	var queue: Dictionary = StoreScript.create_queue("drift", _items(3), [WATCH], store)["queue"]
	StoreScript.advance(queue, 3, _pass_all)
	assert_eq(String(queue["phase"]), "completed")

	_write(WATCH, "extends Node\nvar speed := 99\n")
	var staled: int = StoreScript.refresh_stale(queue)
	assert_eq(staled, 3, "every verdict goes back to pending")
	assert_eq(String(queue["phase"]), "open")
	var evidence: Dictionary = ((queue["items"] as Array)[0] as Dictionary)["evidence"]
	assert_eq(String(evidence.get("stale_reason", "")).length() > 0, true,
		"the stale verdict keeps its audit trail")

	# 无漂移时再次刷新是幂等的。
	assert_eq(StoreScript.refresh_stale(queue), 0)

func test_no_drift_keeps_evidence() -> void:
	var store: Dictionary = StoreScript.load_store(STORE)
	var queue: Dictionary = StoreScript.create_queue("stable", _items(2), [WATCH], store)["queue"]
	StoreScript.advance(queue, 2, _pass_all)
	assert_eq(StoreScript.refresh_stale(queue), 0)
	assert_eq(String(queue["phase"]), "completed")

# ============================================================================
# 持久化健壮性
# ============================================================================

func test_terminal_queue_refuses_advance() -> void:
	var store: Dictionary = StoreScript.load_store(STORE)
	var queue: Dictionary = StoreScript.create_queue("done", _items(1), [WATCH], store)["queue"]
	StoreScript.advance(queue, 1, _pass_all)
	var again: Dictionary = StoreScript.advance(queue, 1, _pass_all)
	assert_eq(int(again["processed"]), 0)
	assert_eq(String(again["outcome"]), "completed")

func test_create_queue_validates_input() -> void:
	var store: Dictionary = StoreScript.load_store(STORE)
	assert_has(StoreScript.create_queue("x", [], [WATCH], store), "error")
	var dup: Dictionary = StoreScript.create_queue("x",
		[{"id": "same", "kind": "a"}, {"id": "same", "kind": "b"}], [WATCH], store)
	assert_has(dup, "error")
	# 缺 id 的条目自动补号，不报错。
	var auto_id: Dictionary = StoreScript.create_queue("x",
		[{"kind": "a"}, {"kind": "b"}], [WATCH], store)
	assert_false(auto_id.has("error"))

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
