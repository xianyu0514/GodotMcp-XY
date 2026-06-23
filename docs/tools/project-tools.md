# Project Tools

[← Tools reference](README.md)

**55 tools** — 3 core, 52 advanced.

Project-level tools: project info and settings (read and write), resource creation and property editing, input map and autoload management, global-class / ClassDB metadata, the test runner, health and dependency audits, Godot 4.7 migration scanning/fixes, and asset authoring (themes, gradients, drawable textures, animations, TileSets, PCK packing).

> Core tools are enabled out of the box. Advanced tools are registered but disabled by
> default; enable the ones you need from the **MCP** dock panel (or in tests via
> `core.set_tool_enabled("<tool>", true)`). See [the tools overview](README.md) for details.

### Project (3)

| Tool | Tier | Description |
| --- | --- | --- |
| `get_project_info` | Core | Get general information about the Godot project, including name, version, and description. |
| `get_project_settings` | Core | Get project settings. Optionally filter by a prefix. |
| `list_project_resources` | Core | List all resource files in the project (.tres, .res, .png, .ogg, etc.). |

### Project-Advanced (52)

| Tool | Tier | Description |
| --- | --- | --- |
| `create_resource` | Advanced | Create a new Godot resource file (.tres). Supports common resource types. |
| `create_custom_resource` | Advanced | Create a .tres/.res for a custom class_name Resource (or Resource script by path), setting exported properties. Resolves project global classes, not just built-in engine types. |
| `batch_create_resources` | Advanced | Create many resource files (.tres) in one call from a list spec, with shared defaults each item can override. Ideal for data-driven card, relic, or enemy sets. |
| `update_resource_properties` | Advanced | Load an existing resource file, set/merge exported properties, and re-save it. Use to tweak data such as card cost or enemy HP. |
| `read_resource_properties` | Advanced | Read a resource file and return its exported properties as JSON-friendly values, optionally including built-in base Resource properties. |
| `get_project_structure` | Advanced | Get project structure and file organization. |
| `list_project_tests` | Advanced | Discover runnable project tests under the Godot project's test directories. Reports Python integration tests and GUT unit tests, including whether each test is currently runnable. |
| `run_project_test` | Advanced | Run a single project test script without blocking the editor. The first call starts the run on a background thread and returns status 'pending'; call again with the same test_path to poll for the finished result. Python integration tests are executed with python. GUT unit tests are executed through Godot headless when addons/gut is available. |
| `run_project_tests` | Advanced | Discover and run multiple project tests from a directory without blocking the editor. The first call starts the batch on a background thread and returns status 'pending'; call again with the same arguments to poll for the aggregated result. Reuses the same framework filters as list_project_tests and aggregates pass/fail counts. |
| `list_project_input_actions` | Advanced | List project InputMap actions stored in ProjectSettings, including serialized input events. |
| `upsert_project_input_action` | Advanced | Create or update a project InputMap action in ProjectSettings and save project.godot. |
| `remove_project_input_action` | Advanced | Remove a project InputMap action from ProjectSettings and save project.godot. |
| `list_project_autoloads` | Advanced | List project autoload entries with resolved path, singleton flag, and project setting order. |
| `list_project_global_classes` | Advanced | List project global script classes registered through class_name metadata. |
| `get_class_api_metadata` | Advanced | Get typed API metadata for an engine ClassDB class or a project global script class. |
| `inspect_csharp_project_support` | Advanced | Inspect C# / Mono project support files such as .csproj and .sln, including target frameworks, assembly metadata, and references. |
| `compare_render_screenshots` | Advanced | Compare two screenshot images and report pixel differences, RMSE, and threshold-based match status. |
| `inspect_tileset_resource` | Advanced | Inspect a TileSet resource and summarize its sources, atlas tiles, and scene tiles. |
| `reimport_resources` | Advanced | Reimport project resources. |
| `get_import_metadata` | Advanced | Get resource import metadata. |
| `get_resource_uid_info` | Advanced | Get resource UID information. |
| `fix_resource_uid` | Advanced | Fix resource UID issues. |
| `get_resource_dependencies` | Advanced | Get resource dependencies. |
| `scan_missing_resource_dependencies` | Advanced | Scan for missing resource dependencies. |
| `scan_cyclic_resource_dependencies` | Advanced | Scan for cyclic resource dependencies. |
| `detect_broken_scripts` | Advanced | Detect broken scripts in the project. |
| `audit_project_health` | Advanced | Audit project health and integrity. |
| `find_resource_usages` | Advanced | Find which resources reference a target resource (reverse dependency lookup). |
| `list_unused_resources` | Advanced | List resource files that no other resource references. |
| `scan_migration_compatibility` | Advanced | Scan project source for usages of APIs changed by a target Godot release (default 4.7) and report migration issues with file/line and severity. |
| `apply_migration_fixes` | Advanced | Apply the safe mechanical migration rewrites (e.g. enum/identifier renames) for a target Godot release. Defaults to a dry-run preview. |
| `find_deprecated_api_usage` | Advanced | Scan scripts for removed/deprecated Godot 4.x APIs and report file:line with the modern replacement; class/property rules are cross-checked against ClassDB. |
| `detect_gdextension_addons` | Advanced | Detect native GDExtension addons by scanning .gdextension files and report entry symbol, compatibility_minimum, per-platform library availability and any SConstruct build hints. Detection only. |
| `create_gradient_texture` | Advanced | Create and save a GradientTexture2D (.tres) with a configurable color gradient and fill mode (linear radial square or conic). Conic fill requires Godot 4.7. |
| `pack_pck` | Advanced | Bundle a set of files into a Godot .pck archive using PCKPacker mapping virtual target paths to existing source files. Useful for building DLC or mod packs. |
| `configure_render_output` | Advanced | Configure project-level render output settings including the Godot 4.7 HDR 2D output (rendering/viewport/hdr_2d) and transparent background. Unavailable keys are reported as unsupported. |
| `create_drawable_texture` | Advanced | Create and save a Godot 4.7 DrawableTexture2D (.tres) a GPU-backed texture you can draw onto at runtime initialized via setup(width height format fill_color use_mipmaps). Requires Godot 4.7 returns unsupported on older versions. |
| `draw_on_texture` | Advanced | Draw onto an existing Godot 4.7 DrawableTexture2D by blitting source textures onto target rectangles (blit_rect) with an optional modulate color. Requires Godot 4.7 returns unsupported on older versions. |
| `generate_asset` | Advanced | Generate a game asset (sprite/texture or sound effect) from a text prompt and land it into res://. provider 'placeholder' (default) synthesizes a deterministic procedural Image (PNG) or AudioStreamWAV (.tres/.wav) offline so prototypes never block on missing art; provider 'external' calls an external image/audio/TTS HTTP API, validates the bytes (image: PNG/JPEG/WEBP; audio: WAV/OGG/MP3), and saves them. With provider 'external', pass a `preset` (openai_image, stability_image, elevenlabs_tts, local_sd_webui) to fill endpoint/headers/body from a built-in template (API key read from an OS env var, never logged), or set endpoint/headers manually; use `body_format: "multipart"` for APIs that require multipart/form-data (e.g. Stability v2beta). A default preset and key env var can also be configured in the MCP panel. Returns 'unconfigured' when no endpoint/preset is set so callers can fall back to placeholders. The result is reimported when an editor interface is available. |
| `create_theme` | Advanced | Create and save a Theme resource (.tres/.theme) for styling Control-based UI such as card and HUD scenes, optionally setting default base scale, font size, and default font. Populate it afterwards with set_theme_item. |
| `set_theme_item` | Advanced | Load an existing Theme, set one item (color, constant, font_size, font, icon, or stylebox) for a given Control type, and re-save it. Colors/constants/font sizes are given directly; fonts/icons/styleboxes are resource paths. |
| `set_default_theme` | Advanced | Set or clear the project-wide default GUI theme (the gui/theme/custom project setting) and persist it to project.godot. Pass clear=true to fall back to the engine default. |
| `set_project_setting` | Advanced | Set a project setting (ProjectSettings) and optionally persist it to project.godot. Use for window size, rendering, physics layers, application config, input device settings, etc. Pass value_type to coerce the value to int/float/bool/string/vector2/vector3/color; otherwise the value is stored as provided. |
| `add_project_autoload` | Advanced | Register a project autoload singleton (e.g. a GameState/RNG/SaveManager script) and persist it to project.godot. The path must point to an existing .gd/.tscn/.scn/.cs resource. Set enabled=false to register the autoload without the singleton '*' prefix; pass overwrite=true to replace an existing entry of the same name. |
| `remove_project_autoload` | Advanced | Remove a project autoload singleton by name and persist the change to project.godot. Returns an error if no autoload with that name exists. |
| `create_animation` | Advanced | Create and save an Animation resource (.tres/.res/.anim) for editor-phase authoring of card, UI, and FX motion played by an AnimationPlayer at runtime. Set length (seconds), loop_mode (none/linear/pingpong), and step. Use insert_animation_keys to add tracks and keyframes. |
| `insert_animation_keys` | Advanced | Load an existing Animation, ensure a track for the given path exists, insert keyframes, and re-save. track_type 'value' targets a 'Node:property' path; 'position_3d'/'rotation_3d'/'scale_3d' target a node path. For value tracks pass value_type to coerce key values to int/float/bool/string/vector2/vector3/color. |
| `create_tileset` | Advanced | Create and save a TileSet resource (.tres/.res) for 2D tile maps used by a TileMapLayer (Godot 4.x). Sets tile_size and optionally adds a TileSetAtlasSource from a texture (texture_region_size defaults to tile_size). When create_tiles is true every grid cell that fits in the texture becomes a tile. Returns the atlas source_id and tiles_created. |
| `configure_tileset_layers` | Advanced | Add and configure layers on an existing TileSet (.tres/.res): physics layers (collision_layer/mask bitmasks), navigation layers, custom data layers (name + Variant type), and terrain sets with terrains (name, color, match mode). New layers are appended; existing ones are preserved. Saves the TileSet. Use after create_tileset so tiles can support collision, autotiling, navigation, and per-tile metadata. |
| `set_tile_collision_polygon` | Advanced | Set a collision polygon on a tile in a TileSet atlas source, on a given physics layer. Provide explicit polygon points, or omit them to auto-generate a full-tile rectangle (sized to tile_size) so the tile becomes solid. Optionally mark it one-way. The physics layer must already exist (configure_tileset_layers). Saves the TileSet. |
| `set_tile_terrain` | Advanced | Assign a terrain set and terrain to a tile in a TileSet atlas source, and optionally set terrain peering bits for autotiling. The terrain set and terrain must already exist (configure_tileset_layers). peering_bits maps neighbor names (right_side, bottom_side, left_side, top_side, and the four corners) to a terrain index. Saves the TileSet. |
| `manage_task_plan` | Advanced | Persist and query a durable task graph with Definition-of-Done (DoD) for AI-driven game production, stored as versioned JSON (default `res://.mcp/task_plan.json`) so the plan → execute → run → verify → fix loop survives across sessions. `action='init'` creates/resets the plan with a goal (with `reset=false` it returns an error rather than overwriting an existing plan whose JSON is corrupt; use `reset=true` to discard it); `add_task` appends a task (auto id, depends_on, dod criteria, tags) with cycle detection; `update_task` edits fields; `set_status` sets pending/in_progress/blocked/done (refuses `done` unless every DoD criterion is met, unless `force=true`); `set_dod` replaces the criteria list or updates one criterion's met/evidence; `get` returns the whole graph (or one task) plus progress; `next` returns dependency-ready tasks, blocked tasks and progress; `remove_task` deletes a task and strips dangling dependency references. |
