extends "res://addons/gut/test.gd"

# Unit tests for the unified async job framework (AsyncJobManager). Covers the
# start/poll/cancel/progress lifecycle, per-job independence, the cooperative
# cancellation convention, the AsyncJobRunner-compatible surface, and the
# job_finished signal.

var _manager: AsyncJobManager = null

func before_each() -> void:
	_manager = AsyncJobManager.new()

func after_each() -> void:
	if _manager != null:
		_manager.flush()
	_manager = null

# --- worker helpers ---------------------------------------------------------

func _fast_work() -> Dictionary:
	return {"ok": true, "value": 42}

func _slow_work() -> Dictionary:
	OS.delay_msec(120)
	return {"ok": true}

# Long-running loop that honours cooperative cancellation.
func _cancel_aware_work(job_id: String) -> Dictionary:
	var deadline: int = Time.get_ticks_msec() + 3000
	while Time.get_ticks_msec() < deadline:
		if _manager.is_cancelled(job_id):
			return {"cancelled": true, "status": "cancelled"}
		OS.delay_msec(10)
	return {"ok": true, "timed_out": true}

func _progress_work(job_id: String) -> Dictionary:
	for i in range(1, 11):
		_manager.update_progress(job_id, i, 10)
		OS.delay_msec(15)
	return {"ok": true}

func _non_dictionary_work() -> int:
	return 7

func _wait_for_finish(job_id: String, timeout_ms: int = 5000) -> Dictionary:
	var deadline: int = Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline:
		var polled: Dictionary = _manager.poll_job(job_id)
		if polled.get("status", "") != "pending":
			return polled
		OS.delay_msec(10)
	return {"status": "timeout"}

# --- lifecycle --------------------------------------------------------------

func test_start_poll_done_roundtrip():
	assert_true(_manager.start_job("j-a", Callable(self, "_fast_work")), "start returns true for a new id")
	assert_true(_manager.has_job("j-a"), "job registered under its id")
	var done: Dictionary = _wait_for_finish("j-a")
	assert_eq(done.get("status"), "done", "finished job reports done")
	assert_eq((done.get("result", {}) as Dictionary).get("value"), 42, "worker result forwarded")
	assert_false(_manager.has_job("j-a"), "finished job removed after a successful poll")

func test_poll_pending_while_running():
	assert_true(_manager.start_job("j-p", Callable(self, "_slow_work")))
	var polled: Dictionary = _manager.poll_job("j-p")
	assert_eq(polled.get("status"), "pending", "in-flight job reports pending")
	assert_false(polled.has("result"), "pending poll carries no result")
	_wait_for_finish("j-p")

func test_poll_unknown_returns_missing():
	var polled: Dictionary = _manager.poll_job("nope")
	assert_eq(polled.get("status"), "missing", "unknown job id reports missing")

func test_duplicate_start_rejected():
	assert_true(_manager.start_job("j-b", Callable(self, "_slow_work")), "first start succeeds")
	assert_false(_manager.start_job("j-b", Callable(self, "_slow_work")), "duplicate id rejected while running")
	_wait_for_finish("j-b")

func test_invalid_callable_rejected():
	assert_false(_manager.start_job("j-bad", Callable()), "an invalid callable is rejected")

func test_multiple_jobs_run_independently():
	var ids: Array = []
	for i in range(3):
		var job_id: String = "j-multi-%d" % i
		ids.append(job_id)
		assert_true(_manager.start_job(job_id, Callable(self, "_slow_work")), "job %d starts" % i)
	assert_eq(_manager.active_count(), 3, "three jobs tracked concurrently")
	for job_id in ids:
		var done: Dictionary = _wait_for_finish(job_id)
		assert_eq(done.get("status"), "done", "job %s finishes independently" % job_id)
		assert_true(bool((done.get("result", {}) as Dictionary).get("ok", false)), "job %s result intact" % job_id)
	assert_eq(_manager.active_count(), 0, "registry empty after all jobs polled")

func test_non_dictionary_result_is_wrapped():
	assert_true(_manager.start_job("j-e", Callable(self, "_non_dictionary_work")))
	var done: Dictionary = _wait_for_finish("j-e")
	assert_eq(done.get("status"), "done", "wrapped result still reports done")
	assert_eq((done.get("result", {}) as Dictionary).get("result"), 7, "non-dictionary value wrapped under 'result'")

func test_elapsed_ms_and_active_count_lifecycle():
	assert_eq(_manager.active_count(), 0, "no jobs initially")
	assert_eq(_manager.elapsed_ms("missing"), 0, "unknown key has zero elapsed time")
	_manager.start_job("j-f", Callable(self, "_slow_work"))
	assert_eq(_manager.active_count(), 1, "one job tracked")
	assert_true(_manager.elapsed_ms("j-f") >= 0, "elapsed time measurable")
	_wait_for_finish("j-f")
	assert_eq(_manager.active_count(), 0, "count returns to zero after polling")

func test_flush_clears_outstanding_jobs():
	_manager.start_job("j-g", Callable(self, "_slow_work"))
	_manager.flush()
	assert_eq(_manager.active_count(), 0, "flush joins and clears outstanding jobs")
	assert_false(_manager.has_job("j-g"), "no jobs remain after flush")

# --- cancellation -----------------------------------------------------------

func test_cancel_flips_flag_and_worker_aborts():
	var job_id: String = "j-c"
	assert_true(_manager.start_job(job_id, Callable(self, "_cancel_aware_work").bind(job_id)))
	_manager.cancel_job(job_id)
	assert_true(_manager.is_cancelled(job_id), "cancel flag observed after cancel_job")
	var done: Dictionary = _wait_for_finish(job_id)
	assert_eq(done.get("status"), "cancelled", "worker that honours cancellation reports cancelled")
	assert_true(bool((done.get("result", {}) as Dictionary).get("cancelled", false)), "result carries the cancelled marker")

func test_is_cancelled_false_for_unknown_and_uncancelled():
	assert_false(_manager.is_cancelled("missing"), "unknown job is never cancelled")
	_manager.start_job("j-nc", Callable(self, "_fast_work"))
	assert_false(_manager.is_cancelled("j-nc"), "fresh job is not cancelled")
	_wait_for_finish("j-nc")

func test_cancel_unknown_is_noop():
	# Must not crash and must not register a job.
	_manager.cancel_job("missing")
	assert_false(_manager.has_job("missing"), "cancelling an unknown id registers nothing")

# --- progress ---------------------------------------------------------------

func test_progress_reported_via_poll():
	var job_id: String = "j-d"
	assert_true(_manager.start_job(job_id, Callable(self, "_progress_work").bind(job_id)))
	var deadline: int = Time.get_ticks_msec() + 3000
	var seen_progress: int = -1
	while Time.get_ticks_msec() < deadline:
		var polled: Dictionary = _manager.poll_job(job_id)
		if polled.get("status", "") == "pending":
			seen_progress = int(polled.get("progress", 0))
			if seen_progress >= 1:
				break
		else:
			break
		OS.delay_msec(10)
	assert_true(seen_progress >= 1, "worker progress is observable through poll (observed %d)" % seen_progress)

# --- AsyncJobRunner-compatible surface --------------------------------------

func test_compat_runner_surface():
	assert_true(_manager.start("c-a", Callable(self, "_fast_work")), "compat start alias works")
	var deadline: int = Time.get_ticks_msec() + 3000
	var done: Dictionary = {}
	while Time.get_ticks_msec() < deadline:
		done = _manager.poll("c-a")
		if bool(done.get("finished", false)):
			break
		OS.delay_msec(10)
	assert_true(bool(done.get("finished", false)), "compat poll reports finished once done")
	assert_eq((done.get("result", {}) as Dictionary).get("value"), 42, "compat poll forwards the result")
	assert_false(_manager.has_job("c-a"), "compat poll removed the finished job")

func test_compat_poll_unknown_key_is_not_finished():
	var polled: Dictionary = _manager.poll("c-missing")
	assert_false(bool(polled.get("finished", false)), "compat poll of an unknown key reports not finished")

# --- signal ----------------------------------------------------------------

func test_job_finished_signal_emitted():
	var job_id: String = "j-sig"
	var saw: Array = []
	_manager.job_finished.connect(func(emitted_id: String, emitted_result: Dictionary) -> void:
		saw.append({"id": emitted_id, "result": emitted_result}))
	assert_true(_manager.start_job(job_id, Callable(self, "_fast_work")))
	var deadline: int = Time.get_ticks_msec() + 3000
	while Time.get_ticks_msec() < deadline:
		var polled: Dictionary = _manager.poll_job(job_id)
		if polled.get("status", "") != "pending":
			break
		OS.delay_msec(10)
	assert_eq(saw.size(), 1, "job_finished emitted exactly once")
	assert_eq(saw[0].get("id"), job_id, "signal carries the job id")
	assert_eq((saw[0].get("result", {}) as Dictionary).get("value"), 42, "signal carries the worker result")
