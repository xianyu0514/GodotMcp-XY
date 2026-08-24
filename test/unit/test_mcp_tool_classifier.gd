extends "res://addons/gut/test.gd"

# 单一数据表（MCPToolsManifest）与 classifier / server_core 注册的一致性测试：
#   - test_manifest_matches_classifier：manifest 工具集 == classifier 工具集（含分类/分组）
#   - test_manifest_matches_registered_tools：运行时注册校验 —— 每个注册工具的
#     category/group 必须与 manifest 一致（防“新增工具忘改 manifest / register 与
#     manifest 不一致”漂移）
#   - test_manifest_counts：manifest 计数（221/28/189/4）

const ManifestScript = preload("res://addons/godot_mcp/native_mcp/tools_manifest.gd")

const TOOL_MODULE_PATHS: Array[String] = [
	"res://addons/godot_mcp/tools/node_tools_native.gd",
	"res://addons/godot_mcp/tools/script_tools_native.gd",
	"res://addons/godot_mcp/tools/scene_tools_native.gd",
	"res://addons/godot_mcp/tools/editor_tools_native.gd",
	"res://addons/godot_mcp/tools/debug_tools_native.gd",
	"res://addons/godot_mcp/tools/debug_bridge_tools.gd",
	"res://addons/godot_mcp/tools/debug_runtime_tools.gd",
	"res://addons/godot_mcp/tools/debug_verify_tools.gd",
	"res://addons/godot_mcp/tools/project_tools_native.gd",
	"res://addons/godot_mcp/tools/project_resources_tools.gd",
	"res://addons/godot_mcp/tools/project_assets_tools.gd",
	"res://addons/godot_mcp/tools/project_tileset_tools.gd",
	"res://addons/godot_mcp/tools/project_verification_tools.gd",
	"res://addons/godot_mcp/tools/project_workflow_tools.gd",
	"res://addons/godot_mcp/tools/meta_tools_native.gd",
]

var _classifier = null
var _core = null

func before_each():
	_classifier = load("res://addons/godot_mcp/native_mcp/mcp_tool_classifier.gd").new()
	_core = null

func after_each():
	_classifier = null
	if _core != null:
		# 解除注册表对（绑定到模块实例的）callable 的引用，避免 headless 退出时
		# ObjectDB 泄漏告警（同 test_tool_schema_lint.gd）。
		var names: Array = _core.get_all_tools().keys()
		for name in names:
			_core.unregister_tool(name)
	_core = null

func test_classifier_initializes():
	assert_ne(_classifier, null, "Classifier should initialize")

func test_all_221_tools_registered():
	var all_tools: Array = _classifier.get_all_tools()
	assert_eq(all_tools.size(), 221, "Should have exactly 221 tools registered")

func test_meta_tools_registered():
	var meta_tools: Array = _classifier.get_meta_tools()
	assert_eq(meta_tools.size(), 4, "Should have exactly 4 meta tools")
	assert_true("list_tool_catalog" in meta_tools, "list_tool_catalog should be a meta tool")
	assert_true("enable_tools" in meta_tools, "enable_tools should be a meta tool")
	assert_true("search_tools" in meta_tools, "search_tools should be a meta tool")
	assert_true("get_tool_details" in meta_tools, "get_tool_details should be a meta tool")

func test_meta_tools_are_not_core_or_supplementary():
	assert_true(_classifier.is_meta_tool("list_tool_catalog"), "list_tool_catalog should be meta")
	assert_false(_classifier.is_core_tool("enable_tools"), "enable_tools should not be core")
	assert_false(_classifier.is_supplementary_tool("enable_tools"), "enable_tools should not be supplementary")
	assert_eq(_classifier.get_tool_group("list_tool_catalog"), "Meta", "list_tool_catalog should be in Meta group")
	assert_true(_classifier.is_meta_tool("search_tools"), "search_tools should be meta")
	assert_false(_classifier.is_supplementary_tool("search_tools"), "search_tools should not be supplementary")
	assert_true(_classifier.is_meta_tool("get_tool_details"), "get_tool_details should be meta")
	assert_eq(_classifier.get_tool_group("get_tool_details"), "Meta", "get_tool_details should be in Meta group")

func test_verify_scripts_is_supplementary_script_advanced():
	assert_true(_classifier.is_supplementary_tool("verify_scripts"), "verify_scripts should be supplementary")
	assert_false(_classifier.is_core_tool("verify_scripts"), "verify_scripts should not be core")
	assert_eq(_classifier.get_tool_group("verify_scripts"), "Script-Advanced", "verify_scripts should be in Script-Advanced group")

func test_undo_redo_history_tools_are_supplementary_editor_advanced():
	for tool_name in ["undo", "redo", "get_undo_history"]:
		assert_true(_classifier.is_supplementary_tool(tool_name), tool_name + " should be supplementary")
		assert_false(_classifier.is_core_tool(tool_name), tool_name + " should not be core")
		assert_false(_classifier.is_meta_tool(tool_name), tool_name + " should not be meta")
		assert_eq(_classifier.get_tool_group(tool_name), "Editor-Advanced", tool_name + " should be in Editor-Advanced group")

func test_editor_advanced_group_count():
	var tools: Array = _classifier.get_group_tools("Editor-Advanced")
	assert_eq(tools.size(), 23, "Editor-Advanced should have 23 tools")

func test_play_and_verify_is_supplementary_debug_advanced():
	assert_true(_classifier.is_supplementary_tool("play_and_verify"), "play_and_verify should be supplementary")
	assert_eq(_classifier.get_tool_group("play_and_verify"), "Debug-Advanced", "play_and_verify should be in Debug-Advanced group")

func test_manage_task_plan_is_supplementary_project_advanced():
	assert_true(_classifier.is_supplementary_tool("manage_task_plan"), "manage_task_plan should be supplementary")
	assert_eq(_classifier.get_tool_group("manage_task_plan"), "Project-Advanced", "manage_task_plan should be in Project-Advanced group")

func test_manage_localization_is_supplementary_project_advanced():
	assert_true(_classifier.is_supplementary_tool("manage_localization"), "manage_localization should be supplementary")
	assert_eq(_classifier.get_tool_group("manage_localization"), "Project-Advanced", "manage_localization should be in Project-Advanced group")

func test_assert_visual_baseline_is_supplementary_project_advanced():
	assert_true(_classifier.is_supplementary_tool("assert_visual_baseline"), "assert_visual_baseline should be supplementary")
	assert_eq(_classifier.get_tool_group("assert_visual_baseline"), "Project-Advanced", "assert_visual_baseline should be in Project-Advanced group")

func test_assert_performance_budget_is_supplementary_debug_advanced():
	assert_true(_classifier.is_supplementary_tool("assert_performance_budget"), "assert_performance_budget should be supplementary")
	assert_eq(_classifier.get_tool_group("assert_performance_budget"), "Debug-Advanced", "assert_performance_budget should be in Debug-Advanced group")

func test_assert_no_runtime_errors_is_supplementary_debug_advanced():
	assert_true(_classifier.is_supplementary_tool("assert_no_runtime_errors"), "assert_no_runtime_errors should be supplementary")
	assert_eq(_classifier.get_tool_group("assert_no_runtime_errors"), "Debug-Advanced", "assert_no_runtime_errors should be in Debug-Advanced group")

func test_slice_sprite_sheet_is_supplementary_project_advanced():
	assert_true(_classifier.is_supplementary_tool("slice_sprite_sheet"), "slice_sprite_sheet should be supplementary")
	assert_eq(_classifier.get_tool_group("slice_sprite_sheet"), "Project-Advanced", "slice_sprite_sheet should be in Project-Advanced group")

func test_inspect_gltf_asset_is_supplementary_project_advanced():
	assert_true(_classifier.is_supplementary_tool("inspect_gltf_asset"), "inspect_gltf_asset should be supplementary")
	assert_eq(_classifier.get_tool_group("inspect_gltf_asset"), "Project-Advanced", "inspect_gltf_asset should be in Project-Advanced group")

func test_generate_3d_asset_is_supplementary_project_advanced():
	assert_true(_classifier.is_supplementary_tool("generate_3d_asset"), "generate_3d_asset should be supplementary")
	assert_eq(_classifier.get_tool_group("generate_3d_asset"), "Project-Advanced", "generate_3d_asset should be in Project-Advanced group")

func test_core_tools_count_within_limit():
	var core_tools: Array = _classifier.get_core_tools()
	assert_eq(core_tools.size(), 28, "Should have exactly 28 core tools")

func test_supplementary_tools_count():
	var supp_tools: Array = _classifier.get_supplementary_tools()
	assert_eq(supp_tools.size(), 189, "Should have 189 supplementary tools")

func test_get_tool_category_create_node():
	var cat: String = _classifier.get_tool_category("create_node")
	assert_eq(cat, "core", "create_node should be core")

func test_get_tool_category_execute_editor_script():
	var cat: String = _classifier.get_tool_category("execute_editor_script")
	assert_eq(cat, "supplementary", "execute_editor_script should be supplementary")

func test_execute_script_now_supplementary():
	assert_true(_classifier.is_supplementary_tool("execute_script"), "execute_script should be supplementary after security downgrade")
	assert_false(_classifier.is_core_tool("execute_script"), "execute_script should not be core after security downgrade")
	assert_eq(_classifier.get_tool_group("execute_script"), "Script", "execute_script should stay in Script group")

func test_execute_editor_script_now_supplementary():
	assert_true(_classifier.is_supplementary_tool("execute_editor_script"), "execute_editor_script should be supplementary after security downgrade")
	assert_false(_classifier.is_core_tool("execute_editor_script"), "execute_editor_script should not be core after security downgrade")
	assert_eq(_classifier.get_tool_group("execute_editor_script"), "Editor", "execute_editor_script should stay in Editor group")

func test_get_tool_category_unknown():
	var cat: String = _classifier.get_tool_category("non_existent_tool")
	assert_eq(cat, "core", "Unknown tool should default to core")

func test_get_tool_group_create_node():
	var group: String = _classifier.get_tool_group("create_node")
	assert_eq(group, "Node-Write", "create_node should be in Node-Write group")

func test_get_tool_group_read_script():
	var group: String = _classifier.get_tool_group("read_script")
	assert_eq(group, "Script", "read_script should be in Script group")

func test_get_tool_group_reload_project():
	var group: String = _classifier.get_tool_group("reload_project")
	assert_eq(group, "Editor-Advanced", "reload_project should be in Editor-Advanced group")

func test_get_tool_group_unknown():
	var group: String = _classifier.get_tool_group("non_existent_tool")
	assert_eq(group, "", "Unknown tool should return empty group")

func test_get_all_groups_contains_core_groups():
	var groups: Array = _classifier.get_all_groups()
	assert_true("Node-Read" in groups, "Should contain Node-Read group")
	assert_true("Node-Write" in groups, "Should contain Node-Write group")
	assert_true("Script" in groups, "Should contain Script group")
	assert_true("Scene" in groups, "Should contain Scene group")
	assert_true("Editor" in groups, "Should contain Editor group")

func test_get_all_groups_contains_supplementary_groups():
	var groups: Array = _classifier.get_all_groups()
	assert_true("Editor-Advanced" in groups, "Should contain Editor-Advanced group")
	assert_true("Debug-Advanced" in groups, "Should contain Debug-Advanced group")
	assert_true("Node-Advanced" in groups, "Should contain Node-Advanced group")
	assert_true("Node-Write-Advanced" in groups, "Should contain Node-Write-Advanced group")
	assert_true("Scene-Advanced" in groups, "Should contain Scene-Advanced group")
	assert_true("Script-Advanced" in groups, "Should contain Script-Advanced group")
	assert_true("Project-Advanced" in groups, "Should contain Project-Advanced group")

func test_get_group_tools_node_write():
	var tools: Array = _classifier.get_group_tools("Node-Write")
	assert_true(tools.size() >= 6, "Node-Write should have 6+ tools")
	assert_true("create_node" in tools, "Node-Write should contain create_node")
	assert_true("delete_node" in tools, "Node-Write should contain delete_node")
	assert_true("update_node_property" in tools, "Node-Write should contain update_node_property")

func test_get_group_tools_script():
	var tools: Array = _classifier.get_group_tools("Script")
	assert_true(tools.size() >= 7, "Script should have 7 tools")
	assert_true("read_script" in tools, "Script should contain read_script")
	assert_true("create_script" in tools, "Script should contain create_script")
	assert_true("modify_script" in tools, "Script should contain modify_script")

func test_is_core_tool():
	assert_true(_classifier.is_core_tool("create_node"), "create_node should be core")
	assert_true(_classifier.is_core_tool("list_project_scripts"), "list_project_scripts should be core")
	assert_true(_classifier.is_core_tool("read_script"), "read_script should be core")

func test_is_supplementary_tool():
	assert_true(_classifier.is_supplementary_tool("reload_project"), "reload_project should be supplementary")
	assert_true(_classifier.is_supplementary_tool("get_performance_metrics"), "get_performance_metrics should be supplementary")
	assert_true(_classifier.is_supplementary_tool("set_anchor_preset"), "set_anchor_preset should be supplementary")
	assert_true(_classifier.is_supplementary_tool("connect_signal"), "connect_signal should be supplementary")
	assert_true(_classifier.is_supplementary_tool("disconnect_signal"), "disconnect_signal should be supplementary")
	assert_true(_classifier.is_supplementary_tool("set_node_groups"), "set_node_groups should be supplementary")
	assert_true(_classifier.is_supplementary_tool("add_resource"), "add_resource should be supplementary")
	assert_true(_classifier.is_supplementary_tool("get_node_groups"), "get_node_groups should be supplementary")
	assert_true(_classifier.is_supplementary_tool("find_nodes_in_group"), "find_nodes_in_group should be supplementary")
	assert_true(_classifier.is_supplementary_tool("analyze_script"), "analyze_script should be supplementary")
	assert_true(_classifier.is_supplementary_tool("validate_script"), "validate_script should be supplementary")
	assert_true(_classifier.is_supplementary_tool("verify_scripts"), "verify_scripts should be supplementary")
	assert_true(_classifier.is_supplementary_tool("search_in_files"), "search_in_files should be supplementary")
	assert_true(_classifier.is_supplementary_tool("list_project_scenes"), "list_project_scenes should be supplementary")
	assert_true(_classifier.is_supplementary_tool("get_scene_structure"), "get_scene_structure should be supplementary")
	assert_true(_classifier.is_supplementary_tool("get_selected_nodes"), "get_selected_nodes should be supplementary")
	assert_true(_classifier.is_supplementary_tool("set_editor_setting"), "set_editor_setting should be supplementary")
	assert_true(_classifier.is_supplementary_tool("get_editor_screenshot"), "get_editor_screenshot should be supplementary")
	assert_true(_classifier.is_supplementary_tool("get_signals"), "get_signals should be supplementary")
	assert_true(_classifier.is_supplementary_tool("create_resource"), "create_resource should be supplementary")
	assert_true(_classifier.is_supplementary_tool("create_custom_resource"), "create_custom_resource should be supplementary")
	assert_true(_classifier.is_supplementary_tool("batch_create_resources"), "batch_create_resources should be supplementary")
	assert_true(_classifier.is_supplementary_tool("update_resource_properties"), "update_resource_properties should be supplementary")
	assert_true(_classifier.is_supplementary_tool("read_resource_properties"), "read_resource_properties should be supplementary")
	assert_true(_classifier.is_supplementary_tool("instantiate_scene"), "instantiate_scene should be supplementary")
	assert_true(_classifier.is_supplementary_tool("save_branch_as_scene"), "save_branch_as_scene should be supplementary")
	assert_true(_classifier.is_supplementary_tool("create_theme"), "create_theme should be supplementary")
	assert_true(_classifier.is_supplementary_tool("set_theme_item"), "set_theme_item should be supplementary")
	assert_true(_classifier.is_supplementary_tool("set_default_theme"), "set_default_theme should be supplementary")
	assert_true(_classifier.is_supplementary_tool("set_project_setting"), "set_project_setting should be supplementary")
	assert_true(_classifier.is_supplementary_tool("add_project_autoload"), "add_project_autoload should be supplementary")
	assert_true(_classifier.is_supplementary_tool("remove_project_autoload"), "remove_project_autoload should be supplementary")
	assert_true(_classifier.is_supplementary_tool("get_project_structure"), "get_project_structure should be supplementary")
	assert_true(_classifier.is_supplementary_tool("get_debugger_sessions"), "get_debugger_sessions should be supplementary")
	assert_true(_classifier.is_supplementary_tool("set_debugger_breakpoint"), "set_debugger_breakpoint should be supplementary")
	assert_true(_classifier.is_supplementary_tool("send_debugger_message"), "send_debugger_message should be supplementary")
	assert_true(_classifier.is_supplementary_tool("toggle_debugger_profiler"), "toggle_debugger_profiler should be supplementary")
	assert_true(_classifier.is_supplementary_tool("get_debugger_messages"), "get_debugger_messages should be supplementary")
	assert_true(_classifier.is_supplementary_tool("add_debugger_capture_prefix"), "add_debugger_capture_prefix should be supplementary")
	assert_true(_classifier.is_supplementary_tool("get_debug_stack_frames"), "get_debug_stack_frames should be supplementary")
	assert_true(_classifier.is_supplementary_tool("get_debug_stack_variables"), "get_debug_stack_variables should be supplementary")
	assert_true(_classifier.is_supplementary_tool("install_runtime_probe"), "install_runtime_probe should be supplementary")
	assert_true(_classifier.is_supplementary_tool("remove_runtime_probe"), "remove_runtime_probe should be supplementary")
	assert_true(_classifier.is_supplementary_tool("request_debug_break"), "request_debug_break should be supplementary")
	assert_true(_classifier.is_supplementary_tool("send_debug_command"), "send_debug_command should be supplementary")
	assert_true(_classifier.is_supplementary_tool("get_runtime_info"), "get_runtime_info should be supplementary")
	assert_true(_classifier.is_supplementary_tool("get_runtime_scene_tree"), "get_runtime_scene_tree should be supplementary")
	assert_true(_classifier.is_supplementary_tool("inspect_runtime_node"), "inspect_runtime_node should be supplementary")
	assert_true(_classifier.is_supplementary_tool("update_runtime_node_property"), "update_runtime_node_property should be supplementary")
	assert_true(_classifier.is_supplementary_tool("call_runtime_node_method"), "call_runtime_node_method should be supplementary")
	assert_true(_classifier.is_supplementary_tool("evaluate_runtime_expression"), "evaluate_runtime_expression should be supplementary")
	assert_true(_classifier.is_supplementary_tool("await_runtime_condition"), "await_runtime_condition should be supplementary")
	assert_true(_classifier.is_supplementary_tool("await_scene_ready"), "await_scene_ready should be supplementary")
	assert_true(_classifier.is_supplementary_tool("assert_runtime_condition"), "assert_runtime_condition should be supplementary")
	assert_true(_classifier.is_supplementary_tool("get_debug_threads"), "get_debug_threads should be supplementary")
	assert_true(_classifier.is_supplementary_tool("get_debug_state_events"), "get_debug_state_events should be supplementary")
	assert_true(_classifier.is_supplementary_tool("get_debug_output"), "get_debug_output should be supplementary")
	assert_true(_classifier.is_supplementary_tool("get_debug_scopes"), "get_debug_scopes should be supplementary")
	assert_true(_classifier.is_supplementary_tool("get_debug_variables"), "get_debug_variables should be supplementary")
	assert_true(_classifier.is_supplementary_tool("expand_debug_variable"), "expand_debug_variable should be supplementary")
	assert_true(_classifier.is_supplementary_tool("evaluate_debug_expression"), "evaluate_debug_expression should be supplementary")
	assert_true(_classifier.is_supplementary_tool("debug_step_into"), "debug_step_into should be supplementary")
	assert_true(_classifier.is_supplementary_tool("debug_step_over"), "debug_step_over should be supplementary")
	assert_true(_classifier.is_supplementary_tool("debug_step_out"), "debug_step_out should be supplementary")
	assert_true(_classifier.is_supplementary_tool("debug_continue"), "debug_continue should be supplementary")
	assert_true(_classifier.is_supplementary_tool("debug_step_into_and_wait"), "debug_step_into_and_wait should be supplementary")
	assert_true(_classifier.is_supplementary_tool("debug_step_over_and_wait"), "debug_step_over_and_wait should be supplementary")
	assert_true(_classifier.is_supplementary_tool("debug_step_out_and_wait"), "debug_step_out_and_wait should be supplementary")
	assert_true(_classifier.is_supplementary_tool("debug_continue_and_wait"), "debug_continue_and_wait should be supplementary")
	assert_true(_classifier.is_supplementary_tool("await_debugger_state"), "await_debugger_state should be supplementary")
	assert_true(_classifier.is_supplementary_tool("get_runtime_performance_snapshot"), "get_runtime_performance_snapshot should be supplementary")
	assert_true(_classifier.is_supplementary_tool("get_runtime_memory_trend"), "get_runtime_memory_trend should be supplementary")
	assert_true(_classifier.is_supplementary_tool("create_runtime_node"), "create_runtime_node should be supplementary")
	assert_true(_classifier.is_supplementary_tool("delete_runtime_node"), "delete_runtime_node should be supplementary")
	assert_true(_classifier.is_supplementary_tool("simulate_runtime_input_event"), "simulate_runtime_input_event should be supplementary")
	assert_true(_classifier.is_supplementary_tool("simulate_runtime_input_action"), "simulate_runtime_input_action should be supplementary")
	assert_true(_classifier.is_supplementary_tool("list_runtime_input_actions"), "list_runtime_input_actions should be supplementary")
	assert_true(_classifier.is_supplementary_tool("upsert_runtime_input_action"), "upsert_runtime_input_action should be supplementary")
	assert_true(_classifier.is_supplementary_tool("remove_runtime_input_action"), "remove_runtime_input_action should be supplementary")
	assert_true(_classifier.is_supplementary_tool("list_runtime_animations"), "list_runtime_animations should be supplementary")
	assert_true(_classifier.is_supplementary_tool("play_runtime_animation"), "play_runtime_animation should be supplementary")
	assert_true(_classifier.is_supplementary_tool("stop_runtime_animation"), "stop_runtime_animation should be supplementary")
	assert_true(_classifier.is_supplementary_tool("get_runtime_animation_state"), "get_runtime_animation_state should be supplementary")
	assert_true(_classifier.is_supplementary_tool("get_runtime_animation_tree_state"), "get_runtime_animation_tree_state should be supplementary")
	assert_true(_classifier.is_supplementary_tool("set_runtime_animation_tree_active"), "set_runtime_animation_tree_active should be supplementary")
	assert_true(_classifier.is_supplementary_tool("travel_runtime_animation_tree"), "travel_runtime_animation_tree should be supplementary")
	assert_true(_classifier.is_supplementary_tool("get_runtime_material_state"), "get_runtime_material_state should be supplementary")
	assert_true(_classifier.is_supplementary_tool("get_runtime_theme_item"), "get_runtime_theme_item should be supplementary")
	assert_true(_classifier.is_supplementary_tool("set_runtime_theme_override"), "set_runtime_theme_override should be supplementary")
	assert_true(_classifier.is_supplementary_tool("clear_runtime_theme_override"), "clear_runtime_theme_override should be supplementary")
	assert_true(_classifier.is_supplementary_tool("get_runtime_shader_parameters"), "get_runtime_shader_parameters should be supplementary")
	assert_true(_classifier.is_supplementary_tool("set_runtime_shader_parameter"), "set_runtime_shader_parameter should be supplementary")
	assert_true(_classifier.is_supplementary_tool("list_runtime_tilemap_layers"), "list_runtime_tilemap_layers should be supplementary")
	assert_true(_classifier.is_supplementary_tool("get_runtime_tilemap_cell"), "get_runtime_tilemap_cell should be supplementary")
	assert_true(_classifier.is_supplementary_tool("set_runtime_tilemap_cell"), "set_runtime_tilemap_cell should be supplementary")
	assert_true(_classifier.is_supplementary_tool("list_runtime_audio_buses"), "list_runtime_audio_buses should be supplementary")
	assert_true(_classifier.is_supplementary_tool("get_runtime_audio_bus"), "get_runtime_audio_bus should be supplementary")
	assert_true(_classifier.is_supplementary_tool("update_runtime_audio_bus"), "update_runtime_audio_bus should be supplementary")
	assert_true(_classifier.is_supplementary_tool("get_runtime_screenshot"), "get_runtime_screenshot should be supplementary")
	assert_true(_classifier.is_supplementary_tool("select_node"), "select_node should be supplementary")
	assert_true(_classifier.is_supplementary_tool("select_file"), "select_file should be supplementary")
	assert_true(_classifier.is_supplementary_tool("get_inspector_properties"), "get_inspector_properties should be supplementary")
	assert_true(_classifier.is_supplementary_tool("list_export_presets"), "list_export_presets should be supplementary")
	assert_true(_classifier.is_supplementary_tool("inspect_export_templates"), "inspect_export_templates should be supplementary")
	assert_true(_classifier.is_supplementary_tool("validate_export_preset"), "validate_export_preset should be supplementary")
	assert_true(_classifier.is_supplementary_tool("run_export"), "run_export should be supplementary")
	assert_true(_classifier.is_supplementary_tool("batch_update_node_properties"), "batch_update_node_properties should be supplementary")
	assert_true(_classifier.is_supplementary_tool("batch_scene_node_edits"), "batch_scene_node_edits should be supplementary")
	assert_true(_classifier.is_supplementary_tool("audit_scene_node_persistence"), "audit_scene_node_persistence should be supplementary")
	assert_true(_classifier.is_supplementary_tool("audit_scene_inheritance"), "audit_scene_inheritance should be supplementary")
	assert_true(_classifier.is_supplementary_tool("list_open_scenes"), "list_open_scenes should be supplementary")
	assert_true(_classifier.is_supplementary_tool("close_scene_tab"), "close_scene_tab should be supplementary")
	assert_true(_classifier.is_supplementary_tool("list_project_script_symbols"), "list_project_script_symbols should be supplementary")
	assert_true(_classifier.is_supplementary_tool("find_script_symbol_definition"), "find_script_symbol_definition should be supplementary")
	assert_true(_classifier.is_supplementary_tool("find_script_symbol_references"), "find_script_symbol_references should be supplementary")
	assert_true(_classifier.is_supplementary_tool("rename_script_symbol"), "rename_script_symbol should be supplementary")
	assert_true(_classifier.is_supplementary_tool("open_script_at_line"), "open_script_at_line should be supplementary")
	assert_true(_classifier.is_supplementary_tool("list_project_tests"), "list_project_tests should be supplementary")
	assert_true(_classifier.is_supplementary_tool("run_project_test"), "run_project_test should be supplementary")
	assert_true(_classifier.is_supplementary_tool("run_project_tests"), "run_project_tests should be supplementary")
	assert_true(_classifier.is_supplementary_tool("list_project_input_actions"), "list_project_input_actions should be supplementary")
	assert_true(_classifier.is_supplementary_tool("upsert_project_input_action"), "upsert_project_input_action should be supplementary")
	assert_true(_classifier.is_supplementary_tool("remove_project_input_action"), "remove_project_input_action should be supplementary")
	assert_true(_classifier.is_supplementary_tool("list_project_autoloads"), "list_project_autoloads should be supplementary")
	assert_true(_classifier.is_supplementary_tool("list_project_global_classes"), "list_project_global_classes should be supplementary")
	assert_true(_classifier.is_supplementary_tool("get_class_api_metadata"), "get_class_api_metadata should be supplementary")
	assert_true(_classifier.is_supplementary_tool("inspect_csharp_project_support"), "inspect_csharp_project_support should be supplementary")
	assert_true(_classifier.is_supplementary_tool("compare_render_screenshots"), "compare_render_screenshots should be supplementary")
	assert_true(_classifier.is_supplementary_tool("inspect_tileset_resource"), "inspect_tileset_resource should be supplementary")
	assert_true(_classifier.is_supplementary_tool("reimport_resources"), "reimport_resources should be supplementary")
	assert_true(_classifier.is_supplementary_tool("get_import_metadata"), "get_import_metadata should be supplementary")
	assert_true(_classifier.is_supplementary_tool("get_resource_uid_info"), "get_resource_uid_info should be supplementary")
	assert_true(_classifier.is_supplementary_tool("fix_resource_uid"), "fix_resource_uid should be supplementary")
	assert_true(_classifier.is_supplementary_tool("get_resource_dependencies"), "get_resource_dependencies should be supplementary")
	assert_true(_classifier.is_supplementary_tool("scan_missing_resource_dependencies"), "scan_missing_resource_dependencies should be supplementary")
	assert_true(_classifier.is_supplementary_tool("scan_cyclic_resource_dependencies"), "scan_cyclic_resource_dependencies should be supplementary")
	assert_true(_classifier.is_supplementary_tool("detect_broken_scripts"), "detect_broken_scripts should be supplementary")
	assert_true(_classifier.is_supplementary_tool("audit_project_health"), "audit_project_health should be supplementary")
	assert_true(_classifier.is_supplementary_tool("find_resource_usages"), "find_resource_usages should be supplementary")
	assert_true(_classifier.is_supplementary_tool("list_unused_resources"), "list_unused_resources should be supplementary")
	assert_true(_classifier.is_supplementary_tool("set_control_offset_transform"), "set_control_offset_transform should be supplementary")
	assert_true(_classifier.is_supplementary_tool("set_collision_one_way"), "set_collision_one_way should be supplementary")
	assert_true(_classifier.is_supplementary_tool("create_gradient_texture"), "create_gradient_texture should be supplementary")
	assert_true(_classifier.is_supplementary_tool("pack_pck"), "pack_pck should be supplementary")
	assert_true(_classifier.is_supplementary_tool("configure_render_output"), "configure_render_output should be supplementary")
	assert_true(_classifier.is_supplementary_tool("create_drawable_texture"), "create_drawable_texture should be supplementary")
	assert_true(_classifier.is_supplementary_tool("draw_on_texture"), "draw_on_texture should be supplementary")
	assert_true(_classifier.is_supplementary_tool("validate_shader"), "validate_shader should be supplementary")
	assert_true(_classifier.is_supplementary_tool("manage_export_templates"), "manage_export_templates should be supplementary")
	assert_true(_classifier.is_supplementary_tool("configure_android_export"), "configure_android_export should be supplementary")
	assert_true(_classifier.is_supplementary_tool("create_animation"), "create_animation should be supplementary")
	assert_true(_classifier.is_supplementary_tool("insert_animation_keys"), "insert_animation_keys should be supplementary")

func test_get_core_max_count():
	assert_eq(_classifier.get_core_max_count(), 30, "Core max count should be 30")

func test_get_all_categories():
	var cats: Array = _classifier.get_all_categories()
	assert_true("core" in cats, "Should contain core category")
	assert_true("supplementary" in cats, "Should contain supplementary category")

func test_classifier_no_duplicate_groups():
	var groups: Array = _classifier.get_all_groups()
	var unique: Array = []
	for g in groups:
		if not g in unique:
			unique.append(g)
	assert_eq(groups.size(), unique.size(), "Groups should not contain duplicates")

func test_classifier_no_duplicate_tools():
	var tools: Array = _classifier.get_all_tools()
	var unique: Array = []
	for t in tools:
		if not t in unique:
			unique.append(t)
	assert_eq(tools.size(), unique.size(), "Tools should not contain duplicates")

func test_human_friendly_domains_are_available():
	var domains: Array[String] = _classifier.get_all_domains()
	for expected in ["2d", "3d", "ui", "assets_animation", "debug_test", "shipping"]:
		assert_true(expected in domains, "Domain should be discoverable: " + expected)

func test_2d_domain_excludes_3d_only_tools():
	var tools: Array[String] = _classifier.get_domain_tools("2d")
	assert_true("create_tileset" in tools, "2D includes TileSet authoring")
	assert_true("slice_sprite_sheet" in tools, "2D includes sprite sheet slicing")
	assert_false("generate_3d_asset" in tools, "2D excludes 3D generation")
	assert_false("inspect_gltf_asset" in tools, "2D excludes glTF inspection")

func test_3d_domain_excludes_2d_only_tools():
	var tools: Array[String] = _classifier.get_domain_tools("3d")
	assert_true("generate_3d_asset" in tools, "3D includes 3D generation")
	assert_true("inspect_gltf_asset" in tools, "3D includes glTF inspection")
	assert_false("create_tileset" in tools, "3D excludes TileSet authoring")

func test_domains_keep_shared_core_workflows():
	for domain in ["2d", "3d", "ui"]:
		var tools: Array[String] = _classifier.get_domain_tools(domain)
		assert_true("create_scene" in tools, domain + " includes shared scene creation")
		assert_true("modify_script" in tools, domain + " includes shared scripting")

func test_unknown_domain_is_empty():
	assert_eq(_classifier.get_domain_tools("unknown"), [], "Unknown domains do not broaden scope")

# ----------------------------------------------------------------------------
# 单一数据表一致性测试（MCPToolsManifest）
# ----------------------------------------------------------------------------

## manifest 工具名集合 == classifier 工具名集合，且每个工具的 category/group 逐条一致。
## 防“改了一边忘改另一边”漂移。
func test_manifest_matches_classifier():
	var manifest_names: Array[String] = ManifestScript.tool_names()
	var classifier_names: Array = _classifier.get_all_tools()
	assert_eq(manifest_names.size(), classifier_names.size(),
		"manifest 工具数 %d 应等于 classifier 工具数 %d" % [manifest_names.size(), classifier_names.size()])

	var classifier_set: Dictionary = {}
	for tool_name in classifier_names:
		classifier_set[str(tool_name)] = true

	var missing_in_classifier: Array[String] = []
	for tool_name in manifest_names:
		if not classifier_set.has(tool_name):
			missing_in_classifier.append(tool_name)
	assert_eq(missing_in_classifier.size(), 0,
		"manifest 有但 classifier 没有的工具: " + str(missing_in_classifier))

	var missing_in_manifest: Array[String] = []
	for tool_name in classifier_names:
		if not ManifestScript.TOOLS.has(str(tool_name)):
			missing_in_manifest.append(str(tool_name))
	assert_eq(missing_in_manifest.size(), 0,
		"classifier 有但 manifest 没有的工具: " + str(missing_in_manifest))

	# 分类/分组逐条一致。
	var mismatches: Array[String] = []
	for tool_name in classifier_names:
		var name_str: String = str(tool_name)
		var classifier_category: String = _classifier.get_tool_category(name_str)
		var classifier_group: String = _classifier.get_tool_group(name_str)
		var manifest_category: String = ManifestScript.category_of(name_str)
		var manifest_group: String = ManifestScript.group_of(name_str)
		if classifier_category != manifest_category or classifier_group != manifest_group:
			mismatches.append("%s: classifier=(%s,%s) manifest=(%s,%s)" % [
				name_str, classifier_category, classifier_group, manifest_category, manifest_group])
	assert_eq(mismatches.size(), 0,
		"classifier 与 manifest 分类/分组不一致的工具: " + str(mismatches))

## 运行时注册校验：实例化全部工具模块注册进 server_core，断言每个注册工具的
## category/group 与 manifest 一致。防“新增工具忘改 manifest / register_tool 与
## manifest 不一致”漂移（注册参数无法直接读取，但可通过 get_all_tools() 拿
## MCPTool.category/group 对比）。
func test_manifest_matches_registered_tools():
	_core = load("res://addons/godot_mcp/native_mcp/mcp_server_core.gd").new()
	var load_failures: Array[String] = []
	for path in TOOL_MODULE_PATHS:
		var script: GDScript = load(path)
		if script == null:
			load_failures.append(path)
			continue
		var instance: RefCounted = script.new()
		instance.register_tools(_core)
	assert_eq(load_failures.size(), 0, "工具模块加载失败: " + str(load_failures))

	var registered: Dictionary = _core.get_all_tools()
	assert_eq(registered.size(), ManifestScript.TOOLS.size(),
		"注册工具数 %d 应等于 manifest 工具数 %d" % [registered.size(), ManifestScript.TOOLS.size()])

	var missing_in_manifest: Array[String] = []
	var mismatches: Array[String] = []
	for tool_name in registered:
		var name_str: String = str(tool_name)
		var tool = registered[tool_name]
		if not ManifestScript.TOOLS.has(name_str):
			missing_in_manifest.append(name_str)
			continue
		var manifest_category: String = ManifestScript.category_of(name_str)
		var manifest_group: String = ManifestScript.group_of(name_str)
		if str(tool.category) != manifest_category or str(tool.group) != manifest_group:
			mismatches.append("%s: registered=(%s,%s) manifest=(%s,%s)" % [
				name_str, str(tool.category), str(tool.group), manifest_category, manifest_group])
	assert_eq(missing_in_manifest.size(), 0,
		"已注册但不在 manifest 的工具（新增工具忘改 manifest）: " + str(missing_in_manifest))
	assert_eq(mismatches.size(), 0,
		"register_tool 与 manifest 分类/分组不一致的工具: " + str(mismatches))

	var invalid_cache_reads: Array[String] = []
	for tool_name in _core.CACHEABLE_READ_TOOLS:
		if not registered.has(tool_name):
			invalid_cache_reads.append(tool_name + " (not registered)")
			continue
		var cached_tool = registered[tool_name]
		if not bool(cached_tool.annotations.get("readOnlyHint", false)):
			invalid_cache_reads.append(tool_name + " (not read-only)")
	assert_eq(invalid_cache_reads.size(), 0,
		"结果缓存只允许已注册且 readOnlyHint=true 的工具: " + str(invalid_cache_reads))

## manifest 计数基线：221 总 / 28 core / 189 supplementary / 4 meta。
func test_manifest_counts():
	assert_eq(ManifestScript.TOOLS.size(), 221, "manifest 应包含 221 个工具")
	assert_eq(ManifestScript.count_by_category("core"), 28, "manifest 应有 28 个 core 工具")
	assert_eq(ManifestScript.count_by_category("supplementary"), 189, "manifest 应有 189 个 supplementary 工具")
	assert_eq(ManifestScript.count_by_category("meta"), 4, "manifest 应有 4 个 meta 工具")
	# meta 工具必须包含（classifier 依赖 manifest 提供 meta 特殊处理数据）。
	var meta_names: Array[String] = ManifestScript.tool_names()
	assert_true("list_tool_catalog" in meta_names, "manifest 应包含 list_tool_catalog")
	assert_true("search_tools" in meta_names, "manifest 应包含 search_tools")
	assert_true("get_tool_details" in meta_names, "manifest 应包含 get_tool_details")
	assert_true("enable_tools" in meta_names, "manifest 应包含 enable_tools")
