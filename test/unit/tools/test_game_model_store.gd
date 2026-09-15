extends "res://addons/gut/test.gd"

## P1-1 游戏模型存储测试：数量核算（总量/增量）、参数注入、指纹漂移
## 检测（用户手改保护的事实来源）、脚本事实解析。

const GameModelStoreScript = preload("res://addons/godot_mcp/tools/game_model_store.gd")

var _model_path: String

func before_each() -> void:
	_model_path = "user://game_model_test_%s.json" % str(get_instance_id())
	_remove_model()

func after_each() -> void:
	_remove_model()

func _remove_model() -> void:
	var absolute: String = ProjectSettings.globalize_path(_model_path)
	if FileAccess.file_exists(absolute):
		DirAccess.remove_absolute(absolute)

func test_parse_script_facts_reads_counts_and_params() -> void:
	var facts: Dictionary = GameModelStoreScript.parse_script_facts(
		"const COINS_TO_WIN: int = 3\nconst ENEMY_COUNT: int = 2\n" \
		+ "const SPEED: float = 260.0\nconst ENEMY_SPEED: float = 80.0\n" \
		+ "const COIN_RADIUS: float = 60.0\n")
	assert_eq(int((facts["counts"] as Dictionary).get("coins", 0)), 3, "coin count parsed from disk truth")
	assert_eq(int((facts["counts"] as Dictionary).get("enemies", 0)), 2, "enemy count parsed")
	assert_eq(float((facts["params"] as Dictionary).get("ENEMY_SPEED", 0.0)), 80.0, "tuned enemy speed parsed")
	assert_eq(float((facts["params"] as Dictionary).get("COIN_RADIUS", 0.0)), 60.0, "pickup radius parsed")

func test_parse_script_facts_missing_consts_absent() -> void:
	var facts: Dictionary = GameModelStoreScript.parse_script_facts("const SPEED: float = 200.0\n")
	assert_false((facts["counts"] as Dictionary).has("coins"), "no coin const -> no count entry")
	assert_true((facts["params"] as Dictionary).has("SPEED"), "present param recorded")

func test_merged_count_total_request_uses_max() -> void:
	GameModelStoreScript.save_model({"counts": {"coins": 1, "enemies": 1}}, _model_path)
	assert_eq(GameModelStoreScript.merged_count("coins", 3, false, _model_path), 3,
		"total request: max(1,3) — ask for 3, get 3")
	assert_eq(GameModelStoreScript.merged_count("coins", 0, false, _model_path), 1,
		"goal without a number never shrinks the existing count")
	assert_eq(GameModelStoreScript.merged_count("coins", 1, false, _model_path), 1,
		"same total keeps the existing count")

func test_merged_count_additive_request_accumulates() -> void:
	GameModelStoreScript.save_model({"counts": {"coins": 1, "enemies": 1}}, _model_path)
	assert_eq(GameModelStoreScript.merged_count("coins", 3, true, _model_path), 4,
		"'add 3 more coins': 1 existing + 3 requested")
	assert_eq(GameModelStoreScript.merged_count("enemies", 1, true, _model_path), 2,
		"'another enemy': 1 existing + 1")

func test_merged_count_empty_model_defaults_to_request() -> void:
	assert_eq(GameModelStoreScript.merged_count("coins", 3, false, _model_path), 3,
		"movement-only prior state: 0 existing, 3 requested -> 3 (gap-analysis case)")
	assert_eq(GameModelStoreScript.merged_count("coins", 3, true, _model_path), 3,
		"additive on empty model is still 3")

func test_apply_param_overrides_injects_tuned_values() -> void:
	GameModelStoreScript.save_model({"params": {"ENEMY_SPEED": 80.0}}, _model_path)
	var source: String = "const SPEED: float = 260.0\nconst ENEMY_SPEED: float = 120.0\nconst COIN_RADIUS: float = 90.0\n"
	var tuned: String = GameModelStoreScript.apply_param_overrides(source, _model_path)
	assert_true(tuned.contains("const ENEMY_SPEED: float = 80.0"),
		"tuned enemy speed survives cumulative regeneration")
	assert_true(tuned.contains("const SPEED: float = 260.0"),
		"untuned params keep blueprint defaults")

func test_apply_param_overrides_ignores_default_valued_records() -> void:
	GameModelStoreScript.save_model({"params": {"SPEED": 260.0, "ENEMY_SPEED": 120.0}}, _model_path)
	var source: String = "const ENEMY_SPEED: float = 120.0\n"
	assert_eq(GameModelStoreScript.apply_param_overrides(source, _model_path), source,
		"records equal to blueprint defaults produce no source noise")

func test_has_user_edits_requires_fingerprint_drift() -> void:
	var script_path: String = "user://game_model_script_%s.gd" % str(get_instance_id())
	var absolute: String = ProjectSettings.globalize_path(script_path)
	var file: FileAccess = FileAccess.open(absolute, FileAccess.WRITE)
	file.store_string("# controller\nconst SPEED: float = 260.0\n")
	file.close()
	GameModelStoreScript.apply_completion("movement goal", {"movement": true},
		script_path, "# controller\nconst SPEED: float = 260.0\n", _model_path)
	assert_false(GameModelStoreScript.has_user_edits(script_path, _model_path),
		"no drift right after recorded completion")
	var edit: FileAccess = FileAccess.open(absolute, FileAccess.WRITE)
	edit.store_string("# controller + user tweaks\nconst SPEED: float = 300.0\n")
	edit.close()
	assert_true(GameModelStoreScript.has_user_edits(script_path, _model_path),
		"fingerprint drift after a manual edit is detected")
	DirAccess.remove_absolute(absolute)

func test_has_user_edits_unknown_path_is_not_conflict() -> void:
	assert_false(GameModelStoreScript.has_user_edits("res://scripts/never_created_xyz.gd", _model_path),
		"no record for the path -> cannot judge -> do not block")

func test_apply_completion_records_facts_and_history() -> void:
	var result: Dictionary = GameModelStoreScript.apply_completion(
		"collect 3 coins", {"collectible": true}, "res://scripts/none.gd",
		"const COINS_TO_WIN: int = 3\n", _model_path)
	assert_eq(int((result["counts"] as Dictionary).get("coins", 0)), 3, "counts recorded")
	var model: Dictionary = GameModelStoreScript.load_model(_model_path)
	assert_eq((model.get("history", []) as Array).size(), 1, "history entry appended")
	assert_true(String(model.get("script_path", "")) == "res://scripts/none.gd", "script path recorded")

func test_current_param_value_reads_disk_truth() -> void:
	assert_eq(GameModelStoreScript.current_param_value("const ENEMY_SPEED: float = 78.0\n", "ENEMY_SPEED"), 78.0,
		"reads the actual current value")
	assert_eq(GameModelStoreScript.current_param_value("no const here\n", "ENEMY_SPEED"), 120.0,
		"falls back to the blueprint default when the const is absent")
