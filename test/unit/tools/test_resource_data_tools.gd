extends "res://addons/gut/test.gd"

# Unit tests for the Batch 1 data-driven resource tools in
# project_resources_tools.gd: create_custom_resource, batch_create_resources,
# update_resource_properties, read_resource_properties.

const TOOL_SCRIPT: String = "res://addons/godot_mcp/tools/project_resources_tools.gd"
const FIXTURE_SCRIPT: String = "res://test/unit/tools/fixtures/sample_card_data.gd"
const TMP_DIR: String = "res://.test_tmp_resource_data"

var _tools: RefCounted = null

func before_each():
	_tools = load(TOOL_SCRIPT).new()
	_cleanup_tmp_dir()

func after_each():
	_cleanup_tmp_dir()
	_tools = null

func _cleanup_tmp_dir():
	if not DirAccess.dir_exists_absolute(TMP_DIR):
		return
	var dir: DirAccess = DirAccess.open(TMP_DIR)
	if dir == null:
		return
	dir.list_dir_begin()
	var entry: String = dir.get_next()
	while entry != "":
		if not dir.current_is_dir():
			dir.remove(entry)
		entry = dir.get_next()
	dir.list_dir_end()
	DirAccess.remove_absolute(TMP_DIR)

func _tmp_path(file_name: String) -> String:
	return TMP_DIR.path_join(file_name)

# --- create_custom_resource -------------------------------------------------

func test_create_custom_resource_missing_path():
	var result: Dictionary = _tools._tool_create_custom_resource({})
	assert_has(result, "error", "Missing resource_path should return an error")

func test_create_custom_resource_unknown_type():
	var result: Dictionary = _tools._tool_create_custom_resource({
		"resource_path": _tmp_path("nope.tres"),
		"resource_type": "ThisClassDoesNotExist"
	})
	assert_has(result, "error", "Unknown type should return an error")

func test_create_custom_resource_with_script_path():
	var path: String = _tmp_path("strike.tres")
	var result: Dictionary = _tools._tool_create_custom_resource({
		"resource_path": path,
		"script_path": FIXTURE_SCRIPT,
		"properties": {"title": "Strike", "cost": 1, "damage": 6, "tags": ["attack"]}
	})
	assert_eq(result.get("status"), "success", "Should create the resource")
	assert_true(ResourceLoader.exists(path), "Resource file should exist on disk")
	assert_true("damage" in result.get("applied_properties", []), "damage should be applied")
	var loaded: Resource = ResourceLoader.load(path)
	assert_eq(loaded.get("title"), "Strike", "title should round-trip")
	assert_eq(loaded.get("cost"), 1, "cost should round-trip")
	assert_eq(loaded.get("damage"), 6, "damage should round-trip")

func test_create_custom_resource_skips_unknown_property():
	var result: Dictionary = _tools._tool_create_custom_resource({
		"resource_path": _tmp_path("skip.tres"),
		"script_path": FIXTURE_SCRIPT,
		"properties": {"cost": 2, "no_such_field": 99}
	})
	assert_eq(result.get("status"), "success", "Should still succeed")
	assert_true("cost" in result.get("applied_properties", []), "cost should be applied")
	assert_true("no_such_field" in result.get("skipped_properties", []), "unknown prop should be skipped")

func test_create_custom_resource_builtin_type_still_supported():
	var path: String = _tmp_path("plain.tres")
	var result: Dictionary = _tools._tool_create_custom_resource({
		"resource_path": path,
		"resource_type": "Resource"
	})
	assert_eq(result.get("status"), "success", "Built-in Resource type should still work")
	assert_true(ResourceLoader.exists(path), "Built-in resource file should exist")

# --- batch_create_resources -------------------------------------------------

func test_batch_create_resources_empty():
	var result: Dictionary = _tools._tool_batch_create_resources({"resources": []})
	assert_has(result, "error", "Empty resources should return an error")

func test_batch_create_resources_creates_multiple():
	var result: Dictionary = _tools._tool_batch_create_resources({
		"base_path": TMP_DIR,
		"script_path": FIXTURE_SCRIPT,
		"properties": {"cost": 1},
		"resources": [
			{"name": "card_a", "properties": {"title": "A", "damage": 4}},
			{"name": "card_b", "properties": {"title": "B", "damage": 8, "cost": 2}},
			{"name": "card_c.tres", "properties": {"title": "C"}}
		]
	})
	assert_eq(result.get("status"), "success", "All items should succeed")
	assert_eq(result.get("created_count"), 3, "Should create 3 resources")
	var card_b: Resource = ResourceLoader.load(_tmp_path("card_b.tres"))
	assert_eq(card_b.get("damage"), 8, "Per-item property should apply")
	assert_eq(card_b.get("cost"), 2, "Per-item override should beat shared default")
	var card_a: Resource = ResourceLoader.load(_tmp_path("card_a.tres"))
	assert_eq(card_a.get("cost"), 1, "Shared default property should apply when not overridden")

func test_batch_create_resources_reports_failures():
	var result: Dictionary = _tools._tool_batch_create_resources({
		"base_path": TMP_DIR,
		"script_path": FIXTURE_SCRIPT,
		"resources": [
			{"name": "ok_card", "properties": {"title": "OK"}},
			{"properties": {"title": "no path or name"}}
		]
	})
	assert_eq(result.get("status"), "partial", "Mixed result should be partial")
	assert_eq(result.get("created_count"), 1, "One item should succeed")
	assert_eq(result.get("failed_count"), 1, "One item should fail")

# --- update_resource_properties ---------------------------------------------

func test_update_resource_properties_missing_params():
	var result: Dictionary = _tools._tool_update_resource_properties({"resource_path": _tmp_path("x.tres")})
	assert_has(result, "error", "Missing properties should return an error")

func test_update_resource_properties_missing_file():
	var result: Dictionary = _tools._tool_update_resource_properties({
		"resource_path": _tmp_path("does_not_exist.tres"),
		"properties": {"cost": 3}
	})
	assert_has(result, "error", "Nonexistent resource should return an error")

func test_update_resource_properties_changes_values():
	var path: String = _tmp_path("update_me.tres")
	_tools._tool_create_custom_resource({
		"resource_path": path,
		"script_path": FIXTURE_SCRIPT,
		"properties": {"title": "Old", "cost": 1}
	})
	var result: Dictionary = _tools._tool_update_resource_properties({
		"resource_path": path,
		"properties": {"cost": 9, "title": "New"}
	})
	assert_eq(result.get("status"), "success", "Update should succeed")
	assert_true("cost" in result.get("updated_properties", []), "cost should be updated")
	var reloaded: Resource = ResourceLoader.load(path)
	assert_eq(reloaded.get("cost"), 9, "cost should be persisted")
	assert_eq(reloaded.get("title"), "New", "title should be persisted")

# --- read_resource_properties -----------------------------------------------

func test_read_resource_properties_missing_file():
	var result: Dictionary = _tools._tool_read_resource_properties({"resource_path": _tmp_path("ghost.tres")})
	assert_has(result, "error", "Nonexistent resource should return an error")

func test_read_resource_properties_returns_exported():
	var path: String = _tmp_path("read_me.tres")
	_tools._tool_create_custom_resource({
		"resource_path": path,
		"script_path": FIXTURE_SCRIPT,
		"properties": {"title": "Reader", "cost": 4, "tags": ["skill"], "anchor": {"x": 2, "y": 3}}
	})
	var result: Dictionary = _tools._tool_read_resource_properties({"resource_path": path})
	assert_eq(result.get("status"), "success", "Read should succeed")
	var props: Dictionary = result.get("properties", {})
	assert_eq(props.get("title"), "Reader", "Should read title")
	assert_eq(props.get("cost"), 4, "Should read cost")
	assert_eq(props.get("tags"), ["skill"], "Should read array property")
	assert_eq(props.get("anchor"), {"x": 2.0, "y": 3.0}, "Vector2 should serialize to x/y dict")
	assert_eq(result.get("script_path"), FIXTURE_SCRIPT, "Should report the backing script path")
	assert_true(result.get("property_count", 0) >= 5, "Should report exported property count")
