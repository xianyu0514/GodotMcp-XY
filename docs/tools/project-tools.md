# Project Tools

[← Tools reference](README.md)

**64 tools** — 3 core, 61 advanced.

Inspect and maintain project-level state: settings, resources, input map, tests, autoloads, migration checks, rendering assets, TileSets, sprite sheets, glTF imports and task plans.

## Recommended workflow

1. Read project facts with `get_project_info`, `get_project_settings` and `list_project_resources`.
2. Use advanced resource tools for imports, dependency analysis and usage audits.
3. Bootstrap the test environment with `prepare_project_test_environment`, `ensure_project_directory` and `create_project_smoke_test`, then run tests through `list_project_tests`, `run_project_test` and `run_project_tests`.
4. Enable production helpers such as `generate_asset`, `slice_sprite_sheet`, `inspect_gltf_asset`, `assert_visual_baseline` and `manage_task_plan` only for the workflows that need them.

## Tool list

### Project (3 core)

| Tool | Tier | Description |
| --- | --- | --- |
| `get_project_info` | core | Get general information about the Godot project, including name, version, and description. |
| `get_project_settings` | core | Get project settings. Optionally filter by a prefix. |
| `list_project_resources` | core | List project resources with lossless `limit`/`offset` pages. Follow `next_offset` while `has_more`; pages reuse one revision-safe scan snapshot. |

### Project-Advanced (61 advanced)

| Tool | Tier | Description |
| --- | --- | --- |
| `create_resource` | advanced | Create a new Godot resource file (.tres). Supports common resource types. |
| `create_custom_resource` | advanced | Create a .tres/.res for a custom class_name Resource (or Resource script by path), setting exported properties. Resolves project global classes, not just built-in engine types. |
| `batch_create_resources` | advanced | Create many resource files (.tres) in one call from a list spec, with shared defaults each item can override. Ideal for data-driven card, relic, or enemy sets. |
| `update_resource_properties` | advanced | Load an existing resource file, set/merge exported properties, and re-save it. Use to tweak data such as card cost or enemy HP. |
| `read_resource_properties` | advanced | Read a resource file and return its exported properties as JSON-friendly values, optionally including built-in base Resource properties. |
| `get_project_structure` | advanced | Get project structure and file organization. |
| `prepare_project_test_environment` | advanced | Inspect and prepare the project's test environment without requiring GUT or Python. Checks res://test/, res://tests/ and res://.mcp_runtime_tests/ and returns ready/empty/unconfigured/blocked plus a recoverable flag and recommended action. |
| `ensure_project_directory` | advanced | Ensure a directory exists under res://. Idempotent and safe: refuses the project root and rejects path escape. Returns 'created' or 'unchanged'. |
| `create_project_smoke_test` | advanced | Generate a minimal framework-independent smoke test under res://test/. The native test checks main-scene load, project file presence and a clean headless run, so an empty project can pass QA without GUT or Python installed. |
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
| `assert_visual_baseline` | advanced | Visual regression gate: compare a candidate screenshot against a stored baseline (golden) image and return pass/fail against tolerances (max_diff_pixels / max_diff_ratio / rmse_threshold). Missing baseline (or update_baseline=true) saves the candidate as the new baseline and passes. Optionally writes a diff heatmap PNG. Dimension mismatches fail. |
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
| `find_resource_usages` | advanced | Find resources that reference a target, with lossless `limit`/`offset` pages backed by one revision-safe scan. |
| `list_unused_resources` | advanced | List unreferenced resources with lossless `limit`/`offset` pages backed by one revision-safe scan. |
| `scan_migration_compatibility` | advanced | Scan `.gd`/`.cs` for target-version migration issues, with lossless `limit`/`offset` pages backed by one revision-safe scan. |
| `apply_migration_fixes` | advanced | Apply the safe mechanical migration rewrites (e.g. enum/identifier renames) for a target Godot release. Defaults to a dry-run preview. |
| `find_deprecated_api_usage` | advanced | Scan scripts for removed/deprecated Godot 4.x APIs and replacements, with lossless pages backed by one revision-safe scan. |
| `detect_gdextension_addons` | advanced | Detect native GDExtension addons by scanning .gdextension files and report entry symbol, compatibility_minimum, per-platform library availability and any SConstruct build hints. Detection only. |
| `create_gradient_texture` | advanced | Create and save a GradientTexture2D (.tres) with a configurable color gradient and fill mode (linear radial square or conic). Conic fill requires Godot 4.7. |
| `pack_pck` | advanced | Bundle a set of files into a Godot .pck archive using PCKPacker mapping virtual target paths to existing source files. Useful for building DLC or mod packs. |
| `configure_render_output` | advanced | Configure project-level render output settings including the Godot 4.7 HDR 2D output (rendering/viewport/hdr_2d) and transparent background. Unavailable keys are reported as unsupported. |
| `create_drawable_texture` | advanced | Create and save a Godot 4.7 DrawableTexture2D (.tres) a GPU-backed texture you can draw onto at runtime initialized via setup(width height format fill_color use_mipmaps). Requires Godot 4.7 returns unsupported on older versions. |
| `draw_on_texture` | advanced | Draw onto an existing Godot 4.7 DrawableTexture2D by blitting source textures onto target rectangles (blit_rect) with an optional modulate color. Requires Godot 4.7 returns unsupported on older versions. |
| `generate_asset` | advanced | Generate an image/audio asset from a prompt into res://; key from env var. Returns 'unconfigured' when unset; reimports when possible. |
| `slice_sprite_sheet` | advanced | Slice a sprite sheet texture into a SpriteFrames resource (.tres), animation-ready in one step. Grid = {h_frames, v_frames} or {cell_width, cell_height}, plus optional margin/spacing; frames row-major from 0. 'animations' (array of {name, frames or start_frame+end_frame, fps, loop}) defines named clips; omit for a looping 'default' clip over all frames. create_scene=true also saves an AnimatedSprite2D scene (first clip autoplays). |
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
| `manage_task_plan` | advanced | Persistent task graph + Definition-of-Done (DoD) in JSON (default res://.mcp/task_plan.json). Actions: init, add_task, update_task, set_status (done needs DoD unless force), set_dod, get, next, remove_task. |
| `generate_3d_asset` | advanced | Generate a 3D model (glTF/GLB) from a text prompt via an external provider into res://. Async: submit job, poll status, download, validate. API key from an OS env var (never logged). Returns 'unconfigured' when unset; reimports when possible. |
| `bump_version` | advanced | Automate version + changelog for the ship loop: read the current version from `application/config/version`, compute the next one (semantic `bump` major/minor/patch or an explicit `version`), and unless `dry_run` write it back to project.godot. When `update_changelog` is on, prepend a dated entry to `changelog_path` (default res://CHANGELOG.md). Returns previous/new version and whether files were written. |
| `manage_localization` | advanced | Localization workflow: 'extract' scans .tscn translatable properties (text/tooltip_text/placeholder_text/title/hint_tooltip) and .gd tr()/atr() calls, merging new keys into a standard CSV (first column keys, one per locale) while preserving existing translations; 'import' builds one .translation per locale from the CSV and registers it in ProjectSettings; 'export' writes registered .translations back to CSV; 'list' shows registered locales. Write actions support dry_run. |
