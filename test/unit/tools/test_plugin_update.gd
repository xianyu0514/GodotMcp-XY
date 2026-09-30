extends "res://addons/gut/test.gd"

# check_plugin_update：版本比较、release 解析与注入链路（不依赖外网）。

const EditorToolsScript = preload("res://addons/godot_mcp/tools/editor_tools_native.gd")

const SAMPLE_RELEASE: String = '{"tag_name":"v1.3.0","name":"1.3.0","published_at":"2026-09-27T00:00:00Z","html_url":"https://github.com/xianyu0514/GodotMcp-XY/releases/tag/v1.3.0","body":"## What changed\n- engine compat knowledge\n- custom tools API","assets":[{"browser_download_url":"https://github.com/xianyu0514/GodotMcp-XY/releases/download/v1.3.0/godot_mcp.zip"},{"browser_download_url":"https://example.com/readme.txt"}]}'

var _tools: RefCounted = null

func before_each() -> void:
	_tools = EditorToolsScript.new()

func after_each() -> void:
	_tools = null

# --- semver 比较（纯函数）---

func test_semver_compare_orders_versions():
	assert_eq(EditorToolsScript.semver_compare("1.3.0", "1.1.0"), 1)
	assert_eq(EditorToolsScript.semver_compare("1.1.0", "1.3.0"), -1)
	assert_eq(EditorToolsScript.semver_compare("1.1.0", "1.1.0"), 0)
	assert_eq(EditorToolsScript.semver_compare("v1.3.0", "1.1.0"), 1, "v 前缀容忍")
	assert_eq(EditorToolsScript.semver_compare("1.2", "1.2.0"), 0, "缺段按 0")
	assert_eq(EditorToolsScript.semver_compare("1.10.0", "1.9.0"), 1, "数值比较非字典序")

# --- release 解析（纯函数）---

func test_parse_release_extracts_core_fields():
	var release: Dictionary = EditorToolsScript.parse_release_payload(SAMPLE_RELEASE)
	assert_false(release.has("error"), str(release))
	assert_eq(String(release["tag_name"]), "v1.3.0")
	assert_eq(String(release["download_url"]), "https://github.com/xianyu0514/GodotMcp-XY/releases/download/v1.3.0/godot_mcp.zip",
		"zip 资产必须命中（非 zip 跳过）")
	assert_true(str(release["notes_excerpt"]).contains("custom tools API"))

func test_parse_release_rejects_garbage():
	assert_true(EditorToolsScript.parse_release_payload("not json").has("error"))
	assert_true(EditorToolsScript.parse_release_payload('{"message":"Not Found"}').has("error"),
		"GitHub API 错误消息必须转译为 error")
	assert_true(EditorToolsScript.parse_release_payload('{"html_url":"x"}').has("error"),
		"缺 tag_name 必须报错")

# --- 工具层（debug 注入，无外网）---

func test_tool_reports_update_available_via_injection():
	_tools._debug_release_json = SAMPLE_RELEASE
	var result: Dictionary = await _tools._tool_check_plugin_update({})
	assert_false(result.has("error"), str(result))
	assert_eq(String(result["current_version"]), "1.2.1", "当前版本读自 plugin.cfg")
	assert_eq(String(result["latest_version"]), "v1.3.0")
	assert_true(bool(result["update_available"]))
	assert_true((result["install_steps"] as Array).size() >= 3, "必须给安装步骤")
	assert_true(str(result["honest_note"]).contains("not swap files"), "诚实声明不自动交换的原因")

func test_tool_reports_up_to_date_via_injection():
	_tools._debug_release_json = '{"tag_name":"v1.1.0","html_url":"u","body":"","assets":[],"published_at":""}'
	var result: Dictionary = await _tools._tool_check_plugin_update({})
	assert_false(result.has("error"))
	assert_false(bool(result["update_available"]), "同版本应报 up to date")

func test_tool_network_failure_is_actionable():
	# 无 debug 注入且网络不可达时（headless CI 无 GitHub）：curl+HTTP 双失败
	# 返回自愈错误——若网络恰好可达则退化为正常路径校验。
	var result: Dictionary = await _tools._tool_check_plugin_update({"timeout_sec": 3})
	if result.has("error"):
		assert_true(str(result["error"]).contains("GitHub"))
		assert_true(str(result.get("recommended_action", "")).contains("releases"),
			"失败路径必须给手动 releases 页指引")
		assert_eq(String(result.get("current_version", "")), "1.2.1")
	else:
		assert_true(result.has("update_available"), "网络可达时走正常比较路径")
