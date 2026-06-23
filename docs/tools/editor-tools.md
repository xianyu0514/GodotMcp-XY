# Editor Tools

[← Tools reference](README.md)

**24 tools** — 4 core, 20 advanced.

Drive the Godot editor itself: run/stop the project, inspect editor state, select files/nodes, manage open scripts, export builds and capture screenshots.

## Recommended workflow

1. Check `get_editor_state` before automation.
2. Run or stop the game with `run_project` / `stop_project`.
3. Use selection, inspector and screenshot tools for UI-adjacent workflows.
4. Enable export and buffer-sync tools only when packaging or coordinating with the editor UI.

## Tool list

### Editor (4 core)

| Tool | Tier | Description |
| --- | --- | --- |
| `get_editor_state` | core | Get the current state of the Godot editor, including active scene and selection info. |
| `run_project` | core | Run the current project or a specific scene. Launches the game in play mode. |
| `stop_project` | core | Stop the currently running project and return to editor mode. |
| `execute_editor_script` | core | Execute a script in the editor with access to editor APIs. |

### Editor-Advanced (20 advanced)

| Tool | Tier | Description |
| --- | --- | --- |
| `get_selected_nodes` | advanced | Get the list of currently selected nodes in the editor. |
| `set_editor_setting` | advanced | Set an editor setting value. Requires editor restart for some settings to take effect. |
| `get_editor_screenshot` | advanced | Capture a screenshot of the editor viewport and save it to a file. |
| `get_signals` | advanced | Get all signals and their connections for a node. |
| `reload_project` | advanced | Rescan the project filesystem and reload scripts. Useful after external file changes. |
| `select_node` | advanced | Select a node in the current edited scene and focus it in the Inspector. |
| `select_file` | advanced | Select a project file in the Godot FileSystem dock. |
| `get_inspector_properties` | advanced | Inspect a node or resource and return property metadata and serialized values similar to the Inspector. |
| `list_export_presets` | advanced | List export presets from export_presets.cfg. |
| `inspect_export_templates` | advanced | Inspect locally installed Godot export templates for the current editor version. |
| `validate_export_preset` | advanced | Validate an export preset against export_presets.cfg and local template availability. |
| `run_export` | advanced | Run a Godot CLI export for a configured preset. |
| `smoke_test_export` | advanced | Post-export smoke test: confirm an exported product exists and (optionally) launches cleanly. Resolves the artifact from `artifact_path` or the preset export_path, optionally exports first (`run_export`), asserts the file exists, and when `launch=true` runs it with `launch_args` (default `--quit-after 120`) to capture and check the exit code against `expected_exit_code`. Returns an objective pass/fail with reasons. |
| `manage_export_templates` | advanced | Manage locally installed Godot export templates: report status (templates dir installed versions and the official download URL/.tpz filename) install a .tpz/.zip archive or remove an installed version directory. Works on Godot 4.6+. |
| `configure_android_export` | advanced | Configure Android-specific options on an existing Android export preset in export_presets.cfg such as package name version code/name Gradle build APK/AAB format SDK levels target architectures and keystore file paths. Keystore passwords are not written here. Works on Godot 4.6+. |
| `get_unsaved_changes` | advanced | List scenes and scripts with unsaved edits in the editor buffers (Godot 4.7 APIs; *_supported flags report availability). |
| `save_all_scripts` | advanced | Save every script currently open in the script editor (Godot 4.7 ScriptEditor.save_all_scripts). |
| `reload_open_scripts` | advanced | Reload the editor's open script buffers from disk so the editor does not overwrite externally rewritten files (Godot 4.7). |
| `close_script_tab` | advanced | Close a script tab in the editor's script editor, optionally targeting a specific script path (Godot 4.7). |
| `get_import_status` | advanced | Report whether the EditorFileSystem is currently scanning or importing assets (importing field requires Godot 4.7). |
