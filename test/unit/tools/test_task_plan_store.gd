extends "res://addons/gut/test.gd"

# Unit tests for TaskPlanStore — the pure task-graph + Definition-of-Done logic
# behind the manage_task_plan tool. Covers add/update/status/dod/remove,
# dependency validation, cycle detection, next-actionable + progress queries,
# and the JSON save/load round trip (under user:// so tests stay isolated).

var _store: TaskPlanStore = null

func before_each():
	_store = TaskPlanStore.new()

func after_each():
	_store = null

# --- construction -----------------------------------------------------------

func test_new_plan_is_empty():
	assert_eq(_store.plan.get("schema_version"), TaskPlanStore.SCHEMA_VERSION)
	assert_eq((_store.plan.get("tasks") as Array).size(), 0)

func test_init_plan_sets_goal():
	_store.init_plan("Ship a slice", false)
	assert_eq(_store.plan.get("goal"), "Ship a slice")

# --- add_task ---------------------------------------------------------------

func test_add_task_requires_title():
	var r: Dictionary = _store.add_task({})
	assert_has(r, "error", "Missing title should error")

func test_add_task_auto_id():
	var r: Dictionary = _store.add_task({"title": "First"})
	assert_eq(r.get("status"), "ok")
	assert_eq((r["task"] as Dictionary).get("id"), "t1")
	var r2: Dictionary = _store.add_task({"title": "Second"})
	assert_eq((r2["task"] as Dictionary).get("id"), "t2")

func test_add_task_duplicate_id_errors():
	_store.add_task({"title": "A", "id": "a"})
	var r: Dictionary = _store.add_task({"title": "B", "id": "a"})
	assert_has(r, "error", "Duplicate id should error")

func test_add_task_normalizes_string_dod():
	var r: Dictionary = _store.add_task({"title": "A", "dod": ["jumps 96px"]})
	var dod: Array = (r["task"] as Dictionary).get("dod")
	assert_eq(dod.size(), 1)
	assert_eq((dod[0] as Dictionary).get("criterion"), "jumps 96px")
	assert_false((dod[0] as Dictionary).get("met"))

func test_add_task_unknown_dependency_errors():
	var r: Dictionary = _store.add_task({"title": "A", "depends_on": ["ghost"]})
	assert_has(r, "error", "Unknown dependency should error")

func test_add_task_self_dependency_errors():
	var r: Dictionary = _store.add_task({"title": "A", "id": "a", "depends_on": ["a"]})
	assert_has(r, "error", "Self dependency should error")

# --- cycle detection --------------------------------------------------------

func test_cycle_detected_on_update():
	_store.add_task({"title": "A", "id": "a"})
	_store.add_task({"title": "B", "id": "b", "depends_on": ["a"]})
	var r: Dictionary = _store.update_task("a", {"depends_on": ["b"]})
	assert_has(r, "error", "a->b->a cycle should be rejected")
	# The rejected edge must not be persisted.
	assert_eq((_store.get_task("a").get("depends_on") as Array).size(), 0)

# --- set_status / DoD gate --------------------------------------------------

func test_set_status_done_blocked_by_unmet_dod():
	_store.add_task({"title": "A", "id": "a", "dod": ["compiles"]})
	var r: Dictionary = _store.set_status("a", "done", false, "")
	assert_has(r, "error", "done should be refused when DoD unmet")

func test_set_status_done_with_force():
	_store.add_task({"title": "A", "id": "a", "dod": ["compiles"]})
	var r: Dictionary = _store.set_status("a", "done", true, "forced")
	assert_eq(r.get("status"), "ok")
	assert_eq(_store.get_task("a").get("status"), "done")

func test_set_status_done_when_all_met():
	_store.add_task({"title": "A", "id": "a", "dod": [{"criterion": "x", "met": true}]})
	var r: Dictionary = _store.set_status("a", "done", false, "")
	assert_eq(r.get("status"), "ok")

func test_set_status_records_journal():
	_store.add_task({"title": "A", "id": "a"})
	_store.set_status("a", "in_progress", false, "started")
	assert_eq((_store.get_task("a").get("journal") as Array).size(), 1)

# --- set_dod ----------------------------------------------------------------

func test_set_dod_updates_single_by_index():
	_store.add_task({"title": "A", "id": "a", "dod": ["x", "y"]})
	var r: Dictionary = _store.set_dod("a", {"index": 1, "met": true, "evidence": "log line 5"})
	assert_eq(r.get("status"), "ok")
	var dod: Array = _store.get_task("a").get("dod")
	assert_true((dod[1] as Dictionary).get("met"))
	assert_eq((dod[1] as Dictionary).get("evidence"), "log line 5")

func test_set_dod_appends_new_criterion():
	_store.add_task({"title": "A", "id": "a"})
	_store.set_dod("a", {"criterion": "fps>=60", "met": false})
	assert_eq((_store.get_task("a").get("dod") as Array).size(), 1)

func test_set_dod_replaces_list():
	_store.add_task({"title": "A", "id": "a", "dod": ["old"]})
	_store.set_dod("a", {"dod": ["new1", "new2"]})
	assert_eq((_store.get_task("a").get("dod") as Array).size(), 2)

# --- remove_task ------------------------------------------------------------

func test_remove_task_strips_dependency_refs():
	_store.add_task({"title": "A", "id": "a"})
	_store.add_task({"title": "B", "id": "b", "depends_on": ["a"]})
	_store.remove_task("a")
	assert_false(_store.has_task("a"))
	assert_eq((_store.get_task("b").get("depends_on") as Array).size(), 0, "dangling ref should be stripped")

# --- next_actionable / progress ---------------------------------------------

func test_next_actionable_respects_dependencies():
	_store.add_task({"title": "A", "id": "a"})
	_store.add_task({"title": "B", "id": "b", "depends_on": ["a"]})
	var n: Dictionary = _store.next_actionable()
	assert_eq((n["ready"] as Array).size(), 1, "only a is ready")
	assert_eq(((n["ready"] as Array)[0] as Dictionary).get("id"), "a")
	assert_eq((n["blocked"] as Array).size(), 1, "b is blocked")

func test_next_actionable_unblocks_after_dependency_done():
	_store.add_task({"title": "A", "id": "a"})
	_store.add_task({"title": "B", "id": "b", "depends_on": ["a"]})
	_store.set_status("a", "done", true, "")
	var n: Dictionary = _store.next_actionable()
	var ids: Array = []
	for entry in n["ready"]:
		ids.append((entry as Dictionary).get("id"))
	assert_true("b" in ids, "b becomes ready once a is done")

func test_progress_counts():
	_store.add_task({"title": "A", "id": "a"})
	_store.add_task({"title": "B", "id": "b"})
	_store.set_status("a", "done", true, "")
	var p: Dictionary = _store.progress()
	assert_eq(p.get("total"), 2)
	assert_eq(p.get("done"), 1)
	assert_eq(p.get("percent_done"), 50.0)

# --- persistence round trip -------------------------------------------------

func test_save_and_load_round_trip():
	var path: String = "user://test_task_plan_%d.json" % (Time.get_ticks_usec())
	_store.init_plan("Goal X", true)
	_store.add_task({"title": "A", "id": "a", "dod": ["x"]})
	var saved: Dictionary = TaskPlanStore.save_plan(_store.plan, path)
	assert_eq(saved.get("status"), "ok")
	assert_true(TaskPlanStore.plan_exists(path))
	var loaded = TaskPlanStore.load_plan(path)
	assert_true(loaded is Dictionary and not loaded.has("error"))
	assert_eq(loaded.get("goal"), "Goal X")
	assert_eq((loaded.get("tasks") as Array).size(), 1)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))

func test_load_missing_plan_errors():
	var loaded = TaskPlanStore.load_plan("user://does_not_exist_%d.json" % Time.get_ticks_usec())
	assert_has(loaded, "error", "Loading a missing plan should error")
