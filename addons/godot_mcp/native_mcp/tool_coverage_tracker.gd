# tool_coverage_tracker.gd — 工具覆盖矩阵追踪器
#
# 背景：过去"覆盖"的判定标准是"这个工具调用过"。这只能证明工具存在（L0），
# 完全不能证明它能工作，更不能证明结果可信。
#
# 本模块把覆盖分成五个等级，并强制状态语义：
#
#   L0 Registered   —— 工具成功注册。只能证明工具存在。
#   L1 Invoked      —— 工具收到调用。只证明路由和参数基本可达。
#   L2 Functional   —— 产生了符合预期的真实结果（create_node 后场景里真有节点）。
#   L3 Verified     —— 结果经过第二个独立能力验证（create_node 后 list_nodes 确认）。
#   L4 Closed Loop  —— 正向 → 故障 → 检测 → 修复 → 再验证 全链路通过。
#
# 严格禁止的状态跃迁（历史上正是这些跃迁制造了假象）：
#   BLOCKED      -> PASS
#   UNSUPPORTED  -> PASS
#   "completed"  -> PASS
#   "tool returned" -> PASS
#
# 状态词汇表（封闭集合）：
#   PASS FAIL BLOCKED UNSUPPORTED UNCONFIGURED NOT_TESTED NOT_APPLICABLE STALE

class_name MCPToolCoverageTracker
extends RefCounted

## 覆盖等级
enum Level { L0, L1, L2, L3, L4 }

const LEVEL_NAMES: Array[String] = ["L0", "L1", "L2", "L3", "L4"]

## 状态封闭集合。任何不在集合内的值都被拒绝并计入 unknown。
const STATUSES: Array[String] = [
	"PASS", "FAIL", "BLOCKED", "UNSUPPORTED", "UNCONFIGURED",
	"NOT_TESTED", "NOT_APPLICABLE", "STALE"
]

## 表示"这一步确实跑通了"的状态
const PASSING_STATUSES: Array[String] = ["PASS"]

## 表示"确定没跑通"的状态
const FAILING_STATUSES: Array[String] = ["FAIL"]

## 表示"没跑成，但不能算通过也不能算失败"的状态
const BLOCKING_STATUSES: Array[String] = [
	"BLOCKED", "UNSUPPORTED", "UNCONFIGURED", "STALE"
]

## 适用范围（applicability）封闭集合
const APPLICABILITY: Array[String] = ["yes", "no", "unknown"]

## 故障敏感工具：这类工具"看起来成功"但实际没生效的危害最大，
## 因此它们必须达到 L4（闭环）才算覆盖，而不是 L3。
const FAULT_SENSITIVE_TOOLS: Array[String] = [
	"connect_signal", "disconnect_signal", "batch_connect_signals",
	"attach_script", "add_project_autoload", "remove_project_autoload",
	"upsert_project_input_action", "remove_project_input_action",
	"update_runtime_node_property", "call_runtime_node_method",
	"set_runtime_tilemap_cell", "set_runtime_shader_parameter",
	"set_tilemap_layer_cells", "set_tile_collision_polygon", "set_tile_terrain",
	"set_theme_item", "set_default_theme", "set_anchor_preset",
	"run_export", "smoke_test_export", "validate_export_preset",
	"pack_pck", "manage_export_templates", "configure_android_export",
	"assert_no_runtime_errors", "assert_performance_budget",
	"assert_visual_baseline", "assert_runtime_condition", "play_and_verify",
	"verify_scripts", "detect_broken_scripts", "validate_script", "validate_shader",
	"scan_missing_resource_dependencies", "scan_cyclic_resource_dependencies",
	"audit_project_health", "fix_resource_uid", "reimport_resources",
	"modify_script", "create_script", "create_node", "delete_node",
	"duplicate_node", "move_node", "rename_node", "update_node_property",
	"save_scene", "create_scene", "open_scene", "instantiate_scene",
	"run_project", "stop_project", "install_runtime_probe", "remove_runtime_probe"
]

## 持久化目录（位于 .mcp 下，被项目健康扫描排除）
const COVERAGE_ROOT: String = "res://.mcp/coverage"

## 报告一次导出的最大记录数，防止报告把上下文撑爆
const REPORT_MAX_ENTRIES: int = 400

const ManifestScript = preload("res://addons/godot_mcp/native_mcp/tools_manifest.gd")

var _session_name: String = ""
var _engine_version: String = ""
var _project_revision: int = 0
var _records: Dictionary = {}
var _started_at: String = ""
var _rejected_transitions: int = 0
var _events: Array[Dictionary] = []


# ---------------------------------------------------------------------------
# 会话管理
# ---------------------------------------------------------------------------

## 开启一次覆盖会话。会把全部工具初始化为 NOT_TESTED / applicability=unknown，
## 这样"未分类"在 gate 里会被显式统计出来，而不是悄悄消失。
func start_session(session_name: String = "", tool_names: Array = [],
		engine_version: String = "", project_revision: int = 0) -> Dictionary:
	_session_name = session_name.strip_edges()
	if _session_name.is_empty():
		_session_name = "coverage_%s" % Time.get_datetime_string_from_system(true).replace(":", "-")
	_engine_version = engine_version if not engine_version.is_empty() \
		else _current_engine_version()
	_project_revision = project_revision
	_started_at = Time.get_datetime_string_from_system(true)
	_records = {}
	_rejected_transitions = 0
	_events = []
	var names: Array = tool_names
	if names.is_empty():
		names = ManifestScript.tool_names()
	for name_value in names:
		var tool_name: String = String(name_value)
		_records[tool_name] = _new_record(tool_name)
	return {
		"session_name": _session_name,
		"engine_version": _engine_version,
		"project_revision": _project_revision,
		"started_at": _started_at,
		"tools": _records.size()
	}


func session_name() -> String:
	return _session_name


# ---------------------------------------------------------------------------
# 记录
# ---------------------------------------------------------------------------

## 记录一条覆盖证据。
##
## 支持字段：
##   tool_name (必需)
##   group, profile, domain
##   applicability: yes|no|unknown
##   applicability_reason
##   positive_test, negative_test, repair_test   —— 状态值
##   execution_status   —— 执行是否发生：invoked / not_invoked
##   verification_status
##   side_effect_proven: bool
##   cleanup_proven: bool
##   evidence_refs: Array[String]
##   dependencies: Array[String]
##   generated_artifacts: Array[String]
##
## 返回 {accepted: bool, record: Dictionary, errors: Array[String], warnings: []}
func record(fields: Dictionary) -> Dictionary:
	var errors: Array[String] = []
	var warnings: Array[String] = []
	var tool_name: String = String(fields.get("tool_name", "")).strip_edges()
	if tool_name.is_empty():
		return {"accepted": false, "record": {}, "errors": ["tool_name is required"], "warnings": []}
	if not _records.has(tool_name):
		_records[tool_name] = _new_record(tool_name)
	var entry: Dictionary = _records[tool_name]

	for status_key in ["positive_test", "negative_test", "repair_test", "verification_status"]:
		if not fields.has(status_key):
			continue
		var value: String = String(fields[status_key]).strip_edges().to_upper()
		if value.is_empty():
			continue
		if not value in STATUSES:
			errors.append("%s: '%s' is not in the status vocabulary %s" % [status_key, value, str(STATUSES)])
			continue
		if not _transition_allowed(status_key, value, entry, warnings):
			errors.append("%s: forbidden transition to PASS while a blocking status is recorded" % status_key)
			continue
		entry[status_key] = value

	if fields.has("execution_status"):
		var execution: String = String(fields["execution_status"]).strip_edges().to_lower()
		if execution in ["invoked", "not_invoked", "registered"]:
			entry["execution_status"] = execution
		elif not execution.is_empty():
			errors.append("execution_status: '%s' must be one of invoked/not_invoked/registered" % execution)

	if fields.has("applicability"):
		var applicability: String = String(fields["applicability"]).strip_edges().to_lower()
		if not applicability in APPLICABILITY:
			errors.append("applicability: '%s' must be one of %s" % [applicability, str(APPLICABILITY)])
		else:
			entry["applicability"] = applicability
			if applicability == "no":
				entry["applicability_reason"] = String(fields.get("applicability_reason", "")).strip_edges()
				if entry["applicability_reason"].is_empty():
					warnings.append("applicability=no requires an explicit applicability_reason")

	for bool_key in ["side_effect_proven", "cleanup_proven"]:
		if fields.has(bool_key):
			entry[bool_key] = bool(fields[bool_key])

	for list_key in ["evidence_refs", "dependencies", "generated_artifacts"]:
		if fields.has(list_key) and fields[list_key] is Array:
			var existing: Array = entry[list_key]
			for item_value in (fields[list_key] as Array):
				var item: String = String(item_value).strip_edges()
				if not item.is_empty() and not item in existing:
					existing.append(item)

	for text_key in ["group", "profile", "domain"]:
		if fields.has(text_key):
			var text: String = String(fields[text_key]).strip_edges()
			if not text.is_empty():
				entry[text_key] = text

	if not errors.is_empty():
		_rejected_transitions += errors.size()
		return {"accepted": false, "record": entry.duplicate(true), "errors": errors, "warnings": warnings}

	entry["last_verified_revision"] = int(fields.get("project_revision", _project_revision))
	entry["last_verified_engine_version"] = String(fields.get("engine_version", _engine_version))
	var custom_timestamp: String = String(fields.get("timestamp", "")).strip_edges()
	entry["last_verified_at"] = custom_timestamp if not custom_timestamp.is_empty() \
		else Time.get_datetime_string_from_system(true)
	entry["coverage_level"] = LEVEL_NAMES[_level_for(entry)]
	_events.append({
		"tool_name": tool_name,
		"at": entry["last_verified_at"],
		"fields": _compact_fields(fields)
	})
	return {"accepted": true, "record": entry.duplicate(true), "errors": [], "warnings": warnings}


## 批量记录
func record_many(entries: Array) -> Dictionary:
	var accepted: int = 0
	var rejected: int = 0
	var errors: Array[String] = []
	for entry_value in entries:
		if not (entry_value is Dictionary):
			rejected += 1
			errors.append("entry is not a dictionary")
			continue
		var result: Dictionary = record(entry_value as Dictionary)
		if bool(result.get("accepted", false)):
			accepted += 1
		else:
			rejected += 1
			errors.append_array(_string_array(result.get("errors", [])))
	return {"accepted": accepted, "rejected": rejected, "errors": errors}


func get_record(tool_name: String) -> Dictionary:
	if not _records.has(tool_name):
		return {}
	return (_records[tool_name] as Dictionary).duplicate(true)


func tool_names() -> Array[String]:
	var result: Array[String] = []
	for name_value in _records:
		result.append(String(name_value))
	result.sort()
	return result


# ---------------------------------------------------------------------------
# 审计：Coverage Gate
# ---------------------------------------------------------------------------

## 执行覆盖门禁。判定标准（严格版，见报告 #50）：
##
##   applicable tools:          100% 有覆盖记录
##   applicable positive tools: 100% >= L3
##   fault-sensitive tools:     100% >= L4
##   non-applicable tools:      100% 有明确原因
##   unknown applicability:     0
##   unclassified tools:        0
##
## 返回 {passed, gates: [...], counts: {...}, violations: {...}}
func audit() -> Dictionary:
	var applicable: Array[String] = []
	var not_applicable: Array[String] = []
	var unknown_applicability: Array[String] = []
	var below_l3: Array[Dictionary] = []
	var below_l4: Array[Dictionary] = []
	var missing_reason: Array[String] = []
	var never_tested: Array[String] = []

	for name_value in tool_names():
		var tool_name: String = name_value
		var entry: Dictionary = _records[tool_name]
		var applicability: String = String(entry.get("applicability", "unknown"))
		if applicability == "unknown":
			unknown_applicability.append(tool_name)
			continue
		if applicability == "no":
			not_applicable.append(tool_name)
			if String(entry.get("applicability_reason", "")).is_empty():
				missing_reason.append(tool_name)
			continue
		applicable.append(tool_name)
		var level: int = _level_for(entry)
		if String(entry.get("positive_test", "")) == "NOT_TESTED":
			never_tested.append(tool_name)
		if level < Level.L3:
			below_l3.append({
				"tool_name": tool_name,
				"level": LEVEL_NAMES[level],
				"positive_test": String(entry.get("positive_test", "")),
				"verification_status": String(entry.get("verification_status", ""))
			})
		if is_fault_sensitive(tool_name) and level < Level.L4:
			below_l4.append({
				"tool_name": tool_name,
				"level": LEVEL_NAMES[level],
				"negative_test": String(entry.get("negative_test", "")),
				"repair_test": String(entry.get("repair_test", ""))
			})

	var gates: Array[Dictionary] = [
		{
			"gate": "applicable_tools_have_record",
			"passed": unknown_applicability.is_empty(),
			"detail": "%d applicable, %d not-applicable, %d unknown" % [
				applicable.size(), not_applicable.size(), unknown_applicability.size()],
			"violations": unknown_applicability
		},
		{
			"gate": "applicable_positive_tools_reach_l3",
			"passed": below_l3.is_empty(),
			"detail": "%d applicable tools below L3" % below_l3.size(),
			"violations": below_l3
		},
		{
			"gate": "fault_sensitive_tools_reach_l4",
			"passed": below_l4.is_empty(),
			"detail": "%d fault-sensitive tools below L4" % below_l4.size(),
			"violations": below_l4
		},
		{
			"gate": "non_applicable_tools_have_reason",
			"passed": missing_reason.is_empty(),
			"detail": "%d not-applicable tools without a reason" % missing_reason.size(),
			"violations": missing_reason
		},
		{
			"gate": "unknown_applicability_is_zero",
			"passed": unknown_applicability.is_empty(),
			"detail": "%d tools with unknown applicability" % unknown_applicability.size(),
			"violations": unknown_applicability
		}
	]

	var passed: bool = true
	for gate_value in gates:
		if not bool((gate_value as Dictionary).get("passed", false)):
			passed = false
			break

	var level_counts: Dictionary = {}
	for name in LEVEL_NAMES:
		level_counts[name] = 0
	for name_value in tool_names():
		var level_name: String = String((_records[name_value] as Dictionary).get("coverage_level", "L0"))
		if level_counts.has(level_name):
			level_counts[level_name] = int(level_counts[level_name]) + 1

	return {
		"passed": passed,
		"session_name": _session_name,
		"engine_version": _engine_version,
		"gates": gates,
		"counts": {
			"total": _records.size(),
			"applicable": applicable.size(),
			"not_applicable": not_applicable.size(),
			"unknown_applicability": unknown_applicability.size(),
			"never_tested": never_tested.size(),
			"fault_sensitive": _count_fault_sensitive(applicable),
			"by_level": level_counts,
			"rejected_transitions": _rejected_transitions
		},
		"violations": {
			"below_l3": below_l3,
			"below_l4": below_l4,
			"missing_reason": missing_reason,
			"unknown_applicability": unknown_applicability,
			"never_tested": never_tested
		}
	}


## 导出覆盖矩阵报告。按 domain / group 分组输出，可直接落到 .mcp/coverage 下。
func export_report(include_records: bool = true, max_entries: int = REPORT_MAX_ENTRIES) -> Dictionary:
	var audit_result: Dictionary = audit()
	var by_group: Dictionary = {}
	var by_domain: Dictionary = {}
	var records_out: Array = []
	var index: int = 0
	for name_value in tool_names():
		var tool_name: String = name_value
		var entry: Dictionary = _records[tool_name]
		var group: String = String(entry.get("group", ManifestScript.group_of(tool_name)))
		var domain: String = String(entry.get("domain", ""))
		if domain.is_empty():
			domain = _infer_domain(tool_name, group)
		if not by_group.has(group):
			by_group[group] = {"total": 0, "levels": {}, "tools": []}
		if not by_domain.has(domain):
			by_domain[domain] = {"total": 0, "levels": {}, "tools": []}
		var level_name: String = String(entry.get("coverage_level", "L0"))
		for bucket in [by_group[group], by_domain[domain]]:
			bucket["total"] = int(bucket["total"]) + 1
			if not (bucket["levels"] as Dictionary).has(level_name):
				(bucket["levels"] as Dictionary)[level_name] = 0
			var levels: Dictionary = bucket["levels"]
			levels[level_name] = int(levels[level_name]) + 1
			(bucket["tools"] as Array).append(tool_name)
		if include_records and index < maxi(0, max_entries):
			records_out.append(entry.duplicate(true))
		index += 1

	return {
		"session_name": _session_name,
		"engine_version": _engine_version,
		"generated_at": Time.get_datetime_string_from_system(true),
		"gate": audit_result,
		"by_group": _sorted_bucket(by_group),
		"by_domain": _sorted_bucket(by_domain),
		"record_count": records_out.size(),
		"truncated": tool_names().size() > maxi(0, max_entries),
		"records": records_out
	}


# ---------------------------------------------------------------------------
# 持久化
# ---------------------------------------------------------------------------

func save(path: String = "") -> Dictionary:
	var target: String = path.strip_edges()
	if target.is_empty():
		target = "%s/%s.json" % [COVERAGE_ROOT, _safe_filename(_session_name)]
	var payload: String = JSON.stringify(export_report(true), "\t")
	var directory: String = target.get_base_dir()
	var make_error: int = DirAccess.make_dir_recursive_absolute(directory)
	if make_error != OK and not DirAccess.dir_exists_absolute(directory):
		return {"saved": false, "path": target, "error": "cannot create directory " + directory}
	var file: FileAccess = FileAccess.open(target, FileAccess.WRITE)
	if file == null:
		return {"saved": false, "path": target, "error": "cannot open " + target}
	file.store_string(payload)
	file.close()
	return {"saved": true, "path": target, "bytes": payload.to_utf8_buffer().size()}


func load_session(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {"loaded": false, "error": "coverage file not found: " + path}
	var text: String = FileAccess.get_file_as_string(path)
	var parsed: Variant = JSON.parse_string(text)
	if not (parsed is Dictionary):
		return {"loaded": false, "error": "coverage file is not a JSON object"}
	var data: Dictionary = parsed
	_session_name = String(data.get("session_name", _session_name))
	_engine_version = String(data.get("engine_version", _engine_version))
	_records = {}
	var records: Variant = data.get("records", [])
	if records is Array:
		for record_value in (records as Array):
			if not (record_value is Dictionary):
				continue
			var entry: Dictionary = record_value
			var tool_name: String = String(entry.get("tool_name", ""))
			if tool_name.is_empty():
				continue
			_records[tool_name] = entry
	return {"loaded": true, "tools": _records.size(), "session_name": _session_name}


# ---------------------------------------------------------------------------
# 判定规则
# ---------------------------------------------------------------------------

## 故障敏感判定：显式清单 + 语义启发式（写入类 / 断言类）
static func is_fault_sensitive(tool_name: String) -> bool:
	if tool_name in FAULT_SENSITIVE_TOOLS:
		return true
	if tool_name.begins_with("set_") or tool_name.begins_with("assert_") \
			or tool_name.begins_with("connect_") or tool_name.begins_with("disconnect_"):
		return true
	return false


## 等级判定（严格单向推导，不允许外部直接写 coverage_level）
##
##   applicability=no            -> L0（必须有原因）
##   Not invoked at all          -> L0
##   Invoked, no positive proof  -> L1
##   Positive PASS               -> L2
##   Positive PASS + verification PASS -> L3
##   + negative PASS + repair PASS     -> L4
static func _level_for(entry: Dictionary) -> int:
	if String(entry.get("applicability", "unknown")) == "no":
		return Level.L0
	var execution: String = String(entry.get("execution_status", "not_invoked"))
	if execution != "invoked":
		return Level.L0
	var positive: String = String(entry.get("positive_test", "NOT_TESTED"))
	if positive != "PASS":
		return Level.L1
	var verification: String = String(entry.get("verification_status", "NOT_TESTED"))
	if verification != "PASS":
		return Level.L2
	var negative: String = String(entry.get("negative_test", "NOT_TESTED"))
	var repair: String = String(entry.get("repair_test", "NOT_TESTED"))
	if negative == "PASS" and repair == "PASS":
		return Level.L4
	return Level.L3


## 禁止的跃迁：任何已有 BLOCKED/UNSUPPORTED/UNCONFIGURED/STALE 记录的维度，
## 不允许把 positive/verification 直接写成 PASS。
static func _transition_allowed(status_key: String, value: String,
		entry: Dictionary, warnings: Array[String]) -> bool:
	if value != "PASS":
		return true
	if status_key != "positive_test" and status_key != "verification_status":
		return true
	var blocking_dimensions: Array[String] = [
		"positive_test", "negative_test", "repair_test", "verification_status"
	]
	for dimension in blocking_dimensions:
		if dimension == status_key:
			continue
		var current: String = String(entry.get(dimension, "NOT_TESTED"))
		if current in BLOCKING_STATUSES:
			warnings.append(
				"%s is %s; recording %s=PASS would imply a forbidden %s->PASS transition"
				% [dimension, current, status_key, current])
			return false
	return true


# ---------------------------------------------------------------------------
# 内部实现
# ---------------------------------------------------------------------------

func _new_record(tool_name: String) -> Dictionary:
	return {
		"tool_name": tool_name,
		"group": ManifestScript.group_of(tool_name),
		"profile": "",
		"domain": _infer_domain(tool_name, ManifestScript.group_of(tool_name)),
		"applicability": "unknown",
		"applicability_reason": "",
		"positive_test": "NOT_TESTED",
		"negative_test": "NOT_TESTED",
		"repair_test": "NOT_TESTED",
		"execution_status": "not_invoked",
		"verification_status": "NOT_TESTED",
		"side_effect_proven": false,
		"cleanup_proven": false,
		"evidence_refs": [],
		"dependencies": [],
		"generated_artifacts": [],
		"last_verified_revision": _project_revision,
		"last_verified_engine_version": _engine_version,
		"last_verified_at": "",
		"coverage_level": "L0"
	}


func _count_fault_sensitive(tool_names_in: Array[String]) -> int:
	var count: int = 0
	for tool_name in tool_names_in:
		if is_fault_sensitive(tool_name):
			count += 1
	return count


static func _infer_domain(tool_name: String, group: String) -> String:
	var name: String = tool_name.to_lower()
	var group_name: String = group.to_lower()
	if group_name.begins_with("debug") or name.begins_with("debug") \
			or name.contains("_debug") or name.begins_with("get_debug"):
		return "debug"
	if name.contains("runtime") or name in ["run_project", "stop_project", "play_and_verify"]:
		return "runtime"
	if name.contains("export") or name.contains("pck") or name in ["smoke_test_export", "bump_version"]:
		return "build"
	if name.contains("script") or name in ["verify_scripts", "validate_shader", "search_in_files"]:
		return "script"
	if name.contains("scene") or name in ["instantiate_scene", "save_branch_as_scene"]:
		return "scene"
	if name.contains("node") or name in ["create_node", "delete_node"]:
		return "node"
	if name.contains("tile"):
		return "2d"
	if name.contains("theme") or name.contains("anchor") or name.contains("control") \
			or name.contains("localization"):
		return "ui"
	if name.contains("resource") or name.contains("asset") or name.contains("animation") \
			or name.contains("audio") or name.contains("gradient") or name.contains("texture"):
		return "assets_animation"
	if name.contains("3d") or name.contains("gltf") or name.contains("shader") \
			or name.contains("render"):
		return "3d"
	if name.contains("test") or name.contains("health") or name.contains("migration"):
		return "qa"
	return "core_editing"


static func _compact_fields(fields: Dictionary) -> Dictionary:
	var compact: Dictionary = {}
	for key_value in fields:
		var key: String = String(key_value)
		if key == "tool_name":
			continue
		var value: Variant = fields[key_value]
		if value is Array:
			compact[key] = (value as Array).size()
		elif value is String and String(value).length() > 120:
			compact[key] = String(value).substr(0, 120) + "…"
		else:
			compact[key] = value
	return compact


static func _sorted_bucket(bucket: Dictionary) -> Dictionary:
	var result: Dictionary = {}
	var keys: Array = bucket.keys()
	keys.sort()
	for key_value in keys:
		var key: String = String(key_value)
		result[key] = bucket[key_value]
	return result


static func _safe_filename(value: String) -> String:
	var text: String = value.strip_edges()
	if text.is_empty():
		return "coverage.json"
	var result: String = ""
	for character in text:
		if _is_safe_char(character):
			result += character
		else:
			result += "_"
	return result.substr(0, 64) + ".json"


static func _is_safe_char(character: String) -> bool:
	if character.length() != 1:
		return false
	var code: int = character.unicode_at(0)
	var is_alnum: bool = (code >= 48 and code <= 57) or \
		(code >= 65 and code <= 90) or (code >= 97 and code <= 122)
	return is_alnum or character == "_" or character == "-" or character == "."


static func _string_array(value: Variant) -> Array[String]:
	var result: Array[String] = []
	if not (value is Array):
		return result
	for item in (value as Array):
		result.append(String(item))
	return result


static func _current_engine_version() -> String:
	var version: Dictionary = Engine.get_version_info()
	return "%s.%s.%s" % [
		String(version.get("major", "?")),
		String(version.get("minor", "?")),
		String(version.get("patch", "?"))
	]
