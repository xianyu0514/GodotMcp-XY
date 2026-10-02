extends "res://addons/gut/test.gd"

# 参考 addon：对话工具集的 handler 逻辑 + custom tools API 注册链路。

const DialogueTools := preload("res://addons/godot_mcp_dialogue_tools/dialogue_tools.gd")
const RegistryScript := preload("res://addons/godot_mcp/tools/custom_tools_registry.gd")

var _tools: RefCounted = null
var _tmp_dir: String = ""

func before_each() -> void:
	_tools = DialogueTools.new()
	_tmp_dir = "res://tmp_dlg_%d" % Time.get_ticks_usec()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_tmp_dir))
	RegistryScript._registered.clear()
	RegistryScript._applied_cores.clear()

func after_each() -> void:
	var absolute: String = ProjectSettings.globalize_path(_tmp_dir)
	if DirAccess.dir_exists_absolute(absolute):
		DirAccess.remove_absolute(absolute)
	_tmp_dir = ""
	_tools = null
	_reset_registry()

func _reset_registry() -> void:
	RegistryScript._registered.clear()
	RegistryScript._applied_cores.clear()
	if Engine.has_meta("GodotMCPCustomTools"):
		Engine.remove_meta("GodotMCPCustomTools")

func _write(full_path: String, content: String) -> void:
	var file: FileAccess = FileAccess.open(full_path, FileAccess.WRITE)
	assert_not_null(file, "Failed to open " + full_path + " for writing")
	file.store_string(content)
	file.close()

func _write_graph(graph: Dictionary) -> String:
	var path: String = _tmp_dir.path_join("dialogue.json")
	_write(path, JSON.stringify(graph, "\t"))
	return path

# --- 校验 ---

func test_valid_dialogue_passes():
	var path: String = _write_graph({
		"start": "intro",
		"nodes": [
			{"id": "intro", "text": "Hello", "next": ["choice"]},
			{"id": "choice", "text": "Pick one", "next": ["end_a", "end_b"]},
			{"id": "end_a", "text": "A", "next": []},
			{"id": "end_b", "text": "B", "next": []}
		]
	})
	var result: Dictionary = _tools.validate_dialogue({"path": path})
	assert_true(bool(result["valid"]), str(result))
	assert_eq(int(result["node_count"]), 4)
	assert_eq((result["dangling_links"] as Array).size(), 0)
	assert_eq((result["unreachable_nodes"] as Array).size(), 0)

func test_dangling_links_detected():
	var path: String = _write_graph({
		"start": "a",
		"nodes": [
			{"id": "a", "text": "Hi", "next": ["ghost"]}
		]
	})
	var result: Dictionary = _tools.validate_dialogue({"path": path})
	assert_true((result["dangling_links"] as Array).has("ghost"), "悬空目标必须报告")
	assert_false(bool(result["valid"]))

func test_unreachable_nodes_detected():
	var path: String = _write_graph({
		"start": "a",
		"nodes": [
			{"id": "a", "text": "Hi", "next": []},
			{"id": "orphan", "text": "Never reached", "next": []}
		]
	})
	var result: Dictionary = _tools.validate_dialogue({"path": path})
	assert_true((result["unreachable_nodes"] as Array).has("orphan"))
	assert_false(bool(result["valid"]))

# --- 字数统计 ---

func test_wordcount_per_character():
	var path: String = _write_graph({
		"nodes": [
			{"id": "1", "speaker": "alice", "text": "Hello world foo", "next": []},
			{"id": "2", "speaker": "bob", "text": "Hey", "next": []},
			{"id": "3", "speaker": "alice", "text": "More words here", "next": []}
		]
	})
	var result: Dictionary = _tools.wordcount_dialogue({"path": path})
	var per: Dictionary = result.get("per_character", {})
	assert_eq(int(per.get("alice", 0)), 6, "alice: 3 + 3 = 6")
	assert_eq(int(per.get("bob", 0)), 1)
	assert_eq(int(result["total_words"]), 7)

# --- 本地化键提取 ---

func test_loc_keys_missing_and_found():
	var graph_path: String = _write_graph({
		"nodes": [
			{"id": "1", "loc_id": "dlg_hello", "next": []},
			{"id": "2", "loc_id": "dlg_missing", "next": []}
		]
	})
	var csv_path: String = _tmp_dir.path_join("loc.csv")
	_write(csv_path, "dlg_hello,Hello\ndlg_world,World\n")
	var result: Dictionary = _tools.loc_keys_dialogue({"path": graph_path, "csv_path": csv_path})
	assert_eq(int(result["referenced"]), 2)
	assert_true((result["missing"] as Array).has("dlg_missing"))
	assert_true((result["found"] as Array).has("dlg_hello"))

# --- 注册链路集成（custom tools API 端到端）---

func test_full_custom_tools_api_lifecycle():
	# 注册（模拟 addon _enter_tree）
	var reg_result: Dictionary = RegistryScript.register_tool(
		"custom_lifecycle_test", "Lifecycle test tool.",
		{"type": "object", "properties": {"value": {"type": "integer"}}},
		Callable(self, "_lifecycle_handler"))
	assert_true(reg_result.has("ok"), str(reg_result))
	# 挂载到真 core
	var core: RefCounted = load("res://addons/godot_mcp/native_mcp/mcp_server_core.gd").new()
	RegistryScript.apply_to(core)
	assert_true(core.has_tool("custom_lifecycle_test"))
	core.set_tool_enabled("custom_lifecycle_test", true)
	# 调用
	var call_result: Dictionary = await core._handle_tool_call({
		"id": 1, "params": {"name": "custom_lifecycle_test", "arguments": {"value": 42}}})
	assert_eq(_handler_calls, 1, "handler 必须收到调用")
	# 注销
	RegistryScript.unregister_tool("custom_lifecycle_test")
	assert_false(core.has_tool("custom_lifecycle_test"), "注销后工具从 server 移除")

var _handler_calls: int = 0
func _lifecycle_handler(params: Dictionary) -> Dictionary:
	_handler_calls += 1
	return {"echo": params.get("value", null)}
