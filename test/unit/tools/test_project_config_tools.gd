extends "res://addons/gut/test.gd"

# Unit tests for the Batch 4 project configuration tools in
# project_tools_native.gd: set_project_setting, add_project_autoload,
# remove_project_autoload.
#
# Success-path tests use persist=false so they only touch in-memory
# ProjectSettings and never write project.godot. Any in-memory key they set is
# cleared in after_each so other test files are not contaminated.

const TOOL_SCRIPT: String = "res://addons/godot_mcp/tools/project_tools_native.gd"
const TMP_SETTING: String = "application/devin_test/tmp_value"
const TMP_AUTOLOAD: String = "DevinTmpAutoload"
const EXISTING_SCRIPT: String = "res://addons/godot_mcp/runtime/mcp_runtime_probe.gd"

var _tools: RefCounted = null

func before_each():
	_tools = load(TOOL_SCRIPT).new()

func after_each():
	for key in [TMP_SETTING, "autoload/" + TMP_AUTOLOAD]:
		if ProjectSettings.has_setting(key):
			ProjectSettings.set_setting(key, null)
	_tools = null

# --- set_project_setting ----------------------------------------------------

func test_set_project_setting_missing_setting():
	var result: Dictionary = _tools._tool_set_project_setting({"value": 1})
	assert_has(result, "error", "Missing setting should return an error")

func test_set_project_setting_missing_value():
	var result: Dictionary = _tools._tool_set_project_setting({"setting": TMP_SETTING})
	assert_has(result, "error", "Missing value should return an error")

func test_set_project_setting_require_existing_missing():
	var result: Dictionary = _tools._tool_set_project_setting({
		"setting": "application/devin_test/definitely_absent",
		"value": 1,
		"require_existing": true,
		"persist": false
	})
	assert_has(result, "error", "require_existing on absent key should error")

func test_set_project_setting_unknown_value_type():
	var result: Dictionary = _tools._tool_set_project_setting({
		"setting": TMP_SETTING,
		"value": 1,
		"value_type": "banana",
		"persist": false
	})
	assert_has(result, "error", "Unknown value_type should error")

func test_set_project_setting_sets_value():
	var result: Dictionary = _tools._tool_set_project_setting({
		"setting": TMP_SETTING,
		"value": "hello",
		"persist": false
	})
	assert_eq(result.get("status"), "success", "Should succeed")
	assert_false(result.get("existed"), "Key should not have existed")
	assert_false(result.get("persisted"), "Should not persist when persist=false")
	assert_eq(ProjectSettings.get_setting(TMP_SETTING), "hello", "Setting should be stored in memory")

func test_set_project_setting_coerces_int_from_string():
	var result: Dictionary = _tools._tool_set_project_setting({
		"setting": TMP_SETTING,
		"value": "1920",
		"value_type": "int",
		"persist": false
	})
	assert_eq(result.get("status"), "success", "Should succeed")
	assert_eq(typeof(result.get("new")), TYPE_INT, "Coerced value should be an int")
	assert_eq(result.get("new"), 1920, "Coerced value should equal 1920")

func test_set_project_setting_coerces_bool_false():
	var result: Dictionary = _tools._tool_set_project_setting({
		"setting": TMP_SETTING,
		"value": "false",
		"value_type": "bool",
		"persist": false
	})
	assert_eq(result.get("status"), "success", "Should succeed")
	assert_eq(result.get("new"), false, "String 'false' should coerce to bool false")

func test_set_project_setting_coerces_vector2():
	var result: Dictionary = _tools._tool_set_project_setting({
		"setting": TMP_SETTING,
		"value": [320, 180],
		"value_type": "vector2",
		"persist": false
	})
	assert_eq(result.get("status"), "success", "Should succeed")
	assert_eq(result.get("new"), Vector2(320, 180), "Array should coerce to Vector2")

# --- add_project_autoload ---------------------------------------------------

func test_add_autoload_missing_name():
	var result: Dictionary = _tools._tool_add_project_autoload({"path": EXISTING_SCRIPT})
	assert_has(result, "error", "Missing name should return an error")

func test_add_autoload_missing_path():
	var result: Dictionary = _tools._tool_add_project_autoload({"name": TMP_AUTOLOAD})
	assert_has(result, "error", "Missing path should return an error")

func test_add_autoload_invalid_name():
	var result: Dictionary = _tools._tool_add_project_autoload({
		"name": "1Bad Name",
		"path": EXISTING_SCRIPT,
		"persist": false
	})
	assert_has(result, "error", "Invalid identifier name should return an error")

func test_add_autoload_path_not_found():
	var result: Dictionary = _tools._tool_add_project_autoload({
		"name": TMP_AUTOLOAD,
		"path": "res://does/not/exist.gd",
		"persist": false
	})
	assert_has(result, "error", "Nonexistent path should return an error")

func test_add_autoload_existing_without_overwrite():
	# MCPRuntimeProbe is declared in project.godot, so it already exists. The full
	# suite runs 1000+ tests in one engine process and earlier tests can mutate
	# in-memory ProjectSettings, so we assert the "already exists" precondition
	# explicitly instead of relying on the global autoload surviving intact.
	var probe_key: String = "autoload/MCPRuntimeProbe"
	if not ProjectSettings.has_setting(probe_key):
		ProjectSettings.set_setting(probe_key, "*" + EXISTING_SCRIPT)
	var result: Dictionary = _tools._tool_add_project_autoload({
		"name": "MCPRuntimeProbe",
		"path": EXISTING_SCRIPT,
		"persist": false
	})
	assert_has(result, "error", "Existing autoload without overwrite should error")

func test_add_autoload_success():
	var result: Dictionary = _tools._tool_add_project_autoload({
		"name": TMP_AUTOLOAD,
		"path": EXISTING_SCRIPT,
		"persist": false
	})
	assert_eq(result.get("status"), "success", "Should succeed")
	assert_true(result.get("enabled"), "Default should be enabled")
	assert_false(result.get("replaced"), "Should not have replaced an existing entry")
	var stored: String = str(ProjectSettings.get_setting("autoload/" + TMP_AUTOLOAD))
	assert_true(stored.begins_with("*"), "Enabled autoload should be stored with '*' prefix")

func test_add_autoload_disabled_no_prefix():
	var result: Dictionary = _tools._tool_add_project_autoload({
		"name": TMP_AUTOLOAD,
		"path": EXISTING_SCRIPT,
		"enabled": false,
		"persist": false
	})
	assert_eq(result.get("status"), "success", "Should succeed")
	var stored: String = str(ProjectSettings.get_setting("autoload/" + TMP_AUTOLOAD))
	assert_false(stored.begins_with("*"), "Disabled autoload should not have '*' prefix")

# --- remove_project_autoload ------------------------------------------------

func test_remove_autoload_missing_name():
	var result: Dictionary = _tools._tool_remove_project_autoload({})
	assert_has(result, "error", "Missing name should return an error")

func test_remove_autoload_not_found():
	var result: Dictionary = _tools._tool_remove_project_autoload({
		"name": "DevinDefinitelyAbsentAutoload",
		"persist": false
	})
	assert_has(result, "error", "Removing a missing autoload should error")

func test_remove_autoload_success():
	# Seed an in-memory autoload, then remove it.
	ProjectSettings.set_setting("autoload/" + TMP_AUTOLOAD, "*" + EXISTING_SCRIPT)
	var result: Dictionary = _tools._tool_remove_project_autoload({
		"name": TMP_AUTOLOAD,
		"persist": false
	})
	assert_eq(result.get("status"), "success", "Should succeed")
	assert_false(ProjectSettings.has_setting("autoload/" + TMP_AUTOLOAD), "Autoload should be removed from memory")
