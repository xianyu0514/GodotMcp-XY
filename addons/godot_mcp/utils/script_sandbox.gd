# script_sandbox.gd
# Capability denylist guard for AI-driven script execution.
# 给 AI 驱动的脚本执行加可配置的能力面护栏：扫描 execute_editor_script /
# evaluate_* 的源码或表达式，命中危险能力（OS 进程 / 文件越界 / 网络 / 危险 API）
# 时返回 blocked。判定是纯函数、确定性、可单测。
#
# 这是"防误操作"的护栏，不是对抗性安全沙箱：静态扫描可被反射/拼接绕过，
# 不试图做完备隔离。真正强隔离需引擎级支持。

@tool
class_name MCPScriptSandbox
extends RefCounted

const REASON: String = "script_sandbox"

# ---------------------------------------------------------------------------
# 能力面（capability）模型
#
# 纯文本黑名单的问题是"一刀切"：OS.execute 被无条件拦掉，但有些工作流确实
# 需要调用导出脚本、跑测试进程。于是使用者只能整体关掉护栏，反而更不安全。
#
# 能力面把判定从"这段代码含不含某个标识符"升级为"这段代码需要哪种能力、
# 调用方有没有被授予"。默认一个都不授予（等价于今天的严格行为），需要哪样
# 显式给哪样，其余照旧拦截。
# ---------------------------------------------------------------------------
enum Capability {
	READ_PROJECT,       # 读取 res:// 下资产
	WRITE_PROJECT,      # 写 res:// 下资产
	READ_USER,          # 读取 user:// 目录
	WRITE_USER,         # 写 user:// 目录
	NETWORK,            # 发起网络请求
	PROCESS,            # 派生外部进程
	MCP_SOURCE_WRITE    # 改动本插件自身源码（默认拒绝：AI 不该改自己的工具）
}

const CAPABILITY_NAMES: Array[String] = [
	"read_project", "write_project", "read_user", "write_user",
	"network", "process", "mcp_source_write"
]

## 每个类别需要的"最低能力"。值为空串表示该类别**永不授予**（真正危险的 API）。
const CATEGORY_CAPABILITY: Dictionary = {
	"os_process": "process",
	"network": "network",
	"filesystem": "write_project",
	"dangerous_api": ""
}

## 默认授予的能力：一个都不给。调用方按需显式放行。
const DEFAULT_GRANTED_CAPABILITIES: Array = []

## 插件自身源码与运行期目录：改写这些路径需要 mcp_source_write。
## 这里**默认拒绝**，因为让 Agent 修改自己的工具链会让后续所有判定失去基准。
const DEFAULT_PROTECTED_WRITE_PATHS: Array[String] = [
	"res://addons/godot_mcp", "res://.mcp"
]

## 受保护的读取路径默认留空：读取一般无副作用。需要保护密钥文件时由调用方传入。
const DEFAULT_PROTECTED_READ_PATHS: Array[String] = []

# Process-lifetime cache of compiled RegEx keyed by pattern string. The denylist
# is constant, so each pattern only needs to be compiled once instead of on every
# scan() call (a scan would otherwise compile ~26 identifier regexes per call).
# A failed compile is cached as null so we never retry it.
static var _regex_cache: Dictionary = {}

# 默认拒绝清单：按类别组织。键为类别名，值为"标识符"数组（按词边界匹配）。
const DEFAULT_DENYLIST: Dictionary = {
	"os_process": [
		"OS.execute",
		"OS.execute_with_pipe",
		"OS.create_process",
		"OS.create_instance",
		"OS.shell_open",
		"OS.shell_show_in_file_manager",
		"OS.kill",
		"OS.set_environment",
		"OS.set_restart_on_exit",
		"OS.crash",
		"OS.move_to_trash",
	],
	"network": [
		"HTTPClient",
		"HTTPRequest",
		"StreamPeerTCP",
		"StreamPeerTLS",
		"TCPServer",
		"PacketPeerUDP",
		"WebSocketPeer",
		"WebSocketMultiplayerPeer",
		"ENetConnection",
		"ENetMultiplayerPeer",
		"IP.resolve",
		"IP.resolve_hostname",
	],
	"dangerous_api": [
		"JavaScriptBridge",
		"JavaClassWrapper",
		"ClassDB.instantiate",
		"OS.set_thread_name",
	],
}

# dangerous_api 里需要"调用式"匹配的模式（带括号），单独用正则。
const DANGEROUS_CALL_PATTERNS: Dictionary = {
	"dangerous_api": [
		"\\.quit\\s*\\(",          # get_tree().quit() / SceneTree.quit()
	],
}

# 默认启用的全部类别。
const ALL_CATEGORIES: Array = ["os_process", "filesystem", "network", "dangerous_api"]


# 主入口：扫描代码/表达式，返回判定结果。
# config:
#   enabled: bool            是否启用护栏（默认 true）
#   categories: Array        启用的类别（默认 ALL_CATEGORIES）
#   extra_denylist: Array    追加的拦截标识符（不分类，命中归到 "custom"）
#   allowlist: Array         例外标识符（精确串，命中后从结果中豁免）
#   warn_only: bool          只告警不拦截（blocked 始终 false，warned 反映命中）
#   capabilities: Array      授予的能力名（默认空 = 一个都不给）
#   mode: String             "read" 或 "write"（默认 "write"），决定受保护路径的
#                            读取面还是写入面生效
#   protected_read_paths: Array  额外/覆盖的受保护读取路径（默认空）
#   protected_write_paths: Array 额外/覆盖的受保护写入路径（默认插件源码与 .mcp）
# 返回:
#   {blocked: bool, reason, category, token, error, warned: bool,
#    capability: String, required_capabilities: Array}
static func scan(code: String, config: Dictionary = {}) -> Dictionary:
	var ok: Dictionary = {
		"blocked": false, "reason": "", "category": "", "token": "", "error": "",
		"warned": false, "capability": "", "required_capabilities": []
	}

	if not bool(config.get("enabled", true)):
		return ok
	if code == null or String(code).strip_edges().is_empty():
		return ok

	var categories: Array = config.get("categories", ALL_CATEGORIES)
	var allowlist: Array = config.get("allowlist", [])
	var warn_only: bool = bool(config.get("warn_only", false))
	var granted: Array = config.get("capabilities", DEFAULT_GRANTED_CAPABILITIES)
	var mode: String = String(config.get("mode", "write")).strip_edges().to_lower()
	var is_write: bool = mode != "read"

	var required: Array[String] = []

	# 预处理：得到"剥离字符串与注释后的代码"（用于标识符匹配，避免字符串/注释误杀），
	# 以及"提取出的字符串字面量数组"（用于文件路径越界检查）。
	var stripped: Dictionary = _strip_strings_and_comments(String(code))
	var code_no_str: String = stripped["code"]
	var literals: Array = stripped["literals"]

	# 0) 受保护路径：写插件源码 / 读敏感文件，按 mode 分开判定。
	#    读和写是两件事，混用一个 protected_paths 会让"只读一下配置"也被拦。
	var protected_write: Array = config.get("protected_write_paths", DEFAULT_PROTECTED_WRITE_PATHS)
	var protected_read: Array = config.get("protected_read_paths", DEFAULT_PROTECTED_READ_PATHS)
	for literal_value in literals:
		var lit: String = String(literal_value)
		if lit.is_empty() or allowlist.has(lit):
			continue
		var hit_write: String = _under_protected(lit, protected_write)
		if is_write and not hit_write.is_empty():
			if granted.has(CAPABILITY_NAMES[Capability.MCP_SOURCE_WRITE]):
				continue
			required.append(CAPABILITY_NAMES[Capability.MCP_SOURCE_WRITE])
			return _hit("protected_write_path", hit_write, warn_only,
				CAPABILITY_NAMES[Capability.MCP_SOURCE_WRITE], required)
		var hit_read: String = _under_protected(lit, protected_read)
		if not hit_read.is_empty():
			required.append(CAPABILITY_NAMES[Capability.READ_USER])
			return _hit("protected_read_path", hit_read, warn_only,
				CAPABILITY_NAMES[Capability.READ_USER], required)

	# 1) 标识符类（os_process / network / dangerous_api）
	for category in DEFAULT_DENYLIST.keys():
		if not categories.has(category):
			continue
		var capability: String = String(CATEGORY_CAPABILITY.get(category, ""))
		# 空串 = 该类别永不授予，命中即拦。
		if not capability.is_empty() and granted.has(capability):
			continue
		for token in DEFAULT_DENYLIST[category]:
			if allowlist.has(token):
				continue
			if _matches_identifier(code_no_str, token):
				if not capability.is_empty():
					required.append(capability)
				return _hit(category, token, warn_only, capability, required)

	# 1b) 调用式危险模式
	for category in DANGEROUS_CALL_PATTERNS.keys():
		if not categories.has(category):
			continue
		var pattern_capability: String = String(CATEGORY_CAPABILITY.get(category, ""))
		if not pattern_capability.is_empty() and granted.has(pattern_capability):
			continue
		for pattern in DANGEROUS_CALL_PATTERNS[category]:
			if allowlist.has(pattern):
				continue
			if _matches_regex(code_no_str, pattern):
				return _hit(category, pattern, warn_only, pattern_capability, required)

	# 2) 自定义追加清单
	var extra: Array = config.get("extra_denylist", [])
	for token in extra:
		if allowlist.has(token):
			continue
		if _matches_identifier(code_no_str, String(token)):
			return _hit("custom", String(token), warn_only, "", required)

	# 3) 文件系统越界：检查字符串字面量是否命中危险路径
	if categories.has("filesystem") and not granted.has(CAPABILITY_NAMES[Capability.WRITE_PROJECT]):
		for literal in literals:
			var lit: String = String(literal)
			if allowlist.has(lit):
				continue
			var bad: String = _path_violation(lit)
			if not bad.is_empty():
				required.append(CAPABILITY_NAMES[Capability.WRITE_PROJECT])
				return _hit("filesystem", bad, warn_only,
					CAPABILITY_NAMES[Capability.WRITE_PROJECT], required)

	return ok


## 这段代码需要哪些能力（不改变任何状态，仅供诊断与授权提示）。
static func required_capabilities(code: String, config: Dictionary = {}) -> Array[String]:
	var probe: Dictionary = config.duplicate(true)
	probe["warn_only"] = true
	probe.erase("capabilities")
	# 逐个能力试探：授予它就不再被拦，说明被拦是因为缺这个能力。
	var needed: Array[String] = []
	var baseline: Dictionary = scan(code, probe)
	if not bool(baseline.get("warned", false)):
		return needed
	var capability: String = String(baseline.get("capability", ""))
	if not capability.is_empty():
		needed.append(capability)
		return needed
	for name in CAPABILITY_NAMES:
		var trial: Dictionary = probe.duplicate(true)
		trial["capabilities"] = [name]
		if not bool(scan(code, trial).get("warned", false)):
			needed.append(name)
	return needed


## 字面量是否落在受保护路径之下。返回命中的受保护前缀（空=未命中）。
static func _under_protected(literal: String, protected_paths: Array) -> String:
	if literal.is_empty():
		return ""
	var candidate: String = literal.strip_edges().replace("\\", "/")
	if not (candidate.begins_with("res://") or candidate.begins_with("user://")):
		return ""
	for path_value in protected_paths:
		var protected: String = String(path_value).strip_edges().replace("\\", "/")
		if protected.is_empty():
			continue
		if candidate == protected or candidate.begins_with(protected + "/"):
			return protected
	return ""


static func _hit(category: String, token: String, warn_only: bool,
		capability: String = "", required: Array = []) -> Dictionary:
	var message: String = "blocked by script sandbox: %s (%s)" % [category, token]
	if not capability.is_empty():
		message += " — requires capability '%s'" % capability
	if warn_only:
		return {
			"blocked": false, "reason": REASON, "category": category, "token": token,
			"error": "", "warned": true, "capability": capability,
			"required_capabilities": required
		}
	return {
		"blocked": true,
		"reason": REASON,
		"category": category,
		"token": token,
		"error": message,
		"warned": false,
		"capability": capability,
		"required_capabilities": required
	}


# 词边界匹配：token 形如 "OS.execute"。要求 token 前后不是标识符字符，
# 从而 "my_OS.executex" / "foo_HTTPRequest" 之类不会误命中。
static func _matches_identifier(text: String, token: String) -> bool:
	var escaped: String = _escape_regex(token)
	# 前界：行首或非[字母数字下划线]；后界：行尾或非[字母数字下划线]
	var pattern: String = "(?<![A-Za-z0-9_])" + escaped + "(?![A-Za-z0-9_])"
	return _matches_regex(text, pattern)


static func _matches_regex(text: String, pattern: String) -> bool:
	var re: RegEx = _compiled_regex(pattern)
	if re == null:
		return false
	return re.search(text) != null


# Return a compiled RegEx for 'pattern', reusing a cached instance when possible.
# Returns null (cached) when the pattern fails to compile.
static func _compiled_regex(pattern: String) -> RegEx:
	if _regex_cache.has(pattern):
		return _regex_cache[pattern]
	var re: RegEx = RegEx.new()
	if re.compile(pattern) != OK:
		_regex_cache[pattern] = null
		return null
	_regex_cache[pattern] = re
	return re


static func _escape_regex(s: String) -> String:
	var specials: String = "\\.^$*+?()[]{}|"
	var out: String = ""
	for i in range(s.length()):
		var c: String = s[i]
		if specials.contains(c):
			out += "\\" + c
		else:
			out += c
	return out


# 判断一个字符串字面量是否是危险/越界路径，返回命中的片段（空=安全）。
static func _path_violation(literal: String) -> String:
	if literal.is_empty():
		return ""

	# 家目录引用按"路径形态"判定，避免误杀任意含 '~' 的文本（如 "~5 enemies"、"~1.0"）。
	if literal == "~" or literal.begins_with("~/"):
		return "~"

	# 复用 PathValidator 的危险模式（/etc/、/var/、X:\ 等）；'~' 上面已按路径形态单独处理。
	for pattern in PathValidator.DANGEROUS_PATTERNS:
		if pattern == "~":
			continue
		if literal.contains(pattern):
			return pattern

	# res:// 或 user:// 下的目录遍历
	if (literal.begins_with("res://") or literal.begins_with("user://")) and literal.contains(".."):
		return ".."

	# 绝对 Unix 路径（排除资源 scheme）。/root/ 是 Godot 场景树节点路径前缀
	# （get_node("/root/Main") 很常见），按"防误操作"取向放行，避免误杀合法节点路径；
	# 越界到系统目录的写法（/etc/、/var/ 等）已被上面的危险模式拦截。
	if literal.begins_with("/") and not literal.begins_with("/root/"):
		return literal

	# Windows 盘符 X:\ 或 X:/
	var drive: RegEx = _compiled_regex("^[A-Za-z]:[\\\\/]")
	if drive != null and drive.search(literal) != null:
		return literal

	return ""


# 把源码里的字符串字面量与注释剥离，返回:
#   {code: String, literals: Array}
# code: 字符串内容替换为空、注释删除后的代码（保留结构供标识符匹配）
# literals: 提取出的字符串字面量内容（供路径检查）
static func _strip_strings_and_comments(code: String) -> Dictionary:
	# Accumulate into a PackedStringArray and join once at the end; building the
	# result with `out += c` per character is O(n^2) on long scripts because each
	# concatenation reallocates the whole string.
	var out_parts: PackedStringArray = PackedStringArray()
	var literals: Array = []
	var i: int = 0
	var n: int = code.length()

	while i < n:
		var c: String = code[i]

		# 注释：# 到行尾
		if c == "#":
			while i < n and code[i] != "\n":
				i += 1
			continue

		# 三引号字符串 """ 或 '''
		if (c == "\"" or c == "'") and i + 2 < n and code[i + 1] == c and code[i + 2] == c:
			var quote3: String = c
			i += 3
			var buf3: String = ""
			while i < n:
				if code[i] == quote3 and i + 2 < n and code[i + 1] == quote3 and code[i + 2] == quote3:
					i += 3
					break
				if i + 2 >= n and code[i] == quote3:
					i = n
					break
				buf3 += code[i]
				i += 1
			literals.append(buf3)
			out_parts.append(" ")
			continue

		# 单/双引号字符串
		if c == "\"" or c == "'":
			var quote: String = c
			i += 1
			var buf: String = ""
			while i < n and code[i] != quote:
				if code[i] == "\\" and i + 1 < n:
					buf += code[i + 1]
					i += 2
					continue
				buf += code[i]
				i += 1
			i += 1  # 跳过结束引号
			literals.append(buf)
			out_parts.append(" ")
			continue

		out_parts.append(c)
		i += 1

	return {"code": "".join(out_parts), "literals": literals}
