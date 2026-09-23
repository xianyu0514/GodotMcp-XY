extends "res://addons/gut/test.gd"

## 会话层资源（godot://project/brief、engine/expression-rules、recipes）
## 单测：处理器直调（headless 无插件注册表 => brief 走 unavailable 降级、
## recipes 走空目录），规则资源钉住三条 Expression 禁令与两条运行时语义。

const PluginScript = preload("res://addons/godot_mcp/mcp_server_native.gd")

func test_brief_resource_degrades_honestly_headless() -> void:
	var result: Dictionary = PluginScript._resource_project_brief({})
	assert_true(result.has("contents"))
	var entry: Dictionary = (result.get("contents", [{}])[0]) as Dictionary if result.get("contents", [{}])[0] is Dictionary else {}
	assert_eq(String(entry.get("uri", "")), "godot://project/brief")
	assert_eq(String(entry.get("mimeType", "")), "application/json")
	var parsed: Variant = JSON.parse_string(String(entry.get("text", "")))
	assert_true(parsed is Dictionary, "valid JSON even in degraded mode")
	var body: Dictionary = parsed if parsed is Dictionary else {}
	assert_eq(String(body.get("status", "")), "unavailable",
		"no registry => honest unavailable, not a fake brief")

func test_expression_rules_carry_the_hard_truths() -> void:
	var result: Dictionary = PluginScript._resource_expression_rules({})
	var text: String = String(((result.get("contents", [{}])[0]) as Dictionary).get("text", ""))
	assert_true(text.to_lower().contains("no ternary"), "ternary ban shipped")
	assert_true(text.contains("self"), "self ban shipped")
	assert_true(text.contains("is' operator") or text.contains("'is'"), "is-operator ban shipped")
	assert_true(text.contains("current scene") or text.contains("CURRENT SCENE"), "base semantics shipped")
	assert_true(text.contains("get_shader_parameter") and text.contains("NULL"),
		"null-uniform truth shipped")
	assert_true(text.to_lower().contains("queue_free") and text.to_lower().contains("counter"),
		"death-window guidance shipped")

func test_recipes_resource_is_valid_catalog_headless() -> void:
	var result: Dictionary = PluginScript._resource_recipes({})
	var entry: Dictionary = ((result.get("contents", [{}])[0]) as Dictionary)
	assert_eq(String(entry.get("uri", "")), "godot://recipes")
	var parsed: Variant = JSON.parse_string(String(entry.get("text", "")))
	assert_true(parsed is Dictionary and (parsed as Dictionary).has("recipes"),
		"catalog shape {recipes: [...]}")
	var recipes: Array = (parsed as Dictionary).get("recipes", [])
	assert_eq(recipes.size(), 0, "headless has no workflows instance — empty catalog, valid shape")
