@tool
class_name ChangeSetTools
extends RefCounted

# apply_change_set（M5 第二交付工具层）：把 ChangeSetExecutor 的可恢复
# 变更单协议暴露为 MCP 工具，并接上编辑器侧守卫。
#
# 工具层职责（执行器保持纯逻辑）：
# - 写入前守卫：modify 的 .gd/.cs 目标若有未保存编辑器缓冲区，拒绝执行
#   （磁盘指纹不可靠，写入会被用户保存时覆盖）。
# - 写入后同步：对写过的脚本调用 sync_script_buffer_after_write，
#   让打开的脚本编辑器看到外部修改。
# - 结果补充 follow-up：verify_scripts（编译验证）与 query_change_impact
#   （影响范围），完成审计要求的"差异 + 验证计划"闭环。

const ExecutorScript = preload("res://addons/godot_mcp/tools/change_set_executor.gd")

var _editor_interface: EditorInterface = null
## journal 落盘位置。生产固定默认（res://.mcp/change_journal.json，恢复
## 语义的一部分，不作为用户参数）；测试注入临时路径。
var _journal_path: String = ""

func initialize(editor_interface: EditorInterface) -> void:
	_editor_interface = editor_interface

func register_tools(server_core: RefCounted) -> void:
	_register_apply_change_set(server_core)

# ============================================================================
# apply_change_set
# ============================================================================

func _register_apply_change_set(server_core: RefCounted) -> void:
	var tool_name: String = "apply_change_set"
	var description: String = "Apply a recoverable cross-file change set over text resources (.gd/.cs/.tscn/.tres/.cfg/.json...): preview pins every file's read version (expected_content_hash), then per-file write->readback->journal-mark. If the journal cannot be written the change set refuses to start. Interrupted sets (crash/disconnect) are re-submitted with the same change_set_id and the same operations — applied files are skipped, untouched files are resumed, manually-edited files stop at an explicit conflict and are never overwritten. Committed sets replay as a receipt without rewriting. dry_run=true previews fingerprints and edit counts without touching disk."

	var input_schema: Dictionary = {
		"type": "object",
		"properties": {
			"intent": {
				"type": "string",
				"description": "What this change set is for (recorded in the journal for recovery classification)."
			},
			"operations": {
				"type": "array",
				"items": {"type": "object"},
				"description": "Per-file operations. modify: {path, expected_content_hash (from read_script/batch_read_scripts), edits: [{old_text, new_text}] — each old_text must occur exactly once}. create: {path, new_content}."
			},
			"change_set_id": {
				"type": "string",
				"description": "Replay/recovery identity. Omit on first submit (an id is generated and returned); pass the same id with the same operations to resume, collect a receipt, or get the conflict verdict."
			},
			"dry_run": {
				"type": "boolean",
				"description": "Preview fingerprints and edit counts without writing anything. Default false.",
				"default": false
			}
		},
		"required": ["intent", "operations"]
	}

	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"change_set_id": {"type": "string"},
			"intent": {"type": "string"},
			"dry_run": {"type": "boolean"},
			"outcome": {"type": "string", "description": "planned|committed|resumed_committed|receipt|requires_recovery|conflict|failed|recoverable"},
			"preview": {"type": "array"},
			"files": {"type": "array"},
			"conflicted_paths": {"type": "array"},
			"verification": {"type": "object"},
			"follow_up": {"type": "array", "items": {"type": "string"}}
		}
	}

	var annotations: Dictionary = {
		"readOnlyHint": false,
		"destructiveHint": false,
		"idempotentHint": true,
		"openWorldHint": false
	}

	server_core.register_tool(tool_name, description, input_schema,
		Callable(self, "_tool_apply_change_set"),
		output_schema, annotations,
		"supplementary", "Project-Advanced")

func _tool_apply_change_set(params: Dictionary) -> Dictionary:
	var intent: String = str(params.get("intent", "")).strip_edges()
	if intent.is_empty():
		return {"error": "Missing required parameter: intent"}
	var operations: Variant = params.get("operations", [])
	if not (operations is Array) or (operations as Array).is_empty():
		return {"error": "Missing required parameter: operations (non-empty array)"}
	var dry_run: bool = bool(params.get("dry_run", false))

	# 写入前守卫：目标脚本在编辑器里有未保存修改时，磁盘指纹不可靠。
	if not dry_run:
		var script_editor: Object = null
		if _editor_interface:
			script_editor = _editor_interface.get_script_editor()
		for operation_value in operations:
			var operation: Dictionary = operation_value if operation_value is Dictionary else {}
			var path: String = str(operation.get("path", ""))
			if path.get_extension() != "gd" and path.get_extension() != "cs":
				continue
			var guard: Dictionary = ScriptToolsNative._script_buffer_write_guard(script_editor, path)
			if guard.has("error"):
				return guard

	var executor_request: Dictionary = {
		"intent": intent,
		"operations": operations,
		"change_set_id": str(params.get("change_set_id", "")),
		"dry_run": dry_run,
	}
	if not _journal_path.is_empty():
		executor_request["journal_path"] = _journal_path
	var result: Dictionary = ExecutorScript.apply(executor_request)

	# 写后同步：让打开的脚本编辑器看到外部写入（dry_run/未写文件的
	# outcome 同样安全——sync 只对存在的文件 update_file）。
	if _editor_interface and not dry_run:
		var outcome: String = str(result.get("outcome", ""))
		if outcome == "committed" or outcome == "resumed_committed" \
				or outcome == "requires_recovery":
			for path_value in _written_paths(result):
				EditorToolsNative.sync_script_buffer_after_write(
					_editor_interface, String(path_value))

	var follow_up: Array = []
	match str(result.get("outcome", "")):
		"planned":
			follow_up.append("re-submit with the same change_set_id (%s) and dry_run omitted to execute" % str(result.get("change_set_id", "")))
		"committed", "resumed_committed":
			follow_up.append("verify_scripts on the written .gd/.cs files to confirm the project still compiles")
			follow_up.append('query_change_impact {"target_paths": [...]} to review the transitive surface you just changed')
		"requires_recovery":
			follow_up.append("the journal stays prepared — re-submit the same change_set_id with the same operations to resume; applied files are skipped automatically")
		"receipt":
			follow_up.append("nothing to do — this change set is already committed and the disk still matches")
		"conflict":
			follow_up.append("inspect conflicted_paths (manual edits are preserved); resolve them explicitly, then start a new change_set_id")
	if not follow_up.is_empty():
		result["follow_up"] = follow_up
	return result

static func _written_paths(result: Dictionary) -> Array:
	var paths: Array = []
	for file_value in result.get("files", []):
		var file_entry: Dictionary = file_value if file_value is Dictionary else {}
		var state: String = String(file_entry.get("state", ""))
		if state == "applied":
			paths.append(String(file_entry.get("path", "")))
	return paths
