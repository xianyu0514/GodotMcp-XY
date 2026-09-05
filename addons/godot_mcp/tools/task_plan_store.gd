class_name TaskPlanStore
extends RefCounted

# Durable task-graph + Definition-of-Done store for AI-driven game production.
#
# This is the pure-logic layer behind the `manage_task_plan` MCP tool: a project
# can persist an ordered, dependency-aware task graph (with per-task DoD criteria,
# a free-form journal and timestamps) to a versioned JSON file, so the
# plan -> execute -> run -> verify -> fix loop survives across sessions instead of
# living only in chat context.
#
# Logic (add/update/status/dod/next/remove + cycle detection) is intentionally
# free of MCP/editor coupling so it can be unit-tested directly; the tool layer
# only does parameter validation and delegates persistence to load_plan/save_plan.
#
# Persisted shape (default path res://.mcp/task_plan.json):
#   {
#     "schema_version": 1,
#     "goal": "Ship a vertical slice",
#     "created_at": "2026-06-22T18:06:00",
#     "updated_at": "2026-06-22T18:06:00",
#     "tasks": [
#       {
#         "id": "t1", "title": "...", "description": "...",
#         "status": "pending|in_progress|blocked|done",
#         "depends_on": ["t0"],
#         "dod": [
#           {
#             "criterion": "...", "met": false, "evidence": "",
#             # Optional machine-checkable gate (see VALID_GATE_TYPES). When a
#             # gate is present and 'observed' metrics are supplied to set_dod,
#             # 'met'/'evidence' are computed objectively and the full verdict
#             # ({met, checks, failures}) is recorded under 'last_evaluation'.
#             "gate": {"type": "performance_budget", "budget": {"min_fps": 55}},
#             "last_evaluation": {"met": true, "checks": [], "failures": []}
#           }
#         ],
#         "tags": ["gameplay"],
#         "journal": [{"at": "...", "note": "..."}],
#         "created_at": "...", "updated_at": "..."
#       }
#     ]
#   }

const SCHEMA_VERSION: int = 1
const DEFAULT_PLAN_PATH: String = "res://.mcp/task_plan.json"
const CHECKPOINT_REVISION_KEY: String = "checkpoint_revision"
const CHECKPOINT_STAGING_SUFFIX: String = ".next"
const CHECKPOINT_BACKUP_SUFFIX: String = ".bak"
const VALID_STATUSES: Array = ["pending", "in_progress", "blocked", "done"]

# A DoD criterion may carry an optional 'gate' so the VERIFY phase can decide
# 'met' objectively from observed metrics instead of a self-asserted boolean.
# Gate types mirror the three verification tools.
const VALID_GATE_TYPES: Array = ["performance_budget", "no_runtime_errors", "visual_baseline"]

# performance_budget keys -> comparator (mirrors assert_performance_budget).
# Observed values are supplied under the same key as the budget threshold.
const PERF_BUDGET_COMPARATORS: Dictionary = {
	"min_fps": "gte",
	"max_frame_time_ms": "lte",
	"max_physics_frame_time_ms": "lte",
	"max_object_count": "lte",
	"max_resource_count": "lte",
	"max_rendered_objects": "lte",
	"max_memory_mb": "lte",
	"max_node_count": "lte"
}

var plan: Dictionary

func _init(initial: Dictionary = {}) -> void:
	if initial.is_empty():
		plan = new_plan("")
	else:
		plan = initial

# --- construction -----------------------------------------------------------

static func _now() -> String:
	return Time.get_datetime_string_from_system(false, true)

static func new_plan(goal: String) -> Dictionary:
	var ts: String = _now()
	return {
		"schema_version": SCHEMA_VERSION,
		"goal": goal,
		"created_at": ts,
		"updated_at": ts,
		"tasks": []
	}

func _touch() -> void:
	plan["updated_at"] = _now()

# --- task lookup ------------------------------------------------------------

func _tasks() -> Array:
	if not (plan.get("tasks") is Array):
		plan["tasks"] = []
	return plan["tasks"]

func has_task(task_id: String) -> bool:
	return _find_index(task_id) != -1

func _find_index(task_id: String) -> int:
	var tasks: Array = _tasks()
	for i in tasks.size():
		if str((tasks[i] as Dictionary).get("id", "")) == task_id:
			return i
	return -1

func get_task(task_id: String) -> Dictionary:
	var idx: int = _find_index(task_id)
	if idx == -1:
		return {}
	return _tasks()[idx]

func _next_auto_id() -> String:
	# Smallest unused "t<N>" id so ids stay short and stable.
	var n: int = 1
	while has_task("t%d" % n):
		n += 1
	return "t%d" % n

# --- DoD normalization ------------------------------------------------------

static func _normalize_dod(raw) -> Dictionary:
	# Accepts an Array of strings and/or {criterion, met, evidence} dicts.
	# Returns {"dod": [...]} on success or {"error": "..."} on bad shape.
	if raw == null:
		return {"dod": []}
	if not (raw is Array):
		return {"error": "dod must be an array of criteria"}
	var out: Array = []
	for entry in raw:
		if entry is String:
			# Trim so string entries are stored the same way dict entries (and the
			# single-criterion set_dod path) are, keeping later trimmed lookups
			# consistent.
			var text: String = (entry as String).strip_edges()
			if text.is_empty():
				return {"error": "each dod entry needs a non-empty 'criterion'"}
			out.append({"criterion": text, "met": false, "evidence": ""})
		elif entry is Dictionary:
			var criterion: String = str(entry.get("criterion", "")).strip_edges()
			if criterion.is_empty():
				return {"error": "each dod entry needs a non-empty 'criterion'"}
			var normalized: Dictionary = {
				"criterion": criterion,
				"met": bool(entry.get("met", false)),
				"evidence": str(entry.get("evidence", ""))
			}
			if entry.has("gate") and entry["gate"] != null:
				var gate_result: Dictionary = _normalize_gate(entry["gate"])
				if gate_result.has("error"):
					return gate_result
				normalized["gate"] = gate_result["gate"]
			out.append(normalized)
		else:
			return {"error": "dod entries must be strings or objects"}
	return {"dod": out}

# Validate and normalize a DoD gate spec. Returns {"gate": {...}} or {"error": ...}.
static func _normalize_gate(raw) -> Dictionary:
	if not (raw is Dictionary):
		return {"error": "gate must be an object"}
	var gate_type: String = str(raw.get("type", "")).strip_edges()
	if not (gate_type in VALID_GATE_TYPES):
		return {"error": "gate.type must be one of: %s" % ", ".join(VALID_GATE_TYPES)}
	var gate: Dictionary = {"type": gate_type}
	match gate_type:
		"performance_budget":
			if not (raw.get("budget") is Dictionary) or (raw["budget"] as Dictionary).is_empty():
				return {"error": "performance_budget gate needs a non-empty 'budget' object"}
			var budget: Dictionary = {}
			for key in (raw["budget"] as Dictionary).keys():
				if not PERF_BUDGET_COMPARATORS.has(str(key)):
					return {"error": "unknown budget key '%s'. Valid: %s" % [key, ", ".join(PERF_BUDGET_COMPARATORS.keys())]}
				budget[str(key)] = float(raw["budget"][key])
			gate["budget"] = budget
		"no_runtime_errors":
			gate["max_errors"] = max(0, int(raw.get("max_errors", 0)))
		"visual_baseline":
			var has_threshold: bool = false
			if raw.has("max_diff_pixels"):
				gate["max_diff_pixels"] = max(0, int(raw["max_diff_pixels"]))
				has_threshold = true
			if raw.has("max_diff_ratio"):
				gate["max_diff_ratio"] = float(raw["max_diff_ratio"])
				has_threshold = true
			if not has_threshold:
				return {"error": "visual_baseline gate needs 'max_diff_pixels' and/or 'max_diff_ratio'"}
	return {"gate": gate}

# Objectively evaluate a normalized gate against observed metrics.
# observed is a flat map keyed the same way as the gate's thresholds
# (e.g. {"min_fps": 58, "max_memory_mb": 180} or {"error_count": 0}).
# Returns {"met": bool, "checks": [...], "failures": [...]}.
static func evaluate_gate(gate: Dictionary, observed: Dictionary) -> Dictionary:
	var checks: Array = []
	var failures: Array = []
	var gate_type: String = str(gate.get("type", ""))
	match gate_type:
		"performance_budget":
			var budget: Dictionary = gate.get("budget", {})
			for key in budget.keys():
				var limit: float = float(budget[key])
				var comparator: String = str(PERF_BUDGET_COMPARATORS.get(key, "lte"))
				if not observed.has(key):
					var miss: Dictionary = {"metric": key, "limit": limit, "observed": null, "passed": false, "reason": "missing"}
					checks.append(miss)
					failures.append(miss)
					continue
				var actual: float = float(observed[key])
				var passed: bool = (actual >= limit) if comparator == "gte" else (actual <= limit)
				var check: Dictionary = {"metric": key, "limit": limit, "observed": actual, "comparator": comparator, "passed": passed}
				checks.append(check)
				if not passed:
					failures.append(check)
		"no_runtime_errors":
			var max_errors: int = int(gate.get("max_errors", 0))
			# Require an actual measurement: an empty observed must not pass on a
			# default of 0 ("can't prove no errors ⇒ not met"), matching how the
			# other gate types treat missing metrics.
			var has_measurement: bool = observed.has("error_count") or (observed.get("errors") is Array)
			if not has_measurement:
				var miss_ec: Dictionary = {"metric": "error_count", "limit": max_errors, "observed": null, "comparator": "lte", "passed": false, "reason": "missing"}
				checks.append(miss_ec)
				failures.append(miss_ec)
			else:
				var error_count: int = 0
				if observed.has("error_count"):
					error_count = int(observed["error_count"])
				else:
					error_count = (observed["errors"] as Array).size()
				var ok_errors: bool = error_count <= max_errors
				var ec: Dictionary = {"metric": "error_count", "limit": max_errors, "observed": error_count, "comparator": "lte", "passed": ok_errors}
				checks.append(ec)
				if not ok_errors:
					failures.append(ec)
		"visual_baseline":
			if gate.has("max_diff_pixels"):
				var limit_px: int = int(gate["max_diff_pixels"])
				var actual_px: int = int(observed.get("diff_pixels", -1))
				var ok_px: bool = actual_px >= 0 and actual_px <= limit_px
				var cpx: Dictionary = {"metric": "diff_pixels", "limit": limit_px, "observed": actual_px, "comparator": "lte", "passed": ok_px}
				checks.append(cpx)
				if not ok_px:
					failures.append(cpx)
			if gate.has("max_diff_ratio"):
				var limit_ratio: float = float(gate["max_diff_ratio"])
				var has_ratio: bool = observed.has("diff_ratio")
				var actual_ratio: float = float(observed.get("diff_ratio", -1.0))
				var ok_ratio: bool = has_ratio and actual_ratio >= 0.0 and actual_ratio <= limit_ratio
				var cr: Dictionary = {"metric": "diff_ratio", "limit": limit_ratio, "observed": actual_ratio if has_ratio else null, "comparator": "lte", "passed": ok_ratio}
				checks.append(cr)
				if not ok_ratio:
					failures.append(cr)
		_:
			return {"met": false, "checks": [], "failures": [{"reason": "unknown gate type '%s'" % gate_type}]}
	return {"met": failures.is_empty(), "checks": checks, "failures": failures}

static func dod_all_met(task: Dictionary) -> bool:
	var dod = task.get("dod", [])
	if not (dod is Array) or (dod as Array).is_empty():
		return true
	for entry in dod:
		if not bool((entry as Dictionary).get("met", false)):
			return false
	return true

# --- mutations --------------------------------------------------------------

func init_plan(goal: String, reset: bool) -> Dictionary:
	if reset or not (plan.get("tasks") is Array):
		plan = new_plan(goal)
	else:
		plan["goal"] = goal
		_touch()
	return {"status": "ok", "plan": plan}

func add_task(fields: Dictionary) -> Dictionary:
	var title: String = str(fields.get("title", "")).strip_edges()
	if title.is_empty():
		return {"error": "title is required"}

	var task_id: String = str(fields.get("id", "")).strip_edges()
	if task_id.is_empty():
		task_id = _next_auto_id()
	elif has_task(task_id):
		return {"error": "task id '%s' already exists" % task_id}

	var status: String = str(fields.get("status", "pending")).strip_edges()
	if not (status in VALID_STATUSES):
		return {"error": "invalid status '%s'" % status}

	var depends_on: Array = []
	if fields.has("depends_on"):
		if not (fields["depends_on"] is Array):
			return {"error": "depends_on must be an array of task ids"}
		for dep in fields["depends_on"]:
			depends_on.append(str(dep))
		var dep_check: Dictionary = _validate_dependencies(task_id, depends_on)
		if dep_check.has("error"):
			return dep_check

	var dod_result: Dictionary = _normalize_dod(fields.get("dod", []))
	if dod_result.has("error"):
		return dod_result

	var tags: Array = []
	if fields.has("tags"):
		if not (fields["tags"] is Array):
			return {"error": "tags must be an array of strings"}
		for tag in fields["tags"]:
			tags.append(str(tag))

	var ts: String = _now()
	var task: Dictionary = {
		"id": task_id,
		"title": title,
		"description": str(fields.get("description", "")),
		"status": status,
		"depends_on": depends_on,
		"dod": dod_result["dod"],
		"tags": tags,
		"journal": [],
		"created_at": ts,
		"updated_at": ts
	}
	# Detect cycles created by this task before committing it.
	_tasks().append(task)
	var cycle: Dictionary = _detect_cycle()
	if cycle.has("error"):
		_tasks().pop_back()
		return cycle
	_touch()
	return {"status": "ok", "task": task}

func update_task(task_id: String, fields: Dictionary) -> Dictionary:
	var idx: int = _find_index(task_id)
	if idx == -1:
		return {"error": "task '%s' not found" % task_id}
	var task: Dictionary = _tasks()[idx]

	if fields.has("title"):
		var title: String = str(fields["title"]).strip_edges()
		if title.is_empty():
			return {"error": "title cannot be empty"}
		task["title"] = title
	if fields.has("description"):
		task["description"] = str(fields["description"])
	if fields.has("status"):
		var status: String = str(fields["status"]).strip_edges()
		if not (status in VALID_STATUSES):
			return {"error": "invalid status '%s'" % status}
		task["status"] = status
	if fields.has("tags"):
		if not (fields["tags"] is Array):
			return {"error": "tags must be an array of strings"}
		var tags: Array = []
		for tag in fields["tags"]:
			tags.append(str(tag))
		task["tags"] = tags
	if fields.has("dod"):
		var dod_result: Dictionary = _normalize_dod(fields["dod"])
		if dod_result.has("error"):
			return dod_result
		task["dod"] = dod_result["dod"]
	if fields.has("depends_on"):
		if not (fields["depends_on"] is Array):
			return {"error": "depends_on must be an array of task ids"}
		var depends_on: Array = []
		for dep in fields["depends_on"]:
			depends_on.append(str(dep))
		var dep_check: Dictionary = _validate_dependencies(task_id, depends_on)
		if dep_check.has("error"):
			return dep_check
		var previous: Array = task["depends_on"]
		task["depends_on"] = depends_on
		var cycle: Dictionary = _detect_cycle()
		if cycle.has("error"):
			task["depends_on"] = previous
			return cycle

	task["updated_at"] = _now()
	if fields.has("journal"):
		_append_journal(task, str(fields["journal"]))
	_touch()
	return {"status": "ok", "task": task}

func set_status(task_id: String, status: String, force: bool, journal: String) -> Dictionary:
	var idx: int = _find_index(task_id)
	if idx == -1:
		return {"error": "task '%s' not found" % task_id}
	if not (status in VALID_STATUSES):
		return {"error": "invalid status '%s'" % status}
	var task: Dictionary = _tasks()[idx]

	if status == "done" and not force and not dod_all_met(task):
		return {"error": "cannot mark '%s' done: not all DoD criteria are met (use force=true to override)" % task_id}

	task["status"] = status
	task["updated_at"] = _now()
	if not journal.is_empty():
		_append_journal(task, journal)
	_touch()
	return {"status": "ok", "task": task}

func set_dod(task_id: String, args: Dictionary) -> Dictionary:
	var idx: int = _find_index(task_id)
	if idx == -1:
		return {"error": "task '%s' not found" % task_id}
	var task: Dictionary = _tasks()[idx]

	# Mode A: replace the whole criteria list.
	if args.has("dod"):
		var dod_result: Dictionary = _normalize_dod(args["dod"])
		if dod_result.has("error"):
			return dod_result
		task["dod"] = dod_result["dod"]
		task["updated_at"] = _now()
		_touch()
		return {"status": "ok", "task": task}

	# Mode B: update a single criterion's met/evidence, by index or criterion text.
	var dod: Array = task.get("dod", [])
	var target: int = -1
	# Reject whitespace-only criterion text up front so neither creating a new
	# criterion by text nor renaming an existing one can persist an empty string,
	# matching the non-empty rule enforced on the full-list path (_normalize_dod).
	if args.has("criterion") and str(args["criterion"]).strip_edges().is_empty():
		return {"error": "criterion text must be non-empty"}
	if args.has("index"):
		target = int(args["index"])
	elif args.has("criterion"):
		var wanted: String = str(args["criterion"]).strip_edges()
		for i in dod.size():
			if str((dod[i] as Dictionary).get("criterion", "")) == wanted:
				target = i
				break
		if target == -1:
			# Validate everything that could fail BEFORE mutating the task, so an
			# error return never leaves a half-created criterion behind.
			if args.has("gate") and args["gate"] != null:
				var pre_gate: Dictionary = _normalize_gate(args["gate"])
				if pre_gate.has("error"):
					return pre_gate
			if args.has("observed"):
				# A brand-new criterion has no prior gate, so 'observed' can only be
				# evaluated when a gate is supplied in this same call.
				if not (args.has("gate") and args["gate"] != null):
					return {"error": "criterion has no gate to evaluate 'observed' against"}
				if not (args["observed"] is Dictionary):
					return {"error": "observed must be an object of measured metrics"}
			# Append a brand-new criterion, then fall through to the shared update
			# logic below so gate / observed / met / evidence are all applied the
			# same way as for an existing criterion (avoids ignoring 'observed').
			dod.append({"criterion": wanted, "met": false, "evidence": ""})
			task["dod"] = dod
			target = dod.size() - 1
	else:
		return {"error": "set_dod needs 'dod' (full list) or 'index'/'criterion' to update one entry"}

	if target < 0 or target >= dod.size():
		return {"error": "dod index %d out of range (task has %d criteria)" % [target, dod.size()]}
	# Work on a copy and only commit it back once every validation has passed,
	# so an error return never leaves a criterion partially mutated (e.g. a gate
	# attached but the subsequent 'observed' evaluation rejected).
	var entry: Dictionary = (dod[target] as Dictionary).duplicate(true)
	# Allow attaching/replacing a gate on this criterion.
	if args.has("gate"):
		if args["gate"] == null:
			entry.erase("gate")
		else:
			var gate_result: Dictionary = _normalize_gate(args["gate"])
			if gate_result.has("error"):
				return gate_result
			entry["gate"] = gate_result["gate"]
	# Objective path: given observed metrics, compute 'met' from the gate.
	if args.has("observed"):
		if not (entry.get("gate") is Dictionary):
			return {"error": "criterion has no gate to evaluate 'observed' against"}
		if not (args["observed"] is Dictionary):
			return {"error": "observed must be an object of measured metrics"}
		var verdict: Dictionary = evaluate_gate(entry["gate"], args["observed"])
		entry["met"] = bool(verdict["met"])
		entry["evidence"] = JSON.stringify({"gate": entry["gate"]["type"], "met": verdict["met"], "checks": verdict["checks"]})
		entry["last_evaluation"] = verdict
	else:
		if args.has("met"):
			entry["met"] = bool(args["met"])
		if args.has("evidence"):
			entry["evidence"] = str(args["evidence"])
	if args.has("criterion"):
		# Store the trimmed text so it matches how criteria are matched/created
		# above (line 424), instead of persisting whitespace-padded input.
		entry["criterion"] = str(args["criterion"]).strip_edges()
	# All validations passed — commit the mutated copy back.
	dod[target] = entry
	task["dod"] = dod
	task["updated_at"] = _now()
	_touch()
	return {"status": "ok", "task": task}

func remove_task(task_id: String) -> Dictionary:
	var idx: int = _find_index(task_id)
	if idx == -1:
		return {"error": "task '%s' not found" % task_id}
	_tasks().remove_at(idx)
	# Strip dangling references so the graph stays consistent.
	for task in _tasks():
		var deps: Array = (task as Dictionary).get("depends_on", [])
		if deps.has(task_id):
			deps.erase(task_id)
	_touch()
	return {"status": "ok", "removed": task_id}

func _append_journal(task: Dictionary, note: String) -> void:
	if note.strip_edges().is_empty():
		return
	if not (task.get("journal") is Array):
		task["journal"] = []
	task["journal"].append({"at": _now(), "note": note})

# --- dependency / cycle validation ------------------------------------------

func _validate_dependencies(task_id: String, depends_on: Array) -> Dictionary:
	for dep in depends_on:
		var dep_id: String = str(dep)
		if dep_id == task_id:
			return {"error": "task '%s' cannot depend on itself" % task_id}
		if not has_task(dep_id):
			return {"error": "depends_on references unknown task '%s'" % dep_id}
	return {}

func _detect_cycle() -> Dictionary:
	# Iterative DFS with colour marks; returns {"error": ...} when a cycle exists.
	var tasks: Array = _tasks()
	var edges: Dictionary = {}
	for task in tasks:
		edges[str((task as Dictionary).get("id", ""))] = (task as Dictionary).get("depends_on", [])
	var state: Dictionary = {}  # 0=unvisited,1=visiting,2=done
	for node in edges.keys():
		if state.get(node, 0) == 2:
			continue
		var stack: Array = [{"node": node, "i": 0}]
		state[node] = 1
		while not stack.is_empty():
			var frame: Dictionary = stack.back()
			var deps: Array = edges.get(frame["node"], [])
			if frame["i"] < deps.size():
				var nxt: String = str(deps[frame["i"]])
				frame["i"] = int(frame["i"]) + 1
				if not edges.has(nxt):
					continue
				var color: int = state.get(nxt, 0)
				if color == 1:
					return {"error": "dependency cycle detected involving task '%s'" % nxt}
				elif color == 0:
					state[nxt] = 1
					stack.append({"node": nxt, "i": 0})
			else:
				state[frame["node"]] = 2
				stack.pop_back()
	return {}

# --- queries ----------------------------------------------------------------

func progress() -> Dictionary:
	var counts: Dictionary = {"pending": 0, "in_progress": 0, "blocked": 0, "done": 0}
	for task in _tasks():
		var status: String = str((task as Dictionary).get("status", "pending"))
		if counts.has(status):
			counts[status] = int(counts[status]) + 1
	var total: int = _tasks().size()
	var done: int = int(counts["done"])
	var percent: float = 0.0
	if total > 0:
		percent = round(float(done) / float(total) * 1000.0) / 10.0
	return {
		"total": total,
		"pending": counts["pending"],
		"in_progress": counts["in_progress"],
		"blocked": counts["blocked"],
		"done": counts["done"],
		"percent_done": percent
	}

func next_actionable() -> Dictionary:
	# A task is actionable when it is pending and every dependency is done.
	var ready: Array = []
	var blocked: Array = []
	for task in _tasks():
		var t: Dictionary = task
		var status: String = str(t.get("status", "pending"))
		if status == "done" or status == "in_progress":
			continue
		var unmet: Array = []
		for dep in t.get("depends_on", []):
			var dep_task: Dictionary = get_task(str(dep))
			if dep_task.is_empty() or str(dep_task.get("status", "")) != "done":
				unmet.append(str(dep))
		if unmet.is_empty() and status == "pending":
			ready.append({"id": t["id"], "title": t["title"]})
		else:
			blocked.append({"id": t["id"], "title": t["title"], "status": status, "blocked_by": unmet})
	return {
		"ready": ready,
		"blocked": blocked,
		"progress": progress()
	}

# --- persistence ------------------------------------------------------------

static func save_plan(target_plan: Dictionary, path: String) -> Dictionary:
	var base_dir: String = path.get_base_dir()
	if not base_dir.is_empty():
		var abs_dir: String = ProjectSettings.globalize_path(base_dir)
		if not DirAccess.dir_exists_absolute(abs_dir):
			var err: Error = DirAccess.make_dir_recursive_absolute(abs_dir)
			if err != OK and not DirAccess.dir_exists_absolute(abs_dir):
				return {"error": "could not create directory '%s': %s" % [base_dir, error_string(err)]}
	# A previous crash may have left the newest committed generation in .next.
	# Promote it before reusing that filename, otherwise another interruption
	# during the retry could fall back past work that was already recovered.
	var recovery_result: Dictionary = _preserve_newest_staging(path)
	if recovery_result.has("error"):
		return recovery_result
	# Write and validate a complete staging generation before touching the
	# committed checkpoint.  The previous primary is retained as a backup so a
	# process/editor crash in either rename window always leaves a readable plan.
	var highest_revision: int = _highest_checkpoint_revision(path)
	target_plan[CHECKPOINT_REVISION_KEY] = max(
		int(target_plan.get(CHECKPOINT_REVISION_KEY, 0)), highest_revision
	) + 1
	var staging_path: String = path + CHECKPOINT_STAGING_SUFFIX
	var file: FileAccess = FileAccess.open(staging_path, FileAccess.WRITE)
	if file == null:
		return {"error": "could not open '%s' for writing: %s" % [staging_path, error_string(FileAccess.get_open_error())]}
	file.store_string(JSON.stringify(target_plan, "\t"))
	file.flush()
	file.close()
	var staged: Dictionary = _read_checkpoint(staging_path)
	if staged.has("error"):
		return {"error": "could not validate staged task plan at '%s': %s" % [staging_path, staged["error"]]}

	var primary_absolute: String = ProjectSettings.globalize_path(path)
	var staging_absolute: String = ProjectSettings.globalize_path(staging_path)
	var backup_path: String = path + CHECKPOINT_BACKUP_SUFFIX
	var backup_absolute: String = ProjectSettings.globalize_path(backup_path)
	if FileAccess.file_exists(path):
		if FileAccess.file_exists(backup_path):
			var remove_error: Error = DirAccess.remove_absolute(backup_absolute)
			if remove_error != OK:
				return {"error": "could not replace checkpoint backup '%s': %s" % [backup_path, error_string(remove_error)]}
		var backup_error: Error = DirAccess.rename_absolute(primary_absolute, backup_absolute)
		if backup_error != OK:
			return {"error": "could not rotate task plan '%s' to backup: %s" % [path, error_string(backup_error)]}

	var promote_error: Error = DirAccess.rename_absolute(staging_absolute, primary_absolute)
	if promote_error != OK:
		# Best-effort restoration is only needed when the primary was rotated.
		# The fully written staging generation is intentionally left in place so
		# load_plan() can still recover it if restoration also fails.
		if not FileAccess.file_exists(path) and FileAccess.file_exists(backup_path):
			DirAccess.rename_absolute(backup_absolute, primary_absolute)
		return {"error": "could not promote staged task plan '%s': %s" % [staging_path, error_string(promote_error)]}
	return {"status": "ok", CHECKPOINT_REVISION_KEY: target_plan[CHECKPOINT_REVISION_KEY]}

static func load_plan(path: String) -> Dictionary:
	# Consider all generations because a crash can happen after staging is
	# flushed or after the primary has been renamed to its backup.  Revision wins;
	# for legacy/tied generations the committed primary has highest priority.
	if not plan_exists(path):
		return {"error": "no task plan at '%s'; call init first" % path}
	var best_plan: Dictionary = {}
	var best_revision: int = -1
	var best_priority: int = -1
	var found_valid: bool = false
	var candidates: Array = [
		{"path": path + CHECKPOINT_BACKUP_SUFFIX, "priority": 0},
		{"path": path + CHECKPOINT_STAGING_SUFFIX, "priority": 1},
		{"path": path, "priority": 2}
	]
	for candidate_value in candidates:
		var candidate: Dictionary = candidate_value
		var candidate_path: String = str(candidate["path"])
		if not FileAccess.file_exists(candidate_path):
			continue
		var loaded: Dictionary = _read_checkpoint(candidate_path)
		if loaded.has("error"):
			continue
		var candidate_plan: Dictionary = loaded["plan"]
		var revision: int = max(0, int(candidate_plan.get(CHECKPOINT_REVISION_KEY, 0)))
		var priority: int = int(candidate["priority"])
		if not found_valid or revision > best_revision or (revision == best_revision and priority > best_priority):
			best_plan = candidate_plan
			best_revision = revision
			best_priority = priority
			found_valid = true
	if not found_valid:
		return {"error": "task plan at '%s' has no valid checkpoint generation" % path}
	return best_plan

static func _read_checkpoint(path: String) -> Dictionary:
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {"error": "could not open for reading: %s" % error_string(FileAccess.get_open_error())}
	var text: String = file.get_as_text()
	file.close()
	var parser := JSON.new()
	var parse_error: Error = parser.parse(text)
	if parse_error != OK:
		return {"error": "invalid JSON at line %d: %s" % [parser.get_error_line(), parser.get_error_message()]}
	var parsed = parser.data
	if not (parsed is Dictionary):
		return {"error": "checkpoint is not a JSON object"}
	return {"plan": parsed}

static func _highest_checkpoint_revision(path: String) -> int:
	var highest: int = 0
	for candidate_path in [path, path + CHECKPOINT_STAGING_SUFFIX, path + CHECKPOINT_BACKUP_SUFFIX]:
		if not FileAccess.file_exists(candidate_path):
			continue
		var loaded: Dictionary = _read_checkpoint(candidate_path)
		if loaded.has("error"):
			continue
		var candidate_plan: Dictionary = loaded["plan"]
		highest = max(highest, int(candidate_plan.get(CHECKPOINT_REVISION_KEY, 0)))
	return highest

static func _preserve_newest_staging(path: String) -> Dictionary:
	var staging_path: String = path + CHECKPOINT_STAGING_SUFFIX
	if not FileAccess.file_exists(staging_path):
		return {"status": "unchanged"}
	var staged_result: Dictionary = _read_checkpoint(staging_path)
	if staged_result.has("error"):
		return {"status": "unchanged"}
	var staged_plan: Dictionary = staged_result["plan"]
	var staged_revision: int = max(0, int(staged_plan.get(CHECKPOINT_REVISION_KEY, 0)))

	var primary_valid: bool = false
	var primary_revision: int = -1
	if FileAccess.file_exists(path):
		var primary_result: Dictionary = _read_checkpoint(path)
		if not primary_result.has("error"):
			primary_valid = true
			primary_revision = max(0, int((primary_result["plan"] as Dictionary).get(CHECKPOINT_REVISION_KEY, 0)))
	if primary_valid and primary_revision >= staged_revision:
		return {"status": "unchanged"}

	var backup_path: String = path + CHECKPOINT_BACKUP_SUFFIX
	var backup_valid: bool = false
	var backup_revision: int = -1
	if FileAccess.file_exists(backup_path):
		var backup_result: Dictionary = _read_checkpoint(backup_path)
		if not backup_result.has("error"):
			backup_valid = true
			backup_revision = max(0, int((backup_result["plan"] as Dictionary).get(CHECKPOINT_REVISION_KEY, 0)))
	if backup_valid and backup_revision > staged_revision:
		return {"status": "unchanged"}

	var primary_absolute: String = ProjectSettings.globalize_path(path)
	var staging_absolute: String = ProjectSettings.globalize_path(staging_path)
	var backup_absolute: String = ProjectSettings.globalize_path(backup_path)
	var rotated_primary: bool = false
	if FileAccess.file_exists(path):
		if primary_valid:
			if FileAccess.file_exists(backup_path):
				var backup_remove_error: Error = DirAccess.remove_absolute(backup_absolute)
				if backup_remove_error != OK:
					return {"error": "could not replace checkpoint backup '%s': %s" % [backup_path, error_string(backup_remove_error)]}
			var rotate_error: Error = DirAccess.rename_absolute(primary_absolute, backup_absolute)
			if rotate_error != OK:
				return {"error": "could not preserve previous task plan '%s': %s" % [path, error_string(rotate_error)]}
			rotated_primary = true
		else:
			var corrupt_remove_error: Error = DirAccess.remove_absolute(primary_absolute)
			if corrupt_remove_error != OK:
				return {"error": "could not remove invalid task plan '%s': %s" % [path, error_string(corrupt_remove_error)]}

	var promote_error: Error = DirAccess.rename_absolute(staging_absolute, primary_absolute)
	if promote_error != OK:
		if rotated_primary and not FileAccess.file_exists(path) and FileAccess.file_exists(backup_path):
			DirAccess.rename_absolute(backup_absolute, primary_absolute)
		return {"error": "could not preserve recovered task plan '%s': %s" % [staging_path, error_string(promote_error)]}
	return {"status": "recovered"}

static func plan_exists(path: String) -> bool:
	return (
		FileAccess.file_exists(path)
		or FileAccess.file_exists(path + CHECKPOINT_STAGING_SUFFIX)
		or FileAccess.file_exists(path + CHECKPOINT_BACKUP_SUFFIX)
	)
