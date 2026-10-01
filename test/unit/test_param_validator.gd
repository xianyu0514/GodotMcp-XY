extends "res://addons/gut/test.gd"

# P1-11 回归（2026-09-30 体检 §12.3）：此前同一类型错误在 6 个工具上产生
# 4 种失败模式（静默忽略 / 运行时崩溃 / 带警告照跑 / 无一正确报错）。
# 校验层 = 分发前按 input_schema 结构化拒绝（-32602 语义）。

const ServerCoreScript = preload("res://addons/godot_mcp/native_mcp/mcp_server_core.gd")

const SCHEMA: Dictionary = {
	"type": "object",
	"properties": {
		"limit": {"type": "integer", "default": 100},
		"ratio": {"type": "number"},
		"mode": {"type": "string", "enum": ["fast", "slow"]},
		"enabled": {"type": "boolean"},
		"tags": {"type": "array"},
		"meta": {"type": "object"},
		"note": {"type": "string"}
	}
}

func test_type_mismatch_is_structurally_rejected():
	var errors: Array = ServerCoreScript._validate_arguments_against_schema(
		"tool_x", SCHEMA, {"limit": "abc"})
	assert_eq(errors.size(), 1)
	var message: String = str(errors[0])
	assert_true(message.contains("limit"), "错误必须指明参数名")
	assert_true(message.contains("integer"), "错误必须指明期望类型")
	assert_true(message.contains("string"), "错误必须指明实际类型")

func test_integer_accepts_integral_float():
	var errors: Array = ServerCoreScript._validate_arguments_against_schema(
		"tool_x", SCHEMA, {"limit": 3000.0})
	assert_eq(errors.size(), 0, "JS 客户端整值浮点必须容忍")
	var fraction: Array = ServerCoreScript._validate_arguments_against_schema(
		"tool_x", SCHEMA, {"limit": 3000.5})
	assert_eq(fraction.size(), 1, "非整值浮点必须拒绝")

func test_number_accepts_integer():
	var errors: Array = ServerCoreScript._validate_arguments_against_schema(
		"tool_x", SCHEMA, {"ratio": 3})
	assert_eq(errors.size(), 0, "int 当 number 用必须容忍")

func test_enum_rejection_lists_allowed_values():
	var errors: Array = ServerCoreScript._validate_arguments_against_schema(
		"tool_x", SCHEMA, {"mode": "turbo"})
	assert_eq(errors.size(), 1)
	var message: String = str(errors[0])
	assert_true(message.contains("fast") and message.contains("slow"), "错误应列出合法取值")

func test_bool_array_object_string_types_enforced():
	assert_eq(ServerCoreScript._validate_arguments_against_schema("t", SCHEMA, {"enabled": "yes"}).size(), 1)
	assert_eq(ServerCoreScript._validate_arguments_against_schema("t", SCHEMA, {"tags": "x"}).size(), 1)
	assert_eq(ServerCoreScript._validate_arguments_against_schema("t", SCHEMA, {"meta": 7}).size(), 1)
	assert_eq(ServerCoreScript._validate_arguments_against_schema("t", SCHEMA, {"note": 5}).size(), 1)

func test_valid_args_pass_and_unknown_keys_ignored():
	assert_eq(ServerCoreScript._validate_arguments_against_schema(
		"t", SCHEMA, {"limit": 5, "mode": "fast", "note": "ok", "_meta": {"x": 1}}).size(), 0,
		"合法参数 + 扩展键应放行")

func test_bool_is_not_integer():
	# JSON 里 true/false 不是 0/1——类型系统必须区分
	var errors: Array = ServerCoreScript._validate_arguments_against_schema(
		"t", SCHEMA, {"limit": true})
	assert_eq(errors.size(), 1)

func test_non_dict_schema_is_passthrough():
	assert_eq(ServerCoreScript._validate_arguments_against_schema("t", {}, {"limit": "x"}).size(), 0,
		"无 schema 的工具不拦（向后兼容）")

# --- P1-12 别名折叠 ---

func test_alias_folds_into_canonical_when_schema_declares_it():
	var schema: Dictionary = {"type": "object", "properties": {"limit": {"type": "integer"}}}
	var folded: Dictionary = ServerCoreScript._canonicalize_param_aliases(
		schema, {"count": 5})
	assert_eq(int(folded["args"]["limit"]), 5, "count 别名应折叠到 limit")
	assert_eq(String(folded["applied"]["count"]), "limit", "折叠必须可观测")

func test_no_fold_when_both_canonical_and_alias_present():
	var schema: Dictionary = {"type": "object", "properties": {"limit": {"type": "integer"}}}
	var folded: Dictionary = ServerCoreScript._canonicalize_param_aliases(
		schema, {"limit": 10, "count": 5})
	assert_eq(int(folded["args"]["limit"]), 10, "正名已给时以正名为准")
	assert_eq(int(folded["applied"].size()), 0)

func test_no_fold_for_family_member_absent_from_schema():
	var schema: Dictionary = {"type": "object", "properties": {"count": {"type": "integer"}}}
	var folded: Dictionary = ServerCoreScript._canonicalize_param_aliases(
		schema, {"limit": 5})
	assert_eq(int(folded["args"]["count"]), 5 if false else int(folded["args"].get("count", 0)),
		"schema 未声明 limit 时不得反向折叠")
	assert_eq(int(folded["args"].get("limit", 5)), 5, "原参数保留")

func test_no_fold_without_schema():
	var folded: Dictionary = ServerCoreScript._canonicalize_param_aliases(
		{}, {"count": 5})
	assert_eq(int(folded["args"]["count"]), 5)
	assert_eq(int(folded["applied"].size()), 0)
