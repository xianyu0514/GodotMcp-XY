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
# 返回:
#   {blocked: bool, reason, category, token, error, warned: bool}
static func scan(code: String, config: Dictionary = {}) -> Dictionary:
	var ok: Dictionary = {"blocked": false, "reason": "", "category": "", "token": "", "error": "", "warned": false}

	if not bool(config.get("enabled", true)):
		return ok
	if code == null or String(code).strip_edges().is_empty():
		return ok

	var categories: Array = config.get("categories", ALL_CATEGORIES)
	var allowlist: Array = config.get("allowlist", [])
	var warn_only: bool = bool(config.get("warn_only", false))

	# 预处理：得到"剥离字符串与注释后的代码"（用于标识符匹配，避免字符串/注释误杀），
	# 以及"提取出的字符串字面量数组"（用于文件路径越界检查）。
	var stripped: Dictionary = _strip_strings_and_comments(String(code))
	var code_no_str: String = stripped["code"]
	var literals: Array = stripped["literals"]

	# 1) 标识符类（os_process / network / dangerous_api）
	for category in DEFAULT_DENYLIST.keys():
		if not categories.has(category):
			continue
		for token in DEFAULT_DENYLIST[category]:
			if allowlist.has(token):
				continue
			if _matches_identifier(code_no_str, token):
				return _hit(category, token, warn_only)

	# 1b) 调用式危险模式
	for category in DANGEROUS_CALL_PATTERNS.keys():
		if not categories.has(category):
			continue
		for pattern in DANGEROUS_CALL_PATTERNS[category]:
			if allowlist.has(pattern):
				continue
			if _matches_regex(code_no_str, pattern):
				return _hit(category, pattern, warn_only)

	# 2) 自定义追加清单
	var extra: Array = config.get("extra_denylist", [])
	for token in extra:
		if allowlist.has(token):
			continue
		if _matches_identifier(code_no_str, String(token)):
			return _hit("custom", String(token), warn_only)

	# 3) 文件系统越界：检查字符串字面量是否命中危险路径
	if categories.has("filesystem"):
		for literal in literals:
			var lit: String = String(literal)
			if allowlist.has(lit):
				continue
			var bad: String = _path_violation(lit)
			if not bad.is_empty():
				return _hit("filesystem", bad, warn_only)

	return ok


static func _hit(category: String, token: String, warn_only: bool) -> Dictionary:
	if warn_only:
		return {"blocked": false, "reason": REASON, "category": category, "token": token, "error": "", "warned": true}
	return {
		"blocked": true,
		"reason": REASON,
		"category": category,
		"token": token,
		"error": "blocked by script sandbox: %s (%s)" % [category, token],
		"warned": false,
	}


# 词边界匹配：token 形如 "OS.execute"。要求 token 前后不是标识符字符，
# 从而 "my_OS.executex" / "foo_HTTPRequest" 之类不会误命中。
static func _matches_identifier(text: String, token: String) -> bool:
	var escaped: String = _escape_regex(token)
	# 前界：行首或非[字母数字下划线]；后界：行尾或非[字母数字下划线]
	var pattern: String = "(?<![A-Za-z0-9_])" + escaped + "(?![A-Za-z0-9_])"
	return _matches_regex(text, pattern)


static func _matches_regex(text: String, pattern: String) -> bool:
	var re: RegEx = RegEx.new()
	if re.compile(pattern) != OK:
		return false
	return re.search(text) != null


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
	var drive: RegEx = RegEx.new()
	if drive.compile("^[A-Za-z]:[\\\\/]") == OK and drive.search(literal) != null:
		return literal

	return ""


# 把源码里的字符串字面量与注释剥离，返回:
#   {code: String, literals: Array}
# code: 字符串内容替换为空、注释删除后的代码（保留结构供标识符匹配）
# literals: 提取出的字符串字面量内容（供路径检查）
static func _strip_strings_and_comments(code: String) -> Dictionary:
	var out: String = ""
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
			out += " "
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
			out += " "
			continue

		out += c
		i += 1

	return {"code": out, "literals": literals}
