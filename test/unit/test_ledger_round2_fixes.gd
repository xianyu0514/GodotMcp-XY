extends "res://addons/gut/test.gd"

# 2026-10-04 English Rift 日报（mcp-daily-2026-10-04.md）第二轮修复回归测试：
#   - N-4：godot_version 带 patch 号（两个引擎并存可区分）
#   - N-1 尾巴：prepare_project_test_environment 发现 custom 测试时给出
#     自定义运行器指引
#   - N-2：extends SceneTree 的项目自带 runner 走 headless --script 子进程
#     执行（framework=script，可发现可运行可计数），非 GutTest 非 SceneTree
#     的脚本显式 skipped 且理由指明
#   - N-7：Control 命中测试函数（get_control_at_point / 鼠标注入 hit_control
#     的核心逻辑）

const PROJECT_TOOLS = preload("res://addons/godot_mcp/tools/project_tools_native.gd")
const RUNTIME_PROBE = preload("res://addons/godot_mcp/runtime/mcp_runtime_probe.gd")

var _project_tools: RefCounted = null
var _tmp_dir: String = "res://.tmp_ledger2_tests"


func before_each() -> void:
	_project_tools = PROJECT_TOOLS.new()
	DirAccess.make_dir_recursive_absolute(_tmp_dir)


func after_each() -> void:
	_project_tools = null
	var dir: DirAccess = DirAccess.open(_tmp_dir)
	if dir:
		dir.list_dir_begin()
		var entry: String = dir.get_next()
		while not entry.is_empty():
			if entry != "." and entry != ".." and not dir.current_is_dir():
				DirAccess.remove_absolute(_tmp_dir + "/" + entry)
			entry = dir.get_next()
		dir.list_dir_end()
	DirAccess.remove_absolute(_tmp_dir)


func _write_tmp(file_name: String, content: String) -> String:
	var path: String = _tmp_dir + "/" + file_name
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	file.store_string(content)
	file.close()
	return path


# ============================================================================
# N-4：godot_version 带 patch 号
# ============================================================================

func test_project_info_version_includes_patch_number() -> void:
	var result: Dictionary = _project_tools._tool_get_project_info({})
	var version: String = String(result["godot_version"])
	# 本仓库用 4.7.2：patch 段必须在版本串里（"4.7.stable" 形态不再出现）。
	assert_true(version.begins_with("4.7.2."), 
		"godot_version must include the patch number, got: " + version)
	assert_true(version.ends_with(".stable"),
		"godot_version must end with the status segment")
	var executable: String = String(result.get("engine_executable_path", ""))
	if executable.contains("4.7.2"):
		assert_true(version.contains("4.7.2"),
			"version string and executable path must agree on the engine version")


# ============================================================================
# N-1 尾巴 + N-2 发现层：SceneTree runner 的发现与指引
# ============================================================================

func test_scene_tree_runner_discovered_as_framework_script() -> void:
	var runner_path: String = _write_tmp("test_custom_gate.gd",
		"extends SceneTree\n\nfunc _initialize() -> void:\n\tquit(0)\n")
	var absolute: String = ProjectSettings.globalize_path(runner_path)
	assert_true(PROJECT_TOOLS._file_extends_scene_tree(absolute),
		"extends SceneTree must be detected as a runnable script runner")
	assert_false(PROJECT_TOOLS._file_extends_gut_test(absolute),
		"SceneTree runner is not a GutTest")

	# 发现层：framework=script、runnable=true
	var list_result: Dictionary = _project_tools._tool_list_project_tests({
		"search_path": _tmp_dir})
	var found: Array = []
	for entry_value in list_result.get("tests", []):
		if String(entry_value.get("test_path", "")) == runner_path:
			found.append(entry_value)
	assert_eq(found.size(), 1, "SceneTree runner must be discovered")
	assert_eq(String(found[0]["framework"]), "script",
		"SceneTree runner must be labeled framework=script")
	assert_true(bool(found[0]["runnable"]), "Script runner must be runnable")

	# prepare：custom 测试在场时给出自定义运行器指引
	var prepared: Dictionary = _project_tools._tool_prepare_project_test_environment({
		"search_path": _tmp_dir})
	assert_gte(int(prepared.get("custom_test_count", 0)), 1,
		"prepare must count custom-runner scripts (>=1)")
	assert_eq(String(prepared.get("recommended_action", "")),
		"use_custom_runner_for_framework_script_tests",
		"prepare must point at the custom runner path")


func test_gut_detection_unchanged_for_guttest_files() -> void:
	assert_true(PROJECT_TOOLS._file_extends_gut_test(
		_write_tmp("still_gut.gd", "extends GutTest\n\nfunc test_x() -> void:\n\tpass\n")),
		"GutTest detection must keep working")


# ============================================================================
# N-2：framework=script 执行（真子进程，红/绿两态）
# ============================================================================

func test_script_framework_runs_green_runner_and_reports_exit_zero() -> void:
	var runner_path: String = _write_tmp("test_green_runner.gd",
		"extends SceneTree\n\nfunc _initialize() -> void:\n\tprint(\"GREEN_GATE\")\n\tquit(0)\n")
	var result: Dictionary = _project_tools._execute_project_test_blocking(runner_path)
	assert_eq(String(result["status"]), "passed",
		"Green custom runner must report passed")
	assert_eq(int(result["exit_code"]), 0, "Exit code 0 must surface")
	assert_eq(String(result["framework"]), "script", "Framework must be script")
	assert_true(String(result.get("command", [])[0]).to_lower().contains("godot"),
		"Command must record the engine executable")


func test_script_framework_runs_red_runner_and_reports_nonzero_exit() -> void:
	var runner_path: String = _write_tmp("test_red_runner.gd",
		"extends SceneTree\n\nfunc _initialize() -> void:\n\tprint(\"RED_GATE\")\n\tquit(1)\n")
	var result: Dictionary = _project_tools._execute_project_test_blocking(runner_path)
	assert_eq(String(result["status"]), "failed",
		"Red custom runner must report failed")
	assert_ne(int(result["exit_code"]), 0,
		"Non-zero exit code must surface — the gate is red")


func test_non_gut_nonscenetree_script_is_skipped_with_reason() -> void:
	var path: String = _write_tmp("test_plain_refcounted.gd",
		"extends RefCounted\n\nfunc run_all() -> void:\n\tpass\n")
	var result: Dictionary = _project_tools._execute_project_test_blocking(path)
	assert_eq(String(result["status"]), "skipped",
		"Neither GutTest nor SceneTree must be skipped, never run")
	assert_eq(String(result["reason"]), "not_guttest_nor_scenetree",
		"Skip reason must name the shape mismatch")


# ============================================================================
# N-7：Control 命中测试（get_control_at_point / hit_control 的核心逻辑）
# ============================================================================

func test_find_control_at_point_reports_deepest_hit() -> void:
	var probe: Node = RUNTIME_PROBE.new()
	add_child_autofree(probe)
	var root: Control = Control.new()
	root.name = "RootPanel"
	root.size = Vector2(200, 200)
	var button: Button = Button.new()
	button.name = "PlayButton"
	button.text = "Play"
	button.position = Vector2(50, 50)
	button.size = Vector2(80, 30)
	root.add_child(button)
	add_child_autofree(root)

	# 等一帧让布局生效（global rect 依赖树与布局）。
	await get_tree().process_frame

	var hit: Dictionary = probe._find_control_at_point(get_viewport(),
		get_tree().root, root.get_global_rect().position + Vector2(60, 60))
	assert_false(hit.is_empty(), "Point inside the button must hit")
	assert_eq(String(hit["control_path"]).contains("PlayButton"), true,
		"The deepest hit must be the button, got: " + str(hit.get("control_path")))
	assert_eq(String(hit.get("control_class")), "Button")
	assert_eq(String(hit.get("control_text")), "Play")

	var miss: Dictionary = probe._find_control_at_point(get_viewport(),
		get_tree().root, root.get_global_rect().position + Vector2(250, 250))
	assert_true(miss.is_empty(),
		"Point outside every control must report an empty hit")
