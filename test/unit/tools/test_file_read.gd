extends "res://addons/gut/test.gd"

# read_project_file：P1-10 回归（2026-09-29 体检）——此前 read_script 只收
# .gd/.cs，JSON/.cfg/.tscn/.tres 排障必须回落本地读取。

const ProjectToolsScript = preload("res://addons/godot_mcp/tools/project_tools_native.gd")

var _tmp_dir: String = ""
var _tools: RefCounted = null

func before_each() -> void:
	_tools = ProjectToolsScript.new()
	_tmp_dir = "res://.tmp_file_read_%d" % Time.get_ticks_usec()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_tmp_dir))

func after_each() -> void:
	var absolute: String = ProjectSettings.globalize_path(_tmp_dir)
	if DirAccess.dir_exists_absolute(absolute):
		_remove_recursive(absolute)
	_tmp_dir = ""
	_tools = null

func _remove_recursive(path: String) -> void:
	var dir: DirAccess = DirAccess.open(path)
	if dir == null:
		return
	dir.list_dir_begin()
	var entry: String = dir.get_next()
	while not entry.is_empty():
		var full: String = path.path_join(entry)
		if dir.current_is_dir():
			_remove_recursive(full)
		else:
			DirAccess.remove_absolute(full)
		entry = dir.get_next()
	dir.list_dir_end()
	DirAccess.remove_absolute(path)

func _write_bytes(name: String, data: PackedByteArray) -> String:
	var path: String = _tmp_dir.path_join(name)
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	file.store_buffer(data)
	file.close()
	return path

func _write_text(name: String, text: String) -> String:
	return _write_bytes(name, text.to_utf8_buffer())

# --- 白名单 ---

func test_json_and_cfg_are_readable():
	var path: String = _write_text("cards.json", '{"cost": 3}\n')
	var result: Dictionary = _tools._tool_read_project_file({"file_path": path})
	assert_false(result.has("error"), str(result))
	assert_true(str(result["content"]).contains('"cost": 3'))
	assert_eq(int(result["total_line_count"]), 1)

func test_disallowed_extension_self_heals():
	var path: String = _write_bytes("asset.png", PackedByteArray([0x89, 0x50, 0x4e, 0x47]))
	var result: Dictionary = _tools._tool_read_project_file({"file_path": path})
	assert_true(result.has("error"), "二进制资源必须拒读")
	var message: String = str(result["error"])
	assert_true(message.contains("File extension not allowed"), "应说明扩展名白名单")
	assert_true(message.contains("read_script"), "应指路脚本专用读取工具")

# --- 分页 ---

func test_line_pagination_is_lossless():
	var body: String = ""
	for i in range(50):
		body += "line_%d\n" % i
	var path: String = _write_text("big.cfg", body)
	var page1: Dictionary = _tools._tool_read_project_file({"file_path": path, "max_lines": 20})
	assert_true(bool(page1["truncated"]))
	assert_eq(int(page1["line_count"]), 20)
	assert_eq(int(page1["next_offset"]), 20)
	assert_true(str(page1["content"]).begins_with("line_0"))
	var page3: Dictionary = _tools._tool_read_project_file({"file_path": path, "offset_lines": 40, "max_lines": 20})
	assert_false(bool(page3["truncated"]), "最后一页不再截断")
	assert_true(str(page3["content"]).contains("line_49"))
	# 全量 hash 与分页 hash 一致（写前置条件的对称性）
	var full: Dictionary = _tools._tool_read_project_file({"file_path": path})
	assert_eq(String(page1["content_hash"]), String(full["content_hash"]))

func test_offset_beyond_end_returns_empty_page():
	var path: String = _write_text("small.txt", "one\n")
	var result: Dictionary = _tools._tool_read_project_file({"file_path": path, "offset_lines": 99})
	assert_false(result.has("error"), str(result))
	assert_eq(String(result["content"]), "")
	assert_eq(int(result["line_count"]), 0)

# --- 大小上限 ---

func test_oversized_file_refused_with_actual_size():
	var body: String = "x".repeat(5000)
	var path: String = _write_text("fat.json", body)
	var result: Dictionary = _tools._tool_read_project_file({"file_path": path, "max_bytes": 1024})
	assert_true(result.has("error"))
	assert_true(str(result["error"]).contains("5000"), "错误应含实际字节数")
	assert_eq(int(result.get("total_size_bytes", 0)), 5000, "超限响应应带上报大小")

# --- 二进制护栏 ---

func test_nul_byte_in_text_extension_refused():
	var path: String = _write_bytes("fake.json", PackedByteArray([0x7b, 0x00, 0x7d]))
	var result: Dictionary = _tools._tool_read_project_file({"file_path": path})
	assert_true(result.has("error"), "文本扩展名里的 NUL 字节必须拒读")
	assert_true(str(result["error"]).contains("NUL"))

# --- 错误自愈 ---

func test_missing_file_points_at_enumeration_tools():
	var result: Dictionary = _tools._tool_read_project_file({"file_path": "res://.tmp_no_such_%d.json" % Time.get_ticks_usec()})
	assert_true(result.has("error"))
	assert_true(str(result["error"]).contains("list_project_resources"), "缺文件应指路枚举工具")

func test_missing_path_param_rejected():
	assert_true(_tools._tool_read_project_file({}).has("error"))

func test_scripts_still_readable_for_parity():
	var path: String = _write_text("helper.gd", "extends RefCounted\n")
	var result: Dictionary = _tools._tool_read_project_file({"file_path": path})
	assert_false(result.has("error"), str(result))

func test_project_godot_readable():
	# 2026-09-29 真机验收实锤：godot 扩展名不在白名单时 project.godot 读不了。
	var result: Dictionary = _tools._tool_read_project_file({"file_path": "res://project.godot"})
	assert_false(result.has("error"), str(result))
	assert_true(str(result["content"]).contains("config_version"), "读到的应是项目配置内容")
	assert_true(int(result["total_line_count"]) > 0)
