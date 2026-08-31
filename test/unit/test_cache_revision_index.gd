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

func test_whole_project_script_reads_depend_on_script_aggregate() -> void:
	# verify_scripts 等全项目脚本读必须挂在 SCRIPT_AGGREGATE（modify_script/
	# create_script/外部文件事件都会推进它）；不能挂 SCRIPT_ALL——
	# modify_script 刻意不推进 ALL，单文件修复后的缓存会变陈旧。
	for tool_name in ["verify_scripts", "detect_broken_scripts",
			"list_project_script_symbols", "find_script_symbol_references"]:
		var tags: Array[String] = INDEX_SCRIPT.read_tags(tool_name, {})
		assert_has(tags, INDEX_SCRIPT.TAG_SCRIPT_AGGREGATE, tool_name)
		assert_does_not_have(tags, INDEX_SCRIPT.TAG_SCRIPT_ALL, tool_name)

func test_modify_script_invalidates_cached_verify_scripts() -> void:
	var index = INDEX_SCRIPT.new()
	var snapshot: Dictionary = index.snapshot(
		INDEX_SCRIPT.read_tags("verify_scripts", {}))
	index.advance(INDEX_SCRIPT.mutation_tags("modify_script", "Script",
		{"script_path": "res://scripts/player.gd"}))
	assert_false(index.is_current(snapshot),
		"a script repair must invalidate the cached whole-project verify")

func test_health_scan_reads_depend_on_resource_and_script_aggregates() -> void:
	for tool_name in ["audit_project_health", "scan_missing_resource_dependencies",
			"scan_cyclic_resource_dependencies"]:
		var tags: Array[String] = INDEX_SCRIPT.read_tags(tool_name, {})
		assert_has(tags, INDEX_SCRIPT.TAG_RESOURCE_AGGREGATE, tool_name)
		assert_has(tags, INDEX_SCRIPT.TAG_SCRIPT_AGGREGATE, tool_name)

func test_export_preset_reads_track_the_config_file() -> void:
	for tool_name in ["list_export_presets", "inspect_export_presets", "validate_export_preset"]:
		var tags: Array[String] = INDEX_SCRIPT.read_tags(tool_name, {})
		assert_has(tags, "resource:res://export_presets.cfg", tool_name)
	# 预设 CRUD 工具属于未特判分组，回退推进 GLOBAL——所有快照都含 GLOBAL，
	# 因此 CRUD 后这三个读必然失效（不会拿到陈旧的预设列表）。
	var index = INDEX_SCRIPT.new()
	var snapshot: Dictionary = index.snapshot(
		INDEX_SCRIPT.read_tags("inspect_export_presets", {}))
	index.advance(INDEX_SCRIPT.mutation_tags("create_export_preset", "Project-Advanced", {}))
	assert_false(index.is_current(snapshot), "preset CRUD must invalidate preset reads")

func test_inspect_tileset_resource_is_scoped_by_path() -> void:
	var tags: Array[String] = INDEX_SCRIPT.read_tags("inspect_tileset_resource", {
		"resource_path": "res://tilesets/ground.tres"})
	assert_has(tags, "resource:res://tilesets/ground.tres")

func test_import_status_is_time_domain_and_never_cached() -> void:
	# get_import_status 汇报的是编辑器实时扫描进度——revision 标签无法跟踪
	# 时间域状态，缓存它会让轮询方拿到冻结的 busy/progress 长达 TTL 窗口。
	assert_false("get_import_status" in INDEX_SCRIPT.CACHEABLE_READ_TOOLS)

func test_read_resource_properties_ignores_script_domain() -> void:
	var tags: Array[String] = INDEX_SCRIPT.read_tags("read_resource_properties", {
		"resource_path": "res://cards/strike.tres"})
	assert_does_not_have(tags, INDEX_SCRIPT.TAG_SCRIPT_AGGREGATE,
		"unrelated script edits must not kill per-resource cache hits")

func test_unused_resources_depend_on_script_owners() -> void:
	# 脚本里的 preload/load 决定资源是否被使用：modify_script 后必须重算。
	var tags: Array[String] = INDEX_SCRIPT.read_tags("list_unused_resources", {})
	assert_has(tags, INDEX_SCRIPT.TAG_SCRIPT_AGGREGATE)

func test_android_export_config_invalidates_preset_reads() -> void:
	# configure_android_export 改写 export_presets.cfg：预设读必须看到新配置。
	var index = INDEX_SCRIPT.new()
	var snapshot: Dictionary = index.snapshot(
		INDEX_SCRIPT.read_tags("inspect_export_presets", {}))
	index.advance(INDEX_SCRIPT.mutation_tags("configure_android_export", "Editor-Advanced", {}))
	assert_false(index.is_current(snapshot),
		"android config write must invalidate the preset-read cache")

func test_scene_writes_invalidate_resource_aggregate_reads() -> void:
	# 存盘 .tscn 改变 ext_resource 集合：scan_missing/audit/search(.tscn) 必须重扫。
	for tool_name in ["create_scene", "save_scene", "save_branch_as_scene"]:
		var index = INDEX_SCRIPT.new()
		var snapshot: Dictionary = index.snapshot(
			INDEX_SCRIPT.read_tags("scan_missing_resource_dependencies", {}))
		index.advance(INDEX_SCRIPT.mutation_tags(tool_name, "Scene-Basic", {}))
		assert_false(index.is_current(snapshot),
			"%s must invalidate dependency-scan reads" % tool_name)

func test_attach_script_invalidates_unused_resource_reads() -> void:
	var index = INDEX_SCRIPT.new()
	var snapshot: Dictionary = index.snapshot(
		INDEX_SCRIPT.read_tags("list_unused_resources", {}))
	index.advance(INDEX_SCRIPT.mutation_tags("attach_script", "Script-Basic", {}))
	assert_false(index.is_current(snapshot),
		"a newly referenced script is no longer unused")
