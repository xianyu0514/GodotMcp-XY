extends "res://addons/gut/test.gd"

## K-2 知识分层门禁（docs/ai-capability-spec.md）：配方渲染文本不得
## ① 提及仓库内部项目/夹具（通用配方泄漏本仓库事实）；
## ② 携带未占位符化的既有场景引用（.tscn 必须以 <...> 形式出现——
##    断言用户项目结构是知识注入，占位符让发现层（gather_task_context）负责）。

const WorkflowsScript = preload("res://addons/godot_mcp/native_mcp/prompt_workflows.gd")

## 仓库内部项目/夹具名：出现即泄漏（slice_b 是仓库的验证载体项目，
## 不是插件用户的语境）。
const REPO_FIXTURE_TOKENS: Array[String] = [
	"slice_b", "stress_game", "TestScene", "res://addons/godot_mcp",
]

var _workflows: RefCounted

func before_each() -> void:
	_workflows = WorkflowsScript.new()

func after_each() -> void:
	_workflows = null

## 渲染全部配方（每个必填参数给最小值），返回 [{name, text}]。
func _rendered_recipes() -> Array:
	var rendered: Array = []
	for prompt_value in _workflows.get_prompts():
		var prompt: Dictionary = prompt_value
		var name: String = String(prompt.get("name", ""))
		var args: Dictionary = {}
		for argument_value in prompt.get("arguments", []):
			var argument: Dictionary = argument_value
			if bool(argument.get("required", false)):
				args[String(argument.get("name", "goal"))] = "x"
		# get_prompts() 的返回不带 callable（RPC 形状）；用 get_callable(name) 取执行体。
		var getter: Callable = _workflows.get_callable(name)
		var result: Dictionary = {}
		if getter.is_valid():
			result = await getter.call(args)
		if not result.is_empty():
			var text: String = ""
			for message_value in result.get("messages", []):
				var message: Dictionary = message_value
				if message.get("content", {}) is Dictionary:
					text += String((message.get("content", {}) as Dictionary).get("text", ""))
			rendered.append({"name": name, "text": text})
	return rendered

func test_no_recipe_leaks_repo_internal_fixtures() -> void:
	var rendered: Array = await _rendered_recipes()
	assert_gte(rendered.size(), 21, "all recipes must render")
	var leaks: Array = []
	for entry_value in rendered:
		var entry: Dictionary = entry_value
		for token in REPO_FIXTURE_TOKENS:
			if String(entry.get("text", "")).contains(token):
				leaks.append("%s: %s" % [entry.get("name", "?"), token])
	assert_eq(leaks.size(), 0,
		"K-2: recipes are generic — repo-internal fixtures leaked: %s" % str(leaks))

func test_existing_scene_references_are_placeholders() -> void:
	var rendered: Array = await _rendered_recipes()
	var offenders: Array = []
	for entry_value in rendered:
		var entry: Dictionary = entry_value
		var text: String = String(entry.get("text", ""))
		# 每个 .tscn 出现必须包在 <...> 内：取 ".tscn" 前最近的 '<' 与 '>' 边界判断。
		var search_from: int = 0
		while true:
			var at: int = text.find(".tscn", search_from)
			if at < 0:
				break
			# substr(start, length)：窗口 = [at-200, at+5)，长度是差值而不是结束下标。
			var window_start: int = maxi(0, at - 200)
			var prefix: String = text.substr(window_start, at + 5 - window_start)
			var last_open: int = prefix.rfind("<")
			var last_close: int = prefix.rfind(">")
			var is_placeholder: bool = last_open > last_close
			if not is_placeholder:
				offenders.append("%s: ...%s" % [entry.get("name", "?"), prefix.substr(maxi(0, prefix.length() - 60))])
			search_from = at + 5
	assert_eq(offenders.size(), 0,
		"K-2: existing-scene references must be <placeholders> (project facts belong to gather_task_context, not recipes): %s" % str(offenders))
