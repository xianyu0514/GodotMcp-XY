# token_estimator.gd
# 工具定义 token 估算器 —— 借鉴 DSH token-meter 的启发式计费口径
# （DSH: packages/llm/token-meter/src/estimate.ts —— tokens ≈ 字符数 / 4，
#  文本用 Math.ceil 向上取整；工具 schema 按 JSON.stringify(tools).length / 4 计费）。
# 纯静态工具类：不依赖编辑器环境（headless 可测），不注册任何 MCP 工具，
# 仅用于预算门禁（test/unit/test_tool_schema_lint.gd）与未来的文档/计量。

class_name MCPTokenEstimator
extends RefCounted

## 每 token 的字符数启发式（DSH CHARS_PER_TOKEN = 4）。
const CHARS_PER_TOKEN: int = 4

## 文本 token 估算：max(1, ceil(chars / 4))。
## 与 DSH 一致使用向上取整；任何输入至少计 1 token（保守地板，避免 0 值工具）。
static func estimate_text(text: String) -> int:
	return maxi(1, ceili(float(text.length()) / float(CHARS_PER_TOKEN)))

## JSON 值 token 估算：canonical_json(data).length / 4（向上取整）。
## 先经 canonical_json 递归 key 排序，保证跨运行确定性（Godot Dictionary 无序）。
static func estimate_json(data: Variant) -> int:
	var json: String = canonical_json(data)
	return ceili(float(json.length()) / float(CHARS_PER_TOKEN))

## 单个工具定义的 token 估算：name + description + inputSchema 之和。
## 不含 outputSchema —— 按 DSH 口径模型只可见 name/description/parameters；
## Godot MCP 的 outputSchema 只在 get_tool_details 按需返回，不进 tools/list。
static func estimate_tool_definition(tool_name: String, description: String, input_schema: Dictionary) -> int:
	return estimate_text(tool_name) + estimate_text(description) + estimate_json(input_schema)

## schema 的 canonical 序列化字节数（字符串长度）。
static func estimate_schema_bytes(schema: Dictionary) -> int:
	return canonical_json(schema).length()

## 确定性 JSON 序列化：递归按 key 排序后 JSON.stringify。
## Godot 的 JSON.stringify 按 Dictionary 插入序输出，同一内容的两个不同构造
## 顺序会产生不同字符串；此处先做递归 key 排序（数组保持原序、元素递归处理），
## 保证同一数据跨运行、跨进程得到完全相同的 JSON 文本。
static func canonical_json(data: Variant) -> String:
	return JSON.stringify(_canonicalize(data))

static func _canonicalize(data: Variant) -> Variant:
	match typeof(data):
		TYPE_DICTIONARY:
			var source: Dictionary = data
			var result: Dictionary = {}
			var keys: Array = source.keys()
			keys.sort_custom(_key_less)
			for key in keys:
				result[key] = _canonicalize(source[key])
			return result
		TYPE_ARRAY:
			var result: Array = []
			for item in data:
				result.append(_canonicalize(item))
			return result
		_:
			return data

## key 排序比较器：字符串按字典序；混合类型先按类型码、再按字符串形式，
## 保证任意 key 集合都存在确定的全序（schema 中实际只有字符串 key）。
static func _key_less(a: Variant, b: Variant) -> bool:
	if typeof(a) == TYPE_STRING and typeof(b) == TYPE_STRING:
		return (a as String) < (b as String)
	if typeof(a) == typeof(b):
		return str(a) < str(b)
	return typeof(a) < typeof(b)
