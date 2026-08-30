# workflow_checkpoint_store.gd — 工作流检查点、恢复与事务
#
# 背景：长工作流（50 / 100 步）里，Agent 崩溃、编辑器重启、传输中断都会让
# 已经跑过的几十步白白丢失。而且中途失败时没有回滚点，只能重头再来。
#
# 本模块提供：
#   - checkpoint：每个阶段结束时保存场景状态、资源修订、回执、产物、待执行步骤
#   - resume：从任意检查点恢复工作流计划
#   - transaction：begin / commit / rollback，让"一组编辑要么全成功要么全撤销"
#
# 事务语义说明（诚实边界）：
#   本模块保证**工作流计划层**的原子恢复（任务状态、回执、产物登记）。
#   场景内容级撤销依赖 Godot 的 EditorUndoRedoManager；本模块通过可注入的
#   undo_provider 触发它，并在没有 provider 时明确报告 scene_undo=false，
#   绝不假装撤销了场景内容。

class_name MCPWorkflowCheckpointStore
extends RefCounted

const CHECKPOINT_ROOT: String = "res://.mcp/checkpoints"

## 每个工作流默认保留的检查点数量（超出后按时间淘汰最旧的）
const DEFAULT_KEEP_LAST: int = 10

## 事务默认超时，防止 begin 后忘记 commit 而长期占用
const DEFAULT_TRANSACTION_LEASE_MS: int = 30 * 60 * 1000

var _transactions: Dictionary = {}
var _checkpoints_written: int = 0
var _restores: int = 0
var _rollbacks: int = 0
var _undo_provider: Callable = Callable()


## 注入场景级撤销 provider：Callable() -> bool（true 表示撤销成功）
func set_undo_provider(provider: Callable) -> void:
	_undo_provider = provider


# ---------------------------------------------------------------------------
# 检查点
# ---------------------------------------------------------------------------

## 保存一个检查点。
##
## plan 是工作流计划字典；extra 可携带调用方的旁路状态（runtime 会话、fixture 等）。
## 返回 {checkpoint_id, path, sequence, label}
func create_checkpoint(workflow_id: String, label: String, plan: Dictionary,
		extra: Dictionary = {}) -> Dictionary:
	var clean_id: String = _safe_id(workflow_id)
	if clean_id.is_empty():
		return {"error": "workflow_id is required"}
	var sequence: int = _next_sequence(clean_id)
	var checkpoint_id: String = "cp_%03d" % sequence
	var checkpoint: Dictionary = {
		"schema_version": 1,
		"checkpoint_id": checkpoint_id,
		"workflow_id": clean_id,
		"label": label.strip_edges(),
		"sequence": sequence,
		"at": Time.get_datetime_string_from_system(true),
		"at_msec": Time.get_ticks_msec(),
		# 计划层快照：任务、回执、产物、状态
		"tasks": _snapshot_tasks(plan),
		"workflow_state": _snapshot_workflow(plan),
		"artifacts": ((plan.get("workflow", {}) as Dictionary).get("artifacts", {}) as Dictionary).duplicate(true),
		"receipts": ((plan.get("workflow", {}) as Dictionary).get("receipts", []) as Array).duplicate(true),
		"goal": String(plan.get("goal", "")),
		"extra": extra.duplicate(true)
	}
	var target: String = "%s/%s/%s.json" % [CHECKPOINT_ROOT, clean_id, checkpoint_id]
	if DirAccess.make_dir_recursive_absolute(target.get_base_dir()) != OK \
			and not DirAccess.dir_exists_absolute(target.get_base_dir()):
		return {"error": "cannot create checkpoint directory for " + clean_id}
	var file: FileAccess = FileAccess.open(target, FileAccess.WRITE)
	if file == null:
		return {"error": "cannot write checkpoint " + target}
	file.store_string(JSON.stringify(checkpoint, "\t"))
	file.close()
	_checkpoints_written += 1
	return {
		"checkpoint_id": checkpoint_id,
		"path": target,
		"sequence": sequence,
		"label": checkpoint["label"],
		"workflow_id": clean_id
	}


## 列出某工作流的检查点（按序号升序）
func list_checkpoints(workflow_id: String) -> Array[Dictionary]:
	var clean_id: String = _safe_id(workflow_id)
	var directory: String = "%s/%s" % [CHECKPOINT_ROOT, clean_id]
	var entries: Array[Dictionary] = []
	var dir: DirAccess = DirAccess.open(directory)
	if dir == null:
		return entries
	dir.list_dir_begin()
	var file_name: String = dir.get_next()
	while not file_name.is_empty():
		if not dir.current_is_dir() and file_name.ends_with(".json"):
			var full_path: String = "%s/%s" % [directory, file_name]
			var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(full_path))
			if parsed is Dictionary:
				var data: Dictionary = parsed
				entries.append({
					"checkpoint_id": String(data.get("checkpoint_id", "")),
					"label": String(data.get("label", "")),
					"sequence": int(data.get("sequence", 0)),
					"at": String(data.get("at", "")),
					"path": full_path,
					"task_count": (data.get("tasks", []) as Array).size(),
					"receipt_count": (data.get("receipts", []) as Array).size()
				})
		file_name = dir.get_next()
	dir.list_dir_end()
	entries.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a.get("sequence", 0)) < int(b.get("sequence", 0))
	)
	return entries


func latest_checkpoint(workflow_id: String) -> Dictionary:
	var entries: Array[Dictionary] = list_checkpoints(workflow_id)
	if entries.is_empty():
		return {}
	return entries[entries.size() - 1]


## 读取检查点内容
func read_checkpoint(workflow_id: String, checkpoint_id: String) -> Variant:
	var clean_id: String = _safe_id(workflow_id)
	if checkpoint_id.strip_edges().is_empty():
		return {"error": "checkpoint_id is required"}
	var target: String = "%s/%s/%s.json" % [CHECKPOINT_ROOT, clean_id, checkpoint_id]
	if not FileAccess.file_exists(target):
		return {"error": "checkpoint not found: " + target}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(target))
	if not (parsed is Dictionary):
		return {"error": "checkpoint is not a JSON object: " + target}
	return parsed


## 把检查点恢复到 plan 上（就地修改并返回摘要）。
## 只恢复计划层（任务状态/回执/产物/工作流状态），不触碰场景内容。
func restore_into(plan: Dictionary, checkpoint: Dictionary) -> Dictionary:
	if checkpoint.has("error"):
		return checkpoint
	if not checkpoint.has("tasks"):
		return {"error": "checkpoint has no task snapshot"}
	plan["tasks"] = (checkpoint.get("tasks", []) as Array).duplicate(true)
	plan["goal"] = String(checkpoint.get("goal", plan.get("goal", "")))
	var workflow: Variant = plan.get("workflow", {})
	if not (workflow is Dictionary):
		workflow = {}
		plan["workflow"] = workflow
	var workflow_dict: Dictionary = workflow
	var stored_state: Variant = checkpoint.get("workflow_state", {})
	if stored_state is Dictionary:
		for key in (stored_state as Dictionary):
			workflow_dict[key] = (stored_state as Dictionary)[key]
	workflow_dict["artifacts"] = (checkpoint.get("artifacts", {}) as Dictionary).duplicate(true)
	workflow_dict["receipts"] = (checkpoint.get("receipts", []) as Array).duplicate(true)
	_restores += 1
	return {
		"restored": true,
		"checkpoint_id": String(checkpoint.get("checkpoint_id", "")),
		"label": String(checkpoint.get("label", "")),
		"tasks": (plan.get("tasks", []) as Array).size(),
		"receipts": ((plan.get("workflow", {}) as Dictionary).get("receipts", []) as Array).size(),
		"scene_undo": false,
		"note": "plan-level restore only; scene content is untouched"
	}


## 裁剪旧检查点，只保留最近 keep_last 个
func prune(workflow_id: String, keep_last: int = DEFAULT_KEEP_LAST) -> Dictionary:
	var entries: Array[Dictionary] = list_checkpoints(workflow_id)
	var keep: int = maxi(0, keep_last)
	var removed: Array[String] = []
	if entries.size() <= keep:
		return {"removed": removed, "kept": entries.size()}
	var to_remove: Array[Dictionary] = entries.slice(0, entries.size() - keep)
	for entry_value in to_remove:
		var entry: Dictionary = entry_value
		var path: String = String(entry.get("path", ""))
		DirAccess.remove_absolute(path)
		removed.append(String(entry.get("checkpoint_id", "")))
	return {"removed": removed, "kept": keep}


## 删除某工作流的全部检查点
func clear_workflow(workflow_id: String) -> int:
	var clean_id: String = _safe_id(workflow_id)
	var directory: String = "%s/%s" % [CHECKPOINT_ROOT, clean_id]
	return _remove_tree(directory)


# ---------------------------------------------------------------------------
# 事务
# ---------------------------------------------------------------------------

## 开启事务：先落检查点，再把事务登记在内存里。
func begin_transaction(workflow_id: String, plan: Dictionary, label: String = "",
		extra: Dictionary = {}) -> Dictionary:
	var clean_id: String = _safe_id(workflow_id)
	if clean_id.is_empty():
		return {"error": "workflow_id is required"}
	if _transactions.has(clean_id):
		return {
			"error": "transaction already open for workflow '%s'; commit or rollback first" % clean_id,
			"transaction": (_transactions[clean_id] as Dictionary).duplicate(true)
		}
	var checkpoint: Dictionary = create_checkpoint(
		clean_id, label if not label.is_empty() else "transaction_begin", plan, extra)
	if checkpoint.has("error"):
		return checkpoint
	_transactions[clean_id] = {
		"workflow_id": clean_id,
		"checkpoint_id": String(checkpoint.get("checkpoint_id", "")),
		"label": String(checkpoint.get("label", "")),
		"started_at": Time.get_datetime_string_from_system(true),
		"started_at_msec": Time.get_ticks_msec(),
		"lease_ms": DEFAULT_TRANSACTION_LEASE_MS
	}
	var result: Dictionary = (_transactions[clean_id] as Dictionary).duplicate(true)
	result["open"] = true
	return result


## 提交事务：丢弃回滚点（检查点保留用于审计）
func commit_transaction(workflow_id: String) -> Dictionary:
	var clean_id: String = _safe_id(workflow_id)
	if not _transactions.has(clean_id):
		return {"error": "no open transaction for workflow '%s'" % clean_id}
	var transaction: Dictionary = _transactions[clean_id]
	_transactions.erase(clean_id)
	return {
		"committed": true,
		"workflow_id": clean_id,
		"checkpoint_id": String(transaction.get("checkpoint_id", "")),
		"duration_ms": Time.get_ticks_msec() - int(transaction.get("started_at_msec", 0))
	}


## 回滚事务：恢复检查点，并尝试调用场景级 undo provider。
func rollback_transaction(workflow_id: String, plan: Dictionary) -> Dictionary:
	var clean_id: String = _safe_id(workflow_id)
	if not _transactions.has(clean_id):
		return {"error": "no open transaction for workflow '%s'" % clean_id}
	var transaction: Dictionary = _transactions[clean_id]
	var checkpoint_value: Variant = read_checkpoint(
		clean_id, String(transaction.get("checkpoint_id", "")))
	if checkpoint_value is Dictionary and (checkpoint_value as Dictionary).has("error"):
		_transactions.erase(clean_id)
		return checkpoint_value
	var restored: Dictionary = restore_into(plan, checkpoint_value as Dictionary)
	var scene_undo: bool = false
	if _undo_provider.is_valid():
		scene_undo = bool(_undo_provider.call())
	_transactions.erase(clean_id)
	_rollbacks += 1
	restored["rolled_back"] = true
	restored["workflow_id"] = clean_id
	restored["scene_undo"] = scene_undo
	if scene_undo:
		restored["note"] = "plan restored and scene undo applied"
	else:
		restored["note"] = "plan restored; scene undo was not available"
	return restored


func active_transactions() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for key_value in _transactions:
		var entry: Dictionary = (_transactions[key_value] as Dictionary).duplicate(true)
		entry["expired"] = _transaction_expired(entry)
		result.append(entry)
	return result


func stats() -> Dictionary:
	return {
		"checkpoints_written": _checkpoints_written,
		"restores": _restores,
		"rollbacks": _rollbacks,
		"active_transactions": _transactions.size(),
		"root": CHECKPOINT_ROOT
	}


# ---------------------------------------------------------------------------
# 内部实现
# ---------------------------------------------------------------------------

func _snapshot_tasks(plan: Dictionary) -> Array:
	var snapshot: Array = []
	for task_value in (plan.get("tasks", []) as Array):
		if not (task_value is Dictionary):
			continue
		snapshot.append((task_value as Dictionary).duplicate(true))
	return snapshot


func _snapshot_workflow(plan: Dictionary) -> Dictionary:
	var workflow_value: Variant = plan.get("workflow", {})
	if not (workflow_value is Dictionary):
		return {}
	var workflow: Dictionary = workflow_value
	var snapshot: Dictionary = {}
	for key in workflow:
		# 大体积字段由专用字段单独保存，避免重复
		if key in ["receipts", "artifacts"]:
			continue
		snapshot[key] = workflow[key]
	return snapshot.duplicate(true)


func _next_sequence(workflow_id: String) -> int:
	var entries: Array[Dictionary] = list_checkpoints(workflow_id)
	if entries.is_empty():
		return 1
	return int(entries[entries.size() - 1].get("sequence", 0)) + 1


func _transaction_expired(transaction: Dictionary) -> bool:
	var lease: int = int(transaction.get("lease_ms", DEFAULT_TRANSACTION_LEASE_MS))
	if lease <= 0:
		return false
	return Time.get_ticks_msec() - int(transaction.get("started_at_msec", 0)) > lease


func _remove_tree(path: String) -> int:
	if not DirAccess.dir_exists_absolute(path):
		return 0
	var removed: int = 0
	var dir: DirAccess = DirAccess.open(path)
	if dir == null:
		return 0
	dir.list_dir_begin()
	var entry: String = dir.get_next()
	while not entry.is_empty():
		var full_path: String = "%s/%s" % [path, entry]
		if dir.current_is_dir():
			removed += _remove_tree(full_path)
		else:
			DirAccess.remove_absolute(full_path)
			removed += 1
		entry = dir.get_next()
	dir.list_dir_end()
	var parent: DirAccess = DirAccess.open(path.get_base_dir())
	if parent != null:
		parent.remove(path)
	return removed


static func _safe_id(value: String) -> String:
	var text: String = value.strip_edges()
	var result: String = ""
	for character in text:
		var code: int = character.unicode_at(0)
		var is_alnum: bool = (code >= 48 and code <= 57) or \
			(code >= 65 and code <= 90) or (code >= 97 and code <= 122)
		if is_alnum or character == "_" or character == "-":
			result += character
		else:
			result += "_"
	return result.substr(0, 64)
