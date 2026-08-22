extends "res://addons/gut/test.gd"

# ============================================================================
# test_token_estimator.gd — MCPTokenEstimator 单元测试
#
# 口径：DSH token-meter 启发式（tokens ≈ 字符数 / 4，文本向上取整，
#       工具 schema 按 JSON.stringify(...).length / 4 计费）——
#       addons/godot_mcp/utils/token_estimator.gd（纯静态类，无编辑器依赖）。
# 覆盖：estimate_text / estimate_json / canonical_json / estimate_tool_definition /
#       estimate_schema_bytes 的正常路径、边界与确定性。
# ============================================================================

const TOKEN_ESTIMATOR: GDScript = preload("res://addons/godot_mcp/utils/token_estimator.gd")


# ----------------------------------------------------------------------------
# estimate_text
# ----------------------------------------------------------------------------

func test_estimate_text_empty_string() -> void:
	# 空串：ceil(0/4)=0，但保守地板 max(1, ...) 取 1（与 DSH 风格一致，任何文本至少 1 token）。
	assert_eq(TOKEN_ESTIMATOR.estimate_text(""), 1, "空串应估算为 1 token（地板值）")


func test_estimate_text_single_char() -> void:
	assert_eq(TOKEN_ESTIMATOR.estimate_text("a"), 1, "单字符应估算为 1 token")


func test_estimate_text_short_ascii() -> void:
	# "hello world" = 11 字符 → ceil(11/4) = 3。
	assert_eq(TOKEN_ESTIMATOR.estimate_text("hello world"), 3)


func test_estimate_text_boundaries() -> void:
	# 4 字符 → 1；5 字符 → 2（向上取整，与 DSH 的 Math.ceil 一致）。
	assert_eq(TOKEN_ESTIMATOR.estimate_text("abcd"), 1, "4 字符应估算为 1 token")
	assert_eq(TOKEN_ESTIMATOR.estimate_text("abcde"), 2, "5 字符应向上取整为 2 token")


func test_estimate_text_long_text() -> void:
	# 400 字符 → ceil(400/4) = 100。
	assert_eq(TOKEN_ESTIMATOR.estimate_text("a".repeat(400)), 100, "400 字符应估算为 100 token")


func test_estimate_text_unicode_counted_by_characters() -> void:
	# 中文字符串：GDScript String.length() 按 Unicode 码点计（UTF-32 视角），
	# 40 个汉字 → 40 字符 → ceil(40/4) = 10。
	assert_eq(TOKEN_ESTIMATOR.estimate_text("估".repeat(40)), 10, "40 个字符（含中文）应估算为 10 token")


# ----------------------------------------------------------------------------
# estimate_json
# ----------------------------------------------------------------------------

func test_estimate_json_empty_dict() -> void:
	# "{}" = 2 字符 → ceil(2/4) = 1。
	assert_eq(TOKEN_ESTIMATOR.estimate_json({}), 1, "空字典应估算为 1 token")


func test_estimate_json_small_dict() -> void:
	# {"a":1} canonical 序列化 = 7 字符 → ceil(7/4) = 2。
	assert_eq(TOKEN_ESTIMATOR.estimate_json({"a": 1}), 2, "小字典应估算为 2 token")


func test_estimate_json_nested_structure() -> void:
	var data: Dictionary = {
		"list": [1, 2, {"k": "v"}],
		"n": {"x": true, "y": null},
	}
	var tokens: int = TOKEN_ESTIMATOR.estimate_json(data)
	assert_true(tokens > 0, "嵌套结构估算应 > 0，实际 %d" % tokens)
	# 口径一致性：estimate_json 就是 canonical 字节数 / 4 向上取整。
	assert_eq(tokens, ceili(float(TOKEN_ESTIMATOR.canonical_json(data).length()) / 4.0),
			"estimate_json 应等于 canonical 字节数 / 4 向上取整")


func test_estimate_json_array() -> void:
	# [1,2,3] = 7 字符 → ceil(7/4) = 2。
	assert_eq(TOKEN_ESTIMATOR.estimate_json([1, 2, 3]), 2, "数组应估算为 2 token")


# ----------------------------------------------------------------------------
# canonical_json（确定性）
# ----------------------------------------------------------------------------

func test_canonical_json_key_order_deterministic() -> void:
	var a: Dictionary = {}
	a["z"] = 1
	a["a"] = 2
	a["m"] = 3
	var b: Dictionary = {}
	b["m"] = 3
	b["a"] = 2
	b["z"] = 1
	assert_eq(TOKEN_ESTIMATOR.canonical_json(a), TOKEN_ESTIMATOR.canonical_json(b),
			"不同插入序的字典应产生相同的 canonical JSON")
	assert_eq(TOKEN_ESTIMATOR.canonical_json(a), "{\"a\":2,\"m\":3,\"z\":1}",
			"canonical JSON 应按 key 字典序输出")


func test_canonical_json_nested_sorting() -> void:
	var d1: Dictionary = {"outer": {"b": 1, "a": [3, {"y": 2, "x": 1}]}}
	var d2: Dictionary = {"outer": {"a": [3, {"x": 1, "y": 2}], "b": 1}}
	assert_eq(TOKEN_ESTIMATOR.canonical_json(d1), TOKEN_ESTIMATOR.canonical_json(d2),
			"嵌套字典/数组应递归排序，不同构造顺序结果一致")


func test_canonical_json_mixed_type_keys_deterministic() -> void:
	var a: Dictionary = {1: "int", "a": "str", 2.5: "float"}
	var b: Dictionary = {"a": "str", 2.5: "float", 1: "int"}
	assert_eq(TOKEN_ESTIMATOR.canonical_json(a), TOKEN_ESTIMATOR.canonical_json(b),
			"混合类型 key 也应有确定的全序（类型码 + 字符串形式）")


func test_canonical_json_is_valid_json() -> void:
	var parsed: Variant = JSON.parse_string(TOKEN_ESTIMATOR.canonical_json({"a": [1, 2, {"c": true}]}))
	assert_true(parsed != null, "canonical JSON 必须能被 JSON.parse_string 解析")
	var parsed_dict: Dictionary = parsed
	assert_eq(parsed_dict["a"][2]["c"], true, "解析后结构与原数据一致")


# ----------------------------------------------------------------------------
# estimate_tool_definition
# ----------------------------------------------------------------------------

func test_estimate_tool_definition_small_tool() -> void:
	var name: String = "get_project_info"
	var desc: String = "获取当前项目的名称、版本、渲染器与 Godot 版本等元信息，用于了解项目环境。"
	var schema: Dictionary = {"type": "object", "properties": {}}
	var est: int = TOKEN_ESTIMATOR.estimate_tool_definition(name, desc, schema)
	assert_true(est > 0, "估算应 > 0，实际 %d" % est)
	assert_true(est < 500, "小工具估算应在合理区间（< 500），实际 %d" % est)
	# 口径一致性：name + description + inputSchema 三项之和。
	assert_eq(est, TOKEN_ESTIMATOR.estimate_text(name) + TOKEN_ESTIMATOR.estimate_text(desc)
			+ TOKEN_ESTIMATOR.estimate_json(schema), "估算应等于 name+description+inputSchema 之和")


func test_estimate_tool_definition_output_schema_excluded() -> void:
	# outputSchema 不进估算（模型不可见，仅 get_tool_details 按需返回）——
	# 相同 name/description/input_schema 的工具，output 大小不影响估算值。
	var schema: Dictionary = {"type": "object", "properties": {"path": {"type": "string"}}}
	var est: int = TOKEN_ESTIMATOR.estimate_tool_definition("read_script", "读取脚本文件。", schema)
	# 对比：若把 outputSchema 也算进去，估算会显著更大；这里只验证函数签名不含
	# output 参数（编译期即保证），并验证估算与手算一致。
	assert_eq(est, TOKEN_ESTIMATOR.estimate_text("read_script") + TOKEN_ESTIMATOR.estimate_text("读取脚本文件。")
			+ TOKEN_ESTIMATOR.estimate_json(schema))


# ----------------------------------------------------------------------------
# estimate_schema_bytes
# ----------------------------------------------------------------------------

func test_estimate_schema_bytes_matches_canonical_length() -> void:
	var schema: Dictionary = {"type": "object", "properties": {"a": {"type": "string", "description": "x"}}}
	assert_eq(TOKEN_ESTIMATOR.estimate_schema_bytes(schema),
			TOKEN_ESTIMATOR.canonical_json(schema).length(), "schema 字节数应等于 canonical JSON 长度")


func test_estimate_schema_bytes_deterministic() -> void:
	var s1: Dictionary = {"properties": {"b": 1, "a": 2}, "type": "object"}
	var s2: Dictionary = {"type": "object", "properties": {"a": 2, "b": 1}}
	assert_eq(TOKEN_ESTIMATOR.estimate_schema_bytes(s1), TOKEN_ESTIMATOR.estimate_schema_bytes(s2),
			"同一 schema 的不同构造顺序应得到相同字节数")
