class_name MCPToolDomains
extends RefCounted

## 面向用户任务的用途分类。它与 core/supplementary 和互斥的 group 正交，
## 因此一个通用工具可以同时服务 2D、3D 和 UI，而专属工具仍保持隔离。
const DOMAIN_ORDER: Array[String] = [
	"2d", "3d", "ui", "assets_animation", "debug_test", "shipping"
]

const DOMAIN_EXTRAS: Dictionary = {
	"2d": [
		"create_tileset", "inspect_tileset_resource", "configure_tileset_layers",
		"set_tile_collision_polygon", "set_tile_terrain", "set_tilemap_layer_cells",
		"get_tilemap_layer_cells", "list_runtime_tilemap_layers", "set_runtime_tilemap_cell",
		"get_runtime_tilemap_cell", "slice_sprite_sheet", "create_drawable_texture",
		"create_gradient_texture", "draw_on_texture", "set_collision_one_way"
	],
	"3d": [
		"generate_3d_asset", "inspect_gltf_asset", "configure_render_output",
		"get_runtime_material_state", "get_runtime_shader_parameters",
		"set_runtime_shader_parameter", "validate_shader", "compare_render_screenshots",
		"assert_visual_baseline"
	],
	"ui": [
		"create_theme", "set_default_theme", "set_theme_item", "set_anchor_preset",
		"set_control_offset_transform", "get_runtime_theme_item",
		"set_runtime_theme_override", "clear_runtime_theme_override", "manage_localization",
		"get_editor_screenshot", "get_runtime_screenshot", "assert_visual_baseline"
	],
	"assets_animation": [
		"generate_asset", "generate_3d_asset", "inspect_gltf_asset", "slice_sprite_sheet",
		"create_drawable_texture", "create_gradient_texture", "draw_on_texture",
		"create_animation", "insert_animation_keys", "list_runtime_animations",
		"play_runtime_animation", "stop_runtime_animation", "get_runtime_animation_state",
		"get_runtime_animation_tree_state", "set_runtime_animation_tree_active",
		"travel_runtime_animation_tree", "list_runtime_audio_buses", "get_runtime_audio_bus",
		"update_runtime_audio_bus", "reimport_resources", "get_import_metadata"
	],
	"debug_test": [
		"get_debug_output", "get_debugger_messages", "get_debugger_sessions",
		"add_debugger_capture_prefix", "set_debugger_breakpoint", "request_debug_break",
		"debug_continue", "debug_step_into", "debug_step_over", "debug_step_out",
		"debug_continue_and_wait", "debug_step_into_and_wait", "debug_step_over_and_wait",
		"debug_step_out_and_wait", "get_debug_threads", "get_debug_stack_frames",
		"get_debug_variables", "get_debug_stack_variables", "get_debug_scopes",
		"evaluate_debug_expression", "expand_debug_variable", "await_debugger_state",
		"install_runtime_probe", "remove_runtime_probe", "get_runtime_info",
		"get_runtime_scene_tree", "inspect_runtime_node", "play_and_verify",
		"assert_runtime_condition", "await_runtime_condition", "assert_no_runtime_errors",
		"assert_performance_budget", "get_performance_metrics", "get_runtime_performance_snapshot",
		"run_project_test", "run_project_tests", "list_project_tests",
		"prepare_project_test_environment", "ensure_project_directory", "create_project_smoke_test"
	],
	"shipping": [
		"list_export_presets", "validate_export_preset", "run_export", "smoke_test_export",
		"configure_android_export", "inspect_export_templates", "manage_export_templates",
		"pack_pck", "bump_version", "audit_project_health", "scan_migration_compatibility",
		"apply_migration_fixes", "find_deprecated_api_usage", "detect_broken_scripts",
		"scan_missing_resource_dependencies", "scan_cyclic_resource_dependencies",
		"list_unused_resources", "fix_resource_uid"
	]
}

static func get_all_domains() -> Array[String]:
	return DOMAIN_ORDER.duplicate()

static func get_tools(domain: String, classifications: Dictionary) -> Array[String]:
	if not DOMAIN_EXTRAS.has(domain):
		return []
	var result: Array[String] = []
	# Creation-oriented scopes share the small default toolkit. Operational scopes
	# stay focused so enabling them does not silently broaden the active surface.
	if domain in ["2d", "3d", "ui"]:
		for tool_name in classifications:
			if classifications[tool_name].get("category", "") == "core":
				result.append(str(tool_name))
	for tool_name in DOMAIN_EXTRAS[domain]:
		if classifications.has(tool_name) and not tool_name in result:
			result.append(tool_name)
	result.sort()
	return result
