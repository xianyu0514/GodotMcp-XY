class_name MCPToolsManifest
extends RefCounted

# ============================================================================
# tools_manifest.gd — 单一数据表：工具分类/分组的唯一权威来源
#
# 背景：此前工具名/分类/分组在 5 处重复维护（各 tools/*.gd 的 register_tool
# 调用、mcp_tool_classifier.gd 的 _build_classifications() 手写列表、docs 表格、
# translations JSON、测试计数断言），漂移风险高。本次重构引入本 manifest 作为
# 唯一真相，mcp_tool_classifier.gd 的 _build_classifications() 改为从
# MCPToolsManifest.TOOLS 生成。
#
# 内容来源：与工具注册实现逐条一致（225 个工具：30 core + 191
# supplementary + 4 meta）。
#
# 注意：
#   - TOOLS 是分类/分组的唯一权威来源；tools/*.gd 的 register_tool 调用仍然
#     各自携带 category/group（向后兼容，一致性由 test_mcp_tool_classifier.gd
#     的 test_manifest_matches_registered_tools 强制）。
#   - 新增工具流程：先在 tools/*.gd 中实现并调用 register_tool，再把条目加入
#     本 TOOLS 表，最后更新 docs 与 translations（见 AGENTS.md）。
# ============================================================================

const TOOLS: Dictionary = {
	"add_debugger_capture_prefix": {"category": "supplementary", "group": "Debug-Advanced"},
	"add_project_autoload": {"category": "supplementary", "group": "Project-Advanced"},
	"add_resource": {"category": "supplementary", "group": "Node-Write-Advanced"},
	"analyze_script": {"category": "supplementary", "group": "Script-Advanced"},
	"apply_project_change_set": {"category": "core", "group": "Project"},
	"apply_migration_fixes": {"category": "supplementary", "group": "Project-Advanced"},
	"assert_no_runtime_errors": {"category": "supplementary", "group": "Debug-Advanced"},
	"assert_performance_budget": {"category": "supplementary", "group": "Debug-Advanced"},
	"assert_runtime_condition": {"category": "supplementary", "group": "Debug-Advanced"},
	"assert_visual_baseline": {"category": "supplementary", "group": "Project-Advanced"},
	"attach_script": {"category": "core", "group": "Script"},
	"audit_project_health": {"category": "supplementary", "group": "Project-Advanced"},
	"audit_scene_inheritance": {"category": "supplementary", "group": "Node-Advanced"},
	"audit_scene_node_persistence": {"category": "supplementary", "group": "Node-Advanced"},
	"await_debugger_state": {"category": "supplementary", "group": "Debug-Advanced"},
	"await_runtime_condition": {"category": "supplementary", "group": "Debug-Advanced"},
	"await_scene_ready": {"category": "supplementary", "group": "Debug-Advanced"},
	"batch_connect_signals": {"category": "supplementary", "group": "Node-Advanced"},
	"batch_create_resources": {"category": "supplementary", "group": "Project-Advanced"},
	"batch_get_node_properties": {"category": "supplementary", "group": "Node-Advanced"},
	"batch_read_scripts": {"category": "supplementary", "group": "Script-Advanced"},
	"batch_scene_node_edits": {"category": "supplementary", "group": "Node-Advanced"},
	"batch_update_node_properties": {"category": "supplementary", "group": "Node-Advanced"},
	"bump_version": {"category": "supplementary", "group": "Project-Advanced"},
	"call_runtime_node_method": {"category": "supplementary", "group": "Debug-Advanced"},
	"clear_output": {"category": "core", "group": "Debug"},
	"clear_runtime_theme_override": {"category": "supplementary", "group": "Debug-Advanced"},
	"close_scene_tab": {"category": "supplementary", "group": "Scene-Advanced"},
	"close_script_tab": {"category": "supplementary", "group": "Editor-Advanced"},
	"compare_render_screenshots": {"category": "supplementary", "group": "Project-Advanced"},
	"configure_android_export": {"category": "supplementary", "group": "Editor-Advanced"},
	"configure_render_output": {"category": "supplementary", "group": "Project-Advanced"},
	"configure_tileset_layers": {"category": "supplementary", "group": "Project-Advanced"},
	"connect_signal": {"category": "supplementary", "group": "Node-Write-Advanced"},
	"create_animation": {"category": "supplementary", "group": "Project-Advanced"},
	"create_custom_resource": {"category": "supplementary", "group": "Project-Advanced"},
	"create_drawable_texture": {"category": "supplementary", "group": "Project-Advanced"},
	"create_gradient_texture": {"category": "supplementary", "group": "Project-Advanced"},
	"create_node": {"category": "core", "group": "Node-Write"},
	"create_resource": {"category": "supplementary", "group": "Project-Advanced"},
	"create_runtime_node": {"category": "supplementary", "group": "Debug-Advanced"},
	"create_scene": {"category": "core", "group": "Scene"},
	"create_script": {"category": "core", "group": "Script"},
	"create_theme": {"category": "supplementary", "group": "Project-Advanced"},
	"create_tileset": {"category": "supplementary", "group": "Project-Advanced"},
	"debug_continue": {"category": "supplementary", "group": "Debug-Advanced"},
	"debug_continue_and_wait": {"category": "supplementary", "group": "Debug-Advanced"},
	"debug_print": {"category": "core", "group": "Debug"},
	"debug_step_into": {"category": "supplementary", "group": "Debug-Advanced"},
	"debug_step_into_and_wait": {"category": "supplementary", "group": "Debug-Advanced"},
	"debug_step_out": {"category": "supplementary", "group": "Debug-Advanced"},
	"debug_step_out_and_wait": {"category": "supplementary", "group": "Debug-Advanced"},
	"debug_step_over": {"category": "supplementary", "group": "Debug-Advanced"},
	"debug_step_over_and_wait": {"category": "supplementary", "group": "Debug-Advanced"},
	"delete_node": {"category": "core", "group": "Node-Write"},
	"delete_runtime_node": {"category": "supplementary", "group": "Debug-Advanced"},
	"detect_broken_scripts": {"category": "supplementary", "group": "Project-Advanced"},
	"detect_gdextension_addons": {"category": "supplementary", "group": "Project-Advanced"},
	"disconnect_signal": {"category": "supplementary", "group": "Node-Write-Advanced"},
	"draw_on_texture": {"category": "supplementary", "group": "Project-Advanced"},
	"duplicate_node": {"category": "core", "group": "Node-Write"},
	"enable_tools": {"category": "meta", "group": "Meta"},
	"evaluate_debug_expression": {"category": "supplementary", "group": "Debug-Advanced"},
	"evaluate_runtime_expression": {"category": "supplementary", "group": "Debug-Advanced"},
	"execute_editor_script": {"category": "supplementary", "group": "Editor"},
	"execute_script": {"category": "supplementary", "group": "Script"},
	"expand_debug_variable": {"category": "supplementary", "group": "Debug-Advanced"},
	"find_deprecated_api_usage": {"category": "supplementary", "group": "Project-Advanced"},
	"find_nodes_in_group": {"category": "supplementary", "group": "Node-Advanced"},
	"find_resource_usages": {"category": "supplementary", "group": "Project-Advanced"},
	"find_script_symbol_definition": {"category": "supplementary", "group": "Script-Advanced"},
	"find_script_symbol_references": {"category": "supplementary", "group": "Script-Advanced"},
	"fix_resource_uid": {"category": "supplementary", "group": "Project-Advanced"},
	"generate_3d_asset": {"category": "supplementary", "group": "Project-Advanced"},
	"generate_asset": {"category": "supplementary", "group": "Project-Advanced"},
	"get_class_api_metadata": {"category": "supplementary", "group": "Project-Advanced"},
	"get_current_scene": {"category": "core", "group": "Scene"},
	"get_current_script": {"category": "core", "group": "Script"},
	"get_debug_output": {"category": "supplementary", "group": "Debug-Advanced"},
	"get_debug_scopes": {"category": "supplementary", "group": "Debug-Advanced"},
	"get_debug_stack_frames": {"category": "supplementary", "group": "Debug-Advanced"},
	"get_debug_stack_variables": {"category": "supplementary", "group": "Debug-Advanced"},
	"get_debug_state_events": {"category": "supplementary", "group": "Debug-Advanced"},
	"get_debug_threads": {"category": "supplementary", "group": "Debug-Advanced"},
	"get_debug_variables": {"category": "supplementary", "group": "Debug-Advanced"},
	"get_debugger_messages": {"category": "supplementary", "group": "Debug-Advanced"},
	"get_debugger_sessions": {"category": "supplementary", "group": "Debug-Advanced"},
	"get_editor_logs": {"category": "core", "group": "Debug"},
	"get_editor_screenshot": {"category": "supplementary", "group": "Editor-Advanced"},
	"get_editor_state": {"category": "core", "group": "Editor"},
	"get_import_metadata": {"category": "supplementary", "group": "Project-Advanced"},
	"get_import_status": {"category": "supplementary", "group": "Editor-Advanced"},
	"get_inspector_properties": {"category": "supplementary", "group": "Editor-Advanced"},
	"get_node_groups": {"category": "supplementary", "group": "Node-Advanced"},
	"get_node_properties": {"category": "core", "group": "Node-Read"},
	"get_node_subresource": {"category": "supplementary", "group": "Node-Advanced"},
	"get_performance_metrics": {"category": "supplementary", "group": "Debug-Advanced"},
	"get_project_context": {"category": "core", "group": "Project"},
	"get_project_info": {"category": "core", "group": "Project"},
	"get_project_settings": {"category": "core", "group": "Project"},
	"get_project_structure": {"category": "supplementary", "group": "Project-Advanced"},
	"get_resource_dependencies": {"category": "supplementary", "group": "Project-Advanced"},
	"get_resource_uid_info": {"category": "supplementary", "group": "Project-Advanced"},
	"get_runtime_animation_state": {"category": "supplementary", "group": "Debug-Advanced"},
	"get_runtime_animation_tree_state": {"category": "supplementary", "group": "Debug-Advanced"},
	"get_runtime_audio_bus": {"category": "supplementary", "group": "Debug-Advanced"},
	"get_runtime_info": {"category": "supplementary", "group": "Debug-Advanced"},
	"get_runtime_ui_semantics": {"category": "supplementary", "group": "Debug-Advanced"},
	"get_runtime_material_state": {"category": "supplementary", "group": "Debug-Advanced"},
	"get_runtime_memory_trend": {"category": "supplementary", "group": "Debug-Advanced"},
	"get_runtime_performance_snapshot": {"category": "supplementary", "group": "Debug-Advanced"},
	"get_runtime_scene_tree": {"category": "supplementary", "group": "Debug-Advanced"},
	"get_runtime_screenshot": {"category": "supplementary", "group": "Debug-Advanced"},
	"get_runtime_shader_parameters": {"category": "supplementary", "group": "Debug-Advanced"},
	"get_runtime_theme_item": {"category": "supplementary", "group": "Debug-Advanced"},
	"get_runtime_tilemap_cell": {"category": "supplementary", "group": "Debug-Advanced"},
	"get_scene_structure": {"category": "supplementary", "group": "Scene-Advanced"},
	"get_scene_tree": {"category": "core", "group": "Node-Read"},
	"get_selected_nodes": {"category": "supplementary", "group": "Editor-Advanced"},
	"get_signals": {"category": "supplementary", "group": "Editor-Advanced"},
	"get_tilemap_layer_cells": {"category": "supplementary", "group": "Scene-Advanced"},
	"get_tool_details": {"category": "meta", "group": "Meta"},
	"get_undo_history": {"category": "supplementary", "group": "Editor-Advanced"},
	"get_unsaved_changes": {"category": "supplementary", "group": "Editor-Advanced"},
	"insert_animation_keys": {"category": "supplementary", "group": "Project-Advanced"},
	"inspect_csharp_project_support": {"category": "supplementary", "group": "Project-Advanced"},
	"inspect_export_templates": {"category": "supplementary", "group": "Editor-Advanced"},
	"inspect_gltf_asset": {"category": "supplementary", "group": "Project-Advanced"},
	"inspect_runtime_node": {"category": "supplementary", "group": "Debug-Advanced"},
	"inspect_tileset_resource": {"category": "supplementary", "group": "Project-Advanced"},
	"install_runtime_probe": {"category": "supplementary", "group": "Debug-Advanced"},
	"instantiate_scene": {"category": "supplementary", "group": "Scene-Advanced"},
	"list_export_presets": {"category": "supplementary", "group": "Editor-Advanced"},
	"list_nodes": {"category": "core", "group": "Node-Read"},
	"list_open_scenes": {"category": "supplementary", "group": "Scene-Advanced"},
	"list_project_autoloads": {"category": "supplementary", "group": "Project-Advanced"},
	"list_project_global_classes": {"category": "supplementary", "group": "Project-Advanced"},
	"list_project_input_actions": {"category": "supplementary", "group": "Project-Advanced"},
	"list_project_resources": {"category": "core", "group": "Project"},
	"list_project_scenes": {"category": "supplementary", "group": "Scene-Advanced"},
	"list_project_script_symbols": {"category": "supplementary", "group": "Script-Advanced"},
	"list_project_scripts": {"category": "core", "group": "Script"},
	"list_project_tests": {"category": "supplementary", "group": "Project-Advanced"},
	"list_runtime_animations": {"category": "supplementary", "group": "Debug-Advanced"},
	"list_runtime_audio_buses": {"category": "supplementary", "group": "Debug-Advanced"},
	"list_runtime_input_actions": {"category": "supplementary", "group": "Debug-Advanced"},
	"list_runtime_tilemap_layers": {"category": "supplementary", "group": "Debug-Advanced"},
	"list_tool_catalog": {"category": "meta", "group": "Meta"},
	"list_unused_resources": {"category": "supplementary", "group": "Project-Advanced"},
	"manage_export_templates": {"category": "supplementary", "group": "Editor-Advanced"},
	"manage_localization": {"category": "supplementary", "group": "Project-Advanced"},
	"manage_task_plan": {"category": "supplementary", "group": "Project-Advanced"},
	"modify_script": {"category": "core", "group": "Script"},
	"move_node": {"category": "core", "group": "Node-Write"},
	"open_scene": {"category": "core", "group": "Scene"},
	"open_script_at_line": {"category": "supplementary", "group": "Script-Advanced"},
	"pack_pck": {"category": "supplementary", "group": "Project-Advanced"},
	"play_and_verify": {"category": "supplementary", "group": "Debug-Advanced"},
	"play_runtime_animation": {"category": "supplementary", "group": "Debug-Advanced"},
	"read_resource_properties": {"category": "supplementary", "group": "Project-Advanced"},
	"read_script": {"category": "core", "group": "Script"},
	"redo": {"category": "supplementary", "group": "Editor-Advanced"},
	"reimport_resources": {"category": "supplementary", "group": "Project-Advanced"},
	"reload_open_scripts": {"category": "supplementary", "group": "Editor-Advanced"},
	"reload_project": {"category": "supplementary", "group": "Editor-Advanced"},
	"remove_project_autoload": {"category": "supplementary", "group": "Project-Advanced"},
	"remove_project_input_action": {"category": "supplementary", "group": "Project-Advanced"},
	"remove_runtime_input_action": {"category": "supplementary", "group": "Debug-Advanced"},
	"remove_runtime_probe": {"category": "supplementary", "group": "Debug-Advanced"},
	"rename_node": {"category": "core", "group": "Node-Write"},
	"rename_script_symbol": {"category": "supplementary", "group": "Script-Advanced"},
	"request_debug_break": {"category": "supplementary", "group": "Debug-Advanced"},
	"run_export": {"category": "supplementary", "group": "Editor-Advanced"},
	"run_project": {"category": "core", "group": "Editor"},
	"run_project_test": {"category": "supplementary", "group": "Project-Advanced"},
	"run_project_tests": {"category": "supplementary", "group": "Project-Advanced"},
	"save_all_scripts": {"category": "supplementary", "group": "Editor-Advanced"},
	"save_branch_as_scene": {"category": "supplementary", "group": "Scene-Advanced"},
	"save_scene": {"category": "core", "group": "Scene"},
	"scan_cyclic_resource_dependencies": {"category": "supplementary", "group": "Project-Advanced"},
	"scan_migration_compatibility": {"category": "supplementary", "group": "Project-Advanced"},
	"scan_missing_resource_dependencies": {"category": "supplementary", "group": "Project-Advanced"},
	"search_in_files": {"category": "supplementary", "group": "Script-Advanced"},
	"search_tools": {"category": "meta", "group": "Meta"},
	"select_file": {"category": "supplementary", "group": "Editor-Advanced"},
	"select_node": {"category": "supplementary", "group": "Editor-Advanced"},
	"send_debug_command": {"category": "supplementary", "group": "Debug-Advanced"},
	"send_debugger_message": {"category": "supplementary", "group": "Debug-Advanced"},
	"set_anchor_preset": {"category": "supplementary", "group": "Node-Write-Advanced"},
	"set_collision_one_way": {"category": "supplementary", "group": "Node-Write-Advanced"},
	"set_control_offset_transform": {"category": "supplementary", "group": "Node-Write-Advanced"},
	"set_debugger_breakpoint": {"category": "supplementary", "group": "Debug-Advanced"},
	"set_default_theme": {"category": "supplementary", "group": "Project-Advanced"},
	"set_editor_setting": {"category": "supplementary", "group": "Editor-Advanced"},
	"set_node_groups": {"category": "supplementary", "group": "Node-Write-Advanced"},
	"set_node_subresource": {"category": "supplementary", "group": "Node-Write-Advanced"},
	"set_project_setting": {"category": "supplementary", "group": "Project-Advanced"},
	"set_runtime_animation_tree_active": {"category": "supplementary", "group": "Debug-Advanced"},
	"set_runtime_shader_parameter": {"category": "supplementary", "group": "Debug-Advanced"},
	"set_runtime_theme_override": {"category": "supplementary", "group": "Debug-Advanced"},
	"set_runtime_tilemap_cell": {"category": "supplementary", "group": "Debug-Advanced"},
	"set_theme_item": {"category": "supplementary", "group": "Project-Advanced"},
	"set_tile_collision_polygon": {"category": "supplementary", "group": "Project-Advanced"},
	"set_tile_terrain": {"category": "supplementary", "group": "Project-Advanced"},
	"set_tilemap_layer_cells": {"category": "supplementary", "group": "Scene-Advanced"},
	"simulate_runtime_input_action": {"category": "supplementary", "group": "Debug-Advanced"},
	"simulate_runtime_input_event": {"category": "supplementary", "group": "Debug-Advanced"},
	"slice_sprite_sheet": {"category": "supplementary", "group": "Project-Advanced"},
	"smoke_test_export": {"category": "supplementary", "group": "Editor-Advanced"},
	"stop_project": {"category": "core", "group": "Editor"},
	"stop_runtime_animation": {"category": "supplementary", "group": "Debug-Advanced"},
	"toggle_debugger_profiler": {"category": "supplementary", "group": "Debug-Advanced"},
	"travel_runtime_animation_tree": {"category": "supplementary", "group": "Debug-Advanced"},
	"undo": {"category": "supplementary", "group": "Editor-Advanced"},
	"update_node_property": {"category": "core", "group": "Node-Write"},
	"update_resource_properties": {"category": "supplementary", "group": "Project-Advanced"},
	"update_runtime_audio_bus": {"category": "supplementary", "group": "Debug-Advanced"},
	"update_runtime_node_property": {"category": "supplementary", "group": "Debug-Advanced"},
	"upsert_project_input_action": {"category": "supplementary", "group": "Project-Advanced"},
	"upsert_runtime_input_action": {"category": "supplementary", "group": "Debug-Advanced"},
	"validate_export_preset": {"category": "supplementary", "group": "Editor-Advanced"},
	"validate_script": {"category": "supplementary", "group": "Script-Advanced"},
	"validate_shader": {"category": "supplementary", "group": "Script-Advanced"},
	"verify_scripts": {"category": "supplementary", "group": "Script-Advanced"},
	"visual_playtest": {"category": "supplementary", "group": "Debug-Advanced"},
}

## 全部工具名（按名字排序，便于测试与文档对照）。
static func tool_names() -> Array[String]:
	var names: Array[String] = []
	for tool_name in TOOLS:
		names.append(str(tool_name))
	names.sort()
	return names

## 返回工具分类（core / supplementary / meta）；未知工具返回空串。
static func category_of(tool_name: String) -> String:
	if TOOLS.has(tool_name):
		return str(TOOLS[tool_name]["category"])
	return ""

## 返回工具分组（如 Node-Write）；未知工具返回空串。
static func group_of(tool_name: String) -> String:
	if TOOLS.has(tool_name):
		return str(TOOLS[tool_name]["group"])
	return ""

## 返回指定分类下的工具数量；未知分类返回 0。
static func count_by_category(category: String) -> int:
	var count: int = 0
	for tool_name in TOOLS:
		if TOOLS[tool_name]["category"] == category:
			count += 1
	return count

## 全部工具名 -> {category, group}（浅拷贝，防止调用方改动常量表）。
static func all_entries() -> Dictionary:
	return TOOLS.duplicate()
