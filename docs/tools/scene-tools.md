# Scene Tools

[← Tools reference](README.md)

**12 tools** — 4 core, 8 advanced.

Tools for managing `.tscn` scenes and editor scene tabs: creating, opening, saving and closing scenes, inspecting scene structure, instancing prefabs, saving a node branch as a reusable scene, and editing `TileMapLayer` cells.

> Core tools are enabled out of the box. Advanced tools are registered but disabled by
> default; enable the ones you need from the **MCP** dock panel (or in tests via
> `core.set_tool_enabled("<tool>", true)`). See [the tools overview](README.md) for details.

### Scene (4)

| Tool | Tier | Description |
| --- | --- | --- |
| `create_scene` | Core | Create a new Godot scene with a root node. The scene is saved to the specified path. |
| `save_scene` | Core | Save the current scene to disk. If no path is provided, saves to the current scene's path. |
| `open_scene` | Core | Open a scene file from the project. Closes the current scene if one is open. |
| `get_current_scene` | Core | Get information about the currently open scene, including name, path, and root node type. |

### Scene-Advanced (8)

| Tool | Tier | Description |
| --- | --- | --- |
| `get_scene_structure` | Advanced | Get the complete structure of the current scene as a tree. Returns node types, names, and hierarchy. |
| `list_project_scenes` | Advanced | List all scene files (.tscn) in the project. Returns paths relative to res://. |
| `list_open_scenes` | Advanced | List scene tabs currently open in the Godot editor. |
| `close_scene_tab` | Advanced | Close the active scene tab, or activate a specified scene tab and close it. |
| `instantiate_scene` | Advanced | Instance an existing scene file (.tscn) as a child of a node in the currently edited scene. Useful for placing prefabs such as card UIs or enemy instances into the scene tree. |
| `save_branch_as_scene` | Advanced | Save a node and all of its descendants from the currently edited scene as a reusable scene file (.tscn). Useful for extracting a designed UI branch into a prefab. Does not modify the source scene tree. |
| `set_tilemap_layer_cells` | Advanced | Set or erase a batch of cells on a TileMapLayer node (Godot 4.x) in the currently edited scene using the single-layer TileMapLayer API. Each cell is {coords:[x,y], source_id, atlas_coords:[x,y], alternative} or {coords:[x,y], erase:true}. Assign a TileSet to the layer so painted cells render. Wrapped in editor UndoRedo. |
| `get_tilemap_layer_cells` | Advanced | Read cells from a TileMapLayer node (Godot 4.x) in the currently edited scene. Without 'coords' it returns every used cell; with 'coords' (array of [x,y]) it returns just those. Each cell reports source_id, atlas_coords and alternative (source_id -1 means empty). |
