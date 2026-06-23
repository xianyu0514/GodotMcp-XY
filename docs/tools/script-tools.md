# Script Tools

[← Tools reference](README.md)

**17 tools** — 7 core, 10 advanced.

Read, create, modify, validate and search project scripts. The category supports GDScript, C# project inspection, shader validation and symbol/reference workflows.

## Recommended workflow

1. Discover files with `list_project_scripts` or `search_in_files`.
2. Read context with `read_script` or `batch_read_scripts`.
3. Edit with `create_script`, `modify_script` or `attach_script`.
4. Validate with `validate_script`, `validate_shader`, symbol indexing and reference search tools.

## Tool list

### Script (7 core)

| Tool | Tier | Description |
| --- | --- | --- |
| `list_project_scripts` | core | List all GDScript files (.gd) in the project. Returns paths relative to res://. |
| `read_script` | core | Read the content of a GDScript file (.gd). Returns the complete script source code. |
| `create_script` | core | Create a new GDScript file with optional template. GDScript files are complete programs, not resource files. |
| `modify_script` | core | Modify the content of an existing GDScript file. Can replace entire content or specific lines. |
| `get_current_script` | core | Get the currently edited script in the Godot editor. |
| `attach_script` | core | Attach a script to a node. |
| `execute_script` | core | Execute a script in the editor context. Guarded by the script sandbox under STRICT security (both the multi-line and single-line expression paths). |

### Script-Advanced (10 advanced)

| Tool | Tier | Description |
| --- | --- | --- |
| `batch_read_scripts` | advanced | Read the contents of multiple GDScript (.gd) or C# (.cs) script files in a single call. Returns one result entry per requested path, reducing round trips when reading several scripts. |
| `analyze_script` | advanced | Analyze a GDScript file and report code quality issues. |
| `validate_script` | advanced | Validate a script file for syntax errors. |
| `validate_shader` | advanced | Validate a Godot shader (.gdshader file or raw Shader code) without a GPU. Reports whether it parses plus shader_type render_modes and uniforms and structural issues (missing/invalid shader_type unbalanced braces/parentheses/brackets) with line numbers. Works on Godot 4.6+. |
| `search_in_files` | advanced | Search for text in project files. |
| `list_project_script_symbols` | advanced | Index script symbols across project GDScript and C# files. Returns class, extends, functions, signals, properties, and constants. |
| `find_script_symbol_definition` | advanced | Find definition locations for a script symbol across GDScript and C# project files. |
| `find_script_symbol_references` | advanced | Find textual project references to a script symbol across GDScript, C#, and scene files. |
| `rename_script_symbol` | advanced | Rename a script symbol across project files using identifier-boundary text replacements. Supports dry-run previews before applying changes. |
| `open_script_at_line` | advanced | Open a script file at a specific line number in the Godot editor. |
