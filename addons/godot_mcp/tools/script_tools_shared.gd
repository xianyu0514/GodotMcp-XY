# script_tools_shared.gd - Script Tools 跨域共享纯函数辅助
# 2026-10-03 拆分配套：被发现/写入/验证三个子域共同使用的无状态纯函数集中
# 在此（全部 static，零实例状态、零桶依赖），三个子桶各自 preload 本文件，
# 依赖图保持无环，编译分帧不被 preload 链重新合并。

class_name ScriptToolsShared
extends RefCounted

static func _build_autoload_path_map() -> Dictionary:
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


static func _collect_script_files(directory_path: String, extensions: Array, result: Array) -> void:
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


static func _normalize_script_extensions(raw_extensions: Variant) -> Array:
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


static func _normalize_symbol_kinds(raw_symbol_kinds: Variant) -> Array:
	var normalized: Array = []
	if not (raw_symbol_kinds is Array):
		return normalized
	for kind in raw_symbol_kinds:
		var kind_text: String = str(kind).strip_edges().to_lower()
		if kind_text in ["function", "signal", "property", "constant"] and not normalized.has(kind_text):
			normalized.append(kind_text)
	return normalized


static func _normalize_definition_symbol_kinds(raw_symbol_kinds: Variant) -> Array:
	var normalized: Array = []
	if not (raw_symbol_kinds is Array):
		return normalized
	for kind in raw_symbol_kinds:
		var kind_text: String = str(kind).strip_edges().to_lower()
		if kind_text in ["class", "function", "signal", "property", "constant"] and not normalized.has(kind_text):
			normalized.append(kind_text)
	return normalized


static func _normalize_reference_extensions(raw_extensions: Variant) -> Array:
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


static func _is_valid_identifier_name(identifier_name: String) -> bool:
	if identifier_name.is_empty():
		return false
	var regex: RegEx = RegEx.new()
	if regex.compile("^[A-Za-z_][A-Za-z0-9_]*$") != OK:
		return false
	return regex.search(identifier_name) != null


static func _strip_inline_comment(line: String) -> String:
	var comment_index: int = line.find("#")
	if comment_index >= 0:
		return line.substr(0, comment_index)
	return line


static func _strip_csharp_line_comment(line: String) -> String:
	var comment_index: int = line.find("//")
	if comment_index >= 0:
		return line.substr(0, comment_index)
	return line


static func _collect_script_reference_files(directory_path: String, extensions: Array, result: Array,
		include_tooling: bool = true) -> void:
	var normalized: Array[String] = []
	for ext_value in extensions:
		var ext: String = String(ext_value).strip_edges().to_lower()
		if not ext.begins_with("."):
			ext = "." + ext
		if not ext.is_empty() and not normalized.has(ext):
			normalized.append(ext)
	var collected: Array[String] = []
	ProjectToolsNative._collect_resources(directory_path, normalized, collected, false, include_tooling)
	collected.sort()
	for path_value in collected:
		result.append(path_value)


static func _escape_regex_pattern(text: String) -> String:
	var escaped: String = ""
	var special_characters: String = "\\.^$|?*+()[]{}"
	for character in text:
		var character_text: String = str(character)
		if special_characters.contains(character_text):
			escaped += "\\" + character_text
		else:
			escaped += character_text
	return escaped

## 行级"代码区域"掩蔽：注释（# 之后）与字符串字面量（'…' / "…"，含
## 反斜杠转义；三引号块跨行由调用方携带状态）里的位置标记为 true——
## 这些位置上的符号名匹配不属于代码引用，重命名不得触碰（E4 语义）。


static func _masked_code_positions(line: String, in_triple_quote_in: bool) -> Dictionary:
	var mask: Array = []
	mask.resize(line.length())
	for i in range(line.length()):
		mask[i] = in_triple_quote_in
	var in_triple_quote: bool = in_triple_quote_in
	var in_string: int = 0  # 0=无, 1='...', 2="..."
	var i: int = 0
	while i < line.length():
		var ch: String = line[i]
		if in_triple_quote:
			if line.substr(i, 3) == '"""':
				mask[i] = true
				mask[i + 1] = true
				mask[i + 2] = true
				in_triple_quote = false
				i += 3
				continue
			mask[i] = true
			i += 1
			continue
		if in_string != 0:
			mask[i] = true
			var quote: String = "'" if in_string == 1 else '"'
			if ch == "\\" and i + 1 < line.length():
				mask[i + 1] = true
				i += 2
				continue
			if ch == quote:
				in_string = 0
			i += 1
			continue
		if ch == "#":
			for j in range(i, line.length()):
				mask[j] = true
			break
		if line.substr(i, 3) == '"""':
			mask[i] = true
			mask[i + 1] = true
			mask[i + 2] = true
			in_triple_quote = true
			i += 3
			continue
		if ch == "'" or ch == '"':
			in_string = 1 if ch == "'" else 2
			mask[i] = true
		i += 1
	return {"mask": mask, "in_triple_quote": in_triple_quote}


static func _spaces_to_tabs(code: String) -> String:
	# 廉价守卫：没有任何以 4 空格开头的行时跳过整段 split/join。
	if not (code.begins_with("    ") or code.contains("\n    ")):
		return code
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
