@tool
class_name AsyncJobManager
extends RefCounted

# Unified asynchronous job framework for long-running MCP tool work (test runs,
# external generation, exports). Jobs run on the Godot 4.x WorkerThreadPool so
# the editor main thread is never blocked and several jobs run concurrently.
#
# Caller contract (pending -> poll, mirroring the runtime-probe convention):
#   - start_job(job_id, work) launches `work` (a Callable returning a
#     Dictionary) on a worker thread under a caller-chosen stable job_id.
#     Returns false when the id is already taken or the callable is invalid.
#   - poll_job(job_id) reads status/progress/result; a finished job is removed
#     from the registry (polling again then reports "missing").
#   - cancel_job(job_id) flips a cooperative cancellation flag; the worker
#     checks is_cancelled(job_id) and aborts early. Workers signal that they
#     honoured the cancellation by returning a Dictionary that contains a
#     truthy "cancelled" key; poll_job then reports status "cancelled".
#   - update_progress(job_id, progress, total) publishes progress numbers from
#     the worker thread; the main thread forwards them to MCP notifications.
#
# poll_job() status values:
#   "missing"   - no job under this id (never started, or already polled)
#   "pending"   - worker still running (progress/total/elapsed_ms available)
#   "done"      - finished; "result" holds the worker's Dictionary
#   "cancelled" - finished AND the worker returned a truthy "cancelled" key
#
# Thread safety: every mutable job field lives behind the job's own Mutex. The
# worker thread only touches its own record (result/progress/cancel flag); the
# registry itself is only mutated by the caller's thread on start/poll, so it
# needs no extra locking. job_finished is emitted from the worker thread after
# the result is stored; connected handlers run on that worker thread and must
# be thread-safe (they must not touch the scene tree).
#
# AsyncJobRunner-compatible surface (start/poll/has_job/active_count/
# elapsed_ms/flush) is provided so this class is a drop-in superset of the
# older Thread-based runner; existing callers keep working unchanged.

signal job_finished(job_id: String, result: Dictionary)

class _Job extends RefCounted:
	var task_id: int = -1
	var mutex: Mutex = Mutex.new()
	var finished: bool = false
	var result: Dictionary = {}
	var progress: int = 0
	var total: int = 0
	var cancelled_requested: bool = false
	var started_ms: int = 0
	var progress_callback: Callable = Callable()

var _jobs: Dictionary = {}

# ============================================================================
# AsyncJobRunner-compatible surface
# ============================================================================

func has_job(job_id: String) -> bool:
	return _jobs.has(job_id)

func active_count() -> int:
	return _jobs.size()

func elapsed_ms(job_id: String) -> int:
	if not _jobs.has(job_id):
		return 0
	var job: _Job = _jobs[job_id]
	return Time.get_ticks_msec() - job.started_ms

func start(key: String, work: Callable) -> bool:
	return start_job(key, work)

func poll(key: String) -> Dictionary:
	var polled: Dictionary = poll_job(key)
	var status: String = str(polled.get("status", ""))
	if status != "done" and status != "cancelled":
		return {"finished": false, "result": {}}
	return {"finished": true, "result": polled.get("result", {})}

# Join every outstanding worker task and clear the registry. Call on teardown.
func flush() -> void:
	for job_id in _jobs.keys():
		var job: _Job = _jobs[job_id]
		if job != null and job.task_id >= 0:
			WorkerThreadPool.wait_for_task_completion(job.task_id)
	_jobs.clear()

# ============================================================================
# Unified job API
# ============================================================================

# Start `work` on a worker thread under `job_id`. Returns false when the id is
# already taken or the callable is not valid. `progress_callback`, when given,
# is invoked on the worker thread on every update_progress call and must be
# thread-safe. Workers signal cooperative cancellation by returning a
# Dictionary with a truthy "cancelled" key.
func start_job(job_id: String, work: Callable, progress_callback: Callable = Callable()) -> bool:
	if _jobs.has(job_id):
		return false
	if not work.is_valid():
		return false
	var job: _Job = _Job.new()
	job.started_ms = Time.get_ticks_msec()
	job.progress_callback = progress_callback
	_jobs[job_id] = job
	job.task_id = WorkerThreadPool.add_task(Callable(self, "_run").bind(job_id, job, work))
	if job.task_id < 0:
		_jobs.erase(job_id)
		return false
	return true

# Poll a job. A finished job is joined and removed from the registry.
func poll_job(job_id: String) -> Dictionary:
	if not _jobs.has(job_id):
		return {"status": "missing", "progress": 0, "total": 0, "elapsed_ms": 0}
	var job: _Job = _jobs[job_id]
	job.mutex.lock()
	var finished: bool = job.finished
	var result: Dictionary = job.result.duplicate(true) if finished else {}
	var progress: int = job.progress
	var total: int = job.total
	job.mutex.unlock()
	var out: Dictionary = {
		"status": "pending" if not finished else "done",
		"progress": progress,
		"total": total,
		"elapsed_ms": Time.get_ticks_msec() - job.started_ms
	}
	if not finished:
		return out
	if bool(result.get("cancelled", false)):
		out["status"] = "cancelled"
	out["result"] = result
	if job.task_id >= 0:
		WorkerThreadPool.wait_for_task_completion(job.task_id)
	_jobs.erase(job_id)
	return out

# Request cooperative cancellation: the flag is observed by the worker via
# is_cancelled(). The worker decides when/where to abort.
func cancel_job(job_id: String) -> void:
	if not _jobs.has(job_id):
		return
	var job: _Job = _jobs[job_id]
	job.mutex.lock()
	job.cancelled_requested = true
	job.mutex.unlock()

# True when cancel_job() was called for this job. Poll from the worker thread.
func is_cancelled(job_id: String) -> bool:
	if not _jobs.has(job_id):
		return false
	var job: _Job = _jobs[job_id]
	job.mutex.lock()
	var cancelled: bool = job.cancelled_requested
	job.mutex.unlock()
	return cancelled

# Publish progress from the worker thread. When a progress_callback was
# registered for the job it is invoked (on the worker thread) with
# (job_id, progress, total).
func update_progress(job_id: String, progress: int, total: int = 0) -> void:
	if not _jobs.has(job_id):
		return
	var job: _Job = _jobs[job_id]
	job.mutex.lock()
	job.progress = progress
	job.total = total
	var callback: Callable = job.progress_callback
	job.mutex.unlock()
	if callback.is_valid():
		callback.call(job_id, progress, total)

# Worker entry point: run the work, store the produced Dictionary under the
# job's mutex, then announce completion. A non-Dictionary return value is
# wrapped under "result" (same convention as AsyncJobRunner).
func _run(job_id: String, job: _Job, work: Callable) -> void:
	var produced: Variant = work.call()
	var result: Dictionary = produced if produced is Dictionary else {"result": produced}
	job.mutex.lock()
	job.result = result
	job.finished = true
	job.mutex.unlock()
	job_finished.emit(job_id, result)

func _notification(what: int) -> void:
	if what != NOTIFICATION_PREDELETE:
		return
	# Inline the flush logic: calling a self method during PREDELETE can fail
	# with "in base 'null instance'" once the script method table is torn down.
	for job_id in _jobs.keys():
		var job: _Job = _jobs[job_id]
		if job != null and job.task_id >= 0:
			WorkerThreadPool.wait_for_task_completion(job.task_id)
	_jobs.clear()
