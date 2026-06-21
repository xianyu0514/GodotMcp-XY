extends "res://addons/gut/test.gd"

# Unit tests for the Batch 8 TileSet layer tools (project_tools_native.gd):
# configure_tileset_layers, set_tile_collision_polygon, set_tile_terrain.
# These tools operate on saved TileSet (.tres) files, so the success path is
# fully exercised headless: build a TileSet with an atlas tile, save it, run
# the tool, reload from disk and assert the layers / tile data round-trip.

const PROJECT_TOOL_SCRIPT: String = "res://addons/godot_mcp/tools/project_tools_native.gd"
const TMP_DIR: String = "res://.test_tmp_tileset_layers"

var _project_tools: RefCounted = null

func before_each():
	_project_tools = load(PROJECT_TOOL_SCRIPT).new()
	_cleanup_tmp_dir()
	DirAccess.make_dir_recursive_absolute(TMP_DIR)

func after_each():
	_cleanup_tmp_dir()
	_project_tools = null

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

# Build a TileSet on disk with one atlas source (id 0) holding a tile at (0,0).
func _make_tileset(file_name: String = "set.tres") -> String:
	var image: Image = Image.create(16, 16, false, Image.FORMAT_RGBA8)
	image.fill(Color(1, 1, 1, 1))
	var texture: ImageTexture = ImageTexture.create_from_image(image)
	var atlas: TileSetAtlasSource = TileSetAtlasSource.new()
	atlas.texture = texture
	atlas.texture_region_size = Vector2i(16, 16)
	atlas.create_tile(Vector2i(0, 0))
	var tile_set: TileSet = TileSet.new()
	tile_set.tile_size = Vector2i(16, 16)
	tile_set.add_source(atlas, 0)
	var path: String = _tmp_path(file_name)
	var err: Error = ResourceSaver.save(tile_set, path)
	assert_eq(err, OK, "Fixture TileSet should save")
	return path

# --- configure_tileset_layers: validation -----------------------------------

func test_configure_missing_path():
	var result: Dictionary = _project_tools._tool_configure_tileset_layers({})
	assert_has(result, "error", "Missing tileset_path should error")

func test_configure_missing_tileset_file():
	var result: Dictionary = _project_tools._tool_configure_tileset_layers({
		"tileset_path": _tmp_path("ghost.tres")
	})
	assert_has(result, "error", "Nonexistent TileSet should error")

func test_configure_bad_terrain_mode():
	var path: String = _make_tileset()
	var result: Dictionary = _project_tools._tool_configure_tileset_layers({
		"tileset_path": path,
		"terrain_sets": [{"mode": "diagonal"}]
	})
	assert_has(result, "error", "Invalid terrain mode should error")

func test_configure_bad_custom_data_type():
	var path: String = _make_tileset()
	var result: Dictionary = _project_tools._tool_configure_tileset_layers({
		"tileset_path": path,
		"custom_data_layers": [{"name": "weight", "type": 9999}]
	})
	assert_has(result, "error", "Out-of-range Variant type should error")

func test_configure_rejects_non_array_physics():
	var path: String = _make_tileset()
	var result: Dictionary = _project_tools._tool_configure_tileset_layers({
		"tileset_path": path,
		"physics_layers": {"collision_layer": 1}
	})
	assert_has(result, "error", "physics_layers must be an array")

# --- configure_tileset_layers: success round-trip ----------------------------

func test_configure_all_layer_types_roundtrip():
	var path: String = _make_tileset()
	var result: Dictionary = _project_tools._tool_configure_tileset_layers({
		"tileset_path": path,
		"physics_layers": [{"collision_layer": 2, "collision_mask": 3}],
		"navigation_layers": [{"layers": 1}],
		"custom_data_layers": [{"name": "weight", "type": TYPE_INT}],
		"terrain_sets": [{"mode": "corners_and_sides", "terrains": [{"name": "grass", "color": "#00ff00"}]}]
	})
	assert_eq(result.get("status"), "success", "Should configure layers")
	assert_eq(result.get("physics_layers_count"), 1, "One physics layer")
	assert_eq(result.get("navigation_layers_count"), 1, "One navigation layer")
	assert_eq(result.get("custom_data_layers_count"), 1, "One custom data layer")
	assert_eq(result.get("terrain_sets_count"), 1, "One terrain set")

	var loaded: TileSet = ResourceLoader.load(path) as TileSet
	assert_eq(loaded.get_physics_layers_count(), 1, "Physics layer persisted")
	assert_eq(loaded.get_physics_layer_collision_layer(0), 2, "collision_layer persisted")
	assert_eq(loaded.get_physics_layer_collision_mask(0), 3, "collision_mask persisted")
	assert_eq(loaded.get_navigation_layers_count(), 1, "Navigation layer persisted")
	assert_eq(loaded.get_custom_data_layers_count(), 1, "Custom data layer persisted")
	assert_eq(loaded.get_custom_data_layer_name(0), "weight", "Custom data name persisted")
	assert_eq(loaded.get_custom_data_layer_type(0), TYPE_INT, "Custom data type persisted")
	assert_eq(loaded.get_terrain_sets_count(), 1, "Terrain set persisted")
	assert_eq(loaded.get_terrains_count(0), 1, "Terrain persisted")
	assert_eq(loaded.get_terrain_name(0, 0), "grass", "Terrain name persisted")

func test_configure_appends_existing_layers():
	var path: String = _make_tileset()
	_project_tools._tool_configure_tileset_layers({
		"tileset_path": path, "physics_layers": [{"collision_layer": 1}]
	})
	var result: Dictionary = _project_tools._tool_configure_tileset_layers({
		"tileset_path": path, "physics_layers": [{"collision_layer": 1}]
	})
	assert_eq(result.get("physics_layers_count"), 2, "Second call appends, not replaces")
	assert_eq(result.get("physics_layers_added"), 1, "Only one added this call")

# --- set_tile_collision_polygon ----------------------------------------------

func test_collision_missing_required():
	var result: Dictionary = _project_tools._tool_set_tile_collision_polygon({"tileset_path": _tmp_path("x.tres")})
	assert_has(result, "error", "Missing source_id/tile_coords should error")

func test_collision_physics_layer_out_of_range():
	var path: String = _make_tileset()
	var result: Dictionary = _project_tools._tool_set_tile_collision_polygon({
		"tileset_path": path, "source_id": 0, "tile_coords": [0, 0], "physics_layer": 0
	})
	assert_has(result, "error", "No physics layers yet -> out of range")
	assert_true(result.get("error", "").contains("out of range"), "Error mentions range")

func test_collision_unknown_tile():
	var path: String = _make_tileset()
	_project_tools._tool_configure_tileset_layers({"tileset_path": path, "physics_layers": [{}]})
	var result: Dictionary = _project_tools._tool_set_tile_collision_polygon({
		"tileset_path": path, "source_id": 0, "tile_coords": [5, 5], "physics_layer": 0
	})
	assert_has(result, "error", "Nonexistent tile should error")

func test_collision_auto_rectangle_roundtrip():
	var path: String = _make_tileset()
	_project_tools._tool_configure_tileset_layers({"tileset_path": path, "physics_layers": [{}]})
	var result: Dictionary = _project_tools._tool_set_tile_collision_polygon({
		"tileset_path": path, "source_id": 0, "tile_coords": [0, 0], "physics_layer": 0
	})
	assert_eq(result.get("status"), "success", "Should set the collision polygon")
	# Full-tile rect for 16x16 -> half extents 8, 4 corners.
	assert_eq(result.get("polygon_points"), [[-8.0, -8.0], [8.0, -8.0], [8.0, 8.0], [-8.0, 8.0]], "Auto rect covers the tile")

	var loaded: TileSet = ResourceLoader.load(path) as TileSet
	var atlas: TileSetAtlasSource = loaded.get_source(0) as TileSetAtlasSource
	var td: TileData = atlas.get_tile_data(Vector2i(0, 0), 0)
	assert_eq(td.get_collision_polygons_count(0), 1, "One polygon persisted on layer 0")
	assert_eq(td.get_collision_polygon_points(0, 0).size(), 4, "Rect has 4 vertices")

func test_collision_custom_points_and_one_way():
	var path: String = _make_tileset()
	_project_tools._tool_configure_tileset_layers({"tileset_path": path, "physics_layers": [{}]})
	var result: Dictionary = _project_tools._tool_set_tile_collision_polygon({
		"tileset_path": path, "source_id": 0, "tile_coords": [0, 0], "physics_layer": 0,
		"points": [[-8, 0], [8, 0], [8, 8], [-8, 8]], "one_way": true
	})
	assert_eq(result.get("status"), "success", "Custom polygon should set")
	assert_eq(result.get("one_way"), true, "one_way reported")
	var loaded: TileSet = ResourceLoader.load(path) as TileSet
	var atlas: TileSetAtlasSource = loaded.get_source(0) as TileSetAtlasSource
	var td: TileData = atlas.get_tile_data(Vector2i(0, 0), 0)
	assert_true(td.is_collision_polygon_one_way(0, 0), "one_way persisted")

func test_collision_rejects_degenerate_points():
	var path: String = _make_tileset()
	_project_tools._tool_configure_tileset_layers({"tileset_path": path, "physics_layers": [{}]})
	var result: Dictionary = _project_tools._tool_set_tile_collision_polygon({
		"tileset_path": path, "source_id": 0, "tile_coords": [0, 0], "physics_layer": 0,
		"points": [[0, 0], [8, 8]]
	})
	assert_has(result, "error", "Fewer than 3 points should error")

# --- set_tile_terrain --------------------------------------------------------

func test_terrain_missing_required():
	var result: Dictionary = _project_tools._tool_set_tile_terrain({
		"tileset_path": _tmp_path("x.tres"), "source_id": 0, "tile_coords": [0, 0]
	})
	assert_has(result, "error", "Missing terrain_set/terrain should error")

func test_terrain_set_out_of_range():
	var path: String = _make_tileset()
	var result: Dictionary = _project_tools._tool_set_tile_terrain({
		"tileset_path": path, "source_id": 0, "tile_coords": [0, 0],
		"terrain_set": 0, "terrain": 0
	})
	assert_has(result, "error", "No terrain sets -> out of range")

func test_terrain_unknown_peering_neighbor():
	var path: String = _make_tileset()
	_project_tools._tool_configure_tileset_layers({
		"tileset_path": path,
		"terrain_sets": [{"mode": "corners_and_sides", "terrains": [{"name": "grass"}]}]
	})
	var result: Dictionary = _project_tools._tool_set_tile_terrain({
		"tileset_path": path, "source_id": 0, "tile_coords": [0, 0],
		"terrain_set": 0, "terrain": 0, "peering_bits": {"northwest": 0}
	})
	assert_has(result, "error", "Unknown neighbor name should error")

func test_terrain_assignment_roundtrip():
	var path: String = _make_tileset()
	_project_tools._tool_configure_tileset_layers({
		"tileset_path": path,
		"terrain_sets": [{"mode": "corners_and_sides", "terrains": [{"name": "grass"}]}]
	})
	var result: Dictionary = _project_tools._tool_set_tile_terrain({
		"tileset_path": path, "source_id": 0, "tile_coords": [0, 0],
		"terrain_set": 0, "terrain": 0, "peering_bits": {"top_side": 0, "left_side": 0}
	})
	assert_eq(result.get("status"), "success", "Terrain should assign")
	assert_eq((result.get("peering_bits_set") as Array).size(), 2, "Two peering bits set")

	var loaded: TileSet = ResourceLoader.load(path) as TileSet
	var atlas: TileSetAtlasSource = loaded.get_source(0) as TileSetAtlasSource
	var td: TileData = atlas.get_tile_data(Vector2i(0, 0), 0)
	assert_eq(td.terrain_set, 0, "terrain_set persisted")
	assert_eq(td.terrain, 0, "terrain persisted")
	assert_eq(td.get_terrain_peering_bit(TileSet.CELL_NEIGHBOR_TOP_SIDE), 0, "Peering bit persisted")
