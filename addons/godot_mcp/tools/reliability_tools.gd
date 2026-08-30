# reliability_tools.gd — 可靠性与工业化能力对外暴露层
#
# 这一层本身不含业务逻辑，它只是把已经建好的工业化组件接成 Agent 可调用的
# MCP 工具：
#
#   MCPToolCoverageTracker   -> 覆盖门禁（L0~L4 + 状态词表 + 禁止跃迁）
#   MCPFixtureManager        -> 测试夹具生命周期（scope / 租约 / 清理 / 孤儿回收）
#   MCPCapabilityGapAnalyzer -> 能力缺口分析（"该不该新增工具"的可审计依据）
#   MCPChaosSuite            -> 混沌注入与自动恢复验证
#   MCPWorkflowCheckpointStore -> 检查点 / 事务 / 回滚
#
# 设计约定：
#   1. 组件都是进程级共享单例（挂在 Engine meta 上）。否则每个工具各自 new 一个
#      实例，覆盖率统计、事务表、夹具登记表就永远为空——这类"看起来跑通了其实
#      什么都没测"的 bug 正是工业化最该防的。
#   2. 没有真实注入手段的混沌场景，一律 SKIPPED + 明确原因，绝不伪装 PASS。
#   3. 任何"不可判定"的结论返回 unknown / unvalidated，绝不返回乐观值。

@tool
class_name ReliabilityTools
extends RefCounted

const COVERAGE_SCRIPT = preload(
	"res://addons/godot_mcp/native_mcp/tool_coverage_tracker.gd")
const FIXTURE_SCRIPT = preload(
	"res://addons/godot_mcp/native_mcp/fixture_manager.gd")
const GAP_SCRIPT = preload(
	"res://addons/godot_mcp/native_mcp/capability_gap_analyzer.gd")
const CHAOS_SCRIPT = preload(
	"res://addons/godot_mcp/native_mcp/chaos_suite.gd")
const CHECKPOINT_SCRIPT = preload(
	"res://addons/godot_mcp/native_mcp/workflow_checkpoint_store.gd")

const META_COVERAGE: String = "GodotMCPCoverageTracker"
const META_FIXTURES: String = "GodotMCPFixtureManager"
const META_GAP: String = "GodotMCPCapabilityGapAnalyzer"
const META_CHAOS: String = "GodotMCPChaosSuite"
const META_CHECKPOINTS: String = "GodotMCPCheckpointStore"

var _editor_interface: EditorInterface = null

func initialize(editor_interface: EditorInterface) -> void:
	_editor_interface = editor_interface
	_wire_undo_provider()

func register_tools(server_core: RefCounted) -> void:
	_register_start_coverage_session(server_core)
	_register_record_tool_coverage(server_core)
	_register_get_tool_coverage(server_core)
	_register_audit_tool_coverage(server_core)
	_register_export_coverage_report(server_core)
	_register_create_fixture_scope(server_core)
	_register_register_fixture_artifact(server_core)
	_register_cleanup_fixture_scope(server_core)
	_register_list_fixture_scopes(server_core)
	_register_record_capability_usage(server_core)
	_register_analyze_capability_gaps(server_core)
	_register_run_chaos_suite(server_core)
	_register_manage_workflow_checkpoint(server_core)
	_register_manage_workflow_transaction(server_core)


# ============================================================================
# 共享组件访问
# ============================================================================

## 进程级共享访问器。用 Variant + 鸭子类型，避开 class_name 静态类型在
## headless 场景下的全局类缓存加载顺序问题（chaos_suite 已验证过这个坑）。
static func _shared(meta_key: String, script: Script) -> Variant:
	if Engine.has_meta(meta_key):
		var existing: Variant = Engine.get_meta(meta_key)
		if existing != null and is_instance_valid(existing):
			return existing
	var instance: Variant = script.new()
	Engine.set_meta(meta_key, instance)
	return instance


static func shared_coverage() -> Variant:
	return _shared(META_COVERAGE, COVERAGE_SCRIPT)

static func shared_fixtures() -> Variant:
	return _shared(META_FIXTURES, FIXTURE_SCRIPT)

static func shared_gap_analyzer() -> Variant:
	return _shared(META_GAP, GAP_SCRIPT)

static func shared_chaos() -> Variant:
	return _shared(META_CHAOS, CHAOS_SCRIPT)

static func shared_checkpoints() -> Variant:
	return _shared(META_CHECKPOINTS, CHECKPOINT_SCRIPT)


## 事务回滚时的场景级撤销。拿不到 EditorUndoRedoManager 就返回 false，
## 由调用方如实标注 scene_undo=false —— 绝不声称撤销成功。
func _wire_undo_provider() -> void:
	var store: Variant = shared_checkpoints()
	if not store.has_method("set_undo_provider"):
		return
	store.set_undo_provider(func() -> bool: return _plugin_undo())


static func _plugin_undo() -> bool:
	if not Engine.has_meta("GodotMCPPlugin"):
		return false
	var plugin: Variant = Engine.get_meta("GodotMCPPlugin")
	if plugin == null or not is_instance_valid(plugin):
		return false
	if not (plugin as Object).has_method("get_undo_redo"):
		return false
	var undo_redo: Variant = (plugin as Object).call("get_undo_redo")
	if undo_redo == null or not is_instance_valid(undo_redo):
		return false
	if not (undo_redo as Object).has_method("undo"):
		return false
	(undo_redo as Object).call("undo")
	return true


# ============================================================================
# start_coverage_session
# ============================================================================

func _register_start_coverage_session(server_core: RefCounted) -> void:
	var tool_name: String = "start_coverage_session"
	var description: String = "Start a tool coverage session. Every tool is initialised as NOT_TESTED with applicability=unknown so that untested and unclassified tools are counted explicitly by the coverage gate instead of silently disappearing."

	var input_schema: Dictionary = {
		"type": "object",
		"properties": {
			"session_name": {
				"type": "string",
				"description": "Optional session label. Defaults to a timestamped name."
			},
			"tool_names": {
				"type": "array",
				"items": {"type": "string"},
				"description": "Subset of tools to track. Omit to track every tool in the manifest."
			},
			"engine_version": {
				"type": "string",
				"description": "Override the recorded engine version (defaults to the running engine)."
			},
			"project_revision": {
				"type": "integer",
				"description": "Optional project revision stamp stored alongside the session."
			}
		}
	}

	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"session_name": {"type": "string"},
			"engine_version": {"type": "string"},
			"project_revision": {"type": "integer"},
			"started_at": {"type": "string"},
			"tools": {"type": "integer"}
		}
	}

	var annotations: Dictionary = {
		"readOnlyHint": false,
		"destructiveHint": false,
		"idempotentHint": false,
		"openWorldHint": false
	}

	server_core.register_tool(tool_name, description, input_schema,
		Callable(self, "_tool_start_coverage_session"), output_schema, annotations,
		"supplementary", "Reliability")


func _tool_start_coverage_session(params: Dictionary) -> Dictionary:
	var tracker: Variant = shared_coverage()
	var names: Array = []
	var raw_names: Variant = params.get("tool_names", [])
	if raw_names is Array:
		for name_value in (raw_names as Array):
			names.append(String(name_value).strip_edges())
	var result: Dictionary = tracker.start_session(
		String(params.get("session_name", "")).strip_edges(),
		names,
		String(params.get("engine_version", "")).strip_edges(),
		int(params.get("project_revision", 0)))
	if result.has("error"):
		return result
	result["note"] = "records start at L0/NOT_TESTED; use record_tool_coverage to advance them"
	return result


# ============================================================================
# record_tool_coverage
# ============================================================================

const COVERAGE_PASSTHROUGH_KEYS: Array[String] = [
	"tool_name", "group", "profile", "domain",
	"applicability", "applicability_reason",
	"positive_test", "negative_test", "repair_test",
	"execution_status", "verification_status",
	"side_effect_proven", "cleanup_proven",
	"evidence_refs", "dependencies", "generated_artifacts"
]

func _register_record_tool_coverage(server_core: RefCounted) -> void:
	var tool_name: String = "record_tool_coverage"
	var description: String = "Record coverage evidence for one or more tools. Illegal status transitions (for example BLOCKED -> PASS) are rejected and reported, so a single run cannot silently claim success. Status vocabulary: PASS/FAIL/BLOCKED/UNSUPPORTED/UNCONFIGURED/NOT_TESTED/NOT_APPLICABLE/STALE."

	var input_schema: Dictionary = {
		"type": "object",
		"properties": {
			"entries": {
				"type": "array",
				"description": "One or more coverage records. Each entry needs tool_name plus the status fields you can actually justify.",
				"items": {
					"type": "object",
					"properties": {
						"tool_name": {"type": "string"},
						"applicability": {
							"type": "string",
							"enum": ["yes", "no", "unknown"],
							"description": "Whether this tool is applicable to the target project. Must be resolved, never left unknown."
						},
						"applicability_reason": {"type": "string"},
						"positive_test": {"type": "string"},
						"negative_test": {"type": "string"},
						"repair_test": {"type": "string"},
						"execution_status": {
							"type": "string",
							"enum": ["invoked", "not_invoked"],
							"description": "Whether the tool actually executed. 'invoked' alone is never enough to claim PASS."
						},
						"verification_status": {"type": "string"},
						"side_effect_proven": {"type": "boolean"},
						"cleanup_proven": {"type": "boolean"},
						"evidence_refs": {"type": "array", "items": {"type": "string"}},
						"dependencies": {"type": "array", "items": {"type": "string"}},
						"generated_artifacts": {"type": "array", "items": {"type": "string"}},
						"group": {"type": "string"},
						"domain": {"type": "string"}
					},
					"required": ["tool_name"],
					"additionalProperties": true
				}
			},
			"entry": {
				"type": "object",
				"description": "Convenience single-record form. Ignored when entries is provided.",
				"additionalProperties": true
			}
		}
	}

	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"accepted": {"type": "integer"},
			"rejected": {"type": "integer"},
			"errors": {"type": "array"},
			"warnings": {"type": "array"},
			"records": {"type": "array"}
		}
	}

	var annotations: Dictionary = {
		"readOnlyHint": false,
		"destructiveHint": false,
		"idempotentHint": false,
		"openWorldHint": false
	}

	server_core.register_tool(tool_name, description, input_schema,
		Callable(self, "_tool_record_tool_coverage"), output_schema, annotations,
		"supplementary", "Reliability")


func _tool_record_tool_coverage(params: Dictionary) -> Dictionary:
	var tracker: Variant = shared_coverage()
	var raw_entries: Variant = params.get("entries", null)
	if not (raw_entries is Array):
		var single: Variant = params.get("entry", null)
		if single is Dictionary:
			raw_entries = [single]
		elif params.has("tool_name"):
			raw_entries = [params]
	if not (raw_entries is Array) or (raw_entries as Array).is_empty():
		return {"error": "entries (or entry / inline tool_name fields) is required"}

	var accepted: int = 0
	var rejected: int = 0
	var errors: Array[String] = []
	var warnings: Array[String] = []
	var records: Array[Dictionary] = []

	for entry_value in (raw_entries as Array):
		if not (entry_value is Dictionary):
			rejected += 1
			errors.append("each entry must be an object")
			continue
		var source: Dictionary = entry_value as Dictionary
		var fields: Dictionary = {}
		for key in COVERAGE_PASSTHROUGH_KEYS:
			if source.has(key):
				fields[key] = source[key]
		var result: Dictionary = tracker.record(fields)
		if bool(result.get("accepted", false)):
			accepted += 1
			records.append(result.get("record", {}))
		else:
			rejected += 1
			errors.append_array(_string_array(result.get("errors", [])))
		warnings.append_array(_string_array(result.get("warnings", [])))

	return {
		"accepted": accepted,
		"rejected": rejected,
		"errors": errors,
		"warnings": warnings,
		"records": records
	}


# ============================================================================
# get_tool_coverage
# ============================================================================

func _register_get_tool_coverage(server_core: RefCounted) -> void:
	var tool_name: String = "get_tool_coverage"
	var description: String = "Read the coverage record of one tool, or list the current session's records filtered by level/status. Returns an empty record when the tool has no session data."

	var input_schema: Dictionary = {
		"type": "object",
		"properties": {
			"tool_name": {
				"type": "string",
				"description": "Tool to look up. Omit to list records by filter."
			},
			"min_level": {
				"type": "string",
				"enum": ["L0", "L1", "L2", "L3", "L4"],
				"description": "When listing, keep only records at or above this coverage level."
			},
			"status": {
				"type": "string",
				"description": "When listing, keep only records whose positive_test equals this status."
			},
			"limit": {"type": "integer", "default": 200}
		}
	}

	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"session_name": {"type": "string"},
			"record": {"type": "object"},
			"records": {"type": "array"},
			"count": {"type": "integer"},
			"truncated": {"type": "boolean"}
		}
	}

	var annotations: Dictionary = {
		"readOnlyHint": true,
		"destructiveHint": false,
		"idempotentHint": true,
		"openWorldHint": false
	}

	server_core.register_tool(tool_name, description, input_schema,
		Callable(self, "_tool_get_tool_coverage"), output_schema, annotations,
		"supplementary", "Reliability")


func _tool_get_tool_coverage(params: Dictionary) -> Dictionary:
	var tracker: Variant = shared_coverage()
	var tool_name: String = String(params.get("tool_name", "")).strip_edges()
	if not tool_name.is_empty():
		var record: Dictionary = tracker.get_record(tool_name)
		return {
			"session_name": tracker.session_name(),
			"record": record,
			"found": not record.is_empty()
		}

	var min_level: String = String(params.get("min_level", "")).strip_edges().to_upper()
	var status_filter: String = String(params.get("status", "")).strip_edges()
	var limit: int = int(params.get("limit", 200))
	var levels: Array[String] = ["L0", "L1", "L2", "L3", "L4"]
	var min_index: int = -1
	if not min_level.is_empty():
		min_index = levels.find(min_level)

	var records: Array[Dictionary] = []
	var total: int = 0
	for name_value in tracker.tool_names():
		var entry_name: String = String(name_value)
		var entry: Dictionary = tracker.get_record(entry_name)
		if entry.is_empty():
			continue
		total += 1
		if min_index >= 0:
			var level_name: String = String(entry.get("coverage_level", "L0"))
			if levels.find(level_name) < min_index:
				continue
		if not status_filter.is_empty() \
				and String(entry.get("positive_test", "")) != status_filter:
			continue
		if records.size() >= maxi(1, limit):
			continue
		records.append(entry)

	return {
		"session_name": tracker.session_name(),
		"records": records,
		"count": records.size(),
		"matched_before_limit": total,
		"truncated": total > records.size()
	}


# ============================================================================
# audit_tool_coverage
# ============================================================================

func _register_audit_tool_coverage(server_core: RefCounted) -> void:
	var tool_name: String = "audit_tool_coverage"
	var description: String = "Run the coverage gate. Requires: every applicable tool has a record and reaches L3, every fault-sensitive tool reaches L4, every non-applicable tool has an explicit reason, and zero tools remain unclassified or of unknown applicability."

	var input_schema: Dictionary = {
		"type": "object",
		"properties": {
			"fail_fast": {
				"type": "boolean",
				"description": "Stop at the first failing gate instead of collecting every violation. Default false so the report is actionable.",
				"default": false
			}
		}
	}

	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"passed": {"type": "boolean"},
			"gates": {"type": "array"},
			"counts": {"type": "object"},
			"violations": {"type": "object"}
		}
	}

	var annotations: Dictionary = {
		"readOnlyHint": true,
		"destructiveHint": false,
		"idempotentHint": true,
		"openWorldHint": false
	}

	server_core.register_tool(tool_name, description, input_schema,
		Callable(self, "_tool_audit_tool_coverage"), output_schema, annotations,
		"supplementary", "Reliability")


func _tool_audit_tool_coverage(params: Dictionary) -> Dictionary:
	var tracker: Variant = shared_coverage()
	var audit: Dictionary = tracker.audit()
	if not bool(params.get("fail_fast", false)):
		return audit
	# fail_fast：只保留第一个失败的 gate，供快速判断"能不能发版"
	var gates: Array = audit.get("gates", [])
	var first_failure: Array = []
	for gate_value in gates:
		var gate: Dictionary = gate_value
		first_failure.append(gate)
		if not bool(gate.get("passed", false)):
			break
	audit["gates"] = first_failure
	return audit


# ============================================================================
# export_coverage_report
# ============================================================================

func _register_export_coverage_report(server_core: RefCounted) -> void:
	var tool_name: String = "export_coverage_report"
	var description: String = "Export the coverage matrix (grouped by group and domain) and optionally persist it under res://.mcp/coverage for release auditing."

	var input_schema: Dictionary = {
		"type": "object",
		"properties": {
			"save_path": {
				"type": "string",
				"description": "Optional target path. Defaults to res://.mcp/coverage/<session>.json."
			},
			"include_records": {"type": "boolean", "default": true},
			"max_entries": {
				"type": "integer",
				"default": 400,
				"description": "Cap on inline records. The response reports 'truncated' when more exist."
			}
		}
	}

	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"session_name": {"type": "string"},
			"engine_version": {"type": "string"},
			"generated_at": {"type": "string"},
			"gate": {"type": "object"},
			"by_group": {"type": "object"},
			"by_domain": {"type": "object"},
			"record_count": {"type": "integer"},
			"truncated": {"type": "boolean"},
			"saved": {"type": "boolean"},
			"path": {"type": "string"}
		}
	}

	var annotations: Dictionary = {
		"readOnlyHint": false,
		"destructiveHint": false,
		"idempotentHint": true,
		"openWorldHint": false
	}

	server_core.register_tool(tool_name, description, input_schema,
		Callable(self, "_tool_export_coverage_report"), output_schema, annotations,
		"supplementary", "Reliability")


func _tool_export_coverage_report(params: Dictionary) -> Dictionary:
	var tracker: Variant = shared_coverage()
	var include_records: bool = bool(params.get("include_records", true))
	var max_entries: int = int(params.get("max_entries", 400))
	var report: Dictionary = tracker.export_report(include_records, max_entries)
	var save_path: String = String(params.get("save_path", "")).strip_edges()
	if save_path.is_empty():
		report["saved"] = false
		report["path"] = ""
		return report
	var saved: Dictionary = tracker.save(save_path)
	report["saved"] = bool(saved.get("saved", false))
	report["path"] = String(saved.get("path", save_path))
	if saved.has("error"):
		report["save_error"] = String(saved["error"])
	return report


# ============================================================================
# create_fixture_scope
# ============================================================================

func _register_create_fixture_scope(server_core: RefCounted) -> void:
	var tool_name: String = "create_fixture_scope"
	var description: String = "Create a leased fixture scope under res://.mcp/fixtures for temporary test artifacts. Every scope carries a lease so abandoned fixtures can be detected and reclaimed instead of leaking into the project."

	var input_schema: Dictionary = {
		"type": "object",
		"properties": {
			"name": {"type": "string", "description": "Human-readable scope name."},
			"lease_ms": {
				"type": "integer",
				"description": "Lease duration in milliseconds. Default 24 hours. Use 0 for a non-expiring scope."
			},
			"tags": {"type": "array", "items": {"type": "string"}},
			"description": {"type": "string"},
			"root": {
				"type": "string",
				"description": "Optional explicit root. Must stay under res://.mcp/fixtures."
			}
		}
	}

	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"fixture_id": {"type": "string"},
			"root": {"type": "string"},
			"name": {"type": "string"},
			"reused": {"type": "boolean"},
			"lease_ms": {"type": "integer"},
			"created_at": {"type": "string"}
		}
	}

	var annotations: Dictionary = {
		"readOnlyHint": false,
		"destructiveHint": false,
		"idempotentHint": true,
		"openWorldHint": false
	}

	server_core.register_tool(tool_name, description, input_schema,
		Callable(self, "_tool_create_fixture_scope"), output_schema, annotations,
		"supplementary", "Reliability")


func _tool_create_fixture_scope(params: Dictionary) -> Dictionary:
	var manager: Variant = shared_fixtures()
	var options: Dictionary = {}
	if params.has("lease_ms"):
		options["lease_ms"] = int(params["lease_ms"])
	if params.has("tags"):
		options["tags"] = params["tags"]
	if params.has("description"):
		options["description"] = String(params["description"])
	if params.has("root"):
		options["root"] = String(params["root"])
	var result: Dictionary = manager.create_scope(
		String(params.get("name", "")).strip_edges(), options)
	if result.has("error"):
		return result
	result["note"] = "call cleanup_fixture_scope when done; otherwise it is reclaimed after the lease"
	return result


# ============================================================================
# register_fixture_artifact
# ============================================================================

func _register_register_fixture_artifact(server_core: RefCounted) -> void:
	var tool_name: String = "register_fixture_artifact"
	var description: String = "Register a file path or scene node path as owned by a fixture scope, so cleanup removes it even when the creating step crashed before reporting anything."

	var input_schema: Dictionary = {
		"type": "object",
		"properties": {
			"fixture_id": {"type": "string", "description": "Scope root returned by create_fixture_scope."},
			"path": {"type": "string", "description": "File path created inside the scope."},
			"paths": {"type": "array", "items": {"type": "string"}},
			"node_path": {"type": "string", "description": "Scene node path that cleanup should flag for revert."},
			"node_paths": {"type": "array", "items": {"type": "string"}}
		},
		"required": ["fixture_id"]
	}

	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"fixture_id": {"type": "string"},
			"registered_paths": {"type": "array"},
			"registered_nodes": {"type": "array"},
			"errors": {"type": "array"},
			"tracked": {"type": "integer"}
		}
	}

	var annotations: Dictionary = {
		"readOnlyHint": false,
		"destructiveHint": false,
		"idempotentHint": true,
		"openWorldHint": false
	}

	server_core.register_tool(tool_name, description, input_schema,
		Callable(self, "_tool_register_fixture_artifact"), output_schema, annotations,
		"supplementary", "Reliability")


func _tool_register_fixture_artifact(params: Dictionary) -> Dictionary:
	var manager: Variant = shared_fixtures()
	var fixture_id: String = String(params.get("fixture_id", "")).strip_edges()
	if fixture_id.is_empty():
		return {"error": "fixture_id is required"}

	var paths: Array[String] = []
	var single_path: String = String(params.get("path", "")).strip_edges()
	if not single_path.is_empty():
		paths.append(single_path)
	for value in _array_param(params, "paths"):
		var cleaned: String = String(value).strip_edges()
		if not cleaned.is_empty():
			paths.append(cleaned)

	var node_paths: Array[String] = []
	var single_node: String = String(params.get("node_path", "")).strip_edges()
	if not single_node.is_empty():
		node_paths.append(single_node)
	for value in _array_param(params, "node_paths"):
		var node_value: String = String(value).strip_edges()
		if not node_value.is_empty():
			node_paths.append(node_value)

	if paths.is_empty() and node_paths.is_empty():
		return {"error": "provide path/paths or node_path/node_paths"}

	var registered_paths: Array[String] = []
	var registered_nodes: Array[String] = []
	var errors: Array[String] = []
	for path in paths:
		var result: Dictionary = manager.register_path(fixture_id, path)
		if result.has("error"):
			errors.append(String(result["error"]))
		else:
			registered_paths.append(String(result.get("path", path)))
	for node_path in node_paths:
		var node_result: Dictionary = manager.register_node(fixture_id, node_path)
		if node_result.has("error"):
			errors.append(String(node_result["error"]))
		else:
			registered_nodes.append(String(node_result.get("node_path", node_path)))

	var scope: Dictionary = manager.get_scope(fixture_id)
	var tracked: int = (scope.get("paths", []) as Array).size()
	return {
		"fixture_id": fixture_id,
		"registered_paths": registered_paths,
		"registered_nodes": registered_nodes,
		"errors": errors,
		"tracked": tracked
	}


# ============================================================================
# cleanup_fixture_scope
# ============================================================================

func _register_cleanup_fixture_scope(server_core: RefCounted) -> void:
	var tool_name: String = "cleanup_fixture_scope"
	var description: String = "Clean up fixture scopes: one scope by id, all scopes, every expired scope, or orphaned directories left behind by a crashed process. Reports what was actually removed and what failed, instead of claiming success."

	var input_schema: Dictionary = {
		"type": "object",
		"properties": {
			"fixture_id": {"type": "string", "description": "Scope to clean. Omit together with mode=all/expired/orphans."},
			"mode": {
				"type": "string",
				"enum": ["scope", "all", "expired", "orphans"],
				"default": "scope",
				"description": "scope: clean one id. all: every known scope. expired: only scopes past their lease. orphans: directories under res://.mcp/fixtures with no live scope."
			}
		}
	}

	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"mode": {"type": "string"},
			"cleaned": {"type": "array"},
			"removed_files": {"type": "integer"},
			"removed_dirs": {"type": "integer"},
			"failed": {"type": "array"},
			"nodes_to_revert": {"type": "array"}
		}
	}

	var annotations: Dictionary = {
		"readOnlyHint": false,
		"destructiveHint": true,
		"idempotentHint": true,
		"openWorldHint": false
	}

	server_core.register_tool(tool_name, description, input_schema,
		Callable(self, "_tool_cleanup_fixture_scope"), output_schema, annotations,
		"supplementary", "Reliability")


func _tool_cleanup_fixture_scope(params: Dictionary) -> Dictionary:
	var manager: Variant = shared_fixtures()
	var mode: String = String(params.get("mode", "scope")).strip_edges().to_lower()
	if mode.is_empty():
		mode = "scope"
	if mode == "all":
		return _merge_mode(manager.cleanup_all(), "all")
	if mode == "expired":
		return _merge_mode(manager.cleanup_expired(), "expired")
	if mode == "orphans":
		return _merge_mode(manager.cleanup_orphans(), "orphans")
	if mode != "scope":
		return {"error": "unknown mode '" + mode + "'"}

	var fixture_id: String = String(params.get("fixture_id", "")).strip_edges()
	if fixture_id.is_empty():
		return {"error": "fixture_id is required for mode=scope"}
	var result: Dictionary = manager.cleanup(fixture_id)
	if result.has("error"):
		return result
	result["mode"] = "scope"
	return result


static func _merge_mode(result: Dictionary, mode: String) -> Dictionary:
	result["mode"] = mode
	return result


# ============================================================================
# list_fixture_scopes
# ============================================================================

func _register_list_fixture_scopes(server_core: RefCounted) -> void:
	var tool_name: String = "list_fixture_scopes"
	var description: String = "List live fixture scopes with their lease state, plus orphaned directories under res://.mcp/fixtures that no live scope owns."

	var input_schema: Dictionary = {
		"type": "object",
		"properties": {
			"include_orphans": {"type": "boolean", "default": true},
			"include_stats": {"type": "boolean", "default": true}
		}
	}

	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"scopes": {"type": "array"},
			"scope_count": {"type": "integer"},
			"orphans": {"type": "array"},
			"orphan_count": {"type": "integer"},
			"stats": {"type": "object"}
		}
	}

	var annotations: Dictionary = {
		"readOnlyHint": true,
		"destructiveHint": false,
		"idempotentHint": true,
		"openWorldHint": false
	}

	server_core.register_tool(tool_name, description, input_schema,
		Callable(self, "_tool_list_fixture_scopes"), output_schema, annotations,
		"supplementary", "Reliability")


func _tool_list_fixture_scopes(params: Dictionary) -> Dictionary:
	var manager: Variant = shared_fixtures()
	var scopes: Array = manager.list_scopes()
	var out: Dictionary = {
		"scopes": scopes,
		"scope_count": scopes.size(),
		"orphans": [],
		"orphan_count": 0,
		"stats": {}
	}
	if bool(params.get("include_orphans", true)):
		var orphans: Array = manager.find_orphans()
		out["orphans"] = orphans
		out["orphan_count"] = orphans.size()
	if bool(params.get("include_stats", true)):
		out["stats"] = manager.stats()
	return out


# ============================================================================
# record_capability_usage
# ============================================================================

func _register_record_capability_usage(server_core: RefCounted) -> void:
	var tool_name: String = "record_capability_usage"
	var description: String = "Record how an objective was actually satisfied: the tool chain used, whether a fallback was needed, whether it succeeded, replan count, token cost and duration. This is the evidence behind any decision to add a new tool."

	var input_schema: Dictionary = {
		"type": "object",
		"properties": {
			"entries": {
				"type": "array",
				"items": {
					"type": "object",
					"properties": {
						"capability": {
							"type": "string",
							"description": "What the agent was trying to achieve, e.g. 'set tilemap cell'."
						},
						"goal": {"type": "string"},
						"tool_chain": {"type": "array", "items": {"type": "string"}},
						"used_fallback": {"type": "boolean"},
						"fallback_kind": {
							"type": "string",
							"enum": ["editor_script", "generated_code", "composition", "manual"]
						},
						"success": {"type": "boolean"},
						"replan_count": {"type": "integer"},
						"token_cost": {"type": "integer"},
						"duration_ms": {"type": "integer"},
						"blocked_reason": {"type": "string"}
					},
					"required": ["capability"],
					"additionalProperties": true
				}
			},
			"entry": {
				"type": "object",
				"description": "Convenience single-record form. Ignored when entries is provided.",
				"additionalProperties": true
			}
		}
	}

	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"accepted": {"type": "integer"},
			"total": {"type": "integer"},
			"usage_count": {"type": "integer"}
		}
	}

	var annotations: Dictionary = {
		"readOnlyHint": false,
		"destructiveHint": false,
		"idempotentHint": false,
		"openWorldHint": false
	}

	server_core.register_tool(tool_name, description, input_schema,
		Callable(self, "_tool_record_capability_usage"), output_schema, annotations,
		"supplementary", "Reliability")


func _tool_record_capability_usage(params: Dictionary) -> Dictionary:
	var analyzer: Variant = shared_gap_analyzer()
	var raw_entries: Variant = params.get("entries", null)
	if not (raw_entries is Array):
		var single: Variant = params.get("entry", null)
		if single is Dictionary:
			raw_entries = [single]
		elif params.has("capability"):
			raw_entries = [params]
	if not (raw_entries is Array) or (raw_entries as Array).is_empty():
		return {"error": "entries (or entry / inline capability fields) is required"}
	var result: Dictionary = analyzer.record_many(raw_entries as Array)
	result["usage_count"] = analyzer.usage_count()
	return result


# ============================================================================
# analyze_capability_gaps
# ============================================================================

func _register_analyze_capability_gaps(server_core: RefCounted) -> void:
	var tool_name: String = "analyze_capability_gaps"
	var description: String = "Analyse recorded capability usage and rank the objectives that keep needing fallbacks, long tool chains or replans. A capability only becomes a 'promote to new tool' recommendation once it clears the frequency and score thresholds, so a single awkward call never justifies a new tool."

	var input_schema: Dictionary = {
		"type": "object",
		"properties": {
			"min_frequency": {
				"type": "integer",
				"default": 3,
				"description": "Minimum number of samples before a capability is analysed at all."
			},
			"capability": {
				"type": "string",
				"description": "Optional single capability to inspect in depth."
			},
			"save_path": {
				"type": "string",
				"description": "Optional path to persist the report under res://.mcp/capability_gaps."
			}
		}
	}

	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"threshold": {"type": "integer"},
			"capabilities": {"type": "array"},
			"promote_candidates": {"type": "array"},
			"samples": {"type": "integer"},
			"detail": {"type": "object"},
			"saved": {"type": "boolean"},
			"path": {"type": "string"}
		}
	}

	var annotations: Dictionary = {
		"readOnlyHint": true,
		"destructiveHint": false,
		"idempotentHint": true,
		"openWorldHint": false
	}

	server_core.register_tool(tool_name, description, input_schema,
		Callable(self, "_tool_analyze_capability_gaps"), output_schema, annotations,
		"supplementary", "Reliability")


func _tool_analyze_capability_gaps(params: Dictionary) -> Dictionary:
	var analyzer: Variant = shared_gap_analyzer()
	var min_frequency: int = int(params.get("min_frequency", 3))
	var capability: String = String(params.get("capability", "")).strip_edges()
	if not capability.is_empty():
		return {
			"detail": analyzer.analyze_capability(capability),
			"closest_tools": GAP_SCRIPT.closest_tools(capability),
			"samples": analyzer.usage_count()
		}

	var report: Dictionary = analyzer.analyze(min_frequency)
	report["threshold"] = GAP_SCRIPT.PROMOTE_SCORE_THRESHOLD
	var save_path: String = String(params.get("save_path", "")).strip_edges()
	if not save_path.is_empty():
		var saved: Dictionary = analyzer.save(save_path)
		report["saved"] = bool(saved.get("saved", false))
		report["path"] = String(saved.get("path", save_path))
		if saved.has("error"):
			report["save_error"] = String(saved["error"])
	else:
		report["saved"] = false
		report["path"] = ""
	return report


# ============================================================================
# run_chaos_suite
# ============================================================================

func _register_run_chaos_suite(server_core: RefCounted) -> void:
	var tool_name: String = "run_chaos_suite"
	var description: String = "Inject faults and assert automatic recovery: stale cache, invalid receipt, missing runtime, deleted file, timeout, plus environment-level scenarios. A scenario only reports PASS when the fault was actually injected AND recovery was proven. Environment-level scenarios without an injected fault report SKIPPED with an explicit reason instead of a fake PASS."

	var input_schema: Dictionary = {
		"type": "object",
		"properties": {
			"scenarios": {
				"type": "array",
				"items": {"type": "string"},
				"description": "Scenario names to run. Omit to run every built-in scenario.",
				"enum": ["drop_connection", "timeout", "stale_cache", "invalid_receipt",
					"missing_runtime", "editor_reload", "deleted_file", "changed_uid"]
			},
			"use_shared_components": {
				"type": "boolean",
				"default": true,
				"description": "Run against the live shared reliability components instead of throwaway instances."
			},
			"reset_stats": {"type": "boolean", "default": false}
		}
	}

	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"scenarios": {"type": "array"},
			"summary": {"type": "object"},
			"adapters": {"type": "array"},
			"stats": {"type": "object"}
		}
	}

	var annotations: Dictionary = {
		"readOnlyHint": false,
		"destructiveHint": true,
		"idempotentHint": false,
		"openWorldHint": false
	}

	server_core.register_tool(tool_name, description, input_schema,
		Callable(self, "_tool_run_chaos_suite"), output_schema, annotations,
		"supplementary", "Reliability")


func _tool_run_chaos_suite(params: Dictionary) -> Dictionary:
	var suite: Variant = shared_chaos()
	if bool(params.get("reset_stats", false)):
		suite.reset_diagnostics()

	var scenario_names: Array = []
	var raw_names: Variant = params.get("scenarios", [])
	if raw_names is Array:
		for name_value in (raw_names as Array):
			scenario_names.append(String(name_value).strip_edges())

	var context: Dictionary = {}
	if bool(params.get("use_shared_components", true)):
		context = {
			"receipt_cache": _shared_receipt_cache(),
			"mutation_bus": _shared_mutation_bus(),
			"coverage": shared_coverage(),
			"checkpoints": shared_checkpoints(),
			"runtime": EditorToolsNativeScript.runtime_session_snapshot_holder()
		}

	var result: Dictionary = suite.run(scenario_names, context)
	result["stats"] = suite.stats()
	result["note"] = "SKIPPED means the fault was not actually injected; it is never counted as a pass"
	return result


const EditorToolsNativeScript = preload(
	"res://addons/godot_mcp/tools/editor_tools_native.gd")


## 收据缓存与文件总线的共享实例。它们挂在 workflow engine 上（如果已装配），
## 退化为进程级 meta，保证混沌场景打在真实组件上而不是新建的沙箱。
static func _shared_receipt_cache() -> Variant:
	if Engine.has_meta("GodotMCPReceiptCache"):
		var existing: Variant = Engine.get_meta("GodotMCPReceiptCache")
		if existing != null and is_instance_valid(existing):
			return existing
	return null


static func _shared_mutation_bus() -> Variant:
	if Engine.has_meta("GodotMCPFileMutationBus"):
		var existing: Variant = Engine.get_meta("GodotMCPFileMutationBus")
		if existing != null and is_instance_valid(existing):
			return existing
	return null


# ============================================================================
# manage_workflow_checkpoint
# ============================================================================

func _register_manage_workflow_checkpoint(server_core: RefCounted) -> void:
	var tool_name: String = "manage_workflow_checkpoint"
	var description: String = "Create, list, read, prune or clear durable workflow checkpoints under res://.mcp/checkpoints. A checkpoint snapshots tasks, receipts, artifacts and workflow state so a run can resume after a crash instead of restarting from scratch."

	var input_schema: Dictionary = {
		"type": "object",
		"properties": {
			"operation": {
				"type": "string",
				"enum": ["create", "list", "read", "latest", "prune", "clear"],
				"default": "list"
			},
			"workflow_id": {"type": "string", "description": "Workflow identifier."},
			"label": {"type": "string", "description": "Human-readable checkpoint label (create)."},
			"plan": {
				"type": "object",
				"description": "Workflow plan snapshot (create). Include 'tasks' and 'workflow' to make the checkpoint resumable.",
				"additionalProperties": true
			},
			"extra": {
				"type": "object",
				"description": "Additional sidecar state to store with the checkpoint (create).",
				"additionalProperties": true
			},
			"checkpoint_id": {"type": "string", "description": "Checkpoint id (read)."},
			"keep_last": {"type": "integer", "default": 10, "description": "Checkpoints to keep (prune)."}
		},
		"required": ["workflow_id"]
	}

	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"operation": {"type": "string"},
			"workflow_id": {"type": "string"},
			"checkpoint_id": {"type": "string"},
			"checkpoints": {"type": "array"},
			"checkpoint": {"type": "object"},
			"removed": {"type": "array"},
			"kept": {"type": "integer"},
			"stats": {"type": "object"}
		}
	}

	var annotations: Dictionary = {
		"readOnlyHint": false,
		"destructiveHint": true,
		"idempotentHint": false,
		"openWorldHint": false
	}

	server_core.register_tool(tool_name, description, input_schema,
		Callable(self, "_tool_manage_workflow_checkpoint"), output_schema, annotations,
		"supplementary", "Reliability")


func _tool_manage_workflow_checkpoint(params: Dictionary) -> Dictionary:
	var store: Variant = shared_checkpoints()
	var workflow_id: String = String(params.get("workflow_id", "")).strip_edges()
	if workflow_id.is_empty():
		return {"error": "workflow_id is required"}
	var operation: String = String(params.get("operation", "list")).strip_edges().to_lower()
	if operation.is_empty():
		operation = "list"

	match operation:
		"create":
			var plan: Dictionary = params.get("plan", {}) if params.get("plan", {}) is Dictionary else {}
			var extra: Dictionary = params.get("extra", {}) if params.get("extra", {}) is Dictionary else {}
			var result: Dictionary = store.create_checkpoint(
				workflow_id, String(params.get("label", "")), plan, extra)
			if result.has("error"):
				return result
			result["operation"] = "create"
			if plan.is_empty():
				result["warning"] = "plan was empty; the checkpoint stores only a task-less snapshot"
			return result
		"list":
			return {
				"operation": "list",
				"workflow_id": workflow_id,
				"checkpoints": store.list_checkpoints(workflow_id),
				"stats": store.stats()
			}
		"latest":
			return {
				"operation": "latest",
				"workflow_id": workflow_id,
				"checkpoint": store.latest_checkpoint(workflow_id)
			}
		"read":
			var checkpoint_id: String = String(params.get("checkpoint_id", "")).strip_edges()
			if checkpoint_id.is_empty():
				return {"error": "checkpoint_id is required for read"}
			var parsed: Variant = store.read_checkpoint(workflow_id, checkpoint_id)
			if parsed is Dictionary and (parsed as Dictionary).has("error"):
				return parsed
			return {
				"operation": "read",
				"workflow_id": workflow_id,
				"checkpoint": parsed
			}
		"prune":
			var pruned: Dictionary = store.prune(workflow_id, int(params.get("keep_last", 10)))
			pruned["operation"] = "prune"
			pruned["workflow_id"] = workflow_id
			return pruned
		"clear":
			var cleared: int = store.clear_workflow(workflow_id)
			return {
				"operation": "clear",
				"workflow_id": workflow_id,
				"removed_checkpoints": cleared
			}
	return {"error": "unknown operation '" + operation + "'"}


# ============================================================================
# manage_workflow_transaction
# ============================================================================

func _register_manage_workflow_transaction(server_core: RefCounted) -> void:
	var tool_name: String = "manage_workflow_transaction"
	var description: String = "Open, commit or roll back a durable workflow transaction. begin() first writes a checkpoint, so a rollback restores the plan from that checkpoint and additionally attempts a scene-level undo. The response states honestly whether the scene undo was available."

	var input_schema: Dictionary = {
		"type": "object",
		"properties": {
			"operation": {
				"type": "string",
				"enum": ["begin", "commit", "rollback", "active", "stats"],
				"default": "active"
			},
			"workflow_id": {"type": "string"},
			"label": {"type": "string", "description": "Checkpoint label used by begin()."},
			"plan": {
				"type": "object",
				"description": "Workflow plan to snapshot (begin) or restore into (rollback).",
				"additionalProperties": true
			},
			"extra": {
				"type": "object",
				"description": "Sidecar state stored with the begin checkpoint.",
				"additionalProperties": true
			}
		},
		"required": ["workflow_id"]
	}

	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"operation": {"type": "string"},
			"workflow_id": {"type": "string"},
			"open": {"type": "boolean"},
			"committed": {"type": "boolean"},
			"rolled_back": {"type": "boolean"},
			"scene_undo": {"type": "boolean"},
			"checkpoint_id": {"type": "string"},
			"note": {"type": "string"},
			"active": {"type": "array"},
			"stats": {"type": "object"}
		}
	}

	var annotations: Dictionary = {
		"readOnlyHint": false,
		"destructiveHint": true,
		"idempotentHint": false,
		"openWorldHint": false
	}

	server_core.register_tool(tool_name, description, input_schema,
		Callable(self, "_tool_manage_workflow_transaction"), output_schema, annotations,
		"supplementary", "Reliability")


func _tool_manage_workflow_transaction(params: Dictionary) -> Dictionary:
	var store: Variant = shared_checkpoints()
	var workflow_id: String = String(params.get("workflow_id", "")).strip_edges()
	if workflow_id.is_empty():
		return {"error": "workflow_id is required"}
	var operation: String = String(params.get("operation", "active")).strip_edges().to_lower()
	if operation.is_empty():
		operation = "active"
	var plan: Dictionary = params.get("plan", {}) if params.get("plan", {}) is Dictionary else {}
	var extra: Dictionary = params.get("extra", {}) if params.get("extra", {}) is Dictionary else {}

	match operation:
		"begin":
			var result: Dictionary = store.begin_transaction(
				workflow_id, plan, String(params.get("label", "")), extra)
			if result.has("error"):
				return result
			result["operation"] = "begin"
			if plan.is_empty():
				result["warning"] = "plan was empty; rollback can only restore an empty plan"
			return result
		"commit":
			var committed: Dictionary = store.commit_transaction(workflow_id)
			if committed.has("error"):
				return committed
			committed["operation"] = "commit"
			return committed
		"rollback":
			var rolled: Dictionary = store.rollback_transaction(workflow_id, plan)
			if rolled.has("error"):
				return rolled
			rolled["operation"] = "rollback"
			if plan.is_empty():
				rolled["warning"] = "plan was empty; only the stored checkpoint was reported back"
			return rolled
		"active":
			return {
				"operation": "active",
				"active": store.active_transactions(),
				"stats": store.stats()
			}
		"stats":
			return {"operation": "stats", "stats": store.stats()}
	return {"error": "unknown operation '" + operation + "'"}


# ============================================================================
# 辅助
# ============================================================================

static func _array_param(params: Dictionary, key: String) -> Array:
	var value: Variant = params.get(key, [])
	return value if value is Array else []


static func _string_array(value: Variant) -> Array[String]:
	var result: Array[String] = []
	if value is Array:
		for item in (value as Array):
			result.append(String(item))
	return result
