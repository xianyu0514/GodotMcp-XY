extends RefCounted
## PromptWorkflows — 真实可执行的工作流 prompts（MCP prompts 能力）
##
## 为 MCP 服务器的 `prompts/list` / `prompts/get` 提供一组真实的工作流模板：
## 每个 prompt 都带 arguments 元数据与一个 get_callable（`Callable(args: Dictionary) -> Dictionary`），
## 渲染后返回 `{description?, messages: [{role, content}]}`，其中 content 是给 AI agent 的
## 逐步工具调用指令（含精确的 JSON 工具调用示例，`{{arg}}` 占位符在调用时被参数值替换）。
##
## 独立 RefCounted 类，避免把 mcp_server_native.gd 撑大。注册入口：register_to_server()。

# ============================================================================
# Prompt 模板（英文，与现有工具描述语言一致）
# ============================================================================

const PLAN_GAME_FEATURE_TEMPLATE: String = """
You are executing the "GDD to Task Graph" workflow against the Godot project through MCP tools.
This is an executable workflow template: follow the steps and call the tools in order.

Goal: {{goal}}
GDD / feature summary: {{gdd_summary}}

Step 1 — Initialize the plan:
{"tool": "manage_task_plan", "args": {"action": "init", "goal": "{{goal}}", "reset": false}}
reset:false refuses to overwrite an existing healthy plan; use reset:true only when you
intend to discard the previous plan.

Step 2 — Add tasks with dependencies and gated DoD:
Break the summary into one task per vertical-slice step. Every Definition-of-Done (DoD)
criterion that can be measured objectively carries a "gate"; inherently manual criteria omit it.
{"tool": "manage_task_plan", "args": {"action": "add_task", "task": {"title": "<task title>", "tags": ["<tag>"], "dod": [{"criterion": "<objective criterion>"}]}}}
{"tool": "manage_task_plan", "args": {"action": "add_task", "task": {"title": "<dependent task>", "depends_on": ["<id-of-prerequisite-task>"], "dod": [{"criterion": "<runs without runtime errors>", "gate": {"type": "no_runtime_errors", "max_errors": 0}}, {"criterion": "<holds frame budget>", "gate": {"type": "performance_budget", "budget": {"min_fps": 55, "max_memory_mb": 200}}}, {"criterion": "<matches golden baseline>", "gate": {"type": "visual_baseline", "max_diff_ratio": 0.005}}]}}}

Gate cheat-sheet: performance_budget (budget: min_fps >=, max_frame_time_ms / max_memory_mb / max_node_count ... <=),
no_runtime_errors (max_errors, default 0), visual_baseline (max_diff_pixels and/or max_diff_ratio).
A missing observed metric counts as a failure — you can't prove it, so it isn't met.

Step 3 — Verify the graph is sound:
{"tool": "manage_task_plan", "args": {"action": "get"}}
Confirm: no cycle error, every depends_on resolves, and progress totals look right.

Step 4 — Hand off to execution:
{"tool": "manage_task_plan", "args": {"action": "next"}}
next returns dependency-ready tasks plus blocked tasks and progress. Take the first ready
task and run the single-slice loop (execute -> run -> verify -> fix) on it.

Done when: a persisted plan exists at res://.mcp/task_plan.json, every measurable DoD
criterion has a gate, get reports no cycles, and next returns at least one ready task.
"""

const DEBUG_RUNTIME_ERROR_TEMPLATE: String = """
You are executing the "Runtime Error Debugging" workflow against the Godot project through MCP tools.
This is an executable workflow template: follow the loop and call the tools in order.

Reported error:
{{error_text}}
{{context_block}}

1. Collect — {"tool": "get_editor_logs", "args": {"source": "runtime"}} (and {"source": "editor_panel"} if needed):
   pull recent logs and locate the stack frames that mention the error above.
2. Locate — {"tool": "read_script", "args": {"script_path": "<path from the stack trace>"}}:
   read the offending script around the reported line.
3. Diagnose — {"tool": "validate_script", "args": {"script_path": "<script path>"}}:
   confirm there are no parse errors, then identify the root cause (null instance, wrong
   type, out-of-range access, missing signal connection, ...).
4. Fix — apply the smallest coherent edit to the script (write_script / execute_editor_script).
   Keep the change backward compatible and consistent with project conventions.
5. Re-verify — re-run validate_script on the edited script, then {"tool": "run_project", "args": {}}
   and pull get_editor_logs again. Confirm the original error is gone and no new error appeared.
6. If the error persists or a new one appears, loop back to step 2 with the newest log output.

Stop and ask a human only if the fix would require a design decision or would remove safety/auth controls.
"""

const REVIEW_SCENE_TEMPLATE: String = """
You are executing the "Scene Structure Review" workflow against the Godot project through MCP tools.
This is an executable workflow template: call the tools in order and report findings.

{{focus_block}}

1. {"tool": "get_scene_structure", "args": {"max_depth": -1}} — read the full scene tree of the
   currently open scene: node types, names, hierarchy.
2. {"tool": "list_nodes", "args": {"recursive": true}} — enumerate nodes for a flat checklist
   (use parent_path to zoom into a subtree, limit to bound the response).
3. {"tool": "audit_scene_node_persistence", "args": {}} — find nodes whose owner/persistence
   state is missing or invalid (affects scene saving and inheritance).
4. {"tool": "audit_scene_inheritance", "args": {}} — classify local nodes, instance roots and
   local additions inside instanced subtrees; report mismatch problems.

Deliver a structured review: tree summary (total nodes, max depth), suspicious nodes,
persistence/inheritance issues, and a prioritized fix list with the smallest safe edit for each.
"""

const RUN_TEST_SUITE_TEMPLATE: String = """
You are executing the "Run Test Suite" workflow against the Godot project through MCP tools.
This is an executable workflow template: call the tools in order.

{{target_dir_block}}

1. Discover — {"tool": "list_project_tests", "args": {"search_path": "{{target_dir}}"}} —
   list Python integration tests and GUT unit tests, including whether each is runnable.
2. Run — {"tool": "run_project_tests", "args": {"search_path": "{{target_dir}}", "only_runnable": true}} —
   the first call returns status "pending"; call again with the same arguments to poll until
   the aggregated result arrives (total_count / passed_count / failed_count / skipped_count).
3. Collect structured results — summarize the aggregate counts, then list every failure with
   its test path and reported message.
4. For each failure, run the runtime-error debugging workflow on the reported message, then
   re-run the affected test ({"tool": "run_project_test", "args": {"test_path": "<path>"}})
   until it passes.
"""

const VISUAL_PLAYTEST_TEMPLATE: String = """
You are executing the "Visual Playtest" workflow against the Godot project through MCP tools.
This is an executable workflow template: run the loop and call the tools in order.

Scenario: {{scenario}}

1. Launch — {"tool": "run_project", "args": {}} — start the game (optionally pass scene_path
   to run a specific scene).
2. Probe — {"tool": "install_runtime_probe", "args": {}} — the first call returns "pending";
   call again to get the cached response before proceeding.
3. Drive — {"tool": "play_and_verify", "args": {"steps": [{"action": "<input action>", "wait_frames": 30, "screenshot": true}], "assertions": [{"expression": "<runtime expression>", "description": "<what to check>"}], "deterministic": true}} —
   script the scenario inputs, screenshot the result frame, and evaluate runtime assertions.
   Set fail_on_runtime_error true (default) so captured errors fail the report.
4. Compare — {"tool": "assert_visual_baseline", "args": {"candidate_path": "<screenshot path>", "baseline_path": "<golden path>", "max_diff_ratio": 0.005}} —
   if the baseline file is missing it is bootstrapped from the candidate and the gate passes;
   otherwise the diff metrics (diff_pixel_count / diff_ratio / rmse) decide the verdict.
5. Verdict — the playtest passes only if every assertion holds, no runtime errors were captured,
   and the diff is within tolerance. On failure, identify the smallest visual cause, patch it,
   and re-run steps 3-4 until the gate passes.
"""

const ONBOARD_NEW_PROJECT_TEMPLATE: String = """
You are executing the "New Project Onboarding" workflow against the Godot project through MCP tools.
This is an executable workflow template: call the tools in order.

1. {"tool": "get_project_info", "args": {}} — project name, version, renderer, main scene, feature tags.
2. {"tool": "get_project_structure", "args": {"max_depth": 3}} — folder layout and file-type statistics.
3. {"tool": "list_tool_catalog", "args": {}} — discover the full tool catalog: which groups exist
   and which are currently enabled.
4. {"tool": "enable_tools", "args": {"groups": ["<needed groups>"]}} — enable only the groups the
   upcoming work needs (start from the core baseline; core and meta tools always stay enabled).

Deliver a concise onboarding brief: what the project is, its structure, autoloads and conventions
you noticed, available tooling, and a recommended first task.
"""

const FIX_COMPILE_ERRORS_TEMPLATE: String = """
You are executing the "Fix Compile Errors" workflow against the Godot project through MCP tools.
This is an executable workflow template: run the loop until validation is clean.

Script paths: {{script_paths_block}}

1. Validate — for each path: {"tool": "validate_script", "args": {"script_path": "<path>"}} —
   collect structured errors with line numbers (and warnings).
2. Read — {"tool": "read_script", "args": {"script_path": "<path>"}} — read the script around
   each reported error line to understand the failing construct.
3. Fix — apply the smallest coherent edit (write_script / execute_editor_script), keeping the
   change backward compatible and consistent with project conventions.
4. Re-validate — re-run validate_script on the edited script until it reports valid with no errors.
5. Check for cascade — validate any scripts that depend on the fixed one, then run the project
   and pull {"tool": "get_editor_logs", "args": {"source": "runtime"}} to confirm no new errors appeared.
"""

# ============================================================================
# Prompt 注册表
# ============================================================================

const ITERATE_PLAY_VERIFY_TEMPLATE: String = """
You are executing the "Iterate: Play, Verify, Fix" loop against the Godot project through MCP tools.
Repeat the loop until every gate passes or you have isolated a root cause you cannot fix.

Target: {{target}}
Gates: {{gates}}

1. Play — {"tool": "run_project", "args": {"scene_path": "<scene if not the main scene>"}}.
   For an orchestrated one-shot, {"tool": "play_and_verify"} already runs, samples and gates.
2. Observe — {"tool": "get_editor_logs", "args": {"source": "runtime"}} for errors;
   {"tool": "get_runtime_info"} and {"tool": "evaluate_runtime_expression", "args": {"expression": "<state to check>"}}
   for live state while the game runs.
3. Gate — {"tool": "assert_no_runtime_errors", "args": {"max_errors": 0}} and, when a frame
   budget applies, {"tool": "assert_performance_budget", "args": {"budget": {"min_fps": 55}}}.
   Scenario-specific expectations: {"tool": "assert_runtime_condition", "args": {"expression": "<expr>"}}.
4. Fix — when a gate fails, read the reported error/state, patch the smallest coherent cause
   (script or scene edit), stop with {"tool": "stop_project"}, and restart from step 1.
5. Cap — after 3 consecutive identical failures with no progress, stop and report the isolated
   root cause instead of looping.

Done when: assert_no_runtime_errors passes, every requested gate reports pass, and the last
play session reached the scenario's expected state.
"""

const RELEASE_EXPORT_FLOW_TEMPLATE: String = """
You are executing the "Release Export Checklist" workflow against the Godot project through MCP tools.

Platform: {{platform}}
Notes: {{notes}}

1. Templates — {"tool": "manage_export_templates", "args": {"action": "status"}}: matching_version_installed
   must be true; when false, download with {"action": "download"} and poll {"action": "download_status"}.
2. Preset — {"tool": "inspect_export_preset"} then {"tool": "validate_export_preset"}: resolve every
   reported issue (export_path, template availability, platform fields) before exporting.
3. Version — {"tool": "bump_version"}: raise the project version per the requested step and record
   the changelog entry it returns.
4. Export — {"tool": "run_export"} for the target preset; the result carries the artifact path.
5. Smoke — {"tool": "smoke_test_export", "args": {"launch": true}}: the product must exist and the
   launched process must exit with the expected code.
6. Report — summarize artifact path, size, version and smoke verdict in one block.

Done when: steps 1-5 all pass; any blocking failure is reported with the exact tool message.
"""

var _prompts: Dictionary = {}  # name -> {name, description, arguments, callable}

func _init() -> void:
	_register_all()

func _register_all() -> void:
	_add_prompt(
		"plan_game_feature",
		"Turn a one-sentence GDD / feature request into an executable manage_task_plan task graph with gated Definition-of-Done, then hand off the first ready task.",
		[
			{"name": "gdd_summary", "description": "One-paragraph game design document / feature request the plan must implement.", "required": true},
			{"name": "goal", "description": "Overall goal statement for the task plan (e.g. '2D platformer vertical slice').", "required": true}
		],
		Callable(self, "_get_plan_game_feature")
	)
	_add_prompt(
		"debug_runtime_error",
		"Debug a runtime error end-to-end: collect logs, locate the failing code, fix the root cause and re-verify until the error is gone.",
		[
			{"name": "error_text", "description": "The exact error message / stack trace reported by the runtime.", "required": true},
			{"name": "context", "description": "Optional context: what was happening, scene/script involved, expected behavior.", "required": false}
		],
		Callable(self, "_get_debug_runtime_error")
	)
	_add_prompt(
		"review_scene",
		"Audit the currently open scene: full structure, node checklist, persistence and inheritance issues, with a prioritized fix list.",
		[
			{"name": "focus", "description": "Optional area to focus the review on (e.g. a node subtree, persistence, inheritance).", "required": false}
		],
		Callable(self, "_get_review_scene")
	)
	_add_prompt(
		"run_test_suite",
		"Discover and run the project test suite, collect structured pass/fail results, and drive failing tests back to green.",
		[
			{"name": "target_dir", "description": "Optional res:// test directory to scope discovery and runs. Default res://test.", "required": false}
		],
		Callable(self, "_get_run_test_suite")
	)
	_add_prompt(
		"visual_playtest",
		"Run a visual regression playtest: launch the game, drive the scenario with the runtime probe, screenshot, compare against the golden baseline and judge the result.",
		[
			{"name": "scenario", "description": "The playtest scenario to drive: inputs, expected states, and what to screenshot.", "required": true}
		],
		Callable(self, "_get_visual_playtest")
	)
	_add_prompt(
		"onboard_new_project",
		"Onboard onto a new Godot project: gather project info and structure, discover the tool catalog, and enable only the tool groups the upcoming work needs.",
		[],
		Callable(self, "_get_onboard_new_project")
	)
	_add_prompt(
		"fix_compile_errors",
		"Fix GDScript compile/validation errors in a feedback loop: validate, read, patch, re-validate, and check dependent scripts for cascading failures.",
		[
			{"name": "script_paths", "description": "Optional comma-separated script paths to fix. When omitted, discover offending scripts from validation errors.", "required": false}
		],
		Callable(self, "_get_fix_compile_errors")
	)
	_add_prompt(
		"iterate_play_verify",
		"Run the play -> verify -> fix loop: launch the project, pull runtime logs and live state, gate on no-runtime-errors / performance / scenario conditions, patch the smallest cause and repeat until green.",
		[
			{"name": "target", "description": "What to verify, e.g. 'enemy wave spawner keeps 55 fps with zero runtime errors'.", "required": true},
			{"name": "gates", "description": "Optional gate list, e.g. 'no_runtime_errors, min_fps=55, player.y never < 0'. Defaults to no-runtime-errors.", "required": false}
		],
		Callable(self, "_get_iterate_play_verify")
	)
	_add_prompt(
		"release_export_flow",
		"Walk the release export checklist: template availability, preset validation, version bump, export, launched smoke test and a final report.",
		[
			{"name": "platform", "description": "Target platform/preset, e.g. 'Windows Desktop'.", "required": false},
			{"name": "notes", "description": "Optional release notes or version step, e.g. 'patch bump, fix controller pause'.", "required": false}
		],
		Callable(self, "_get_release_export_flow")
	)

func _add_prompt(name: String, description: String, arguments: Array[Dictionary], callable: Callable) -> void:
	_prompts[name] = {
		"name": name,
		"description": description,
		"arguments": arguments,
		"callable": callable
	}

# 每个配方的双语触发关键词；enable_tools 路由命中时向客户端提示可用配方。
const PROMPT_KEYWORDS: Dictionary = {
	"iterate_play_verify": ["iterate", "playtest", "verify loop", "gate", "fps", "runtime error",
		"迭代", "试玩", "验证循环", "帧率", "运行时错误", "性能"],
	"release_export_flow": ["export", "release", "ship", "build", "smoke test", "version bump",
		"导出", "发布", "出货", "打包", "冒烟", "版本"],
	"fix_compile_errors": ["compile", "parse error", "syntax", "validation error",
		"编译", "语法错误", "解析错误", "校验错误"],
	"debug_runtime_error": ["runtime error", "stack trace", "crash", "debug",
		"运行错误", "堆栈", "崩溃", "调试"],
	"plan_game_feature": ["gdd", "feature request", "task graph", "vertical slice", "plan",
		"需求", "功能设计", "任务图", "规划", "计划"],
	"visual_playtest": ["visual regression", "screenshot", "baseline", "golden",
		"视觉回归", "截图", "基线", "黄金"],
	"review_scene": ["scene audit", "review scene", "persistence issue",
		"场景审计", "场景检查", "持久化"],
	"run_test_suite": ["run tests", "test suite", "unit test", "gut",
		"跑测试", "测试套件", "单元测试"],
	"onboard_new_project": ["onboard", "new project", "discover tools",
		"上手", "新项目", "工具发现"]
}

## 目标语句命中的第一个配方（关键词出现即命中，长关键词优先）；
## 未命中返回空字典。
func match_prompt(query: String) -> Dictionary:
	var text: String = query.to_lower()
	var best: Dictionary = {}
	var best_len: int = 0
	for prompt_name in PROMPT_KEYWORDS:
		for keyword in PROMPT_KEYWORDS[prompt_name]:
			var keyword_text: String = String(keyword).to_lower()
			if text.contains(keyword_text) and keyword_text.length() > best_len:
				best = {"name": prompt_name, "description": String(_prompts.get(prompt_name, {}).get("description", ""))}
				best_len = keyword_text.length()
	return best

# ============================================================================
# 查询 API
# ============================================================================

## 所有已注册 prompt 的元数据（name/description/arguments），按名称排序，供 prompts/list 使用。
func get_prompts() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for name in _prompts:
		var entry: Dictionary = _prompts[name]
		result.append({
			"name": entry["name"],
			"description": entry["description"],
			"arguments": entry["arguments"]
		})
	result.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return String(a.get("name", "")) < String(b.get("name", ""))
	)
	return result

## 单个 prompt 的元数据；未注册返回空字典。
func get_prompt(name: String) -> Dictionary:
	return _prompts.get(name, {})

## 单个 prompt 的 get_callable；未注册返回无效 Callable。
func get_callable(name: String) -> Callable:
	var entry: Variant = _prompts.get(name, null)
	if entry is Dictionary:
		return entry.get("callable", Callable())
	return Callable()

## 把全部 prompt 注册到 server core（register_prompt），返回注册数量。
func register_to_server(server: RefCounted) -> int:
	if server == null or not server.has_method("register_prompt"):
		return 0
	var count: int = 0
	for name in _prompts:
		var entry: Dictionary = _prompts[name]
		server.register_prompt(
			String(entry["name"]),
			String(entry["description"]),
			entry["arguments"],
			entry["callable"]
		)
		count += 1
	return count

# ============================================================================
# get_callable 实现（args: Dictionary -> Dictionary）
# ============================================================================

## 渲染模板：校验必填参数 -> 替换 {{arg}} 占位符 -> 返回 MCP messages 结构。
## 缺少必填参数时返回 {"error": "..."}，与工具处理函数的错误字典约定一致。
func _render(template: String, args: Dictionary, required: Array[String]) -> Dictionary:
	for arg_name in required:
		if not args.has(arg_name) or str(args.get(arg_name, "")).strip_edges().is_empty():
			return {"error": "Missing required prompt argument: " + arg_name}
	var content: String = template
	for key in args:
		content = content.replace("{{" + key + "}}", str(args[key]))
	return {
		"messages": [{
			"role": "user",
			"content": {"type": "text", "text": content}
		}]
	}

func _get_plan_game_feature(args: Dictionary) -> Dictionary:
	return _render(PLAN_GAME_FEATURE_TEMPLATE, args, ["gdd_summary", "goal"])

func _get_debug_runtime_error(args: Dictionary) -> Dictionary:
	var content: String = DEBUG_RUNTIME_ERROR_TEMPLATE
	var context: String = str(args.get("context", "")).strip_edges()
	content = content.replace("{{context_block}}", "\nContext: " + context if not context.is_empty() else "")
	return _render(content, args, ["error_text"])

func _get_review_scene(args: Dictionary) -> Dictionary:
	var content: String = REVIEW_SCENE_TEMPLATE
	var focus: String = str(args.get("focus", "")).strip_edges()
	content = content.replace("{{focus_block}}", "Focus: " + focus if not focus.is_empty() else "")
	return _render(content, args, [])

func _get_run_test_suite(args: Dictionary) -> Dictionary:
	var content: String = RUN_TEST_SUITE_TEMPLATE
	var target_dir: String = str(args.get("target_dir", "")).strip_edges()
	if target_dir.is_empty():
		content = content.replace("{{target_dir_block}}", "No target directory given — using the default res://test.")
		content = content.replace("{{target_dir}}", "res://test")
	else:
		content = content.replace("{{target_dir_block}}", "Target directory: " + target_dir)
		content = content.replace("{{target_dir}}", target_dir)
	return _render(content, args, [])

func _get_visual_playtest(args: Dictionary) -> Dictionary:
	return _render(VISUAL_PLAYTEST_TEMPLATE, args, ["scenario"])

func _get_iterate_play_verify(args: Dictionary) -> Dictionary:
	var content: String = ITERATE_PLAY_VERIFY_TEMPLATE
	var gates: String = str(args.get("gates", "")).strip_edges()
	if gates.is_empty():
		gates = "no runtime errors (max_errors=0)"
	content = content.replace("{{gates}}", gates)
	return _render(content, args, ["target"])

func _get_release_export_flow(args: Dictionary) -> Dictionary:
	var content: String = RELEASE_EXPORT_FLOW_TEMPLATE
	var platform: String = str(args.get("platform", "")).strip_edges()
	if platform.is_empty():
		platform = "the project's default export preset"
	var notes: String = str(args.get("notes", "")).strip_edges()
	if notes.is_empty():
		notes = "none"
	content = content.replace("{{platform}}", platform).replace("{{notes}}", notes)
	return _render(content, args, [])

func _get_onboard_new_project(args: Dictionary) -> Dictionary:
	return _render(ONBOARD_NEW_PROJECT_TEMPLATE, args, [])

func _get_fix_compile_errors(args: Dictionary) -> Dictionary:
	var content: String = FIX_COMPILE_ERRORS_TEMPLATE
	var paths: String = str(args.get("script_paths", "")).strip_edges()
	if paths.is_empty():
		content = content.replace("{{script_paths_block}}", "None specified — discover offending scripts from validation errors.")
	else:
		content = content.replace("{{script_paths_block}}", paths)
	return _render(content, args, [])
