class_name ProjectStateLedger
extends RefCounted

## 跨目标项目状态账本：把每个已完成目标的工件与语义测试套件持久化到
## res://.mcp/project_state.json，让第二个目标"知道"第一个目标建了什么——
## 迭代（"给玩家加个二段跳"）复用已有场景/脚本，而不是建平行新文件。
##
## 纯静态 JSON I/O，无编辑器依赖；有界历史防止无限增长。

const DEFAULT_LEDGER_PATH: String = "res://.mcp/project_state.json"
const SCHEMA_VERSION: int = 1
const MAX_GOAL_HISTORY: int = 50

## 读取账本；不存在或损坏时返回空账本骨架（读侧永不报错——账本是加速器，
## 不是门禁，坏了就当第一次用）。
static func load_ledger(path: String = DEFAULT_LEDGER_PATH) -> Dictionary:
	var ledger: Dictionary = _empty_ledger()
	if not FileAccess.file_exists(path):
		return ledger
	# JSON.new().parse 返回错误码而不向控制台推引擎错误：损坏的账本在
	# GUT/编辑器错误窗口里应当是静默降级，而不是一条吓人的 ERROR。
	var parser: JSON = JSON.new()
	if parser.parse(FileAccess.get_file_as_string(path)) != OK:
		return ledger
	var parsed: Variant = parser.get_data()
	if not (parsed is Dictionary):
		return ledger
	var data: Dictionary = parsed
	if data.get("artifacts") is Dictionary:
		ledger["artifacts"] = data["artifacts"]
	if data.get("goals") is Array:
		ledger["goals"] = data["goals"]
	if data.get("semantic_suite") is String \
			and not String(data["semantic_suite"]).is_empty():
		ledger["semantic_suite"] = data["semantic_suite"]
	return ledger

static func _empty_ledger() -> Dictionary:
	return {
		"schema_version": SCHEMA_VERSION,
		"artifacts": {},
		"goals": [],
		"semantic_suite": "",
	}

## 目标完成时记录：工件合入（不覆盖已有 kind，除非新值非空）、语义套件登记、
## 目标历史有界追加。plan 是 game workflow 的持久 DAG 字典。
static func record_completed_goal(plan: Dictionary, path: String = DEFAULT_LEDGER_PATH) -> Dictionary:
	var workflow: Dictionary = plan.get("workflow", {}) if plan.get("workflow", {}) is Dictionary else {}
	var ledger: Dictionary = load_ledger(path)
	var artifacts: Dictionary = ledger.get("artifacts", {}) if ledger.get("artifacts", {}) is Dictionary else {}
	var plan_artifacts: Dictionary = workflow.get("artifacts", {}) if workflow.get("artifacts", {}) is Dictionary else {}
	for kind in plan_artifacts:
		var value: String = String(plan_artifacts[kind])
		if not value.is_empty():
			artifacts[kind] = value
	ledger["artifacts"] = artifacts
	# 语义套件：完成的 run_game_tests 门禁留下的行为回归资产。
	if String(ledger.get("semantic_suite", "")).is_empty():
		for task_value in plan.get("tasks", []):
			var task: Dictionary = task_value
			if String(task.get("tool_name", "")) != "run_game_tests":
				continue
			if String(task.get("status", "")) != "done":
				continue
			var test_paths: Variant = (task.get("arguments", {}) as Dictionary).get("test_paths", [])
			if test_paths is Array and not (test_paths as Array).is_empty():
				ledger["semantic_suite"] = String((test_paths as Array)[0])
			break
	var goals: Array = ledger.get("goals", []) if ledger.get("goals", []) is Array else []
	goals.append({
		"objective": String(plan.get("goal", "")),
		"workflow_id": String(workflow.get("workflow_id", "")),
		"completed_at": Time.get_datetime_string_from_system(true),
		"artifacts": plan_artifacts.duplicate(),
	})
	while goals.size() > MAX_GOAL_HISTORY:
		goals.pop_front()
	ledger["goals"] = goals
	return save_ledger(ledger, path)

static func save_ledger(ledger: Dictionary, path: String = DEFAULT_LEDGER_PATH) -> Dictionary:
	var absolute_dir: String = ProjectSettings.globalize_path(path).get_base_dir()
	DirAccess.make_dir_recursive_absolute(absolute_dir)
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return {"error": "Cannot write project state ledger at %s" % path}
	file.store_string(JSON.stringify(ledger, "\t"))
	file.close()
	return {"status": "saved", "path": path}

## 迭代上下文：账本是否足以支撑 gameplay 迭代（已有场景 + 脚本）。
static func gameplay_iteration_context(ledger: Dictionary) -> Dictionary:
	var artifacts: Dictionary = ledger.get("artifacts", {}) if ledger.get("artifacts", {}) is Dictionary else {}
	var scene: String = String(artifacts.get("scene", ""))
	var script: String = String(artifacts.get("script", ""))
	if scene.is_empty() or script.is_empty():
		return {}
	return {
		"scene": scene,
		"script": script,
		"semantic_suite": String(ledger.get("semantic_suite", "")),
	}
