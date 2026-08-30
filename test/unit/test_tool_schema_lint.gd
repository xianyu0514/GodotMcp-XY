extends "res://addons/gut/test.gd"

# ============================================================================
# test_tool_schema_lint.gd — 工具 schema JSON Schema 关键字 lint 回归测试
#
# 背景（Coding-Solo #55 实证）：部分 MCP 客户端（如 Copilot）对 inputSchema /
# outputSchema 中不支持的“额外关键字”（default、minimum、maximum、minLength、
# pattern、format 等）会直接拒绝加载整个工具。本测试遍历全部工具 schema，
# 断言其中出现的所有关键字都在“MCP/JSON Schema 安全子集”白名单内，防止未来
# 新增 schema 时引入非标准/不兼容关键字。
#
# 基线（首次诊断快照，Godot 4.7.2 headless；数字随 schema 演进变化，
# 本测试不锁定具体出现次数，只锁定“关键字集合 ⊆ 白名单”）：
#   - 218+ 个工具全部注册成功（当前仓库 231 个）
#   - 实际用到的关键字只有 7 个：
#       type properties description required default items enum
#   - 全部 input_schema 均为 {type:"object", properties:{...}}（含 17 个无参工具
#     properties 为空字典）；全部 output_schema 为 object 类型
#   - input/output schema 均无 oneOf / anyOf
#   - 顶层 input 属性 734 个，其中 191 个无 description（且无 enum/const/items），
#     多为 debug/runtime 工具的自明参数（session_id / timeout_ms / node_path 等），
#     覆盖率 ≈ 74%
#   - 无非字符串 key；无畸形子 schema（properties/items 值非 Dictionary）
# ============================================================================

const TOOL_MODULE_PATHS: Array[String] = [
	"res://addons/godot_mcp/tools/node_tools_native.gd",
	"res://addons/godot_mcp/tools/script_tools_native.gd",
	"res://addons/godot_mcp/tools/scene_tools_native.gd",
	"res://addons/godot_mcp/tools/editor_tools_native.gd",
	"res://addons/godot_mcp/tools/debug_tools_native.gd",
	"res://addons/godot_mcp/tools/debug_bridge_tools.gd",
	"res://addons/godot_mcp/tools/debug_runtime_tools.gd",
	"res://addons/godot_mcp/tools/debug_verify_tools.gd",
	"res://addons/godot_mcp/tools/project_tools_native.gd",
	"res://addons/godot_mcp/tools/project_resources_tools.gd",
	"res://addons/godot_mcp/tools/project_assets_tools.gd",
	"res://addons/godot_mcp/tools/project_tileset_tools.gd",
	"res://addons/godot_mcp/tools/project_verification_tools.gd",
	"res://addons/godot_mcp/tools/project_workflow_tools.gd",
	"res://addons/godot_mcp/tools/export_preset_tools.gd",
	"res://addons/godot_mcp/tools/game_workflow_tools.gd",
	"res://addons/godot_mcp/tools/meta_tools_native.gd",
]
const WORKFLOW_ROUTER = preload("res://addons/godot_mcp/native_mcp/workflow_router.gd")
const TRANSLATION_MANAGER = preload("res://addons/godot_mcp/native_mcp/translation_manager.gd")
const TOKEN_ESTIMATOR = preload("res://addons/godot_mcp/utils/token_estimator.gd")

## 允许关键字白名单 —— MCP/JSON Schema 常见安全子集。
## 覆盖当前 schema 实际用到的全部 7 个关键字（type/properties/required/items/
## enum/description/default），同时放行 JSON Schema 中语义明确、客户端兼容性
## 较好的常见关键字。不在白名单内的关键字（如 examples、$comment、patternProperties、
## minContains、nullable 等）会触发 test_all_tool_schemas_only_use_allowed_keywords
## 失败 —— 届时需显式评估客户端兼容性后再扩充本白名单。
const ALLOWED_SCHEMA_KEYWORDS: Dictionary = {
	"type": true,
	"properties": true,
	"required": true,
	"items": true,
	"enum": true,
	"description": true,
	"default": true,
	"additionalProperties": true,
	"oneOf": true,
	"anyOf": true,
	"const": true,
	"title": true,
	"$schema": true,
	"$ref": true,
	"minimum": true,
	"maximum": true,
	"exclusiveMinimum": true,
	"exclusiveMaximum": true,
	"minLength": true,
	"maxLength": true,
	"pattern": true,
	"format": true,
	"minItems": true,
	"maxItems": true,
	"uniqueItems": true,
	"multipleOf": true,
	"minProperties": true,
	"maxProperties": true,
	"dependentRequired": true,
	"if": true,
	"then": true,
	"else": true,
}

## 对严格客户端（Copilot 等）有已知兼容性风险的关键字。
## 当前 schema 只使用了其中 default（250+ 处，历史基线），因此 default 在
## KNOWN_RISKY_KEYWORD_EXEMPTIONS 中登记为豁免；其余关键字若未来出现在 schema 中，
## test_no_new_risky_keyword_categories 会失败，迫使维护者显式评估 Copilot 风险。
const RISKY_FOR_STRICT_CLIENTS: Array[String] = [
	"default",
	"minimum",
	"maximum",
	"minLength",
	"maxLength",
	"pattern",
	"format",
	"multipleOf",
	"exclusiveMinimum",
	"exclusiveMaximum",
	"minItems",
	"maxItems",
	"uniqueItems",
]

## 已登记豁免的风险关键字（注释见上）。
const KNOWN_RISKY_KEYWORD_EXEMPTIONS: Dictionary = {
	"default": true,
}

## 顶层 input 属性 description 覆盖率软阈值。
## 基线 ≈ 74%（191 个无 description 且无 enum/const/items，多为
## debug/runtime 工具的自明参数）。阈值取 70% 留出余量 —— 该测试是提示性的，
## 不强制 100% 覆盖。
const MIN_DESCRIPTION_COVERAGE: float = 0.70

## 工具数下限（历史基线 218；当前为 231 = 28 核心 + 197 补充 + 6 元）。
## 不锁定具体总数，另行校验 server_core 与分类器注册数一致。
const MIN_TOOL_COUNT: int = 218

## token 预算门禁（口径：MCPTokenEstimator —— DSH token-meter 启发式，
## tokens ≈ 字符数 / 4，工具定义按 name+description+inputSchema 计费；
## outputSchema 模型不可见，不计入）。工具 schema 每轮全额计费，三档预算：
##   - 单工具 ≤ TOOL_TOKEN_BUDGET（400 token ≈ 1600 字符）；
##   - 默认启用集（28 core + 6 meta）≤ DEFAULT_SET_TOKEN_BUDGET（15k token）；
##   - 全量 231 工具 ≤ FULL_SET_TOKEN_BUDGET（60k token）。
## 预算值基于实测数据设定（见 test_tool_definitions_within_token_budget 的运行
## 输出）。若未来新增工具描述过长导致超限，须先登记进 KNOWN_OVER_BUDGET_TOOLS
## （注明原因），并将描述精简列为单独工作项；禁止直接放宽预算。
const TOOL_TOKEN_BUDGET: int = 400
const DEFAULT_SET_TOKEN_BUDGET: int = 15000
const FULL_SET_TOKEN_BUDGET: int = 60000

## 超限豁免清单（应尽量保持为空；见 TOOL_TOKEN_BUDGET 注释）。
## 登记格式：{"tool_name": "超限原因（仍须单独安排描述精简）"}
## 当前 8 个：均为预算门禁建立前已存在的复杂编排/生成/导出工具（长描述 +
## 富参数 schema，实测 458–1191 token）。400 是 DSH 研究（docs/research/
## dsh-tool-token-economy-study.md §3.1 建议 B）建议的单工具预算，保留作为
## 回归线；这 8 个的描述/参数精简是独立工作项，禁止通过放宽预算来掩盖。
const KNOWN_OVER_BUDGET_TOOLS: Dictionary = {
	"generate_asset": "资产生成：~1.6KB 描述 + 20 参数（历史基线，待精简）",
	"manage_task_plan": "任务图编排：~1.8KB 描述 + 富参数（历史基线，待精简）",
	"generate_3d_asset": "文生 3D：~1.4KB 描述 + 富参数（历史基线，待精简）",
	"slice_sprite_sheet": "精灵图切片：富参数 schema（历史基线，待精简）",
	"manage_localization": "本地化工作流：长描述 + 富参数（历史基线，待精简）",
	"configure_android_export": "Android 导出配置：富参数 schema（历史基线，待精简）",
	"assert_visual_baseline": "视觉回归门禁：富参数 schema（历史基线，待精简）",
}

## 值为“名称 -> 子 schema”映射的容器关键字。
const SCHEMA_MAP_KEYWORDS: Array[String] = [
	"properties", "patternProperties", "$defs", "definitions",
	"dependentSchemas", "dependentRequired",
]

## 值为单个子 schema（或 boolean/数组）的容器关键字。
const SCHEMA_SINGLE_KEYWORDS: Array[String] = [
	"items", "contains", "additionalProperties", "propertyNames",
	"unevaluatedItems", "unevaluatedProperties", "if", "then", "else", "not",
]

## 值为子 schema 数组的容器关键字。
const SCHEMA_ARRAY_KEYWORDS: Array[String] = [
	"oneOf", "anyOf", "allOf", "prefixItems",
]

var _core: RefCounted = null
var _tools: Dictionary = {}
var _keyword_counts: Dictionary = {}        # keyword -> 出现次数
var _violations: Array[String] = []         # "tool (input/output): 'keyword'"
var _non_string_keys: Array[String] = []
var _malformed_subschemas: Array[String] = []
var _input_oneof: Array[String] = []
var _output_oneof: Array[String] = []
var _module_load_failures: Array[String] = []
var _module_instances: Array[RefCounted] = []
var _props_no_desc: Array[String] = []      # "tool -> prop"（无 description 且无 enum/const/items）
var _top_props_total: int = 0


func before_all() -> void:
	_core = load("res://addons/godot_mcp/native_mcp/mcp_server_core.gd").new()
	for path in TOOL_MODULE_PATHS:
		var script: GDScript = load(path)
		if script == null:
			_module_load_failures.append(path)
			continue
		var instance: RefCounted = script.new()
		instance.register_tools(_core)
		# Registered callables are bound to their module instances. Keep those
		# instances alive so registry-level tests exercise the complete catalog.
		_module_instances.append(instance)
	_tools = _core.get_all_tools()
	_scan_all_schemas()


func after_all() -> void:
	# 解除工具注册表对（绑定到模块实例的）callable 的引用，打破 RefCounted
	# 循环（meta 模块持有 _server_core），避免 headless 退出时 ObjectDB 泄漏告警。
	if _core != null:
		var names: Array = _core.get_all_tools().keys()
		for name in names:
			_core.unregister_tool(name)
	_tools = {}
	_module_instances.clear()
	_core = null


# ----------------------------------------------------------------------------
# 扫描逻辑
# ----------------------------------------------------------------------------

func _scan_all_schemas() -> void:
	var tool_names: Array = _tools.keys()
	tool_names.sort()
	for tool_name in tool_names:
		var tool = _tools[tool_name]
		_collect_schema_keywords(tool.input_schema, tool_name, "input")
		_collect_schema_keywords(tool.output_schema, tool_name, "output")
	_scan_top_level_descriptions()


## 递归收集 schema 中所有“schema 位置”的 key（属性名等非 schema 位置不会误入）。
func _collect_schema_keywords(schema: Variant, tool_name: String, kind: String) -> void:
	if typeof(schema) != TYPE_DICTIONARY:
		if schema != {}:
			_malformed_subschemas.append("%s (%s): schema 不是 Dictionary: %s" % [tool_name, kind, str(schema)])
		return
	_collect_schema_keys(schema, tool_name, kind)


func _collect_schema_keys(schema: Dictionary, tool_name: String, kind: String) -> void:
	for key in schema.keys():
		if typeof(key) != TYPE_STRING:
			_non_string_keys.append("%s (%s): %s" % [tool_name, kind, str(key)])
			continue
		var kw: String = key
		_keyword_counts[kw] = _keyword_counts.get(kw, 0) + 1
		if not ALLOWED_SCHEMA_KEYWORDS.has(kw):
			_violations.append("%s (%s): '%s'" % [tool_name, kind, kw])
		if kind == "input" and (kw == "oneOf" or kw == "anyOf"):
			_input_oneof.append(tool_name + " -> " + kw)
		if kind == "output" and (kw == "oneOf" or kw == "anyOf"):
			_output_oneof.append(tool_name + " -> " + kw)

	# 名称 -> 子 schema 容器：递归进入每个子 schema。
	for kw in SCHEMA_MAP_KEYWORDS:
		if schema.has(kw):
			var value: Variant = schema[kw]
			if typeof(value) == TYPE_DICTIONARY:
				for sub in (value as Dictionary).values():
					if typeof(sub) == TYPE_DICTIONARY:
						_collect_schema_keys(sub, tool_name, kind)
					elif typeof(sub) != TYPE_BOOL and sub != null:
						_malformed_subschemas.append("%s (%s): %s 的子项不是 Dictionary: %s" % [tool_name, kind, kw, str(typeof(sub))])
			elif typeof(value) != TYPE_DICTIONARY:
				_malformed_subschemas.append("%s (%s): %s 不是 Dictionary: %s" % [tool_name, kind, kw, str(typeof(value))])

	# 单个子 schema 容器。
	for kw in SCHEMA_SINGLE_KEYWORDS:
		if schema.has(kw):
			var v: Variant = schema[kw]
			if typeof(v) == TYPE_DICTIONARY:
				_collect_schema_keys(v, tool_name, kind)
			elif typeof(v) == TYPE_ARRAY:
				for item in v:
					if typeof(item) == TYPE_DICTIONARY:
						_collect_schema_keys(item, tool_name, kind)

	# 子 schema 数组容器。
	for kw in SCHEMA_ARRAY_KEYWORDS:
		if schema.has(kw) and typeof(schema[kw]) == TYPE_ARRAY:
			for item in schema[kw]:
				if typeof(item) == TYPE_DICTIONARY:
					_collect_schema_keys(item, tool_name, kind)


## 统计每个工具 input_schema 顶层 properties 的 description 覆盖情况
## （软规则：每个属性要么有 description，要么有 enum/const/items）。
func _scan_top_level_descriptions() -> void:
	var tool_names: Array = _tools.keys()
	tool_names.sort()
	for tool_name in tool_names:
		var ins: Variant = _tools[tool_name].input_schema
		if typeof(ins) != TYPE_DICTIONARY or typeof(ins.get("properties", null)) != TYPE_DICTIONARY:
			continue
		var props: Dictionary = ins["properties"]
		for pname in props.keys():
			_top_props_total += 1
			var p: Variant = props[pname]
			if typeof(p) != TYPE_DICTIONARY:
				continue
			var has_desc: bool = p.has("description") and str(p.get("description", "")).length() > 0
			var has_enum: bool = p.has("enum") or p.has("const") or p.has("items")
			if not has_desc and not has_enum:
				_props_no_desc.append(tool_name + " -> " + str(pname))


# ----------------------------------------------------------------------------
# 测试
# ----------------------------------------------------------------------------

## 健全性：全部工具模块可加载并注册，且与分类器口径一致。
func test_all_tool_modules_load_and_register() -> void:
	assert_eq(_module_load_failures.size(), 0, "工具模块加载失败: " + str(_module_load_failures))
	assert_true(_tools.size() >= MIN_TOOL_COUNT, "应注册至少 %d 个工具（实际 %d）" % [MIN_TOOL_COUNT, _tools.size()])
	# 分类器已知的工具必须都出现在 server_core 注册表里（schema 都被扫描覆盖）。
	var classifier = load("res://addons/godot_mcp/native_mcp/mcp_tool_classifier.gd").new()
	var classifier_tools: Array = classifier.get_all_tools()
	var missing: Array[String] = []
	for name in classifier_tools:
		if not _tools.has(name):
			missing.append(str(name))
	assert_eq(missing.size(), 0, "分类器已知但未注册的工具: " + str(missing))
	assert_eq(_tools.size(), classifier_tools.size(), "server_core 与分类器工具数应一致（core=%d, classifier=%d）" % [_tools.size(), classifier_tools.size()])


## 核心断言：全部工具 schema 中出现的所有关键字都在允许白名单内。
func test_all_tool_schemas_only_use_allowed_keywords() -> void:
	var sorted_counts: Array = _keyword_counts.keys()
	sorted_counts.sort()
	var usage: String = ", ".join(sorted_counts.map(func(k): return "%s=%d" % [k, _keyword_counts[k]]))
	print("[SchemaLint] 实际用到的关键字（%d 个）：%s" % [sorted_counts.size(), usage])
	var sorted_violations: Array = _violations.duplicate()
	sorted_violations.sort()
	assert_eq(_violations.size(), 0, "schema 中出现白名单外关键字（%d 处）：%s" % [_violations.size(), str(sorted_violations)])


## schema 的所有 key 必须是字符串（JSON Schema 要求）。
func test_no_non_string_schema_keys() -> void:
	assert_eq(_non_string_keys.size(), 0, "schema 中出现非字符串 key: " + str(_non_string_keys))


## 每个子 schema 都必须是 Dictionary（properties/items 值不允许标量）。
func test_no_malformed_subschemas() -> void:
	assert_eq(_malformed_subschemas.size(), 0, "畸形子 schema: " + str(_malformed_subschemas))


## MCP 约定：每个工具的 input_schema 是 {type:"object", properties:{...}}。
func test_schema_is_object_with_properties() -> void:
	var bad: Array[String] = []
	var tool_names: Array = _tools.keys()
	tool_names.sort()
	for tool_name in tool_names:
		var ins: Variant = _tools[tool_name].input_schema
		if typeof(ins) != TYPE_DICTIONARY \
				or ins.get("type", "") != "object" \
				or typeof(ins.get("properties", null)) != TYPE_DICTIONARY:
			bad.append(tool_name + " -> " + str(ins.get("type", "<missing>")) if typeof(ins) == TYPE_DICTIONARY else tool_name + " -> 非 Dictionary")
	assert_eq(bad.size(), 0, "input_schema 不符合 {type:object, properties:{...}} 的工具: " + str(bad))


func test_enable_tools_schema_exposes_one_call_workflow_activation() -> void:
	assert_true(_tools.has("enable_tools"), "enable_tools 应保持为常驻元工具")
	var properties: Dictionary = _tools["enable_tools"].input_schema.get("properties", {})
	assert_true(properties.has("workflow_query"), "ChatGPT 应能直接提交自然语言任务目标")
	assert_true(properties.has("replace_supplementary"), "客户端应能显式选择任务替换或增量装载")
	assert_eq(properties.get("replace_supplementary", {}).get("default", false), true,
		"默认替换旧任务工具以限制后续 tools/list 大小")


## 官方建议 inputSchema 避免 oneOf/anyOf（部分客户端不兼容）；outputSchema 允许。
func test_no_oneof_in_input_schema() -> void:
	var sorted_input: Array = _input_oneof.duplicate()
	sorted_input.sort()
	assert_eq(_input_oneof.size(), 0, "input_schema 中出现 oneOf/anyOf（%d 处）：%s" % [_input_oneof.size(), str(sorted_input)])
	print("[SchemaLint] output_schema 中的 oneOf/anyOf（%d 处）：%s" % [_output_oneof.size(), str(_output_oneof)])


## 风险关键字门禁：RISKY_FOR_STRICT_CLIENTS 中任何关键字一旦被使用，
## 必须显式登记进 KNOWN_RISKY_KEYWORD_EXEMPTIONS（注释说明 Copilot 风险）。
## 当前唯一豁免：default（历史基线 250+ 处）。
func test_no_new_risky_keyword_categories() -> void:
	var unexempted: Array[String] = []
	for kw in RISKY_FOR_STRICT_CLIENTS:
		if _keyword_counts.get(kw, 0) > 0 and not KNOWN_RISKY_KEYWORD_EXEMPTIONS.has(kw):
			unexempted.append("%s=%d" % [kw, _keyword_counts[kw]])
	unexempted.sort()
	assert_eq(unexempted.size(), 0, "出现未豁免的 Copilot 风险关键字: " + str(unexempted))
	print("[SchemaLint] 风险关键字使用情况：" + _risky_usage_summary())


## 软断言（提示性）：input_schema 顶层 properties 的 description 覆盖率。
## 当前基线 ≈ 74%（缺口多为 debug/runtime 工具的自明参数）。
func test_all_properties_have_description() -> void:
	assert_true(_top_props_total > 0, "应扫描到顶层 properties")
	var covered: int = _top_props_total - _props_no_desc.size()
	var coverage: float = float(covered) / float(_top_props_total)
	print("[SchemaLint] description 覆盖率：%d/%d (%.1f%%)；无 description 且无 enum/const/items 的属性 %d 个" % [covered, _top_props_total, coverage * 100.0, _props_no_desc.size()])
	var samples: Array = _props_no_desc.duplicate()
	samples.sort()
	if samples.size() > 30:
		samples = samples.slice(0, 30)
		print("[SchemaLint] 无 description 属性示例（前 30 条）：" + str(samples))
	else:
		print("[SchemaLint] 无 description 属性：" + str(samples))
	assert_true(coverage >= MIN_DESCRIPTION_COVERAGE, "description 覆盖率 %.1f%% 低于阈值 %.0f%%" % [coverage * 100.0, MIN_DESCRIPTION_COVERAGE * 100.0])


## token 预算门禁：工具定义的上下文体积不失控（DSH token-meter 口径，
## 工具 schema 每轮全额计费）。三档预算：单工具 / 默认启用集 / 全量。
## 每次运行都打印实测数据（per-tool 最大/平均、默认集、全量、顶部最肥工具），
## 作为回归对照表；预算调整须基于这些实测值，并优先保持豁免清单为空。
func test_tool_definitions_within_token_budget() -> void:
	var estimator: GDScript = load("res://addons/godot_mcp/utils/token_estimator.gd")
	assert_true(estimator != null, "MCPTokenEstimator 应可加载")
	var classifier = load("res://addons/godot_mcp/native_mcp/mcp_tool_classifier.gd").new()
	var per_tool: Dictionary = {}          # tool_name -> 估算 token
	var over_budget: Array[String] = []
	var default_total: int = 0
	var default_count: int = 0
	var full_total: int = 0
	var tool_names: Array = _tools.keys()
	tool_names.sort()
	for tool_name in tool_names:
		var tool = _tools[tool_name]
		var est: int = estimator.estimate_tool_definition(tool.name, tool.description, tool.input_schema)
		per_tool[tool_name] = est
		full_total += est
		var category: String = classifier.get_tool_category(str(tool_name))
		if category == "core" or category == "meta":
			default_total += est
			default_count += 1
		if est > TOOL_TOKEN_BUDGET and not KNOWN_OVER_BUDGET_TOOLS.has(tool_name):
			over_budget.append("%s=%d" % [tool_name, est])
	over_budget.sort()
	# 诊断：per-tool 最大/平均、默认集、全量、顶部最肥工具。
	var max_est: int = 0
	var max_name: String = ""
	var sum_est: int = 0
	for tool_name in tool_names:
		var e: int = per_tool[tool_name]
		sum_est += e
		if e > max_est:
			max_est = e
			max_name = str(tool_name)
	var avg_est: float = float(sum_est) / float(maxi(1, tool_names.size()))
	print("[TokenBudget] 全量 %d 工具：总估算 %d token（预算 %d）；per-tool 最大 %d (%s)、平均 %.1f" % [tool_names.size(), full_total, FULL_SET_TOKEN_BUDGET, max_est, max_name, avg_est])
	print("[TokenBudget] 默认启用集（core+meta）%d 工具：总估算 %d token（预算 %d）" % [default_count, default_total, DEFAULT_SET_TOKEN_BUDGET])
	print("[TokenBudget] 估算最大的 10 个工具：" + str(_top_n_tools(per_tool, 10)))
	assert_eq(default_count, 34, "默认启用集应为 28 core + 6 meta = 34，实际 %d（分类器口径变化需同步本断言）" % default_count)
	assert_eq(over_budget.size(), 0, "超单工具预算（%d token）的工具 %d 个（登记 KNOWN_OVER_BUDGET_TOOLS 或精简描述）：%s" % [TOOL_TOKEN_BUDGET, over_budget.size(), str(over_budget)])
	assert_true(default_total <= DEFAULT_SET_TOKEN_BUDGET, "默认启用集总估算 %d 超预算 %d" % [default_total, DEFAULT_SET_TOKEN_BUDGET])
	assert_true(full_total <= FULL_SET_TOKEN_BUDGET, "全量总估算 %d 超预算 %d" % [full_total, FULL_SET_TOKEN_BUDGET])


func test_registered_schema_costs_match_budget_estimator() -> void:
	var registered_costs: Dictionary = {}
	for info_value in _core.get_registered_tools():
		var info: Dictionary = info_value
		registered_costs[String(info.get("name", ""))] = int(info.get("schema_tokens", 0))
	assert_eq(registered_costs.size(), _tools.size(), "每个注册工具都应有不可变 schema 成本")
	for tool_name in _tools:
		var tool = _tools[tool_name]
		var expected: int = TOKEN_ESTIMATOR.estimate_tool_definition(
			tool.name, tool.description, tool.input_schema)
		assert_eq(int(registered_costs.get(tool_name, 0)), expected,
			"路由和预算门禁必须共享同一 token 口径: " + String(tool_name))


func test_cost_aware_workflow_avoids_most_full_load_schema_tokens() -> void:
	var router: RefCounted = WORKFLOW_ROUTER.new()
	var routing_hints: Dictionary = TRANSLATION_MANAGER.new().load_locale("zh")
	var route: Dictionary = router.route(
		"debug runtime errors and verify performance",
		_core.get_registered_tools(), 8, _core.get_tool_registry_revision(), routing_hints)
	assert_lte(int(route.get("tool_count", 999)), 8, "真实目录路线仍受工具预算约束")
	assert_gte(float(route.get("estimated_token_savings_ratio", 0.0)), 0.90,
		"真实 231 工具目录的典型路线应避免至少 90% 的补充 schema token")
	assert_gt(int(route.get("estimated_full_load_schema_tokens", 0)),
		int(route.get("estimated_added_schema_tokens", 0)), "成本指标必须反映真实目录节省")
	print("[CostAwareRoute] added=%d full=%d savings=%.2f%% tools=%d" % [
		int(route.get("estimated_added_schema_tokens", 0)),
		int(route.get("estimated_full_load_schema_tokens", 0)),
		float(route.get("estimated_token_savings_ratio", 0.0)) * 100.0,
		int(route.get("tool_count", 0)),
	])


# ----------------------------------------------------------------------------
# 辅助
# ----------------------------------------------------------------------------

func _risky_usage_summary() -> String:
	var parts: Array[String] = []
	for kw in RISKY_FOR_STRICT_CLIENTS:
		parts.append("%s=%d" % [kw, _keyword_counts.get(kw, 0)])
	return ", ".join(parts)


## 返回 per_tool（tool_name -> token 估算）中估算最大的前 n 个，格式 ["name=est"]。
func _top_n_tools(per_tool: Dictionary, n: int) -> Array:
	var pairs: Array = []
	for tool_name in per_tool:
		pairs.append({"name": str(tool_name), "est": per_tool[tool_name]})
	pairs.sort_custom(func(a, b): return a["est"] > b["est"])
	var result: Array = []
	for i in mini(n, pairs.size()):
		result.append("%s=%d" % [pairs[i]["name"], pairs[i]["est"]])
	return result
