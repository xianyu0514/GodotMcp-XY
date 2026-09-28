# Scene Tools

[← Tools reference](README.md)

**12 tools** — 4 core, 8 advanced.

Open, save, inspect and compose scenes. Advanced tools cover tab management, scene instancing, branch saving and TileMapLayer cell access.

## Recommended workflow

1. Find the active scene with `get_current_scene`.
2. Use `open_scene`, `create_scene` and `save_scene` for file-level operations.
3. Inspect hierarchy with `get_scene_structure` before making structural edits.
4. Enable advanced scene tools for prefab-style instancing, branch extraction or TileMapLayer work.

## Tool list

### Scene (4 core)

| Tool | Tier | Description |
| --- | --- | --- |
| `create_scene` | core | Create a new Godot scene with a root node. The scene is saved to the specified path. |
| `save_scene` | core | Save the current scene to disk. If no path is provided, saves to the current scene's path. |
| `open_scene` | core | Open a scene file from the project. Closes the current scene if one is open. |
| `get_current_scene` | core | Get information about the currently open scene, including name, path, and root node type. |

### Scene-Advanced (8 advanced)

| Tool | Tier | Description |
| --- | --- | --- |
| `get_scene_structure` | advanced | Get scene structure as a tree. Reads the currently open scene, or any scene file read-only via `scene_path` (no editor switch needed). `hidden_descendants` quantifies max_depth truncation. |
| `list_project_scenes` | advanced | List all scene files (.tscn) in the project. Returns paths relative to res://. |
| `list_open_scenes` | advanced | List scene tabs currently open in the Godot editor. |
| `close_scene_tab` | advanced | Close the active scene tab, or activate a specified scene tab and close it. |
| `instantiate_scene` | advanced | Instance an existing scene file (.tscn) as a child of a node in the currently edited scene. Useful for placing prefabs such as card UIs or enemy instances into the scene tree. |
| `save_branch_as_scene` | advanced | Save a node and all of its descendants from the currently edited scene as a reusable scene file (.tscn). Useful for extracting a designed UI branch into a prefab. Does not modify the source scene tree. |
| `set_tilemap_layer_cells` | advanced | Set or erase a batch of cells on a TileMapLayer node (Godot 4.x) in the currently edited scene using the single-layer TileMapLayer API. Each cell is {coords:[x,y], source_id, atlas_coords:[x,y], alternative} or {coords:[x,y], erase:true}. Assign a TileSet to the layer so painted cells render. Wrapped in editor UndoRedo. |
| `get_tilemap_layer_cells` | advanced | Read cells from a TileMapLayer node (Godot 4.x) in the currently edited scene. Without 'coords' it returns every used cell; with 'coords' (array of [x,y]) it returns just those. Each cell reports source_id, atlas_coords and alternative (source_id -1 means empty). |
