extends "res://addons/gut/test.gd"

# Unit tests for the manage_task_plan tool handler in project_tools_native.gd.
# Exercises action dispatch, parameter validation and the file-backed round trip
# end to end (using a per-test user:// plan path so runs stay isolated and clean).

const TOOL_SCRIPT: String = "res://addons/godot_mcp/tools/project_tools_native.gd"

var _tools: RefCounted = null
var _plan_path: String = ""

func before_each():
	_tools = load(TOOL_SCRIPT).new()
	_plan_path = "user://test_manage_task_plan_%d.json" % Time.get_ticks_usec()

func after_each():
	var abs_path: String = ProjectSettings.globalize_path(_plan_path)
	if FileAccess.file_exists(abs_path):
		DirAccess.remove_absolute(abs_path)
	_tools = null

func _call(params: Dictionary) -> Dictionary:
	params["plan_path"] = _plan_path
	return _tools._tool_manage_task_plan(params)

# --- validation -------------------------------------------------------------

func test_missing_action_errors():
	var r: Dictionary = _tools._tool_manage_task_plan({})
	assert_has(r, "error", "Missing action should error")

func test_invalid_action_errors():
	var r: Dictionary = _call({"action": "bogus"})
	assert_has(r, "error", "Unknown action should error")

func test_bad_plan_path_errors():
	var r: Dictionary = _tools._tool_manage_task_plan({"action": "init", "plan_path": "/etc/passwd"})
	assert_has(r, "error", "Non res:// / user:// path should error")

func test_action_before_init_errors():
	var r: Dictionary = _call({"action": "next"})
	assert_has(r, "error", "Actions before init should error (no plan file)")

# --- happy path -------------------------------------------------------------

func test_init_creates_plan_file():
	var r: Dictionary = _call({"action": "init", "goal": "Vertical slice"})
	assert_eq(r.get("status"), "ok")
	assert_true(FileAccess.file_exists(ProjectSettings.globalize_path(_plan_path)))
	assert_eq((r["plan"] as Dictionary).get("goal"), "Vertical slice")

func test_add_task_and_get():
	_call({"action": "init", "goal": "G"})
	var added: Dictionary = _call({"action": "add_task", "title": "Movement", "dod": ["jumps"]})
	assert_eq(added.get("status"), "ok")
	var tid: String = (added["task"] as Dictionary).get("id")
	var got: Dictionary = _call({"action": "get", "id": tid})
	assert_eq((got["task"] as Dictionary).get("title"), "Movement")
	assert_true(got.has("progress"))

func test_set_status_done_gated_then_forced():
	_call({"action": "init", "goal": "G"})
	var added: Dictionary = _call({"action": "add_task", "title": "T", "dod": ["x"]})
	var tid: String = (added["task"] as Dictionary).get("id")
	var blocked: Dictionary = _call({"action": "set_status", "id": tid, "status": "done"})
	assert_has(blocked, "error", "done blocked by unmet DoD")
	var forced: Dictionary = _call({"action": "set_status", "id": tid, "status": "done", "force": true})
	assert_eq(forced.get("status"), "ok")

func test_set_dod_then_done_passes():
	_call({"action": "init", "goal": "G"})
	var added: Dictionary = _call({"action": "add_task", "title": "T", "dod": ["x"]})
	var tid: String = (added["task"] as Dictionary).get("id")
	_call({"action": "set_dod", "id": tid, "index": 0, "met": true, "evidence": "done"})
	var done: Dictionary = _call({"action": "set_status", "id": tid, "status": "done"})
	assert_eq(done.get("status"), "ok", "done allowed once DoD met")

func test_next_reports_ready_and_blocked():
	_call({"action": "init", "goal": "G"})
	var a: Dictionary = _call({"action": "add_task", "title": "A"})
	var aid: String = (a["task"] as Dictionary).get("id")
	_call({"action": "add_task", "title": "B", "depends_on": [aid]})
	var n: Dictionary = _call({"action": "next"})
	assert_eq((n["ready"] as Array).size(), 1)
	assert_eq((n["blocked"] as Array).size(), 1)

func test_remove_task_persists():
	_call({"action": "init", "goal": "G"})
	var a: Dictionary = _call({"action": "add_task", "title": "A"})
	var aid: String = (a["task"] as Dictionary).get("id")
	var removed: Dictionary = _call({"action": "remove_task", "id": aid})
	assert_eq(removed.get("removed"), aid)
	var got: Dictionary = _call({"action": "get", "id": aid})
	assert_has(got, "error", "Removed task should be gone after reload")

func test_state_persists_across_handler_calls():
	_call({"action": "init", "goal": "G"})
	_call({"action": "add_task", "title": "A", "id": "a"})
	# A fresh handler instance must see the persisted task.
	var fresh: RefCounted = load(TOOL_SCRIPT).new()
	var got: Dictionary = fresh._tool_manage_task_plan({"action": "get", "id": "a", "plan_path": _plan_path})
	assert_eq((got["task"] as Dictionary).get("title"), "A")
