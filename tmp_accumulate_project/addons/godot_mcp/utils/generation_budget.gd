class_name MCPGenerationBudget
extends RefCounted

# 外部（付费）素材生成调用的预算护栏。
# 采用滑动窗口的"调用计数 + 上限 + 拒绝策略"，与传输层 _rate_limit 同样思路。
# max_calls <= 0 表示不限制（默认关闭，向后兼容）。window_sec 为统计窗口（秒）。
# 状态进程内静态保存（一个编辑器会话内有效），无需落盘，避免引入额外文件 IO。

static var _max_calls: int = 0
static var _window_sec: int = 3600
static var _timestamps: Array[int] = []

# 由设置（MCP 面板/配置文件）驱动；每次消费前调用，确保读取到最新配置。
static func configure(max_calls: int, window_sec: int) -> void:
	_max_calls = maxi(0, max_calls)
	_window_sec = maxi(1, window_sec)

static func reset() -> void:
	_timestamps.clear()

static func _prune(now_sec: int) -> void:
	var cutoff: int = now_sec - _window_sec
	while not _timestamps.is_empty() and _timestamps[0] <= cutoff:
		_timestamps.remove_at(0)

# 尝试占用一次预算配额。返回：
#   {allowed: bool, remaining: int (-1=无限), reset_in_sec: int, max_calls: int, window_sec: int}
# 仅当 allowed 为 true 时才计入一次调用；被拒绝时不计数。
static func try_consume() -> Dictionary:
	if _max_calls <= 0:
		return {"allowed": true, "remaining": -1, "reset_in_sec": 0, "max_calls": 0, "window_sec": _window_sec}
	var now_sec: int = int(Time.get_unix_time_from_system())
	_prune(now_sec)
	if _timestamps.size() >= _max_calls:
		var reset_in: int = _window_sec - (now_sec - _timestamps[0])
		return {"allowed": false, "remaining": 0, "reset_in_sec": maxi(0, reset_in), "max_calls": _max_calls, "window_sec": _window_sec}
	_timestamps.append(now_sec)
	return {"allowed": true, "remaining": _max_calls - _timestamps.size(), "reset_in_sec": _window_sec, "max_calls": _max_calls, "window_sec": _window_sec}

# 只读快照，不消费配额（供面板/诊断显示）。
static func snapshot() -> Dictionary:
	var now_sec: int = int(Time.get_unix_time_from_system())
	_prune(now_sec)
	var used: int = _timestamps.size()
	return {
		"max_calls": _max_calls,
		"window_sec": _window_sec,
		"used": used,
		"remaining": -1 if _max_calls <= 0 else maxi(0, _max_calls - used),
	}
