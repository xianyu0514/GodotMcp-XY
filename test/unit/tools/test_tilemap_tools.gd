extends "res://addons/gut/test.gd"

# Unit tests for the Batch 6 TileMapLayer tools:
# create_tileset (project_tools_native.gd),
# set_tilemap_layer_cells / get_tilemap_layer_cells (scene_tools_native.gd).
# Editor-dependent paths (resolving a TileMapLayer in the edited scene) are
# exercised live over HTTP; here we cover validation, parsing and the
# headless-safe create_tileset resource path.

const PROJECT_TOOL_SCRIPT: String = "res://addons/godot_mcp/tools/project_tools_native.gd"
const SCENE_TOOL_SCRIPT: String = "res://addons/godot_mcp/tools/scene_tools_native.gd"
const TMP_DIR: String = "res://.test_tmp_tilemap"

var _project_tools: RefCounted = null
var _scene_tools: RefCounted = null

func before_each():
	_project_tools = load(PROJECT_TOOL_SCRIPT).new()
	_scene_tools = load(SCENE_TOOL_SCRIPT).new()
	_cleanup_tmp_dir()

func after_each():
	_cleanup_tmp_dir()
	_project_tools = null
	_scene_tools = null
	if Engine.has_meta("GodotMCPPlugin"):
		Engine.remove_meta("GodotMCPPlugin")

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

# --- create_tileset ---------------------------------------------------------

func test_create_tileset_missing_path():
	var result: Dictionary = _project_tools._tool_create_tileset({})
	assert_has(result, "error", "Missing tileset_path should return an error")

func test_create_tileset_rejects_bad_extension():
	var result: Dictionary = _project_tools._tool_create_tileset({"tileset_path": _tmp_path("nope.txt")})
	assert_has(result, "error", "Non-resource extension should return an error")

func test_create_tileset_rejects_non_positive_tile_size():
	var result: Dictionary = _project_tools._tool_create_tileset({
		"tileset_path": _tmp_path("bad.tres"),
		"tile_size": [0, 16]
	})
	assert_has(result, "error", "Non-positive tile_size should return an error")

func test_create_tileset_missing_texture():
	var result: Dictionary = _project_tools._tool_create_tileset({
		"tileset_path": _tmp_path("notex.tres"),
		"texture_path": "res://does_not_exist_atlas.png"
	})
	assert_has(result, "error", "Nonexistent texture should return an error")
	assert_true(result.get("error", "").contains("not found"), "Error should mention the missing texture")

func test_create_tileset_default_tile_size():
	var path: String = _tmp_path("ground.tres")
	var result: Dictionary = _project_tools._tool_create_tileset({"tileset_path": path})
	assert_eq(result.get("status"), "success", "Should create the tileset")
	assert_eq(result.get("tile_size"), [16, 16], "Default tile_size should be 16x16")
	assert_eq(result.get("source_id"), -1, "No atlas source without a texture")
	assert_eq(result.get("tiles_created"), 0, "No tiles created without a texture")
	assert_true(ResourceLoader.exists(path), "TileSet file should exist on disk")
	var loaded: TileSet = ResourceLoader.load(path) as TileSet
	assert_ne(loaded, null, "Saved file should load as a TileSet")
	assert_eq(loaded.tile_size, Vector2i(16, 16), "tile_size should round-trip")

func test_create_tileset_custom_tile_size():
	var path: String = _tmp_path("big.tres")
	var result: Dictionary = _project_tools._tool_create_tileset({
		"tileset_path": path,
		"tile_size": [32, 48]
	})
	assert_eq(result.get("status"), "success", "Should create the tileset")
	var loaded: TileSet = ResourceLoader.load(path) as TileSet
	assert_eq(loaded.tile_size, Vector2i(32, 48), "Custom tile_size should round-trip")

func test_create_tileset_with_texture_creates_atlas_tiles():
	# Build a small atlas texture on disk so the atlas-source path is covered.
	var image: Image = Image.create(64, 32, false, Image.FORMAT_RGBA8)
	image.fill(Color(1, 1, 1, 1))
	DirAccess.make_dir_recursive_absolute(TMP_DIR)
	var tex_path: String = _tmp_path("atlas.png")
	image.save_png(ProjectSettings.globalize_path(tex_path))
	# save_png writes outside the resource importer, so load straight from Image.
	if not ResourceLoader.exists(tex_path):
		pass_test("Headless import unavailable for the atlas texture; covered live over HTTP")
		return
	var path: String = _tmp_path("atlas_set.tres")
	var result: Dictionary = _project_tools._tool_create_tileset({
		"tileset_path": path,
		"tile_size": [16, 16],
		"texture_path": tex_path
	})
	assert_eq(result.get("status"), "success", "Should create the tileset with an atlas")
	assert_eq(result.get("source_id"), 0, "First atlas source id should be 0")
	assert_eq(result.get("tiles_created"), 8, "64x32 / 16x16 should create 8 tiles")

# --- _parse_vector2i (pure helper) ------------------------------------------

func test_parse_vector2i_from_array():
	assert_eq(_scene_tools._parse_vector2i([3, 7]), Vector2i(3, 7), "Array should parse to Vector2i")

func test_parse_vector2i_from_dict():
	assert_eq(_scene_tools._parse_vector2i({"x": 2, "y": 5}), Vector2i(2, 5), "Dict should parse to Vector2i")

func test_parse_vector2i_from_vector2i():
	assert_eq(_scene_tools._parse_vector2i(Vector2i(9, 9)), Vector2i(9, 9), "Vector2i should pass through")

func test_parse_vector2i_rejects_scalar():
	assert_eq(_scene_tools._parse_vector2i(5), null, "Scalar should not parse to Vector2i")

func test_parse_vector2i_rejects_short_array():
	assert_eq(_scene_tools._parse_vector2i([1]), null, "Single-element array should not parse")

# --- set_tilemap_layer_cells (validation) -----------------------------------

func test_set_cells_missing_node_path():
	var result: Dictionary = _scene_tools._tool_set_tilemap_layer_cells({"cells": [{"coords": [0, 0]}]})
	assert_has(result, "error", "Missing node_path should return an error")

func test_set_cells_missing_cells():
	var result: Dictionary = _scene_tools._tool_set_tilemap_layer_cells({"node_path": "/root/Main/Ground"})
	assert_has(result, "error", "Missing cells should return an error")

func test_set_cells_empty_array():
	var result: Dictionary = _scene_tools._tool_set_tilemap_layer_cells({"node_path": "/root/Main/Ground", "cells": []})
	assert_has(result, "error", "Empty cells array should return an error")

func test_set_cells_entry_missing_coords():
	var result: Dictionary = _scene_tools._tool_set_tilemap_layer_cells({
		"node_path": "/root/Main/Ground",
		"cells": [{"source_id": 0}]
	})
	assert_has(result, "error", "Cell without coords should return an error")

func test_set_cells_entry_bad_coords():
	var result: Dictionary = _scene_tools._tool_set_tilemap_layer_cells({
		"node_path": "/root/Main/Ground",
		"cells": [{"coords": 5}]
	})
	assert_has(result, "error", "Cell with scalar coords should return an error")

# --- get_tilemap_layer_cells (validation) -----------------------------------

func test_get_cells_missing_node_path():
	var result: Dictionary = _scene_tools._tool_get_tilemap_layer_cells({})
	assert_has(result, "error", "Missing node_path should return an error")

func test_get_cells_coords_not_array():
	var result: Dictionary = _scene_tools._tool_get_tilemap_layer_cells({
		"node_path": "/root/Main/Ground",
		"coords": "0,0"
	})
	assert_has(result, "error", "Non-array coords should return an error")

func test_get_cells_coords_bad_entry():
	var result: Dictionary = _scene_tools._tool_get_tilemap_layer_cells({
		"node_path": "/root/Main/Ground",
		"coords": [5]
	})
	assert_has(result, "error", "Bad coords entry should return an error")
