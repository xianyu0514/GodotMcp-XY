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
#   - 218+ 个工具全部注册成功（7 个工具模块；当前仓库 221 个）
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
	"res://addons/godot_mcp/tools/project_tools_native.gd",
	"res://addons/godot_mcp/tools/meta_tools_native.gd",
]

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

## 工具数下限（历史基线 218；仓库演进中，当前为 221 = 28 核心 + 189 补充 +
## 4 元）。不锁定具体总数，另行校验 server_core 与分类器注册数一致。
const MIN_TOOL_COUNT: int = 218

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


# ----------------------------------------------------------------------------
# 辅助
# ----------------------------------------------------------------------------

func _risky_usage_summary() -> String:
	var parts: Array[String] = []
	for kw in RISKY_FOR_STRICT_CLIENTS:
		parts.append("%s=%d" % [kw, _keyword_counts.get(kw, 0)])
	return ", ".join(parts)
