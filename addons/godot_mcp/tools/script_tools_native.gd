# script_tools_native.gd - Script Tools原生实现（简化版）
# 根据godot-dev-guide添加完整的类型提示

@tool
class_name ScriptToolsNative
extends RefCounted

const VIBE_CODING_POLICY = preload("res://addons/godot_mcp/utils/vibe_coding_policy.gd")

var _editor_interface: EditorInterface = null

# Autoload/全局类声明缓存：批量校验（verify_scripts）时避免对每个失败脚本重复
# 遍历 ProjectSettings.get_property_list() / get_global_class_list()（TTL 到期自动重建）。
var _autoload_decls_cache: String = ""
var _autoload_decls_cache_ts: int = 0
const AUTOLOAD_DECLS_CACHE_TTL_MS: int = 5000

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

# ============================================================================
# 工具注册
# ============================================================================

func register_tools(server_core: RefCounted) -> void:
	_register_list_project_scripts(server_core)
	_register_list_project_script_symbols(server_core)
	_register_find_script_symbol_definition(server_core)
	_register_find_script_symbol_references(server_core)
	_register_rename_script_symbol(server_core)
	_register_read_script(server_core)
	_register_batch_read_scripts(server_core)
	_register_create_script(server_core)
	_register_modify_script(server_core)
	_register_analyze_script(server_core)
	_register_get_current_script(server_core)
	_register_open_script_at_line(server_core)
	_register_attach_script(server_core)
	_register_validate_script(server_core)
	_register_verify_scripts(server_core)
	_register_validate_shader(server_core)
	_register_search_in_files(server_core)

# ============================================================================
# list_project_scripts - 列出所有脚本
# ============================================================================

func _register_list_project_scripts(server_core: RefCounted) -> void:
	var tool_name: String = "list_project_scripts"
	var description: String = "List GDScript (.gd) and C# (.cs) script files in the project. Supports limit/offset pagination; count is the page size and total_count is the full total. Returns paths relative to res://."
	
	# inputSchema
	var input_schema: Dictionary = {
		"type": "object",
		"properties": {
			"search_path": {
				"type": "string",
				"description": "Optional subpath to search (e.g. 'res://scripts/'). Default is 'res://'.",
				"default": "res://"
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
			"truncated": {"type": "boolean", "description": "True when more script paths remain after this page."}
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
	
	# 使用DirAccess递归查找所有.gd文件
	var scripts: Array = []
	_collect_scripts(search_path, scripts)
	
	# 排序
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
		"truncated": page["truncated"]
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

	var include_extensions: Array = _normalize_script_extensions(params.get("include_extensions", [".gd", ".cs"]))
	if include_extensions.is_empty():
		return {"error": "include_extensions must contain at least one supported script extension"}

	var symbol_kinds: Array = _normalize_symbol_kinds(params.get("symbol_kinds", []))
	var name_filter: String = str(params.get("name_filter", "")).strip_edges().to_lower()
	var script_paths: Array = []
	_collect_script_files(search_path, include_extensions, script_paths)
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

	var include_extensions: Array = _normalize_script_extensions(params.get("include_extensions", [".gd", ".cs"]))
	if include_extensions.is_empty():
		return {"error": "include_extensions must contain at least one supported script extension"}

	var symbol_kinds: Array = _normalize_definition_symbol_kinds(params.get("symbol_kinds", []))
	var preferred_script_path: String = str(params.get("preferred_script_path", "")).strip_edges()
	var max_results: int = max(1, int(params.get("max_results", 20)))

	var script_paths: Array = []
	_collect_script_files(search_path, include_extensions, script_paths)
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

	var include_extensions: Array = _normalize_reference_extensions(params.get("include_extensions", [".gd", ".cs", ".tscn"]))
	if include_extensions.is_empty():
		return {"error": "include_extensions must contain at least one supported file extension"}

	var include_definitions: bool = bool(params.get("include_definitions", false))
	var case_sensitive: bool = bool(params.get("case_sensitive", true))
	var preferred_script_path: String = str(params.get("preferred_script_path", "")).strip_edges()
	var max_results: int = max(1, int(params.get("max_results", 100)))

	var file_paths: Array = []
	_collect_script_reference_files(search_path, include_extensions, file_paths)
	file_paths.sort()
	if not preferred_script_path.is_empty():
		file_paths.sort_custom(Callable(self, "_compare_script_paths_for_preference").bind(preferred_script_path))

	var definitions_by_path: Dictionary = {}
	if not include_definitions:
		definitions_by_path = _collect_definition_lines_by_path(file_paths, symbol_name, case_sensitive)

	var references: Array = []
	for file_path in file_paths:
		if references.size() >= max_results:
			break
		var definition_lines: Array = definitions_by_path.get(file_path, [])
		var matches: Array = _find_symbol_references_in_file(file_path, symbol_name, case_sensitive, include_definitions, definition_lines, max_results - references.size())
		for match in matches:
			references.append(match)
			if references.size() >= max_results:
				break

	# Annotate references with Autoload singleton name when a referenced script is an Autoload
	var autoload_path_map: Dictionary = _build_autoload_path_map()
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

func _build_autoload_path_map() -> Dictionary:
	# Build a mapping from script path to Autoload singleton name
	# Format: {"res://path/to/script.gd": "AutoloadName"}
	var result: Dictionary = {}
	var property_list: Array = ProjectSettings.get_property_list()
	for prop in property_list:
		var prop_name: String = str(prop.get("name", ""))
		if not prop_name.begins_with("autoload/"):
			continue
		var autoload_name: String = prop_name.trim_prefix("autoload/")
		if autoload_name.is_empty():
			continue
		var autoload_value: String = str(ProjectSettings.get_setting(prop_name, ""))
		# Strip leading "*" which marks global singleton autoloads
		if autoload_value.begins_with("*"):
			autoload_value = autoload_value.substr(1)
		if autoload_value.begins_with("res://"):
			result[autoload_value] = autoload_name
	# Fallback: try direct get_setting for dynamically registered autoloads
	if result.is_empty():
		for i in range(256):
			var key: String = "autoload/" + str(i)
			if ProjectSettings.has_setting(key):
				var val: String = str(ProjectSettings.get_setting(key, ""))
				if val.begins_with("*"):
					val = val.substr(1)
				if val.begins_with("res://"):
					result[val] = key.trim_prefix("autoload/")
			else:
				break
	return result

# ============================================================================
# rename_script_symbol - 重命名脚本符号
# ============================================================================

func _register_rename_script_symbol(server_core: RefCounted) -> void:
	var tool_name: String = "rename_script_symbol"
	var description: String = "Rename a script symbol across project files using identifier-boundary text replacements. Supports dry-run previews before applying changes."

	var input_schema: Dictionary = {
		"type": "object",
		"properties": {
			"symbol_name": {
				"type": "string",
				"description": "Existing symbol name to rename."
			},
			"new_name": {
				"type": "string",
				"description": "New symbol name to write."
			},
			"search_path": {
				"type": "string",
				"description": "Optional subpath to search. Default is 'res://'.",
				"default": "res://"
			},
			"include_extensions": {
				"type": "array",
				"items": {"type": "string"},
				"description": "File extensions to update. Supported values are '.gd', '.cs', and '.tscn'. Default is ['.gd', '.cs'].",
				"default": [".gd", ".cs"]
			},
			"case_sensitive": {
				"type": "boolean",
				"description": "Whether symbol matching is case-sensitive. Default is true.",
				"default": true
			},
			"dry_run": {
				"type": "boolean",
				"description": "When true, preview the impacted files without modifying them. Default is true.",
				"default": true
			},
			"max_results": {
				"type": "integer",
				"description": "Maximum number of replacement matches to inspect. Default is 200.",
				"default": 200
			}
		},
		"required": ["symbol_name", "new_name"]
	}

	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"symbol_name": {"type": "string"},
			"new_name": {"type": "string"},
			"dry_run": {"type": "boolean"},
			"changed_files": {"type": "array", "items": {"type": "object"}},
			"replacement_count": {"type": "integer"}
		}
	}

	var annotations: Dictionary = {
		"readOnlyHint": false,
		"destructiveHint": true,
		"idempotentHint": false,
		"openWorldHint": false
	}

	server_core.register_tool(tool_name, description, input_schema,
						  Callable(self, "_tool_rename_script_symbol"),
						  output_schema, annotations,
						  "supplementary", "Script-Advanced")

func _tool_rename_script_symbol(params: Dictionary) -> Dictionary:
	var symbol_name: String = str(params.get("symbol_name", "")).strip_edges()
	var new_name: String = str(params.get("new_name", "")).strip_edges()
	if symbol_name.is_empty():
		return {"error": "Missing required parameter: symbol_name"}
	if new_name.is_empty():
		return {"error": "Missing required parameter: new_name"}
	if symbol_name == new_name:
		return {"error": "symbol_name and new_name must differ"}
	if not _is_valid_identifier_name(new_name):
		return {"error": "new_name must be a valid identifier"}

	var search_path: String = str(params.get("search_path", "res://")).strip_edges()
	var path_validation: Dictionary = PathValidator.validate_directory_path(search_path)
	if not path_validation["valid"]:
		return {"error": "Invalid path: " + path_validation["error"]}
	search_path = path_validation["sanitized"]

	var include_extensions: Array = _normalize_reference_extensions(params.get("include_extensions", [".gd", ".cs", ".tscn"]))
	if include_extensions.is_empty():
		return {"error": "include_extensions must contain at least one supported file extension"}

	var case_sensitive: bool = bool(params.get("case_sensitive", true))
	var dry_run: bool = bool(params.get("dry_run", true))
	var max_results: int = max(1, int(params.get("max_results", 200)))

	var file_paths: Array = []
	_collect_script_reference_files(search_path, include_extensions, file_paths)
	file_paths.sort()

	var changed_files: Array = []
	var replacement_count: int = 0
	for file_path in file_paths:
		if replacement_count >= max_results:
			break
		var remaining_results: int = max_results - replacement_count
		var replacement_result: Dictionary = _rename_symbol_in_file(file_path, symbol_name, new_name, case_sensitive, dry_run, remaining_results)
		if replacement_result.is_empty():
			continue
		changed_files.append(replacement_result)
		replacement_count += int(replacement_result.get("replacement_count", 0))

	return {
		"symbol_name": symbol_name,
		"new_name": new_name,
		"dry_run": dry_run,
		"changed_files": changed_files,
		"replacement_count": replacement_count
	}

# 辅助函数：递归收集脚本文件
func _collect_scripts(directory_path: String, result: Array) -> void:
	var dir: DirAccess = DirAccess.open(directory_path)
	
	if not dir:
		return
	
	# 列出所有文件和目录
	dir.list_dir_begin()
	var file_name: String = dir.get_next()
	
	while not file_name.is_empty():
		# 跳过特殊目录
		if file_name != "." and file_name != "..":
			var full_path: String = directory_path
			if not full_path.ends_with("/"):
				full_path += "/"
			full_path += file_name
			
			if dir.current_is_dir():
				# 递归处理子目录
				_collect_scripts(full_path, result)
			elif file_name.ends_with(".gd") or file_name.ends_with(".cs"):
				# 添加脚本文件（GDScript 或 C#）
				result.append(full_path)
		
		file_name = dir.get_next()
	
	dir.list_dir_end()

func _collect_script_files(directory_path: String, extensions: Array, result: Array) -> void:
	var dir: DirAccess = DirAccess.open(directory_path)
	if not dir:
		return

	dir.list_dir_begin()
	var file_name: String = dir.get_next()
	while not file_name.is_empty():
		if file_name != "." and file_name != "..":
			var full_path: String = directory_path
			if not full_path.ends_with("/"):
				full_path += "/"
			full_path += file_name

			if dir.current_is_dir():
				_collect_script_files(full_path, extensions, result)
			else:
				var extension: String = "." + file_name.get_extension().to_lower()
				if extensions.has(extension):
					result.append(full_path)
		file_name = dir.get_next()
	dir.list_dir_end()

func _normalize_script_extensions(raw_extensions: Variant) -> Array:
	var normalized: Array = []
	if not (raw_extensions is Array):
		return normalized
	for extension in raw_extensions:
		var extension_text: String = str(extension).strip_edges().to_lower()
		if extension_text.is_empty():
			continue
		if not extension_text.begins_with("."):
			extension_text = "." + extension_text
		if extension_text in [".gd", ".cs"] and not normalized.has(extension_text):
			normalized.append(extension_text)
	return normalized

func _normalize_symbol_kinds(raw_symbol_kinds: Variant) -> Array:
	var normalized: Array = []
	if not (raw_symbol_kinds is Array):
		return normalized
	for kind in raw_symbol_kinds:
		var kind_text: String = str(kind).strip_edges().to_lower()
		if kind_text in ["function", "signal", "property", "constant"] and not normalized.has(kind_text):
			normalized.append(kind_text)
	return normalized

func _normalize_definition_symbol_kinds(raw_symbol_kinds: Variant) -> Array:
	var normalized: Array = []
	if not (raw_symbol_kinds is Array):
		return normalized
	for kind in raw_symbol_kinds:
		var kind_text: String = str(kind).strip_edges().to_lower()
		if kind_text in ["class", "function", "signal", "property", "constant"] and not normalized.has(kind_text):
			normalized.append(kind_text)
	return normalized

func _normalize_reference_extensions(raw_extensions: Variant) -> Array:
	var normalized: Array = []
	if not (raw_extensions is Array):
		return normalized
	for extension in raw_extensions:
		var extension_text: String = str(extension).strip_edges().to_lower()
		if extension_text.is_empty():
			continue
		if not extension_text.begins_with("."):
			extension_text = "." + extension_text
		if extension_text in [".gd", ".cs", ".tscn"] and not normalized.has(extension_text):
			normalized.append(extension_text)
	return normalized

func _is_valid_identifier_name(identifier_name: String) -> bool:
	if identifier_name.is_empty():
		return false
	var regex: RegEx = RegEx.new()
	if regex.compile("^[A-Za-z_][A-Za-z0-9_]*$") != OK:
		return false
	return regex.search(identifier_name) != null

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
	var line_count: int = content.split("\n").size()
	var has_class_name: bool = false
	var class_name_value: String = ""
	var extends_from: String = ""
	var functions: Array = []
	var signals: Array = []
	var properties: Array = []
	var constants: Array = []

	for line in content.split("\n"):
		var trimmed: String = _strip_inline_comment(line).strip_edges()
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

func _index_csharp_symbols(script_path: String, content: String) -> Dictionary:
	var line_count: int = content.split("\n").size()
	var class_name_value: String = ""
	var extends_from: String = ""
	var functions: Array = []
	var signals: Array = []
	var properties: Array = []
	var constants: Array = []
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

	for line in content.split("\n"):
		var trimmed: String = _strip_csharp_line_comment(line).strip_edges()
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

func _strip_inline_comment(line: String) -> String:
	var comment_index: int = line.find("#")
	if comment_index >= 0:
		return line.substr(0, comment_index)
	return line

func _strip_csharp_line_comment(line: String) -> String:
	var comment_index: int = line.find("//")
	if comment_index >= 0:
		return line.substr(0, comment_index)
	return line

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
		var trimmed: String = _strip_inline_comment(raw_line).strip_edges()
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
		var trimmed: String = _strip_csharp_line_comment(raw_line).strip_edges()
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

func _collect_script_reference_files(directory_path: String, extensions: Array, result: Array) -> void:
	var dir: DirAccess = DirAccess.open(directory_path)
	if not dir:
		return

	dir.list_dir_begin()
	var file_name: String = dir.get_next()
	while not file_name.is_empty():
		if file_name != "." and file_name != "..":
			var full_path: String = directory_path
			if not full_path.ends_with("/"):
				full_path += "/"
			full_path += file_name

			if dir.current_is_dir():
				_collect_script_reference_files(full_path, extensions, result)
			else:
				var extension: String = "." + file_name.get_extension().to_lower()
				if extensions.has(extension):
					result.append(full_path)
		file_name = dir.get_next()
	dir.list_dir_end()

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

	var references: Array = []
	var regex: RegEx = RegEx.new()
	var escaped_symbol_name: String = _escape_regex_pattern(symbol_name)
	var compile_pattern: String = "(?i)(?<![A-Za-z0-9_])%s(?![A-Za-z0-9_])" % escaped_symbol_name if not case_sensitive else "(?<![A-Za-z0-9_])%s(?![A-Za-z0-9_])" % escaped_symbol_name
	if regex.compile(compile_pattern) != OK:
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
			search_line = _strip_inline_comment(raw_line)
		elif file_path.ends_with(".cs"):
			search_line = _strip_csharp_line_comment(raw_line)
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

func _escape_regex_pattern(text: String) -> String:
	var escaped: String = ""
	var special_characters: String = "\\.^$|?*+()[]{}"
	for character in text:
		var character_text: String = str(character)
		if special_characters.contains(character_text):
			escaped += "\\" + character_text
		else:
			escaped += character_text
	return escaped

func _rename_symbol_in_file(file_path: String, symbol_name: String, new_name: String, case_sensitive: bool, dry_run: bool, remaining_results: int) -> Dictionary:
	var file: FileAccess = FileAccess.open(file_path, FileAccess.READ)
	if not file:
		return {}

	var lines: PackedStringArray = file.get_as_text().split("\n")
	file.close()

	var regex: RegEx = RegEx.new()
	var escaped_symbol_name: String = _escape_regex_pattern(symbol_name)
	var compile_pattern: String = "(?i)(?<![A-Za-z0-9_])%s(?![A-Za-z0-9_])" % escaped_symbol_name if not case_sensitive else "(?<![A-Za-z0-9_])%s(?![A-Za-z0-9_])" % escaped_symbol_name
	if regex.compile(compile_pattern) != OK:
		return {}

	var replacements: Array = []
	var updated_lines: PackedStringArray = []
	for i in range(lines.size()):
		var raw_line: String = lines[i]
		var matches: Array = regex.search_all(raw_line)
		var replacement_total: int = min(matches.size(), max(0, remaining_results - replacements.size()))
		if replacement_total <= 0:
			updated_lines.append(raw_line)
			continue
		var new_line: String = regex.sub(raw_line, new_name, true, replacement_total)
		if new_line != raw_line:
			replacements.append({
				"line": i + 1,
				"before": raw_line.strip_edges(),
				"after": new_line.strip_edges(),
				"replacement_count": replacement_total
			})
		updated_lines.append(new_line)
		if replacements.size() >= remaining_results:
			for j in range(i + 1, lines.size()):
				updated_lines.append(lines[j])
			break

	if replacements.is_empty():
		return {}

	if not dry_run:
		var write_file: FileAccess = FileAccess.open(file_path, FileAccess.WRITE)
		if not write_file:
			return {}
		write_file.store_string("\n".join(updated_lines))
		write_file.close()

	var total_replacements: int = 0
	for replacement in replacements:
		total_replacements += int(replacement.get("replacement_count", 0))

	return {
		"script_path": file_path,
		"replacement_count": total_replacements,
		"changes": replacements
	}

# ============================================================================
# read_script - 读取脚本内容
# ============================================================================

func _register_read_script(server_core: RefCounted) -> void:
	var tool_name: String = "read_script"
	var description: String = "Read the content of a GDScript (.gd) or C# (.cs) script file. Returns the complete script source code."
	
	# inputSchema
	var input_schema: Dictionary = {
		"type": "object",
		"properties": {
			"script_path": {
				"type": "string",
				"description": "Path to the script file (e.g. 'res://scripts/player.gd')"
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
			"line_count": {"type": "integer"}
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
	
	if script_path.is_empty():
		return {"error": "Missing required parameter: script_path"}
	
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

	var line_count: int = content.split("\n").size()
	
	return {
		"script_path": script_path,
		"content": content,
		"line_count": line_count
	}

# ============================================================================
# batch_read_scripts - 批量读取脚本
# ============================================================================

func _register_batch_read_scripts(server_core: RefCounted) -> void:
	var tool_name: String = "batch_read_scripts"
	var description: String = "Read the contents of multiple GDScript (.gd) or C# (.cs) script files in a single call. Returns one result entry per requested path, reducing round trips when reading several scripts."

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

func _register_create_script(server_core: RefCounted) -> void:
	var tool_name: String = "create_script"
	var description: String = "Create a new GDScript (.gd) or C# (.cs) script file with optional template."
	
	# inputSchema
	var input_schema: Dictionary = {
		"type": "object",
		"properties": {
			"script_path": {
				"type": "string",
				"description": "Path where the script will be saved (e.g. 'res://scripts/player.gd' or 'res://scripts/Player.cs')"
			},
			"content": {
				"type": "string",
				"description": "Optional initial content for the script. If not provided, creates a template based on the file extension (.gd → GDScript, .cs → C#)."
			},
			"template": {
				"type": "string",
				"description": "Optional template to use: 'empty', 'node', 'characterbody2d', 'characterbody3d', 'area2d', 'area3d'. Default is 'empty'."
			},
			"attach_to_node": {
				"type": "string",
				"description": "Optional node path to attach the script to after creation (e.g. '/root/MainScene/Player')."
			}
		},
		"required": ["script_path"]
	}
	
	# outputSchema
	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"status": {"type": "string"},
			"script_path": {"type": "string"},
			"line_count": {"type": "integer"}
		}
	}
	
	# annotations
	var annotations: Dictionary = {
		"readOnlyHint": false,
		"destructiveHint": false,
		"idempotentHint": false,
		"openWorldHint": false
	}
	
	# 注册工具
	server_core.register_tool(tool_name, description, input_schema,
						  Callable(self, "_tool_create_script"),
						  output_schema, annotations,
						  "core", "Script")

func _tool_create_script(params: Dictionary) -> Dictionary:
	var script_path: String = params.get("script_path", "")
	var content: String = params.get("content", "")
	var template: String = params.get("template", "empty")
	var attach_to_node: String = params.get("attach_to_node", "")

	if script_path.is_empty():
		return {"error": "Missing required parameter: script_path"}

	var validation: Dictionary = PathValidator.validate_file_path(script_path, [".gd", ".cs"])
	if not validation["valid"]:
		return {"error": "Invalid path: " + validation["error"]}

	script_path = validation["sanitized"]

	if FileAccess.file_exists(script_path):
		return {"error": "File already exists: " + script_path}

	if content.is_empty():
		if script_path.ends_with(".cs"):
			content = _get_csharp_script_template(template, script_path.get_file().get_basename())
		else:
			content = _get_script_template(template)

	var file: FileAccess = FileAccess.open(script_path, FileAccess.WRITE)
	if not file:
		return {"error": "Failed to create file: " + script_path}

	file.store_string(content)
	file.close()

	var line_count: int = content.split("\n").size()
	var result: Dictionary = {
		"status": "success",
		"script_path": script_path,
		"line_count": line_count
	}

	if not attach_to_node.is_empty():
		var editor_interface: EditorInterface = _get_editor_interface()
		if editor_interface:
			var node: Node = _resolve_node_path(editor_interface, attach_to_node)
			if node:
				var script_res: Script = load(script_path)
				if script_res:
					node.set_script(script_res)
					result["attached_to"] = attach_to_node
					editor_interface.get_resource_filesystem().scan()
				else:
					result["attach_warning"] = "Script created but failed to load for attachment"
			else:
				result["attach_warning"] = "Node not found: " + attach_to_node
		else:
			result["attach_warning"] = "Editor interface not available for script attachment"

	return result

func _resolve_node_path(editor_interface: EditorInterface, path: String) -> Node:
	var edited_scene: Node = editor_interface.get_edited_scene_root()
	if not edited_scene:
		return null
	if path == str(edited_scene.get_path()) or path == "/root/" + edited_scene.name:
		return edited_scene
	if path.begins_with("/root/" + edited_scene.name + "/"):
		var relative: String = path.substr(("/root/" + edited_scene.name + "/").length())
		return edited_scene.get_node_or_null(relative)
	return edited_scene.get_node_or_null(path)

# 辅助函数：获取脚本模板
func _get_script_template(template_name: String) -> String:
	if template_name == "node":
		return """@tool
extends Node

# Called when the node enters the scene tree
func _ready() -> void:
	pass

# Called every frame
func _process(delta: float) -> void:
	pass
"""
	elif template_name == "characterbody2d":
		return """@tool
extends CharacterBody2D

func _physics_process(delta: float) -> void:
	move_and_slide()
"""
	elif template_name == "characterbody3d":
		return """@tool
extends CharacterBody3D

func _physics_process(delta: float) -> void:
	move_and_slide()
"""
	else:
		return ""

func _get_csharp_script_template(template_name: String, script_class_name: String) -> String:
	var safe_name: String = script_class_name.replace(" ", "_").replace("-", "_")
	if safe_name.is_empty():
		safe_name = "NewScript"
	
	if template_name == "node":
		return ("using Godot;\n"
			+ "using System;\n"
			+ "\n"
			+ "public partial class " + safe_name + " : Node\n"
			+ "{\n"
			+ "\tpublic override void _Ready()\n"
			+ "\t{\n"
			+ "\t\t\n"
			+ "\t}\n"
			+ "\n"
			+ "\tpublic override void _Process(double delta)\n"
			+ "\t{\n"
			+ "\t\t\n"
			+ "\t}\n"
			+ "}\n")
	elif template_name == "characterbody2d":
		return ("using Godot;\n"
			+ "using System;\n"
			+ "\n"
			+ "public partial class " + safe_name + " : CharacterBody2D\n"
			+ "{\n"
			+ "\tpublic override void _PhysicsProcess(double delta)\n"
			+ "\t{\n"
			+ "\t\tMoveAndSlide();\n"
			+ "\t}\n"
			+ "}\n")
	elif template_name == "characterbody3d":
		return ("using Godot;\n"
			+ "using System;\n"
			+ "\n"
			+ "public partial class " + safe_name + " : CharacterBody3D\n"
			+ "{\n"
			+ "\tpublic override void _PhysicsProcess(double delta)\n"
			+ "\t{\n"
			+ "\t\tMoveAndSlide();\n"
			+ "\t}\n"
			+ "}\n")
	elif template_name == "area2d":
		return ("using Godot;\n"
			+ "using System;\n"
			+ "\n"
			+ "public partial class " + safe_name + " : Area2D\n"
			+ "{\n"
			+ "\tpublic override void _Ready()\n"
			+ "\t{\n"
			+ "\t\t\n"
			+ "\t}\n"
			+ "}\n")
	elif template_name == "area3d":
		return ("using Godot;\n"
			+ "using System;\n"
			+ "\n"
			+ "public partial class " + safe_name + " : Area3D\n"
			+ "{\n"
			+ "\tpublic override void _Ready()\n"
			+ "\t{\n"
			+ "\t\t\n"
			+ "\t}\n"
			+ "}\n")
	else:
		# empty template
		return ("using Godot;\n"
			+ "using System;\n"
			+ "\n"
			+ "public partial class " + safe_name + " : Node\n"
			+ "{\n"
			+ "\tpublic override void _Ready()\n"
			+ "\t{\n"
			+ "\t\t\n"
			+ "\t}\n"
			+ "}\n")

# ============================================================================
# modify_script - 修改脚本内容
# ============================================================================

func _register_modify_script(server_core: RefCounted) -> void:
	var tool_name: String = "modify_script"
	var description: String = "Modify the content of an existing GDScript (.gd) or C# (.cs) script file. Can replace entire content or specific lines."
	
	# inputSchema
	var input_schema: Dictionary = {
		"type": "object",
		"properties": {
			"script_path": {
				"type": "string",
				"description": "Path to the script file to modify (e.g. 'res://scripts/player.gd')"
			},
			"content": {
				"type": "string",
				"description": "New content for the script (full replacement)"
			},
			"line_number": {
				"type": "integer",
				"description": "Optional line number to replace (1-indexed). If provided with 'content', replaces that line only."
			}
		},
		"required": ["script_path", "content"]
	}
	
	# outputSchema
	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"status": {"type": "string"},
			"script_path": {"type": "string"},
			"line_count": {"type": "integer"}
		}
	}
	
	# annotations - destructiveHint = true
	var annotations: Dictionary = {
		"readOnlyHint": false,
		"destructiveHint": true,  # 会覆盖文件
		"idempotentHint": false,
		"openWorldHint": false
	}
	
	# 注册工具
	server_core.register_tool(tool_name, description, input_schema,
						  Callable(self, "_tool_modify_script"),
						  output_schema, annotations,
						  "core", "Script")

func _tool_modify_script(params: Dictionary) -> Dictionary:
	# 参数提取
	var script_path: String = params.get("script_path", "")
	var new_content: String = params.get("content", "")
	var line_number: int = params.get("line_number", 0)
	
	# 参数验证
	if script_path.is_empty():
		return {"error": "Missing required parameter: script_path"}
	if new_content.is_empty():
		return {"error": "Missing required parameter: content"}
	
	# 使用PathValidator验证路径安全性
	var validation: Dictionary = PathValidator.validate_file_path(script_path, [".gd", ".cs"])
	if not validation["valid"]:
		return {"error": "Invalid path: " + validation["error"]}
	
	# 使用清理后的路径
	script_path = validation["sanitized"]
	
	# 验证文件是否存在
	if not FileAccess.file_exists(script_path):
		return {"error": "File not found: " + script_path}
	
	# 读取现有内容
	var file: FileAccess = FileAccess.open(script_path, FileAccess.READ)
	if not file:
		return {"error": "Failed to open file for reading: " + script_path}
	
	var existing_lines: Array = []
	while not file.eof_reached():
		existing_lines.append(file.get_line())
	file.close()
	
	# 修改内容
	var final_content: String
	
	if line_number > 0 and line_number <= existing_lines.size():
		# 替换特定行
		existing_lines[line_number - 1] = new_content
		final_content = "\n".join(existing_lines)
	else:
		# 全量替换
		final_content = new_content
	
	# 写入文件
	file = FileAccess.open(script_path, FileAccess.WRITE)
	if not file:
		return {"error": "Failed to open file for writing: " + script_path}
	
	file.store_string(final_content)
	file.close()
	
	# 计算行数
	var line_count: int = final_content.split("\n").size()
	
	return {
		"status": "success",
		"script_path": script_path,
		"line_count": line_count
	}

# ============================================================================
# analyze_script - 分析脚本结构（完整版）
# ============================================================================

func _register_analyze_script(server_core: RefCounted) -> void:
	var tool_name: String = "analyze_script"
	var description: String = "Analyze the structure of a GDScript file. Returns functions, signals, properties, and more."
	
	# inputSchema
	var input_schema: Dictionary = {
		"type": "object",
		"properties": {
			"script_path": {
				"type": "string",
				"description": "Path to the script file to analyze (e.g. 'res://scripts/player.gd')"
			}
		},
		"required": ["script_path"]
	}
	
	# outputSchema
	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"script_path": {"type": "string"},
			"has_class_name": {"type": "boolean"},
			"extends_from": {"type": "string"},
			"functions": {"type": "array", "items": {"type": "string"}},
			"signals": {"type": "array", "items": {"type": "string"}},
			"properties": {"type": "array", "items": {"type": "string"}},
			"line_count": {"type": "integer"}
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
						  Callable(self, "_tool_analyze_script"),
						  output_schema, annotations,
						  "supplementary", "Script-Advanced")

func _tool_analyze_script(params: Dictionary) -> Dictionary:
	# 参数提取
	var script_path: String = params.get("script_path", "")
	
	# 参数验证
	if script_path.is_empty():
		return {"error": "Missing required parameter: script_path"}
	
	# 使用PathValidator验证路径安全性
	var validation: Dictionary = PathValidator.validate_file_path(script_path, [".gd", ".cs"])
	if not validation["valid"]:
		return {"error": "Invalid path: " + validation["error"]}
	
	# 使用清理后的路径
	script_path = validation["sanitized"]
	
	# 验证文件是否存在
	var line_count: int = 0
	var has_class_name: bool = false
	var extends_from: String = ""
	var functions: Array = []
	var signals: Array = []
	var properties: Array = []
	
	# 读取文件内容
	var file: FileAccess = FileAccess.open(script_path, FileAccess.READ)
	if not file:
		return {"error": "Failed to open file: " + script_path}
	
	while not file.eof_reached():
		var line: String = file.get_line()
		line_count += 1
		
		# 简单解析
		var trimmed: String = line.strip_edges()
		
		if trimmed.begins_with("class_name "):
			has_class_name = true
		elif trimmed.begins_with("extends ") and extends_from.is_empty():
			extends_from = trimmed.split(" ")[1]
		elif trimmed.begins_with("func "):
			# 提取函数名
			var func_name: String = trimmed.replace("func ", "").split("(")[0]
			functions.append(func_name)
		elif trimmed.begins_with("signal "):
			var signal_name: String = trimmed.replace("signal ", "").split("(")[0]
			signals.append(signal_name)
		elif trimmed.begins_with("var ") and not trimmed.begins_with("var _"):
			var var_part: String = trimmed.replace("var ", "").split(":")[0].split("=")[0].strip_edges()
			if not var_part.is_empty():
				properties.append(var_part)
	
	file.close()
	
	return {
		"script_path": script_path,
		"has_class_name": has_class_name,
		"extends_from": extends_from,
		"language": "gdscript" if script_path.ends_with(".gd") else "csharp" if script_path.ends_with(".cs") else "unknown",
		"functions": functions,
		"signals": signals,
		"properties": properties,
		"line_count": line_count
	}

# ============================================================================
# get_current_script - 获取当前正在编辑的脚本
# ============================================================================

func _register_get_current_script(server_core: RefCounted) -> void:
	var tool_name: String = "get_current_script"
	var description: String = "Get the script currently being edited in the Godot script editor. Returns the script path and content."

	var input_schema: Dictionary = {
		"type": "object",
		"properties": {}
	}

	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"script_found": {"type": "boolean"},
			"script_path": {"type": "string"},
			"content": {"type": "string"},
			"line_count": {"type": "integer"}
		}
	}

	var annotations: Dictionary = {
		"readOnlyHint": true,
		"destructiveHint": false,
		"idempotentHint": true,
		"openWorldHint": false
	}

	server_core.register_tool(tool_name, description, input_schema,
						  Callable(self, "_tool_get_current_script"),
						  output_schema, annotations,
						  "core", "Script")

func _tool_get_current_script(params: Dictionary) -> Dictionary:
	var editor_interface: EditorInterface = _get_editor_interface()
	if not editor_interface:
		return {"script_found": false, "message": "Editor interface not available"}

	var script_editor: ScriptEditor = editor_interface.get_script_editor()
	if not script_editor:
		return {"script_found": false, "message": "Script editor not available"}

	var current_script: Script = script_editor.get_current_script()
	if not current_script:
		return {"script_found": false, "message": "No script is currently being edited in the script editor"}

	var script_path: String = current_script.resource_path
	if script_path.is_empty():
		return {"script_found": false, "message": "Current script has no file path (may be a built-in script)"}

	var file: FileAccess = FileAccess.open(script_path, FileAccess.READ)
	if not file:
		return {"script_found": false, "message": "Failed to open script file: " + script_path}

	var content: String = file.get_as_text()
	file.close()

	var line_count: int = content.split("\n").size()

	return {
		"script_found": true,
		"script_path": script_path,
		"content": content,
		"line_count": line_count
	}

# ============================================================================
# open_script_at_line - 打开脚本并定位到指定行/列
# ============================================================================

func _register_open_script_at_line(server_core: RefCounted) -> void:
	var tool_name: String = "open_script_at_line"
	var description: String = "Open a script in the Godot script editor and move the caret to a specific line and column."

	var input_schema: Dictionary = {
		"type": "object",
		"properties": {
			"script_path": {
				"type": "string",
				"description": "Path to the script file (e.g. 'res://scripts/player.gd' or 'res://scripts/Player.cs')."
			},
			"line": {
				"type": "integer",
				"description": "1-based line number to focus.",
				"default": 1
			},
			"column": {
				"type": "integer",
				"description": "0-based column to focus.",
				"default": 0
			},
			"grab_focus": {
				"type": "boolean",
				"description": "Whether the editor should grab focus. Ignored unless allow_ui_focus=true when Vibe Coding mode is enabled.",
				"default": true
			},
			"allow_ui_focus": {
				"type": "boolean",
				"description": "Allow this call to focus the script editor when Vibe Coding mode is enabled.",
				"default": false
			}
		},
		"required": ["script_path"]
	}

	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"status": {"type": "string"},
			"script_path": {"type": "string"},
			"line": {"type": "integer"},
			"column": {"type": "integer"},
			"caret_line": {"type": "integer"},
			"caret_column": {"type": "integer"}
		}
	}

	var annotations: Dictionary = {
		"readOnlyHint": false,
		"destructiveHint": false,
		"idempotentHint": true,
		"openWorldHint": false
	}

	server_core.register_tool(tool_name, description, input_schema,
						  Callable(self, "_tool_open_script_at_line"),
						  output_schema, annotations,
						  "supplementary", "Script-Advanced")

func _tool_open_script_at_line(params: Dictionary) -> Dictionary:
	var script_path: String = str(params.get("script_path", "")).strip_edges()
	if script_path.is_empty():
		return {"error": "Missing required parameter: script_path"}

	var validation: Dictionary = PathValidator.validate_file_path(script_path, [".gd", ".cs"])
	if not validation["valid"]:
		return {"error": "Invalid path: " + validation["error"]}
	script_path = validation["sanitized"]

	if not FileAccess.file_exists(script_path):
		return {"error": "Script file not found: " + script_path}

	var editor_interface: EditorInterface = _get_editor_interface()
	if not editor_interface:
		return {"error": "Editor interface not available"}

	var script_resource: Script = load(script_path)
	if not script_resource:
		return {"error": "Failed to load script: " + script_path}

	var line: int = max(1, int(params.get("line", 1)))
	var column: int = max(0, int(params.get("column", 0)))
	var grab_focus: bool = VIBE_CODING_POLICY.should_grab_focus(_is_vibe_coding_mode(), params, true)

	editor_interface.edit_script(script_resource, line - 1, column, grab_focus)

	var caret_line: int = line - 1
	var caret_column: int = column
	var script_editor: ScriptEditor = editor_interface.get_script_editor()
	if script_editor:
		var current_editor: ScriptEditorBase = script_editor.get_current_editor()
		if current_editor:
			var base_editor: Control = current_editor.get_base_editor()
			if base_editor:
				if base_editor.has_method("set_caret_line"):
					base_editor.call("set_caret_line", line - 1, true, true, -1, 0)
				if base_editor.has_method("set_caret_column"):
					base_editor.call("set_caret_column", column, true, 0)
				if base_editor.has_method("get_caret_line") and base_editor.has_method("get_caret_column"):
					caret_line = int(base_editor.call("get_caret_line"))
					caret_column = int(base_editor.call("get_caret_column"))

	return {
		"status": "success",
		"script_path": script_path,
		"line": line,
		"column": column,
		"caret_line": caret_line + 1,
		"caret_column": caret_column
	}

# ============================================================================
# attach_script - 将脚本附加到节点
# ============================================================================

func _register_attach_script(server_core: RefCounted) -> void:
	var tool_name: String = "attach_script"
	var description: String = "Attach an existing GDScript file to a node in the scene tree."

	var input_schema: Dictionary = {
		"type": "object",
		"properties": {
			"node_path": {
				"type": "string",
				"description": "Path to the node to attach the script to (e.g. '/root/MainScene/Player')"
			},
			"script_path": {
				"type": "string",
				"description": "Path to the script file (e.g. 'res://scripts/player.gd')"
			}
		},
		"required": ["node_path", "script_path"]
	}

	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"status": {"type": "string"},
			"node_path": {"type": "string"},
			"script_path": {"type": "string"},
			"previous_script": {"type": "string"}
		}
	}

	var annotations: Dictionary = {
		"readOnlyHint": false,
		"destructiveHint": false,
		"idempotentHint": true,
		"openWorldHint": false
	}

	server_core.register_tool(tool_name, description, input_schema,
		Callable(self, "_tool_attach_script"),
		output_schema, annotations,
		"core", "Script")

func _tool_attach_script(params: Dictionary) -> Dictionary:
	var node_path: String = params.get("node_path", "")
	var script_path: String = params.get("script_path", "")

	if node_path.is_empty():
		return {"error": "Missing required parameter: node_path"}
	if script_path.is_empty():
		return {"error": "Missing required parameter: script_path"}

	var editor_interface: EditorInterface = _get_editor_interface()
	if not editor_interface:
		return {"error": "Editor interface not available"}

	var validation: Dictionary = PathValidator.validate_file_path(script_path, [".gd", ".cs"])
	if not validation["valid"]:
		return {"error": "Invalid script path: " + validation["error"]}
	script_path = validation["sanitized"]

	if not FileAccess.file_exists(script_path):
		return {"error": "Script file not found: " + script_path}

	var target_node: Node = _resolve_node_path(editor_interface, node_path)
	if not target_node:
		return {"error": "Node not found: " + node_path}

	var previous_script: String = ""
	var old_script: Variant = target_node.get_script()
	if old_script and old_script is Script:
		previous_script = old_script.resource_path

	var script_res: Script = load(script_path)
	if not script_res:
		return {"error": "Failed to load script: " + script_path}

	target_node.set_script(script_res)
	editor_interface.get_resource_filesystem().scan()

	return {
		"status": "success",
		"node_path": node_path,
		"script_path": script_path,
		"previous_script": previous_script
	}

# ============================================================================
# validate_script - 验证 GDScript 语法
# ============================================================================

func _register_validate_script(server_core: RefCounted) -> void:
	var tool_name: String = "validate_script"
	var description: String = "Validate GDScript syntax without executing it. Checks for errors and warnings; returns structured compile errors with line numbers."

	var input_schema: Dictionary = {
		"type": "object",
		"properties": {
			"script_path": {
				"type": "string",
				"description": "Path to the script file to validate (e.g. 'res://scripts/player.gd')"
			},
			"content": {
				"type": "string",
				"description": "Optional script content to validate directly (instead of reading from file)"
			},
			"check_warnings": {
				"type": "boolean",
				"description": "Whether to check for warnings. Default is true."
			}
		},
		"required": []
	}

	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"valid": {"type": "boolean"},
			"errors": {"type": "array"},
			"warnings": {"type": "array"},
			"error_count": {"type": "integer"},
			"warning_count": {"type": "integer"}
		}
	}

	var annotations: Dictionary = {
		"readOnlyHint": true,
		"destructiveHint": false,
		"idempotentHint": true,
		"openWorldHint": false
	}

	server_core.register_tool(tool_name, description, input_schema,
		Callable(self, "_tool_validate_script"),
		output_schema, annotations,
		"supplementary", "Script-Advanced")

func _tool_validate_script(params: Dictionary) -> Dictionary:
	var script_path: String = params.get("script_path", "")
	var content: String = params.get("content", "")
	var check_warnings: bool = params.get("check_warnings", true)

	if script_path.is_empty() and content.is_empty():
		return {"error": "Must provide either script_path or content"}

	if not content.is_empty():
		content = _spaces_to_tabs(content)

	if content.is_empty():
		var validation: Dictionary = PathValidator.validate_file_path(script_path, [".gd", ".cs"])
		if not validation["valid"]:
			return {"error": "Invalid path: " + validation["error"]}
		script_path = validation["sanitized"]

		if not FileAccess.file_exists(script_path):
			return {"error": "Script file not found: " + script_path}

		var file: FileAccess = FileAccess.open(script_path, FileAccess.READ)
		if not file:
			return {"error": "Failed to open file: " + script_path}
		content = file.get_as_text()
		file.close()

	var validation_content: String = _strip_class_names(content)
	var test_script: GDScript = GDScript.new()
	test_script.source_code = validation_content
	var reload_err: Error = test_script.reload()

	var errors: Array = []
	var warnings: Array = []
	var autoload_aware: bool = false

	if reload_err != OK:
		var autoload_decls: String = _get_autoload_declarations_cached()
		if not autoload_decls.is_empty():
			var retry_content: String = _insert_autoload_decls_after_extends(validation_content, autoload_decls)
			var retry_script: GDScript = GDScript.new()
			retry_script.source_code = retry_content
			var retry_err: Error = retry_script.reload()
			if retry_err == OK:
				autoload_aware = true
				warnings.append({
					"line": 0,
					"column": 0,
					"message": "Script validates successfully with Autoload/global class awareness. Original validation failed due to unresolved Autoload or global class names."
				})
		if not autoload_aware:
			errors.append(_collect_validation_error(test_script, content))

	if check_warnings and reload_err == OK:
		var source_lines: PackedStringArray = content.split("\n")
		for i in range(source_lines.size()):
			var line: String = source_lines[i].strip_edges()
			if line.begins_with("var ") and not ":" in line and not "=" in line:
				warnings.append({
					"line": i + 1,
					"column": 0,
					"message": "Variable lacks type hint"
				})

	return {
		"valid": errors.is_empty(),
		"errors": errors,
		"warnings": warnings,
		"error_count": errors.size(),
		"warning_count": warnings.size(),
		"autoload_aware": autoload_aware
	}

func _is_syntax_error_line(line: String) -> bool:
	var error_keywords: Array = ["unexpected", "expected", "indent", "mismatched"]
	var line_lower: String = line.to_lower()
	for keyword in error_keywords:
		if keyword in line_lower:
			return true
	return false

# 从 Godot 编译错误文本中提取行号。
# 支持 "Parse Error: Expected ')' at line 12 (script.gd)" / "Line 12: ..." 等格式；
# 提取不到返回 0（中文或其他语言格式不匹配时也不会崩溃）。
static func _extract_error_line(error_text: String) -> int:
	if error_text.is_empty():
		return 0
	var line_regex := RegEx.new()
	if line_regex.compile("(?:line|Line)\\s*(\\d+)") != OK:
		return 0
	var match: RegExMatch = line_regex.search(error_text)
	if match:
		return int(match.get_string(1))
	return 0

# 提取错误类型前缀（Parse Error / Compile Error / ERROR 等），未识别返回空字符串。
static func _extract_error_type_prefix(error_text: String) -> String:
	var lower: String = error_text.to_lower()
	var prefixes: Array[String] = ["parse error", "compile error", "parser error", "error"]
	for prefix in prefixes:
		if lower.begins_with(prefix):
			return error_text.substr(0, prefix.length()).capitalize()
	return ""

# 收集 validate_script 的单个编译错误（带行号的结构化错误）：
# 1. 优先读取 _error_text meta（现有行为）；
# 2. 为空则探测 _error_script / _error_line 等其他 meta（Godot 4.x reload 失败时部分版本会写入）；
# 3. 仍为空则回退到 _is_syntax_error_line 逐行启发式（保留）。
func _collect_validation_error(test_script: GDScript, content: String) -> Dictionary:
	var error_msg: String = ""
	if test_script.has_meta("_error_text"):
		error_msg = str(test_script.get_meta("_error_text", ""))
	if error_msg.is_empty():
		for meta_key in test_script.get_meta_list():
			if meta_key == "_error_text":
				continue
			var meta_val: Variant = test_script.get_meta(meta_key)
			if meta_val is String and not str(meta_val).is_empty():
				error_msg = str(meta_val)
				break
	if not error_msg.is_empty():
		var error_line: int = _extract_error_line(error_msg)
		if error_line == 0 and test_script.has_meta("_error_line"):
			error_line = int(test_script.get_meta("_error_line", 0))
		var error_prefix: String = _extract_error_type_prefix(error_msg)
		var display_msg: String = error_msg
		if not error_prefix.is_empty() and not error_msg.to_lower().begins_with(error_prefix.to_lower()):
			display_msg = "%s: %s" % [error_prefix, error_msg]
		return {
			"line": error_line,
			"column": 0,
			"message": display_msg
		}
	var err_lines: PackedStringArray = content.split("\n")
	for i in range(err_lines.size()):
		var line: String = err_lines[i].strip_edges()
		if line.is_empty():
			continue
		if _is_syntax_error_line(line):
			return {
				"line": i + 1,
				"column": 0,
				"message": "Syntax error near: " + line
			}
	return {
		"line": 0,
		"column": 0,
		"message": "Script has syntax errors"
	}

func _strip_class_names(source: String) -> String:
	var lines: PackedStringArray = source.split("\n")
	var result: PackedStringArray = []
	for line in lines:
		var stripped: String = line.strip_edges()
		if stripped.begins_with("class_name "):
			result.append("")
		else:
			result.append(line)
	return "\n".join(result)

# 带 TTL 的 Autoload/全局类声明缓存：批量校验场景（verify_scripts）下，多个失败脚本
# 共享同一份声明，避免每个脚本都重新遍历 ProjectSettings（TTL 内 ProjectSettings 变更
# 会在到期后自动感知；`_build_autoload_declarations` 本身保持不变，供直接调用）。
func _get_autoload_declarations_cached() -> String:
	var now: int = Time.get_ticks_msec()
	if _autoload_decls_cache.is_empty() or now - _autoload_decls_cache_ts > AUTOLOAD_DECLS_CACHE_TTL_MS:
		_autoload_decls_cache = _build_autoload_declarations()
		_autoload_decls_cache_ts = now
	return _autoload_decls_cache

func _build_autoload_declarations() -> String:
	var decls: PackedStringArray = []
	# First pass: read autoloads from ProjectSettings property list (persisted settings)
	for property_info in ProjectSettings.get_property_list():
		var property_name: String = str(property_info.get("name", ""))
		if not property_name.begins_with("autoload/"):
			continue
		var autoload_name: String = property_name.trim_prefix("autoload/")
		decls.append("var %s" % autoload_name)
	# Fallback: if no autoloads found via property list, try direct get_setting for known patterns
	# This covers autoloads registered dynamically via set_setting() without save()
	if decls.is_empty():
		for i in range(256):
			var key: String = "autoload/" + str(i)
			if ProjectSettings.has_setting(key):
				var autoload_val: String = str(ProjectSettings.get_setting(key, ""))
				if not autoload_val.is_empty():
					decls.append("var %s" % key.trim_prefix("autoload/"))
			else:
				break
	var global_classes: PackedStringArray = ProjectSettings.get_global_class_list()
	for class_name_str in global_classes:
		if not class_name_str.is_empty():
			decls.append("var %s" % class_name_str)
	return "\n".join(decls)

func _insert_autoload_decls_after_extends(content: String, autoload_decls: String) -> String:
	var lines: PackedStringArray = content.split("\n")
	var insert_index: int = 0
	for i in range(lines.size()):
		var stripped: String = lines[i].strip_edges()
		if stripped.begins_with("extends ") or stripped.begins_with("class_name "):
			insert_index = i + 1
			if stripped.begins_with("class_name "):
				continue
			break
	var result_lines: PackedStringArray = []
	for i in range(lines.size()):
		if i == insert_index:
			result_lines.append(autoload_decls)
		result_lines.append(lines[i])
	if insert_index >= lines.size():
		result_lines.append(autoload_decls)
	return "\n".join(result_lines)

func _spaces_to_tabs(code: String) -> String:
	var lines: PackedStringArray = code.split("\n")
	var result_lines: PackedStringArray = []
	for line in lines:
		if line.is_empty():
			result_lines.append(line)
			continue
		var leading_spaces: int = 0
		for c in line:
			if c == " ":
				leading_spaces += 1
			else:
				break
		if leading_spaces == 0:
			result_lines.append(line)
			continue
		var tab_count: int = leading_spaces / 4
		var remaining_spaces: int = leading_spaces % 4
		var new_line: String = "\t".repeat(tab_count) + " ".repeat(remaining_spaces) + line.substr(leading_spaces)
		result_lines.append(new_line)
	return "\n".join(result_lines)

# ============================================================================
# verify_scripts - 批量校验项目脚本编译状态
# ============================================================================

func _register_verify_scripts(server_core: RefCounted) -> void:
	var tool_name: String = "verify_scripts"
	var description: String = "Batch-verify the compilation status of project scripts, returning per-script structured errors and warnings with line numbers. With no script_paths it scans the whole project for .gd scripts (skipping res://addons/ and res://test/ by default to avoid false positives from the plugin itself and the test suite), capped by max_scripts. Use after editing code as a verification step, complementing validate_script (single script) and execute_editor_script (full reload)."

	var input_schema: Dictionary = {
		"type": "object",
		"properties": {
			"script_paths": {
				"type": "array",
				"items": {"type": "string"},
				"description": "Optional explicit script paths (.gd/.cs) to verify. When omitted, the project is scanned for .gd scripts under res:// (excluding res://addons/ and res://test/)."
			},
			"check_warnings": {
				"type": "boolean",
				"description": "Whether to check for warnings. Default is true."
			},
			"max_scripts": {
				"type": "integer",
				"description": "Maximum number of scripts to verify in one call (each GDScript.reload has cost). Default is 100."
			}
		}
	}

	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"verified": {"type": "integer"},
			"failed": {"type": "integer"},
			"results": {
				"type": "array",
				"items": {
					"type": "object",
					"properties": {
						"path": {"type": "string"},
						"valid": {"type": "boolean"},
						"errors": {"type": "array"},
						"warnings": {"type": "array"},
						"error_count": {"type": "integer"},
						"warning_count": {"type": "integer"}
					}
				}
			},
			"total_checked": {"type": "integer"}
		}
	}

	var annotations: Dictionary = {
		"readOnlyHint": true,
		"destructiveHint": false,
		"idempotentHint": true,
		"openWorldHint": false
	}

	server_core.register_tool(tool_name, description, input_schema,
		Callable(self, "_tool_verify_scripts"),
		output_schema, annotations,
		"supplementary", "Script-Advanced")

func _tool_verify_scripts(params: Dictionary) -> Dictionary:
	var check_warnings: bool = bool(params.get("check_warnings", true))
	var max_scripts: int = max(1, int(params.get("max_scripts", 100)))

	# 去重：同一路径只校验一次（显式路径可能重复，扫描结果天然无重复）。
	var seen: Dictionary = {}
	var requested: Array = []
	var raw_paths: Variant = params.get("script_paths", [])
	if raw_paths is Array:
		for p in raw_paths:
			var s: String = String(p).strip_edges()
			if not s.is_empty() and not seen.has(s):
				seen[s] = true
				requested.append(s)

	var paths: Array = []
	if requested.is_empty():
		# Default: scan the project, skipping the plugin's own addons/, the test
		# suite and the engine cache to avoid false positives.
		_collect_verify_script_paths(paths)
	else:
		paths = requested
	paths.sort()

	var results: Array = []
	var verified: int = 0
	var failed: int = 0
	var checked: int = 0
	for script_path in paths:
		if checked >= max_scripts:
			break
		checked += 1
		var result: Dictionary = _verify_single_script(String(script_path), check_warnings)
		results.append(result)
		if bool(result.get("valid", false)):
			verified += 1
		else:
			failed += 1

	return {
		"verified": verified,
		"failed": failed,
		"results": results,
		"total_checked": checked
	}

# 校验单个脚本文件，返回与 validate_script 一致的结构化错误/警告。
# 复用 _tool_validate_script 的同一套编译逻辑（class_name 剥离、Autoload/全局类
# 感知重试、_collect_validation_error 错误提取），保证单脚本与批量结果一致。
func _verify_single_script(script_path: String, check_warnings: bool) -> Dictionary:
	var validation: Dictionary = PathValidator.validate_file_path(script_path, [".gd", ".cs"])
	if not validation["valid"]:
		return {
			"path": script_path,
			"valid": false,
			"errors": [{"line": 0, "column": 0, "message": "Invalid script path: " + validation["error"]}],
			"warnings": [],
			"error_count": 1,
			"warning_count": 0
		}
	if not FileAccess.file_exists(script_path):
		return {
			"path": script_path,
			"valid": false,
			"errors": [{"line": 0, "column": 0, "message": "Script file not found: " + script_path}],
			"warnings": [],
			"error_count": 1,
			"warning_count": 0
		}
	var file: FileAccess = FileAccess.open(script_path, FileAccess.READ)
	if not file:
		return {
			"path": script_path,
			"valid": false,
			"errors": [{"line": 0, "column": 0, "message": "Failed to open file: " + script_path}],
			"warnings": [],
			"error_count": 1,
			"warning_count": 0
		}
	var content: String = file.get_as_text()
	file.close()

	var vr: Dictionary = _tool_validate_script({"content": content, "check_warnings": check_warnings})
	return {
		"path": script_path,
		"valid": bool(vr.get("valid", false)),
		"errors": vr.get("errors", []),
		"warnings": vr.get("warnings", []),
		"error_count": int(vr.get("error_count", 0)),
		"warning_count": int(vr.get("warning_count", 0))
	}

# 递归收集 .gd 脚本，跳过指定名称的子目录（如 addons/test/.godot）。
func _collect_gd_scripts_excluding(directory_path: String, result: Array, skip_dir_names: Array) -> void:
	var dir: DirAccess = DirAccess.open(directory_path)
	if not dir:
		return

	dir.list_dir_begin()
	var file_name: String = dir.get_next()
	while not file_name.is_empty():
		if file_name != "." and file_name != "..":
			var full_path: String = directory_path
			if not full_path.ends_with("/"):
				full_path += "/"
			full_path += file_name

			if dir.current_is_dir():
				if not (file_name in skip_dir_names):
					_collect_gd_scripts_excluding(full_path, result, skip_dir_names)
			elif file_name.ends_with(".gd"):
				result.append(full_path)
		file_name = dir.get_next()
	dir.list_dir_end()

# 收集待校验脚本路径：编辑器模式优先用 EditorFileSystem 缓存索引（比 DirAccess
# 递归扫描快一个量级，大项目尤其明显）；无编辑器接口（headless/CI）时回退 DirAccess。
func _collect_verify_script_paths(result: Array) -> void:
	var ei: EditorInterface = _get_editor_interface()
	var efs: EditorFileSystem = ei.get_resource_filesystem() if ei else null
	if efs and efs.get_filesystem() != null:
		_walk_editor_filesystem(efs.get_filesystem(), result, ["addons", "test", ".godot"])
		return
	_collect_gd_scripts_excluding("res://", result, ["addons", "test", ".godot"])

func _walk_editor_filesystem(dir: EditorFileSystemDirectory, result: Array, skip_dir_names: Array) -> void:
	for i in range(dir.get_subdir_count()):
		var sub: EditorFileSystemDirectory = dir.get_subdir(i)
		if sub.get_name() in skip_dir_names:
			continue
		_walk_editor_filesystem(sub, result, skip_dir_names)
	var dir_path: String = dir.get_path()
	if dir_path.ends_with("/"):
		dir_path = dir_path.trim_suffix("/")
	for i in range(dir.get_file_count()):
		var fname: String = dir.get_file(i)
		if fname.ends_with(".gd"):
			result.append(dir_path + "/" + fname)

# ============================================================================
# search_in_files - 在项目文件中搜索内容
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

	var state: Dictionary = {
		"results": [],
		"files_searched": 0,
		"total_matches": 0,
		"max_results": max_results
	}

	_search_recursive(search_path, pattern, file_extensions, use_regex,
		case_sensitive, regex, state)

	return {
		"pattern": pattern,
		"results": state["results"],
		"total_matches": state["total_matches"],
		"files_searched": state["files_searched"]
	}

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

const _SHADER_TYPES: PackedStringArray = ["spatial", "canvas_item", "particles", "sky", "fog"]

func _register_validate_shader(server_core: RefCounted) -> void:
	var tool_name: String = "validate_shader"
	var description: String = "Validate a Godot shader (.gdshader file or raw Shader code) without a GPU. Reports whether the shader parses, plus its shader_type, render_modes and uniforms, and structural issues (missing/invalid shader_type, unbalanced braces/parentheses/brackets) with line numbers. Works on Godot 4.6+. Note: the engine writes its detailed SHADER ERROR diagnostics (with exact line) to the Godot output log; those cannot be retrieved through the script API, so this tool reports a reliable valid/invalid result plus structural hints."

	var input_schema: Dictionary = {
		"type": "object",
		"properties": {
			"shader_path": {
				"type": "string",
				"description": "Path to the shader file to validate (e.g. 'res://shaders/water.gdshader'). Optional if 'content' is provided."
			},
			"content": {
				"type": "string",
				"description": "Optional shader source to validate directly (instead of reading from file)."
			}
		},
		"required": []
	}

	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"valid": {"type": "boolean"},
			"shader_type": {"type": "string"},
			"render_modes": {"type": "array"},
			"uniforms": {"type": "array"},
			"issues": {"type": "array"},
			"issue_count": {"type": "integer"},
			"godot_version": {"type": "string"}
		}
	}

	var annotations: Dictionary = {
		"readOnlyHint": true,
		"destructiveHint": false,
		"idempotentHint": true,
		"openWorldHint": false
	}

	server_core.register_tool(tool_name, description, input_schema,
		Callable(self, "_tool_validate_shader"),
		output_schema, annotations,
		"supplementary", "Script-Advanced")

func _tool_validate_shader(params: Dictionary) -> Dictionary:
	var shader_path: String = params.get("shader_path", "")
	var content: String = params.get("content", "")

	if shader_path.is_empty() and content.is_empty():
		return {"error": "Must provide either shader_path or content"}

	if content.is_empty():
		var validation: Dictionary = PathValidator.validate_file_path(shader_path, [".gdshader"])
		if not validation["valid"]:
			return {"error": "Invalid path: " + validation["error"]}
		shader_path = validation["sanitized"]
		if not FileAccess.file_exists(shader_path):
			return {"error": "Shader file not found: " + shader_path}
		var file: FileAccess = FileAccess.open(shader_path, FileAccess.READ)
		if not file:
			return {"error": "Failed to open file: " + shader_path}
		content = file.get_as_text()
		file.close()

	var godot_version: String = str(Engine.get_version_info().get("string", ""))

	if content.strip_edges().is_empty():
		return {
			"valid": false,
			"shader_type": "",
			"render_modes": [],
			"uniforms": [],
			"issues": [{"line": 1, "severity": "error", "message": "Shader source is empty"}],
			"issue_count": 1,
			"godot_version": godot_version
		}

	var lines: PackedStringArray = content.split("\n")
	var issues: Array = []

	# Strip comments first (preserving line structure) so shader_type /
	# render_mode detection and the sentinel injection ignore anything that
	# appears inside // line or /* block */ comments.
	var stripped_code: String = _strip_shader_comments(content)

	# shader_type detection (declaration + value validity)
	var type_info: Dictionary = _find_shader_type(stripped_code)
	var shader_type_value: String = str(type_info.get("value", ""))
	var shader_type_line: int = int(type_info.get("line", -1))
	if shader_type_line < 0:
		issues.append({"line": 1, "severity": "error", "message": "Missing 'shader_type' declaration (expected one of: spatial, canvas_item, particles, sky, fog)"})
	elif not _SHADER_TYPES.has(shader_type_value):
		issues.append({"line": shader_type_line + 1, "severity": "error", "message": "Invalid shader_type '%s' (expected one of: spatial, canvas_item, particles, sky, fog)" % shader_type_value})

	# bracket balance on comment-stripped source
	for pair in [["{", "}"], ["(", ")"], ["[", "]"]]:
		var opens: int = stripped_code.count(pair[0])
		var closes: int = stripped_code.count(pair[1])
		if opens != closes:
			issues.append({"line": 0, "severity": "error", "message": "Unbalanced '%s%s': %d opening vs %d closing" % [pair[0], pair[1], opens, closes]})

	# Authoritative parse check: inject a unique sentinel uniform after the
	# shader_type line and see whether the parser surfaces it. This works
	# identically on Godot 4.6 and 4.7 and needs no GPU.
	var sentinel: String = "__mcp_validate_sentinel_uniform__"
	var valid: bool = false
	var render_modes: Array = []
	var uniforms: Array = []
	if shader_type_line >= 0:
		var probe_lines: PackedStringArray = []
		for i in range(lines.size()):
			probe_lines.append(lines[i])
			if i == shader_type_line:
				probe_lines.append("uniform float %s;" % sentinel)
		var probe_shader: Shader = Shader.new()
		probe_shader.code = "\n".join(probe_lines)
		for u in probe_shader.get_shader_uniform_list():
			if str(u.get("name", "")) == sentinel:
				valid = true
				break

	if valid:
		var clean_shader: Shader = Shader.new()
		clean_shader.code = content
		for u in clean_shader.get_shader_uniform_list():
			uniforms.append({
				"name": str(u.get("name", "")),
				"type": int(u.get("type", 0)),
				"hint_string": str(u.get("hint_string", ""))
			})
		render_modes = _parse_render_modes(stripped_code)
	elif issues.is_empty():
		issues.append({"line": 0, "severity": "error", "message": "Shader failed to parse. The engine's detailed SHADER ERROR (with line number) is written to the Godot output log."})

	return {
		"valid": valid,
		"shader_type": shader_type_value,
		"render_modes": render_modes,
		"uniforms": uniforms,
		"issues": issues,
		"issue_count": issues.size(),
		"godot_version": godot_version
	}

func _find_shader_type(code: String) -> Dictionary:
	var lines: PackedStringArray = code.split("\n")
	var re: RegEx = RegEx.new()
	re.compile("^\\s*shader_type\\s+([A-Za-z_][A-Za-z0-9_]*)\\s*;")
	for i in range(lines.size()):
		var m: RegExMatch = re.search(lines[i])
		if m:
			return {"line": i, "value": m.get_string(1)}
	return {"line": -1, "value": ""}

func _parse_render_modes(code: String) -> Array:
	var modes: Array = []
	var re: RegEx = RegEx.new()
	re.compile("render_mode\\s+([^;]+);")
	var m: RegExMatch = re.search(code)
	if m:
		for part in m.get_string(1).split(","):
			var p: String = part.strip_edges()
			if not p.is_empty():
				modes.append(p)
	return modes

func _strip_shader_comments(code: String) -> String:
	# Replace comment characters with spaces while preserving newlines, so the
	# returned string has the same length/line layout as the input. This lets
	# line-number-based detection (shader_type / render_mode) and the sentinel
	# injection run on a comment-free view without shifting any line indices.
	var result: String = ""
	var i: int = 0
	var n: int = code.length()
	while i < n:
		var c: String = code[i]
		var nxt: String = code[i + 1] if i + 1 < n else ""
		if c == "/" and nxt == "/":
			# line comment: blank to end of line, keep the newline
			while i < n and code[i] != "\n":
				result += " "
				i += 1
		elif c == "/" and nxt == "*":
			# block comment: blank every char but preserve newlines
			result += "  "
			i += 2
			while i < n and not (code[i] == "*" and i + 1 < n and code[i + 1] == "/"):
				result += ("\n" if code[i] == "\n" else " ")
				i += 1
			if i < n:
				result += "  "
				i += 2
		else:
			result += c
			i += 1
	return result
