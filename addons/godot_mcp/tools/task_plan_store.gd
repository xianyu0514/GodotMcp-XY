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
#         "dod": [{"criterion": "...", "met": false, "evidence": ""}],
#         "tags": ["gameplay"],
#         "journal": [{"at": "...", "note": "..."}],
#         "created_at": "...", "updated_at": "..."
#       }
#     ]
#   }

const SCHEMA_VERSION: int = 1
const DEFAULT_PLAN_PATH: String = "res://.mcp/task_plan.json"
const VALID_STATUSES: Array = ["pending", "in_progress", "blocked", "done"]

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
			out.append({"criterion": entry, "met": false, "evidence": ""})
		elif entry is Dictionary:
			var criterion: String = str(entry.get("criterion", "")).strip_edges()
			if criterion.is_empty():
				return {"error": "each dod entry needs a non-empty 'criterion'"}
			out.append({
				"criterion": criterion,
				"met": bool(entry.get("met", false)),
				"evidence": str(entry.get("evidence", ""))
			})
		else:
			return {"error": "dod entries must be strings or objects"}
	return {"dod": out}

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
	if args.has("index"):
		target = int(args["index"])
	elif args.has("criterion"):
		var wanted: String = str(args["criterion"]).strip_edges()
		for i in dod.size():
			if str((dod[i] as Dictionary).get("criterion", "")) == wanted:
				target = i
				break
		if target == -1:
			# Append a brand-new criterion when it does not exist yet.
			dod.append({"criterion": wanted, "met": bool(args.get("met", false)), "evidence": str(args.get("evidence", ""))})
			task["dod"] = dod
			task["updated_at"] = _now()
			_touch()
			return {"status": "ok", "task": task}
	else:
		return {"error": "set_dod needs 'dod' (full list) or 'index'/'criterion' to update one entry"}

	if target < 0 or target >= dod.size():
		return {"error": "dod index %d out of range (task has %d criteria)" % [target, dod.size()]}
	var entry: Dictionary = dod[target]
	if args.has("met"):
		entry["met"] = bool(args["met"])
	if args.has("evidence"):
		entry["evidence"] = str(args["evidence"])
	if args.has("criterion"):
		entry["criterion"] = str(args["criterion"])
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
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return {"error": "could not open '%s' for writing: %s" % [path, error_string(FileAccess.get_open_error())]}
	file.store_string(JSON.stringify(target_plan, "\t"))
	file.close()
	return {"status": "ok"}

static func load_plan(path: String) -> Dictionary:
	# Returns the parsed plan dict, or {"error": ...} on parse failure.
	# Callers should check plan_exists() first to distinguish "no plan yet".
	if not FileAccess.file_exists(path):
		return {"error": "no task plan at '%s'; call init first" % path}
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {"error": "could not open '%s' for reading: %s" % [path, error_string(FileAccess.get_open_error())]}
	var text: String = file.get_as_text()
	file.close()
	var parsed = JSON.parse_string(text)
	if not (parsed is Dictionary):
		return {"error": "task plan at '%s' is not a valid JSON object" % path}
	return parsed

static func plan_exists(path: String) -> bool:
	return FileAccess.file_exists(path)
