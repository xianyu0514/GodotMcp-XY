# chaos_suite.gd — 混沌注入与自动恢复验证
#
# 背景：MCP 在"一切正常"时跑通不代表可靠。真正的问题是注入故障后能不能自愈：
#   连接中断 / 超时 / 缓存过期 / 收据失效 / 运行时缺失 /
#   编辑器重载 / 文件被删 / UID 变更
#
# 设计原则（与覆盖门禁一致）：
#   - 没有适配器（无法真实注入）的场景返回 "skipped" + 明确原因，**绝不返回 PASS**
#   - 只有「注入成功」且「恢复断言通过」才算 PASS
#   - 每个场景都返回可审计的 evidence，而不是一句 ok
#
# 内置场景在纯内存组件上运行（收据缓存、覆盖追踪、检查点、文件总线、会话管理），
# 不触碰真实项目；环境级场景（断连 / 编辑器重载）需要调用方注册适配器。

class_name MCPChaosSuite
extends RefCounted

## 场景结论（与覆盖追踪同一套语义）
const STATUS_PASS: String = "PASS"
const STATUS_FAIL: String = "FAIL"
const STATUS_SKIPPED: String = "SKIPPED"
const STATUS_ERROR: String = "ERROR"

## 内置场景名
const SCENARIOS: Array[String] = [
	"drop_connection", "timeout", "stale_cache", "invalid_receipt",
	"missing_runtime", "editor_reload", "deleted_file", "changed_uid"
]

## 完全自包含、无需适配器的场景
const SELF_CONTAINED: Array[String] = [
	"stale_cache", "invalid_receipt", "missing_runtime", "deleted_file", "timeout"
]

const TaxonomyScript = preload("res://addons/godot_mcp/utils/failure_taxonomy.gd")
const ReceiptCacheScript = preload("res://addons/godot_mcp/native_mcp/semantic_receipt_cache.gd")
const FileMutationBusScript = preload("res://addons/godot_mcp/native_mcp/file_mutation_bus.gd")
const RuntimeSessionScript = preload("res://addons/godot_mcp/native_mcp/runtime_session_manager.gd")

## 环境级场景适配器：name -> Callable(context) -> Dictionary
var _adapters: Dictionary = {}

var _runs: int = 0
var _passed: int = 0
var _failed: int = 0
var _skipped: int = 0


## 注册一个环境级场景适配器。
## adapter 签名：func(context: Dictionary) -> Dictionary
## 必须返回 {injected: bool, recovered: bool, evidence: Dictionary}
func register_adapter(scenario_name: String, adapter: Callable) -> bool:
	var name: String = scenario_name.strip_edges()
	if name.is_empty() or not adapter.is_valid():
		return false
	_adapters[name] = adapter
	return true


func registered_adapters() -> Array[String]:
	var result: Array[String] = []
	for name_value in _adapters:
		result.append(String(name_value))
	result.sort()
	return result


# ---------------------------------------------------------------------------
# 执行
# ---------------------------------------------------------------------------

## 运行指定场景（空数组表示全部内置场景）。
##
## context 可携带被测组件实例：
##   receipt_cache: MCPSemanticReceiptCache
##   mutation_bus:  MCPFileMutationBus
##   runtime:       MCPRuntimeSessionManager
##   coverage:      MCPToolCoverageTracker
##   checkpoints:   MCPWorkflowCheckpointStore
func run(scenario_names: Array = [], context: Dictionary = {}) -> Dictionary:
	var names: Array[String] = []
	if scenario_names.is_empty():
		names = SCENARIOS.duplicate()
	else:
		for name_value in scenario_names:
			var name: String = String(name_value).strip_edges().to_lower()
			if name in SCENARIOS and not name in names:
				names.append(name)
			elif not name.is_empty() and not name in SCENARIOS:
				names.append(name)

	var results: Array[Dictionary] = []
	for name in names:
		results.append(_run_one(name, context))
		_runs += 1

	var passed: int = 0
	var failed: int = 0
	var skipped: int = 0
	var errored: int = 0
	for entry_value in results:
		var status: String = String((entry_value as Dictionary).get("status", ""))
		match status:
			STATUS_PASS: passed += 1
			STATUS_FAIL: failed += 1
			STATUS_SKIPPED: skipped += 1
			_: errored += 1
	_passed += passed
	_failed += failed
	_skipped += skipped

	return {
		"scenarios": results,
		"summary": {
			"total": results.size(),
			"passed": passed,
			"failed": failed,
			"skipped": skipped,
			"errored": errored,
			# 混沌门禁：允许 skip（环境不支持），但不允许 fail/error
			"gate_passed": failed == 0 and errored == 0
		},
		"adapters": registered_adapters()
	}


func stats() -> Dictionary:
	return {"runs": _runs, "passed": _passed, "failed": _failed, "skipped": _skipped}


func reset_diagnostics() -> void:
	_runs = 0
	_passed = 0
	_failed = 0
	_skipped = 0


# ---------------------------------------------------------------------------
# 场景实现
# ---------------------------------------------------------------------------

func _run_one(scenario_name: String, context: Dictionary) -> Dictionary:
	if _adapters.has(scenario_name):
		return _run_adapter(scenario_name, context)
	match scenario_name:
		"stale_cache":
			return _scenario_stale_cache(context)
		"invalid_receipt":
			return _scenario_invalid_receipt(context)
		"missing_runtime":
			return _scenario_missing_runtime(context)
		"deleted_file":
			return _scenario_deleted_file(context)
		"timeout":
			return _scenario_timeout(context)
		_:
			return {
				"scenario": scenario_name,
				"status": STATUS_SKIPPED,
				"reason": "no adapter registered for this environment-level scenario; "
					+ "register one with register_adapter('%s', callable) to actually test it" % scenario_name,
				"evidence": {"self_contained": scenario_name in SELF_CONTAINED}
			}


## 注入：把一条 VALID 收据标记为 STALE。
## 断言：lookup 不再报告 reusable，且状态为 stale（不得被复用）。
func _scenario_stale_cache(context: Dictionary) -> Dictionary:
	# 跨模块引用统一走 Variant + 鸭子类型：class_name 静态类型依赖全局类缓存的
	# 加载顺序，在 headless -s 场景下可能尚未注册。
	var cache: Variant = context.get("receipt_cache", null)
	if cache == null or not cache.has_method("record"):
		cache = ReceiptCacheScript.new()
	var key_value: String = "chaos-key"
	cache.record("get_project_info", key_value, {
		"status_name": "success", "objective_proven": true
	}, "", {"read_only": true, "idempotent": true})
	var baseline: Dictionary = cache.lookup(key_value)
	if not bool(baseline.get("reusable", false)):
		return {
			"scenario": "stale_cache",
			"status": STATUS_FAIL,
			"reason": "baseline receipt was reusable=false before injecting the fault",
			"evidence": {"baseline": baseline}
		}
	cache.revalidate({key_value: {}})
	var after_value: Dictionary = cache.lookup(key_value)
	return {
		"scenario": "stale_cache",
		"status": STATUS_PASS if String(after_value.get("status", "")) == "stale" else STATUS_FAIL,
		"reason": "stale receipt must never be reused",
		"evidence": {"baseline": baseline, "after_injection": after_value}
	}


## 注入：先记录 BLOCKED，再尝试把 positive_test 写成 PASS。
## 断言：追踪器必须拒绝这条跃迁（BLOCKED -> PASS 是被禁止的）。
func _scenario_invalid_receipt(context: Dictionary) -> Dictionary:
	var coverage: Variant = context.get("coverage", null)
	if coverage == null or not coverage.has_method("start_session"):
		coverage = load("res://addons/godot_mcp/native_mcp/tool_coverage_tracker.gd").new()
	coverage.start_session("chaos", ["chaos_tool"])
	coverage.record({
		"tool_name": "chaos_tool", "execution_status": "invoked",
		"positive_test": "BLOCKED", "applicability": "yes"
	})
	var rejected: Dictionary = coverage.record({
		"tool_name": "chaos_tool", "positive_test": "PASS"
	})
	var accepted: bool = bool(rejected.get("accepted", false))
	return {
		"scenario": "invalid_receipt",
		"status": STATUS_PASS if not accepted else STATUS_FAIL,
		"reason": "BLOCKED -> PASS must be rejected by the coverage tracker",
		"evidence": {"errors": rejected.get("errors", []), "warnings": rejected.get("warnings", [])}
	}


## 注入：runtime 会话从未启动。
## 断言：任何 runtime 工具都必须报出缺失的前置事实，而不是悄悄执行。
func _scenario_missing_runtime(context: Dictionary) -> Dictionary:
	var session: Variant = context.get("runtime", null)
	if session == null or not session.has_method("missing_prerequisites"):
		session = RuntimeSessionScript.new()
		session.set_liveness_probe(func() -> bool: return false)
	session.reset()
	var missing: Array[String] = session.missing_prerequisites("call_runtime_node_method")
	var ready: bool = session.is_ready()
	return {
		"scenario": "missing_runtime",
		"status": STATUS_PASS if (not missing.is_empty() and not ready) else STATUS_FAIL,
		"reason": "runtime tools must report missing prerequisites when no session is running",
		"evidence": {"missing": missing, "runtime_ready": ready}
	}


## 注入：发布一次文件删除事件。
## 断言：订阅者收到批次，且批次带出被删除路径与失效事实。
func _scenario_deleted_file(context: Dictionary) -> Dictionary:
	var bus: Variant = context.get("mutation_bus", null)
	if bus == null or not bus.has_method("publish_deleted"):
		bus = FileMutationBusScript.new()
	bus.subscribe("chaos_probe", func(batch: Dictionary) -> int:
		return OK
	)
	bus.publish_deleted("res://chaos/fixture_probe.gd", {"tool_name": "chaos"})
	var batch: Dictionary = bus.flush()
	var deleted: Array = batch.get("deleted_paths", [])
	var facts: Array = batch.get("facts_invalidated", [])
	var recovered: bool = deleted.has("res://chaos/fixture_probe.gd") and not facts.is_empty()
	bus.unsubscribe("chaos_probe")
	return {
		"scenario": "deleted_file",
		"status": STATUS_PASS if recovered else STATUS_FAIL,
		"reason": "a delete must fan out to every cache subscriber in one batch",
		"evidence": {
			"deleted_paths": deleted,
			"facts_invalidated": facts,
			"delivered_to": batch.get("delivered_to", [])
		}
	}


## 注入：一次超时错误。
## 断言：必须被分类成 transport_error 并给出退避重试策略，而不是 replan。
func _scenario_timeout(context: Dictionary) -> Dictionary:
	var category: int = TaxonomyScript.classify_text("request timed out after 30s")
	var decision: Dictionary = TaxonomyScript.policy_for(category, 1)
	var is_transport: bool = TaxonomyScript.category_name(category) == "transport_error"
	var is_retry: bool = String(decision.get("policy", "")) == "retry_backoff"
	return {
		"scenario": "timeout",
		"status": STATUS_PASS if (is_transport and is_retry) else STATUS_FAIL,
		"reason": "timeouts must be retried with backoff, never treated as a tool failure",
		"evidence": {"category": TaxonomyScript.category_name(category), "policy": decision}
	}


func _run_adapter(scenario_name: String, context: Dictionary) -> Dictionary:
	var adapter: Callable = _adapters[scenario_name]
	var raw: Variant = adapter.call(context)
	if not (raw is Dictionary):
		return {
			"scenario": scenario_name,
			"status": STATUS_ERROR,
			"reason": "adapter must return a Dictionary",
			"evidence": {"raw": str(raw)}
		}
	var result: Dictionary = raw
	if not bool(result.get("injected", false)):
		return {
			"scenario": scenario_name,
			"status": STATUS_SKIPPED,
			"reason": String(result.get("reason", "adapter reported that the fault was not injected")),
			"evidence": result.get("evidence", {})
		}
	var recovered: bool = bool(result.get("recovered", false))
	return {
		"scenario": scenario_name,
		"status": STATUS_PASS if recovered else STATUS_FAIL,
		"reason": String(result.get("reason", "")),
		"evidence": result.get("evidence", {})
	}
