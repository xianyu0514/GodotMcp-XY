# path_normalizer.gd — 路径规范化与目录/文件判定
#
# 背景：同一个目录在不同工具里会写成 "res://test"、"res://test/"、"res://test//",
# 甚至 "res://test\\sub"。结果就是：
#   * 缓存键各写各的，同一份结果被存成 N 份；
#   * scan_missing_resource_dependencies 传入带斜杠和不带斜杠得到不同的扫描结果；
#   * 路径比较用 == 判断，明明是同一个目录却被当成两个。
#
# 这里把"路径怎么变成唯一标准形"收敛到一个地方，所有工具都调用它。
#
# 核心约定（Canonical Form）：
#   1. 前缀一律保留 res:// / user://，其余前缀原样返回（由调用方校验）
#   2. 反斜杠转成正斜杠
#   3. 折叠重复的 /
#   4. 去掉 "." 段；".." 段按 POSIX 语义上溯（越界则判为非法，不静默吞掉）
#   5. **目录路径以 "/" 结尾，文件路径不以 "/" 结尾**
#      无法从字符串判断时（无扩展名且未指明），由调用方显式选 canonical_dir
#      或 canonical_file，绝不猜。
#   6. 去掉首尾空白

class_name MCPPathNormalizer
extends RefCounted

const ALLOWED_PREFIXES: Array[String] = ["res://", "user://"]

## 目录型扩展名：这些扩展名在 Godot 里是"目录"（如 .godot 缓存根）
const DIRECTORY_EXTENSIONS: Array[String] = ["godot"]


# ---------------------------------------------------------------------------
# 规范化
# ---------------------------------------------------------------------------

## 推断式规范化：有扩展名视为文件，无扩展名视为目录。
## 需要确定语义时请直接用 canonical_file / canonical_dir，不要依赖推断。
static func canonical(path: String) -> String:
	return canonical_dir(path) if looks_like_directory(path) else canonical_file(path)


## 规范化为文件路径（末尾一定没有 "/"）。
static func canonical_file(path: String) -> String:
	return _finish(path, false)


## 规范化为目录路径（末尾一定有 "/"，根目录除外即 "res://" 本身）。
static func canonical_dir(path: String) -> String:
	return _finish(path, true)


## 从字符串形态判断是否像目录：没有扩展名、或原本就带了尾部斜杠。
## 这只是启发式；真正决定用的是 canonical_file / canonical_dir 的显式调用。
static func looks_like_directory(path: String) -> bool:
	var trimmed: String = path.strip_edges()
	if trimmed.ends_with("/"):
		return true
	var file_name: String = trimmed.get_file()
	if file_name.is_empty():
		return true
	return file_name.get_extension().is_empty() or _is_directory_extension(file_name)


static func _is_directory_extension(file_name: String) -> bool:
	var extension: String = file_name.get_extension().to_lower()
	return extension in DIRECTORY_EXTENSIONS


static func _finish(path: String, as_directory: bool) -> String:
	var raw: String = path.strip_edges()
	if raw.is_empty():
		return ""
	var prefix: String = ""
	var body: String = raw
	for candidate in ALLOWED_PREFIXES:
		if raw.begins_with(candidate):
			prefix = candidate
			body = raw.substr(candidate.length())
			break
	if prefix.is_empty():
		# 非 Godot 路径：仅做字符级规范化，不猜前缀。
		return _clean_body(body, as_directory, "")

	body = body.replace("\\", "/")
	var segments: Array[String] = []
	for part in body.split("/", false):
		if part == ".":
			continue
		if part == "..":
			# 越界的 ".." 不能静默丢弃：那意味着调用方想逃出项目根目录。
			if segments.is_empty():
				return ""
			segments.remove_at(segments.size() - 1)
			continue
		segments.append(part)
	var joined: String = "/".join(PackedStringArray(segments))
	if joined.is_empty():
		return prefix
	if as_directory:
		return prefix + joined + "/"
	return prefix + joined


static func _clean_body(body: String, as_directory: bool, prefix: String) -> String:
	var cleaned: String = body.replace("\\", "/")
	var segments: Array[String] = []
	for part in cleaned.split("/", false):
		if part == ".":
			continue
		if part == "..":
			if segments.is_empty():
				return ""
			segments.remove_at(segments.size() - 1)
			continue
		segments.append(part)
	var joined: String = "/".join(PackedStringArray(segments))
	if joined.is_empty():
		return prefix if not prefix.is_empty() else "/"
	if prefix.is_empty() and cleaned.begins_with("/"):
		joined = "/" + joined
	if as_directory:
		return prefix + joined + "/"
	return prefix + joined


# ---------------------------------------------------------------------------
# 比较
# ---------------------------------------------------------------------------

## 两个路径是否指向同一个东西（忽略书写差异）。
## 文件和目录不相等：res://a/b 与 res://a/b/ 在 Godot 语义下是同一个 b，
## 但当 b 是文件时 "res://a/b/" 并不存在，所以这里按规范化后的字符串比较：
## canonical_file("res://a/b/") == "res://a/b" —— 视为相等。
static func equivalent(left: String, right: String) -> bool:
	var a: String = canonical(left)
	var b: String = canonical(right)
	if a.is_empty() or b.is_empty():
		return false
	if a == b:
		return true
	# 只有尾部斜杠差异时也算相等（都是目录语义）
	return canonical_dir(left) == canonical_dir(right) \
		and looks_like_directory(left) and looks_like_directory(right)


## 用于缓存键 / 去重的稳定键。Windows 与 macOS 默认文件系统大小写不敏感，
## 因此默认折叠大小写；Linux 上折叠也只会让键更保守（多失效而非误命中）。
static func key(path: String) -> String:
	return canonical(path).to_lower()


## 父目录（一定是目录形）。自身就是根时返回自身。
static func parent(path: String) -> String:
	var as_file: String = canonical_file(path)
	if as_file.is_empty():
		return ""
	var prefix: String = ""
	for candidate in ALLOWED_PREFIXES:
		if as_file.begins_with(candidate):
			prefix = candidate
			break
	var body: String = as_file.substr(prefix.length())
	var index: int = body.rfind("/")
	if index < 0:
		return prefix
	return prefix + body.substr(0, index + 1)


## 相对项目根的显示名（去掉前缀与尾部斜杠）
static func display(path: String) -> String:
	var value: String = canonical_file(path)
	for candidate in ALLOWED_PREFIXES:
		if value.begins_with(candidate):
			return value.substr(candidate.length())
	return value


## 批量规范化，返回一一对应的数组
static func canonical_all(paths: Array) -> Array[String]:
	var result: Array[String] = []
	for value in paths:
		result.append(canonical(String(value)))
	return result


## 去重：把一堆写法各异的路径收敛成唯一集合
static func deduplicate(paths: Array) -> Array[String]:
	var seen: Dictionary = {}
	var result: Array[String] = []
	for value in paths:
		var k: String = key(String(value))
		if seen.has(k):
			continue
		seen[k] = true
		result.append(canonical(String(value)))
	return result


## 判断 child 是否位于 parent 之下（含自身）
static func is_under(child_path: String, parent_path: String) -> bool:
	var child: String = canonical(child_path)
	var parent: String = canonical_dir(parent_path)
	if child.is_empty() or parent.is_empty():
		return false
	if child == parent:
		return true
	return child.begins_with(parent) or canonical_dir(child) == parent
