extends "res://addons/gut/test.gd"

# query_engine_compat：引擎 API 兼容知识库的检索与数据完整性。
# 数据来源均为实测（AGENTS.md/goal-playbook/评审实测/CI），见各条 source 字段。

const ProjectToolsScript = preload("res://addons/godot_mcp/tools/project_tools_native.gd")
const KnowledgeScript = preload("res://addons/godot_mcp/native_mcp/engine_compat_knowledge.gd")

var _tools: RefCounted = null

func before_each() -> void:
	_tools = ProjectToolsScript.new()

func after_each() -> void:
	_tools = null

# --- 数据完整性：每条真值必须可追溯且结构完整 ---

func test_entries_have_required_fields_and_unique_ids():
	var seen: Dictionary = {}
	for entry in KnowledgeScript.ENTRIES:
		var entry_id: String = String(entry.get("id", ""))
		assert_false(entry_id.is_empty(), "every entry needs an id")
		assert_false(seen.has(entry_id), "id must be unique: " + entry_id)
		seen[entry_id] = true
		for field in ["api", "aliases", "kind", "versions", "title", "truth", "workaround", "source"]:
			assert_true(entry.has(field), entry_id + " missing field " + field)
		assert_true(KnowledgeScript.KINDS.has(String(entry["kind"])), entry_id + " has unknown kind")
		assert_true(str(entry["source"]).length() > 5, entry_id + " source must be traceable")
	assert_true(KnowledgeScript.ENTRIES.size() >= 20, "knowledge base should stay comprehensive")

func test_versions_filter_omits_other_version_entries():
	var result: Dictionary = _tools._tool_query_engine_compat({"query": "float", "engine_version": "4.6"})
	assert_eq(int(result.get("count", -1)), 0, "float() 陷阱是 4.7 条目，4.6 过滤后不应出现")
	var no_filter: Dictionary = _tools._tool_query_engine_compat({"query": "float"})
	assert_eq(int(no_filter.get("count", 0)), 1, "不过滤时 float() 命中 1 条")
	var universal: Dictionary = _tools._tool_query_engine_compat({"query": "TileMap", "engine_version": "4.6"})
	assert_true(int(universal.get("count", 0)) >= 1, "全版本条目（TileMap）在 4.6 过滤下仍命中")

# --- 检索行为 ---

func test_api_name_exact_hit_outranks_body_hits():
	var result: Dictionary = _tools._tool_query_engine_compat({"query": "float()"})
	assert_eq(int(result.get("count", 0)), 1)
	var top: Dictionary = (result["matches"] as Array)[0]
	assert_eq(String(top["id"]), "gdscript-float-constructor-unavailable")
	assert_true(str(top["workaround"]).contains("as float"), "命中必须带可执行的 workaround")

func test_symptom_keywords_find_traps():
	for query in ["pause", "暂停", "Expression", "闭包", "tilemap", "time_scale", "gselect"]:
		var result: Dictionary = _tools._tool_query_engine_compat({"query": query})
		assert_true(int(result.get("count", 0)) >= 1, "症状词应命中: " + query)

func test_empty_query_returns_overview():
	var result: Dictionary = _tools._tool_query_engine_compat({})
	assert_true(result.has("overview"))
	var kinds: Dictionary = result["overview"]["kinds"]
	assert_true(int(kinds.get("api", 0)) >= 6, "api 类条目应占主体")
	assert_eq(int(result["total_entries"]), KnowledgeScript.ENTRIES.size())

func test_no_match_returns_self_healing_hint():
	var result: Dictionary = _tools._tool_query_engine_compat({"query": "quantum_entanglement"})
	assert_eq(int(result.get("count", 0)), 0)
	assert_true(result.has("hint"))
	assert_true(str(result["hint"]).contains("float()"), "提示应列出可检索的 api 名供重试")

func test_limit_bounds_result_size():
	var result: Dictionary = _tools._tool_query_engine_compat({"query": "the", "limit": 3})
	assert_true(int(result.get("count", 0)) <= 3, "limit 应约束返回条数")

func test_query_is_deterministic():
	var first: Dictionary = _tools._tool_query_engine_compat({"query": "expression"})
	var ids_first: Array = []
	for m in first["matches"]:
		ids_first.append(String(m["id"]))
	var second: Dictionary = _tools._tool_query_engine_compat({"query": "expression"})
	var ids_second: Array = []
	for m in second["matches"]:
		ids_second.append(String(m["id"]))
	assert_eq(ids_first, ids_second, "同查询两次结果必须一致（排序确定性）")
