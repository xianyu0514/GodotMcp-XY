# ScriptVerifyTools - Script Tools 验证/分析（validate/verify/analyze/shader）
# 从 script_tools_native.gd 按域拆分（2026-10-03 启动性能：GDScript 编译
# 分帧粒度细化——原单文件 456ms 编译占满一整帧，按域拆分后每模块独立编译
# 独立分帧）。纯机械迁移 + 少量共享纯函数辅助 static 化，函数体未改。

class_name ScriptVerifyTools
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


var _autoload_decls_cache: String = ""


var _autoload_decls_cache_ts: int = 0


const AUTOLOAD_DECLS_CACHE_TTL_MS: int = 5000



## 注册本域全部工具（由 TOOL_SCRIPT_PATHS 的模块条目调用；
## 顺序即本文件内注册函数的出现顺序）。
func register_tools(server_core: RefCounted) -> void:
	_register_analyze_script(server_core)
	_register_get_current_script(server_core)
	_register_validate_script(server_core)
	_register_verify_scripts(server_core)
	_register_validate_shader(server_core)

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
		content = ScriptToolsSharedScript._spaces_to_tabs(content)

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
	# 廉价守卫：无 class_name 声明时无需整段 split/join。
	if not source.contains("class_name "):
		return source
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


func _register_verify_scripts(server_core: RefCounted) -> void:
	var tool_name: String = "verify_scripts"
	var description: String = "Batch-verify the compilation status of project scripts, returning per-script structured errors and warnings with line numbers. With no script_paths it scans the whole project for .gd scripts (skipping res://addons/ and res://test/ by default to avoid false positives from the plugin itself and the test suite), capped by max_scripts. Use after editing code as a verification step, complementing validate_script (single script) and execute_editor_script (full reload). May exceed a default 30s client timeout on large projects — set a longer timeout instead of re-issuing on silence."

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
		"total_checked": checked,
		# 还有脚本没被检查（超过 max_scripts 截断）：调用方/门禁据此判定
		# 本次验证不完整，不能当通过。
		"truncated": checked < paths.size()
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
	# 按路径记忆编译结果：依赖标签推进后的全量重扫只重编译真正变化的文件。
	return ScriptCompileMemoScript.diagnostics_for(script_path,
		"verify|%s" % str(check_warnings),
		func() -> Dictionary:
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
	)

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
	# 磁盘为真相源：工作流刚创建的脚本在 EditorFileSystem 冷缓存里不存在，
	# 走缓存会把 total_checked 报成 0，验证门禁因此永远失败。
	# slice_b：嵌套 Godot 项目——其脚本只在切片项目的类/autoload 上下文可编译。
	_collect_gd_scripts_excluding("res://", result, ["addons", "test", ".godot", "slice_b"])


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


static func _tool_validate_shader(params: Dictionary) -> Dictionary:
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


static func _find_shader_type(code: String) -> Dictionary:
	var lines: PackedStringArray = code.split("\n")
	var re: RegEx = RegEx.new()
	re.compile("^\\s*shader_type\\s+([A-Za-z_][A-Za-z0-9_]*)\\s*;")
	for i in range(lines.size()):
		var m: RegExMatch = re.search(lines[i])
		if m:
			return {"line": i, "value": m.get_string(1)}
	return {"line": -1, "value": ""}


static func _parse_render_modes(code: String) -> Array:
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


static func _strip_shader_comments(code: String) -> String:
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
