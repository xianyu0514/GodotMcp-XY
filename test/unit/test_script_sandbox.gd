extends "res://addons/gut/test.gd"

# 针对 MCPScriptSandbox 的纯函数单测：给定脚本/表达式 -> 是否拦截，确定性可断言。

var _sandbox: GDScript = null

func before_each():
	_sandbox = load("res://addons/godot_mcp/utils/script_sandbox.gd")

func after_each():
	_sandbox = null

func _scan(code: String, config: Dictionary = {}) -> Dictionary:
	if not config.has("enabled"):
		config["enabled"] = true
	return _sandbox.scan(code, config)

# ---------- os_process ----------

func test_blocks_os_execute():
	var r: Dictionary = _scan("OS.execute(\"ls\", [])")
	assert_true(r["blocked"], "OS.execute should be blocked")
	assert_eq(r["category"], "os_process")
	assert_eq(r["reason"], "script_sandbox")

func test_blocks_os_create_process():
	assert_true(_scan("var p = OS.create_process(\"bash\", [])")["blocked"])

func test_blocks_os_shell_open():
	assert_true(_scan("OS.shell_open(\"https://x\")")["blocked"])

# ---------- network ----------

func test_blocks_http_request():
	var r: Dictionary = _scan("var h = HTTPRequest.new()")
	assert_true(r["blocked"], "HTTPRequest should be blocked")
	assert_eq(r["category"], "network")

func test_blocks_tcp_server():
	assert_true(_scan("var s = TCPServer.new()")["blocked"])

# ---------- dangerous_api ----------

func test_blocks_tree_quit():
	var r: Dictionary = _scan("get_tree().quit()")
	assert_true(r["blocked"], "get_tree().quit() should be blocked")
	assert_eq(r["category"], "dangerous_api")

func test_blocks_javascript_bridge():
	assert_true(_scan("JavaScriptBridge.eval(\"1\")")["blocked"])

# ---------- filesystem ----------

func test_blocks_absolute_unix_path():
	var r: Dictionary = _scan("var f = FileAccess.open(\"/etc/passwd\", FileAccess.READ)")
	assert_true(r["blocked"], "Out-of-project absolute path should be blocked")
	assert_eq(r["category"], "filesystem")

func test_blocks_windows_drive_path():
	assert_true(_scan("DirAccess.open(\"C:\\\\Windows\")")["blocked"])

func test_blocks_res_traversal():
	assert_true(_scan("FileAccess.open(\"res://../../escape.txt\", FileAccess.READ)")["blocked"])

# ---------- 应放行 ----------

func test_allows_benign_scene_script():
	var code: String = "var n = edited_scene.get_node(\"Player\")\n_custom_print(n.name)"
	assert_false(_scan(code)["blocked"], "Benign scene script should pass")

func test_allows_res_path_read():
	assert_false(_scan("var f = FileAccess.open(\"res://data/levels.json\", FileAccess.READ)")["blocked"])

func test_allows_user_path():
	assert_false(_scan("var f = FileAccess.open(\"user://save.dat\", FileAccess.WRITE)")["blocked"])

# ---------- 防误杀：注释 / 字符串 ----------

func test_comment_mentioning_os_execute_is_allowed():
	assert_false(_scan("# OS.execute is dangerous, do not use\nvar x = 1")["blocked"], "Comment must not trigger identifier rule")

func test_string_mentioning_os_execute_is_allowed():
	assert_false(_scan("_custom_print(\"call OS.execute to run\")")["blocked"], "String literal must not trigger identifier rule")

func test_substring_identifier_not_matched():
	assert_false(_scan("var my_os_execute_helper = 1")["blocked"], "Word-boundary match must not hit substrings")

# ---------- 配置 ----------

func test_disabled_allows_everything():
	assert_false(_scan("OS.execute(\"ls\", [])", {"enabled": false})["blocked"], "Disabled sandbox should pass all")

func test_warn_only_does_not_block():
	var r: Dictionary = _scan("OS.execute(\"ls\", [])", {"warn_only": true})
	assert_false(r["blocked"], "warn_only must not block")
	assert_true(r["warned"], "warn_only should report a warning")

func test_category_filter_only_checks_selected():
	var r: Dictionary = _scan("OS.execute(\"ls\", [])", {"categories": ["network"]})
	assert_false(r["blocked"], "os_process not in selected categories -> pass")

func test_extra_denylist():
	var r: Dictionary = _scan("dangerous_custom_call()", {"extra_denylist": ["dangerous_custom_call"]})
	assert_true(r["blocked"], "extra_denylist token should block")
	assert_eq(r["category"], "custom")

func test_allowlist_exempts_token():
	assert_false(_scan("OS.execute(\"ls\", [])", {"allowlist": ["OS.execute"]})["blocked"], "allowlist should exempt token")

func test_empty_code_allowed():
	assert_false(_scan("")["blocked"], "Empty code should pass")

# ---------- 路径误杀回归（PR#76 review） ----------

func test_allows_root_node_path():
	assert_false(_scan("var n = get_node(\"/root/Main/Player\")")["blocked"], "Godot /root/ node path must not be blocked")

func test_allows_root_node_path_in_get_tree():
	assert_false(_scan("get_tree().root.get_node(\"/root/World\")")["blocked"], "/root/ node path is benign")

func test_still_blocks_absolute_system_path():
	var r: Dictionary = _scan("var f = FileAccess.open(\"/home/user/secret.txt\", FileAccess.READ)")
	assert_true(r["blocked"], "absolute non-resource path still blocked")
	assert_eq(r["category"], "filesystem")

func test_still_blocks_etc_even_under_root_prefix():
	assert_true(_scan("FileAccess.open(\"/etc/passwd\", FileAccess.READ)")["blocked"], "/etc/ still blocked")

func test_tilde_in_plain_text_not_blocked():
	assert_false(_scan("_custom_print(\"~5 enemies left\")")["blocked"], "tilde inside arbitrary text must not block")

func test_tilde_version_specifier_not_blocked():
	assert_false(_scan("var v = \"~1.0\"")["blocked"], "tilde version-like string must not block")

func test_tilde_home_path_still_blocked():
	var r: Dictionary = _scan("FileAccess.open(\"~/.ssh/id_rsa\", FileAccess.READ)")
	assert_true(r["blocked"], "~/ home-dir path still blocked")
	assert_eq(r["category"], "filesystem")

# ---------- execute_script 单行旁路回归（PR#76 review） ----------
# execute_script 的单行表达式路径与 execute_editor_script 共用同一 scan()，
# 此处直接验证 scan() 对单行表达式同样拦截危险能力。

func test_single_line_os_execute_blocked():
	var r: Dictionary = _scan("OS.execute(\"rm\", [\"-rf\", \"/tmp/data\"])")
	assert_true(r["blocked"], "single-line OS.execute must be blocked")
	assert_eq(r["category"], "os_process")
