extends RefCounted
## Dependency tags and monotonic revisions for the shared tool-result cache.
##
## Reads capture only the tags they depend on. Mutations advance only the tags
## they can change, so the write path is O(number of affected tags) and never
## scans the LRU. A stale entry is removed lazily when that exact key is read.

const TAG_GLOBAL: String = "global"
const TAG_TOOL_CATALOG: String = "tool_catalog"
const TAG_SCENE_CONTENT: String = "scene_content"
const TAG_SCENE_CATALOG: String = "scene_catalog"
const TAG_SCENE_TABS: String = "scene_tabs"
const TAG_SCRIPT_ALL: String = "script_all"
const TAG_SCRIPT_AGGREGATE: String = "script_aggregate"
const TAG_SCRIPT_CATALOG: String = "script_catalog"
const TAG_RESOURCE_ALL: String = "resource_all"
const TAG_RESOURCE_AGGREGATE: String = "resource_aggregate"
const TAG_RESOURCE_CATALOG: String = "resource_catalog"
const TAG_PROJECT_SETTINGS: String = "project_settings"
const TAG_PROJECT_TREE: String = "project_tree"
const TAG_IMPORT_STATE: String = "import_state"

const SCRIPT_FILE_EXTENSIONS: Array[String] = ["gd", "cs"]
const SCENE_FILE_EXTENSIONS: Array[String] = ["tscn", "scn"]

## This is the single source of truth for reads admitted to the shared result
## cache. Every name must be covered by read_tags(); a unit test enforces it.
## get_import_status is deliberately absent: it reports live editor scan
## progress (a time-domain value), which no revision tag can track.
const CACHEABLE_READ_TOOLS: Array[String] = [
	"get_scene_structure", "list_nodes", "list_project_scenes",
	"list_project_scripts", "get_project_structure", "list_open_scenes",
	"get_scene_tree", "get_node_properties", "batch_get_node_properties",
	"list_project_resources", "list_project_input_actions",
	"list_project_autoloads", "list_project_global_classes",
	"list_tool_catalog", "search_tools", "get_tool_details",
	"read_script", "batch_read_scripts", "get_project_info",
	"get_project_settings", "read_resource_properties", "get_resource_dependencies",
	"find_resource_usages", "list_unused_resources",
	"scan_migration_compatibility", "find_deprecated_api_usage",
	# Whole-project script reads: the workflow engine re-runs these after every
	# script repair round, so caching them by SCRIPT_AGGREGATE (advanced by any
	# script-domain change, unlike SCRIPT_ALL) removes repeated full compiles.
	"verify_scripts", "detect_broken_scripts", "list_project_script_symbols",
	"find_script_symbol_definition", "find_script_symbol_references",
	# Project-wide dependency/health scans (the project_health profile chains
	# all of them per round; scripts participate as dependents/dependees).
	"scan_missing_resource_dependencies", "scan_cyclic_resource_dependencies",
	"audit_project_health",
	# Content-driven lookups repeated in code-understanding loops.
	"search_in_files", "get_class_api_metadata",
	# Per-resource inspection keyed on the exact file path.
	"inspect_tileset_resource",
	# Export preset reads: export_presets.cfg is advanced precisely by the
	# resource:<path> tag on external edits and by GLOBAL on preset CRUD.
	"list_export_presets", "inspect_export_presets", "validate_export_preset",
	# Test discovery: bounded res://test scans repeated by QA loops.
	"list_project_tests", "prepare_project_test_environment"
]

const STATIC_READ_TAGS: Dictionary = {
	"get_scene_structure": [TAG_SCENE_CONTENT],
	"list_nodes": [TAG_SCENE_CONTENT],
	"get_scene_tree": [TAG_SCENE_CONTENT],
	"get_node_properties": [TAG_SCENE_CONTENT],
	"batch_get_node_properties": [TAG_SCENE_CONTENT],
	"list_project_scenes": [TAG_SCENE_CATALOG],
	"list_project_scripts": [TAG_SCRIPT_CATALOG],
	"get_project_structure": [TAG_PROJECT_TREE],
	"list_open_scenes": [TAG_SCENE_TABS],
	"list_project_resources": [TAG_RESOURCE_CATALOG],
	"list_project_input_actions": [TAG_PROJECT_SETTINGS],
	"list_project_autoloads": [TAG_PROJECT_SETTINGS],
	"list_project_global_classes": [TAG_SCRIPT_AGGREGATE, TAG_PROJECT_SETTINGS],
	"list_tool_catalog": [TAG_TOOL_CATALOG],
	"search_tools": [TAG_TOOL_CATALOG],
	"get_tool_details": [TAG_TOOL_CATALOG],
	"get_project_info": [TAG_PROJECT_SETTINGS],
	"get_project_settings": [TAG_PROJECT_SETTINGS],
	# Script owners (.gd/.cs preloads and loads) decide whether a resource is
	# unused, so script-domain changes must invalidate this read too.
	"list_unused_resources": [TAG_RESOURCE_ALL, TAG_RESOURCE_AGGREGATE,
		TAG_RESOURCE_CATALOG, TAG_PROJECT_SETTINGS, TAG_SCRIPT_AGGREGATE],
	"find_resource_usages": [TAG_RESOURCE_ALL, TAG_RESOURCE_AGGREGATE,
		TAG_RESOURCE_CATALOG, TAG_SCRIPT_ALL, TAG_SCRIPT_AGGREGATE],
	"scan_migration_compatibility": [TAG_SCRIPT_ALL, TAG_SCRIPT_AGGREGATE,
		TAG_SCRIPT_CATALOG],
	"find_deprecated_api_usage": [TAG_SCRIPT_ALL, TAG_SCRIPT_AGGREGATE,
		TAG_SCRIPT_CATALOG],
	"verify_scripts": [TAG_SCRIPT_AGGREGATE],
	"detect_broken_scripts": [TAG_SCRIPT_AGGREGATE],
	"list_project_script_symbols": [TAG_SCRIPT_AGGREGATE],
	"find_script_symbol_definition": [TAG_SCRIPT_AGGREGATE],
	"find_script_symbol_references": [TAG_SCRIPT_AGGREGATE],
	"scan_missing_resource_dependencies": [TAG_RESOURCE_AGGREGATE, TAG_SCRIPT_AGGREGATE],
	"scan_cyclic_resource_dependencies": [TAG_RESOURCE_AGGREGATE, TAG_SCRIPT_AGGREGATE],
	"audit_project_health": [TAG_RESOURCE_AGGREGATE, TAG_SCRIPT_AGGREGATE],
	"search_in_files": [TAG_RESOURCE_AGGREGATE, TAG_SCRIPT_AGGREGATE],
	"get_class_api_metadata": [TAG_SCRIPT_AGGREGATE],
	"list_export_presets": [TAG_RESOURCE_AGGREGATE, "resource:res://export_presets.cfg"],
	"inspect_export_presets": [TAG_RESOURCE_AGGREGATE, "resource:res://export_presets.cfg"],
	"validate_export_preset": [TAG_RESOURCE_AGGREGATE, "resource:res://export_presets.cfg"],
	"list_project_tests": [TAG_PROJECT_TREE, TAG_SCRIPT_CATALOG, TAG_RESOURCE_CATALOG],
	"prepare_project_test_environment": [TAG_PROJECT_TREE, TAG_SCRIPT_CATALOG, TAG_RESOURCE_CATALOG]
}

const GLOBAL_MUTATION_TOOLS: Array[String] = [
	"execute_script", "execute_editor_script", "reload_project", "undo", "redo"
]

const RUNTIME_ONLY_GROUPS: Array[String] = ["Debug", "Debug-Advanced"]

const EDITOR_ONLY_MUTATIONS: Array[String] = [
	"clear_output", "close_script_tab", "debug_print", "manage_export_templates",
	"open_script_at_line", "request_debug_break", "run_project", "select_file",
	"select_node", "set_debugger_breakpoint", "set_editor_setting", "stop_project",
	"toggle_debugger_profiler"
]

const PROJECT_SETTING_MUTATIONS: Array[String] = [
	"add_project_autoload", "configure_render_output", "remove_project_autoload",
	"remove_project_input_action", "set_default_theme", "set_project_setting",
	"upsert_project_input_action"
]

const RESOURCE_CREATE_MUTATIONS: Array[String] = [
	"batch_create_resources",
	"create_animation", "create_custom_resource", "create_drawable_texture",
	"create_gradient_texture", "create_resource", "create_theme", "create_tileset",
	"generate_3d_asset", "generate_asset", "slice_sprite_sheet"
]

const RESOURCE_UPDATE_MUTATIONS: Array[String] = [
	"configure_tileset_layers", "draw_on_texture", "fix_resource_uid",
	"insert_animation_keys",
	"set_theme_item", "set_tile_collision_polygon", "set_tile_terrain",
	"update_resource_properties"
]

var _revisions: Dictionary = {TAG_GLOBAL: 0}


## Capture the current global revision plus the exact dependency revisions.
func snapshot(tags: Array[String]) -> Dictionary:
	var result: Dictionary = {TAG_GLOBAL: int(_revisions.get(TAG_GLOBAL, 0))}
	for tag in tags:
		if tag.is_empty() or tag == TAG_GLOBAL:
			continue
		result[tag] = int(_revisions.get(tag, 0))
	return result


func is_current(revision_snapshot: Dictionary) -> bool:
	for tag_value in revision_snapshot:
		var tag: String = String(tag_value)
		if int(revision_snapshot[tag_value]) != int(_revisions.get(tag, 0)):
			return false
	return true


## Advance each tag at most once. TAG_GLOBAL invalidates every snapshot because
## all snapshots include it; it is the conservative fallback for unknown tools.
func advance(tags: Array[String]) -> void:
	var unique: Dictionary = {}
	for tag in tags:
		if not tag.is_empty():
			unique[tag] = true
	for tag_value in unique:
		var tag: String = String(tag_value)
		_revisions[tag] = int(_revisions.get(tag, 0)) + 1


func revision(tag: String) -> int:
	return int(_revisions.get(tag, 0))


static func read_tags(tool_name: String, arguments: Dictionary) -> Array[String]:
	var tags: Array[String] = []
	if STATIC_READ_TAGS.has(tool_name):
		tags.assign(STATIC_READ_TAGS[tool_name])
	match tool_name:
		"read_script":
			tags.append(TAG_SCRIPT_ALL)
			_append_path_tag(tags, "script", arguments.get("script_path", ""))
		"batch_read_scripts":
			tags.append(TAG_SCRIPT_ALL)
			for path_value in arguments.get("script_paths", []):
				_append_path_tag(tags, "script", path_value)
		"read_resource_properties":
			# 只读单个 .tres/.res：脚本域变化与其无关，不带 SCRIPT_AGGREGATE
			# 以免无关的脚本编辑白白杀掉缓存命中。
			tags.append(TAG_RESOURCE_ALL)
			_append_path_tag(tags, "resource", arguments.get("resource_path", ""))
		"inspect_tileset_resource":
			tags.append(TAG_RESOURCE_ALL)
			_append_path_tag(tags, "resource", arguments.get("resource_path", ""))
		"get_resource_dependencies":
			tags.append(TAG_RESOURCE_ALL)
			_append_path_tag(tags, "resource", arguments.get("resource_path", ""))
	return _deduplicated_sorted(tags)


## Return the smallest safe set of tags affected by a successful or partially
## successful mutation. Unknown/plugin-defined writers fall back to global.
static func mutation_tags(tool_name: String, group: String, arguments: Dictionary) -> Array[String]:
	if tool_name in GLOBAL_MUTATION_TOOLS:
		return [TAG_GLOBAL]
	if tool_name in EDITOR_ONLY_MUTATIONS:
		return []

	match tool_name:
		"enable_tools":
			# Its handler owns the catalog transition and invalidates once in bulk.
			return []
		"create_script":
			var create_tags: Array[String] = [
				TAG_SCRIPT_CATALOG, TAG_SCRIPT_AGGREGATE, TAG_RESOURCE_CATALOG, TAG_PROJECT_TREE
			]
			_append_path_tag(create_tags, "script", arguments.get("script_path", ""))
			if not str(arguments.get("attach_to_node", "")).is_empty():
				create_tags.append(TAG_SCENE_CONTENT)
			return _deduplicated_sorted(create_tags)
		"modify_script":
			var modify_tags: Array[String] = [TAG_SCRIPT_AGGREGATE]
			_append_path_tag(modify_tags, "script", arguments.get("script_path", ""))
			return _deduplicated_sorted(modify_tags)
		"rename_script_symbol", "save_all_scripts", "reload_open_scripts":
			return [TAG_SCRIPT_ALL, TAG_SCRIPT_AGGREGATE]
		"attach_script":
			return [TAG_SCENE_CONTENT]
		"create_scene":
			return [TAG_SCENE_CONTENT, TAG_SCENE_CATALOG, TAG_SCENE_TABS,
				TAG_RESOURCE_CATALOG, TAG_PROJECT_TREE]
		"open_scene", "close_scene_tab":
			return [TAG_SCENE_CONTENT, TAG_SCENE_TABS]
		"save_scene":
			return [TAG_SCENE_CATALOG, TAG_RESOURCE_CATALOG, TAG_PROJECT_TREE]
		"save_branch_as_scene":
			return [TAG_SCENE_CONTENT, TAG_SCENE_CATALOG, TAG_RESOURCE_CATALOG,
				TAG_PROJECT_TREE]
		"install_runtime_probe", "remove_runtime_probe":
			return [TAG_PROJECT_SETTINGS, TAG_PROJECT_TREE, TAG_RESOURCE_CATALOG,
				TAG_SCRIPT_ALL, TAG_SCRIPT_AGGREGATE, TAG_SCRIPT_CATALOG]
		"reimport_resources":
			return [TAG_IMPORT_STATE, TAG_RESOURCE_ALL, TAG_RESOURCE_AGGREGATE]
		"configure_android_export":
			return [TAG_PROJECT_SETTINGS, TAG_PROJECT_TREE]
		"bump_version":
			return [TAG_PROJECT_SETTINGS, TAG_PROJECT_TREE]
		"manage_localization":
			# Import/export/extract can touch many translation resources and may
			# also update internationalization/locale/translations.
			return [TAG_PROJECT_SETTINGS, TAG_PROJECT_TREE, TAG_RESOURCE_ALL,
				TAG_RESOURCE_AGGREGATE, TAG_RESOURCE_CATALOG]

	if tool_name in PROJECT_SETTING_MUTATIONS:
		return [TAG_PROJECT_SETTINGS]
	if tool_name in RESOURCE_CREATE_MUTATIONS:
		var resource_create_tags: Array[String] = [
			TAG_RESOURCE_AGGREGATE, TAG_RESOURCE_CATALOG, TAG_PROJECT_TREE
		]
		var tag_count_before_path: int = resource_create_tags.size()
		_append_first_path_tag(resource_create_tags, "resource", arguments,
			["resource_path", "output_path", "path", "animation_path", "texture_path",
				"theme_path", "tileset_path"])
		if resource_create_tags.size() == tag_count_before_path:
			resource_create_tags.append(TAG_RESOURCE_ALL)
		return _deduplicated_sorted(resource_create_tags)
	if tool_name in RESOURCE_UPDATE_MUTATIONS:
		var resource_update_tags: Array[String] = [TAG_RESOURCE_AGGREGATE]
		_append_first_path_tag(resource_update_tags, "resource", arguments,
			["resource_path", "texture_path", "tileset_path", "theme_path", "animation_path"])
		if resource_update_tags.size() == 1:
			resource_update_tags.append(TAG_RESOURCE_ALL)
		return _deduplicated_sorted(resource_update_tags)

	if group.begins_with("Node-"):
		return [TAG_SCENE_CONTENT]
	if group.begins_with("Scene"):
		return [TAG_SCENE_CONTENT]
	if group.begins_with("Script"):
		return [TAG_SCRIPT_ALL, TAG_SCRIPT_AGGREGATE]
	if group in RUNTIME_ONLY_GROUPS:
		return []
	return [TAG_GLOBAL]


## Map one coalesced batch of editor/file-system events to the smallest safe
## dependency revision set. Known paths advance exact script/resource tags;
## structural additions/removals also advance the relevant catalogs. A pathless
## filesystem event falls back to every file-backed domain, but deliberately
## preserves immutable tool discovery and runtime-only state.
static func external_change_tags(batch: Dictionary) -> Array[String]:
	var tags: Array[String] = []
	var structural_paths: Dictionary = {}
	for path_value in batch.get("structural_paths", []):
		var structural_path: String = _normalized_path(path_value)
		if not structural_path.is_empty():
			structural_paths[structural_path] = true

	for path_value in batch.get("paths", []):
		var path: String = _normalized_path(path_value)
		if path.is_empty():
			continue
		if path == "res://project.godot" or path.ends_with("/project.godot"):
			tags.append(TAG_PROJECT_SETTINGS)
			if structural_paths.has(path):
				tags.append(TAG_PROJECT_TREE)
			continue

		var extension: String = path.get_extension().to_lower()
		_append_path_tag(tags, "resource", path)
		tags.append(TAG_RESOURCE_AGGREGATE)
		if extension in SCRIPT_FILE_EXTENSIONS:
			_append_path_tag(tags, "script", path)
			tags.append(TAG_SCRIPT_AGGREGATE)
		elif extension in SCENE_FILE_EXTENSIONS:
			tags.append(TAG_SCENE_CONTENT)

		if structural_paths.has(path):
			tags.append(TAG_PROJECT_TREE)
			tags.append(TAG_RESOURCE_CATALOG)
			if extension in SCRIPT_FILE_EXTENSIONS:
				tags.append(TAG_SCRIPT_CATALOG)
			elif extension in SCENE_FILE_EXTENSIONS:
				tags.append(TAG_SCENE_CATALOG)

	if bool(batch.get("reimported", false)):
		tags.append(TAG_IMPORT_STATE)
		tags.append(TAG_RESOURCE_AGGREGATE)
	if bool(batch.get("sources_changed", false)):
		# The signal carries no paths and precedes reimport. The import-status read
		# must refresh immediately; exact resource tags arrive with reimported.
		tags.append(TAG_IMPORT_STATE)
	if bool(batch.get("script_classes_updated", false)):
		tags.append(TAG_SCRIPT_AGGREGATE)
		tags.append(TAG_SCRIPT_CATALOG)
	if bool(batch.get("project_settings_changed", false)):
		tags.append(TAG_PROJECT_SETTINGS)

	if bool(batch.get("filesystem_fallback", false)):
		tags.append_array([
			TAG_SCENE_CONTENT, TAG_SCENE_CATALOG,
			TAG_SCRIPT_ALL, TAG_SCRIPT_AGGREGATE, TAG_SCRIPT_CATALOG,
			TAG_RESOURCE_ALL, TAG_RESOURCE_AGGREGATE, TAG_RESOURCE_CATALOG,
			TAG_PROJECT_SETTINGS, TAG_PROJECT_TREE, TAG_IMPORT_STATE
		])
	return _deduplicated_sorted(tags)


static func _append_first_path_tag(tags: Array[String], prefix: String,
		arguments: Dictionary, keys: Array[String]) -> void:
	for key in keys:
		var value: Variant = arguments.get(key, "")
		if not str(value).strip_edges().is_empty():
			_append_path_tag(tags, prefix, value)
			return


static func _append_path_tag(tags: Array[String], prefix: String, path_value: Variant) -> void:
	var normalized: String = _normalized_path(path_value)
	if not normalized.is_empty():
		tags.append(prefix + ":" + normalized)


static func _normalized_path(path_value: Variant) -> String:
	var normalized: String = str(path_value).strip_edges().replace("\\", "/")
	if normalized.begins_with("res:/") and not normalized.begins_with("res://"):
		normalized = "res://" + normalized.substr(5)
	while normalized.contains("//") and not normalized.begins_with("res://"):
		normalized = normalized.replace("//", "/")
	return normalized


static func _deduplicated_sorted(tags: Array[String]) -> Array[String]:
	var seen: Dictionary = {}
	for tag in tags:
		if not tag.is_empty():
			seen[tag] = true
	var result: Array[String] = []
	for tag_value in seen:
		result.append(String(tag_value))
	result.sort()
	return result
