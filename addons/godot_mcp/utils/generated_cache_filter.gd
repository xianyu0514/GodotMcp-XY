# generated_cache_filter.gd — 生成物 / 缓存路径分类
#
# 背景：把 res:// 全量扫描的结果直接当"项目健康度"，会扫进 .godot/ 里的
# 导入产物、.mcp/ 里的工作流证据与缓存、以及 .import/.uid 伴随文件。这些
# 东西缺失或损坏是"可以重建"的，跟"源码资产坏了"完全不是一个严重级别。
# 混在一起报，结果就是真正的源码依赖缺失被淹没在几百条噪音里。
#
# 分类：
#   SOURCE        — 源码 / 手工艺资产，坏了就是真坏了
#   GENERATED     — 可由引擎重建（.godot 导入缓存、.import 伴随文件）
#   MCP_RUNTIME   — 本插件运行期产物（证据、缓存、fixture、checkpoint）
#   TOOLING       — 第三方插件 / 测试脚手架（addons/**）
#   UNKNOWN       — 无法判定，按 SOURCE 处理（fail-safe）

class_name MCPGeneratedCacheFilter
extends RefCounted

enum Domain {
	SOURCE,
	GENERATED,
	MCP_RUNTIME,
	TOOLING,
	UNKNOWN
}

const DOMAIN_NAMES: Array[String] = ["source", "generated", "mcp_runtime", "tooling", "unknown"]

## 生成物目录（含前导点，位于项目任意层级）
const GENERATED_DIR_NAMES: Array[String] = [
	".godot", ".import", ".git", ".svn", ".hg", ".vs", ".idea", ".vscode",
	"__pycache__", ".pytest_cache", "node_modules", "build", "dist", ".build"
]

## 本插件运行期目录
const MCP_RUNTIME_DIR: String = ".mcp"

## 第三方 / 脚手架目录
const TOOLING_DIRS: Array[String] = ["addons", "test", "tests", "docs"]

## 生成物伴随文件后缀（源文件仍在，只是缓存描述丢了）
const GENERATED_FILE_SUFFIXES: Array[String] = [".import", ".uid"]

## 明显是缓存/临时文件的扩展名
const GENERATED_FILE_EXTENSIONS: Array[String] = [
	"tmp", "temp", "bak", "log", "pyc", "orig", "rej", "swp"
]

const PathNormalizerScript = preload("res://addons/godot_mcp/utils/path_normalizer.gd")


# ---------------------------------------------------------------------------
# 分类
# ---------------------------------------------------------------------------

static func domain_of(path: String) -> int:
	var normalized: String = PathNormalizerScript.canonical_file(path.strip_edges())
	if normalized.is_empty():
		return Domain.UNKNOWN
	var body: String = normalized
	for prefix in ["res://", "user://"]:
		if body.begins_with(prefix):
			body = body.substr(prefix.length())
			break

	var segments: PackedStringArray = body.split("/", false)
	if segments.is_empty():
		return Domain.UNKNOWN

	# 顶层即插件运行期目录
	if String(segments[0]).to_lower() == MCP_RUNTIME_DIR:
		return Domain.MCP_RUNTIME

	# 任意一层落在生成物目录名下即为生成物。目录路径由调用方在末尾补 "/"，
	# 规范化会去掉它，因此这里拿到的段序列与文件路径一致；同名文件（无扩展名）
	# 被误判成生成物的代价远低于把 .godot 缓存扫进健康审计。
	for index in segments.size():
		var segment: String = String(segments[index]).to_lower()
		if segment in GENERATED_DIR_NAMES:
			return Domain.GENERATED

	var last: String = String(segments[segments.size() - 1])
	var lower_last: String = last.to_lower()
	for suffix in GENERATED_FILE_SUFFIXES:
		if lower_last.ends_with(suffix):
			return Domain.GENERATED
	var extension: String = last.get_extension().to_lower()
	if not extension.is_empty() and extension in GENERATED_FILE_EXTENSIONS:
		return Domain.GENERATED

	var first: String = String(segments[0]).to_lower()
	if first in TOOLING_DIRS and segments.size() > 1:
		return Domain.TOOLING
	if first in TOOLING_DIRS and segments.size() == 1:
		return Domain.TOOLING

	return Domain.SOURCE


static func domain_name(path: String) -> String:
	return DOMAIN_NAMES[domain_of(path)]


static func is_generated(path: String) -> bool:
	return domain_of(path) == Domain.GENERATED


static func is_mcp_runtime(path: String) -> bool:
	return domain_of(path) == Domain.MCP_RUNTIME


## 健康度审计里"算不算源码资产"。fail-safe：无法判定时算源码。
static func is_source_asset(path: String) -> bool:
	var domain: int = domain_of(path)
	return domain == Domain.SOURCE or domain == Domain.UNKNOWN


# ---------------------------------------------------------------------------
# 过滤
# ---------------------------------------------------------------------------

## 默认过滤掉生成物与插件运行期产物。include_generated=true 时只保留全部。
## 返回 {"kept": Array[String], "filtered": Array[Dictionary], "counts": Dictionary}
static func partition(paths: Array, include_generated: bool = false,
		include_tooling: bool = true) -> Dictionary:
	var kept: Array[String] = []
	var filtered: Array[Dictionary] = []
	var counts: Dictionary = {}
	for domain in DOMAIN_NAMES:
		counts[domain] = 0
	for value in paths:
		var path: String = String(value)
		var domain: int = domain_of(path)
		var name: String = DOMAIN_NAMES[domain]
		counts[name] = int(counts[name]) + 1
		var drop: bool = false
		if domain == Domain.GENERATED and not include_generated:
			drop = true
		elif domain == Domain.MCP_RUNTIME:
			drop = true
		elif domain == Domain.TOOLING and not include_tooling:
			drop = true
		if drop:
			filtered.append({"path": path, "domain": name})
		else:
			kept.append(path)
	return {"kept": kept, "filtered": filtered, "counts": counts}


static func filter_paths(paths: Array, include_generated: bool = false,
		include_tooling: bool = true) -> Array[String]:
	return partition(paths, include_generated, include_tooling)["kept"]


## 把一批检查结果按域拆成四份，供审计输出分桶。
## entries 里每项需要有 "path" 字段（缺失归到 source，fail-safe）。
static func split_findings(entries: Array) -> Dictionary:
	var buckets: Dictionary = {
		"source": [],
		"generated": [],
		"mcp_runtime": [],
		"tooling": [],
		"unknown": []
	}
	for value in entries:
		var entry: Dictionary = value if value is Dictionary else {"value": value}
		var raw_path: Variant = entry.get("path", entry.get("file", entry.get("resource", "")))
		var domain: int = domain_of(String(raw_path))
		var name: String = DOMAIN_NAMES[domain]
		(buckets[name] as Array).append(entry)
	return buckets
