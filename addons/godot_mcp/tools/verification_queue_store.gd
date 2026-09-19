class_name VerificationQueueStore
extends RefCounted

# 持久化分片验证队列（M5 第三交付：大型 2D 审计 2026-09-19 步骤 3）。
#
# 设计约束（审计验收口径）：
# - 超预算的必要验证项不丢失：单轮只消费 budget 个 pending 项，其余
#   留在队列里；has_more/outcome=pending_more 如实报告"还没收齐"。
# - 重启后继续：队列落盘（staging+promote 原子写，同 ChangeJournal），
#   下次 advance 从剩余 pending 项接续，已收证据不重跑。
# - 文件变化后旧证据失效：watch_paths 的内容指纹随队列保存；refresh_stale
#   以磁盘实况为准，指纹漂移（用户手改/外部写入）把已判定项打回 pending
#   重验——绝不把陈旧证据当有效覆盖。
# - 失败不产生 completed：outcome 只有在 pending==0 且 failed==0 时才是
#   completed；任一失败 → failed（预算内其余项继续收集证据，一次看全貌）。
#
# 纯逻辑支持层（同 TaskPlanStore/ChangeJournal），不注册 MCP 工具、不耦合
# 编辑器接口；执行体由调用方注入（game_workflow 的 prior_feature 演练、
# 工具层的 script_check 编译检查等）。
#
# Persisted shape (res://.mcp/verification_queues.json):
# {
#   "schema_version": 1,
#   "queues": [
#     {
#       "queue_id": "vq_<ms>_<seq>",
#       "goal": "...", "created_at": "...", "updated_at": "...",
#       "phase": "open|completed|failed|abandoned",
#       "watch_paths": ["res://..."],
#       "coverage_fingerprints": {"res://...": "sha256..."},
#       "items": [
#         {"id": "item_1", "kind": "...", "label": "...", "detail": {...},
#          "status": "pending|passed|failed|skipped",
#          "evidence": {...}, "checked_at": "..."}
#       ]
#     }
#   ]
# }

const SCHEMA_VERSION: int = 1
const DEFAULT_STORE_PATH: String = "res://.mcp/verification_queues.json"
const STAGING_SUFFIX: String = ".next"
const FINAL_PHASES: Array = ["completed", "failed", "abandoned"]

# ============================================================================
# 持久化
# ============================================================================

static func load_store(path: String = DEFAULT_STORE_PATH) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {"schema_version": SCHEMA_VERSION, "queues": []}
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {"error": "could not open verification queue store '%s' for reading" % path}
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	file.close()
	if not (parsed is Dictionary):
		return {"error": "verification queue store '%s' is not a JSON object" % path}
	var store: Dictionary = parsed
	if int(store.get("schema_version", 0)) != SCHEMA_VERSION:
		return {"error": "unsupported verification queue schema_version in '%s'" % path}
	if not (store.get("queues") is Array):
		return {"error": "verification queue store '%s' has no queues array" % path}
	return store

## staging + 解析校验 + 原子提升（同 ChangeJournal.save_journal 的协议）。
static func save_store(store: Dictionary, path: String = DEFAULT_STORE_PATH) -> Dictionary:
	var base_dir: String = path.get_base_dir()
	if not base_dir.is_empty():
		var abs_dir: String = ProjectSettings.globalize_path(base_dir)
		if not DirAccess.dir_exists_absolute(abs_dir):
			var make_error: Error = DirAccess.make_dir_recursive_absolute(abs_dir)
			if make_error != OK and not DirAccess.dir_exists_absolute(abs_dir):
				return {"error": "could not create directory '%s'" % base_dir}
	var staging_path: String = path + STAGING_SUFFIX
	var staged_text: String = JSON.stringify(store, "\t")
	var file: FileAccess = FileAccess.open(staging_path, FileAccess.WRITE)
	if file == null:
		return {"error": "could not open '%s' for writing" % staging_path}
	file.store_string(staged_text)
	file.close()
	var reparsed: Variant = JSON.parse_string(staged_text)
	if not (reparsed is Dictionary):
		DirAccess.remove_absolute(staging_path)
		return {"error": "staged verification queue store failed validation at '%s'" % staging_path}
	var absolute_staging: String = ProjectSettings.globalize_path(staging_path)
	var absolute_primary: String = ProjectSettings.globalize_path(path)
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(absolute_primary)
	var rename_error: Error = DirAccess.rename_absolute(absolute_staging, absolute_primary)
	if rename_error != OK:
		return {"error": "could not promote staged verification queue store '%s': %s" % [path, error_string(rename_error)]}
	return {"saved": true}

# ============================================================================
# 队列生命周期
# ============================================================================

## 创建队列。items 每项 {kind, label, detail, id?}；watch_paths 为证据
## 覆盖的文件（指纹漂移 → 证据失效重验）。
static func create_queue(goal: String, items: Array, watch_paths: Array,
		store: Dictionary) -> Dictionary:
	if items.is_empty():
		return {"error": "verification queue needs at least one item"}
	var queue_id: String = _new_queue_id(store)
	var normalized_watches: Array = []
	for path_value in watch_paths:
		var path: String = _normalized(String(path_value))
		if not path.is_empty() and not normalized_watches.has(path):
			normalized_watches.append(path)
	var queue: Dictionary = {
		"queue_id": queue_id,
		"goal": goal,
		"created_at": _now(),
		"updated_at": _now(),
		"phase": "open",
		"watch_paths": normalized_watches,
		"coverage_fingerprints": _fingerprint_paths(normalized_watches),
		"items": [],
	}
	var seen_ids: Dictionary = {}
	for index in range(items.size()):
		var item_value: Variant = items[index]
		if not (item_value is Dictionary):
			return {"error": "queue item %d must be an object" % index}
		var item: Dictionary = item_value
		var item_id: String = String(item.get("id", ""))
		if item_id.is_empty():
			item_id = "item_%d" % (index + 1)
		if seen_ids.has(item_id):
			return {"error": "duplicate queue item id '%s'" % item_id}
		seen_ids[item_id] = true
		queue["items"].append({
			"id": item_id,
			"kind": String(item.get("kind", "custom")),
			"label": String(item.get("label", "")),
			"detail": item.get("detail", {}),
			"status": "pending",
			"evidence": {},
			"checked_at": "",
		})
	(store["queues"] as Array).append(queue)
	return {"queue": queue}

static func get_queue(store: Dictionary, queue_id: String) -> Dictionary:
	for queue_value in store.get("queues", []):
		var queue: Dictionary = queue_value
		if String(queue.get("queue_id", "")) == queue_id:
			return queue
	return {}

## 以磁盘实况刷新证据有效性：watch_paths 指纹与 coverage_fingerprints
## 不符 → 已判定项（passed/failed）打回 pending（证据保留在 evidence 的
## stale_evidence 里供审计），phase 回 open。返回失效项数。
static func refresh_stale(queue: Dictionary) -> int:
	var watch_paths: Array = queue.get("watch_paths", [])
	var current: Dictionary = _fingerprint_paths(watch_paths)
	var recorded: Dictionary = queue.get("coverage_fingerprints", {}) if queue.get("coverage_fingerprints", {}) is Dictionary else {}
	var drifted: bool = false
	for path_value in watch_paths:
		var path: String = String(path_value)
		if String(current.get(path, "")) != String(recorded.get(path, "")):
			drifted = true
			break
	if not drifted:
		return 0
	var staled: int = 0
	for item_value in queue.get("items", []):
		var item: Dictionary = item_value
		var status: String = String(item.get("status", ""))
		if status == "passed" or status == "failed":
			var stale_evidence: Dictionary = item.get("evidence", {}).duplicate() if item.get("evidence", {}) is Dictionary else {}
			stale_evidence["stale_reason"] = "watched files changed since this verdict was recorded"
			item["evidence"] = stale_evidence
			item["status"] = "pending"
			item["checked_at"] = ""
			staled += 1
	queue["coverage_fingerprints"] = current
	queue["phase"] = "open"
	queue["updated_at"] = _now()
	return staled

## 分片推进：按序消费最多 budget 个 pending 项；executor(item) ->
## {"passed": bool, "evidence": {...}}，或 {"defer": true} 表示该项等待
## 外部执行器（保持 pending、不消耗预算）。失败不中断本轮（一次看全貌），
## 但 outcome 永远不会在有失败或未收齐时报 completed。返回：
## {processed, passed_count, failed_count, pending_count, has_more,
##  outcome: completed|failed|pending_more, items: 本轮判定}
static func advance(queue: Dictionary, budget: int,
		executor: Callable) -> Dictionary:
	if String(queue.get("phase", "")) in FINAL_PHASES:
		return {
			"processed": 0, "passed_count": _count_status(queue, "passed"),
			"failed_count": _count_status(queue, "failed"),
			"pending_count": _count_status(queue, "pending"),
			"has_more": false,
			"outcome": String(queue.get("phase", "")),
			"items": [],
			"notes": ["queue is in terminal phase '%s'; create a new queue for a re-run" % String(queue.get("phase", ""))],
		}
	var processed: Array = []
	for item_value in queue.get("items", []):
		if budget <= 0:
			break
		var item: Dictionary = item_value
		if String(item.get("status", "")) != "pending":
			continue
		var verdict: Variant = executor.call(item)
		if verdict is Dictionary and (verdict as Dictionary).get("defer", false):
			continue
		var passed: bool = verdict is Dictionary and bool((verdict as Dictionary).get("passed", false))
		var evidence: Dictionary = {}
		if verdict is Dictionary:
			var evidence_value: Variant = (verdict as Dictionary).get("evidence", {})
			if evidence_value is Dictionary:
				evidence = evidence_value
		item["status"] = "passed" if passed else "failed"
		item["evidence"] = evidence
		item["checked_at"] = _now()
		processed.append({
			"id": String(item.get("id", "")),
			"label": String(item.get("label", "")),
			"status": String(item["status"]),
		})
		budget -= 1

	var passed_count: int = _count_status(queue, "passed")
	var failed_count: int = _count_status(queue, "failed")
	var pending_count: int = _count_status(queue, "pending")
	var outcome: String = "pending_more"
	if pending_count == 0 and failed_count == 0:
		outcome = "completed"
		queue["phase"] = "completed"
	elif failed_count > 0 and pending_count == 0:
		outcome = "failed"
		queue["phase"] = "failed"
	queue["updated_at"] = _now()
	return {
		"processed": processed.size(),
		"passed_count": passed_count,
		"failed_count": failed_count,
		"pending_count": pending_count,
		"has_more": pending_count > 0,
		"outcome": outcome,
		"items": processed,
	}

static func _count_status(queue: Dictionary, status: String) -> int:
	var count: int = 0
	for item_value in queue.get("items", []):
		if String((item_value as Dictionary).get("status", "")) == status:
			count += 1
	return count

# ============================================================================
# 内部辅助
# ============================================================================

static func file_sha256(path: String) -> String:
	if not FileAccess.file_exists(path):
		return ""
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		return ""
	var content: String = file.get_as_text()
	file.close()
	return content.sha256_text()

static func _fingerprint_paths(paths: Array) -> Dictionary:
	var fingerprints: Dictionary = {}
	for path_value in paths:
		var path: String = String(path_value)
		fingerprints[path] = file_sha256(path)
	return fingerprints

static func _new_queue_id(store: Dictionary) -> String:
	var sequence: int = (store.get("queues", []) as Array).size() + 1
	return "vq_%d_%03d" % [Time.get_unix_time_from_system() * 1000.0, sequence]

static func _now() -> String:
	return Time.get_datetime_string_from_system(true, true)

static func _normalized(path_value: String) -> String:
	var normalized: String = path_value.strip_edges().replace("\\", "/")
	if normalized.begins_with("res:/") and not normalized.begins_with("res://"):
		normalized = "res://" + normalized.substr(5)
	while normalized.contains("//") and not normalized.begins_with("res://"):
		normalized = normalized.replace("//", "/")
	return normalized
