extends "res://addons/gut/test.gd"

# Unit tests for generate_3d_asset in project_tools_native.gd. These cover the
# offline/pure parts only (config resolution, JSON dot-path extraction, status
# matching, glTF byte validation, and the unconfigured / missing-param / missing
# env-var guard paths). The submit/poll/download HTTP flow is not exercised here
# because it requires a live external provider + the user's own API key.

var _tools: RefCounted = null

func before_each() -> void:
	_tools = load("res://addons/godot_mcp/tools/project_tools_native.gd").new()

func after_each() -> void:
	_tools = null

# --- parameter validation -------------------------------------------------

func test_missing_prompt():
	assert_true(_tools._tool_generate_3d_asset({"resource_path": "res://model.glb"}).has("error"), "missing prompt errors")

func test_missing_resource_path():
	assert_true(_tools._tool_generate_3d_asset({"prompt": "a tree"}).has("error"), "missing resource_path errors")

func test_invalid_extension():
	var result: Dictionary = _tools._tool_generate_3d_asset({"prompt": "a tree", "resource_path": "res://model.png"})
	assert_true(result.has("error"), "non-glTF extension errors")

func test_unknown_preset():
	var result: Dictionary = _tools._tool_generate_3d_asset({"prompt": "a tree", "resource_path": "res://model.glb", "preset": "nope"})
	assert_true(result.has("error"), "unknown preset errors")

func test_unconfigured_when_no_preset_or_endpoint():
	var result: Dictionary = _tools._tool_generate_3d_asset({"prompt": "a tree", "resource_path": "res://model.glb"})
	assert_eq(str(result.get("status", "")), "unconfigured", "no preset/endpoint -> unconfigured")
	assert_eq(str(result.get("category", "")), "model3d", "unconfigured result carries category")

func test_missing_env_var_errors_before_any_http():
	# A preset is selected but its API key env var is unset, so the tool must
	# error out before attempting any network request.
	var key_env: String = "MESHY_API_KEY"
	var had: bool = OS.has_environment(key_env)
	if had:
		# Don't clobber a real key if the test host happens to have one set.
		pass
	else:
		var result: Dictionary = _tools._tool_generate_3d_asset({"prompt": "a tree", "resource_path": "res://model.glb", "preset": "meshy_text_to_3d"})
		assert_true(result.has("error"), "missing env var errors")
		assert_true(str(result["error"]).find(key_env) != -1, "error names the missing env var")

# --- _resolve_3d_config ---------------------------------------------------

func test_resolve_config_meshy_preset():
	var cfg: Dictionary = _tools._resolve_3d_config({"preset": "meshy_text_to_3d"})
	assert_false(cfg.has("error"), "meshy preset resolves")
	assert_eq(str(cfg["preset"]), "meshy_text_to_3d", "preset id recorded")
	assert_eq(str(cfg["task_id_field"]), "result", "meshy task id field")
	assert_eq(str(cfg["status_field"]), "status", "meshy status field")
	assert_true(str(cfg["status_endpoint"]).find("{task_id}") != -1, "status endpoint has task_id placeholder")
	assert_true("SUCCEEDED" in (cfg["success_values"] as Array), "meshy success value")
	assert_eq(str(cfg["api_key_env"]), "MESHY_API_KEY", "meshy key env")

func test_resolve_config_tripo_preset():
	var cfg: Dictionary = _tools._resolve_3d_config({"preset": "tripo_text_to_3d"})
	assert_false(cfg.has("error"), "tripo preset resolves")
	assert_eq(str(cfg["task_id_field"]), "data.task_id", "tripo nested task id field")
	assert_eq(str(cfg["status_field"]), "data.status", "tripo nested status field")
	assert_true((cfg["model_url_fields"] as Array).size() >= 1, "tripo has model url fields")

func test_resolve_config_explicit_overrides_preset():
	var cfg: Dictionary = _tools._resolve_3d_config({
		"preset": "meshy_text_to_3d",
		"submit_endpoint": "https://example.com/submit",
		"status_endpoint": "https://example.com/status/{task_id}",
		"task_id_field": "id",
		"api_key_env": "CUSTOM_KEY"
	})
	assert_eq(str(cfg["submit_endpoint"]), "https://example.com/submit", "explicit submit_endpoint wins")
	assert_eq(str(cfg["task_id_field"]), "id", "explicit task_id_field wins")
	assert_eq(str(cfg["api_key_env"]), "CUSTOM_KEY", "explicit api_key_env wins")

func test_resolve_config_explicit_no_key_opts_out():
	var cfg: Dictionary = _tools._resolve_3d_config({"preset": "meshy_text_to_3d", "api_key_env": ""})
	assert_eq(str(cfg["api_key_env"]), "", "empty api_key_env opts out of auth")

# --- _json_path_value -----------------------------------------------------

func test_json_path_simple():
	var r: Dictionary = _tools._json_path_value({"result": "abc"}, "result")
	assert_false(r.has("error"), "simple path resolves")
	assert_eq(str(r["value"]), "abc", "value extracted")

func test_json_path_nested():
	var r: Dictionary = _tools._json_path_value({"data": {"task_id": "t-1"}}, "data.task_id")
	assert_eq(str(r["value"]), "t-1", "nested path extracted")

func test_json_path_array_index():
	var r: Dictionary = _tools._json_path_value({"items": ["x", "y"]}, "items.1")
	assert_eq(str(r["value"]), "y", "array index path extracted")

func test_json_path_missing():
	var r: Dictionary = _tools._json_path_value({"a": 1}, "b.c")
	assert_true(r.has("error"), "missing path errors")

# --- _status_matches ------------------------------------------------------

func test_status_matches_case_insensitive():
	assert_true(_tools._status_matches("SUCCEEDED", ["succeeded"]), "case-insensitive success match")
	assert_true(_tools._status_matches("failed", ["FAILED", "EXPIRED"]), "case-insensitive failure match")
	assert_false(_tools._status_matches("PENDING", ["SUCCEEDED", "FAILED"]), "no spurious match")

# --- _validate_gltf_bytes -------------------------------------------------

func test_validate_glb_magic():
	var bytes: PackedByteArray = PackedByteArray([0x67, 0x6C, 0x54, 0x46, 0x02, 0x00, 0x00, 0x00])
	assert_true(_tools._validate_gltf_bytes(bytes), "GLB magic accepted")

func test_validate_gltf_json():
	var bytes: PackedByteArray = "  {\"asset\":{}}".to_utf8_buffer()
	assert_true(_tools._validate_gltf_bytes(bytes), "JSON glTF accepted")

func test_validate_rejects_garbage():
	var bytes: PackedByteArray = "not a model".to_utf8_buffer()
	assert_false(_tools._validate_gltf_bytes(bytes), "garbage rejected")

func test_validate_rejects_short():
	assert_false(_tools._validate_gltf_bytes(PackedByteArray([0x67])), "too-short rejected")

# --- _url_host ------------------------------------------------------------

func test_url_host():
	assert_eq(_tools._url_host("https://assets.meshy.ai/path/model.glb"), "assets.meshy.ai", "host parsed")
	assert_eq(_tools._url_host("not-a-url"), "", "no scheme -> empty host")

# --- unified AsyncJobManager pipeline (pending -> poll -> cancel) ----------
# The full submit/poll/download HTTP flow still needs a live provider, but the
# async plumbing around it (job start, job_id, cooperative cancellation, result
# forwarding, main-thread finalize) is covered here offline.

func _fake_gen_cancelled_worker() -> Dictionary:
	return {"status": "cancelled", "cancelled": true, "error": "cancelled by client"}

func test_generate_3d_asset_async_pending_then_cancel():
	# A valid config (meshy preset, no key needed via api_key_env="") starts a
	# background job and returns pending; cancellation flips the job flag and
	# the worker aborts at its next check (submit HTTP round-trip is bounded by
	# timeout_sec = 1s).
	var params: Dictionary = {
		"prompt": "a low-poly tree",
		"resource_path": "res://.tmp_gen_async_test.glb",
		"preset": "meshy_text_to_3d",
		"api_key_env": "",
		"timeout_sec": 1,
		"poll_interval_sec": 1,
		"max_wait_sec": 5
	}
	var result: Dictionary = _tools._tool_generate_3d_asset(params)
	assert_eq(result.get("status"), "pending", "valid config starts a background job")
	var job_id: String = str(result.get("job_id", ""))
	assert_false(job_id.is_empty(), "pending response carries a job_id")
	assert_true(_tools._gen_job_manager.has_job(job_id), "job registered in the manager")
	assert_false(_tools._gen_job_manager.is_cancelled(job_id), "job not cancelled yet")
	_tools._gen_job_manager.cancel_job(job_id)
	assert_true(_tools._gen_job_manager.is_cancelled(job_id), "cancel flag flips after cancel_job")
	# Drain the job: the worker aborts at its next cancellation check, then the
	# registry empties (bounded wait; never asserts the network outcome).
	var deadline: int = Time.get_ticks_msec() + 10000
	while _tools._gen_job_manager.has_job(job_id) and Time.get_ticks_msec() < deadline:
		_tools._gen_job_manager.poll_job(job_id)
		OS.delay_msec(50)
	_tools._gen_job_manager.flush()
	if FileAccess.file_exists("res://.tmp_gen_async_test.glb"):
		DirAccess.remove_absolute("res://.tmp_gen_async_test.glb")
	if FileAccess.file_exists("res://.tmp_gen_async_test.glb.gen.json"):
		DirAccess.remove_absolute("res://.tmp_gen_async_test.glb.gen.json")

func test_generate_3d_asset_forwards_cancelled_worker_result():
	var params: Dictionary = {"prompt": "a tree", "resource_path": "res://.tmp_gen_cancel.glb", "preset": "meshy_text_to_3d", "api_key_env": ""}
	var cfg: Dictionary = _tools._resolve_3d_config(params)
	var key: String = _tools._generate_3d_job_key("a tree", "res://.tmp_gen_cancel.glb", cfg)
	_tools._gen_job_manager.start_job(key, Callable(self, "_fake_gen_cancelled_worker"))
	var result: Dictionary = {}
	var deadline: int = Time.get_ticks_msec() + 5000
	while Time.get_ticks_msec() < deadline:
		result = _tools._tool_generate_3d_asset(params)
		if result.get("status", "") != "pending":
			break
		OS.delay_msec(20)
	assert_eq(result.get("status"), "cancelled", "polling a cancelled generation job returns cancelled")
	assert_true(bool(result.get("cancelled", false)), "the worker's cancelled marker is forwarded")
	if FileAccess.file_exists("res://.tmp_gen_cancel.glb"):
		DirAccess.remove_absolute("res://.tmp_gen_cancel.glb")

func test_generate_3d_job_key_stable_for_same_params():
	var cfg: Dictionary = _tools._resolve_3d_config({"preset": "meshy_text_to_3d"})
	var key_a: String = _tools._generate_3d_job_key("a tree", "res://model.glb", cfg)
	var key_b: String = _tools._generate_3d_job_key("a tree", "res://model.glb", cfg)
	assert_eq(key_a, key_b, "same prompt/path/preset derive the same job key")
	var key_c: String = _tools._generate_3d_job_key("a bush", "res://model.glb", cfg)
	assert_ne(key_a, key_c, "a different prompt derives a different job key")
	var key_d: String = _tools._generate_3d_job_key("a tree", "res://other.glb", cfg)
	assert_ne(key_a, key_d, "a different output path derives a different job key")

# --- main-thread finalize (reimport + inspect) ------------------------------

func test_finalize_generate_3d_asset_merges_reimport_and_inspect():
	# In headless unit runs there is no editor interface: reimport is skipped
	# with a reason and inspect on a missing file yields inspect_error. The
	# merge must be deterministic and never resurrect _needs_finalize.
	var result: Dictionary = _tools._finalize_generate_3d_asset({
		"_needs_finalize": true,
		"status": "success",
		"resource_path": "res://.tmp_missing_model.glb",
		"size_bytes": 12
	}, {"reimport": true, "inspect": true})
	assert_false(result.has("_needs_finalize"), "finalize strips the internal marker")
	assert_eq(result.get("status"), "success", "success status preserved")
	assert_false(bool(result.get("reimported", true)), "reimport is skipped without an editor interface")
	assert_true(result.has("reimport_skipped_reason"), "skip reason recorded")
	assert_has(result, "inspect_error", "inspect on a missing file yields inspect_error")

func test_finalize_generate_3d_asset_respects_reimport_flag():
	var result: Dictionary = _tools._finalize_generate_3d_asset({
		"_needs_finalize": true,
		"status": "success",
		"resource_path": "res://.tmp_missing_model.glb"
	}, {"reimport": false, "inspect": false})
	assert_false(bool(result.get("reimported", true)), "reimport disabled by caller")
	assert_eq(str(result.get("reimport_skipped_reason", "")), "reimport disabled by caller", "explicit skip reason")
	assert_false(result.has("inspect_error") or result.has("inspection"), "inspect disabled by caller")

func test_finalize_passthrough_without_marker():
	var result: Dictionary = _tools._finalize_generate_3d_asset({"status": "failed"}, {"reimport": true, "inspect": true})
	assert_eq(result, {"status": "failed"}, "results without the finalize marker pass through unchanged")
