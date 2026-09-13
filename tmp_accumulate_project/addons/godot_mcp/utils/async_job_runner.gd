@tool
class_name AsyncJobRunner
extends RefCounted

# Runs a blocking unit of work on a background thread so the editor main thread
# is not frozen while it executes. Callers start a job by key, then poll the same
# key until it reports finished. Mirrors the "pending then poll" convention used
# by the runtime probe, applied here to long-running subprocesses (test runs).

class _Job extends RefCounted:
	var thread: Thread = Thread.new()
	var mutex: Mutex = Mutex.new()
	var finished: bool = false
	var result: Dictionary = {}
	var started_ms: int = 0

var _jobs: Dictionary = {}

func has_job(key: String) -> bool:
	return _jobs.has(key)

func active_count() -> int:
	return _jobs.size()

func elapsed_ms(key: String) -> int:
	if not _jobs.has(key):
		return 0
	var job: _Job = _jobs[key]
	return Time.get_ticks_msec() - job.started_ms

# Start `work` (a Callable returning a Dictionary) on a background thread under
# `key`. Returns false if a job with this key is already running.
func start(key: String, work: Callable) -> bool:
	if _jobs.has(key):
		return false
	var job: _Job = _Job.new()
	job.started_ms = Time.get_ticks_msec()
	_jobs[key] = job
	job.thread.start(Callable(self, "_run").bind(job, work))
	return true

func _run(job: _Job, work: Callable) -> void:
	var produced: Variant = work.call()
	var result: Dictionary = produced if produced is Dictionary else {"result": produced}
	job.mutex.lock()
	job.result = result
	job.finished = true
	job.mutex.unlock()

# Poll a job. Returns {"finished": bool, "result": Dictionary}. When finished,
# the worker thread is joined and the job is removed.
func poll(key: String) -> Dictionary:
	if not _jobs.has(key):
		return {"finished": false, "result": {}}
	var job: _Job = _jobs[key]
	job.mutex.lock()
	var done: bool = job.finished
	var result: Dictionary = job.result.duplicate(true) if done else {}
	job.mutex.unlock()
	if not done:
		return {"finished": false, "result": {}}
	if job.thread.is_started():
		job.thread.wait_to_finish()
	_jobs.erase(key)
	return {"finished": true, "result": result}

# Join every outstanding thread and clear the registry. Call on teardown.
func flush() -> void:
	for key in _jobs.keys():
		var job: _Job = _jobs[key]
		if job.thread.is_started():
			job.thread.wait_to_finish()
	_jobs.clear()

func _notification(what: int) -> void:
	if what != NOTIFICATION_PREDELETE:
		return
	# Inline the flush logic: calling a self method during PREDELETE can fail
	# with "in base 'null instance'" once the script method table is torn down.
	for key in _jobs.keys():
		var job: _Job = _jobs[key]
		if job != null and job.thread != null and job.thread.is_started():
			job.thread.wait_to_finish()
	_jobs.clear()
