# failure_taxonomy.gd — 统一失败分类与重试策略
#
# 背景：过去所有失败都走同一条路径，导致两类真实事故：
#   1. HTTP 502 / 隧道抖动被当成工具失败，触发 replan，白跑几十步；
#   2. 脚本语法错误被当成瞬时故障反复重试，浪费预算并污染项目状态。
#
# 本模块把「失败」拆成正交的两件事：
#   category —— 失败到底属于谁的错（传输 / 工具 / 项目 / 目标 / 策略 / 环境）
#   policy   —— 因此该做什么（退避重试 / 等运行时 / 等 Agent / 重规划 / 放弃）
#
# 它是纯函数集合：不持有状态、不访问网络、不触碰文件系统，便于单测覆盖。

class_name MCPFailureTaxonomy
extends RefCounted

## 失败归属：谁错了
enum Category {
	TRANSPORT_ERROR,     # 连接/隧道/HTTP 层故障，工具与项目都没问题
	TOOL_ERROR,          # 工具自身执行失败（参数错、handler 抛错）
	PROJECT_ERROR,       # 项目状态有问题（脚本语法错、资源缺失）
	OBJECTIVE_ERROR,     # 工具成功但目标没达成（false positive）
	POLICY_BLOCK,        # 被沙箱/保护路径/预算策略拦截
	ENVIRONMENT_ERROR    # 环境缺失（导出模板未安装、运行时没起来）
}

## 处置动作
enum Policy {
	RETRY_BACKOFF,       # 指数退避重试同一调用
	WAIT_RUNTIME,        # 等运行时/调试会话就绪后重试
	WAIT_AGENT_INPUT,    # 需要 Agent 补充参数或安装依赖，不自动重试
	REPLAN,              # 换工具/换参数重新规划
	ABORT,               # 确定性失败，直接结束
	ACCEPT               # 不是失败（成功或可接受的旁路结果）
}

## 分类标志：用于结构化输出，避免调用方解析字符串
const CATEGORY_NAMES: Array[String] = [
	"transport_error", "tool_error", "project_error",
	"objective_error", "policy_block", "environment_error"
]

const POLICY_NAMES: Array[String] = [
	"retry_backoff", "wait_runtime", "wait_agent_input",
	"replan", "abort", "accept"
]

## 传输层故障特征词。命中即认为工具与项目都是健康的，只是链路断了。
const TRANSPORT_TERMS: Array[String] = [
	"connection reset", "connection refused", "connection closed", "connection aborted",
	"network error", "socket", "stream closed", "eof",
	"http 502", "http 503", "http 504", "bad gateway", "service unavailable",
	"gateway timeout", "(502)", "(503)", "(504)", "cloudflare", "tunnel",
	"tls", "ssl", "dns", "proxy", "curl"
]

## 环境缺失特征词：不是项目坏了，是机器上缺东西。
const ENVIRONMENT_TERMS: Array[String] = [
	"export template", "not installed", "missing template", "no template",
	"android sdk", "keystore", "jdk", "java", "msbuild", "dotnet",
	"runtime not ready", "runtime is not ready", "no debugger session",
	"no active session", "no runtime probe", "probe not installed",
	"project not running", "scene is not running"
]

## 项目内容故障特征词：源码/资源本身有问题，重试无意义。
const PROJECT_TERMS: Array[String] = [
	"parse error", "syntax error", "compilation failed", "compile error",
	"script error", "invalid script", "broken script", "cyclic dependency",
	"missing dependency", "missing resource", "uid conflict", "failed to load resource"
]

## 参数/契约故障：工具被调用错了，重规划而不是重试。
const TOOL_TERMS: Array[String] = [
	"is required", "missing required", "invalid argument", "invalid parameter",
	"unknown field", "expected type", "not found", "unsupported", "not supported",
	"cannot be empty", "must be", "out of range", "invalid path", "invalid enum"
]

## 策略拦截特征词：被守卫拦下，需要 Agent 授权或换路径。
const POLICY_TERMS: Array[String] = [
	"blocked by script sandbox", "protected path", "policy", "not authorized",
	"budget exceeded", "rate limit", "vibe coding", "forbidden", "denied"
]

## 需要 Agent 介入的确定性错误（重试无意义，但也不该 replan 掉整条链）
const WAIT_AGENT_TERMS: Array[String] = [
	"needs_input", "ambiguous", "clarify", "specify", "must provide",
	"please provide", "which scene", "which node"
]

## 瞬时故障特征词（属于传输或环境，但值得退避重试）
const TRANSIENT_TERMS: Array[String] = [
	"temporarily unavailable", "temporary failure", "try again", "retry",
	"rate limit", "too many requests", "server busy", "timed out", "timeout",
	"busy", "unavailable", "in progress", "already running"
]

## 退避上限，防止指数退避把长工作流卡死
const MAX_RETRY_AFTER_MS: int = 30000
const MAX_BACKOFF_EXPONENT: int = 5


## 把一段自由文本（error/message）归类到 Category。
## 纯文本匹配，按顺序判定：越具体的类型优先级越高。
static func classify_text(message: String) -> int:
	var text: String = message.strip_edges().to_lower()
	if text.is_empty():
		return Category.TOOL_ERROR
	for term in POLICY_TERMS:
		if text.contains(term):
			return Category.POLICY_BLOCK
	for term in TRANSPORT_TERMS:
		if text.contains(term):
			return Category.TRANSPORT_ERROR
	for term in WAIT_AGENT_TERMS:
		if text.contains(term):
			return Category.TOOL_ERROR
	for term in PROJECT_TERMS:
		if text.contains(term):
			return Category.PROJECT_ERROR
	for term in ENVIRONMENT_TERMS:
		if text.contains(term):
			return Category.ENVIRONMENT_ERROR
	for term in TOOL_TERMS:
		if text.contains(term):
			return Category.TOOL_ERROR
	if _is_transient(text):
		return Category.TRANSPORT_ERROR
	return Category.TOOL_ERROR


## 综合工具结果与可选的执行上下文，给出分类。
## `result` 是工具返回的字典；`context` 可携带 {"runtime_ready": bool} 等旁路事实。
static func classify_result(result: Variant, context: Dictionary = {}) -> int:
	if not (result is Dictionary):
		return Category.TOOL_ERROR
	var data: Dictionary = result
	if data.has("error"):
		return classify_text(String(data.get("error", "")))
	if data.has("blocked") and bool(data.get("blocked", false)):
		return Category.POLICY_BLOCK
	var status: String = String(data.get("status", "")).strip_edges().to_lower()
	if status in ["unconfigured", "missing", "unsupported"]:
		return Category.ENVIRONMENT_ERROR
	if status in ["timeout", "timed_out", "busy", "unavailable"]:
		return Category.TRANSPORT_ERROR
	if status in ["failed", "error", "invalid"]:
		return classify_text(String(data.get("message", status)))
	# 工具说自己成功了，但上下文显示目标没达成 —— 这是最危险的 false positive
	if bool(context.get("objective_required", false)):
		if not bool(context.get("objective_proven", true)):
			return Category.OBJECTIVE_ERROR
	return Category.TOOL_ERROR


## 由分类推导处置策略。
## `attempt` 是已经发生的同类失败次数（从 1 开始），用于退避计算。
static func policy_for(category: int, attempt: int = 1) -> Dictionary:
	var policy: int = Policy.ACCEPT
	match category:
		Category.TRANSPORT_ERROR:
			policy = Policy.RETRY_BACKOFF
		Category.ENVIRONMENT_ERROR:
			policy = Policy.WAIT_AGENT_INPUT
		Category.OBJECTIVE_ERROR:
			policy = Policy.REPLAN
		Category.PROJECT_ERROR:
			policy = Policy.REPLAN
		Category.POLICY_BLOCK:
			policy = Policy.ABORT
		Category.TOOL_ERROR:
			policy = Policy.REPLAN
		_:
			policy = Policy.ACCEPT
	return {
		"category": category_name(category),
		"policy": policy_name(policy),
		"retry_after_ms": retry_after_ms(category, attempt),
		"retryable": policy == Policy.RETRY_BACKOFF or policy == Policy.WAIT_RUNTIME
	}


## 指数退避，上限 30s。确定性与瞬时故障返回 0（不该等）。
static func retry_after_ms(category: int, attempt: int) -> int:
	if category != Category.TRANSPORT_ERROR:
		return 0
	var exponent: int = mini(maxi(attempt - 1, 0), MAX_BACKOFF_EXPONENT)
	return mini(1000 * (1 << exponent), MAX_RETRY_AFTER_MS)


## 对完整工具结果做一次判定，输出可直接塞进 workflow 回执的结构化字典。
static func evaluate(tool_name: String, result: Variant, context: Dictionary = {}) -> Dictionary:
	var verdict: Dictionary = {
		"tool_name": tool_name,
		"passed": false,
		"category": "",
		"policy": "",
		"retry_after_ms": 0,
		"retryable": false,
		"objective_proven": false,
		"message": ""
	}
	if not (result is Dictionary) or (result as Dictionary).is_empty():
		verdict["category"] = category_name(Category.TOOL_ERROR)
		verdict["policy"] = policy_name(Policy.REPLAN)
		verdict["message"] = "empty tool result"
		return verdict

	var data: Dictionary = result
	var has_error: bool = data.has("error")
	var category: int = classify_result(data, context)
	if not has_error and category == Category.TOOL_ERROR:
		# 没有 error 字段且无法归类为其他 => 视为成功路径
		verdict["passed"] = true
		verdict["category"] = ""
		verdict["policy"] = policy_name(Policy.ACCEPT)
		verdict["objective_proven"] = bool(context.get("objective_proven", true))
		if not verdict["objective_proven"]:
			verdict["passed"] = false
			verdict["category"] = category_name(Category.OBJECTIVE_ERROR)
			verdict["policy"] = policy_name(Policy.REPLAN)
			verdict["message"] = "tool succeeded but objective evidence was not produced"
		return verdict

	var attempt: int = maxi(1, int(context.get("attempt", 1)))
	var decision: Dictionary = policy_for(category, attempt)
	verdict["passed"] = false
	verdict["category"] = decision["category"]
	verdict["policy"] = decision["policy"]
	verdict["retry_after_ms"] = int(decision["retry_after_ms"])
	verdict["retryable"] = bool(decision["retryable"])
	verdict["message"] = String(data.get("error", data.get("message", ""))).substr(0, 512)
	return verdict


static func _is_transient(text: String) -> bool:
	for term in TRANSIENT_TERMS:
		if text.contains(term):
			return true
	return false


static func category_name(category: int) -> String:
	if category >= 0 and category < CATEGORY_NAMES.size():
		return CATEGORY_NAMES[category]
	return ""


static func policy_name(policy: int) -> String:
	if policy >= 0 and policy < POLICY_NAMES.size():
		return POLICY_NAMES[policy]
	return ""


## 反查：把字符串名转回枚举，便于配置/测试驱动。未知值返回 -1。
static func category_from_name(name: String) -> int:
	return CATEGORY_NAMES.find(name.strip_edges().to_lower())


static func policy_from_name(name: String) -> int:
	return POLICY_NAMES.find(name.strip_edges().to_lower())
