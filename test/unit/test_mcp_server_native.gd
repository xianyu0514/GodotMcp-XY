extends "res://addons/gut/test.gd"

var _plugin_script: GDScript = null

func before_each():
	_plugin_script = load("res://addons/godot_mcp/mcp_server_native.gd")

func after_each():
	_plugin_script = null

func test_plugin_script_loads():
	assert_ne(_plugin_script, null, "Plugin script should load successfully")

func test_plugin_has_enter_tree():
	assert_true(_plugin_script.has_method("_enter_tree") or _plugin_script.get_script_method_list().any(func(m): return m.name == "_enter_tree"), "Should have _enter_tree method")

func test_plugin_has_exit_tree():
	var methods: Array = _plugin_script.get_script_method_list()
	var method_names: Array = methods.map(func(m): return m["name"])
	assert_true(method_names.has("_exit_tree"), "Should have _exit_tree method")

func test_plugin_has_start_server():
	var methods: Array = _plugin_script.get_script_method_list()
	var method_names: Array = methods.map(func(m): return m["name"])
	assert_true(method_names.has("start_server"), "Should have start_server method")

func test_plugin_has_stop_server():
	var methods: Array = _plugin_script.get_script_method_list()
	var method_names: Array = methods.map(func(m): return m["name"])
	assert_true(method_names.has("stop_server"), "Should have stop_server method")

func test_plugin_has_get_server_status():
	var methods: Array = _plugin_script.get_script_method_list()
	var method_names: Array = methods.map(func(m): return m["name"])
	assert_true(method_names.has("get_server_status"), "Should have get_server_status method")

func test_find_files_recursive():
	var result: Array = []
	var dir: DirAccess = DirAccess.open("res://")
	if dir:
		_plugin_script._find_files_recursive(dir, ".tscn", result)
		assert_true(result.size() > 0, "Should find at least one .tscn file in the project")

func test_find_files_recursive_gd():
	var result: Array = []
	var dir: DirAccess = DirAccess.open("res://")
	if dir:
		_plugin_script._find_files_recursive(dir, ".gd", result)
		assert_true(result.size() > 0, "Should find at least one .gd file in the project")

func test_count_nodes():
	var root: Node = Node.new()
	root.name = "Root"
	add_child_autofree(root)
	var child: Node = Node.new()
	child.name = "Child"
	root.add_child(child)
	var count: int = _plugin_script._count_nodes(root)
	assert_eq(count, 2, "Should count root + 1 child")

func test_get_node_tree():
	var root: Node = Node.new()
	root.name = "Root"
	add_child_autofree(root)
	var child: Node = Node.new()
	child.name = "Child1"
	root.add_child(child)
	var tree: Array = _plugin_script._get_node_tree(root, 1)
	assert_eq(tree.size(), 1, "Should have 1 child")
	assert_eq(tree[0]["name"], "Child1", "Child name should match")

func test_get_godot_version():
	var version: Dictionary = _plugin_script._get_godot_version()
	assert_true(version.has("version"), "Should have version key")
	assert_true(version.has("major"), "Should have major key")
	assert_true(version["major"] >= 4, "Godot major should be >= 4")

func test_plugin_name():
	var methods: Array = _plugin_script.get_script_method_list()
	var method_names: Array = methods.map(func(m): return m["name"])
	assert_true(method_names.has("_get_plugin_name"), "Should have _get_plugin_name method")
	assert_true(method_names.has("_has_main_screen"), "Should have _has_main_screen method for main screen plugin")
	assert_true(method_names.has("_make_visible"), "Should have _make_visible method for main screen plugin")
	assert_true(method_names.has("_get_plugin_icon"), "Should have _get_plugin_icon method for main screen plugin")
	assert_true(method_names.has("_create_main_screen_panel"), "Should have _create_main_screen_panel method")

func test_export_variables():
	var script_props: Array = _plugin_script.get_script_property_list()
	var prop_names: Array = script_props.map(func(p): return p["name"])
	assert_true(prop_names.has("auto_start"), "Should have auto_start export")
	assert_true(prop_names.has("transport_mode"), "Should have transport_mode export")
	assert_true(prop_names.has("http_port"), "Should have http_port export")
	assert_true(prop_names.has("auth_enabled"), "Should have auth_enabled export")
	assert_true(prop_names.has("log_level"), "Should have log_level export")
	assert_true(prop_names.has("vibe_coding_mode"), "Should have vibe_coding_mode export")

func test_has_load_tool_states_in_enter_tree():
	var methods: Array = _plugin_script.get_script_method_list()
	var method_names: Array = methods.map(func(m): return m["name"])
	assert_true(method_names.has("_enter_tree"), "Should have _enter_tree method")
	# Verify load_tool_states is called before UI creation (test _enter_tree calls it)
	var source_code: String = _plugin_script.source_code
	assert_true(source_code.contains("load_tool_states"), "_enter_tree should call load_tool_states")
	assert_true(source_code.contains("_create_main_screen_panel"), "Should still create main screen panel")
	# Verify correct ordering: load_tool_states before _create_main_screen_panel
	var load_pos: int = source_code.find("load_tool_states")
	var panel_pos: int = source_code.find("_create_main_screen_panel")
	assert_true(load_pos >= 0, "load_tool_states should exist in source")
	assert_true(panel_pos >= 0, "_create_main_screen_panel should exist in source")
	assert_true(load_pos < panel_pos, "load_tool_states should be called BEFORE _create_main_screen_panel")

func test_has_autoload_registration_methods():
	var methods: Array = _plugin_script.get_script_method_list()
	var method_names: Array = methods.map(func(m): return m["name"])
	assert_true(method_names.has("_ensure_runtime_probe_autoload"), "Should have _ensure_runtime_probe_autoload method")
	assert_true(method_names.has("_remove_runtime_probe_autoload"), "Should have _remove_runtime_probe_autoload method")

func test_autoload_registered_in_enter_tree():
	var methods: Array = _plugin_script.get_script_method_list()
	var method_names: Array = methods.map(func(m): return m["name"])
	assert_true(method_names.has("_enter_tree"), "Should have _enter_tree method")
	var source_code: String = _plugin_script.source_code
	# Verify _ensure_runtime_probe_autoload is called in _enter_tree
	assert_true(source_code.contains("_ensure_runtime_probe_autoload"), "_enter_tree should call _ensure_runtime_probe_autoload")
	# Verify correct ordering: _register_all_tools -> _ensure_runtime_probe_autoload -> _create_main_screen_panel
	var register_pos: int = source_code.find("_register_all_tools")
	var autoload_pos: int = source_code.find("_ensure_runtime_probe_autoload")
	var panel_pos: int = source_code.find("_create_main_screen_panel")
	assert_true(register_pos >= 0, "_register_all_tools should exist in source")
	assert_true(autoload_pos >= 0, "_ensure_runtime_probe_autoload should exist in source")
	assert_true(panel_pos >= 0, "_create_main_screen_panel should exist in source")
	assert_true(register_pos < autoload_pos, "_ensure_runtime_probe_autoload should be called AFTER _register_all_tools")
	assert_true(autoload_pos < panel_pos, "_ensure_runtime_probe_autoload should be called BEFORE _create_main_screen_panel")

func test_autoload_removed_in_exit_tree():
	var source_code: String = _plugin_script.source_code
	assert_true(source_code.contains("_remove_runtime_probe_autoload"), "_exit_tree should call _remove_runtime_probe_autoload")

func test_plugin_has_apply_auth_config():
	var methods: Array = _plugin_script.get_script_method_list()
	var method_names: Array = methods.map(func(m): return m["name"])
	assert_true(method_names.has("_apply_auth_config"), "Should have _apply_auth_config method")

func test_plugin_has_should_enable_auth():
	var methods: Array = _plugin_script.get_script_method_list()
	var method_names: Array = methods.map(func(m): return m["name"])
	assert_true(method_names.has("should_enable_auth"), "Should have should_enable_auth static method")

func test_should_enable_auth_gating():
	assert_true(_plugin_script.should_enable_auth(true, "http"), "Enabled + http transport should enable auth")
	assert_false(_plugin_script.should_enable_auth(false, "http"), "Disabled auth should not enable auth")
	assert_false(_plugin_script.should_enable_auth(true, "stdio"), "stdio transport should not enable HTTP auth")
	assert_false(_plugin_script.should_enable_auth(false, "stdio"), "Disabled + stdio should not enable auth")

func test_apply_auth_config_called_in_start_path():
	var source_code: String = _plugin_script.source_code
	var start_pos: int = source_code.find("func _start_native_server")
	assert_true(start_pos >= 0, "_start_native_server should exist")
	var overrides_pos: int = source_code.find("_apply_cmdline_overrides()", start_pos)
	var apply_pos: int = source_code.find("_apply_auth_config()", start_pos)
	var start_call_pos: int = source_code.find("_native_server.start()", start_pos)
	assert_true(overrides_pos >= 0, "cmdline overrides should be applied in start path")
	assert_true(apply_pos >= 0, "_apply_auth_config() should be called in _start_native_server")
	assert_true(start_call_pos >= 0, "server start() should be called in start path")
	assert_true(overrides_pos < apply_pos, "_apply_auth_config() should run AFTER cmdline overrides")
	assert_true(apply_pos < start_call_pos, "_apply_auth_config() should run BEFORE server start()")

func test_enter_tree_calls_apply_auth_config():
	var source_code: String = _plugin_script.source_code
	var enter_pos: int = source_code.find("func _enter_tree")
	var exit_pos: int = source_code.find("func _exit_tree")
	var apply_pos: int = source_code.find("_apply_auth_config()", enter_pos)
	assert_true(enter_pos >= 0 and exit_pos >= 0, "enter/exit tree methods should exist")
	assert_true(apply_pos >= 0 and apply_pos < exit_pos, "_enter_tree should call _apply_auth_config()")

func test_apply_auth_config_sets_or_clears_auth_manager():
	var source_code: String = _plugin_script.source_code
	var apply_pos: int = source_code.find("func _apply_auth_config")
	assert_true(apply_pos >= 0, "_apply_auth_config should exist")
	var body: String = source_code.substr(apply_pos, 900)
	assert_true(body.contains("McpAuthManager.new()"), "_apply_auth_config should create McpAuthManager when applicable")
	assert_true(body.contains("set_auth_manager(null)"), "_apply_auth_config should clear the auth manager when not applicable")
	assert_true(body.contains("set_token(auth_token)"), "_apply_auth_config should apply the current auth token")
