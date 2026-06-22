# Debug & Runtime Tools

[← Tools reference](README.md)

**71 tools** — 3 core, 68 advanced.

The largest category. Edit-time debugging (logs, debugger sessions, breakpoints, stack frames and variables, profilers) plus a rich **runtime probe** API that inspects and drives a *running* game: live scene tree, node inspection/mutation, expression evaluation, input injection, and animation / audio / shader / theme / tilemap control.

> Core tools are enabled out of the box. Advanced tools are registered but disabled by
> default; enable the ones you need from the **MCP** dock panel (or in tests via
> `core.set_tool_enabled("<tool>", true)`). See [the tools overview](README.md) for details.

### Debug (3)

| Tool | Tier | Description |
| --- | --- | --- |
| `get_editor_logs` | Core | Get recent log messages from the editor or runtime. Supports filtering by source, type, and pagination. |
| `debug_print` | Core | Print debug messages to the editor console. |
| `clear_output` | Core | Clear the editor output panel. |

### Debug-Advanced (68)

| Tool | Tier | Description |
| --- | --- | --- |
| `get_performance_metrics` | Advanced | Get performance metrics from the editor or running game. |
| `get_debugger_sessions` | Advanced | List Godot editor debugger sessions and their active/break state. |
| `set_debugger_breakpoint` | Advanced | Enable or disable a breakpoint in active Godot debugger sessions. |
| `send_debugger_message` | Advanced | Send a custom debugger message to active Godot debugger sessions. |
| `toggle_debugger_profiler` | Advanced | Toggle an EngineProfiler in active Godot debugger sessions. |
| `get_debugger_messages` | Advanced | Read custom messages captured by the Godot debugger bridge. |
| `add_debugger_capture_prefix` | Advanced | Allow the debugger bridge to capture custom EngineDebugger messages with the given prefix. |
| `get_debug_stack_frames` | Advanced | Return the latest captured script stack frames and request a fresh stack dump from breaked sessions. |
| `get_debug_stack_variables` | Advanced | Return latest captured local/member/global variables for a stack frame and request a fresh variable dump. |
| `install_runtime_probe` | Advanced | Install a runtime probe for debugging. |
| `remove_runtime_probe` | Advanced | Remove a runtime probe. |
| `request_debug_break` | Advanced | Request the debugger to break at the current execution point. |
| `send_debug_command` | Advanced | Send a command to the debugger. |
| `get_runtime_info` | Advanced | Get runtime information about the running game. |
| `await_scene_ready` | Advanced | Poll the runtime until the specified scene is loaded and ready. |
| `get_runtime_scene_tree` | Advanced | Get the scene tree from the running game. |
| `inspect_runtime_node` | Advanced | Inspect a node in the running game. |
| `update_runtime_node_property` | Advanced | Update a node property in the running game. |
| `call_runtime_node_method` | Advanced | Call a method on a node in the running game. |
| `evaluate_runtime_expression` | Advanced | Evaluate an expression in the running game context. |
| `await_runtime_condition` | Advanced | Wait for a condition to be true in the running game. |
| `assert_runtime_condition` | Advanced | Assert a condition in the running game. |
| `play_and_verify` | Advanced | Drive the running game through scripted input steps (with waits/screenshots), then evaluate a batch of runtime assertions and return a single pass/fail report. |
| `get_debug_threads` | Advanced | Return DAP-style debugger threads visible from the active Godot debug session. |
| `get_debug_state_events` | Advanced | Read recorded debugger break/resume/stop state transitions from the bridge. |
| `get_debug_output` | Advanced | Read categorized runtime debugger output captured by the editor bridge. |
| `get_debug_scopes` | Advanced | Group latest captured stack variables into DAP-like scopes for a frame. |
| `get_debug_variables` | Advanced | Resolve a DAP-style variablesReference into child variables, with optional pagination for large arrays and dictionaries. |
| `expand_debug_variable` | Advanced | Expand a captured debug variable or evaluated expression value by scope and path, with pagination for arrays and dictionaries. |
| `evaluate_debug_expression` | Advanced | Evaluate an expression in the paused script debugger context for a given frame. |
| `debug_step_into` | Advanced | Step into the next function call in the debugger. |
| `debug_step_over` | Advanced | Step over the next line in the debugger. |
| `debug_step_out` | Advanced | Step out of the current function in the debugger. |
| `debug_continue` | Advanced | Continue execution in the debugger. |
| `debug_step_into_and_wait` | Advanced | Step into and wait for the debugger to pause. |
| `debug_step_over_and_wait` | Advanced | Step over and wait for the debugger to pause. |
| `debug_step_out_and_wait` | Advanced | Step out and wait for the debugger to pause. |
| `debug_continue_and_wait` | Advanced | Continue and wait for the debugger to pause or complete. |
| `await_debugger_state` | Advanced | Wait for a specific debugger state. |
| `get_runtime_performance_snapshot` | Advanced | Get a performance snapshot from the running game. |
| `get_runtime_memory_trend` | Advanced | Get memory usage trends from the running game. |
| `create_runtime_node` | Advanced | Create a node in the running game. |
| `delete_runtime_node` | Advanced | Delete a node in the running game. |
| `simulate_runtime_input_event` | Advanced | Simulate an input event in the running game. |
| `simulate_runtime_input_action` | Advanced | Simulate an input action in the running game. |
| `list_runtime_input_actions` | Advanced | List input actions available in the running game. |
| `upsert_runtime_input_action` | Advanced | Create or update an input action in the running game. |
| `remove_runtime_input_action` | Advanced | Remove an input action from the running game. |
| `list_runtime_animations` | Advanced | List animations available in the running game. |
| `play_runtime_animation` | Advanced | Play an animation in the running game. |
| `stop_runtime_animation` | Advanced | Stop an animation in the running game. |
| `get_runtime_animation_state` | Advanced | Get the state of an animation in the running game. |
| `get_runtime_animation_tree_state` | Advanced | Get the state of an animation tree in the running game. |
| `set_runtime_animation_tree_active` | Advanced | Set an animation tree active/inactive in the running game. |
| `travel_runtime_animation_tree` | Advanced | Travel to a new state in an animation tree in the running game. |
| `get_runtime_material_state` | Advanced | Get the state of a material in the running game. |
| `get_runtime_theme_item` | Advanced | Get a theme item in the running game. |
| `set_runtime_theme_override` | Advanced | Set a theme override in the running game. |
| `clear_runtime_theme_override` | Advanced | Clear a theme override in the running game. |
| `get_runtime_shader_parameters` | Advanced | Get shader parameters in the running game. |
| `set_runtime_shader_parameter` | Advanced | Set a shader parameter in the running game. |
| `list_runtime_tilemap_layers` | Advanced | List TileMap layers in the running game. |
| `get_runtime_tilemap_cell` | Advanced | Get a TileMap cell in the running game. |
| `set_runtime_tilemap_cell` | Advanced | Set a TileMap cell in the running game. |
| `list_runtime_audio_buses` | Advanced | List audio buses in the running game. |
| `get_runtime_audio_bus` | Advanced | Get an audio bus in the running game. |
| `update_runtime_audio_bus` | Advanced | Update an audio bus in the running game. |
| `get_runtime_screenshot` | Advanced | Take a screenshot of the running game. |
