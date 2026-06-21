extends "res://addons/gut/test.gd"

# Unit tests for the Batch 3 UI theme tools in project_tools_native.gd:
# create_theme, set_theme_item, set_default_theme.

const TOOL_SCRIPT: String = "res://addons/godot_mcp/tools/project_tools_native.gd"
const TMP_DIR: String = "res://.test_tmp_theme"

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

# --- create_theme -----------------------------------------------------------

func test_create_theme_missing_path():
	var result: Dictionary = _tools._tool_create_theme({})
	assert_has(result, "error", "Missing theme_path should return an error")

func test_create_theme_rejects_bad_extension():
	var result: Dictionary = _tools._tool_create_theme({"theme_path": _tmp_path("nope.txt")})
	assert_has(result, "error", "Non-theme extension should return an error")

func test_create_theme_creates_file():
	var path: String = _tmp_path("card_theme.tres")
	var result: Dictionary = _tools._tool_create_theme({
		"theme_path": path,
		"default_base_scale": 1.5,
		"default_font_size": 18
	})
	assert_eq(result.get("status"), "success", "Should create the theme")
	assert_true(ResourceLoader.exists(path), "Theme file should exist on disk")
	var loaded: Theme = ResourceLoader.load(path) as Theme
	assert_ne(loaded, null, "Saved file should load as a Theme")
	assert_almost_eq(loaded.default_base_scale, 1.5, 0.001, "default_base_scale should round-trip")
	assert_eq(loaded.default_font_size, 18, "default_font_size should round-trip")

func test_create_theme_missing_font_path():
	var result: Dictionary = _tools._tool_create_theme({
		"theme_path": _tmp_path("with_font.tres"),
		"default_font_path": "res://.test_tmp_theme/no_such_font.tres"
	})
	assert_has(result, "error", "Nonexistent default font should return an error")

# --- set_theme_item ---------------------------------------------------------

func test_set_theme_item_missing_params():
	var result: Dictionary = _tools._tool_set_theme_item({"theme_path": _tmp_path("x.tres")})
	assert_has(result, "error", "Missing item params should return an error")

func test_set_theme_item_invalid_item_type():
	var path: String = _tmp_path("inv.tres")
	_tools._tool_create_theme({"theme_path": path})
	var result: Dictionary = _tools._tool_set_theme_item({
		"theme_path": path,
		"item_type": "bogus",
		"item_name": "font_color",
		"theme_type": "Label",
		"value": "#ffffff"
	})
	assert_has(result, "error", "Invalid item_type should return an error")

func test_set_theme_item_missing_theme_file():
	var result: Dictionary = _tools._tool_set_theme_item({
		"theme_path": _tmp_path("ghost.tres"),
		"item_type": "color",
		"item_name": "font_color",
		"theme_type": "Label",
		"value": "#ffffff"
	})
	assert_has(result, "error", "Nonexistent theme should return an error")

func test_set_theme_item_sets_color():
	var path: String = _tmp_path("colors.tres")
	_tools._tool_create_theme({"theme_path": path})
	var result: Dictionary = _tools._tool_set_theme_item({
		"theme_path": path,
		"item_type": "color",
		"item_name": "font_color",
		"theme_type": "Label",
		"value": {"r": 1.0, "g": 0.0, "b": 0.0, "a": 1.0}
	})
	assert_eq(result.get("status"), "success", "Should set the color item")
	var loaded: Theme = ResourceLoader.load(path) as Theme
	assert_true(loaded.has_color("font_color", "Label"), "Theme should have the color item")
	assert_eq(loaded.get_color("font_color", "Label"), Color(1, 0, 0, 1), "Color value should round-trip")

func test_set_theme_item_sets_constant_and_font_size():
	var path: String = _tmp_path("nums.tres")
	_tools._tool_create_theme({"theme_path": path})
	_tools._tool_set_theme_item({
		"theme_path": path, "item_type": "constant",
		"item_name": "h_separation", "theme_type": "HBoxContainer", "value": 12
	})
	var result: Dictionary = _tools._tool_set_theme_item({
		"theme_path": path, "item_type": "font_size",
		"item_name": "font_size", "theme_type": "Button", "value": 24
	})
	assert_eq(result.get("status"), "success", "Should set the font_size item")
	var loaded: Theme = ResourceLoader.load(path) as Theme
	assert_eq(loaded.get_constant("h_separation", "HBoxContainer"), 12, "Constant should round-trip")
	assert_eq(loaded.get_font_size("font_size", "Button"), 24, "Font size should round-trip")

func test_set_theme_item_font_requires_resource():
	var path: String = _tmp_path("font_item.tres")
	_tools._tool_create_theme({"theme_path": path})
	var result: Dictionary = _tools._tool_set_theme_item({
		"theme_path": path, "item_type": "font",
		"item_name": "font", "theme_type": "Label",
		"value": "res://.test_tmp_theme/no_such_font.tres"
	})
	assert_has(result, "error", "Missing font resource should return an error")

# --- set_default_theme (validation branches only; success writes project.godot) ---

func test_set_default_theme_missing_path():
	var result: Dictionary = _tools._tool_set_default_theme({})
	assert_has(result, "error", "Missing theme_path without clear should return an error")

func test_set_default_theme_missing_file():
	var result: Dictionary = _tools._tool_set_default_theme({"theme_path": _tmp_path("ghost_theme.tres")})
	assert_has(result, "error", "Nonexistent theme should return an error")

func test_set_default_theme_rejects_bad_extension():
	var result: Dictionary = _tools._tool_set_default_theme({"theme_path": _tmp_path("nope.txt")})
	assert_has(result, "error", "Non-theme extension should return an error")
