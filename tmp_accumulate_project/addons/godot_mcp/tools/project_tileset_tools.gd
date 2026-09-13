# project_tileset_tools.gd - Project TileSet-domain tools (split from project_tools_native.gd)
# TileSet create / layer config (physics/navigation/custom-data/terrain) / collision / terrain / inspect.

@tool
class_name ProjectTilesetTools
extends RefCounted

var _editor_interface: EditorInterface = null
var _server_core: RefCounted = null

func initialize(editor_interface: EditorInterface) -> void:
	_editor_interface = editor_interface

# ============================================================================
# Tool registration
# ============================================================================

func register_tools(server_core: RefCounted) -> void:
	_server_core = server_core
	_register_inspect_tileset_resource(server_core)
	_register_create_tileset(server_core)
	_register_configure_tileset_layers(server_core)
	_register_set_tile_collision_polygon(server_core)
	_register_set_tile_terrain(server_core)

# ============================================================================
# inspect_tileset_resource - 检查 TileSet 资源
# ============================================================================

func _register_inspect_tileset_resource(server_core: RefCounted) -> void:
	var tool_name: String = "inspect_tileset_resource"
	var description: String = "Inspect a TileSet resource and summarize its sources, atlas tiles, and scene tiles."

	var input_schema: Dictionary = {
		"type": "object",
		"properties": {
			"resource_path": {
				"type": "string",
				"description": "Path to a TileSet resource, such as 'res://tiles/terrain.tres'."
			},
			"include_tiles": {
				"type": "boolean",
				"description": "Whether to include per-tile entries for atlas and scene sources. Default is true."
			}
		},
		"required": ["resource_path"]
	}

	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"resource_path": {"type": "string"},
			"source_count": {"type": "integer"},
			"tile_size": {"type": "object"},
			"sources": {"type": "array"}
		}
	}

	var annotations: Dictionary = {
		"readOnlyHint": true,
		"destructiveHint": false,
		"idempotentHint": true,
		"openWorldHint": false
	}

	server_core.register_tool(tool_name, description, input_schema,
						  Callable(self, "_tool_inspect_tileset_resource"),
						  output_schema, annotations,
						  "supplementary", "Project-Advanced")

func _tool_inspect_tileset_resource(params: Dictionary) -> Dictionary:
	var resource_path: String = str(params.get("resource_path", "")).strip_edges()
	if resource_path.is_empty():
		return {"error": "Missing required parameter: resource_path"}

	var validation: Dictionary = PathValidator.validate_file_path(resource_path, [".tres", ".res"])
	if not validation.get("valid", false):
		return {"error": validation.get("error", "Invalid resource path")}
	resource_path = str(validation.get("sanitized", resource_path))

	if not FileAccess.file_exists(resource_path):
		return {"error": "File not found: " + resource_path}

	var resource: Resource = ResourceLoader.load(resource_path)
	if resource == null:
		return {"error": "Failed to load resource: " + resource_path}
	if not (resource is TileSet):
		return {"error": "Resource is not a TileSet: " + resource_path}

	var tile_set: TileSet = resource as TileSet
	var include_tiles: bool = bool(params.get("include_tiles", true))
	var sources: Array = []
	for index in range(tile_set.get_source_count()):
		var source_id: int = tile_set.get_source_id(index)
		var source: TileSetSource = tile_set.get_source(source_id)
		sources.append(_serialize_tileset_source(source_id, source, include_tiles))

	return {
		"resource_path": resource_path,
		"source_count": tile_set.get_source_count(),
		"tile_size": _serialize_vector2i(tile_set.tile_size),
		"sources": sources
	}


# ============================================================================
# create_tileset - Create and save a TileSet (.tres/.res) for 2D tile maps.
# Optionally add a TileSetAtlasSource from a texture and auto-create the atlas
# tiles in the grid. Pairs with set_tilemap_layer_cells (4.7 TileMapLayer).
# ============================================================================

func _register_create_tileset(server_core: RefCounted) -> void:
	var tool_name: String = "create_tileset"
	var description: String = "Create and save a TileSet resource (.tres/.res) for 2D tile maps consumed by a TileMapLayer (Godot 4.x). Sets tile_size, and optionally adds a TileSetAtlasSource from a texture (texture_region_size defaults to tile_size). When create_tiles is true (default) every grid cell that fits in the texture is created as a tile. Returns the atlas source_id and how many tiles were created."

	var input_schema: Dictionary = {
		"type": "object",
		"properties": {
			"tileset_path": {"type": "string", "description": "Save path for the TileSet (.tres/.res), e.g. res://tilesets/ground.tres."},
			"tile_size": {"type": "array", "description": "Tile grid size in pixels as [w, h] (or {x, y}). Default [16, 16].", "items": {"type": "integer"}},
			"texture_path": {"type": "string", "description": "Optional res:// path to a Texture2D to add as a TileSetAtlasSource."},
			"texture_region_size": {"type": "array", "description": "Atlas tile region size in pixels as [w, h]. Defaults to tile_size.", "items": {"type": "integer"}},
			"create_tiles": {"type": "boolean", "description": "Auto-create every atlas grid tile that fits in the texture. Default true.", "default": true}
		},
		"required": ["tileset_path"]
	}

	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"status": {"type": "string"},
			"tileset_path": {"type": "string"},
			"tile_size": {"type": "array"},
			"source_id": {"type": "integer"},
			"tiles_created": {"type": "integer"}
		}
	}

	var annotations: Dictionary = {
		"readOnlyHint": false,
		"destructiveHint": false,
		"idempotentHint": false,
		"openWorldHint": false
	}

	server_core.register_tool(tool_name, description, input_schema,
						  Callable(self, "_tool_create_tileset"),
						  output_schema, annotations,
						  "supplementary", "Project-Advanced")

func _tool_create_tileset(params: Dictionary) -> Dictionary:
	var tileset_path: String = str(params.get("tileset_path", "")).strip_edges()
	if tileset_path.is_empty():
		return {"error": "Missing required parameter: tileset_path"}

	var validation: Dictionary = PathValidator.validate_file_path(tileset_path, [".tres", ".res"])
	if not validation["valid"]:
		return {"error": "Invalid path: " + validation["error"]}
	tileset_path = validation["sanitized"]

	var tile_size: Vector2i = Vector2i(16, 16)
	if params.has("tile_size"):
		var parsed_size: Variant = _parse_vector2i(params["tile_size"])
		if parsed_size == null:
			return {"error": "Parameter 'tile_size' must be [w, h] or {x, y}"}
		tile_size = parsed_size
	if tile_size.x <= 0 or tile_size.y <= 0:
		return {"error": "tile_size must be positive"}

	var tile_set: TileSet = TileSet.new()
	tile_set.tile_size = tile_size

	var source_id: int = -1
	var tiles_created: int = 0
	var texture_path: String = str(params.get("texture_path", "")).strip_edges()
	if not texture_path.is_empty():
		if not ResourceLoader.exists(texture_path):
			return {"error": "Texture not found: " + texture_path}
		var texture: Texture2D = ResourceLoader.load(texture_path) as Texture2D
		if not texture:
			return {"error": "Resource is not a Texture2D: " + texture_path}

		var region_size: Vector2i = tile_size
		if params.has("texture_region_size"):
			var parsed_region: Variant = _parse_vector2i(params["texture_region_size"])
			if parsed_region == null:
				return {"error": "Parameter 'texture_region_size' must be [w, h] or {x, y}"}
			region_size = parsed_region
		if region_size.x <= 0 or region_size.y <= 0:
			return {"error": "texture_region_size must be positive"}

		var atlas: TileSetAtlasSource = TileSetAtlasSource.new()
		atlas.texture = texture
		atlas.texture_region_size = region_size
		source_id = tile_set.add_source(atlas)

		if bool(params.get("create_tiles", true)):
			var columns: int = int(texture.get_width() / region_size.x)
			var rows: int = int(texture.get_height() / region_size.y)
			for ty in range(rows):
				for tx in range(columns):
					var coords: Vector2i = Vector2i(tx, ty)
					if not atlas.has_tile(coords):
						atlas.create_tile(coords)
						tiles_created += 1

	var dir_path: String = tileset_path.get_base_dir()
	if not dir_path.is_empty() and not DirAccess.dir_exists_absolute(dir_path):
		var mk: Error = DirAccess.make_dir_recursive_absolute(dir_path)
		if mk != OK:
			return {"error": "Failed to create directory: " + dir_path}

	var error: Error = ResourceSaver.save(tile_set, tileset_path)
	if error != OK:
		return {"error": "Failed to save tileset: " + error_string(error)}

	return {
		"status": "success",
		"tileset_path": tileset_path,
		"tile_size": [tile_set.tile_size.x, tile_set.tile_size.y],
		"source_id": source_id,
		"tiles_created": tiles_created
	}

static func _parse_vector2i(value: Variant) -> Variant:
	if value is Vector2i:
		return value
	if value is Vector2:
		return Vector2i(value)
	if value is Dictionary:
		return Vector2i(int(value.get("x", 0)), int(value.get("y", 0)))
	if value is Array and value.size() >= 2:
		return Vector2i(int(value[0]), int(value[1]))
	return null


# ============================================================================
# Batch 8 - TileSet physics / terrain / navigation / custom-data layers
# ============================================================================

const _TILESET_CELL_NEIGHBORS: Dictionary = {
	"right_side": TileSet.CELL_NEIGHBOR_RIGHT_SIDE,
	"bottom_right_corner": TileSet.CELL_NEIGHBOR_BOTTOM_RIGHT_CORNER,
	"bottom_side": TileSet.CELL_NEIGHBOR_BOTTOM_SIDE,
	"bottom_left_corner": TileSet.CELL_NEIGHBOR_BOTTOM_LEFT_CORNER,
	"left_side": TileSet.CELL_NEIGHBOR_LEFT_SIDE,
	"top_left_corner": TileSet.CELL_NEIGHBOR_TOP_LEFT_CORNER,
	"top_side": TileSet.CELL_NEIGHBOR_TOP_SIDE,
	"top_right_corner": TileSet.CELL_NEIGHBOR_TOP_RIGHT_CORNER
}

const _TILESET_TERRAIN_MODES: Dictionary = {
	"corners": TileSet.TERRAIN_MODE_MATCH_CORNERS,
	"sides": TileSet.TERRAIN_MODE_MATCH_SIDES,
	"corners_and_sides": TileSet.TERRAIN_MODE_MATCH_CORNERS_AND_SIDES
}

# Whether a peering-bit neighbor is valid for a terrain set's match mode.
# Godot 4.7 exposes no TileSet.is_valid_terrain_peering_bit(), so derive it
# from the terrain mode: CORNERS_AND_SIDES uses both side and corner bits,
# SIDES uses only side bits, CORNERS uses only corner bits. The neighbor map
# only contains square-tile neighbors (4 sides + 4 corners).
func _is_terrain_peering_bit_valid(tile_set: TileSet, terrain_set: int, neighbor_key: String) -> bool:
	var mode: int = tile_set.get_terrain_set_mode(terrain_set)
	var is_side: bool = neighbor_key.ends_with("_side")
	var is_corner: bool = neighbor_key.ends_with("_corner")
	match mode:
		TileSet.TERRAIN_MODE_MATCH_CORNERS_AND_SIDES:
			return is_side or is_corner
		TileSet.TERRAIN_MODE_MATCH_SIDES:
			return is_side
		TileSet.TERRAIN_MODE_MATCH_CORNERS:
			return is_corner
	return false

func _load_tileset_for_edit(tileset_path: String) -> Dictionary:
	var validation: Dictionary = PathValidator.validate_file_path(tileset_path, [".tres", ".res"])
	if not validation["valid"]:
		return {"error": "Invalid path: " + validation["error"]}
	var sanitized: String = validation["sanitized"]
	if not ResourceLoader.exists(sanitized):
		return {"error": "TileSet not found: " + sanitized}
	var tile_set: TileSet = ResourceLoader.load(sanitized) as TileSet
	if not tile_set:
		return {"error": "Resource is not a TileSet: " + sanitized}
	return {"tile_set": tile_set, "path": sanitized}

func _resolve_atlas_tile_data(tile_set: TileSet, source_id: int, coords: Vector2i, alternative_id: int) -> Dictionary:
	if not tile_set.has_source(source_id):
		return {"error": "TileSet has no source with id %d" % source_id}
	var atlas: TileSetAtlasSource = tile_set.get_source(source_id) as TileSetAtlasSource
	if not atlas:
		return {"error": "Source %d is not a TileSetAtlasSource" % source_id}
	if not atlas.has_tile(coords):
		return {"error": "Atlas source %d has no tile at coords (%d, %d)" % [source_id, coords.x, coords.y]}
	if not atlas.has_alternative_tile(coords, alternative_id):
		return {"error": "Tile (%d, %d) has no alternative with id %d" % [coords.x, coords.y, alternative_id]}
	var tile_data: TileData = atlas.get_tile_data(coords, alternative_id)
	if not tile_data:
		return {"error": "Failed to resolve TileData for tile (%d, %d)" % [coords.x, coords.y]}
	return {"tile_data": tile_data}

# --- configure_tileset_layers --------------------------------------------------

func _register_configure_tileset_layers(server_core: RefCounted) -> void:
	var tool_name: String = "configure_tileset_layers"
	var description: String = "Add and configure layers on an existing TileSet resource (.tres/.res): physics layers (collision_layer/mask bitmasks), navigation layers (layers bitmask), custom data layers (name + Variant type), and terrain sets with terrains (name, color, match mode). New layers are appended; existing layers are preserved. Saves the TileSet back to disk. Use after create_tileset so tiles can support collision, autotiling, navigation, and per-tile metadata."

	var input_schema: Dictionary = {
		"type": "object",
		"properties": {
			"tileset_path": {"type": "string", "description": "Path to an existing TileSet (.tres/.res)."},
			"physics_layers": {"type": "array", "description": "Physics layers to append. Each item is {collision_layer:int=1, collision_mask:int=1} (bitmasks)."},
			"navigation_layers": {"type": "array", "description": "Navigation layers to append. Each item is {layers:int=1} (navigation layers bitmask)."},
			"custom_data_layers": {"type": "array", "description": "Custom data layers to append. Each item is {name:string, type:int}. type is a Variant.Type value (e.g. 4=String, 2=int, 3=float, 1=bool, 5=Vector2, 20=Color). Defaults to 4 (String)."},
			"terrain_sets": {"type": "array", "description": "Terrain sets to append. Each item is {mode:string(corners|sides|corners_and_sides, default corners_and_sides), terrains:[{name:string, color:string|array|object}]}."}
		},
		"required": ["tileset_path"]
	}

	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"status": {"type": "string"},
			"tileset_path": {"type": "string"},
			"physics_layers_count": {"type": "integer"},
			"navigation_layers_count": {"type": "integer"},
			"custom_data_layers_count": {"type": "integer"},
			"terrain_sets_count": {"type": "integer"},
			"physics_layers_added": {"type": "integer"},
			"navigation_layers_added": {"type": "integer"},
			"custom_data_layers_added": {"type": "integer"},
			"terrain_sets_added": {"type": "integer"}
		}
	}

	var annotations: Dictionary = {
		"readOnlyHint": false,
		"destructiveHint": false,
		"idempotentHint": false,
		"openWorldHint": false
	}

	server_core.register_tool(tool_name, description, input_schema,
						  Callable(self, "_tool_configure_tileset_layers"),
						  output_schema, annotations,
						  "supplementary", "Project-Advanced")

func _tool_configure_tileset_layers(params: Dictionary) -> Dictionary:
	var tileset_path: String = str(params.get("tileset_path", "")).strip_edges()
	if tileset_path.is_empty():
		return {"error": "Missing required parameter: tileset_path"}

	var loaded: Dictionary = _load_tileset_for_edit(tileset_path)
	if loaded.has("error"):
		return loaded
	var tile_set: TileSet = loaded["tile_set"]
	var sanitized: String = loaded["path"]

	var physics_added: int = 0
	if params.has("physics_layers"):
		if not (params["physics_layers"] is Array):
			return {"error": "Parameter 'physics_layers' must be an array"}
		for entry in params["physics_layers"]:
			if not (entry is Dictionary):
				return {"error": "Each physics_layers item must be an object"}
			tile_set.add_physics_layer()
			var idx: int = tile_set.get_physics_layers_count() - 1
			tile_set.set_physics_layer_collision_layer(idx, int(entry.get("collision_layer", 1)))
			tile_set.set_physics_layer_collision_mask(idx, int(entry.get("collision_mask", 1)))
			physics_added += 1

	var navigation_added: int = 0
	if params.has("navigation_layers"):
		if not (params["navigation_layers"] is Array):
			return {"error": "Parameter 'navigation_layers' must be an array"}
		for entry in params["navigation_layers"]:
			if not (entry is Dictionary):
				return {"error": "Each navigation_layers item must be an object"}
			tile_set.add_navigation_layer()
			var idx: int = tile_set.get_navigation_layers_count() - 1
			tile_set.set_navigation_layer_layers(idx, int(entry.get("layers", 1)))
			navigation_added += 1

	var custom_added: int = 0
	if params.has("custom_data_layers"):
		if not (params["custom_data_layers"] is Array):
			return {"error": "Parameter 'custom_data_layers' must be an array"}
		for entry in params["custom_data_layers"]:
			if not (entry is Dictionary):
				return {"error": "Each custom_data_layers item must be an object"}
			var type_value: int = int(entry.get("type", TYPE_STRING))
			if type_value < 0 or type_value >= TYPE_MAX:
				return {"error": "custom_data_layers type must be a valid Variant.Type (0..%d)" % (TYPE_MAX - 1)}
			tile_set.add_custom_data_layer()
			var idx: int = tile_set.get_custom_data_layers_count() - 1
			var layer_name: String = str(entry.get("name", "")).strip_edges()
			if not layer_name.is_empty():
				tile_set.set_custom_data_layer_name(idx, layer_name)
			tile_set.set_custom_data_layer_type(idx, type_value)
			custom_added += 1

	var terrain_sets_added: int = 0
	if params.has("terrain_sets"):
		if not (params["terrain_sets"] is Array):
			return {"error": "Parameter 'terrain_sets' must be an array"}
		for entry in params["terrain_sets"]:
			if not (entry is Dictionary):
				return {"error": "Each terrain_sets item must be an object"}
			var mode_name: String = str(entry.get("mode", "corners_and_sides")).strip_edges().to_lower()
			if not _TILESET_TERRAIN_MODES.has(mode_name):
				return {"error": "Invalid terrain set mode '%s' (use corners, sides, or corners_and_sides)" % mode_name}
			tile_set.add_terrain_set()
			var set_idx: int = tile_set.get_terrain_sets_count() - 1
			tile_set.set_terrain_set_mode(set_idx, _TILESET_TERRAIN_MODES[mode_name])
			if entry.has("terrains"):
				if not (entry["terrains"] is Array):
					return {"error": "terrain_sets 'terrains' must be an array"}
				for terrain_entry in entry["terrains"]:
					if not (terrain_entry is Dictionary):
						return {"error": "Each terrains item must be an object"}
					tile_set.add_terrain(set_idx)
					var terrain_idx: int = tile_set.get_terrains_count(set_idx) - 1
					var terrain_name: String = str(terrain_entry.get("name", "")).strip_edges()
					if not terrain_name.is_empty():
						tile_set.set_terrain_name(set_idx, terrain_idx, terrain_name)
					if terrain_entry.has("color"):
						tile_set.set_terrain_color(set_idx, terrain_idx, ProjectToolsNative._parse_color(terrain_entry["color"]))
			terrain_sets_added += 1

	var error: Error = ResourceSaver.save(tile_set, sanitized)
	if error != OK:
		return {"error": "Failed to save tileset: " + error_string(error)}

	return {
		"status": "success",
		"tileset_path": sanitized,
		"physics_layers_count": tile_set.get_physics_layers_count(),
		"navigation_layers_count": tile_set.get_navigation_layers_count(),
		"custom_data_layers_count": tile_set.get_custom_data_layers_count(),
		"terrain_sets_count": tile_set.get_terrain_sets_count(),
		"physics_layers_added": physics_added,
		"navigation_layers_added": navigation_added,
		"custom_data_layers_added": custom_added,
		"terrain_sets_added": terrain_sets_added
	}

# --- set_tile_collision_polygon -----------------------------------------------

func _register_set_tile_collision_polygon(server_core: RefCounted) -> void:
	var tool_name: String = "set_tile_collision_polygon"
	var description: String = "Set a collision polygon on a tile inside a TileSet atlas source, on a given physics layer. Provide explicit polygon 'points', or omit them to auto-generate a full-tile rectangle (centered on the tile, sized to the TileSet tile_size) so the tile becomes solid. Optionally mark the polygon one-way. The physics layer must already exist (add it with configure_tileset_layers). Saves the TileSet."

	var input_schema: Dictionary = {
		"type": "object",
		"properties": {
			"tileset_path": {"type": "string", "description": "Path to an existing TileSet (.tres/.res)."},
			"source_id": {"type": "integer", "description": "Atlas source id (returned by create_tileset)."},
			"tile_coords": {"type": "array", "description": "Atlas tile coordinates as [x, y] (or {x, y}).", "items": {"type": "integer"}},
			"alternative_id": {"type": "integer", "description": "Alternative tile id. Default 0 (the base tile).", "default": 0},
			"physics_layer": {"type": "integer", "description": "Physics layer index on the TileSet. Default 0.", "default": 0},
			"points": {"type": "array", "description": "Polygon vertices as a list of [x, y] (or {x, y}), in tile-local pixels centered on the tile origin. Omit to generate a full-tile rectangle."},
			"one_way": {"type": "boolean", "description": "Mark the polygon as one-way collision. Default false.", "default": false}
		},
		"required": ["tileset_path", "source_id", "tile_coords"]
	}

	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"status": {"type": "string"},
			"tileset_path": {"type": "string"},
			"source_id": {"type": "integer"},
			"tile_coords": {"type": "array"},
			"physics_layer": {"type": "integer"},
			"polygon_points": {"type": "array"},
			"one_way": {"type": "boolean"}
		}
	}

	var annotations: Dictionary = {
		"readOnlyHint": false,
		"destructiveHint": false,
		"idempotentHint": false,
		"openWorldHint": false
	}

	server_core.register_tool(tool_name, description, input_schema,
						  Callable(self, "_tool_set_tile_collision_polygon"),
						  output_schema, annotations,
						  "supplementary", "Project-Advanced")

func _tool_set_tile_collision_polygon(params: Dictionary) -> Dictionary:
	var tileset_path: String = str(params.get("tileset_path", "")).strip_edges()
	if tileset_path.is_empty():
		return {"error": "Missing required parameter: tileset_path"}
	if not params.has("source_id"):
		return {"error": "Missing required parameter: source_id"}
	if not params.has("tile_coords"):
		return {"error": "Missing required parameter: tile_coords"}

	var coords_parsed: Variant = _parse_vector2i(params["tile_coords"])
	if coords_parsed == null:
		return {"error": "Parameter 'tile_coords' must be [x, y] or {x, y}"}
	var coords: Vector2i = coords_parsed

	var loaded: Dictionary = _load_tileset_for_edit(tileset_path)
	if loaded.has("error"):
		return loaded
	var tile_set: TileSet = loaded["tile_set"]
	var sanitized: String = loaded["path"]

	var physics_layer: int = int(params.get("physics_layer", 0))
	if physics_layer < 0 or physics_layer >= tile_set.get_physics_layers_count():
		return {"error": "physics_layer %d out of range (TileSet has %d physics layers)" % [physics_layer, tile_set.get_physics_layers_count()]}

	var alternative_id: int = int(params.get("alternative_id", 0))
	var resolved: Dictionary = _resolve_atlas_tile_data(tile_set, int(params["source_id"]), coords, alternative_id)
	if resolved.has("error"):
		return resolved
	var tile_data: TileData = resolved["tile_data"]

	var polygon: PackedVector2Array = PackedVector2Array()
	if params.has("points"):
		if not (params["points"] is Array):
			return {"error": "Parameter 'points' must be an array of [x, y]"}
		for point in params["points"]:
			var pv: Variant = ProjectToolsNative._parse_vector2(point)
			if pv == null:
				return {"error": "Each points item must be [x, y] or {x, y}"}
			polygon.append(pv)
		if polygon.size() < 3:
			return {"error": "A collision polygon needs at least 3 points"}
	else:
		var half: Vector2 = Vector2(tile_set.tile_size) * 0.5
		polygon.append(Vector2(-half.x, -half.y))
		polygon.append(Vector2(half.x, -half.y))
		polygon.append(Vector2(half.x, half.y))
		polygon.append(Vector2(-half.x, half.y))

	var one_way: bool = bool(params.get("one_way", false))
	tile_data.add_collision_polygon(physics_layer)
	var polygon_index: int = tile_data.get_collision_polygons_count(physics_layer) - 1
	tile_data.set_collision_polygon_points(physics_layer, polygon_index, polygon)
	tile_data.set_collision_polygon_one_way(physics_layer, polygon_index, one_way)

	var error: Error = ResourceSaver.save(tile_set, sanitized)
	if error != OK:
		return {"error": "Failed to save tileset: " + error_string(error)}

	var points_out: Array = []
	for p in polygon:
		points_out.append([p.x, p.y])

	return {
		"status": "success",
		"tileset_path": sanitized,
		"source_id": int(params["source_id"]),
		"tile_coords": [coords.x, coords.y],
		"physics_layer": physics_layer,
		"polygon_points": points_out,
		"one_way": one_way
	}

# --- set_tile_terrain ---------------------------------------------------------

func _register_set_tile_terrain(server_core: RefCounted) -> void:
	var tool_name: String = "set_tile_terrain"
	var description: String = "Assign a terrain set and terrain to a tile in a TileSet atlas source, and optionally set terrain peering bits for autotiling. The terrain set and terrain must already exist (create them with configure_tileset_layers). peering_bits maps neighbor names (right_side, bottom_right_corner, bottom_side, bottom_left_corner, left_side, top_left_corner, top_side, top_right_corner) to a terrain index; neighbors that are not valid for the terrain set's match mode and tile shape are rejected with an error. Saves the TileSet."

	var input_schema: Dictionary = {
		"type": "object",
		"properties": {
			"tileset_path": {"type": "string", "description": "Path to an existing TileSet (.tres/.res)."},
			"source_id": {"type": "integer", "description": "Atlas source id (returned by create_tileset)."},
			"tile_coords": {"type": "array", "description": "Atlas tile coordinates as [x, y] (or {x, y}).", "items": {"type": "integer"}},
			"alternative_id": {"type": "integer", "description": "Alternative tile id. Default 0 (the base tile).", "default": 0},
			"terrain_set": {"type": "integer", "description": "Terrain set index on the TileSet."},
			"terrain": {"type": "integer", "description": "Terrain index within the terrain set."},
			"peering_bits": {"type": "object", "description": "Optional map of neighbor name -> terrain index for autotiling, e.g. {\"top_side\": 0, \"left_side\": 0}."}
		},
		"required": ["tileset_path", "source_id", "tile_coords", "terrain_set", "terrain"]
	}

	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"status": {"type": "string"},
			"tileset_path": {"type": "string"},
			"source_id": {"type": "integer"},
			"tile_coords": {"type": "array"},
			"terrain_set": {"type": "integer"},
			"terrain": {"type": "integer"},
			"peering_bits_set": {"type": "array"}
		}
	}

	var annotations: Dictionary = {
		"readOnlyHint": false,
		"destructiveHint": false,
		"idempotentHint": false,
		"openWorldHint": false
	}

	server_core.register_tool(tool_name, description, input_schema,
						  Callable(self, "_tool_set_tile_terrain"),
						  output_schema, annotations,
						  "supplementary", "Project-Advanced")

func _tool_set_tile_terrain(params: Dictionary) -> Dictionary:
	var tileset_path: String = str(params.get("tileset_path", "")).strip_edges()
	if tileset_path.is_empty():
		return {"error": "Missing required parameter: tileset_path"}
	if not params.has("source_id"):
		return {"error": "Missing required parameter: source_id"}
	if not params.has("tile_coords"):
		return {"error": "Missing required parameter: tile_coords"}
	if not params.has("terrain_set"):
		return {"error": "Missing required parameter: terrain_set"}
	if not params.has("terrain"):
		return {"error": "Missing required parameter: terrain"}

	var coords_parsed: Variant = _parse_vector2i(params["tile_coords"])
	if coords_parsed == null:
		return {"error": "Parameter 'tile_coords' must be [x, y] or {x, y}"}
	var coords: Vector2i = coords_parsed

	var loaded: Dictionary = _load_tileset_for_edit(tileset_path)
	if loaded.has("error"):
		return loaded
	var tile_set: TileSet = loaded["tile_set"]
	var sanitized: String = loaded["path"]

	var terrain_set: int = int(params["terrain_set"])
	if terrain_set < 0 or terrain_set >= tile_set.get_terrain_sets_count():
		return {"error": "terrain_set %d out of range (TileSet has %d terrain sets)" % [terrain_set, tile_set.get_terrain_sets_count()]}
	var terrain: int = int(params["terrain"])
	if terrain < 0 or terrain >= tile_set.get_terrains_count(terrain_set):
		return {"error": "terrain %d out of range (terrain set %d has %d terrains)" % [terrain, terrain_set, tile_set.get_terrains_count(terrain_set)]}

	var alternative_id: int = int(params.get("alternative_id", 0))
	var resolved: Dictionary = _resolve_atlas_tile_data(tile_set, int(params["source_id"]), coords, alternative_id)
	if resolved.has("error"):
		return resolved
	var tile_data: TileData = resolved["tile_data"]

	var peering_set: Array = []
	if params.has("peering_bits"):
		if not (params["peering_bits"] is Dictionary):
			return {"error": "Parameter 'peering_bits' must be an object of neighbor -> terrain index"}
		for neighbor_name in params["peering_bits"]:
			var key: String = str(neighbor_name).strip_edges().to_lower()
			if not _TILESET_CELL_NEIGHBORS.has(key):
				return {"error": "Unknown peering neighbor '%s'" % str(neighbor_name)}
			if not _is_terrain_peering_bit_valid(tile_set, terrain_set, key):
				return {"error": "peering neighbor '%s' is not valid for terrain set %d (check its match mode and tile shape)" % [key, terrain_set]}
			var peer_terrain: int = int(params["peering_bits"][neighbor_name])
			if peer_terrain < 0 or peer_terrain >= tile_set.get_terrains_count(terrain_set):
				return {"error": "peering_bits['%s'] terrain %d out of range" % [key, peer_terrain]}

	tile_data.set_terrain_set(terrain_set)
	tile_data.set_terrain(terrain)
	if params.has("peering_bits"):
		for neighbor_name in params["peering_bits"]:
			var key: String = str(neighbor_name).strip_edges().to_lower()
			tile_data.set_terrain_peering_bit(_TILESET_CELL_NEIGHBORS[key], int(params["peering_bits"][neighbor_name]))
			peering_set.append(key)

	var error: Error = ResourceSaver.save(tile_set, sanitized)
	if error != OK:
		return {"error": "Failed to save tileset: " + error_string(error)}

	return {
		"status": "success",
		"tileset_path": sanitized,
		"source_id": int(params["source_id"]),
		"tile_coords": [coords.x, coords.y],
		"terrain_set": terrain_set,
		"terrain": terrain,
		"peering_bits_set": peering_set
	}


func _serialize_tileset_source(source_id: int, source: TileSetSource, include_tiles: bool) -> Dictionary:
	var source_entry: Dictionary = {
		"source_id": source_id,
		"class_name": source.get_class(),
		"tile_count": source.get_tiles_count()
	}

	if source is TileSetAtlasSource:
		var atlas_source: TileSetAtlasSource = source as TileSetAtlasSource
		var texture: Texture2D = atlas_source.texture
		source_entry["source_type"] = "atlas"
		source_entry["texture_path"] = texture.resource_path if texture else ""
		source_entry["texture_size"] = _serialize_vector2(texture.get_size()) if texture else {}
		source_entry["margins"] = _serialize_vector2i(atlas_source.margins)
		source_entry["separation"] = _serialize_vector2i(atlas_source.separation)
		source_entry["texture_region_size"] = _serialize_vector2i(atlas_source.texture_region_size)
		source_entry["atlas_grid_size"] = _serialize_vector2i(atlas_source.get_atlas_grid_size())
		source_entry["uses_texture_padding"] = atlas_source.use_texture_padding
		if include_tiles:
			var atlas_tiles: Array = []
			for tile_index in range(atlas_source.get_tiles_count()):
				var atlas_coords: Vector2i = atlas_source.get_tile_id(tile_index)
				var alternatives: Array = []
				for alt_index in range(atlas_source.get_alternative_tiles_count(atlas_coords)):
					alternatives.append(atlas_source.get_alternative_tile_id(atlas_coords, alt_index))
				atlas_tiles.append({
					"atlas_coords": _serialize_vector2i(atlas_coords),
					"size_in_atlas": _serialize_vector2i(atlas_source.get_tile_size_in_atlas(atlas_coords)),
					"texture_region": _serialize_rect2i(atlas_source.get_tile_texture_region(atlas_coords)),
					"alternative_ids": alternatives,
					"alternative_count": alternatives.size()
				})
			source_entry["tiles"] = atlas_tiles
	elif source is TileSetScenesCollectionSource:
		var scenes_source: TileSetScenesCollectionSource = source as TileSetScenesCollectionSource
		source_entry["source_type"] = "scenes_collection"
		source_entry["scene_tile_count"] = scenes_source.get_scene_tiles_count()
		if include_tiles:
			var scene_tiles: Array = []
			for tile_index in range(scenes_source.get_scene_tiles_count()):
				var scene_tile_id: int = scenes_source.get_scene_tile_id(tile_index)
				var packed_scene: PackedScene = scenes_source.get_scene_tile_scene(scene_tile_id)
				scene_tiles.append({
					"scene_tile_id": scene_tile_id,
					"scene_path": packed_scene.resource_path if packed_scene else ""
				})
			source_entry["scene_tiles"] = scene_tiles
	else:
		source_entry["source_type"] = "unknown"

	return source_entry

func _serialize_vector2i(value: Vector2i) -> Dictionary:
	return {"x": value.x, "y": value.y}

func _serialize_vector2(value: Vector2) -> Dictionary:
	return {"x": value.x, "y": value.y}

func _serialize_rect2i(value: Rect2i) -> Dictionary:
	return {
		"position": _serialize_vector2i(value.position),
		"size": _serialize_vector2i(value.size)
	}
