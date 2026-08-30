# semantic_receipt_cache.gd — 语义收据复用
#
# 背景：工作流执行 50 步，前 45 步已 PASS，第 46 步失败。Replan 后重新执行
# 前面的步骤，造成 token、时间、工具调用三重浪费，还会产生重复副作用并污染
# 项目状态。
#
# 关键设计：Receipt Key 不是 workflow_step_id，而是**语义键**：
#   tool_name
#   + normalized_arguments
#   + dependency_revision（依赖的缓存修订快照）
#   + input_artifact_digest
#   + engine_version
#   + project_revision
#
# 只要这些没变，之前验证过的收据就可以直接复用，而不必重跑。
#
# 失效粒度由「事实」而非工具决定：场景变了要失效 scene/node/runtime/visual 相关
# 收据，但不该失效 export template status。

class_name MCPSemanticReceiptCache
extends RefCounted

## 收据生命周期
enum Lifecycle {
	VALID,          # 依赖未变，可直接复用
	STALE,          # 依赖已变，需要重新执行
	INVALID,        # 被显式作废（例如事实被 invalidate）
	NON_REUSABLE    # 该结果从一开始就不允许复用（非确定性 / 有副作用）
}

const LIFECYCLE_NAMES: Array[String] = ["valid", "stale", "invalid", "non_reusable"]

## 参与语义键计算时要剔除的参数键：它们只影响传输，不影响结果语义。
const VOLATILE_ARGUMENT_KEYS: Array[String] = [
	"_meta", "progressToken", "progress_token", "request_id",
	"trace_id", "_timestamp", "client_id"
]

## 只有这些结果才允许被复用。判定为失败 / 待定 / 能力缺口的结果一律不可复用，
## 否则会把一次失败或"环境没配好"固化成永久结论。
const REUSABLE_STATUS_NAMES: Array[String] = ["success"]

## 内联证据的体积护栏。收据缓存常驻内存，不能让一份大结果把它撑爆；
## 超限就退化成 evidence_ref（调用方仍可从证据仓库回查完整内容）。
const INLINE_EVIDENCE_MAX_BYTES: int = 20000
const INLINE_EVIDENCE_MAX_KEYS: int = 24

## 缓存容量上限，按 LRU 淘汰。
const MAX_ENTRIES: int = 512

const TokenEstimatorScript = preload("res://addons/godot_mcp/utils/token_estimator.gd")
const CapabilityDAGScript = preload("res://addons/godot_mcp/native_mcp/capability_dag.gd")

# --- 实例状态 ---------------------------------------------------------------

var _entries: Dictionary = {}
var _insertion_order: Array[String] = []
var _hits: int = 0
var _misses: int = 0
var _invalidations: int = 0
var _evictions: int = 0
var _reuses: int = 0


# ---------------------------------------------------------------------------
# 语义键计算（静态，纯函数）
# ---------------------------------------------------------------------------

## 计算语义键。
##
## context 可包含：
##   dependency_revisions: Dictionary  —— 依赖修订快照（来自 cache_revision_index）
##   input_artifact_digest: String     —— 输入产物的内容摘要
##   engine_version: String            —— Godot 版本
##   project_revision: int             —— 项目级修订（外部传入的单调计数）
static func semantic_key(tool_name: String, arguments: Variant, context: Dictionary = {}) -> String:
	var payload: Dictionary = {
		"tool": tool_name,
		"arguments": normalize_arguments(arguments),
		"dependency_revisions": _canonical_revisions(context.get("dependency_revisions", {})),
		"input_artifact_digest": String(context.get("input_artifact_digest", "")),
		"engine_version": String(context.get("engine_version", "")),
		"project_revision": int(context.get("project_revision", 0))
	}
	return TokenEstimatorScript.canonical_json(payload).sha256_text()


## 归一化参数：剔除传输层键、递归排序字典键，保证语义相同则键相同。
static func normalize_arguments(value: Variant) -> Variant:
	if value is Dictionary:
		var data: Dictionary = value
		var result: Dictionary = {}
		var keys: Array = data.keys()
		keys.sort()
		for key_value in keys:
			var key: String = String(key_value)
			if key in VOLATILE_ARGUMENT_KEYS:
				continue
			result[key] = normalize_arguments(data[key_value])
		return result
	if value is Array:
		var items: Array = value
		var result_items: Array = []
		for item in items:
			result_items.append(normalize_arguments(item))
		return result_items
	return value


## 是否允许复用某个结果。默认只允许完整成功的确定性结果。
static func is_reusable(outcome: Dictionary, traits: Dictionary = {}) -> bool:
	if outcome.is_empty():
		return false
	if bool(traits.get("destructive", false)) or bool(traits.get("has_side_effects", false)):
		return false
	if not bool(traits.get("idempotent", false)) and not bool(traits.get("read_only", false)):
		return false
	var status_name: String = String(outcome.get("status_name", ""))
	if not status_name in REUSABLE_STATUS_NAMES:
		return false
	# 传输成功但目标未验证通过的结果不可复用：那正是要重跑的场景
	if not bool(outcome.get("objective_proven", true)):
		return false
	return true


# ---------------------------------------------------------------------------
# 实例 API
# ---------------------------------------------------------------------------

## 记录一条可复用收据。返回是否真的被缓存（不可复用时返回 false）。
##
## evidence 是未落盘时的内联证据体；超过 INLINE_EVIDENCE_MAX_BYTES 会退化成
## 只留 evidence_ref，并置 evidence_truncated=true —— 复用方必须能回查落盘
## 证据，不能拿到一份看起来完整其实是空壳的收据。
func record(tool_name: String, semantic_key: String, outcome: Dictionary,
		evidence_ref: String = "", traits: Dictionary = {},
		evidence: Dictionary = {}) -> bool:
	if not is_reusable(outcome, traits):
		var existing: Variant = _entries.get(semantic_key, null)
		if existing is Dictionary:
			_entries.erase(semantic_key)
			_insertion_order.erase(semantic_key)
		return false
	var produces: Array[String] = CapabilityDAGScript.produces_for(tool_name)
	var stored_evidence: Dictionary = evidence.duplicate(true)
	var truncated: bool = false
	if stored_evidence.size() > INLINE_EVIDENCE_MAX_KEYS:
		stored_evidence = _head_of(stored_evidence, INLINE_EVIDENCE_MAX_KEYS)
		truncated = true
	var serialized: String = JSON.stringify(stored_evidence)
	if serialized.length() > INLINE_EVIDENCE_MAX_BYTES:
		stored_evidence = {}
		truncated = true
	_entries[semantic_key] = {
		"semantic_key": semantic_key,
		"tool_name": tool_name,
		"status_name": String(outcome.get("status_name", "")),
		"objective_proven": bool(outcome.get("objective_proven", false)),
		"evidence_ref": evidence_ref,
		"evidence_digest": String(outcome.get("evidence_digest", "")),
		"evidence": stored_evidence,
		"evidence_truncated": truncated and stored_evidence.is_empty(),
		"evidence_bytes": int(outcome.get("evidence_bytes", serialized.length())),
		"produces": produces,
		"lifecycle": LIFECYCLE_NAMES[Lifecycle.VALID],
		"recorded_at": Time.get_ticks_msec(),
		"reuse_count": 0
	}
	_touch(semantic_key)
	prune(MAX_ENTRIES)
	return true


## 只保留前 limit 个键（字典顺序即插入顺序），用于防止单条收据撑爆内存。
static func _head_of(source: Dictionary, limit: int) -> Dictionary:
	var result: Dictionary = {}
	var kept: int = 0
	for key_value in source.keys():
		if kept >= limit:
			break
		result[key_value] = source[key_value]
		kept += 1
	return result


## 查询一条收据。返回统一的判定结果：
## {found, status, tool_name, outcome, evidence_ref, reuse_count}
## status 取值来自 LIFECYCLE_NAMES，未命中时 status = "stale"。
func lookup(semantic_key: String) -> Dictionary:
	if not _entries.has(semantic_key):
		_misses += 1
		return {"found": false, "status": LIFECYCLE_NAMES[Lifecycle.STALE], "tool_name": ""}
	var entry: Dictionary = _entries[semantic_key]
	var lifecycle: String = String(entry.get("lifecycle", LIFECYCLE_NAMES[Lifecycle.VALID]))
	if lifecycle != LIFECYCLE_NAMES[Lifecycle.VALID]:
		_misses += 1
		return {
			"found": true,
			"status": lifecycle,
			"tool_name": String(entry.get("tool_name", "")),
			"reuse_count": int(entry.get("reuse_count", 0))
		}
	_hits += 1
	_reuses += 1
	entry["reuse_count"] = int(entry.get("reuse_count", 0)) + 1
	entry["last_used_at"] = Time.get_ticks_msec()
	_touch(semantic_key)
	return {
		"found": true,
		"status": LIFECYCLE_NAMES[Lifecycle.VALID],
		"tool_name": String(entry.get("tool_name", "")),
		"status_name": String(entry.get("status_name", "")),
		"objective_proven": bool(entry.get("objective_proven", false)),
		"evidence_ref": String(entry.get("evidence_ref", "")),
		"evidence_digest": String(entry.get("evidence_digest", "")),
		"evidence": (entry.get("evidence", {}) as Dictionary).duplicate(true),
		"evidence_truncated": bool(entry.get("evidence_truncated", false)),
		"evidence_bytes": int(entry.get("evidence_bytes", 0)),
		"key": semantic_key,
		"reuse_count": int(entry.get("reuse_count", 0)),
		"reusable": true
	}


## 按「事实」失效。produces 与传入事实相交的收据会被标记为 invalid。
## 这是 #8 要求的定向失效：场景变化不该动 export template 收据。
func invalidate_facts(facts: Array) -> int:
	var invalidated: int = 0
	var wanted: Dictionary = {}
	for fact_value in facts:
		wanted[String(fact_value)] = true
	if wanted.is_empty():
		return 0
	for key_value in _entries.keys():
		var entry: Dictionary = _entries[key_value]
		var produces: Array = entry.get("produces", [])
		for produced_value in produces:
			if wanted.has(String(produced_value)):
				entry["lifecycle"] = LIFECYCLE_NAMES[Lifecycle.INVALID]
				invalidated += 1
				break
	if invalidated > 0:
		_invalidations += invalidated
	return invalidated


## 某个工具执行后，按它 invalidate 的事实作废相关收据。
func invalidate_for_tool(tool_name: String) -> int:
	var facts: Array[String] = CapabilityDAGScript.invalidates_for(tool_name)
	if facts.is_empty():
		return 0
	# 工具自身产生的收据也应失效（重新执行后结果可能不同）
	facts.append_array(CapabilityDAGScript.produces_for(tool_name))
	return invalidate_facts(facts)


## 校验一批收据的依赖修订是否仍然成立；不成立的标记为 stale。
## revisions_provider: Callable(semantic_key) -> Dictionary
func revalidate(revision_snapshots: Dictionary) -> int:
	var marked: int = 0
	for key_value in revision_snapshots:
		var key: String = String(key_value)
		if not _entries.has(key):
			continue
		var entry: Dictionary = _entries[key]
		if String(entry.get("lifecycle", "")) != LIFECYCLE_NAMES[Lifecycle.VALID]:
			continue
		entry["lifecycle"] = LIFECYCLE_NAMES[Lifecycle.STALE]
		marked += 1
	if marked > 0:
		_invalidations += marked
	return marked


## 丢弃所有非 VALID 条目，回收内存
func purge_invalid() -> int:
	var removed: int = 0
	var stale_keys: Array[String] = []
	for key_value in _entries:
		var key: String = String(key_value)
		if String((_entries[key] as Dictionary).get("lifecycle", "")) != LIFECYCLE_NAMES[Lifecycle.VALID]:
			stale_keys.append(key)
	for key in stale_keys:
		_entries.erase(key)
		_insertion_order.erase(key)
		removed += 1
	return removed


## LRU 裁剪
func prune(max_entries: int) -> int:
	var limit: int = maxi(0, max_entries)
	var evicted: int = 0
	while _insertion_order.size() > limit:
		var oldest: String = _insertion_order[0]
		_insertion_order.remove_at(0)
		_entries.erase(oldest)
		evicted += 1
		_evictions += 1
	return evicted


func clear() -> void:
	_entries.clear()
	_insertion_order.clear()


func size() -> int:
	return _entries.size()


func stats() -> Dictionary:
	var by_lifecycle: Dictionary = {}
	for name in LIFECYCLE_NAMES:
		by_lifecycle[name] = 0
	for key_value in _entries:
		var lifecycle: String = String((_entries[key_value] as Dictionary).get("lifecycle", ""))
		if by_lifecycle.has(lifecycle):
			by_lifecycle[lifecycle] = int(by_lifecycle[lifecycle]) + 1
	return {
		"entries": _entries.size(),
		"by_lifecycle": by_lifecycle,
		"hits": _hits,
		"misses": _misses,
		"reuses": _reuses,
		"invalidations": _invalidations,
		"evictions": _evictions
	}


func reset_diagnostics() -> void:
	_hits = 0
	_misses = 0
	_invalidations = 0
	_evictions = 0
	_reuses = 0


# ---------------------------------------------------------------------------
# 内部实现
# ---------------------------------------------------------------------------

func _touch(semantic_key: String) -> void:
	_insertion_order.erase(semantic_key)
	_insertion_order.append(semantic_key)


static func _canonical_revisions(value: Variant) -> Dictionary:
	if not (value is Dictionary):
		return {}
	var data: Dictionary = value
	var result: Dictionary = {}
	var keys: Array = data.keys()
	keys.sort()
	for key_value in keys:
		result[String(key_value)] = int(data[key_value])
	return result
