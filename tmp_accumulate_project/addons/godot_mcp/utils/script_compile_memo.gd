# script_compile_memo.gd
# 按路径记忆单文件 GDScript 编译诊断结果。
#
# verify_scripts / detect_broken_scripts 等全项目扫描在每次调用时对每个
# .gd 做一次真实 GDScript.reload() 编译（主线程）。结果缓存在工具级去重
# 了重复调用，但依赖标签失效后的首轮仍要全量重编——本 memo 按
# (路径, mtime+长度, 环境签名) 记忆单文件结果，标签推进后只有真正变化的
# 文件需要重编译。
#
# 失效语义：
# - mtime 或文件长度变化（磁盘真相）→ 重算。长度弥补文件系统时间戳
#   粒度：同一秒内"改写后长度不同"的内容变化也能被识别。
# - autoload / 全局脚本类注册表变化 → 重算（编译结果依赖它们：
#   autoload 感知重试、class_name 引用解析）。autoload 增删另由工具侧
#   整体 clear()（add/remove_project_autoload、install/remove_runtime_
#   probe）——全清比在签名里精确追踪更简单，autoload 非高频操作。
# - include_warnings / check_warnings 等变体 → 独立条目
# - 残余窗口（已知且接受）：外部编辑器同一秒内的**等长**改写使
#   mtime+长度都不变，memo 会继续供出旧结论直到该文件下次磁盘变化。
#   MCP 自身写路径（create_script/modify_script）已显式失效不受影响；
#   这是 mtime+长度方案的固有边界（与 make/编译器的时间戳判定一致）。

class_name ScriptCompileMemo
extends RefCounted

const MAX_ENTRIES: int = 1024
const EVICT_QUARTER: int = MAX_ENTRIES / 4

static var _entries: Dictionary = {}


## 返回 path 的编译诊断；无有效条目时调用 compute 计算并记忆。
## mtime 不可得（文件不存在等）时不记忆，直接计算。
static func diagnostics_for(path: String, variant: String, compute: Callable) -> Dictionary:
	var result: Variant = result_for(path, "compile|" + variant, compute)
	return result if result is Dictionary else {}


## 通用文件级结果记忆：与编译诊断同一套失效语义（mtime+长度、环境签名、
## 有界 FIFO），供依赖解析等"每文件一次昂贵解析"的场景复用。
## 环境签名对依赖解析同样成立——ResourceUID 解析依赖全局注册表。
static func result_for(path: String, domain: String, compute: Callable) -> Variant:
	var signature: String = file_signature(path)
	if signature.is_empty():
		return compute.call()
	var key: String = "%s|%s|%s|%s" % [path, signature, _environment_signature(), domain]
	if _entries.has(key):
		return _entries[key]
	var result: Variant = compute.call()
	if result == null:
		return null
	if result is Dictionary and (result as Dictionary).is_empty():
		return result
	if result is Array and (result as Array).is_empty():
		return result
	if _entries.size() >= MAX_ENTRIES:
		_evict_oldest()
	_entries[key] = result
	return result


## 写侧失效：插件自身改写脚本后调用（modify_script/create_script/...）。
## mtime 只有秒级精度，同秒内的等长改写（== ↔ !=、等长重命名）会让
## memo 供出改写前的结论且无 TTL 上界——修复循环里这是热路径。
## 外部编辑器改写仍靠 mtime+长度兜底。
static func invalidate(path: String) -> void:
	var prefix: String = path + "|"
	for key_value in _entries.keys():
		if String(key_value).begins_with(prefix):
			_entries.erase(key_value)


static func clear() -> void:
	_entries.clear()


static func entry_count() -> int:
	return _entries.size()


## "mtime:length" 磁盘签名；打开失败/不可得返回空串（跳过记忆）。
## get_length() 不读内容，开销远低于全文件读取 + 编译。
static func file_signature(path: String) -> String:
	var mtime: int = FileAccess.get_modified_time(path)
	if mtime <= 0:
		return ""
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		return ""
	var length: int = file.get_length()
	file.close()
	return "%d:%d" % [mtime, length]


## 编译环境签名：autoload 表 + 引擎全局脚本类缓存。任一变化都应让所有
## 记忆失效（例如新增 autoload 后，引用它的脚本从失败翻转为通过）。
static func _environment_signature() -> String:
	var autoloads: Dictionary = {}
	if ProjectSettings.has_setting("autoload"):
		var autoload_value: Variant = ProjectSettings.get_setting("autoload")
		if autoload_value is Dictionary:
			autoloads = autoload_value
	var global_classes: Dictionary = {}
	if ProjectSettings.has_setting("_global_script_class_cache"):
		var classes_value: Variant = ProjectSettings.get_setting("_global_script_class_cache")
		if classes_value is Dictionary:
			global_classes = classes_value
	return "%d:%d" % [autoloads.hash(), global_classes.hash()]


## Dictionary 按插入序遍历：最旧条目（同一文件的陈旧签名变体）优先淘汰。
static func _evict_oldest() -> void:
	var removed: int = 0
	for key_value in _entries.keys():
		if removed >= EVICT_QUARTER:
			break
		_entries.erase(key_value)
		removed += 1
