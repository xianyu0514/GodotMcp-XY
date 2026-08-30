# file_mutation_bus.gd — 文件变更广播总线
#
# 背景：一次真实事故中，测试 fixture 被删除后，verify_scripts 仍然尝试验证
# coverage_2d_temp.gd / system_proxy_probe.gd / template_http_replacement.gd
# 这些已经不存在的文件；直到手工调用 reload_project(full_scan=true) 才恢复。
#
# 根因是缓存失效没有统一入口：EditorFileSystem 缓存、脚本缓存、资源缓存、
# 工作流依赖修订、覆盖追踪各自为政，于是出现"一份缓存已删除、另一份仍认为存在"。
#
# 本模块提供单一广播点：任何 delete / rename / move / 外部编辑 / reimport
# 都发布一次事件，所有订阅者在同一批次里完成失效。

class_name MCPFileMutationBus
extends RefCounted

## 变更事件类型
enum Event {
	FILE_CREATED,
	FILE_MODIFIED,
	FILE_DELETED,
	FILE_MOVED,
	RESOURCE_REIMPORTED
}

const EVENT_NAMES: Array[String] = [
	"file_created", "file_modified", "file_deleted",
	"file_moved", "resource_reimported"
]

const CapabilityDAGScript = preload("res://addons/godot_mcp/native_mcp/capability_dag.gd")

## 事件 -> 受影响的能力事实。订阅者据此做定向失效，而不是全量清缓存。
const FACT_IMPACT: Dictionary = {
	"file_created": [
		CapabilityDAGScript.FACT_SCENE_EXISTS,
		CapabilityDAGScript.FACT_SCRIPT_EXISTS,
		CapabilityDAGScript.FACT_TILESET_EXISTS,
		CapabilityDAGScript.FACT_THEME_EXISTS
	],
	"file_modified": [
		CapabilityDAGScript.FACT_SCENE_SAVED,
		CapabilityDAGScript.FACT_SCRIPT_EXISTS
	],
	"file_deleted": [
		CapabilityDAGScript.FACT_SCENE_EXISTS,
		CapabilityDAGScript.FACT_SCENE_SAVED,
		CapabilityDAGScript.FACT_SCRIPT_EXISTS,
		CapabilityDAGScript.FACT_SCRIPT_ATTACHED,
		CapabilityDAGScript.FACT_TILESET_EXISTS,
		CapabilityDAGScript.FACT_THEME_EXISTS,
		CapabilityDAGScript.FACT_EXPORTED_ARTIFACT
	],
	"file_moved": [
		CapabilityDAGScript.FACT_SCENE_EXISTS,
		CapabilityDAGScript.FACT_SCRIPT_EXISTS,
		CapabilityDAGScript.FACT_SCRIPT_ATTACHED
	],
	"resource_reimported": [
		CapabilityDAGScript.FACT_SCENE_EXISTS,
		CapabilityDAGScript.FACT_TILESET_EXISTS
	]
}

## 文件扩展名 -> 语义域。用于把一次删除精确映射成"脚本缓存失效"还是
## "场景缓存失效"，避免无差别全量失效拖慢大项目。
const EXTENSION_DOMAIN: Dictionary = {
	"gd": "script",
	"cs": "script",
	"tscn": "scene",
	"scn": "scene",
	"tres": "resource",
	"res": "resource",
	"gdshader": "shader",
	"material": "resource",
	"import": "import"
}

var _subscribers: Dictionary = {}
var _subscriber_order: Array[String] = []
var _pending: Array[Dictionary] = []
var _published_events: int = 0
var _flushed_batches: int = 0
var _failed_subscribers: int = 0


# ---------------------------------------------------------------------------
# 订阅
# ---------------------------------------------------------------------------

## 注册订阅者。callback 签名：func(batch: Dictionary) -> void
## 同名的重复注册会被覆盖（幂等），避免插件重载后重复收到事件。
func subscribe(subscriber_name: String, callback: Callable) -> bool:
	var name: String = subscriber_name.strip_edges()
	if name.is_empty() or not callback.is_valid():
		return false
	if not _subscribers.has(name):
		_subscriber_order.append(name)
	_subscribers[name] = callback
	return true


func unsubscribe(subscriber_name: String) -> bool:
	var name: String = subscriber_name.strip_edges()
	if not _subscribers.has(name):
		return false
	_subscribers.erase(name)
	_subscriber_order.erase(name)
	return true


func subscriber_names() -> Array[String]:
	var result: Array[String] = []
	for name in _subscriber_order:
		result.append(name)
	return result


# ---------------------------------------------------------------------------
# 发布
# ---------------------------------------------------------------------------

## 发布一次变更。事件会被合并到当前批次，在 flush() 时统一投递。
##
## metadata 常用字段：{"old_path": ..., "external": bool, "tool_name": ...}
func publish(event: int, path: String, metadata: Dictionary = {}) -> Dictionary:
	var event_name: String = event_name(event)
	var record: Dictionary = {
		"event": event_name,
		"path": _normalized_path(path),
		"domain": domain_for_path(path),
		"metadata": metadata.duplicate(true),
		"at": Time.get_ticks_msec()
	}
	_pending.append(record)
	_published_events += 1
	return record


func publish_created(path: String, metadata: Dictionary = {}) -> Dictionary:
	return publish(Event.FILE_CREATED, path, metadata)


func publish_modified(path: String, metadata: Dictionary = {}) -> Dictionary:
	return publish(Event.FILE_MODIFIED, path, metadata)


func publish_deleted(path: String, metadata: Dictionary = {}) -> Dictionary:
	return publish(Event.FILE_DELETED, path, metadata)


func publish_moved(from_path: String, to_path: String, metadata: Dictionary = {}) -> Dictionary:
	var merged: Dictionary = metadata.duplicate(true)
	merged["old_path"] = _normalized_path(from_path)
	return publish(Event.FILE_MOVED, to_path, merged)


func publish_reimported(path: String, metadata: Dictionary = {}) -> Dictionary:
	return publish(Event.RESOURCE_REIMPORTED, path, metadata)


## 待投递事件数
func pending_count() -> int:
	return _pending.size()


# ---------------------------------------------------------------------------
# 投递
# ---------------------------------------------------------------------------

## 把合并后的批次投递给所有订阅者。
##
## 单个订阅者抛错不会中断广播（它会被记入 failed 列表），因为一个缓存失效失败
## 不应该阻止其他缓存保持一致。
##
## 返回：
## {
##   delivered: bool, events: int, paths: Array[String],
##   facts_invalidated: Array[String], delivered_to: Array[String],
##   failed: Array[String]
## }
func flush() -> Dictionary:
	var batch: Dictionary = _build_batch()
	if int(batch.get("events", 0)) == 0:
		return batch
	_flushed_batches += 1
	var delivered_to: Array[String] = []
	var failed: Array[String] = []
	for name in _subscriber_order:
		var callback: Callable = _subscribers[name]
		var error: int = callback.call(batch)
		# 订阅者返回 int 错误码（OK=0）或不返回；非 0 视为失败
		if error is int and int(error) != OK:
			failed.append(name)
			_failed_subscribers += 1
		else:
			delivered_to.append(name)
	batch["delivered_to"] = delivered_to
	batch["failed"] = failed
	return batch


## 清空待投递队列而不投递（用于测试与插件重载）
func discard_pending() -> int:
	var count: int = _pending.size()
	_pending.clear()
	return count


func stats() -> Dictionary:
	return {
		"pending": _pending.size(),
		"subscribers": _subscriber_order.size(),
		"published_events": _published_events,
		"flushed_batches": _flushed_batches,
		"failed_subscribers": _failed_subscribers
	}


# ---------------------------------------------------------------------------
# 映射工具（静态）
# ---------------------------------------------------------------------------

static func event_name(event: int) -> String:
	if event >= 0 and event < EVENT_NAMES.size():
		return EVENT_NAMES[event]
	return ""


static func event_from_name(name: String) -> int:
	return EVENT_NAMES.find(name.strip_edges().to_lower())


## 该事件会让哪些能力事实失效
static func facts_for_event(event_name_value: String) -> Array[String]:
	var result: Array[String] = []
	var impact: Variant = FACT_IMPACT.get(event_name_value, [])
	if not (impact is Array):
		return result
	for fact_value in (impact as Array):
		result.append(String(fact_value))
	return result


static func domain_for_path(path: String) -> String:
	var normalized: String = _normalized_path(path)
	var extension: String = normalized.get_extension().to_lower()
	if extension.is_empty():
		return "directory"
	return String(EXTENSION_DOMAIN.get(extension, "file"))


# ---------------------------------------------------------------------------
# 内部实现
# ---------------------------------------------------------------------------

func _build_batch() -> Dictionary:
	var events: Array[Dictionary] = _pending
	_pending = []
	if events.is_empty():
		return {
			"delivered": false, "events": 0, "paths": [],
			"facts_invalidated": [], "domains": [], "deleted_paths": [],
			"delivered_to": [], "failed": []
		}
	var paths: Array[String] = []
	var deleted_paths: Array[String] = []
	var domains: Dictionary = {}
	var facts: Dictionary = {}
	for record_value in events:
		var record: Dictionary = record_value
		var path: String = String(record.get("path", ""))
		if not path.is_empty() and not path in paths:
			paths.append(path)
		if String(record.get("event", "")) == EVENT_NAMES[Event.FILE_DELETED] \
				and not path in deleted_paths:
			deleted_paths.append(path)
		var domain: String = String(record.get("domain", ""))
		if not domain.is_empty():
			domains[domain] = true
		for fact_value in facts_for_event(String(record.get("event", ""))):
			facts[String(fact_value)] = true
	var sorted_paths: Array[String] = paths
	sorted_paths.sort()
	var sorted_deleted: Array[String] = deleted_paths
	sorted_deleted.sort()
	var sorted_facts: Array[String] = []
	for fact_value in facts:
		sorted_facts.append(String(fact_value))
	sorted_facts.sort()
	var sorted_domains: Array[String] = []
	for domain_value in domains:
		sorted_domains.append(String(domain_value))
	sorted_domains.sort()
	return {
		"delivered": true,
		"events": events.size(),
		"records": events,
		"paths": sorted_paths,
		"deleted_paths": sorted_deleted,
		"domains": sorted_domains,
		"facts_invalidated": sorted_facts,
		"delivered_to": [],
		"failed": []
	}


static func _normalized_path(path_value: Variant) -> String:
	var normalized: String = str(path_value).strip_edges().replace("\\", "/")
	if normalized.begins_with("res:/") and not normalized.begins_with("res://"):
		normalized = "res://" + normalized.substr(5)
	while normalized.contains("//") and not normalized.begins_with("res://"):
		normalized = normalized.replace("//", "/")
	return normalized
