# Script Tools

[← Tools reference](README.md)

**17 tools** — 7 core, 10 advanced.

Tools for working with GDScript and C# source files: reading, creating, modifying, attaching, analyzing and validating scripts, validating shaders, project-wide search, and symbol indexing (definition / reference lookup and rename).

> Core tools are enabled out of the box. Advanced tools are registered but disabled by
> default; enable the ones you need from the **MCP** dock panel (or in tests via
> `core.set_tool_enabled("<tool>", true)`). See [the tools overview](README.md) for details.

### Script (7)

| Tool | Tier | Description |
| --- | --- | --- |
| `list_project_scripts` | Core | List all GDScript files (.gd) in the project. Returns paths relative to res://. |
| `read_script` | Core | Read the content of a GDScript file (.gd). Returns the complete script source code. |
| `create_script` | Core | Create a new GDScript file with optional template. GDScript files are complete programs, not resource files. |
| `modify_script` | Core | Modify the content of an existing GDScript file. Can replace entire content or specific lines. |
| `get_current_script` | Core | Get the currently edited script in the Godot editor. |
| `attach_script` | Core | Attach a script to a node. |
| `execute_script` | Core | Execute a script in the editor context. |

### Script-Advanced (10)

| Tool | Tier | Description |
| --- | --- | --- |
| `batch_read_scripts` | Advanced | Read the contents of multiple GDScript (.gd) or C# (.cs) script files in a single call. Returns one result entry per requested path, reducing round trips when reading several scripts. |
| `analyze_script` | Advanced | Analyze a GDScript file and report code quality issues. |
| `validate_script` | Advanced | Validate a script file for syntax errors. |
| `validate_shader` | Advanced | Validate a Godot shader (.gdshader file or raw Shader code) without a GPU. Reports whether it parses plus shader_type render_modes and uniforms and structural issues (missing/invalid shader_type unbalanced braces/parentheses/brackets) with line numbers. Works on Godot 4.6+. |
| `search_in_files` | Advanced | Search for text in project files. |
| `list_project_script_symbols` | Advanced | Index script symbols across project GDScript and C# files. Returns class, extends, functions, signals, properties, and constants. |
| `find_script_symbol_definition` | Advanced | Find definition locations for a script symbol across GDScript and C# project files. |
| `find_script_symbol_references` | Advanced | Find textual project references to a script symbol across GDScript, C#, and scene files. |
| `rename_script_symbol` | Advanced | Rename a script symbol across project files using identifier-boundary text replacements. Supports dry-run previews before applying changes. |
| `open_script_at_line` | Advanced | Open a script file at a specific line number in the Godot editor. |
