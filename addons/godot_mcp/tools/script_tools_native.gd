# script_tools_native.gd - Script Tools 兼容壳（实例转发层）
# 2026-10-03 按域拆分：发现/符号索引/搜索 -> script_symbol_tools.gd；
# 写入（create/modify/rename/attach/open）-> script_write_tools.gd；
# 验证/分析（validate/verify/analyze/shader）-> script_verify_tools.gd；
# 跨域共享纯函数 -> script_tools_shared.gd。
#
# 四个模块经 TOOL_SCRIPT_PATHS 独立注册独立分帧（本文件不在注册清单里，
# 不占启动编译帧）。本壳仅为既有调用方（15 个测试文件直接实例化后调用
# _tool_* 处理器；change_set_tools.gd 的静态引用）保留零逻辑转发——
# 每个转发单行 return，新增工具直接落在对应子模块，无需回填本壳。

class_name ScriptToolsNative
extends RefCounted

const ScriptToolsSharedScript = preload("res://addons/godot_mcp/tools/script_tools_shared.gd")
const ScriptSymbolToolsScript = preload("res://addons/godot_mcp/tools/script_symbol_tools.gd")
const ScriptWriteToolsScript = preload("res://addons/godot_mcp/tools/script_write_tools.gd")
const ScriptVerifyToolsScript = preload("res://addons/godot_mcp/tools/script_verify_tools.gd")

var _symbol_tools: RefCounted = ScriptSymbolToolsScript.new()
var _write_tools: RefCounted = ScriptWriteToolsScript.new()
var _verify_tools: RefCounted = ScriptVerifyToolsScript.new()

func initialize(editor_interface: EditorInterface) -> void:
	_symbol_tools.initialize(editor_interface)
	_write_tools.initialize(editor_interface)
	_verify_tools.initialize(editor_interface)

func register_tools(server_core: RefCounted) -> void:
	# 兼容路径：正常启动经 TOOL_SCRIPT_PATHS 直接注册四个子模块，不经过本壳。
	_symbol_tools.register_tools(server_core)
	_write_tools.register_tools(server_core)
	_verify_tools.register_tools(server_core)

## change_set_tools.gd 的既有静态引用经此转发。
static func _script_buffer_write_guard(script_editor: Object, script_path: String) -> Dictionary:
	return ScriptWriteToolsScript._script_buffer_write_guard(script_editor, script_path)

# ---- 发现/符号索引/搜索域转发（script_symbol_tools.gd）----

func _tool_list_project_scripts(params: Dictionary) -> Dictionary:
	return _symbol_tools._tool_list_project_scripts(params)

func _tool_list_project_script_symbols(params: Dictionary) -> Dictionary:
	return _symbol_tools._tool_list_project_script_symbols(params)

func _tool_find_script_symbol_definition(params: Dictionary) -> Dictionary:
	return _symbol_tools._tool_find_script_symbol_definition(params)

func _tool_find_script_symbol_references(params: Dictionary) -> Dictionary:
	return _symbol_tools._tool_find_script_symbol_references(params)

func _tool_read_script(params: Dictionary) -> Dictionary:
	return _symbol_tools._tool_read_script(params)

func _tool_batch_read_scripts(params: Dictionary) -> Dictionary:
	return _symbol_tools._tool_batch_read_scripts(params)

func _tool_search_in_files(params: Dictionary) -> Dictionary:
	return _symbol_tools._tool_search_in_files(params)

# ---- 写入域转发（script_write_tools.gd）----

func _tool_rename_script_symbol(params: Dictionary) -> Dictionary:
	return _write_tools._tool_rename_script_symbol(params)

func _tool_create_script(params: Dictionary) -> Dictionary:
	return _write_tools._tool_create_script(params)

func _tool_modify_script(params: Dictionary) -> Dictionary:
	return _write_tools._tool_modify_script(params)

func _tool_open_script_at_line(params: Dictionary) -> Dictionary:
	return _write_tools._tool_open_script_at_line(params)

func _tool_attach_script(params: Dictionary) -> Dictionary:
	return _write_tools._tool_attach_script(params)

# ---- 验证/分析域转发（script_verify_tools.gd）----

func _tool_analyze_script(params: Dictionary) -> Dictionary:
	return _verify_tools._tool_analyze_script(params)

func _tool_get_current_script(params: Dictionary) -> Dictionary:
	return _verify_tools._tool_get_current_script(params)

func _tool_validate_script(params: Dictionary) -> Dictionary:
	return _verify_tools._tool_validate_script(params)

func _tool_verify_scripts(params: Dictionary) -> Dictionary:
	return _verify_tools._tool_verify_scripts(params)

func _tool_validate_shader(params: Dictionary) -> Dictionary:
	return _verify_tools._tool_validate_shader(params)

# ---- 私有辅助的兼容转发（测试直接调用；归属见各子模块）----

func _spaces_to_tabs(code: String) -> String:
	return ScriptToolsSharedScript._spaces_to_tabs(code)

func _rename_symbol_in_file(file_path: String, symbol_name: String, new_name: String,
		case_sensitive: bool, dry_run: bool, remaining_results: int) -> Dictionary:
	return _write_tools._rename_symbol_in_file(file_path, symbol_name, new_name,
		case_sensitive, dry_run, remaining_results)

func _build_autoload_declarations() -> String:
	return _verify_tools._build_autoload_declarations()

func _get_autoload_declarations_cached() -> String:
	return _verify_tools._get_autoload_declarations_cached()

func _collect_gd_scripts_excluding(directory_path: String, result: Array, skip_dir_names: Array) -> void:
	_verify_tools._collect_gd_scripts_excluding(directory_path, result, skip_dir_names)

func _collect_verify_script_paths(result: Array) -> void:
	_verify_tools._collect_verify_script_paths(result)

func _extract_error_line(error_text: String) -> int:
	return ScriptVerifyToolsScript._extract_error_line(error_text)

func _strip_class_names(source: String) -> String:
	return _verify_tools._strip_class_names(source)
