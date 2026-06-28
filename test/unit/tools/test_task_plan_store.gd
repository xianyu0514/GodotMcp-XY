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

# --- DoD gates (objective verification) -------------------------------------

func test_normalize_dod_stores_valid_gate():
	_store.init_plan("g", true)
	var r: Dictionary = _store.add_task({"title": "perf", "dod": [{"criterion": "fps ok", "gate": {"type": "performance_budget", "budget": {"min_fps": 55}}}]})
	assert_false(r.has("error"))
	var gate: Dictionary = r["task"]["dod"][0]["gate"]
	assert_eq(gate["type"], "performance_budget")
	assert_eq(float(gate["budget"]["min_fps"]), 55.0)

func test_normalize_dod_rejects_bad_gate_type():
	_store.init_plan("g", true)
	var r: Dictionary = _store.add_task({"title": "x", "dod": [{"criterion": "c", "gate": {"type": "bogus"}}]})
	assert_has(r, "error")

func test_normalize_dod_rejects_unknown_budget_key():
	_store.init_plan("g", true)
	var r: Dictionary = _store.add_task({"title": "x", "dod": [{"criterion": "c", "gate": {"type": "performance_budget", "budget": {"max_warp": 1}}}]})
	assert_has(r, "error")

func test_evaluate_gate_perf_pass_and_fail():
	var gate: Dictionary = {"type": "performance_budget", "budget": {"min_fps": 55.0, "max_memory_mb": 200.0}}
	assert_true(TaskPlanStore.evaluate_gate(gate, {"min_fps": 60, "max_memory_mb": 180})["met"], "within budget -> met")
	assert_false(TaskPlanStore.evaluate_gate(gate, {"min_fps": 40, "max_memory_mb": 180})["met"], "fps below floor -> not met")
	assert_false(TaskPlanStore.evaluate_gate(gate, {"min_fps": 60})["met"], "missing metric -> not met")

func test_evaluate_gate_no_runtime_errors():
	var gate: Dictionary = {"type": "no_runtime_errors", "max_errors": 0}
	assert_true(TaskPlanStore.evaluate_gate(gate, {"error_count": 0})["met"])
	assert_false(TaskPlanStore.evaluate_gate(gate, {"error_count": 2})["met"])
	assert_true(TaskPlanStore.evaluate_gate(gate, {"errors": []})["met"])
	assert_false(TaskPlanStore.evaluate_gate(gate, {"errors": ["boom"]})["met"])

func test_evaluate_gate_visual_baseline():
	var gate: Dictionary = {"type": "visual_baseline", "max_diff_pixels": 10}
	assert_true(TaskPlanStore.evaluate_gate(gate, {"diff_pixels": 5})["met"])
	assert_false(TaskPlanStore.evaluate_gate(gate, {"diff_pixels": 50})["met"])
	assert_false(TaskPlanStore.evaluate_gate(gate, {})["met"], "missing observation -> not met")

func test_set_dod_observed_sets_met_objectively():
	_store.init_plan("g", true)
	var add: Dictionary = _store.add_task({"title": "perf", "dod": [{"criterion": "fps ok", "gate": {"type": "performance_budget", "budget": {"min_fps": 55}}}]})
	var tid: String = add["task"]["id"]
	var pass_res: Dictionary = _store.set_dod(tid, {"index": 0, "observed": {"min_fps": 60}})
	assert_true(pass_res["task"]["dod"][0]["met"], "observed within budget -> met")
	assert_true(str(pass_res["task"]["dod"][0]["evidence"]).length() > 0, "evidence auto-filled")
	var fail_res: Dictionary = _store.set_dod(tid, {"index": 0, "observed": {"min_fps": 30}})
	assert_false(fail_res["task"]["dod"][0]["met"], "observed below budget -> not met")

func test_set_dod_observed_without_gate_errors():
	_store.init_plan("g", true)
	var add: Dictionary = _store.add_task({"title": "t", "dod": ["manual"]})
	var tid: String = add["task"]["id"]
	var r: Dictionary = _store.set_dod(tid, {"index": 0, "observed": {"min_fps": 60}})
	assert_has(r, "error", "observed without a gate should error")

func test_set_dod_can_attach_gate_then_evaluate():
	_store.init_plan("g", true)
	var add: Dictionary = _store.add_task({"title": "t", "dod": ["no errors"]})
	var tid: String = add["task"]["id"]
	_store.set_dod(tid, {"index": 0, "gate": {"type": "no_runtime_errors"}})
	var r: Dictionary = _store.set_dod(tid, {"index": 0, "observed": {"error_count": 0}})
	assert_true(r["task"]["dod"][0]["met"])

func test_set_status_done_respects_gate_met():
	_store.init_plan("g", true)
	var add: Dictionary = _store.add_task({"title": "t", "dod": [{"criterion": "fps", "gate": {"type": "performance_budget", "budget": {"min_fps": 55}}}]})
	var tid: String = add["task"]["id"]
	var blocked: Dictionary = _store.set_status(tid, "done", false, "")
	assert_has(blocked, "error", "cannot mark done while gated DoD unmet")
	_store.set_dod(tid, {"index": 0, "observed": {"min_fps": 60}})
	var okdone: Dictionary = _store.set_status(tid, "done", false, "")
	assert_false(okdone.has("error"), "done allowed once gate satisfied")

func test_set_dod_new_criterion_evaluates_gate_and_observed():
	# Creating a brand-new criterion via criterion text while passing gate +
	# observed together must evaluate the gate, not silently default met=false.
	_store.init_plan("g", true)
	var add: Dictionary = _store.add_task({"title": "t", "dod": ["seed"]})
	var tid: String = add["task"]["id"]
	var r: Dictionary = _store.set_dod(tid, {"criterion": "fps ok", "gate": {"type": "performance_budget", "budget": {"min_fps": 55}}, "observed": {"min_fps": 60}})
	var dod: Array = r["task"]["dod"]
	assert_eq(dod.size(), 2, "new gated criterion appended")
	assert_true(bool(dod[1]["met"]), "observed evaluated against gate on new criterion")
	assert_true(dod[1].has("gate"), "gate attached to new criterion")

func test_set_dod_new_criterion_rejects_bad_gate_without_appending():
	_store.init_plan("g", true)
	var add: Dictionary = _store.add_task({"title": "t", "dod": ["seed"]})
	var tid: String = add["task"]["id"]
	var r: Dictionary = _store.set_dod(tid, {"criterion": "bad", "gate": {"type": "not_a_gate"}})
	assert_has(r, "error", "invalid gate type rejected")
	var task: Dictionary = _store.get_task(tid)
	assert_eq((task["dod"] as Array).size(), 1, "no half-created criterion left behind")

func test_evaluate_gate_no_runtime_errors_requires_measurement():
	# An empty observed must NOT pass on a default of 0 ("can't prove ⇒ not met").
	var gate: Dictionary = {"type": "no_runtime_errors", "max_errors": 0}
	assert_false(TaskPlanStore.evaluate_gate(gate, {})["met"], "no measurement -> not met")
	assert_true(TaskPlanStore.evaluate_gate(gate, {"error_count": 0})["met"], "measured 0 errors -> met")

func test_set_dod_new_criterion_observed_without_gate_does_not_mutate():
	# observed but no gate on a new criterion must error WITHOUT leaving a
	# half-created criterion behind (rollback contract).
	_store.init_plan("g", true)
	var add: Dictionary = _store.add_task({"title": "t", "dod": ["seed"]})
	var tid: String = add["task"]["id"]
	var r: Dictionary = _store.set_dod(tid, {"criterion": "x", "observed": {"min_fps": 60}})
	assert_has(r, "error", "observed without a gate should error")
	var task: Dictionary = _store.get_task(tid)
	assert_eq((task["dod"] as Array).size(), 1, "no half-created criterion left behind")

func test_set_dod_new_criterion_non_dict_observed_does_not_mutate():
	_store.init_plan("g", true)
	var add: Dictionary = _store.add_task({"title": "t", "dod": ["seed"]})
	var tid: String = add["task"]["id"]
	var r: Dictionary = _store.set_dod(tid, {"criterion": "x", "gate": {"type": "no_runtime_errors"}, "observed": 5})
	assert_has(r, "error", "non-dict observed should error")
	var task: Dictionary = _store.get_task(tid)
	assert_eq((task["dod"] as Array).size(), 1, "no half-created criterion left behind")

func test_set_dod_existing_criterion_error_rolls_back_gate():
	# Attaching a gate AND passing a bad observed in one call must error WITHOUT
	# leaving the gate on the existing criterion (transactional update).
	_store.init_plan("g", true)
	var add: Dictionary = _store.add_task({"title": "t", "dod": ["seed"]})
	var tid: String = add["task"]["id"]
	var r: Dictionary = _store.set_dod(tid, {"index": 0, "gate": {"type": "no_runtime_errors"}, "observed": 5})
	assert_has(r, "error", "non-dict observed should error")
	var task: Dictionary = _store.get_task(tid)
	assert_false((task["dod"][0] as Dictionary).has("gate"), "gate not committed when call errors")

func test_set_dod_stores_trimmed_criterion_text():
	# A criterion is matched/created by its trimmed text, so it must also be
	# stored trimmed instead of persisting whitespace-padded input.
	_store.init_plan("g", true)
	var add: Dictionary = _store.add_task({"title": "t", "dod": ["seed"]})
	var tid: String = add["task"]["id"]
	var r: Dictionary = _store.set_dod(tid, {"criterion": "  fps ok  "})
	assert_eq(r.get("status", ""), "ok", "set_dod should succeed")
	# New criterion stored trimmed, and a follow-up call with the same padded text
	# updates that same entry (no duplicate created).
	var task: Dictionary = _store.get_task(tid)
	assert_eq(str((task["dod"][1] as Dictionary)["criterion"]), "fps ok", "criterion stored trimmed")
	_store.set_dod(tid, {"criterion": "fps ok", "met": true})
	task = _store.get_task(tid)
	assert_eq((task["dod"] as Array).size(), 2, "no duplicate criterion created")

func test_normalize_dod_trims_string_entries():
	# Full-list / add_task string entries must be stored trimmed too, so a later
	# trimmed set_dod lookup matches them.
	_store.init_plan("g", true)
	var add: Dictionary = _store.add_task({"title": "t", "dod": ["  fps ok  "]})
	var tid: String = add["task"]["id"]
	var task: Dictionary = _store.get_task(tid)
	assert_eq(str((task["dod"][0] as Dictionary)["criterion"]), "fps ok", "string entry stored trimmed")
	var r: Dictionary = _store.set_dod(tid, {"criterion": "fps ok", "met": true})
	assert_eq(r.get("status", ""), "ok", "trimmed lookup should match the stored entry")

func test_normalize_dod_rejects_whitespace_only_string_entry():
	_store.init_plan("g", true)
	var add: Dictionary = _store.add_task({"title": "t", "dod": ["   "]})
	assert_has(add, "error", "whitespace-only criterion should be rejected")

func test_set_dod_rejects_whitespace_only_new_criterion():
	# Creating a criterion by whitespace-only text must error, consistent with
	# the full-list path, instead of persisting an empty-text criterion.
	_store.init_plan("g", true)
	var add: Dictionary = _store.add_task({"title": "t", "dod": ["seed"]})
	var tid: String = add["task"]["id"]
	var r: Dictionary = _store.set_dod(tid, {"criterion": "   "})
	assert_has(r, "error", "whitespace-only new criterion should be rejected")
	var task: Dictionary = _store.get_task(tid)
	assert_eq((task["dod"] as Array).size(), 1, "no empty criterion appended")

func test_set_dod_rejects_rename_to_whitespace_only():
	# Renaming an existing criterion (by index) to whitespace-only text must error
	# and leave the original text untouched.
	_store.init_plan("g", true)
	var add: Dictionary = _store.add_task({"title": "t", "dod": ["seed"]})
	var tid: String = add["task"]["id"]
	var r: Dictionary = _store.set_dod(tid, {"index": 0, "criterion": "   "})
	assert_has(r, "error", "renaming to whitespace-only should be rejected")
	var task: Dictionary = _store.get_task(tid)
	assert_eq(str((task["dod"][0] as Dictionary)["criterion"]), "seed", "original text unchanged")
