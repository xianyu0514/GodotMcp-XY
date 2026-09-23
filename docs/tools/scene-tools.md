# Scene Tools

[← Tools reference](README.md)

**16 tools** — 4 core, 12 advanced.

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

### Scene-Advanced (12 advanced)

| Tool | Tier | Description |
| --- | --- | --- |
| `get_scene_structure` | advanced | Get the complete structure of the current scene as a tree. Returns node types, names, and hierarchy. |
| `list_project_scenes` | advanced | List all scene files (.tscn) in the project. Returns paths relative to res://. |
| `list_open_scenes` | advanced | List scene tabs currently open in the Godot editor. |
| `close_scene_tab` | advanced | Close the active scene tab, or activate a specified scene tab and close it. |
| `instantiate_scene` | advanced | Instance an existing scene file (.tscn) as a child of a node in the currently edited scene. Useful for placing prefabs such as card UIs or enemy instances into the scene tree. |
| `save_branch_as_scene` | advanced | Save a node and all of its descendants from the currently edited scene as a reusable scene file (.tscn). Useful for extracting a designed UI branch into a prefab. Does not modify the source scene tree. |
| `set_tilemap_layer_cells` | advanced | Set or erase a batch of cells on a TileMapLayer node (Godot 4.x) in the currently edited scene using the single-layer TileMapLayer API. Each cell is {coords:[x,y], source_id, atlas_coords:[x,y], alternative} or {coords:[x,y], erase:true}. Assign a TileSet to the layer so painted cells render. Wrapped in editor UndoRedo. |
| `get_tilemap_layer_cells` | advanced | Read cells from a TileMapLayer node (Godot 4.x) in the currently edited scene. Without 'coords' it returns every used cell; with 'coords' (array of [x,y]) it returns just those. Each cell reports source_id, atlas_coords and alternative (source_id -1 means empty). |
| `batch_update_scene_files` | advanced | Semantic batch property edit across many .tscn FILES at once (text-level — everything but the edited lines stays byte-identical). Each edit targets {node, property, value} with an optional `expect_current` guard: only nodes whose current serialized value equals the guard are rewritten, so tuning every grunt while the boss keeps its special value is one call; drifted values are reported as preserved (special config kept). An explicit `preserve` list is an absolute keep. The existing serialized type is followed when lossless (220.0 over int 200 stays `220`). Unserialized properties are reported missing, never silently appended. `dry_run` defaults to true — first call previews, re-run with `dry_run=false` to write. |
| `create_scene_variant` | advanced | Create a scene VARIANT by inheritance: boss.tscn <- enemy.tscn with property overrides. The variant keeps only its differences — every base-scene change flows into all variants; `batch_update_scene_files` retunes them later with the `expect_current` guard. Overrides are {node, property, value} relative to the root (''/'.' = root, 'Brain' = child, 'Mid/Leaf' = deeper). Idempotent (on_exists=skip default); text-level generation; open_after_create goes through the scene-ready barrier. |
| `create_navigation_region` | advanced | Create a NavigationRegion2D in the edited scene with an OUTLINE-DRIVEN baked navigation polygon. Outlines are `[x, y]` point arrays (world space); `agent_radius` is the shrink-margin data knob. Baking uses the quiet 4.6 path (outlines ARE the source geometry — no scene parse, no engine noise) and vertex/polygon counts come back inline. Runtime proof: `get_node('<region>').navigation_polygon.get_vertices().size() >= 4`. |
