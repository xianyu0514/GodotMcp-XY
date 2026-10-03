# ScriptSymbolTools - Script Tools 发现/符号索引/搜索 + 跨域共享纯函数辅助
# 从 script_tools_native.gd 按域拆分（2026-10-03 启动性能：GDScript 编译
# 分帧粒度细化——原单文件 456ms 编译占满一整帧，按域拆分后每模块独立编译
# 独立分帧）。纯机械迁移 + 少量共享纯函数辅助 static 化，函数体未改。

class_name ScriptSymbolTools
extends RefCounted

const VIBE_CODING_POLICY = preload("res://addons/godot_mcp/utils/vibe_coding_policy.gd")
const ScriptCompileMemoScript = preload("res://addons/godot_mcp/utils/script_compile_memo.gd")
const GeneratedCacheFilterScript = preload("res://addons/godot_mcp/utils/generated_cache_filter.gd")
const SCENE_CONTEXT = preload("res://addons/godot_mcp/utils/scene_context.gd")
const SCRIPT_WRITE_DIAGNOSTICS = preload("res://addons/godot_mcp/utils/script_write_diagnostics.gd")
const ChangeJournalScript = preload("res://addons/godot_mcp/tools/change_journal.gd")

const ScriptToolsSharedScript = preload("res://addons/godot_mcp/tools/script_tools_shared.gd")

var _editor_interface: EditorInterface = null

func initialize(editor_interface: EditorInterface) -> void:
	_editor_interface = editor_interface

func _get_editor_interface() -> EditorInterface:
	if _editor_interface:
		return _editor_interface
	if Engine.has_meta("GodotMCPPlugin"):
		var plugin = Engine.get_meta("GodotMCPPlugin")
		if plugin and plugin.has_method("get_editor_interface"):
			return plugin.get_editor_interface()
	return null

func _is_vibe_coding_mode() -> bool:
	if Engine.has_meta("GodotMCPPlugin"):
		var plugin = Engine.get_meta("GodotMCPPlugin")
		if plugin and plugin.get("vibe_coding_mode") != null:
			return bool(plugin.vibe_coding_mode)
	return true



## 注册本域全部工具（由 TOOL_SCRIPT_PATHS 的模块条目调用；
## 顺序即本文件内注册函数的出现顺序）。
func register_tools(server_core: RefCounted) -> void:
	_register_list_project_scripts(server_core)
	_register_list_project_script_symbols(server_core)
	_register_find_script_symbol_definition(server_core)
	_register_find_script_symbol_references(server_core)
	_register_read_script(server_core)
	_register_batch_read_scripts(server_core)
	_register_search_in_files(server_core)

func _register_list_project_scripts(server_core: RefCounted) -> void:
	var tool_name: String = "list_project_scripts"
	var description: String = "List GDScript (.gd) and C# (.cs) script files in the project. Tooling directories (addons/test/docs) are excluded by default so plugin scripts cannot drown out project scripts; pass include_tooling=true or point search_path into a tooling directory to list them. Supports limit/offset pagination; count is the page size and total_count is the full total. Returns paths relative to res://."
	
	# inputSchema
	var input_schema: Dictionary = {
		"type": "object",
		"properties": {
			"search_path": {
				"type": "string",
				"description": "Optional subpath to search (e.g. 'res://scripts/'). Default is 'res://'.",
				"default": "res://"
			},
			"include_tooling": {
				"type": "boolean",
				"description": "Include tooling directories (addons/test/docs). Default false; implied when search_path itself points into a tooling directory."
			},
			"limit": {
				"type": "integer",
				"description": "Maximum number of script paths to return. Default is 1000. Extra paths are omitted and 'truncated' is set true."
			},
			"offset": {
				"type": "integer",
				"description": "Number of script paths to skip before applying limit. Default 0."
			}
		}
	}
	
	# outputSchema
	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"scripts": {
				"type": "array",
				"items": {"type": "string"}
			},
			"count": {"type": "integer", "description": "Number of script paths in this page."},
			"total_count": {"type": "integer", "description": "Total number of script paths before limit/offset pagination."},
			"truncated": {"type": "boolean", "description": "True when more script paths remain after this page."},
			"include_tooling": {"type": "boolean", "description": "Whether tooling directories were included in this listing."}
		}
	}
	
	# annotations - readOnlyHint = true
	var annotations: Dictionary = {
		"readOnlyHint": true,
		"destructiveHint": false,
		"idempotentHint": true,
		"openWorldHint": false
	}
	
	# 注册工具
	server_core.register_tool(tool_name, description, input_schema,
						  Callable(self, "_tool_list_project_scripts"),
						  output_schema, annotations,
						  "core", "Script")


func _tool_list_project_scripts(params: Dictionary) -> Dictionary:
	# 参数提取
	var search_path: String = params.get("search_path", "res://")

	# 使用PathValidator验证路径安全性
	var validation: Dictionary = PathValidator.validate_directory_path(search_path)
	if not validation["valid"]:
		return {"error": "Invalid path: " + validation["error"]}

	# 使用清理后的路径
	search_path = validation["sanitized"]

	# 文件发现走统一收集器：跳过 .godot/.import 生成域。工具目录（addons/test/docs）
	# 默认排除——此前裸 DirAccess 会让插件自身脚本淹没项目脚本（2026-09-27 体检
	# P1-5：res:// 下前 30 条里 27 条是 addons/godot_mcp）。显式 include_tooling
	# 或 search_path 本身指向工具目录时仍可列出，与 search_in_files 同语义。
	var include_tooling: bool = params.get("include_tooling",
		GeneratedCacheFilterScript.domain_of(search_path) == GeneratedCacheFilterScript.Domain.TOOLING)
	var normalized_extensions: Array[String] = [".gd", ".cs"]
	var collected: Array[String] = []
	ProjectToolsNative._collect_resources(search_path, normalized_extensions, collected, false, include_tooling)

	# 排序
	var scripts: Array = []
	for path_value in collected:
		scripts.append(path_value)
	scripts.sort()

	var limit: int = int(params.get("limit", 1000))
	if limit <= 0:
		limit = 1000
	var offset: int = int(params.get("offset", 0))
	var page: Dictionary = PayloadUtils.paginate_list(scripts, limit, offset)
	var scripts_page: Array = page["items"]

	return {
		"scripts": scripts_page,
		"count": scripts_page.size(),
		"total_count": page["total_count"],
		"truncated": page["truncated"],
		"include_tooling": include_tooling
	}

# ============================================================================
# list_project_script_symbols - 列出项目脚本符号索引
# ============================================================================


func _register_list_project_script_symbols(server_core: RefCounted) -> void:
	var tool_name: String = "list_project_script_symbols"
	var description: String = "Index script symbols across project GDScript and C# files. Returns class, extends, functions, signals, properties, and constants."

	var input_schema: Dictionary = {
		"type": "object",
		"properties": {
			"search_path": {
				"type": "string",
				"description": "Optional subpath to search (e.g. 'res://scripts/'). Default is 'res://'.",
				"default": "res://"
			},
			"include_extensions": {
				"type": "array",
				"items": {"type": "string"},
				"description": "Script file extensions to include. Supported values are '.gd' and '.cs'. Default is ['.gd', '.cs'].",
				"default": [".gd", ".cs"]
			},
			"symbol_kinds": {
				"type": "array",
				"items": {"type": "string"},
				"description": "Optional symbol kinds to keep: 'function', 'signal', 'property', 'constant'."
			},
			"name_filter": {
				"type": "string",
				"description": "Optional case-insensitive substring filter applied to symbol names."
			}
		}
	}

	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"scripts": {"type": "array", "items": {"type": "object"}},
			"count": {"type": "integer"}
		}
	}

	var annotations: Dictionary = {
		"readOnlyHint": true,
		"destructiveHint": false,
		"idempotentHint": true,
		"openWorldHint": false
	}

	server_core.register_tool(tool_name, description, input_schema,
						  Callable(self, "_tool_list_project_script_symbols"),
						  output_schema, annotations,
						  "supplementary", "Script-Advanced")


func _tool_list_project_script_symbols(params: Dictionary) -> Dictionary:
	var search_path: String = str(params.get("search_path", "res://")).strip_edges()
	var validation: Dictionary = PathValidator.validate_directory_path(search_path)
	if not validation["valid"]:
		return {"error": "Invalid path: " + validation["error"]}
	search_path = validation["sanitized"]

	var include_extensions: Array = ScriptToolsSharedScript._normalize_script_extensions(params.get("include_extensions", [".gd", ".cs"]))
	if include_extensions.is_empty():
		return {"error": "include_extensions must contain at least one supported script extension"}

	var symbol_kinds: Array = ScriptToolsSharedScript._normalize_symbol_kinds(params.get("symbol_kinds", []))
	var name_filter: String = str(params.get("name_filter", "")).strip_edges().to_lower()
	var script_paths: Array = []
	ScriptToolsSharedScript._collect_script_files(search_path, include_extensions, script_paths)
	script_paths.sort()

	var scripts: Array = []
	for script_path in script_paths:
		var entry: Dictionary = _index_script_symbols(script_path)
		if entry.has("error"):
			continue
		entry = _filter_script_symbol_entry(entry, symbol_kinds, name_filter)
		if entry.is_empty():
			continue
		scripts.append(entry)

	return {
		"scripts": scripts,
		"count": scripts.size()
	}

# ============================================================================
# find_script_symbol_definition - 查找脚本符号定义
# ============================================================================


func _register_find_script_symbol_definition(server_core: RefCounted) -> void:
	var tool_name: String = "find_script_symbol_definition"
	var description: String = "Find definition locations for a script symbol across GDScript and C# project files."

	var input_schema: Dictionary = {
		"type": "object",
		"properties": {
			"symbol_name": {
				"type": "string",
				"description": "Symbol name to resolve, such as 'ready_up', 'Spawned', or 'TempSymbolTarget'."
			},
			"search_path": {
				"type": "string",
				"description": "Optional subpath to search (e.g. 'res://scripts/'). Default is 'res://'.",
				"default": "res://"
			},
			"include_extensions": {
				"type": "array",
				"items": {"type": "string"},
				"description": "Script file extensions to include. Supported values are '.gd' and '.cs'. Default is ['.gd', '.cs'].",
				"default": [".gd", ".cs"]
			},
			"symbol_kinds": {
				"type": "array",
				"items": {"type": "string"},
				"description": "Optional symbol kinds to keep: 'class', 'function', 'signal', 'property', 'constant'."
			},
			"preferred_script_path": {
				"type": "string",
				"description": "Optional preferred script path to rank first when multiple matches exist."
			},
			"max_results": {
				"type": "integer",
				"description": "Maximum number of definitions to return. Default is 20.",
				"default": 20
			}
		},
		"required": ["symbol_name"]
	}

	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"symbol_name": {"type": "string"},
			"definitions": {"type": "array", "items": {"type": "object"}},
			"count": {"type": "integer"}
		}
	}

	var annotations: Dictionary = {
		"readOnlyHint": true,
		"destructiveHint": false,
		"idempotentHint": true,
		"openWorldHint": false
	}

	server_core.register_tool(tool_name, description, input_schema,
						  Callable(self, "_tool_find_script_symbol_definition"),
						  output_schema, annotations,
						  "supplementary", "Script-Advanced")


func _tool_find_script_symbol_definition(params: Dictionary) -> Dictionary:
	var symbol_name: String = str(params.get("symbol_name", "")).strip_edges()
	if symbol_name.is_empty():
		return {"error": "Missing required parameter: symbol_name"}

	var search_path: String = str(params.get("search_path", "res://")).strip_edges()
	var path_validation: Dictionary = PathValidator.validate_directory_path(search_path)
	if not path_validation["valid"]:
		return {"error": "Invalid path: " + path_validation["error"]}
	search_path = path_validation["sanitized"]

	var include_extensions: Array = ScriptToolsSharedScript._normalize_script_extensions(params.get("include_extensions", [".gd", ".cs"]))
	if include_extensions.is_empty():
		return {"error": "include_extensions must contain at least one supported script extension"}

	var symbol_kinds: Array = ScriptToolsSharedScript._normalize_definition_symbol_kinds(params.get("symbol_kinds", []))
	var preferred_script_path: String = str(params.get("preferred_script_path", "")).strip_edges()
	var max_results: int = max(1, int(params.get("max_results", 20)))

	var script_paths: Array = []
	ScriptToolsSharedScript._collect_script_files(search_path, include_extensions, script_paths)
	script_paths.sort()
	if not preferred_script_path.is_empty():
		script_paths.sort_custom(Callable(self, "_compare_script_paths_for_preference").bind(preferred_script_path))

	var definitions: Array = []
	for script_path in script_paths:
		if definitions.size() >= max_results:
			break
		var matches: Array = _find_symbol_definitions_in_script(script_path, symbol_name, symbol_kinds)
		for match in matches:
			definitions.append(match)
			if definitions.size() >= max_results:
				break

	return {
		"symbol_name": symbol_name,
		"definitions": definitions,
		"count": definitions.size()
	}

# ============================================================================
# find_script_symbol_references - 查找脚本符号引用
# ============================================================================


func _register_find_script_symbol_references(server_core: RefCounted) -> void:
	var tool_name: String = "find_script_symbol_references"
	var description: String = "Find textual project references to a script symbol across GDScript, C#, and scene files."

	var input_schema: Dictionary = {
		"type": "object",
		"properties": {
			"symbol_name": {
				"type": "string",
				"description": "Symbol name to search for, such as 'TempReferenceTarget' or 'ready_up'."
			},
			"search_path": {
				"type": "string",
				"description": "Optional subpath to search (e.g. 'res://scripts/'). Default is 'res://'.",
				"default": "res://"
			},
			"include_extensions": {
				"type": "array",
				"items": {"type": "string"},
				"description": "File extensions to search. Supported values are '.gd', '.cs', and '.tscn'. Default is ['.gd', '.cs', '.tscn'].",
				"default": [".gd", ".cs", ".tscn"]
			},
			"include_definitions": {
				"type": "boolean",
				"description": "Whether to include definition lines in the result. Default is false.",
				"default": false
			},
			"case_sensitive": {
				"type": "boolean",
				"description": "Whether symbol matching is case-sensitive. Default is true.",
				"default": true
			},
			"preferred_script_path": {
				"type": "string",
				"description": "Optional preferred script path to rank first when multiple reference files exist."
			},
			"max_results": {
				"type": "integer",
				"description": "Maximum number of reference matches to return. Default is 100.",
				"default": 100
			}
		},
		"required": ["symbol_name"]
	}

	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"symbol_name": {"type": "string"},
			"references": {"type": "array", "items": {"type": "object"}},
			"count": {"type": "integer"}
		}
	}

	var annotations: Dictionary = {
		"readOnlyHint": true,
		"destructiveHint": false,
		"idempotentHint": true,
		"openWorldHint": false
	}

	server_core.register_tool(tool_name, description, input_schema,
						  Callable(self, "_tool_find_script_symbol_references"),
						  output_schema, annotations,
						  "supplementary", "Script-Advanced")


func _tool_find_script_symbol_references(params: Dictionary) -> Dictionary:
	var symbol_name: String = str(params.get("symbol_name", "")).strip_edges()
	if symbol_name.is_empty():
		return {"error": "Missing required parameter: symbol_name"}

	var search_path: String = str(params.get("search_path", "res://")).strip_edges()
	var path_validation: Dictionary = PathValidator.validate_directory_path(search_path)
	if not path_validation["valid"]:
		return {"error": "Invalid path: " + path_validation["error"]}
	search_path = path_validation["sanitized"]

	var include_extensions: Array = ScriptToolsSharedScript._normalize_reference_extensions(params.get("include_extensions", [".gd", ".cs", ".tscn"]))
	if include_extensions.is_empty():
		return {"error": "include_extensions must contain at least one supported file extension"}

	var include_definitions: bool = bool(params.get("include_definitions", false))
	var case_sensitive: bool = bool(params.get("case_sensitive", true))
	var preferred_script_path: String = str(params.get("preferred_script_path", "")).strip_edges()
	var max_results: int = max(1, int(params.get("max_results", 100)))

	var file_paths: Array = []
	ScriptToolsSharedScript._collect_script_reference_files(search_path, include_extensions, file_paths,
		GeneratedCacheFilterScript.domain_of(search_path) == GeneratedCacheFilterScript.Domain.TOOLING)
	file_paths.sort()
	if not preferred_script_path.is_empty():
		file_paths.sort_custom(Callable(self, "_compare_script_paths_for_preference").bind(preferred_script_path))

	var reference_regex: RegEx = _symbol_reference_regex(symbol_name, case_sensitive)

	var references: Array = []
	for file_path in file_paths:
		if references.size() >= max_results:
			break
		# 每文件只读一次：定义行与引用匹配共用同一份行数组（此前定义扫描
		# 与引用扫描各读一遍文件），且定义行只在本文件确有匹配时才计算。
		var file: FileAccess = FileAccess.open(file_path, FileAccess.READ)
		if not file:
			continue
		var lines: PackedStringArray = file.get_as_text().split("\n")
		file.close()
		var has_match: bool = false
		for line_value in lines:
			if reference_regex.is_valid() and reference_regex.search(String(line_value)):
				has_match = true
				break
		if not has_match:
			continue
		var definition_lines: Array = []
		if not include_definitions and (file_path.ends_with(".gd") or file_path.ends_with(".cs")):
			definition_lines = _definition_lines_for_content(file_path, lines, symbol_name, case_sensitive)
		var matches: Array = _find_symbol_references_in_lines(file_path, lines, reference_regex, include_definitions, definition_lines, max_results - references.size())
		for match in matches:
			references.append(match)
			if references.size() >= max_results:
				break

	# Annotate references with Autoload singleton name when a referenced script is an Autoload
	var autoload_path_map: Dictionary = ScriptToolsSharedScript._build_autoload_path_map()
	for ref in references:
		if ref is Dictionary:
			var ref_file: String = str(ref.get("file_path", ref.get("script_path", "")))
			if autoload_path_map.has(ref_file):
				ref["autoload_name"] = autoload_path_map[ref_file]

	return {
		"symbol_name": symbol_name,
		"references": references,
		"count": references.size()
	}


func _index_script_symbols(script_path: String) -> Dictionary:
	var file: FileAccess = FileAccess.open(script_path, FileAccess.READ)
	if not file:
		return {"error": "Failed to open file: " + script_path}
	var content: String = file.get_as_text()
	file.close()

	if script_path.ends_with(".gd"):
		return _index_gdscript_symbols(script_path, content)
	if script_path.ends_with(".cs"):
		return _index_csharp_symbols(script_path, content)
	return {"error": "Unsupported script extension: " + script_path}


func _index_gdscript_symbols(script_path: String, content: String) -> Dictionary:
	var all_lines: PackedStringArray = content.split("\n")
	var line_count: int = all_lines.size()
	var has_class_name: bool = false
	var class_name_value: String = ""
	var extends_from: String = ""
	var functions: Array = []
	var signals: Array = []
	var properties: Array = []
	var constants: Array = []

	for line in all_lines:
		var trimmed: String = ScriptToolsSharedScript._strip_inline_comment(line).strip_edges()
		if trimmed.is_empty():
			continue
		if trimmed.begins_with("class_name "):
			has_class_name = true
			class_name_value = trimmed.trim_prefix("class_name ").split(" ")[0].strip_edges()
		elif trimmed.begins_with("extends ") and extends_from.is_empty():
			extends_from = trimmed.trim_prefix("extends ").split(" ")[0].strip_edges()
		elif trimmed.begins_with("func "):
			var func_name: String = trimmed.trim_prefix("func ").split("(")[0].strip_edges()
			if not func_name.is_empty():
				functions.append(func_name)
		elif trimmed.begins_with("signal "):
			var signal_name: String = trimmed.trim_prefix("signal ").split("(")[0].strip_edges()
			if not signal_name.is_empty():
				signals.append(signal_name)
		elif trimmed.begins_with("const "):
			var const_name: String = trimmed.trim_prefix("const ").split(":")[0].split("=")[0].strip_edges()
			if not const_name.is_empty():
				constants.append(const_name)
		elif trimmed.begins_with("var ") and not trimmed.begins_with("var _"):
			var var_name: String = trimmed.trim_prefix("var ").split(":")[0].split("=")[0].strip_edges()
			if not var_name.is_empty():
				properties.append(var_name)

	return {
		"script_path": script_path,
		"language": "gdscript",
		"class_name": class_name_value,
		"has_class_name": has_class_name,
		"extends_from": extends_from,
		"functions": functions,
		"signals": signals,
		"properties": properties,
		"constants": constants,
		"line_count": line_count,
		"symbol_count": functions.size() + signals.size() + properties.size() + constants.size()
	}


var _csharp_symbol_regex_cache: Dictionary = {}


func _csharp_symbol_regex(kind: String) -> RegEx:
	if _csharp_symbol_regex_cache.is_empty():
		var patterns: Dictionary = {
			"class": "class\\s+([A-Za-z_][A-Za-z0-9_]*)\\s*(?::\\s*([A-Za-z_][A-Za-z0-9_\\.]*))?",
			"method": "(?:public|private|protected|internal)\\s+(?:override\\s+|virtual\\s+|static\\s+|async\\s+|partial\\s+)*[A-Za-z_][A-Za-z0-9_<>\\.?\\[\\]]*\\s+([A-Za-z_][A-Za-z0-9_]*)\\s*\\(",
			"property": "(?:public|private|protected|internal)\\s+(?:static\\s+)?[A-Za-z_][A-Za-z0-9_<>\\.?\\[\\]]*\\s+([A-Za-z_][A-Za-z0-9_]*)\\s*\\{",
			"constant": "(?:public|private|protected|internal)\\s+const\\s+[A-Za-z_][A-Za-z0-9_<>\\.?\\[\\]]*\\s+([A-Za-z_][A-Za-z0-9_]*)",
			"delegate": "delegate\\s+void\\s+([A-Za-z_][A-Za-z0-9_]*)EventHandler\\s*\\("
		}
		for kind_value in patterns:
			var regex: RegEx = RegEx.new()
			regex.compile(String(patterns[kind_value]))
			_csharp_symbol_regex_cache[kind_value] = regex
	return _csharp_symbol_regex_cache.get(kind, RegEx.new())


func _index_csharp_symbols(script_path: String, content: String) -> Dictionary:
	var all_lines: PackedStringArray = content.split("\n")
	var line_count: int = all_lines.size()
	var class_name_value: String = ""
	var extends_from: String = ""
	var functions: Array = []
	var signals: Array = []
	var properties: Array = []
	var constants: Array = []
	var next_delegate_is_signal: bool = false

	# 五个模式为字面量：首次调用编译一次并按名复用（此前每个文件重编译五次）。
	var class_regex: RegEx = _csharp_symbol_regex("class")
	var method_regex: RegEx = _csharp_symbol_regex("method")
	var property_regex: RegEx = _csharp_symbol_regex("property")
	var constant_regex: RegEx = _csharp_symbol_regex("constant")
	var delegate_regex: RegEx = _csharp_symbol_regex("delegate")

	for line in all_lines:
		var trimmed: String = ScriptToolsSharedScript._strip_csharp_line_comment(line).strip_edges()
		if trimmed.is_empty():
			continue

		if trimmed.contains("[Signal]"):
			next_delegate_is_signal = true
			continue

		if class_name_value.is_empty():
			var class_match: RegExMatch = class_regex.search(trimmed)
			if class_match:
				class_name_value = class_match.get_string(1)
				extends_from = class_match.get_string(2)
				continue

		var constant_match: RegExMatch = constant_regex.search(trimmed)
		if constant_match:
			constants.append(constant_match.get_string(1))
			continue

		if next_delegate_is_signal:
			var delegate_match: RegExMatch = delegate_regex.search(trimmed)
			if delegate_match:
				signals.append(delegate_match.get_string(1))
			next_delegate_is_signal = false
			continue

		var property_match: RegExMatch = property_regex.search(trimmed)
		if property_match and trimmed.contains("get;"):
			properties.append(property_match.get_string(1))
			continue

		var method_match: RegExMatch = method_regex.search(trimmed)
		if method_match and not trimmed.contains(" class "):
			functions.append(method_match.get_string(1))

	return {
		"script_path": script_path,
		"language": "csharp",
		"class_name": class_name_value,
		"has_class_name": not class_name_value.is_empty(),
		"extends_from": extends_from,
		"functions": functions,
		"signals": signals,
		"properties": properties,
		"constants": constants,
		"line_count": line_count,
		"symbol_count": functions.size() + signals.size() + properties.size() + constants.size()
	}


func _filter_script_symbol_entry(entry: Dictionary, symbol_kinds: Array, name_filter: String) -> Dictionary:
	var filtered: Dictionary = entry.duplicate(true)
	var include_all_kinds: bool = symbol_kinds.is_empty()
	var functions: Array = entry.get("functions", []).duplicate()
	var signals: Array = entry.get("signals", []).duplicate()
	var properties: Array = entry.get("properties", []).duplicate()
	var constants: Array = entry.get("constants", []).duplicate()

	if not include_all_kinds and not symbol_kinds.has("function"):
		functions.clear()
	if not include_all_kinds and not symbol_kinds.has("signal"):
		signals.clear()
	if not include_all_kinds and not symbol_kinds.has("property"):
		properties.clear()
	if not include_all_kinds and not symbol_kinds.has("constant"):
		constants.clear()

	functions = _filter_symbol_names(functions, name_filter)
	signals = _filter_symbol_names(signals, name_filter)
	properties = _filter_symbol_names(properties, name_filter)
	constants = _filter_symbol_names(constants, name_filter)

	filtered["functions"] = functions
	filtered["signals"] = signals
	filtered["properties"] = properties
	filtered["constants"] = constants
	filtered["symbol_count"] = functions.size() + signals.size() + properties.size() + constants.size()

	if name_filter.is_empty():
		return filtered

	if filtered["symbol_count"] > 0:
		return filtered

	var class_name_value: String = str(filtered.get("class_name", "")).to_lower()
	var extends_from: String = str(filtered.get("extends_from", "")).to_lower()
	if class_name_value.contains(name_filter) or extends_from.contains(name_filter):
		return filtered
	return {}


func _filter_symbol_names(names: Array, name_filter: String) -> Array:
	if name_filter.is_empty():
		return names
	var filtered: Array = []
	for name in names:
		var name_text: String = str(name)
		if name_text.to_lower().contains(name_filter):
			filtered.append(name_text)
	return filtered


func _find_symbol_definitions_in_script(script_path: String, symbol_name: String, symbol_kinds: Array) -> Array:
	var file: FileAccess = FileAccess.open(script_path, FileAccess.READ)
	if not file:
		return []
	var content: String = file.get_as_text()
	file.close()

	if script_path.ends_with(".gd"):
		return _find_gdscript_symbol_definitions(script_path, content, symbol_name, symbol_kinds)
	if script_path.ends_with(".cs"):
		return _find_csharp_symbol_definitions(script_path, content, symbol_name, symbol_kinds)
	return []


func _find_gdscript_symbol_definitions(script_path: String, content: String, symbol_name: String, symbol_kinds: Array) -> Array:
	var definitions: Array = []
	var class_name_value: String = ""
	var extends_from: String = ""
	var include_all_kinds: bool = symbol_kinds.is_empty()

	var lines: PackedStringArray = content.split("\n")
	for i in range(lines.size()):
		var raw_line: String = lines[i]
		var trimmed: String = ScriptToolsSharedScript._strip_inline_comment(raw_line).strip_edges()
		if trimmed.is_empty():
			continue

		if trimmed.begins_with("class_name "):
			class_name_value = trimmed.trim_prefix("class_name ").split(" ")[0].strip_edges()
			if (include_all_kinds or symbol_kinds.has("class")) and class_name_value == symbol_name:
				definitions.append(_build_symbol_definition(script_path, "gdscript", class_name_value, extends_from, "class", class_name_value, i + 1, raw_line.strip_edges()))
			continue

		if trimmed.begins_with("extends ") and extends_from.is_empty():
			extends_from = trimmed.trim_prefix("extends ").split(" ")[0].strip_edges()
			continue

		if (include_all_kinds or symbol_kinds.has("signal")) and trimmed.begins_with("signal "):
			var signal_name: String = trimmed.trim_prefix("signal ").split("(")[0].strip_edges()
			if signal_name == symbol_name:
				definitions.append(_build_symbol_definition(script_path, "gdscript", class_name_value, extends_from, "signal", signal_name, i + 1, raw_line.strip_edges()))
			continue

		if (include_all_kinds or symbol_kinds.has("constant")) and trimmed.begins_with("const "):
			var const_name: String = trimmed.trim_prefix("const ").split(":")[0].split("=")[0].strip_edges()
			if const_name == symbol_name:
				definitions.append(_build_symbol_definition(script_path, "gdscript", class_name_value, extends_from, "constant", const_name, i + 1, raw_line.strip_edges()))
			continue

		if (include_all_kinds or symbol_kinds.has("property")) and trimmed.begins_with("var ") and not trimmed.begins_with("var _"):
			var property_name: String = trimmed.trim_prefix("var ").split(":")[0].split("=")[0].strip_edges()
			if property_name == symbol_name:
				definitions.append(_build_symbol_definition(script_path, "gdscript", class_name_value, extends_from, "property", property_name, i + 1, raw_line.strip_edges()))
			continue

		if (include_all_kinds or symbol_kinds.has("function")) and trimmed.begins_with("func "):
			var function_name: String = trimmed.trim_prefix("func ").split("(")[0].strip_edges()
			if function_name == symbol_name:
				definitions.append(_build_symbol_definition(script_path, "gdscript", class_name_value, extends_from, "function", function_name, i + 1, raw_line.strip_edges()))

	return definitions


func _find_csharp_symbol_definitions(script_path: String, content: String, symbol_name: String, symbol_kinds: Array) -> Array:
	var definitions: Array = []
	var class_name_value: String = ""
	var extends_from: String = ""
	var include_all_kinds: bool = symbol_kinds.is_empty()
	var next_delegate_is_signal: bool = false

	var class_regex: RegEx = RegEx.new()
	class_regex.compile("class\\s+([A-Za-z_][A-Za-z0-9_]*)\\s*(?::\\s*([A-Za-z_][A-Za-z0-9_\\.]*))?")
	var method_regex: RegEx = RegEx.new()
	method_regex.compile("(?:public|private|protected|internal)\\s+(?:override\\s+|virtual\\s+|static\\s+|async\\s+|partial\\s+)*[A-Za-z_][A-Za-z0-9_<>\\.?\\[\\]]*\\s+([A-Za-z_][A-Za-z0-9_]*)\\s*\\(")
	var property_regex: RegEx = RegEx.new()
	property_regex.compile("(?:public|private|protected|internal)\\s+(?:static\\s+)?[A-Za-z_][A-Za-z0-9_<>\\.?\\[\\]]*\\s+([A-Za-z_][A-Za-z0-9_]*)\\s*\\{")
	var constant_regex: RegEx = RegEx.new()
	constant_regex.compile("(?:public|private|protected|internal)\\s+const\\s+[A-Za-z_][A-Za-z0-9_<>\\.?\\[\\]]*\\s+([A-Za-z_][A-Za-z0-9_]*)")
	var delegate_regex: RegEx = RegEx.new()
	delegate_regex.compile("delegate\\s+void\\s+([A-Za-z_][A-Za-z0-9_]*)EventHandler\\s*\\(")

	var lines: PackedStringArray = content.split("\n")
	for i in range(lines.size()):
		var raw_line: String = lines[i]
		var trimmed: String = ScriptToolsSharedScript._strip_csharp_line_comment(raw_line).strip_edges()
		if trimmed.is_empty():
			continue

		if trimmed.contains("[Signal]"):
			next_delegate_is_signal = true
			continue

		if class_name_value.is_empty():
			var class_match: RegExMatch = class_regex.search(trimmed)
			if class_match:
				class_name_value = class_match.get_string(1)
				extends_from = class_match.get_string(2)
				if (include_all_kinds or symbol_kinds.has("class")) and class_name_value == symbol_name:
					definitions.append(_build_symbol_definition(script_path, "csharp", class_name_value, extends_from, "class", class_name_value, i + 1, raw_line.strip_edges()))
				continue

		if (include_all_kinds or symbol_kinds.has("constant")):
			var constant_match: RegExMatch = constant_regex.search(trimmed)
			if constant_match and constant_match.get_string(1) == symbol_name:
				definitions.append(_build_symbol_definition(script_path, "csharp", class_name_value, extends_from, "constant", symbol_name, i + 1, raw_line.strip_edges()))
				continue

		if next_delegate_is_signal:
			var delegate_match: RegExMatch = delegate_regex.search(trimmed)
			if delegate_match:
				var delegate_name: String = delegate_match.get_string(1)
				if (include_all_kinds or symbol_kinds.has("signal")) and delegate_name == symbol_name:
					definitions.append(_build_symbol_definition(script_path, "csharp", class_name_value, extends_from, "signal", delegate_name, i + 1, raw_line.strip_edges()))
			next_delegate_is_signal = false
			continue

		if (include_all_kinds or symbol_kinds.has("property")):
			var property_match: RegExMatch = property_regex.search(trimmed)
			if property_match and trimmed.contains("get;"):
				var property_name: String = property_match.get_string(1)
				if property_name == symbol_name:
					definitions.append(_build_symbol_definition(script_path, "csharp", class_name_value, extends_from, "property", property_name, i + 1, raw_line.strip_edges()))
					continue

		if (include_all_kinds or symbol_kinds.has("function")):
			var method_match: RegExMatch = method_regex.search(trimmed)
			if method_match and not trimmed.contains(" class "):
				var function_name: String = method_match.get_string(1)
				if function_name == symbol_name:
					definitions.append(_build_symbol_definition(script_path, "csharp", class_name_value, extends_from, "function", function_name, i + 1, raw_line.strip_edges()))

	return definitions


func _build_symbol_definition(script_path: String, language: String, class_name_value: String, extends_from: String, symbol_kind: String, symbol_name: String, line: int, context_line: String) -> Dictionary:
	return {
		"script_path": script_path,
		"language": language,
		"class_name": class_name_value,
		"extends_from": extends_from,
		"symbol_kind": symbol_kind,
		"symbol_name": symbol_name,
		"line": line,
		"context_line": context_line
	}


func _compare_script_paths_for_preference(left: String, right: String, preferred_script_path: String) -> bool:
	var left_preferred: bool = left == preferred_script_path
	var right_preferred: bool = right == preferred_script_path
	if left_preferred != right_preferred:
		return left_preferred
	return left < right

## 引用文件收集走统一收集器：跳过 .godot/.import 生成域（此前裸 DirAccess
## 会下探引擎缓存目录）。工具目录按调用方推断包含。


func _collect_definition_lines_by_path(file_paths: Array, symbol_name: String, case_sensitive: bool) -> Dictionary:
	var definitions_by_path: Dictionary = {}
	for file_path in file_paths:
		if not (file_path.ends_with(".gd") or file_path.ends_with(".cs")):
			continue
		var definitions: Array = _find_symbol_definitions_in_script(file_path, symbol_name, [])
		if not case_sensitive:
			var filtered_definitions: Array = []
			for definition in definitions:
				if str(definition.get("symbol_name", "")).to_lower() == symbol_name.to_lower():
					filtered_definitions.append(definition)
			definitions = filtered_definitions
		var lines: Array = []
		for definition in definitions:
			lines.append(int(definition.get("line", 0)))
		if not lines.is_empty():
			definitions_by_path[file_path] = lines
	return definitions_by_path


func _find_symbol_references_in_file(file_path: String, symbol_name: String, case_sensitive: bool, include_definitions: bool, definition_lines: Array, remaining_results: int) -> Array:
	var file: FileAccess = FileAccess.open(file_path, FileAccess.READ)
	if not file:
		return []
	var lines: PackedStringArray = file.get_as_text().split("\n")
	file.close()
	return _find_symbol_references_in_lines(file_path, lines,
		_symbol_reference_regex(symbol_name, case_sensitive),
		include_definitions, definition_lines, remaining_results)


## 符号引用正则按 (symbol, 大小写) 编译一次复用：此前每个文件重编译一次
## 相同模式。上限 64 项（超出即整体重建，符号名空间天然有界）。


var _symbol_regex_cache: Dictionary = {}


func _symbol_reference_regex(symbol_name: String, case_sensitive: bool) -> RegEx:
	var escaped_symbol_name: String = ScriptToolsSharedScript._escape_regex_pattern(symbol_name)
	var compile_pattern: String = "(?i)(?<![A-Za-z0-9_])%s(?![A-Za-z0-9_])" % escaped_symbol_name if not case_sensitive else "(?<![A-Za-z0-9_])%s(?![A-Za-z0-9_])" % escaped_symbol_name
	if _symbol_regex_cache.size() >= 64:
		_symbol_regex_cache.clear()
	if not _symbol_regex_cache.has(compile_pattern):
		var regex: RegEx = RegEx.new()
		if regex.compile(compile_pattern) != OK:
			return RegEx.new()
		_symbol_regex_cache[compile_pattern] = regex
	return _symbol_regex_cache[compile_pattern]


## 从已读取的行数组计算定义行（供引用扫描排除定义处）。


func _definition_lines_for_content(file_path: String, lines: PackedStringArray, symbol_name: String, case_sensitive: bool) -> Array:
	var content: String = "\n".join(lines)
	var definitions: Array
	if file_path.ends_with(".gd"):
		definitions = _find_gdscript_symbol_definitions(file_path, content, symbol_name, [])
	elif file_path.ends_with(".cs"):
		definitions = _find_csharp_symbol_definitions(file_path, content, symbol_name, [])
	else:
		return []
	if not case_sensitive:
		var filtered: Array = []
		for definition in definitions:
			if str(definition.get("symbol_name", "")).to_lower() == symbol_name.to_lower():
				filtered.append(definition)
		definitions = filtered
	var result: Array = []
	for definition in definitions:
		result.append(int(definition.get("line", 0)))
	return result


func _find_symbol_references_in_lines(file_path: String, lines: PackedStringArray, regex: RegEx, include_definitions: bool, definition_lines: Array, remaining_results: int) -> Array:
	var references: Array = []
	if not regex.is_valid():
		return []

	for i in range(lines.size()):
		if references.size() >= remaining_results:
			break
		var line_number: int = i + 1
		if not include_definitions and definition_lines.has(line_number):
			continue
		var raw_line: String = lines[i]
		var search_line: String = raw_line
		if file_path.ends_with(".gd"):
			search_line = ScriptToolsSharedScript._strip_inline_comment(raw_line)
		elif file_path.ends_with(".cs"):
			search_line = ScriptToolsSharedScript._strip_csharp_line_comment(raw_line)
		var matches: Array = regex.search_all(search_line)
		for match in matches:
			references.append({
				"script_path": file_path,
				"line": line_number,
				"column": match.get_start(),
				"match_text": match.get_string(),
				"context_line": raw_line.strip_edges(),
				"is_definition": definition_lines.has(line_number)
			})
			if references.size() >= remaining_results:
				break

	return references


func _register_read_script(server_core: RefCounted) -> void:
	var tool_name: String = "read_script"
	var description: String = "Read complete GDScript (.gd) or C# (.cs) source and its content_hash. Pass this hash as expected_content_hash to modify_script to reject stale writes. Large files: pass offset_lines/max_lines to window the read (content_hash always covers the WHOLE file so the optimistic lock still works); .json/.tscn/.tres/.cfg/.md/.csv belong to read_project_file."

	# inputSchema
	var input_schema: Dictionary = {
		"type": "object",
		"properties": {
			"script_path": {
				"type": "string",
				"description": "Path to the script file (e.g. 'res://scripts/player.gd')"
			},
			"offset_lines": {
				"type": "integer",
				"description": "Zero-based first line to return. Default 0 (whole file).",
				"default": 0
			},
			"max_lines": {
				"type": "integer",
				"description": "Maximum lines per page. Default 0 = whole file. Content is cut on line boundaries; content_hash remains the hash of the whole file.",
				"default": 0
			}
		},
		"required": ["script_path"]
	}

	# outputSchema
	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"script_path": {"type": "string"},
			"content": {"type": "string"},
			"content_hash": {"type": "string", "description": "SHA-256 of the WHOLE-file UTF-8 text, including line endings. Unchanged by offset_lines/max_lines so it still anchors modify_script's optimistic lock."},
			"line_count": {"type": "integer", "description": "Total line count of the whole file."},
			"offset_lines": {"type": "integer"},
			"returned_line_count": {"type": "integer"},
			"has_more": {"type": "boolean"},
			"next_offset_lines": {"type": "integer"}
		}
	}
	
	# annotations - readOnlyHint = true
	var annotations: Dictionary = {
		"readOnlyHint": true,
		"destructiveHint": false,
		"idempotentHint": true,
		"openWorldHint": false
	}
	
	# 注册工具
	server_core.register_tool(tool_name, description, input_schema,
						  Callable(self, "_tool_read_script"),
						  output_schema, annotations,
						  "core", "Script")


func _tool_read_script(params: Dictionary) -> Dictionary:
	# 参数提取
	var script_path: String = params.get("script_path", "")
	var offset_lines: int = int(params.get("offset_lines", 0))
	var max_lines: int = int(params.get("max_lines", 0))

	if script_path.is_empty():
		return {"error": "Missing required parameter: script_path"}
	if offset_lines < 0 or max_lines < 0:
		return {"error": "offset_lines and max_lines must be non-negative integers"}

	# 2026-10-03 台账 P1-2：数据驱动项目大量 .json/.tscn/.cfg，调用方拿着
	# read_script 读 JSON 只会撞类型墙。一次往返自纠：指名正确工具。
	var lower_path: String = script_path.to_lower()
	if not (lower_path.ends_with(".gd") or lower_path.ends_with(".cs")):
		return {
			"error": "read_script reads .gd/.cs only, but '%s' does not look like a script file." % script_path,
			"error_code": "not_a_script",
			"next_step": "For .json/.tscn/.tres/.cfg/.md/.csv and other text project files, call read_project_file {\"file_path\": \"%s\"} instead (same offset_lines/max_lines paging)." % script_path
		}

	# 使用PathValidator验证路径安全性
	var validation: Dictionary = PathValidator.validate_file_path(script_path, [".gd", ".cs"])
	if not validation["valid"]:
		return {"error": "Invalid path: " + validation["error"]}

	# 使用清理后的路径
	script_path = validation["sanitized"]

	# 验证文件是否存在

	var file: FileAccess = FileAccess.open(script_path, FileAccess.READ)

	if not file:
		return {"error": "Failed to open file: " + script_path}

	# 读取内容
	var content: String = file.get_as_text()
	file.close()

	# content_hash 始终锚定"整个文件"——它是 modify_script 乐观锁的锚点；
	# 分页只裁剪返回的 content，不影响锁语义。
	var whole_hash: String = content.sha256_text()
	var lines: PackedStringArray = content.split("\n")
	var total_lines: int = lines.size()
	var result: Dictionary = {
		"script_path": script_path,
		"content_hash": whole_hash,
		"line_count": total_lines,
		"offset_lines": offset_lines
	}
	if max_lines <= 0 and offset_lines <= 0:
		result["content"] = content
		result["returned_line_count"] = total_lines
		result["has_more"] = false
		return result

	if offset_lines >= total_lines:
		result["content"] = ""
		result["returned_line_count"] = 0
		result["has_more"] = false
		return result

	var end_line: int = total_lines if max_lines <= 0 else mini(total_lines, offset_lines + max_lines)
	# split("\n") 丢了分隔符；窗口重组用 \n 还原（CRLF 的 \r 留在行内容里，字节不丢）。
	var page: PackedStringArray = lines.slice(offset_lines, end_line)
	result["content"] = "\n".join(page)
	result["returned_line_count"] = page.size()
	result["has_more"] = end_line < total_lines
	if result["has_more"]:
		result["next_offset_lines"] = end_line
	return result

# ============================================================================
# batch_read_scripts - 批量读取脚本
# ============================================================================


func _register_batch_read_scripts(server_core: RefCounted) -> void:
	var tool_name: String = "batch_read_scripts"
	var description: String = "Read multiple GDScript (.gd) or C# (.cs) scripts. Each successful entry includes content and content_hash for guarded modify_script calls."

	var input_schema: Dictionary = {
		"type": "object",
		"properties": {
			"script_paths": {
				"type": "array",
				"items": {"type": "string"},
				"description": "Paths of the scripts to read (e.g. ['res://scripts/player.gd', 'res://scripts/enemy.gd'])."
			}
		},
		"required": ["script_paths"]
	}

	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"status": {"type": "string"},
			"count": {"type": "integer"},
			"error_count": {"type": "integer"},
			"results": {"type": "array"}
		}
	}

	var annotations: Dictionary = {
		"readOnlyHint": true,
		"destructiveHint": false,
		"idempotentHint": true,
		"openWorldHint": false
	}

	server_core.register_tool(tool_name, description, input_schema,
						  Callable(self, "_tool_batch_read_scripts"),
						  output_schema, annotations,
						  "supplementary", "Script-Advanced")


func _tool_batch_read_scripts(params: Dictionary) -> Dictionary:
	var script_paths: Array = params.get("script_paths", [])
	if script_paths.is_empty():
		return {"error": "Missing required parameter: script_paths"}

	var results: Array = []
	var error_count: int = 0
	for entry in script_paths:
		var script_path: String = str(entry)
		var single: Dictionary = _tool_read_script({"script_path": script_path})
		if single.has("error"):
			results.append({"script_path": script_path, "error": single["error"]})
			error_count += 1
		else:
			results.append(single)

	return {
		"status": "success",
		"count": results.size(),
		"error_count": error_count,
		"results": results
	}

# ============================================================================
# create_script - 创建新脚本
# ============================================================================


func _register_search_in_files(server_core: RefCounted) -> void:
	var tool_name: String = "search_in_files"
	var description: String = "Search for text patterns in project files. Supports literal text and regex matching."

	var input_schema: Dictionary = {
		"type": "object",
		"properties": {
			"pattern": {
				"type": "string",
				"description": "Search pattern (text or regex)"
			},
			"search_path": {
				"type": "string",
				"description": "Directory to search in. Default is 'res://'."
			},
			"file_extensions": {
				"type": "array",
				"items": {"type": "string"},
				"description": "File extensions to include (e.g. ['.gd', '.tscn']). Default is ['.gd']."
			},
			"use_regex": {
				"type": "boolean",
				"description": "Whether to use regex matching. Default is false (literal match)."
			},
			"case_sensitive": {
				"type": "boolean",
				"description": "Whether the search is case-sensitive. Default is true."
			},
			"max_results": {
				"type": "integer",
				"description": "Maximum number of results to return. Default is 50."
			},
				"max_files": {
					"type": "integer",
					"description": "Maximum number of files to open. Default 2000; bounds zero-match scans over projects with many matching extensions.",
					"default": 2000
				},
				"include_tooling": {
					"type": "boolean",
					"description": "Include tooling directories (addons/, test/, docs/). Default false unless search_path itself is inside one.",
					"default": false
				}
		},
		"required": ["pattern"]
	}

	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"pattern": {"type": "string"},
			"results": {"type": "array"},
			"total_matches": {"type": "integer"},
			"files_searched": {"type": "integer"}
		}
	}

	var annotations: Dictionary = {
		"readOnlyHint": true,
		"destructiveHint": false,
		"idempotentHint": true,
		"openWorldHint": false
	}

	server_core.register_tool(tool_name, description, input_schema,
		Callable(self, "_tool_search_in_files"),
		output_schema, annotations,
		"supplementary", "Script-Advanced")


func _tool_search_in_files(params: Dictionary) -> Dictionary:
	var pattern: String = params.get("pattern", "")
	var search_path: String = params.get("search_path", "res://")
	var file_extensions: Array = params.get("file_extensions", [".gd"])
	var use_regex: bool = params.get("use_regex", false)
	var case_sensitive: bool = params.get("case_sensitive", true)
	var max_results: int = params.get("max_results", 50)
	var max_files: int = maxi(1, int(params.get("max_files", 2000)))

	if pattern.is_empty():
		return {"error": "Missing required parameter: pattern"}

	var validation: Dictionary = PathValidator.validate_directory_path(search_path)
	if not validation["valid"]:
		return {"error": "Invalid path: " + validation["error"]}
	search_path = validation["sanitized"]

	var regex: RegEx = null
	if use_regex:
		regex = RegEx.new()
		var compile_err: int = regex.compile(pattern)
		if compile_err != OK:
			return {"error": "Invalid regex pattern: " + pattern}
	# P2-14（2026-09-30 体检 §12.3）：回显实际生效的路径——"路径被归一化"
	# 与"目录本来如此"必须可区分（res://../../ 与 res:// 返回一致是缺陷）。

	# 文件发现走统一收集器：跳过 .godot/.import 等生成域（此前裸 DirAccess
	# 会下探引擎缓存与 __pycache__，零匹配也要读完所有文件）。工具目录
	# （addons/test/docs）默认排除，显式 include_tooling 或指向工具目录的
	# search_path 仍可搜索。
	var include_tooling: bool = params.get("include_tooling",
		GeneratedCacheFilterScript.domain_of(search_path) == GeneratedCacheFilterScript.Domain.TOOLING)
	var normalized_extensions: Array[String] = []
	for ext_value in file_extensions:
		var ext: String = String(ext_value).strip_edges().to_lower()
		if not ext.begins_with("."):
			ext = "." + ext
		if not ext.is_empty() and not normalized_extensions.has(ext):
			normalized_extensions.append(ext)
	var files: Array[String] = []
	ProjectToolsNative._collect_resources(search_path, normalized_extensions, files, false, include_tooling)
	files.sort()

	var state: Dictionary = {
		"results": [],
		"files_searched": 0,
		"total_matches": 0,
		"max_results": max_results
	}
	for file_path in files:
		if state["total_matches"] >= state["max_results"] or state["files_searched"] >= max_files:
			break
		state["files_searched"] = int(state["files_searched"]) + 1
		_search_file(file_path, pattern, use_regex, case_sensitive, regex, state)

	# 2026-10-03 台账 S12（假信号家族）：空结果必须自解释——"没匹配到"与
	# "根本没扫到文件"在调用方眼里必须是两种结论。
	var payload: Dictionary = {
		"pattern": pattern,
		"results": state["results"],
		"total_matches": state["total_matches"],
		"files_searched": state["files_searched"],
		"files_available": files.size(),
		"resolved_search_path": search_path
	}
	if int(state["total_matches"]) == 0:
		if files.is_empty():
			payload["empty_reason"] = "no_files_matched_extensions"
		else:
			payload["empty_reason"] = "pattern_matched_nothing"
	return payload


func _search_recursive(
	dir_path: String, pattern: String, extensions: Array,
	use_regex: bool, case_sensitive: bool, regex: RegEx, state: Dictionary
) -> void:
	if state["total_matches"] >= state["max_results"]:
		return

	var dir: DirAccess = DirAccess.open(dir_path)
	if not dir:
		return

	dir.list_dir_begin()
	var file_name: String = dir.get_next()

	while not file_name.is_empty():
		if state["total_matches"] >= state["max_results"]:
			break

		if file_name == "." or file_name == "..":
			file_name = dir.get_next()
			continue

		var full_path: String = dir_path.path_join(file_name)

		if dir.current_is_dir():
			_search_recursive(full_path, pattern, extensions, use_regex,
				case_sensitive, regex, state)
		else:
			var ext_match: bool = extensions.is_empty()
			for ext in extensions:
				if file_name.ends_with(ext):
					ext_match = true
					break

			if ext_match:
				state["files_searched"] = int(state["files_searched"]) + 1
				_search_file(full_path, pattern, use_regex, case_sensitive, regex, state)

		file_name = dir.get_next()

	dir.list_dir_end()


func _search_file(
	file_path: String, pattern: String, use_regex: bool,
	case_sensitive: bool, regex: RegEx, state: Dictionary
) -> void:
	var file: FileAccess = FileAccess.open(file_path, FileAccess.READ)
	if not file:
		return

	var line_number: int = 0
	var file_matches: Array = []

	while not file.eof_reached() and state["total_matches"] < state["max_results"]:
		var line: String = file.get_line()
		line_number += 1

		var found: bool = false
		var match_text: String = ""

		if use_regex and regex:
			var match_result: RegExMatch = regex.search(line)
			if match_result:
				found = true
				match_text = match_result.get_string()
		else:
			var search_line: String = line if case_sensitive else line.to_lower()
			var search_pattern: String = pattern if case_sensitive else pattern.to_lower()
			var pos: int = search_line.find(search_pattern)
			if pos >= 0:
				found = true
				match_text = line.strip_edges()

		if found:
			file_matches.append({
				"line": line_number,
				"text": match_text
			})
			state["total_matches"] = int(state["total_matches"]) + 1

	file.close()

	if not file_matches.is_empty():
		state["results"].append({
			"file": file_path,
			"matches": file_matches,
			"match_count": file_matches.size()
		})

# ============================================================================
# validate_shader - Validate Godot shaders (.gdshader file / Shader.code)
# ============================================================================


