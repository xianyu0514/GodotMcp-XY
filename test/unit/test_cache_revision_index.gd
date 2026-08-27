extends "res://addons/gut/test.gd"

const INDEX_SCRIPT = preload("res://addons/godot_mcp/native_mcp/cache_revision_index.gd")


func test_every_cacheable_read_has_dependencies() -> void:
	for tool_name in INDEX_SCRIPT.CACHEABLE_READ_TOOLS:
		var tags: Array[String] = INDEX_SCRIPT.read_tags(tool_name, {})
		assert_false(tags.is_empty(), "%s must declare at least one cache dependency" % tool_name)


func test_script_reads_are_scoped_by_normalized_path() -> void:
	var tags: Array[String] = INDEX_SCRIPT.read_tags("read_script", {
		"script_path": "res:\\scripts\\player.gd"
	})
	assert_has(tags, INDEX_SCRIPT.TAG_SCRIPT_ALL)
	assert_has(tags, "script:res://scripts/player.gd")


func test_exact_script_write_does_not_advance_script_wildcard() -> void:
	var tags: Array[String] = INDEX_SCRIPT.mutation_tags(
		"modify_script", "Script", {"script_path": "res://scripts/player.gd"})
	assert_has(tags, "script:res://scripts/player.gd")
	assert_has(tags, INDEX_SCRIPT.TAG_SCRIPT_AGGREGATE)
	assert_does_not_have(tags, INDEX_SCRIPT.TAG_SCRIPT_ALL)


func test_unknown_mutation_fails_safe_to_global_revision() -> void:
	var tags: Array[String] = INDEX_SCRIPT.mutation_tags("plugin_defined_writer", "Custom", {})
	assert_eq(tags, [INDEX_SCRIPT.TAG_GLOBAL])


func test_runtime_mutations_do_not_dirty_project_domains() -> void:
	var tags: Array[String] = INDEX_SCRIPT.mutation_tags(
		"update_runtime_node_property", "Debug-Advanced", {})
	assert_true(tags.is_empty(), "Runtime-only changes must preserve editor/project read caches")


func test_revision_snapshot_only_expires_for_watched_tags() -> void:
	var index = INDEX_SCRIPT.new()
	var script_snapshot: Dictionary = index.snapshot([INDEX_SCRIPT.TAG_SCRIPT_ALL, "script:res://a.gd"])
	index.advance([INDEX_SCRIPT.TAG_SCENE_CONTENT])
	assert_true(index.is_current(script_snapshot), "Unrelated scene changes keep script snapshots current")
	index.advance(["script:res://a.gd"])
	assert_false(index.is_current(script_snapshot), "The matching script path expires its snapshot")


func test_render_configuration_invalidates_project_settings_not_resource_catalog() -> void:
	var tags: Array[String] = INDEX_SCRIPT.mutation_tags(
		"configure_render_output", "Project-Advanced", {"hdr_2d": true})
	assert_has(tags, INDEX_SCRIPT.TAG_PROJECT_SETTINGS)
	assert_does_not_have(tags, INDEX_SCRIPT.TAG_RESOURCE_CATALOG)


func test_localization_write_uses_safe_multi_resource_impact() -> void:
	var tags: Array[String] = INDEX_SCRIPT.mutation_tags(
		"manage_localization", "Project-Advanced", {"action": "import"})
	assert_has(tags, INDEX_SCRIPT.TAG_PROJECT_SETTINGS)
	assert_has(tags, INDEX_SCRIPT.TAG_RESOURCE_ALL)
	assert_has(tags, INDEX_SCRIPT.TAG_RESOURCE_CATALOG)


func test_resource_creation_uses_exact_output_path_when_available() -> void:
	var tags: Array[String] = INDEX_SCRIPT.mutation_tags(
		"create_animation", "Project-Advanced", {"animation_path": "res://anim/walk.tres"})
	assert_has(tags, "resource:res://anim/walk.tres")
	assert_does_not_have(tags, INDEX_SCRIPT.TAG_RESOURCE_ALL)


func test_cross_file_scans_watch_single_file_aggregate_revisions() -> void:
	var expectations: Array = [
		["find_resource_usages", INDEX_SCRIPT.TAG_RESOURCE_AGGREGATE],
		["find_resource_usages", INDEX_SCRIPT.TAG_SCRIPT_AGGREGATE],
		["list_unused_resources", INDEX_SCRIPT.TAG_RESOURCE_AGGREGATE],
		["scan_migration_compatibility", INDEX_SCRIPT.TAG_SCRIPT_AGGREGATE],
		["find_deprecated_api_usage", INDEX_SCRIPT.TAG_SCRIPT_AGGREGATE],
	]
	for expectation in expectations:
		var tool_name: String = expectation[0]
		var changed_tag: String = expectation[1]
		var index = INDEX_SCRIPT.new()
		var snapshot: Dictionary = index.snapshot(INDEX_SCRIPT.read_tags(tool_name, {}))
		index.advance([changed_tag])
		assert_false(index.is_current(snapshot),
			"%s must expire after %s changes" % [tool_name, changed_tag])


func test_external_script_reload_uses_exact_path_without_script_wildcard() -> void:
	var tags: Array[String] = INDEX_SCRIPT.external_change_tags({
		"paths": PackedStringArray(["res:\\scripts\\player.gd"])
	})
	assert_has(tags, "script:res://scripts/player.gd")
	assert_has(tags, INDEX_SCRIPT.TAG_SCRIPT_AGGREGATE)
	assert_has(tags, "resource:res://scripts/player.gd")
	assert_does_not_have(tags, INDEX_SCRIPT.TAG_SCRIPT_ALL,
		"Known external paths must preserve unrelated script reads")
	assert_does_not_have(tags, INDEX_SCRIPT.TAG_RESOURCE_ALL,
		"Known external paths must preserve unrelated resource reads")


func test_external_structural_changes_advance_only_relevant_catalogs() -> void:
	var tags: Array[String] = INDEX_SCRIPT.external_change_tags({
		"paths": PackedStringArray([
			"res://scripts/new_player.gd",
			"res://levels/removed_level.tscn",
			"res://art/new_icon.png"
		]),
		"structural_paths": PackedStringArray([
			"res://scripts/new_player.gd",
			"res://levels/removed_level.tscn",
			"res://art/new_icon.png"
		])
	})
	assert_has(tags, INDEX_SCRIPT.TAG_SCRIPT_CATALOG)
	assert_has(tags, INDEX_SCRIPT.TAG_SCENE_CATALOG)
	assert_has(tags, INDEX_SCRIPT.TAG_RESOURCE_CATALOG)
	assert_has(tags, INDEX_SCRIPT.TAG_PROJECT_TREE)
	assert_has(tags, INDEX_SCRIPT.TAG_SCENE_CONTENT)
	assert_does_not_have(tags, INDEX_SCRIPT.TAG_GLOBAL,
		"A structural file diff is still narrower than global invalidation")


func test_external_reimport_and_project_signals_map_to_owned_domains() -> void:
	var tags: Array[String] = INDEX_SCRIPT.external_change_tags({
		"paths": PackedStringArray(["res://art/hero.png"]),
		"reimported": true,
		"script_classes_updated": true,
		"project_settings_changed": true
	})
	assert_has(tags, "resource:res://art/hero.png")
	assert_has(tags, INDEX_SCRIPT.TAG_IMPORT_STATE)
	assert_has(tags, INDEX_SCRIPT.TAG_SCRIPT_AGGREGATE)
	assert_has(tags, INDEX_SCRIPT.TAG_SCRIPT_CATALOG)
	assert_has(tags, INDEX_SCRIPT.TAG_PROJECT_SETTINGS)


func test_pathless_filesystem_event_fails_safe_without_tool_catalog_churn() -> void:
	var tags: Array[String] = INDEX_SCRIPT.external_change_tags({
		"filesystem_fallback": true
	})
	assert_has(tags, INDEX_SCRIPT.TAG_SCRIPT_ALL)
	assert_has(tags, INDEX_SCRIPT.TAG_RESOURCE_ALL)
	assert_has(tags, INDEX_SCRIPT.TAG_SCENE_CONTENT)
	assert_has(tags, INDEX_SCRIPT.TAG_PROJECT_SETTINGS)
	assert_does_not_have(tags, INDEX_SCRIPT.TAG_TOOL_CATALOG,
		"Unknown file changes must not rebuild immutable tool discovery state")
	assert_does_not_have(tags, INDEX_SCRIPT.TAG_GLOBAL,
		"Fallback remains bounded to file-backed dependency domains")
