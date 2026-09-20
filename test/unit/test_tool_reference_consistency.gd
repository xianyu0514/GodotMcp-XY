extends "res://addons/gut/test.gd"

# 工具引用一致性门禁（接口漂移防线）：
#   - test_prompt_templates_reference_real_tools：所有 prompt 模板渲染后，
#     {"tool": "X"} 引用的 X 必须存在于 tools_manifest —— AI 按模板执行的每次
#     调用都指向真实注册的工具。
#   - test_prompt_templates_find_references_at_all：抽取逻辑防退化守卫 ——
#     若模板格式变化导致正则全部失配，本测试失败（避免门禁空转通过）。
#   - test_extraction_catches_phantom_tool：阳性对照 —— 人造幽灵工具名必须被
#     判为漂移，证明门禁真的会拦。
#   - test_guide_docs_call_shaped_references_exist：使用向导文档中反引号调用形
#     `tool(...)` 的名字必须是已注册工具或已注册 prompt（引擎 API 白名单除外）。
#
# 背景：release_export_flow 模板曾引用不存在的 inspect_export_preset（真实工具
# 为复数 inspect_export_presets）；本门禁让这类漂移在 CI 就被测试发现，而不是
# 在客户端调用报错后才暴露。

const ManifestScript = preload("res://addons/godot_mcp/native_mcp/tools_manifest.gd")
const PromptWorkflowsScript = preload("res://addons/godot_mcp/native_mcp/prompt_workflows.gd")

# 使用向导类文档（面向 AI 客户端/开发者的入口文档）；变更接口时必须同步这些文件。
const GUIDE_DOC_PATHS: Array[String] = [
	"res://docs/goal-playbook.md",
	"res://docs/getting-started.md",
	"res://README.md",
	"res://README.zh.md",
	"res://docs/tools/README.md",
]

# 文档中反引号调用形允许出现的非 MCP 工具名（Godot 引擎 API，附原因）。
const DOC_ENGINE_API_ALLOWLIST: Dictionary = {
	"load": "Godot built-in function documented in guides",
	"can_instantiate": "GDScript resource method documented in guides",
}

var _tool_ref_regex: RegEx
var _doc_call_regex: RegEx
var _manifest_names: Dictionary = {}
var _workflows: RefCounted


func before_all() -> void:
	_tool_ref_regex = RegEx.create_from_string("\\{\\s*\"tool\"\\s*:\\s*\"([a-z0-9_]+)\"")
	_doc_call_regex = RegEx.create_from_string("`([a-z][a-z0-9_]*)\\(")
	for tool_name in ManifestScript.TOOLS:
		_manifest_names[tool_name] = true
	_workflows = PromptWorkflowsScript.new()


func _render_all_prompts() -> String:
	var combined: String = ""
	for meta in _workflows.get_prompts():
		var args: Dictionary = {}
		for arg in meta.get("arguments", []):
			if bool(arg.get("required", false)):
				args[arg["name"]] = str(arg["name"])
		var result: Dictionary = _workflows.get_callable(str(meta["name"])).call(args)
		if result.has("error"):
			fail_test("prompt '%s' failed to render with placeholder args: %s" % [meta["name"], result["error"]])
			continue
		for message in result.get("messages", []):
			combined += str(message.get("content", {}).get("text", "")) + "\n"
	return combined


func _extract_tool_refs(text: String) -> Array[String]:
	var refs: Array[String] = []
	for match_result in _tool_ref_regex.search_all(text):
		refs.append(String(match_result.get_string(1)))
	return refs


func _prompt_names() -> Dictionary:
	var names: Dictionary = {}
	for meta in _workflows.get_prompts():
		names[str(meta["name"])] = true
	return names


func test_prompt_templates_reference_real_tools() -> void:
	var refs: Array[String] = _extract_tool_refs(_render_all_prompts())
	var drift: Array[String] = []
	for ref in refs:
		if not _manifest_names.has(ref) and not (ref in drift):
			drift.append(ref)
	assert_eq(drift.size(), 0,
		"Prompt templates reference tools missing from tools_manifest: %s" % ", ".join(drift))


func test_prompt_templates_find_references_at_all() -> void:
	var refs: Array[String] = _extract_tool_refs(_render_all_prompts())
	var unique: Dictionary = {}
	for ref in refs:
		unique[ref] = true
	assert_gte(unique.size(), 25,
		"Expected >=25 distinct tool references across prompt templates (got %d); "
		% unique.size() + "if templates changed format, update the extraction regex — an empty match set would make the gate vacuous")


func test_extraction_catches_phantom_tool() -> void:
	var synthetic: String = 'Do it: {"tool": "definitely_not_a_tool", "args": {}}'
	var refs: Array[String] = _extract_tool_refs(synthetic)
	assert_true("definitely_not_a_tool" in refs, "Regex must extract the phantom reference")
	assert_false(_manifest_names.has("definitely_not_a_tool"),
		"Phantom control name must not be in the manifest (gate would never fire)")


func test_guide_docs_call_shaped_references_exist() -> void:
	var prompt_names: Dictionary = _prompt_names()
	var total_calls: int = 0
	var drift: Array[String] = []
	for path in GUIDE_DOC_PATHS:
		var file: FileAccess = FileAccess.open(path, FileAccess.READ)
		if file == null:
			fail_test("Guide doc not readable: %s" % path)
			continue
		var text: String = file.get_as_text()
		file.close()
		for match_result in _doc_call_regex.search_all(text):
			var name: String = String(match_result.get_string(1))
			total_calls += 1
			if not _manifest_names.has(name) and not prompt_names.has(name) \
					and not DOC_ENGINE_API_ALLOWLIST.has(name) and not (name in drift):
				drift.append("%s: `%s(`" % [path, name])
	assert_eq(drift.size(), 0,
		"Guide docs contain call-shaped references to unknown tools: %s" % ", ".join(drift))
	assert_gte(total_calls, 5,
		"Expected >=5 call-shaped references across guide docs (got %d); "
		% total_calls + "if docs changed format, update the extraction regex — an empty match set would make the gate vacuous")
