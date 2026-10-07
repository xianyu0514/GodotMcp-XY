# ScriptWriteTools - Script Tools 写入（create/modify/rename/attach/open）
# 从 script_tools_native.gd 按域拆分（2026-10-03 启动性能：GDScript 编译
# 分帧粒度细化——原单文件 456ms 编译占满一整帧，按域拆分后每模块独立编译
# 独立分帧）。纯机械迁移 + 少量共享纯函数辅助 static 化，函数体未改。

class_name ScriptWriteTools
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
	_register_rename_script_symbol(server_core)
	_register_create_script(server_core)
	_register_modify_script(server_core)
	_register_open_script_at_line(server_core)
	_register_attach_script(server_core)

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
	if not ScriptToolsSharedScript._is_valid_identifier_name(new_name):
		return {"error": "new_name must be a valid identifier"}

	var search_path: String = str(params.get("search_path", "res://")).strip_edges()
	var path_validation: Dictionary = PathValidator.validate_directory_path(search_path)
	if not path_validation["valid"]:
		return {"error": "Invalid path: " + path_validation["error"]}
	search_path = path_validation["sanitized"]

	var include_extensions: Array = ScriptToolsSharedScript._normalize_reference_extensions(params.get("include_extensions", [".gd", ".cs", ".tscn"]))
	if include_extensions.is_empty():
		return {"error": "include_extensions must contain at least one supported file extension"}

	var case_sensitive: bool = bool(params.get("case_sensitive", true))
	var dry_run: bool = bool(params.get("dry_run", true))
	var max_results: int = max(1, int(params.get("max_results", 200)))

	var file_paths: Array = []
	ScriptToolsSharedScript._collect_script_reference_files(search_path, include_extensions, file_paths)
	file_paths.sort()

	# —— 准备阶段：dry_run 逐文件计算精确替换与内容指纹 ——
	# 后续写入阶段对同一批未改动的文件重跑同一替换（符号级幂等），
	# 预览（planned）与应用由这份数据绑定，写入后逐文件核对磁盘指纹。
	var planned_results: Array = []
	var replacement_count: int = 0
	for file_path in file_paths:
		if replacement_count >= max_results:
			break
		var remaining_results: int = max_results - replacement_count
		var planned: Dictionary = _rename_symbol_in_file(file_path, symbol_name, new_name, case_sensitive, true, remaining_results)
		if planned.is_empty():
			continue
		planned_results.append(planned)
		replacement_count += int(planned.get("replacement_count", 0))

	if dry_run or planned_results.is_empty():
		return {
			"symbol_name": symbol_name,
			"new_name": new_name,
			"dry_run": dry_run,
			"changed_files": planned_results,
			"replacement_count": replacement_count
		}

	# —— 写入前守卫 1：未收口的旧操作若与手工修改冲突（diverged），拒绝执行 ——
	# 磁盘实况不是旧操作记录的 before/after 之一 = 中断后有人手工改过，
	# 此时覆盖会吞掉用户工作（评测任务 R4 契约）。
	var touched_paths: Array = []
	for planned_entry in planned_results:
		touched_paths.append(String(planned_entry.get("script_path", "")))
	var resumable_notes: Array = []
	for pending_value in ChangeJournalScript.pending_operations_touching(touched_paths):
		var verdict: Dictionary = ChangeJournalScript.classify_operation(pending_value)
		if String(verdict.get("action", "")) == "conflict":
			return {
				"error": "A previous interrupted operation has manually-modified files; refusing to overwrite. Resolve them, then retry.",
				"prior_operation": verdict,
			}
		resumable_notes.append(verdict)

	# —— 写入前守卫 2：目标文件在脚本编辑器中有未保存修改时，磁盘指纹不可靠，
	# 写入会让用户保存时覆盖本次修改 ——
	var editor_interface: EditorInterface = _get_editor_interface()
	var script_editor: ScriptEditor = editor_interface.get_script_editor() if editor_interface else null
	for planned_entry in planned_results:
		var guard_result: Dictionary = _script_buffer_write_guard(script_editor, String(planned_entry.get("script_path", "")))
		if guard_result.has("error"):
			return guard_result

	# —— 变更日志：任何文件写入之前先落盘 prepared 记录 ——
	var journal_entries: Array = []
	for planned_entry in planned_results:
		journal_entries.append({
			"path": String(planned_entry.get("script_path", "")),
			"before_hash": String(planned_entry.get("content_before_hash", "")),
			"after_hash": String(planned_entry.get("content_after_hash", "")),
			"replacement_count": int(planned_entry.get("replacement_count", 0)),
		})
	var intent: String = "rename_script_symbol %s -> %s (case_sensitive=%s, max_results=%d)" % [symbol_name, new_name, str(case_sensitive), max_results]
	var begun: Dictionary = ChangeJournalScript.begin_operation(intent, journal_entries)
	var operation_id: String = ""
	var journal_error: String = ""
	if begun.has("error"):
		# 日志不可写不应阻断重命名本身，但必须在结果里如实暴露（降级运行）。
		journal_error = String(begun["error"])
	else:
		operation_id = String((begun.get("operation", {}) as Dictionary).get("operation_id", ""))
		if not operation_id.is_empty():
			ChangeJournalScript.supersede_pending_touching(touched_paths, operation_id)

	# —— 写入阶段：逐文件应用，每写完一个立即推进日志并核对磁盘指纹 ——
	var changed_files: Array = []
	var applied_count: int = 0
	var verification_mismatches: Array = []
	for planned_entry in planned_results:
		var target_path: String = String(planned_entry.get("script_path", ""))
		var remaining: int = max_results - applied_count
		if remaining <= 0:
			break
		var replacement_result: Dictionary = _rename_symbol_in_file(target_path, symbol_name, new_name, case_sensitive, false, remaining)
		if replacement_result.is_empty():
			# 准备与写入之间文件被改动，计划中的替换没有发生。
			verification_mismatches.append({
				"path": target_path,
				"issue": "planned replacement did not apply (file changed between prepare and apply)"
			})
			continue
		changed_files.append(replacement_result)
		applied_count += int(replacement_result.get("replacement_count", 0))
		if not operation_id.is_empty():
			ChangeJournalScript.mark_file_applied(operation_id, target_path)
		if _file_sha256(target_path) != String(planned_entry.get("content_after_hash", "")):
			verification_mismatches.append({
				"path": target_path,
				"issue": "post-write disk content does not match the planned fingerprint"
			})

	var verified: bool = verification_mismatches.is_empty() and applied_count == replacement_count
	if not operation_id.is_empty():
		ChangeJournalScript.finish_operation(operation_id, verified, verification_mismatches)

	var result: Dictionary = {
		"symbol_name": symbol_name,
		"new_name": new_name,
		"dry_run": false,
		"changed_files": changed_files,
		"replacement_count": applied_count
	}
	if not operation_id.is_empty():
		result["change_journal"] = {
			"operation_id": operation_id,
			"phase": "committed" if verified else "failed",
			"verified": verified,
			"journal_path": ChangeJournalScript.DEFAULT_JOURNAL_PATH,
			"file_count": journal_entries.size()
		}
	elif not journal_error.is_empty():
		result["change_journal_error"] = journal_error
	if not resumable_notes.is_empty():
		result["resumed_prior_operations"] = resumable_notes
	if not verification_mismatches.is_empty():
		result["verification_mismatches"] = verification_mismatches
	return result


static func _file_sha256(path: String) -> String:
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		return ""
	var content: String = file.get_as_text()
	file.close()
	return content.sha256_text()

# 辅助函数：递归收集脚本文件


func _rename_symbol_in_file(file_path: String, symbol_name: String, new_name: String, case_sensitive: bool, dry_run: bool, remaining_results: int) -> Dictionary:
	var file: FileAccess = FileAccess.open(file_path, FileAccess.READ)
	if not file:
		return {}

	var original_content: String = file.get_as_text()
	file.close()
	var lines: PackedStringArray = original_content.split("\n")

	var regex: RegEx = RegEx.new()
	var escaped_symbol_name: String = ScriptToolsSharedScript._escape_regex_pattern(symbol_name)
	var compile_pattern: String = "(?i)(?<![A-Za-z0-9_])%s(?![A-Za-z0-9_])" % escaped_symbol_name if not case_sensitive else "(?<![A-Za-z0-9_])%s(?![A-Za-z0-9_])" % escaped_symbol_name
	if regex.compile(compile_pattern) != OK:
		return {}

	var replacements: Array = []
	var applied_total: int = 0
	var updated_lines: PackedStringArray = []
	var in_triple_quote: bool = false
	for i in range(lines.size()):
		var raw_line: String = lines[i]
		var new_line: String = raw_line
		var line_replaced: int = 0
		# E4 语义：注释与字符串字面量里的同名文本不属于符号引用，不得修改。
		var masking: Dictionary = ScriptToolsSharedScript._masked_code_positions(raw_line, in_triple_quote)
		in_triple_quote = bool(masking["in_triple_quote"])
		var mask: Array = masking["mask"]
		if applied_total < remaining_results:
			# RegEx.sub 的第 4 个参数是起始偏移而不是替换数量；
			# 手工重建行内容，保证实际替换次数、预览与 replacement_count 三者一致。
			var matches: Array = regex.search_all(raw_line)
			var code_matches: Array = []
			for match_value in matches:
				var match_candidate: RegExMatch = match_value
				if not bool(mask[match_candidate.get_start()]):
					code_matches.append(match_candidate)
			var take: int = min(code_matches.size(), remaining_results - applied_total)
			if take > 0:
				var rebuilt: String = ""
				var cursor: int = 0
				for match_index in range(take):
					var match_result: RegExMatch = code_matches[match_index]
					rebuilt += raw_line.substr(cursor, match_result.get_start() - cursor)
					rebuilt += new_name
					cursor = match_result.get_end()
					line_replaced += 1
				rebuilt += raw_line.substr(cursor)
				new_line = rebuilt
		if line_replaced > 0:
			applied_total += line_replaced
			replacements.append({
				"line": i + 1,
				"before": raw_line.strip_edges(),
				"after": new_line.strip_edges(),
				"replacement_count": line_replaced
			})
			updated_lines.append(new_line)
			if applied_total >= remaining_results:
				for j in range(i + 1, lines.size()):
					updated_lines.append(lines[j])
				break
		else:
			updated_lines.append(new_line)

	if replacements.is_empty():
		return {}

	if not dry_run:
		var write_file: FileAccess = FileAccess.open(file_path, FileAccess.WRITE)
		if not write_file:
			return {}
		write_file.store_string("\n".join(updated_lines))
		write_file.close()

	return {
		"script_path": file_path,
		"replacement_count": applied_total,
		"changes": replacements,
		# 内容指纹：预览与实际写入由同一份数据计算（M3 变更日志绑定），
		# after 指纹即写入后磁盘应有的内容，恢复时以此核对实况。
		"content_before_hash": original_content.sha256_text(),
		"content_after_hash": ("\n".join(updated_lines)).sha256_text()
	}

# ============================================================================
# read_script - 读取脚本内容
# ============================================================================


func _register_create_script(server_core: RefCounted) -> void:
	var tool_name: String = "create_script"
	var description: String = "Create a new GDScript (.gd) or C# (.cs) script file with optional template. Saved GDScript returns immediate compiler diagnostics; check validation_status separately from write status."
	
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
	output_schema["properties"].merge(SCRIPT_WRITE_DIAGNOSTICS.output_properties())
	server_core.register_tool(tool_name, description, input_schema,
						  Callable(self, "_tool_create_script"),
						  output_schema, annotations,
						  "core", "Script")


func _tool_create_script(params: Dictionary) -> Dictionary:
	var script_path: String = params.get("script_path", "")
	var content: String = params.get("content", "")
	var template: String = params.get("template", "empty")
	var is_shader: bool = false
	var attach_to_node: String = params.get("attach_to_node", "")

	if script_path.is_empty():
		return {"error": "Missing required parameter: script_path"}

	is_shader = script_path.strip_edges().ends_with(".gdshader")
	var validation: Dictionary = PathValidator.validate_file_path(script_path, [".gd", ".cs", ".gdshader"])
	if not validation["valid"]:
		return {"error": "Invalid path: " + validation["error"]}

	script_path = validation["sanitized"]

	if FileAccess.file_exists(script_path):
		return {"error": "File already exists: " + script_path}

	if content.is_empty():
		if is_shader:
			content = "shader_type canvas_item;\n\nvoid fragment() {\n	COLOR = texture(TEXTURE, UV);\n}\n"
		elif script_path.ends_with(".cs"):
			content = _get_csharp_script_template(template, script_path.get_file().get_basename())
		else:
			content = _get_script_template(template)

	# 着色器先校验后落盘：无效内容不写盘（坏文件不进项目，也避开导入器
	# 引擎噪音）；force=true 可强制写入。
	var shader_precheck: Dictionary = {}
	if is_shader:
		shader_precheck = load("res://addons/godot_mcp/tools/script_verify_tools.gd")._tool_validate_shader({"content": content})
		if int(shader_precheck.get("issue_count", 0)) > 0 and not bool(params.get("force", false)):
			return {
				"status": "failed",
				"script_path": script_path,
				"has_errors": true,
				"shader_type": str(shader_precheck.get("shader_type", "")),
				"diagnostics": shader_precheck.get("issues", []) if shader_precheck.get("issues", []) is Array else [],
				"diagnostics_truncated": false,
				"hint": "shader content invalid — nothing written (pass force=true to write anyway)",
			}

	# 目标目录不存在时先创建（工作流按 profile 推导的 res://scripts/ 等新目录）。
	var script_parent: String = script_path.get_base_dir()
	if script_parent != "res://" and not script_parent.is_empty():
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(script_parent))
	var file: FileAccess = FileAccess.open(script_path, FileAccess.WRITE)
	if not file:
		return {"error": "Failed to create file: " + script_path}

	file.store_string(content)
	file.close()
	# 写侧失效编译 memo：mtime 秒级 + 等长改写会让 memo 无限供出旧结论。
	ScriptCompileMemoScript.invalidate(script_path)

	var line_count: int = content.split("\n").size()
	var result: Dictionary = {
		"status": "success",
		"script_path": script_path,
		"line_count": line_count,
		# 落盘后立即同步编辑器（文件系统 + 打开的缓冲区），使写入成为编辑器
		# 内部操作而不是待确认的“外部修改”。
		"buffers_synced": EditorToolsNative.sync_script_buffer_after_write(
			_get_editor_interface(), script_path).get("status", "")
	}
	if is_shader:
		# 着色器不走 GDScript 诊断：复用 validate_shader 的文本校验
		# （shader_type/括号平衡/基本结构），结果并入同一形状。
		var shader_check: Dictionary = load("res://addons/godot_mcp/tools/script_verify_tools.gd")._tool_validate_shader({"content": content})
		result["validation_status"] = "failed" if int(shader_check.get("issue_count", 0)) > 0 else "passed"
		var shader_issues: Array = shader_check.get("issues", []) if shader_check.get("issues", []) is Array else []
		result["diagnostics"] = shader_issues
		result["diagnostics_truncated"] = false
		result["has_errors"] = int(shader_check.get("issue_count", 0)) > 0
		result["shader_type"] = str(shader_check.get("shader_type", ""))
	else:
		result.merge(SCRIPT_WRITE_DIAGNOSTICS.check(script_path))

	if is_shader and not attach_to_node.is_empty():
		# 着色器挂载语义：load(.gdshader) -> ShaderMaterial(内联) -> node.material。
		# CanvasItem 节点挂 material；其余类型给出可操作警告而不是静默失败。
		var shader_editor: EditorInterface = _get_editor_interface()
		if shader_editor == null:
			result["attach_warning"] = "Editor interface not available for shader attachment"
		else:
			var target_node: Node = _resolve_node_path(shader_editor, attach_to_node)
			if target_node == null:
				result["attach_warning"] = "Node not found: " + attach_to_node \
					+ NodeToolsNative._suggest_parent_path(shader_editor.get_edited_scene_root(), attach_to_node)
			elif not (target_node is CanvasItem):
				result["attach_warning"] = "shader attach expects a CanvasItem (use the visual child, e.g. Player/Visual): " + attach_to_node
			else:
				var shader_res: Shader = load(script_path)
				if shader_res == null:
					result["attach_warning"] = "Shader file written but failed to load: " + script_path
				else:
					var material := ShaderMaterial.new()
					material.shader = shader_res
					(target_node as CanvasItem).material = material
					shader_editor.mark_scene_as_unsaved()
					result["attached_to"] = attach_to_node
					result["attach_kind"] = "shader_material"
		return result

	if not attach_to_node.is_empty():
		if result.get("validation_status", "") == "failed":
			result["attach_warning"] = "Script saved but not attached because compilation failed; inspect diagnostics."
			return result
		var editor_interface: EditorInterface = _get_editor_interface()
		if editor_interface:
			var node: Node = _resolve_node_path(editor_interface, attach_to_node)
			if node:
				var script_res: Script = load(script_path)
				# 刚写入的文件 load() 到的是未编译壳；现场编译（不注册路径，
				# 避免被扫描失效），update_file 让后续会话按路径加载。
				var cold_attach: bool = false
				if script_res and not script_res.can_instantiate():
					var fresh_attach: GDScript = GDScript.new()
					fresh_attach.source_code = FileAccess.get_file_as_string(script_path)
					if fresh_attach.reload() == OK:
						# take_over_path：让场景保存时按外部路径（res://...）引用该
						# 脚本，而不是把源码内嵌成 sub_resource。内嵌会让后续修改
						# .gd 文件与运行中的场景静默分叉（first-playable 冒烟实测：
						# 文件已提交 SPEED 400，游戏仍以 200 运行）。
						fresh_attach.take_over_path(script_path)
						script_res = fresh_attach
						cold_attach = true
					else:
						script_res = null
				if script_res:
					node.set_script(script_res)
					result["attached_to"] = attach_to_node
					if cold_attach:
						editor_interface.get_resource_filesystem().update_file(script_path)
				else:
					result["attach_warning"] = "Script created but failed to load for attachment"
			else:
				result["attach_warning"] = "Node not found: " + attach_to_node \
					+ NodeToolsNative._suggest_parent_path(editor_interface.get_edited_scene_root(), attach_to_node)
		else:
			result["attach_warning"] = "Editor interface not available for script attachment"

	return result


func _resolve_node_path(editor_interface: EditorInterface, path: String) -> Node:
	var edited_scene: Node = editor_interface.get_edited_scene_root()
	if not edited_scene:
		return null
	return _resolve_node_within(edited_scene, path)

## 纯逻辑路径解析（可单测）："/root" 与 "." 显式指被编辑场景根——
## 裸 "/root" 走绝对路径会命中编辑器自己的 Window，挂载静默改错对象
## （真实编辑器 E2E 抓到：场景根从未拿到脚本，控制器全都没在运行）。


static func _resolve_node_within(edited_scene: Node, path: String) -> Node:
	if path == "/root" or path == ".":
		return edited_scene
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
		# 0 字节脚本无法通过编译，也会让挂载与验证门禁失败；默认给最小合法脚本。
		return "extends Node\n"


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
	var description: String = "Modify an existing GDScript (.gd) or C# (.cs) file. Prefer old_text for an exact unique replacement and expected_content_hash from read_script to reject stale writes. Invalid lines and missing/ambiguous text leave the file unchanged. Saved GDScript returns compiler diagnostics; check validation_status separately from write status."
	
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
				"description": "Replacement content: whole file by default, one line with line_number, or the unique old_text block. Empty content is allowed only with old_text (deletion)."
			},
			"line_number": {
				"type": "integer",
				"description": "Line to replace (1-indexed); out-of-range values are rejected. Omitted or 0 means whole file. Cannot combine with old_text."
			},
			"old_text": {
				"type": "string",
				"description": "Optional exact nonempty text to replace with content. Must occur exactly once. Line endings auto-normalize to the file style (miss diagnostics report both sides). Use a larger block when ambiguous."
			},
			"expected_content_hash": {
				"type": "string",
				"description": "Optional SHA-256 content_hash from read_script/batch_read_scripts or the last modify_script result. A mismatch returns content_conflict without writing; re-read and reapply the intended edit."
			},
			"validate": {
				"type": "boolean",
				"description": "Inline-validate .gd after writing and return errors in 'validation' (default true).",
				"default": true
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
			"content_hash": {"type": "string", "description": "SHA-256 of the written UTF-8 source."},
			"buffer_guard_supported": {"type": "boolean", "description": "Whether the editor can detect unsaved script buffers. False without an editor or on older engines."},
			"error_code": {"type": "string"},
			"current_content_hash": {"type": "string"},
			"recovery_hint": {"type": "string"},
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
	output_schema["properties"].merge(SCRIPT_WRITE_DIAGNOSTICS.output_properties())
	server_core.register_tool(tool_name, description, input_schema,
						  Callable(self, "_tool_modify_script"),
						  output_schema, annotations,
						  "core", "Script")


func _tool_modify_script(params: Dictionary) -> Dictionary:
	# 在类型转换和打开写句柄之前验证，错误请求不能退化成全文件覆盖。
	if not params.get("script_path", "") is String:
		return {"error": "script_path must be a string"}
	if not params.get("content") is String:
		return {"error": "Missing or invalid required parameter: content (string)"}
	var raw_line: Variant = params.get("line_number", 0)
	if not (raw_line is int or raw_line is float):
		return {"error": "line_number must be a non-negative integer"}
	if not is_finite(raw_line) or raw_line < 0 or raw_line > 2147483647 or raw_line != int(raw_line):
		return {"error": "line_number must be a non-negative integer within file bounds"}
	var has_old_text: bool = params.has("old_text")
	if has_old_text:
		if not params["old_text"] is String or String(params["old_text"]).is_empty():
			return {"error": "old_text must be a nonempty string"}
		if params.has("line_number"):
			return {"error": "old_text and line_number cannot be combined"}
	if params.has("expected_content_hash"):
		if not params["expected_content_hash"] is String:
			return {"error": "expected_content_hash must be a SHA-256 hex string"}
		var expected: String = params["expected_content_hash"]
		if expected.length() != 64 or not expected.is_valid_hex_number(false):
			return {"error": "expected_content_hash must be a 64-character SHA-256 hex string"}
	var script_path: String = params.get("script_path", "")
	var new_content: String = params.get("content", "")
	var line_number: int = int(raw_line)
	
	# 参数验证
	if script_path.is_empty():
		return {"error": "Missing required parameter: script_path"}
	if new_content.is_empty() and not has_old_text:
		return {"error": "Missing required parameter: content"}

	# 2026-10-03 台账 P1-2（write 侧）：modify_script 只管 .gd/.cs；数据文件
	# (.json/.tscn/.cfg...) 的写入走 apply_change_set 变更单（可预览/可恢复）。
	var write_lower_path: String = script_path.to_lower()
	if not (write_lower_path.ends_with(".gd") or write_lower_path.ends_with(".cs")):
		return {
			"error": "modify_script edits .gd/.cs only, but '%s' does not look like a script file." % script_path,
			"error_code": "not_a_script",
			"next_step": "For .json/.tscn/.tres/.cfg and other text project files, call apply_change_set with an operations entry {\"path\": \"%s\", ...} — it previews, applies and journals cross-file changes with content-hash guards." % script_path
		}
	
	# 使用PathValidator验证路径安全性
	var validation: Dictionary = PathValidator.validate_file_path(script_path, [".gd", ".cs"])
	if not validation["valid"]:
		return {"error": "Invalid path: " + validation["error"]}

	# 使用清理后的路径
	script_path = validation["sanitized"]

	# 验证文件是否存在
	if not FileAccess.file_exists(script_path):
		return {"error": "File not found: " + script_path}
	var editor_interface: EditorInterface = _get_editor_interface()
	var script_editor: ScriptEditor = editor_interface.get_script_editor() if editor_interface else null
	var buffer_guard: Dictionary = _script_buffer_write_guard(script_editor, script_path)
	if buffer_guard.has("error"):
		return buffer_guard
	
	# 读取现有内容
	var file: FileAccess = FileAccess.open(script_path, FileAccess.READ)
	if not file:
		return {"error": "Failed to open file for reading: " + script_path}
	
	var existing_content: String = file.get_as_text()
	file.close()
	var current_hash: String = existing_content.sha256_text()
	if params.has("expected_content_hash") and String(params["expected_content_hash"]).to_lower() != current_hash:
		return {"error": "Script changed since it was read; no changes were written.",
			"error_code": "content_conflict", "script_path": script_path,
			"current_content_hash": current_hash,
			"recovery_hint": "Read the script again, preserve newer changes, and reapply the intended edit with the new content_hash."}

	var final_content: String = new_content
	var line_endings_normalized: bool = false
	if has_old_text:
		var old_text: String = params["old_text"]
		var match_at: int = existing_content.find(old_text)
		var effective_old: String = old_text
		var effective_new: String = new_content
		if match_at < 0:
			# 2026-10-03 台账 P1-3（S10）：Windows 工程默认 CRLF，调用方按
			# LF 构造 old_text 是常态摩擦。原样匹配失败时按文件的主导行尾
			# 风格转换 old_text/new_text 再匹配一次，替换文本跟随同一风格。
			var file_uses_crlf: bool = existing_content.contains("\r\n")
			var old_uses_crlf: bool = old_text.contains("\r\n")
			if file_uses_crlf and not old_uses_crlf:
				effective_old = old_text.replace("\n", "\r\n")
				effective_new = new_content.replace("\n", "\r\n")
			elif not file_uses_crlf and old_uses_crlf:
				effective_old = old_text.replace("\r\n", "\n")
				effective_new = new_content.replace("\r\n", "\n")
			if not effective_old == old_text:
				match_at = existing_content.find(effective_old)
				line_endings_normalized = match_at >= 0
		if match_at < 0:
			var file_style: String = "CRLF" if existing_content.contains("\r\n") else "LF"
			var old_style: String = "CRLF" if old_text.contains("\r\n") else "LF"
			return {"error": "old_text was not found; no changes were written.", "error_code": "text_not_found",
				"file_line_endings": file_style, "old_text_line_endings": old_style,
				"recovery_hint": "Read the current script and use exact text, including whitespace and line endings. This file uses %s line endings while old_text uses %s — after fixing line endings, also check for whitespace drift." % [file_style, old_style]}
		if existing_content.find(effective_old, match_at + 1) >= 0:
			return {"error": "old_text matches more than once; no changes were written.", "error_code": "ambiguous_text",
				"recovery_hint": "Include more surrounding text so old_text identifies exactly one block."}
		final_content = existing_content.substr(0, match_at) + effective_new + existing_content.substr(match_at + effective_old.length())
	elif line_number > 0:
		var existing_lines: PackedStringArray = existing_content.split("\n")
		if line_number > existing_lines.size():
			return {"error": "line_number is outside the script; no changes were written.", "error_code": "line_out_of_range"}
		# 保留未修改部分的字节文本，包括 CRLF 和文件末尾换行。
		var ending: String = "\r" if existing_lines[line_number - 1].ends_with("\r") and not new_content.ends_with("\r") else ""
		existing_lines[line_number - 1] = new_content + ending
		final_content = "\n".join(existing_lines)
	
	# 写入文件
	file = FileAccess.open(script_path, FileAccess.WRITE)
	if not file:
		return {"error": "Failed to open file for writing: " + script_path}
	
	file.store_string(final_content)
	file.close()
	# 写侧失效编译 memo：修复循环里同秒等长改写（== ↔ != 等）必须立即
	# 重编译，否则 verify_scripts 拿到修复前的结论且无 TTL 上界。
	ScriptCompileMemoScript.invalidate(script_path)

	# 计算行数
	var line_count: int = final_content.split("\n").size()

	var result: Dictionary = {
		"status": "success",
		"script_path": script_path,
		"content_hash": final_content.sha256_text(),
		"buffer_guard_supported": buffer_guard["supported"],
		"line_count": line_count,
		# 落盘后立即同步编辑器，避免“文件已在磁盘上修改”的重载弹窗。
		"buffers_synced": EditorToolsNative.sync_script_buffer_after_write(
			editor_interface, script_path).get("status", "")
	}
	if line_endings_normalized:
		# 行尾兜底生效必须显式回执：调用方写入的字节与 old_text/new_text
		# 的字面行尾不同（跟随了文件风格）。
		result["line_endings_normalized"] = true
	var validation_enabled: bool = bool(params.get("validate", true))
	result.merge(SCRIPT_WRITE_DIAGNOSTICS.check(script_path, validation_enabled))
	if script_path.ends_with(".gd") and validation_enabled:
		# Preserve the existing summary for clients that already consume it.
		var errors: Array = []
		for diagnostic: Dictionary in result["diagnostics"]:
			if diagnostic["severity"] == "error":
				errors.append(diagnostic)
		result["validation"] = {"valid": result["validation_status"] == "passed",
			"error_count": errors.size(), "errors": errors.slice(0, 5)}
	return result


## 编辑器未保存缓冲区与磁盘版本是两份状态，磁盘 hash 不能替代缓冲区检查。


static func _script_buffer_write_guard(script_editor: Object, script_path: String) -> Dictionary:
	if script_editor == null:
		return {"supported": false}
	var target_path: String = ProjectSettings.globalize_path(script_path).simplify_path()
	if OS.get_name() == "Windows":
		target_path = target_path.to_lower()
	for method_name: String in ["get_unsaved_files", "get_unsaved_scripts"]:
		if not script_editor.has_method(method_name):
			continue
		for unsaved_path: Variant in script_editor.call(method_name):
			var normalized_path: String = ProjectSettings.globalize_path(str(unsaved_path)).simplify_path()
			if OS.get_name() == "Windows":
				normalized_path = normalized_path.to_lower()
			if normalized_path == target_path:
				return {"error": "The script has unsaved editor changes; no changes were written.",
					"error_code": "unsaved_script_changes", "script_path": script_path, "supported": true,
					"recovery_hint": "Preserve or resolve the unsaved editor changes, then read_script again before retrying."}
		return {"supported": true}
	return {"supported": false}

# ============================================================================
# analyze_script - 分析脚本结构（完整版）
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
			"scene_path": {"type": "string", "description": "Optional: ensure this scene is the active edited scene first (auto-activated; the previous scene is saved when modified)."},
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

	var context_guard: Dictionary = await SCENE_CONTEXT.ensure_scene_active(
		editor_interface, String(params.get("scene_path", "")))
	if not bool(context_guard.get("ok", false)):
		return {"error": String(context_guard.get("error", "scene context guard failed"))}

	var validation: Dictionary = PathValidator.validate_file_path(script_path, [".gd", ".cs"])
	if not validation["valid"]:
		return {"error": "Invalid script path: " + validation["error"]}
	script_path = validation["sanitized"]

	if not FileAccess.file_exists(script_path):
		return {"error": "Script file not found: " + script_path}

	var target_node: Node = _resolve_node_path(editor_interface, node_path)
	if not target_node:
		return {"error": "Node not found: " + node_path}
	# 目标必须在被编辑场景子树内：解析到编辑器自身的节点（如编辑器 Window）
	# 时挂载会静默改错对象——宁可失败也不动不属于当前场景的节点。
	var edited_scene_root: Node = editor_interface.get_edited_scene_root()
	if target_node != edited_scene_root and not edited_scene_root.is_ancestor_of(target_node):
		return {"error": "Node '%s' is outside the edited scene; refusing to modify editor-owned nodes." % node_path}

	var previous_script: String = ""
	var old_script: Variant = target_node.get_script()
	if old_script and old_script is Script:
		previous_script = old_script.resource_path

	var script_res: Script = load(script_path)
	if not script_res:
		return {"error": "Failed to load script: " + script_path}
	# 刚写入的文件在编辑器文件系统扫描前 load() 到的是未编译资源（有源码
	# 无成员）。现场编译等价脚本验证可编译性，但挂载用文件引用（非匿名
	# 副本）——累积模式下 save_scene 需要把 ext_resource 引用持久化到
	# 场景文件，下一个 run_project 才会从磁盘加载正确的脚本（Q1 深修，
	# 真机累积 E2E 抓到：内联编译的匿名脚本被嵌入 sub_resource，重启后
	# 游戏仍跑旧控制器的行为）。
	var script_was_cold: bool = false
	if not script_res.can_instantiate():
		var fresh_script: GDScript = GDScript.new()
		fresh_script.source_code = FileAccess.get_file_as_string(script_path)
		if fresh_script.reload() != OK:
			return {"error": "Script did not compile: " + script_path}
		script_was_cold = true
		# 强制更新文件系统让文件资源可实例化，然后用文件引用挂载
		editor_interface.get_resource_filesystem().update_file(script_path)
		editor_interface.get_resource_filesystem().scan()
		# 重新加载——扫描后应能实例化
		script_res = load(script_path)
		if not script_res or not script_res.can_instantiate():
			# 扫描后仍冷：退回内联编译（单目标模式兼容）
			script_res = fresh_script

	target_node.set_script(script_res)

	return {
		"status": "success",
		"node_path": node_path,
		"script_path": script_path,
		"previous_script": previous_script
	}

# ============================================================================
# validate_script - 验证 GDScript 语法
# ============================================================================


