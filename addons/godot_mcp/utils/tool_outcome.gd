# tool_outcome.gd — 统一工具结果语义
#
# 核心问题：过去「工具返回成功」被直接等同于「目标达成」，产生 false positive。
# 最典型的案例是 run_project：进程起来了、工具返回 success，但游戏因为
# Parse Error 在两帧后就退出了。传输层成功 ≠ 目标成功。
#
# 本模块定义唯一的结果词汇表，并提供从任意工具返回字典归一化到 ToolOutcome
# 的纯函数。所有判定都保留原始 evidence，绝不把结果压缩成一句 "completed"。

class_name MCPToolOutcome
extends RefCounted

## 结果状态。与失败分类（category）正交：
##   状态回答「执行得怎么样」，分类回答「为什么」。
enum Status {
	SUCCESS,        # 执行成功且目标达成
	PARTIAL,        # 部分成功：有产出但不完整（例如批量操作有若干失败项）
	PENDING,        # 异步执行中，需要轮询
	BLOCKED,        # 被前置条件或策略挡住，重试前需要外部变化
	UNSUPPORTED,    # 当前引擎/平台不支持该能力（能力缺口，不是失败）
	UNCONFIGURED,   # 环境未配置（缺模板、缺 SDK），需要 Agent 介入
	FAILURE         # 确定性失败
}

const STATUS_NAMES: Array[String] = [
	"success", "partial", "pending", "blocked",
	"unsupported", "unconfigured", "failure"
]

## 这些状态视为「已终结且可接受」，工作流可以继续推进
const ACCEPTABLE_STATUSES: Array[String] = ["success", "partial"]

## 这些状态必须等外部条件变化，不能原地重试
const WAITING_STATUSES: Array[String] = ["pending", "blocked"]

## 这些状态说明能力本身不可用，应记录 capability gap 而不是记 FAIL
const GAP_STATUSES: Array[String] = ["unsupported", "unconfigured"]

## 工具结果中表示「还在跑」的状态词
const PENDING_RESULT_STATUSES: Array[String] = [
	"pending", "running", "queued", "accepted", "in_progress",
	"processing", "downloading", "installing", "waiting"
]

## 工具结果中表示「明确失败」的状态词
const NEGATIVE_RESULT_STATUSES: Array[String] = [
	"failed", "failing", "error", "invalid", "blocked", "cancelled",
	"canceled", "timeout", "timed_out", "unconfigured", "missing",
	"skipped", "stale", "aborted", "unsupported"
]

## 计数器字段：任一项 > 0 即视为有问题（与 verdict 字段独立校验）
const COUNTER_FIELDS: Array[String] = [
	"failed", "failed_count", "error_count", "errors_count", "invalid_count"
]

## 判定字段：存在且为 false 即视为失败
const VERDICT_FIELDS: Array[String] = ["passed", "success", "valid"]

const TaxonomyScript = preload("res://addons/godot_mcp/utils/failure_taxonomy.gd")


## 把任意工具返回归一化为 ToolOutcome 字典。
##
## 返回结构：
## {
##   tool_name, status, status_name, objective_proven,
##   transport_success, evidence, counters, verdicts,
##   category, policy, message, pending_progress
## }
##
## `context` 可传：
##   objective_required: bool —— 该步骤是否要求产出目标证据
##   objective_proven:   bool —— 由调用方提供的旁路验证结论
static func from_result(tool_name: String, result: Variant, context: Dictionary = {}) -> Dictionary:
	var outcome: Dictionary = {
		"tool_name": tool_name,
		"status": Status.FAILURE,
		"status_name": "failure",
		"objective_proven": false,
		"transport_success": false,
		"evidence": {},
		"counters": {},
		"verdicts": {},
		"category": "",
		"policy": "",
		"message": "",
		"pending_progress": {}
	}
	if not (result is Dictionary):
		outcome["message"] = "tool returned a non-dictionary result"
		return outcome
	var data: Dictionary = result
	if data.is_empty():
		outcome["message"] = "tool returned an empty result"
		return outcome

	# 传输成功只说明调用到了，不代表目标达成
	outcome["transport_success"] = not data.has("error")

	var status_text: String = String(data.get("status", "")).strip_edges().to_lower()
	if status_text in PENDING_RESULT_STATUSES:
		outcome["status"] = Status.PENDING
		outcome["status_name"] = status_name(Status.PENDING)
		outcome["pending_progress"] = _extract_progress(data)
		outcome["evidence"] = _extract_evidence(data)
		return outcome

	var has_error: bool = data.has("error")
	if has_error:
		outcome["status"] = Status.FAILURE
		outcome["status_name"] = status_name(Status.FAILURE)
		var category: int = TaxonomyScript.classify_result(data, context)
		outcome["category"] = TaxonomyScript.category_name(category)
		var decision: Dictionary = TaxonomyScript.policy_for(
			category, maxi(1, int(context.get("attempt", 1))))
		outcome["policy"] = String(decision.get("policy", ""))
		outcome["message"] = String(data.get("error", "")).substr(0, 512)
		return outcome

	if bool(data.get("blocked", false)):
		outcome["status"] = Status.BLOCKED
		outcome["status_name"] = status_name(Status.BLOCKED)
		outcome["category"] = TaxonomyScript.category_name(TaxonomyScript.Category.POLICY_BLOCK)
		outcome["policy"] = TaxonomyScript.policy_name(TaxonomyScript.Policy.ABORT)
		outcome["message"] = String(data.get("error", data.get("reason", "blocked"))).substr(0, 512)
		return outcome

	if status_text == "unsupported":
		outcome["status"] = Status.UNSUPPORTED
		outcome["status_name"] = status_name(Status.UNSUPPORTED)
		outcome["category"] = TaxonomyScript.category_name(TaxonomyScript.Category.ENVIRONMENT_ERROR)
		outcome["policy"] = TaxonomyScript.policy_name(TaxonomyScript.Policy.WAIT_AGENT_INPUT)
		outcome["message"] = String(data.get("message", "capability is unsupported")).substr(0, 512)
		return outcome

	if status_text in ["unconfigured", "missing"]:
		outcome["status"] = Status.UNCONFIGURED
		outcome["status_name"] = status_name(Status.UNCONFIGURED)
		outcome["category"] = TaxonomyScript.category_name(TaxonomyScript.Category.ENVIRONMENT_ERROR)
		outcome["policy"] = TaxonomyScript.policy_name(TaxonomyScript.Policy.WAIT_AGENT_INPUT)
		outcome["message"] = String(data.get("message", "environment is unconfigured")).substr(0, 512)
		return outcome

	outcome["verdicts"] = _extract_verdicts(data)
	outcome["counters"] = _extract_counters(data)
	outcome["evidence"] = _extract_evidence(data)

	if status_text in NEGATIVE_RESULT_STATUSES:
		outcome["status"] = Status.FAILURE
		outcome["status_name"] = status_name(Status.FAILURE)
		var failed_category: int = TaxonomyScript.classify_result(data, context)
		outcome["category"] = TaxonomyScript.category_name(failed_category)
		outcome["policy"] = String(TaxonomyScript.policy_for(
			failed_category, maxi(1, int(context.get("attempt", 1)))).get("policy", ""))
		outcome["message"] = String(data.get("message", status_text)).substr(0, 512)
		return outcome

	if _has_negative_verdict(outcome["verdicts"]) or _has_positive_counter(outcome["counters"]):
		outcome["status"] = Status.FAILURE
		outcome["status_name"] = status_name(Status.FAILURE)
		outcome["category"] = TaxonomyScript.category_name(TaxonomyScript.Category.OBJECTIVE_ERROR)
		outcome["policy"] = TaxonomyScript.policy_name(TaxonomyScript.Policy.REPLAN)
		outcome["message"] = "verification verdict or counter indicates failure"
		return outcome

	if _has_partial_signal(outcome["counters"], data):
		outcome["status"] = Status.PARTIAL
		outcome["status_name"] = status_name(Status.PARTIAL)
	else:
		outcome["status"] = Status.SUCCESS
		outcome["status_name"] = status_name(Status.SUCCESS)

	# objective_proven：有明确目标要求时必须由调用方提供旁路证据
	var objective_required: bool = bool(context.get("objective_required", false))
	var provided_proof: bool = context.has("objective_proven")
	var proven: bool = bool(context.get("objective_proven", true))
	outcome["objective_proven"] = proven if objective_required or provided_proof else true

	if objective_required and not outcome["objective_proven"]:
		outcome["status"] = Status.FAILURE
		outcome["status_name"] = status_name(Status.FAILURE)
		outcome["category"] = TaxonomyScript.category_name(TaxonomyScript.Category.OBJECTIVE_ERROR)
		outcome["policy"] = TaxonomyScript.policy_name(TaxonomyScript.Policy.REPLAN)
		if outcome["message"].is_empty():
			outcome["message"] = "transport succeeded but objective was not proven"
	return outcome


## 工作流是否可以把这个 outcome 当作「步骤完成」
static func is_acceptable(outcome: Dictionary) -> bool:
	return String(outcome.get("status_name", "")) in ACCEPTABLE_STATUSES


## 是否需要等待外部条件（轮询 / 等 Agent 装依赖）
static func is_waiting(outcome: Dictionary) -> bool:
	return String(outcome.get("status_name", "")) in WAITING_STATUSES


## 是否属于能力缺口（应记 CAPABILITY_GAP 而非 FAIL）
static func is_capability_gap(outcome: Dictionary) -> bool:
	return String(outcome.get("status_name", "")) in GAP_STATUSES


static func status_name(status: int) -> String:
	if status >= 0 and status < STATUS_NAMES.size():
		return STATUS_NAMES[status]
	return ""


static func status_from_name(name: String) -> int:
	return STATUS_NAMES.find(name.strip_edges().to_lower())


static func _extract_verdicts(data: Dictionary) -> Dictionary:
	var verdicts: Dictionary = {}
	for key in VERDICT_FIELDS:
		if data.has(key):
			verdicts[key] = bool(data[key])
	return verdicts


static func _extract_counters(data: Dictionary) -> Dictionary:
	var counters: Dictionary = {}
	for key in COUNTER_FIELDS:
		if data.has(key):
			counters[key] = int(data[key])
	return counters


static func _has_negative_verdict(verdicts: Dictionary) -> bool:
	for key in verdicts:
		if not bool(verdicts[key]):
			return true
	return false


static func _has_positive_counter(counters: Dictionary) -> bool:
	for key in counters:
		if int(counters[key]) > 0:
			return true
	return false


## 部分成功信号：批量工具常见「成功 N 个、跳过/失败 0 个但告警 M 个」。
static func _has_partial_signal(counters: Dictionary, data: Dictionary) -> bool:
	for key in ["warnings_count", "warning_count", "skipped_count", "partial_count"]:
		if data.has(key) and int(data[key]) > 0:
			return true
	return bool(data.get("partial", false))


## 抽取进度信息。异步工具必须能在 pending 阶段报告 bytes/percent/phase，
## 否则 Agent 无法区分「正常下载」与「卡死」。
static func _extract_progress(data: Dictionary) -> Dictionary:
	var progress: Dictionary = {}
	var source: Dictionary = data
	if data.get("progress") is Dictionary:
		source = data["progress"]
	for key in ["phase", "bytes", "total", "percent", "received_bytes", "total_bytes", "speed"]:
		if source.has(key):
			progress[key] = source[key]
	if source.has("downloaded_bytes") and not progress.has("bytes"):
		progress["bytes"] = source["downloaded_bytes"]
	if source.has("total_bytes") and not progress.has("total"):
		progress["total"] = source["total_bytes"]
	return progress


## 抽取证据：从原始结果中保留可验证的数值与集合，不删除大字段。
## 调用方（evidence_store）负责在体积超标时落盘并替换为 ref。
static func _extract_evidence(data: Dictionary) -> Dictionary:
	var evidence: Dictionary = {}
	for key in data:
		var name: String = String(key)
		if name in ["error", "status", "progress"]:
			continue
		evidence[name] = data[key]
	return evidence
