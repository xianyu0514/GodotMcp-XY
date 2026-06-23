# Project Tools

[← Tools reference](README.md)

**60 tools** — 3 core, 57 advanced.

Inspect and maintain project-level state: settings, resources, input map, tests, autoloads, migration checks, rendering assets, TileSets, sprite sheets, glTF imports and task plans.

## Recommended workflow

1. Read project facts with `get_project_info`, `get_project_settings` and `list_project_resources`.
2. Use advanced resource tools for imports, dependency analysis and usage audits.
3. Run project tests through `list_project_tests`, `run_project_test` and `run_project_tests`.
4. Enable production helpers such as `generate_asset`, `slice_sprite_sheet`, `inspect_gltf_asset`, `assert_visual_baseline` and `manage_task_plan` only for the workflows that need them.

## Tool list

### Project (3 core)

| Tool | Tier | Description |
| --- | --- | --- |
| `get_project_info` | core | Get general information about the Godot project, including name, version, and description. |
| `get_project_settings` | core | Get project settings. Optionally filter by a prefix. |
| `list_project_resources` | core | List all resource files in the project (.tres, .res, .png, .ogg, etc.). |

### Project-Advanced (57 advanced)

| Tool | Tier | Description |
| --- | --- | --- |
| `create_resource` | advanced | Create a new Godot resource file (.tres). Supports common resource types. |
| `create_custom_resource` | advanced | Create a .tres/.res for a custom class_name Resource (or Resource script by path), setting exported properties. Resolves project global classes, not just built-in engine types. |
| `batch_create_resources` | advanced | Create many resource files (.tres) in one call from a list spec, with shared defaults each item can override. Ideal for data-driven card, relic, or enemy sets. |
| `update_resource_properties` | advanced | Load an existing resource file, set/merge exported properties, and re-save it. Use to tweak data such as card cost or enemy HP. |
| `read_resource_properties` | advanced | Read a resource file and return its exported properties as JSON-friendly values, optionally including built-in base Resource properties. |
| `get_project_structure` | advanced | Get project structure and file organization. |
| `list_project_tests` | advanced | Discover runnable project tests under the Godot project's test directories. Reports Python integration tests and GUT unit tests, including whether each test is currently runnable. |
| `run_project_test` | advanced | Run a single project test script without blocking the editor. The first call starts the run on a background thread and returns status 'pending'; call again with the same test_path to poll for the finished result. Python integration tests are executed with python. GUT unit tests are executed through Godot headless when addons/gut is available. |
| `run_project_tests` | advanced | Discover and run multiple project tests from a directory without blocking the editor. The first call starts the batch on a background thread and returns status 'pending'; call again with the same arguments to poll for the aggregated result. Reuses the same framework filters as list_project_tests and aggregates pass/fail counts. |
| `list_project_input_actions` | advanced | List project InputMap actions stored in ProjectSettings, including serialized input events. |
| `upsert_project_input_action` | advanced | Create or update a project InputMap action in ProjectSettings and save project.godot. |
| `remove_project_input_action` | advanced | Remove a project InputMap action from ProjectSettings and save project.godot. |
| `list_project_autoloads` | advanced | List project autoload entries with resolved path, singleton flag, and project setting order. |
| `list_project_global_classes` | advanced | List project global script classes registered through class_name metadata. |
| `get_class_api_metadata` | advanced | Get typed API metadata for an engine ClassDB class or a project global script class. |
| `inspect_csharp_project_support` | advanced | Inspect C# / Mono project support files such as .csproj and .sln, including target frameworks, assembly metadata, and references. |
| `compare_render_screenshots` | advanced | Compare two screenshot images and report pixel differences, RMSE, and threshold-based match status. |
| `assert_visual_baseline` | advanced | Visual regression gate: compare a candidate screenshot against a stored baseline (golden) image and return a pass/fail verdict against tolerances. If the baseline file does not exist (or update_baseline=true) the candidate is saved as the new baseline and the gate passes (golden-file bootstrap). Otherwise the images are diffed (a per-channel delta above per_pixel_threshold marks a pixel changed) and the gate passes only when every configured tolerance holds: diff_pixel_count <= max_diff_pixels (enforced when max_diff_pixels is given, or when no other tolerance is set), diff_ratio <= max_diff_ratio (when > 0), and rmse <= rmse_threshold (when > 0). Optionally writes a diff heatmap PNG to diff_output_path. Dimension mismatches fail the gate. |
| `inspect_tileset_resource` | advanced | Inspect a TileSet resource and summarize its sources, atlas tiles, and scene tiles. |
| `reimport_resources` | advanced | Reimport project resources. |
| `get_import_metadata` | advanced | Get resource import metadata. |
| `get_resource_uid_info` | advanced | Get resource UID information. |
| `fix_resource_uid` | advanced | Fix resource UID issues. |
| `get_resource_dependencies` | advanced | Get resource dependencies. |
| `scan_missing_resource_dependencies` | advanced | Scan for missing resource dependencies. |
| `scan_cyclic_resource_dependencies` | advanced | Scan for cyclic resource dependencies. |
| `detect_broken_scripts` | advanced | Detect broken scripts in the project. |
| `audit_project_health` | advanced | Audit project health and integrity. |
| `find_resource_usages` | advanced | Find which resources reference a target resource (reverse dependency lookup). |
| `list_unused_resources` | advanced | List resource files that no other resource references. |
| `scan_migration_compatibility` | advanced | Scan project source for usages of APIs changed by a target Godot release (default 4.7) and report migration issues with file/line and severity. |
| `apply_migration_fixes` | advanced | Apply the safe mechanical migration rewrites (e.g. enum/identifier renames) for a target Godot release. Defaults to a dry-run preview. |
| `find_deprecated_api_usage` | advanced | Scan scripts for removed/deprecated Godot 4.x APIs and report file:line with the modern replacement; class/property rules are cross-checked against ClassDB. |
| `detect_gdextension_addons` | advanced | Detect native GDExtension addons by scanning .gdextension files and report entry symbol, compatibility_minimum, per-platform library availability and any SConstruct build hints. Detection only. |
| `create_gradient_texture` | advanced | Create and save a GradientTexture2D (.tres) with a configurable color gradient and fill mode (linear radial square or conic). Conic fill requires Godot 4.7. |
| `pack_pck` | advanced | Bundle a set of files into a Godot .pck archive using PCKPacker mapping virtual target paths to existing source files. Useful for building DLC or mod packs. |
| `configure_render_output` | advanced | Configure project-level render output settings including the Godot 4.7 HDR 2D output (rendering/viewport/hdr_2d) and transparent background. Unavailable keys are reported as unsupported. |
| `create_drawable_texture` | advanced | Create and save a Godot 4.7 DrawableTexture2D (.tres) a GPU-backed texture you can draw onto at runtime initialized via setup(width height format fill_color use_mipmaps). Requires Godot 4.7 returns unsupported on older versions. |
| `draw_on_texture` | advanced | Draw onto an existing Godot 4.7 DrawableTexture2D by blitting source textures onto target rectangles (blit_rect) with an optional modulate color. Requires Godot 4.7 returns unsupported on older versions. |
| `generate_asset` | advanced | Generate a game asset (sprite/texture or sound effect) from a text prompt and land it into res://. provider 'placeholder' (default) synthesizes a deterministic procedural Image (PNG) or AudioStreamWAV (.tres/.wav) offline so prototypes never block on missing art; provider 'external' calls an external image/audio/TTS HTTP API, validates the bytes (image: PNG/JPEG/WEBP; audio: WAV/OGG/MP3), and saves them. With provider 'external', pass a 'preset' (openai_image, stability_image, elevenlabs_tts, local_sd_webui) to fill endpoint/headers/body from a built-in template (API key read from an OS env var, never logged), or set endpoint/headers manually; use body_format 'multipart' for APIs that require multipart/form-data (e.g. Stability v2beta). A default preset and key env var can also be set in the MCP panel. Returns 'unconfigured' when no endpoint/preset is set so callers can fall back to placeholders. The result is reimported when an editor interface is available. |
| `slice_sprite_sheet` | advanced | Slice a sprite sheet texture into a SpriteFrames resource (.tres) so a generated or imported sheet becomes animation-ready in one step. Provide a grid as either {h_frames, v_frames} or {cell_width, cell_height}, with optional margin (border) and spacing (gap between cells); frames are indexed row-major from 0. Pass 'animations' (array of {name, frames:[...] OR start_frame+end_frame, fps, loop}) to define named clips; when omitted a single looping 'default' clip spanning every frame is created. Set create_scene=true to also save an AnimatedSprite2D scene wired to the SpriteFrames with the first clip set to autoplay. |
| `inspect_gltf_asset` | advanced | Import a glTF/GLB file with GLTFDocument and report a structural summary (mesh, material, animation, skin, camera, light and node counts plus their names) together with validation warnings (no meshes, meshes without materials, no animations). Use to verify a generated or downloaded 3D asset is usable before wiring it into a scene. Read-only: it parses the file but does not modify the project. |
| `create_theme` | advanced | Create and save a Theme resource (.tres/.theme) for styling Control-based UI such as card and HUD scenes, optionally setting default base scale, font size, and default font. Populate it afterwards with set_theme_item. |
| `set_theme_item` | advanced | Load an existing Theme, set one item (color, constant, font_size, font, icon, or stylebox) for a given Control type, and re-save it. Colors/constants/font sizes are given directly; fonts/icons/styleboxes are resource paths. |
| `set_default_theme` | advanced | Set or clear the project-wide default GUI theme (the gui/theme/custom project setting) and persist it to project.godot. Pass clear=true to fall back to the engine default. |
| `set_project_setting` | advanced | Set a project setting (ProjectSettings) and optionally persist it to project.godot. Use for window size, rendering, physics layers, application config, input device settings, etc. Pass value_type to coerce the value to int/float/bool/string/vector2/vector3/color; otherwise the value is stored as provided. |
| `add_project_autoload` | advanced | Register a project autoload singleton (e.g. a GameState/RNG/SaveManager script) and persist it to project.godot. The path must point to an existing .gd/.tscn/.scn/.cs resource. Set enabled=false to register the autoload without the singleton '*' prefix; pass overwrite=true to replace an existing entry of the same name. |
| `remove_project_autoload` | advanced | Remove a project autoload singleton by name and persist the change to project.godot. Returns an error if no autoload with that name exists. |
| `create_animation` | advanced | Create and save an Animation resource (.tres/.res/.anim) for editor-phase authoring of card, UI, and FX motion played by an AnimationPlayer at runtime. Set length (seconds), loop_mode (none/linear/pingpong), and step. Use insert_animation_keys to add tracks and keyframes. |
| `insert_animation_keys` | advanced | Load an existing Animation, ensure a track for the given path exists, insert keyframes, and re-save. track_type 'value' targets a 'Node:property' path; 'position_3d'/'rotation_3d'/'scale_3d' target a node path. For value tracks pass value_type to coerce key values to int/float/bool/string/vector2/vector3/color. |
| `create_tileset` | advanced | Create and save a TileSet resource (.tres/.res) for 2D tile maps used by a TileMapLayer (Godot 4.x). Sets tile_size and optionally adds a TileSetAtlasSource from a texture (texture_region_size defaults to tile_size). When create_tiles is true every grid cell that fits in the texture becomes a tile. Returns the atlas source_id and tiles_created. |
| `configure_tileset_layers` | advanced | Add and configure layers on an existing TileSet (.tres/.res): physics layers (collision_layer/mask bitmasks), navigation layers, custom data layers (name + Variant type), and terrain sets with terrains (name, color, match mode). New layers are appended; existing ones are preserved. Saves the TileSet. Use after create_tileset so tiles can support collision, autotiling, navigation, and per-tile metadata. |
| `set_tile_collision_polygon` | advanced | Set a collision polygon on a tile in a TileSet atlas source, on a given physics layer. Provide explicit polygon points, or omit them to auto-generate a full-tile rectangle (sized to tile_size) so the tile becomes solid. Optionally mark it one-way. The physics layer must already exist (configure_tileset_layers). Saves the TileSet. |
| `set_tile_terrain` | advanced | Assign a terrain set and terrain to a tile in a TileSet atlas source, and optionally set terrain peering bits for autotiling. The terrain set and terrain must already exist (configure_tileset_layers). peering_bits maps neighbor names (right_side, bottom_side, left_side, top_side, and the four corners) to a terrain index. Saves the TileSet. |
| `manage_task_plan` | advanced | Persist and query a durable task graph with Definition-of-Done (DoD) for AI-driven game production, stored as versioned JSON (default res://.mcp/task_plan.json) so the plan -> execute -> run -> verify -> fix loop survives across sessions. action='init' creates/resets the plan with a goal (with reset=false it returns an error rather than overwriting an existing plan whose JSON is corrupt; use reset=true to discard it); 'add_task' appends a task (auto id, depends_on, dod criteria, tags) with cycle detection; 'update_task' edits fields; 'set_status' sets pending/in_progress/blocked/done (refuses 'done' unless every DoD criterion is met, unless force=true); 'set_dod' replaces the criteria list or updates one criterion's met/evidence; 'get' returns the whole graph (or one task) plus progress; 'next' returns dependency-ready tasks, blocked tasks and progress; 'remove_task' deletes a task and strips dangling dependency references. |
| `generate_3d_asset` | advanced | Generate a 3D model (glTF/GLB) from a text prompt via an external text-to-3D provider and land it into res://. Asynchronous: submits a job, polls the provider's status endpoint until success/failure, downloads the resulting glTF/GLB, validates the bytes, and (by default) inspects the structure. Pick a `preset` (meshy_text_to_3d, tripo_text_to_3d) to fill the submit/status endpoints, body and field paths from a built-in template, or set them manually. Bring-your-own-key: the API key is read from an OS env var named by the preset (e.g. MESHY_API_KEY / TRIPO_API_KEY), never logged or stored, and the user pays their own provider quota. Returns 'unconfigured' when no preset/submit_endpoint is set. |
| `bump_version` | advanced | Automate version + changelog for the ship loop: read the current version from `application/config/version`, compute the next one (semantic `bump` major/minor/patch or an explicit `version`), and unless `dry_run` write it back to project.godot. When `update_changelog` is on, prepend a dated entry to `changelog_path` (default res://CHANGELOG.md). Returns previous/new version and whether files were written. |
