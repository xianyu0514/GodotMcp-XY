extends "res://addons/gut/test.gd"

const TRACKER_SCRIPT = preload("res://addons/godot_mcp/native_mcp/cache_change_tracker.gd")


func test_precise_reload_and_filesystem_event_coalesce_without_fallback() -> void:
	var tracker = TRACKER_SCRIPT.new()
	tracker.seed_paths(PackedStringArray([
		"res://scripts/player.gd", "res://levels/main.tscn"
	]))
	tracker.queue_paths(PackedStringArray(["res:\\scripts\\player.gd"]))
	tracker.queue_filesystem_snapshot(PackedStringArray([
		"res://scripts/player.gd", "res://levels/main.tscn"
	]))

	var batch: Dictionary = tracker.flush()
	assert_eq(batch.get("paths", PackedStringArray()),
		PackedStringArray(["res://scripts/player.gd"]))
	assert_true(batch.get("structural_paths", PackedStringArray()).is_empty())
	assert_false(bool(batch.get("filesystem_fallback", true)),
		"A known reload path explains the generic filesystem signal")
	assert_true(bool(batch.get("has_changes", false)))


func test_filesystem_snapshot_diff_reports_added_and_deleted_paths() -> void:
	var tracker = TRACKER_SCRIPT.new()
	tracker.seed_paths(PackedStringArray([
		"res://scripts/removed.gd", "res://levels/kept.tscn"
	]))
	tracker.queue_filesystem_snapshot(PackedStringArray([
		"res://levels/kept.tscn", "res://art/added.png"
	]))

	var batch: Dictionary = tracker.flush()
	var expected: PackedStringArray = PackedStringArray([
		"res://art/added.png", "res://scripts/removed.gd"
	])
	assert_eq(batch.get("paths", PackedStringArray()), expected)
	assert_eq(batch.get("structural_paths", PackedStringArray()), expected)
	assert_false(bool(batch.get("filesystem_fallback", true)),
		"A structural diff provides exact paths for catalog invalidation")


func test_unexplained_filesystem_event_uses_safe_fallback() -> void:
	var tracker = TRACKER_SCRIPT.new()
	var paths: PackedStringArray = PackedStringArray(["res://levels/main.tscn"])
	tracker.seed_paths(paths)
	tracker.queue_filesystem_snapshot(paths)

	var batch: Dictionary = tracker.flush()
	assert_true(bool(batch.get("filesystem_fallback", false)),
		"An editor save with no path-bearing companion signal must fail safe")
	assert_true(bool(batch.get("has_changes", false)))


func test_duplicate_events_normalize_once_and_flush_resets_batch() -> void:
	var tracker = TRACKER_SCRIPT.new()
	tracker.queue_paths(PackedStringArray([
		"res:\\art\\hero.png", "res://art/hero.png"
	]), true)
	tracker.queue_sources_changed()
	tracker.queue_script_classes_updated()
	tracker.queue_project_settings_changed()

	var batch: Dictionary = tracker.flush()
	assert_eq(batch.get("paths", PackedStringArray()),
		PackedStringArray(["res://art/hero.png"]))
	assert_true(bool(batch.get("reimported", false)))
	assert_true(bool(batch.get("sources_changed", false)))
	assert_true(bool(batch.get("script_classes_updated", false)))
	assert_true(bool(batch.get("project_settings_changed", false)))
	assert_false(bool(tracker.flush().get("has_changes", true)),
		"Flushing consumes the coalesced event batch exactly once")
