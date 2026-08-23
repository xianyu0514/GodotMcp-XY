# Debug & Runtime Tools

[← Tools reference](README.md)

**75 tools** — 3 core, 72 advanced.

Debug edit-time logs and debugger sessions, then inspect and control a running game through the runtime probe. This is the largest category and includes deterministic play verification, performance budgets and runtime error gates.

## Recommended workflow

1. Start from core logging tools: `get_editor_logs`, `debug_print`, `clear_output`.
2. Enable `Debug-Advanced` for breakpoints, stack frames, variables and profiler workflows.
3. Install the runtime probe before calling live-scene or input tools.
4. Prefer `visual_playtest` for the complete launch → drive/assert → screenshot → golden-baseline → cleanup loop; use the narrower gates independently when needed.

## Tool list

### Debug (3 core)

| Tool | Tier | Description |
| --- | --- | --- |
| `get_editor_logs` | core | Get recent log messages from the editor or runtime. Supports filtering by source, type, and pagination. |
| `debug_print` | core | Print debug messages to the editor console. |
| `clear_output` | core | Clear the editor output panel. |

### Debug-Advanced (72 advanced)

| Tool | Tier | Description |
| --- | --- | --- |
| `get_performance_metrics` | advanced | Get performance metrics from the editor or running game. |
| `get_debugger_sessions` | advanced | List Godot editor debugger sessions and their active/break state. |
| `set_debugger_breakpoint` | advanced | Enable or disable a breakpoint in active Godot debugger sessions. |
| `send_debugger_message` | advanced | Send a custom debugger message to active Godot debugger sessions. |
| `toggle_debugger_profiler` | advanced | Toggle an EngineProfiler in active Godot debugger sessions. |
| `get_debugger_messages` | advanced | Read custom messages captured by the Godot debugger bridge. |
| `add_debugger_capture_prefix` | advanced | Allow the debugger bridge to capture custom EngineDebugger messages with the given prefix. |
| `get_debug_stack_frames` | advanced | Return the latest captured script stack frames and request a fresh stack dump from breaked sessions. |
| `get_debug_stack_variables` | advanced | Return latest captured local/member/global variables for a stack frame and request a fresh variable dump. |
| `install_runtime_probe` | advanced | Install a runtime probe for debugging. |
| `remove_runtime_probe` | advanced | Remove a runtime probe. |
| `request_debug_break` | advanced | Request the debugger to break at the current execution point. |
| `send_debug_command` | advanced | Send a command to the debugger. |
| `get_runtime_info` | advanced | Get runtime information about the running game. |
| `get_runtime_ui_semantics` | advanced | Return runtime Control paths, semantic text, screen rectangles and interaction state, with filters and optional point hit-testing. |
| `await_scene_ready` | advanced | Poll the runtime until the specified scene is loaded and ready. |
| `get_runtime_scene_tree` | advanced | Get the scene tree from the running game. |
| `inspect_runtime_node` | advanced | Inspect a node in the running game. |
| `update_runtime_node_property` | advanced | Update a node property in the running game. |
| `call_runtime_node_method` | advanced | Call a method on a node in the running game. |
| `evaluate_runtime_expression` | advanced | Evaluate an expression in the running game context. Guarded by the script sandbox under STRICT security. |
| `await_runtime_condition` | advanced | Wait for a condition to be true in the running game. |
| `assert_runtime_condition` | advanced | Assert a condition in the running game. |
| `play_and_verify` | advanced | Drive the running game through a scripted sequence of input steps (with optional waits and screenshots), then evaluate a batch of runtime assertions, returning a single pass/fail report. Set deterministic=true to make per-step 'wait_frames' advance an exact number of physics frames inside the game (frame-stepped, fps-independent and reproducible) instead of a wall-clock approximation; combine with 'sample' to record a frame-indexed trajectory and per-label 'metrics' (min/max/first/last/delta/peak frame+time) for measuring game feel, and assert on them via {metric, aggregate, operator, expected}. Runtime errors the game emits during the run are captured via the debugger bridge and (by default) fail the report. Requires the game to be running with the runtime probe installed. |
| `visual_playtest` | advanced | Execute the full visual feedback loop in one call: optionally install the runtime probe and launch a scene, drive deterministic input steps and runtime assertions, ensure a final PNG screenshot, compare or bootstrap a golden baseline, combine runtime and visual results into one verdict, and stop a game launched by the call. |
| `assert_performance_budget` | advanced | Performance budget gate: capture a runtime performance snapshot from the running game and check it against a budget, returning a pass/fail verdict plus a per-metric breakdown. Budget keys: min_fps, max_frame_time_ms, max_physics_frame_time_ms, max_object_count, max_resource_count, max_rendered_objects, max_memory_mb, max_node_count (define only the ones to enforce). min_* checks actual >= limit; max_* checks actual <= limit. Pass an explicit 'snapshot' object to evaluate a previously captured snapshot instead of querying the game. Requires the game to be running with the runtime probe installed (unless 'snapshot' is supplied). |
| `assert_no_runtime_errors` | advanced | Runtime-error hard gate: scan the categorized debugger output captured from the running game and fail if any error events are present. By default it inspects the 'stderr' category; pass 'categories' to widen or narrow it, and 'since_sequence' to only consider events newer than a previously recorded sequence number (so you can gate a specific window of a run). Returns passed=false with the captured error events when any are found. |
| `get_debug_threads` | advanced | Return DAP-style debugger threads visible from the active Godot debug session. |
| `get_debug_state_events` | advanced | Read recorded debugger break/resume/stop state transitions from the bridge. |
| `get_debug_output` | advanced | Read categorized runtime debugger output captured by the editor bridge. |
| `get_debug_scopes` | advanced | Group latest captured stack variables into DAP-like scopes for a frame. |
| `get_debug_variables` | advanced | Resolve a DAP-style variablesReference into child variables, with optional pagination for large arrays and dictionaries. |
| `expand_debug_variable` | advanced | Expand a captured debug variable or evaluated expression value by scope and path, with pagination for arrays and dictionaries. |
| `evaluate_debug_expression` | advanced | Evaluate an expression in the paused script debugger context for a given frame. Guarded by the script sandbox under STRICT security. |
| `debug_step_into` | advanced | Step into the next function call in the debugger. |
| `debug_step_over` | advanced | Step over the next line in the debugger. |
| `debug_step_out` | advanced | Step out of the current function in the debugger. |
| `debug_continue` | advanced | Continue execution in the debugger. |
| `debug_step_into_and_wait` | advanced | Step into and wait for the debugger to pause. |
| `debug_step_over_and_wait` | advanced | Step over and wait for the debugger to pause. |
| `debug_step_out_and_wait` | advanced | Step out and wait for the debugger to pause. |
| `debug_continue_and_wait` | advanced | Continue and wait for the debugger to pause or complete. |
| `await_debugger_state` | advanced | Wait for a specific debugger state. |
| `get_runtime_performance_snapshot` | advanced | Get a performance snapshot from the running game. |
| `get_runtime_memory_trend` | advanced | Get memory usage trends from the running game. |
| `create_runtime_node` | advanced | Create a node in the running game. |
| `delete_runtime_node` | advanced | Delete a node in the running game. |
| `simulate_runtime_input_event` | advanced | Simulate an input event in the running game. |
| `simulate_runtime_input_action` | advanced | Simulate an input action in the running game. |
| `list_runtime_input_actions` | advanced | List input actions available in the running game. |
| `upsert_runtime_input_action` | advanced | Create or update an input action in the running game. |
| `remove_runtime_input_action` | advanced | Remove an input action from the running game. |
| `list_runtime_animations` | advanced | List animations available in the running game. |
| `play_runtime_animation` | advanced | Play an animation in the running game. |
| `stop_runtime_animation` | advanced | Stop an animation in the running game. |
| `get_runtime_animation_state` | advanced | Get the state of an animation in the running game. |
| `get_runtime_animation_tree_state` | advanced | Get the state of an animation tree in the running game. |
| `set_runtime_animation_tree_active` | advanced | Set an animation tree active/inactive in the running game. |
| `travel_runtime_animation_tree` | advanced | Travel to a new state in an animation tree in the running game. |
| `get_runtime_material_state` | advanced | Get the state of a material in the running game. |
| `get_runtime_theme_item` | advanced | Get a theme item in the running game. |
| `set_runtime_theme_override` | advanced | Set a theme override in the running game. |
| `clear_runtime_theme_override` | advanced | Clear a theme override in the running game. |
| `get_runtime_shader_parameters` | advanced | Get shader parameters in the running game. |
| `set_runtime_shader_parameter` | advanced | Set a shader parameter in the running game. |
| `list_runtime_tilemap_layers` | advanced | List TileMap layers in the running game. |
| `get_runtime_tilemap_cell` | advanced | Get a TileMap cell in the running game. |
| `set_runtime_tilemap_cell` | advanced | Set a TileMap cell in the running game. |
| `list_runtime_audio_buses` | advanced | List audio buses in the running game. |
| `get_runtime_audio_bus` | advanced | Get an audio bus in the running game. |
| `update_runtime_audio_bus` | advanced | Update an audio bus in the running game. |
| `get_runtime_screenshot` | advanced | Take a screenshot of the running game. |
