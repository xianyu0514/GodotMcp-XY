extends "res://addons/gut/test.gd"

## E-3 下沉第一批的单测：三条自愈提示 + res:// 写入扫描。
## 知识从配方文本沉入工具分支（docs/knowledge-sinking-inventory.md），
## 每个分支的行为在此钉死。

const RuntimeToolsScript = preload("res://addons/godot_mcp/tools/debug_runtime_tools.gd")
const VerifyToolsScript = preload("res://addons/godot_mcp/tools/debug_verify_tools.gd")
const ResourcesToolsScript = preload("res://addons/godot_mcp/tools/project_resources_tools.gd")

const TMP: String = "res://.tmp_e3"

func before_each() -> void:
	DirAccess.make_dir_recursive_absolute(TMP)

func after_each() -> void:
	var dir: DirAccess = DirAccess.open(TMP)
	if dir:
		for entry in dir.get_files():
			dir.remove(entry)
	var root: DirAccess = DirAccess.open("res://")
	if root and root.dir_exists(TMP.trim_prefix("res://")):
		root.remove(TMP.trim_prefix("res://"))

func _write(path: String, content: String) -> void:
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	file.store_string(content)
	file.close()

func test_expression_failure_hint_names_the_death_window_fix() -> void:
	var hint: String = RuntimeToolsScript._expression_failure_hint()
	assert_true(hint.contains("queue_free"), "names the cause")
	assert_true(hint.to_lower().contains("counter"), "names the counter fix")

func test_unbound_input_hint_names_the_exact_call() -> void:
	var hint: String = VerifyToolsScript._unbound_input_hint("attack")
	assert_true(hint.contains("'attack'"), "names the action")
	assert_true(hint.contains("upsert_project_input_action"), "names the exact fix call")
	assert_eq(VerifyToolsScript._unbound_input_hint(""), "", "no action name -> no hint noise")

func test_res_write_scan_flags_user_io_only_writes() -> void:
	_write(TMP + "/bad_save.gd", "extends Node\nfunc save() -> void:\n\tvar f := FileAccess.open(\"res://save.json\", FileAccess.WRITE)\n")
	_write(TMP + "/ok_read.gd", "extends Node\nfunc load_all() -> void:\n\tvar f := FileAccess.open(\"res://data.json\", FileAccess.READ)\n")
	_write(TMP + "/ok_user.gd", "extends Node\nfunc save() -> void:\n\tvar f := FileAccess.open(\"user://save.json\", FileAccess.WRITE)\n")
	var tools: RefCounted = ResourcesToolsScript.new()
	var result: Dictionary = tools._scan_res_write_paths({"search_path": TMP})
	assert_false(result.has("error"), str(result))
	assert_eq(int(result.get("issue_count", -1)), 1, "only the res:// WRITE is flagged")
	var issues: Array = result.get("issues", [])
	assert_eq(String(issues[0].get("file", "")).ends_with("bad_save.gd"), true)
	assert_true(String(issues[0].get("message", "")).contains("user://"), "message names the fix")
