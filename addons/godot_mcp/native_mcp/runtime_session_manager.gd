# runtime_session_manager.gd — Runtime 会话生命周期与分阶段目标验证
#
# 背景一：run_project 只要"进程创建成功"就返回 success，但项目可能因
#   Parse Error 在两帧后退出。这是最典型的 false positive——工具成功 ≠ 目标成功。
#
# 背景二：Planner 会把 call_runtime_node_method 排在 install_runtime_probe /
#   run_project 之前，因为没有任何组件声明"这个工具需要 runtime 会话"。
#
# 本模块把 runtime 启动拆成五个可观测阶段，并且只有在全部阶段达成后才判定
# runtime_ready=true：
#   Stage 1 process_created     —— 子进程已创建
#   Stage 2 debugger_attached   —— 调试器会话已建立
#   Stage 3 probe_handshake     —— MCP runtime probe 完成握手
#   Stage 4 scene_ready         —— 主场景已就绪
#   Stage 5 alive_after_grace   —— grace period 后进程仍然存活
#
# 存活探测通过可注入的 Callable 完成，便于单元测试与不同 Godot 版本适配。

class_name MCPRuntimeSessionManager
extends RefCounted

enum Stage {
	IDLE,
	PROCESS_CREATED,
	DEBUGGER_ATTACHED,
	PROBE_HANDSHAKE,
	SCENE_READY,
	ALIVE_AFTER_GRACE
}

const STAGE_NAMES: Array[String] = [
	"idle", "process_created", "debugger_attached",
	"probe_handshake", "scene_ready", "alive_after_grace"
]

## 会话状态（与 stage 正交：stage 是进度，state 是结论）
const STATE_ABSENT: String = "absent"
const STATE_STARTING: String = "starting"
const STATE_READY: String = "ready"
const STATE_STARTED_BUT_EXITED: String = "started_but_exited"
const STATE_FAILED: String = "failed"

## grace period：Stage 4 之后仍需存活多久才算真正起来。
## 太短抓不到"两帧就崩"，太长会拖慢工作流；3 秒是实测可用的折中。
const DEFAULT_GRACE_PERIOD_MS: int = 3000

## 各阶段默认等待上限
const DEFAULT_STAGE_TIMEOUT_MS: int = 8000

const CapabilityDAGScript = preload("res://addons/godot_mcp/native_mcp/capability_dag.gd")

var _state: String = STATE_ABSENT
var _stage: int = Stage.IDLE
var _scene_path: String = ""
var _session_id: String = ""
var _stage_timestamps: Dictionary = {}
var _started_at_msec: int = 0
var _last_error: String = ""
var _grace_period_ms: int = DEFAULT_GRACE_PERIOD_MS
var _liveness_probe: Callable = Callable()

## 注入存活探测：Callable() -> bool。未注入时视为"无法判定存活"。
func set_liveness_probe(probe: Callable) -> void:
	_liveness_probe = probe


func set_grace_period_ms(value: int) -> void:
	_grace_period_ms = maxi(0, value)


# ---------------------------------------------------------------------------
# 生命周期推进
# ---------------------------------------------------------------------------

## 开始一次启动：重置状态并宣告 Stage 1 达成
func begin_launch(scene_path: String = "", session_id: String = "") -> Dictionary:
	_state = STATE_STARTING
	_stage = Stage.PROCESS_CREATED
	_scene_path = scene_path.strip_edges()
	_session_id = session_id
	_stage_timestamps = {STAGE_NAMES[Stage.PROCESS_CREATED]: Time.get_ticks_msec()}
	_started_at_msec = Time.get_ticks_msec()
	_last_error = ""
	return snapshot()


func mark_debugger_attached() -> Dictionary:
	_advance(Stage.DEBUGGER_ATTACHED)
	return snapshot()


func mark_probe_installed() -> Dictionary:
	_advance(Stage.PROBE_HANDSHAKE)
	return snapshot()


func mark_scene_ready() -> Dictionary:
	_advance(Stage.SCENE_READY)
	return snapshot()


## 标记进程退出。若已经越过 Stage 1 但没走完全部阶段，判定为
## started_but_exited —— 这正是过去被误报成 success 的场景。
func mark_exited(exit_code: int = 0, reason: String = "") -> Dictionary:
	if _stage >= Stage.ALIVE_AFTER_GRACE:
		_state = STATE_ABSENT
	elif _stage > Stage.IDLE:
		_state = STATE_STARTED_BUT_EXITED
		_last_error = reason if not reason.is_empty() else \
			"process exited at stage '%s' with code %d" % [STAGE_NAMES[_stage], exit_code]
	else:
		_state = STATE_ABSENT
	_stage_timestamps["exited"] = Time.get_ticks_msec()
	return snapshot()


func mark_failed(reason: String) -> Dictionary:
	_state = STATE_FAILED
	_last_error = reason
	return snapshot()


func reset() -> void:
	_state = STATE_ABSENT
	_stage = Stage.IDLE
	_scene_path = ""
	_session_id = ""
	_stage_timestamps = {}
	_started_at_msec = 0
	_last_error = ""


# ---------------------------------------------------------------------------
# 查询 / 校验
# ---------------------------------------------------------------------------

## 分阶段验证的最终结论：只有走完全部 5 个阶段才算 runtime_ready。
## 这一步是 run_project 目标验证的核心，返回结构直接进入工具结果。
func verify_ready() -> Dictionary:
	var alive: bool = _probe_alive()
	var reached_grace: bool = _stage >= Stage.ALIVE_AFTER_GRACE
	if _stage >= Stage.SCENE_READY and not reached_grace:
		# 已过 Stage 4 但还没确认 grace：尝试推进 Stage 5
		if _elapsed_since(Stage.SCENE_READY) >= _grace_period_ms and alive:
			_advance(Stage.ALIVE_AFTER_GRACE)
			reached_grace = true
		elif not alive:
			_state = STATE_STARTED_BUT_EXITED
			_last_error = "process exited during the startup grace period"
	if reached_grace and alive:
		_state = STATE_READY
	var ready: bool = reached_grace and alive and _state == STATE_READY
	return {
		"runtime_ready": ready,
		"state": _state,
		"stage": STAGE_NAMES[_stage],
		"stages_reached": reached_stages(),
		"scene": _scene_path,
		"session_id": _session_id,
		"elapsed_ms": _elapsed_since(Stage.IDLE),
		"grace_period_ms": _grace_period_ms,
		"error": _last_error
	}


## 等待会话就绪。必须由调用方在 await 循环里驱动（本方法不阻塞）。
func is_ready() -> bool:
	return verify_ready().get("runtime_ready", false)


## 某个工具当前能否执行：返回缺失的前置事实。
## 这是 #12/#13 的落地：runtime 工具声明 requires，规划器提前拒绝错误顺序。
func missing_prerequisites(tool_name: String, available_facts: Array = []) -> Array[String]:
	var facts: Dictionary = {}
	for fact_value in available_facts:
		facts[String(fact_value)] = true
	# 依据会话当前状态补齐可推导的事实
	if _stage >= Stage.PROCESS_CREATED:
		facts[CapabilityDAGScript.FACT_RUNTIME_SESSION] = true
		facts[CapabilityDAGScript.FACT_DEBUGGER_SESSION] = _stage >= Stage.DEBUGGER_ATTACHED
	if _stage >= Stage.PROBE_HANDSHAKE:
		facts[CapabilityDAGScript.FACT_RUNTIME_PROBE] = true
	if _state == STATE_READY and _stage >= Stage.ALIVE_AFTER_GRACE:
		facts[CapabilityDAGScript.FACT_RUNTIME_SESSION] = true
		facts[CapabilityDAGScript.FACT_RUNTIME_PROBE] = true

	var missing: Array[String] = []
	for required in CapabilityDAGScript.requires_for(tool_name):
		var fact: String = String(required)
		if not facts.has(fact):
			missing.append(fact)
	return missing


func snapshot() -> Dictionary:
	return {
		"state": _state,
		"stage": STAGE_NAMES[_stage],
		"stage_index": _stage,
		"scene": _scene_path,
		"session_id": _session_id,
		"stages_reached": reached_stages(),
		"elapsed_ms": _elapsed_since(Stage.IDLE),
		"error": _last_error,
		"grace_period_ms": _grace_period_ms
	}


func reached_stages() -> Array[String]:
	var reached: Array[String] = []
	for index in range(Stage.IDLE + 1, Stage.ALIVE_AFTER_GRACE + 1):
		if _stage_timestamps.has(STAGE_NAMES[index]):
			reached.append(STAGE_NAMES[index])
	return reached


# ---------------------------------------------------------------------------
# 内部实现
# ---------------------------------------------------------------------------

func _advance(stage: int) -> void:
	if stage > _stage:
		_stage = stage
		_stage_timestamps[STAGE_NAMES[stage]] = Time.get_ticks_msec()
	if _state == STATE_ABSENT:
		_state = STATE_STARTING


func _elapsed_since(stage: int) -> int:
	if _started_at_msec <= 0:
		return 0
	if stage == Stage.IDLE:
		return Time.get_ticks_msec() - _started_at_msec
	var timestamp: int = int(_stage_timestamps.get(STAGE_NAMES[stage], _started_at_msec))
	return Time.get_ticks_msec() - timestamp


func _probe_alive() -> bool:
	if not _liveness_probe.is_valid():
		# 没有注入探测器时不能谎报存活，但也不能因此判定死亡；
		# 交由 stage 状态决定：已过 grace 阶段即视为存活。
		return _stage >= Stage.ALIVE_AFTER_GRACE
	return bool(_liveness_probe.call())
