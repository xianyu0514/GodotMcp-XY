# capability_dag.gd — 工具前置条件 / 效果声明与依赖求解
#
# 背景：过去的 Planner 更接近「工具选择器」而不是「状态感知规划器」。真实事故：
#   - attach_script 排在 create_scene 之前；
#   - call_runtime_node_method 排在 install_runtime_probe / run_project 之前。
# 根因是工具之间缺少语义依赖声明，排序只能靠名字前缀猜。
#
# 本模块为每个工具声明 requires / produces / invalidates，把「工具列表」升级为
# 「能力 DAG」。规划器据此自动推导执行顺序，并能在计划阶段就报出
# 「第 N 步缺前置事实 X」，而不是等到执行时才失败。

class_name MCPCapabilityDAG
extends RefCounted

# ---------------------------------------------------------------------------
# 事实词汇表（state facts）
# ---------------------------------------------------------------------------
const FACT_SCENE_EXISTS: String = "scene_exists"
const FACT_SCENE_OPEN: String = "scene_open"
const FACT_SCENE_SAVED: String = "scene_saved"
const FACT_NODE_EXISTS: String = "node_exists"
const FACT_SCRIPT_EXISTS: String = "script_exists"
const FACT_SCRIPT_ATTACHED: String = "script_attached"
const FACT_INPUT_ACTIONS_EXIST: String = "input_actions_exist"
const FACT_DEBUGGER_SESSION: String = "debugger_session"
const FACT_RUNTIME_SESSION: String = "runtime_session"
const FACT_RUNTIME_PROBE: String = "runtime_probe"
const FACT_EXPORT_PRESET_VALID: String = "export_preset_valid"
const FACT_EXPORT_TEMPLATE_AVAILABLE: String = "export_template_available"
const FACT_EXPORTED_ARTIFACT: String = "exported_artifact"
const FACT_TILESET_EXISTS: String = "tileset_exists"
const FACT_THEME_EXISTS: String = "theme_exists"

## 需要 runtime probe 才成立的运行时工具（探针是它们的运行时通道）
const RUNTIME_PROBE_TOOLS: Array[String] = [
	"get_runtime_info", "get_runtime_scene_tree", "inspect_runtime_node",
	"update_runtime_node_property", "call_runtime_node_method",
	"evaluate_runtime_expression", "await_runtime_condition",
	"assert_runtime_condition", "await_scene_ready",
	"create_runtime_node", "delete_runtime_node",
	"simulate_runtime_input_event", "simulate_runtime_input_action",
	"list_runtime_input_actions", "upsert_runtime_input_action",
	"remove_runtime_input_action", "list_runtime_animations",
	"play_runtime_animation", "stop_runtime_animation",
	"get_runtime_animation_state", "get_runtime_animation_tree_state",
	"set_runtime_animation_tree_active", "travel_runtime_animation_tree",
	"get_runtime_material_state", "get_runtime_theme_item",
	"set_runtime_theme_override", "clear_runtime_theme_override",
	"get_runtime_shader_parameters", "set_runtime_shader_parameter",
	"list_runtime_tilemap_layers", "get_runtime_tilemap_cell",
	"set_runtime_tilemap_cell", "list_runtime_audio_buses",
	"get_runtime_audio_bus", "update_runtime_audio_bus",
	"get_runtime_screenshot", "get_runtime_performance_snapshot",
	"get_runtime_memory_trend", "assert_no_runtime_errors",
	"assert_performance_budget", "assert_visual_baseline",
	"compare_render_screenshots", "play_and_verify"
]

## 只需要调试器会话（不依赖 MCP runtime probe）的工具
const DEBUGGER_SESSION_TOOLS: Array[String] = [
	"get_debug_threads", "get_debug_stack_frames", "get_debug_stack_variables",
	"get_debug_scopes", "get_debug_variables", "expand_debug_variable",
	"evaluate_debug_expression", "debug_step_into", "debug_step_over",
	"debug_step_out", "debug_continue", "debug_step_into_and_wait",
	"debug_step_over_and_wait", "debug_step_out_and_wait",
	"debug_continue_and_wait", "await_debugger_state", "get_debug_state_events",
	"request_debug_break", "send_debug_command", "toggle_debugger_profiler",
	"get_debug_output", "get_debugger_messages", "set_debugger_breakpoint"
]

## 工具 -> {requires, produces, invalidates}
## invalidates 表示「该操作会让哪些既有事实失效」，用于 receipt 失效判定。
const TOOL_EFFECTS: Dictionary = {
	# --- 场景 / 节点 -------------------------------------------------------
	"create_scene": {
		"requires": [],
		"produces": [FACT_SCENE_EXISTS, FACT_SCENE_OPEN, FACT_NODE_EXISTS],
		"invalidates": [FACT_SCENE_SAVED]
	},
	"open_scene": {
		"requires": [FACT_SCENE_EXISTS],
		"produces": [FACT_SCENE_OPEN, FACT_NODE_EXISTS],
		"invalidates": []
	},
	"save_scene": {
		"requires": [FACT_SCENE_OPEN],
		"produces": [FACT_SCENE_SAVED, FACT_SCENE_EXISTS],
		"invalidates": []
	},
	"save_branch_as_scene": {
		"requires": [FACT_SCENE_OPEN, FACT_NODE_EXISTS],
		"produces": [FACT_SCENE_SAVED, FACT_SCENE_EXISTS],
		"invalidates": []
	},
	"instantiate_scene": {
		"requires": [FACT_SCENE_EXISTS, FACT_SCENE_OPEN],
		"produces": [FACT_NODE_EXISTS],
		"invalidates": [FACT_SCENE_SAVED]
	},
	"create_node": {
		"requires": [FACT_SCENE_OPEN],
		"produces": [FACT_NODE_EXISTS],
		"invalidates": [FACT_SCENE_SAVED]
	},
	"duplicate_node": {
		"requires": [FACT_SCENE_OPEN, FACT_NODE_EXISTS],
		"produces": [FACT_NODE_EXISTS],
		"invalidates": [FACT_SCENE_SAVED]
	},
	"delete_node": {
		"requires": [FACT_SCENE_OPEN, FACT_NODE_EXISTS],
		"produces": [],
		"invalidates": [FACT_SCENE_SAVED]
	},
	"move_node": {
		"requires": [FACT_SCENE_OPEN, FACT_NODE_EXISTS],
		"produces": [],
		"invalidates": [FACT_SCENE_SAVED]
	},
	"rename_node": {
		"requires": [FACT_SCENE_OPEN, FACT_NODE_EXISTS],
		"produces": [],
		"invalidates": [FACT_SCENE_SAVED]
	},
	"update_node_property": {
		"requires": [FACT_SCENE_OPEN, FACT_NODE_EXISTS],
		"produces": [],
		"invalidates": [FACT_SCENE_SAVED]
	},
	"set_anchor_preset": {
		"requires": [FACT_SCENE_OPEN, FACT_NODE_EXISTS],
		"produces": [],
		"invalidates": [FACT_SCENE_SAVED]
	},
	"connect_signal": {
		"requires": [FACT_SCENE_OPEN, FACT_NODE_EXISTS],
		"produces": [],
		"invalidates": [FACT_SCENE_SAVED]
	},
	"disconnect_signal": {
		"requires": [FACT_SCENE_OPEN, FACT_NODE_EXISTS],
		"produces": [],
		"invalidates": [FACT_SCENE_SAVED]
	},

	# --- 脚本 -------------------------------------------------------------
	"create_script": {
		"requires": [],
		"produces": [FACT_SCRIPT_EXISTS],
		"invalidates": []
	},
	"modify_script": {
		"requires": [FACT_SCRIPT_EXISTS],
		"produces": [FACT_SCRIPT_EXISTS],
		"invalidates": []
	},
	"attach_script": {
		"requires": [FACT_SCRIPT_EXISTS, FACT_NODE_EXISTS, FACT_SCENE_OPEN],
		"produces": [FACT_SCRIPT_ATTACHED],
		"invalidates": [FACT_SCENE_SAVED]
	},

	# --- 输入映射 ---------------------------------------------------------
	"upsert_project_input_action": {
		"requires": [],
		"produces": [FACT_INPUT_ACTIONS_EXIST],
		"invalidates": []
	},

	# --- 运行时 -----------------------------------------------------------
	"run_project": {
		"requires": [],
		"produces": [FACT_RUNTIME_SESSION, FACT_DEBUGGER_SESSION],
		"invalidates": [FACT_RUNTIME_PROBE]
	},
	"install_runtime_probe": {
		"requires": [FACT_RUNTIME_SESSION],
		"produces": [FACT_RUNTIME_PROBE],
		"invalidates": []
	},
	"remove_runtime_probe": {
		"requires": [FACT_RUNTIME_SESSION, FACT_RUNTIME_PROBE],
		"produces": [],
		"invalidates": [FACT_RUNTIME_PROBE]
	},
	"stop_project": {
		"requires": [FACT_RUNTIME_SESSION],
		"produces": [],
		"invalidates": [FACT_RUNTIME_SESSION, FACT_RUNTIME_PROBE, FACT_DEBUGGER_SESSION]
	},

	# --- 导出 / 发布 ------------------------------------------------------
	"validate_export_preset": {
		"requires": [FACT_EXPORT_PRESET_VALID],
		"produces": [],
		"invalidates": []
	},
	"run_export": {
		"requires": [FACT_EXPORT_PRESET_VALID, FACT_EXPORT_TEMPLATE_AVAILABLE],
		"produces": [FACT_EXPORTED_ARTIFACT],
		"invalidates": []
	},
	"pack_pck": {
		"requires": [],
		"produces": [FACT_EXPORTED_ARTIFACT],
		"invalidates": []
	},
	"smoke_test_export": {
		"requires": [FACT_EXPORTED_ARTIFACT],
		"produces": [],
		"invalidates": []
	},

	# --- 资源 -------------------------------------------------------------
	"create_tileset": {
		"requires": [],
		"produces": [FACT_TILESET_EXISTS],
		"invalidates": []
	},
	"create_theme": {
		"requires": [],
		"produces": [FACT_THEME_EXISTS],
		"invalidates": []
	},
	"create_animation": {
		"requires": [],
		"produces": ["animation_exists"],
		"invalidates": []
	},
}

## 名称模式兜底规则。按顺序匹配，第一个命中生效。
## 用于没有显式声明的工具，保证新工具也能得到合理的默认依赖。
const PATTERN_RULES: Array[Dictionary] = [
	{"ends_with": "_runtime_tilemap_cell", "requires": [FACT_RUNTIME_SESSION, FACT_RUNTIME_PROBE]},
]


# ---------------------------------------------------------------------------
# 查询 API
# ---------------------------------------------------------------------------

## 获取工具的能力声明；未声明的工具返回空声明（不阻塞规划）。
static func spec_for(tool_name: String) -> Dictionary:
	if TOOL_EFFECTS.has(tool_name):
		return (TOOL_EFFECTS[tool_name] as Dictionary).duplicate(true)
	var inferred: Dictionary = _infer_spec(tool_name)
	return inferred


static func requires_for(tool_name: String) -> Array[String]:
	return _string_array(spec_for(tool_name).get("requires", []))


static func produces_for(tool_name: String) -> Array[String]:
	return _string_array(spec_for(tool_name).get("produces", []))


static func invalidates_for(tool_name: String) -> Array[String]:
	return _string_array(spec_for(tool_name).get("invalidates", []))


## 该工具是否需要运行时会话 / 探针（供 runtime 前置校验复用）
static func needs_runtime(tool_name: String) -> bool:
	return tool_name in RUNTIME_PROBE_TOOLS or tool_name in DEBUGGER_SESSION_TOOLS \
		or FACT_RUNTIME_SESSION in requires_for(tool_name)


static func needs_runtime_probe(tool_name: String) -> bool:
	return tool_name in RUNTIME_PROBE_TOOLS or FACT_RUNTIME_PROBE in requires_for(tool_name)


# ---------------------------------------------------------------------------
# 求解 API
# ---------------------------------------------------------------------------

## 对工具序列做拓扑排序。
##
## 参数：
##   tool_names —— 待排序的工具名（按 profile 组合顺序传入）
##   stages     —— tool_name -> stage 名（用于同层内保持既有 stage 语义）
##   stage_rank —— stage 名 -> 排序权重（数值小者先）
##
## 返回排序后的工具名数组。求解失败（环 / 永远无法满足的前置）时，
## 剩余工具按原始相对顺序追加，保证调用方拿到完整列表而不是丢步骤。
static func order(tool_names: Array[String], stages: Dictionary = {},
		stage_rank: Dictionary = {}) -> Array[String]:
	return diagnose(tool_names, stages, stage_rank).get("ordered", [])


## 完整求解：排序 + 每个步骤缺失的前置事实 + 最终事实集。
##
## 返回：
## {
##   ordered: Array[String],
##   unsatisfied: Dictionary,       # tool_name -> 缺失事实数组（按首次出现位置）
##   facts_before: Array,           # 每个步骤执行前已满足的事实快照（与 ordered 对齐）
##   facts_after: Array,            # 每个步骤执行后的事实快照
##   final_facts: Array[String],
##   reorder_count: int             # 相对输入顺序发生位移的步骤数
## }
static func diagnose(tool_names: Array[String], stages: Dictionary = {},
		stage_rank: Dictionary = {}) -> Dictionary:
	var pending: Array[Dictionary] = []
	for index in range(tool_names.size()):
		var tool_name: String = tool_names[index]
		pending.append({
			"tool_name": tool_name,
			"index": index,
			"requires": requires_for(tool_name),
			"produces": produces_for(tool_name),
			"invalidates": invalidates_for(tool_name)
		})

	var facts: Dictionary = {}
	var ordered: Array[String] = []
	var facts_before: Array = []
	var facts_after: Array = []
	var unsatisfied: Dictionary = {}
	var guard: int = 0
	var max_iterations: int = maxi(1, pending.size() * pending.size() + pending.size())

	while not pending.is_empty() and guard < max_iterations:
		guard += 1
		var ready_index: int = _pick_ready(pending, facts, stages, stage_rank)
		if ready_index < 0:
			# 剩余步骤的前置永远无法满足：记录缺口后按原顺序放行（fail-open），
			# 让上层工作流给出明确的 blocked 原因，而不是静默丢步骤。
			for entry_value in pending:
				var stuck: Dictionary = entry_value
				var missing: Array[String] = _missing_facts(stuck["requires"], facts)
				if not missing.is_empty():
					var stuck_name: String = String(stuck["tool_name"])
					if not unsatisfied.has(stuck_name):
						unsatisfied[stuck_name] = missing
			# 选取"缺口最少"的一步先执行，尽量减少连锁失败
			ready_index = _pick_least_blocked(pending, facts)
			if ready_index < 0:
				ready_index = 0
		var entry: Dictionary = pending[ready_index]
		pending.remove_at(ready_index)
		var name: String = String(entry["tool_name"])
		facts_before.append(_sorted_facts(facts))
		ordered.append(name)
		for fact_value in (entry["invalidates"] as Array):
			facts.erase(String(fact_value))
		for fact_value in (entry["produces"] as Array):
			facts[String(fact_value)] = true
		facts_after.append(_sorted_facts(facts))

	# 极端兜底：把因 guard 超限未处理完的步骤按原序补上
	if not pending.is_empty():
		for entry_value in pending:
			ordered.append(String((entry_value as Dictionary).get("tool_name", "")))

	return {
		"ordered": ordered,
		"unsatisfied": unsatisfied,
		"facts_before": facts_before,
		"facts_after": facts_after,
		"final_facts": _sorted_facts(facts),
		"reorder_count": _reorder_count(tool_names, ordered)
	}


## 给定已满足的事实集，返回执行该工具还缺什么
static func missing_prerequisites(tool_name: String, satisfied_facts: Array) -> Array[String]:
	var satisfied: Dictionary = {}
	for fact_value in satisfied_facts:
		satisfied[String(fact_value)] = true
	return _missing_facts(requires_for(tool_name), satisfied)


## 模拟执行一串工具后得到的事实集（不考虑 unsatisfied）
static func facts_after(tool_names: Array[String], initial_facts: Array = []) -> Array[String]:
	var facts: Dictionary = {}
	for fact_value in initial_facts:
		facts[String(fact_value)] = true
	for tool_name in tool_names:
		for invalidated in invalidates_for(tool_name):
			facts.erase(invalidated)
		for produced in produces_for(tool_name):
			facts[produced] = true
	return _sorted_facts(facts)


# ---------------------------------------------------------------------------
# 内部实现
# ---------------------------------------------------------------------------

static func _infer_spec(tool_name: String) -> Dictionary:
	if tool_name in RUNTIME_PROBE_TOOLS:
		return {"requires": [FACT_RUNTIME_SESSION, FACT_RUNTIME_PROBE], "produces": [], "invalidates": []}
	if tool_name in DEBUGGER_SESSION_TOOLS:
		return {"requires": [FACT_DEBUGGER_SESSION], "produces": [], "invalidates": []}
	for rule_value in PATTERN_RULES:
		var rule: Dictionary = rule_value
		if String(rule.get("ends_with", "")).is_empty():
			continue
		if tool_name.ends_with(String(rule.get("ends_with", ""))):
			return {
				"requires": _string_array(rule.get("requires", [])),
				"produces": [],
				"invalidates": []
			}
	return {"requires": [], "produces": [], "invalidates": []}


static func _pick_ready(pending: Array[Dictionary], facts: Dictionary,
		stages: Dictionary, stage_rank: Dictionary) -> int:
	var best_index: int = -1
	var best_key: Array = []
	for index in range(pending.size()):
		var entry: Dictionary = pending[index]
		if not _missing_facts(entry["requires"], facts).is_empty():
			continue
		var tool_name: String = String(entry["tool_name"])
		var stage_name: String = String(stages.get(tool_name, ""))
		var rank: int = int(stage_rank.get(stage_name, 999))
		var key: Array = [0, rank, int(entry["index"])]
		if best_index < 0 or _compare_keys(key, best_key) < 0:
			best_index = index
			best_key = key
	return best_index


static func _pick_least_blocked(pending: Array[Dictionary], facts: Dictionary) -> int:
	var best_index: int = -1
	var best_missing: int = 2147483647
	for index in range(pending.size()):
		var missing: int = _missing_facts(pending[index]["requires"], facts).size()
		if missing < best_missing:
			best_missing = missing
			best_index = index
	return best_index


static func _missing_facts(required: Variant, facts: Dictionary) -> Array[String]:
	var missing: Array[String] = []
	if not (required is Array):
		return missing
	for fact_value in (required as Array):
		var fact: String = String(fact_value)
		if not facts.has(fact):
			missing.append(fact)
	return missing


static func _sorted_facts(facts: Dictionary) -> Array[String]:
	var result: Array[String] = []
	for fact_value in facts:
		result.append(String(fact_value))
	result.sort()
	return result


static func _string_array(value: Variant) -> Array[String]:
	var result: Array[String] = []
	if not (value is Array):
		return result
	for item in (value as Array):
		result.append(String(item))
	return result


static func _compare_keys(a: Array, b: Array) -> int:
	for index in range(mini(a.size(), b.size())):
		var av: int = int(a[index])
		var bv: int = int(b[index])
		if av != bv:
			return -1 if av < bv else 1
	return 0


static func _reorder_count(original: Array[String], ordered: Array[String]) -> int:
	var moved: int = 0
	var expected: Dictionary = {}
	for index in range(original.size()):
		expected[original[index]] = index
	var previous_index: int = -1
	for tool_name in ordered:
		var current: int = int(expected.get(tool_name, previous_index + 1))
		if current < previous_index:
			moved += 1
		previous_index = maxi(previous_index, current)
	return moved
