# Script Tools

[← Tools reference](README.md)

**18 tools** — 6 core, 12 advanced.

Read, create, modify, validate and search project scripts. The category supports GDScript, C# project inspection, shader validation and symbol/reference workflows.

## Recommended workflow

1. Discover files with `list_project_scripts` or `search_in_files`.
2. Read context with `read_script` or `batch_read_scripts`; retain each `content_hash`.
3. Edit with `create_script`, `modify_script` or `attach_script`. For existing scripts, prefer `old_text` plus `expected_content_hash`.
4. Validate with `validate_script`, `validate_shader`, symbol indexing and reference search tools.

## Tool list

### Script (6 core)

| Tool | Tier | Description |
| --- | --- | --- |
| `list_project_scripts` | core | List GDScript (.gd) and C# (.cs) script files in the project. Supports `limit`/`offset` pagination; `count` is the page size and `total_count` is the full total. Returns paths relative to res://. |
| `read_script` | core | Read complete GDScript/C# source and its SHA-256 `content_hash`. |
| `create_script` | core | Create a GDScript or C# file; return immediate GDScript diagnostics separately from file-write success. |
| `modify_script` | core | Replace a script, valid line or unique `old_text` block; optionally guard against stale content, reject unsaved target buffers when supported, and return saved-source diagnostics. |
| `get_current_script` | core | Get the currently edited script in the Godot editor. |
| `attach_script` | core | Attach a script to a node. |
| `execute_script` | advanced | Execute a script in the editor context. Guarded by the script sandbox under STRICT security (both the multi-line and single-line expression paths). |

### Script-Advanced (12 advanced)

| Tool | Tier | Description |
| --- | --- | --- |
| `batch_read_scripts` | advanced | Read multiple GDScript/C# files; each successful entry includes source and `content_hash`, with individual errors for unreadable paths. |
| `analyze_script` | advanced | Analyze a GDScript file and report code quality issues. |
| `validate_script` | advanced | Validate a script file for syntax errors. Returns structured compile errors with line numbers. |
| `verify_scripts` | advanced | Batch-verify the compilation status of project scripts, returning per-script structured errors and warnings with line numbers. With no script_paths it scans the whole project for .gd scripts (skipping res://addons/ and res://test/ by default to avoid false positives from the plugin itself and the test suite), capped by max_scripts. Use after editing code as a verification step, complementing validate_script (single script) and execute_editor_script (full reload). |
| `validate_shader` | advanced | Validate a Godot shader (.gdshader file or raw Shader code) without a GPU. Reports whether it parses plus shader_type render_modes and uniforms and structural issues (missing/invalid shader_type unbalanced braces/parentheses/brackets) with line numbers. Works on Godot 4.6+. |
| `search_in_files` | advanced | Search for text in project files. Discovery skips generated domains (`.godot`/`.import`) and by default tooling directories (`include_tooling=true` or a tooling `search_path` includes them); `max_files` (default 2000) bounds zero-match scans. |
| `list_project_script_symbols` | advanced | Index script symbols across project GDScript and C# files. Returns class, extends, functions, signals, properties, and constants. |
| `find_script_symbol_definition` | advanced | Find definition locations for a script symbol across GDScript and C# project files. |
| `find_script_symbol_references` | advanced | Find textual project references to a script symbol across GDScript, C#, and scene files. |
| `rename_script_symbol` | advanced | Rename a script symbol across project files using identifier-boundary text replacements. Supports dry-run previews before applying changes. |
| `open_script_at_line` | advanced | Open a script file at a specific line number in the Godot editor. |

## Preserve existing work while editing

After reading a script, pass its `content_hash` back as `expected_content_hash`. The hash covers the returned UTF-8 text, including line endings. A successful modification returns the next `content_hash`, including when the written source fails compilation.

```json
{
  "script_path": "res://player.gd",
  "old_text": "var speed: int = 100",
  "content": "var speed: int = 250",
  "expected_content_hash": "<64-character content_hash from read_script>"
}
```

`old_text` must be nonempty and occur exactly once, including whitespace. Multiline replacements and deletion (`content: ""`) are supported. Missing or ambiguous matches return `text_not_found` / `ambiguous_text` and a `recovery_hint`, without writing. Include more surrounding code to disambiguate. Do not combine `old_text` and `line_number`.

A stale hash returns `content_conflict` and `current_content_hash`. Re-read the file, preserve newer edits and reapply the intended change. Do not blindly retry an old full replacement with the new hash. Known unsaved target buffers return `unsaved_script_changes`; preserve or resolve those editor changes before re-reading.

Existing whole-file requests still work without the optional hash. `line_number: 0` retains whole-file replacement; positive values replace an existing line, preserving untouched CRLF/LF and final-newline text. Invalid, negative or out-of-range lines are rejected instead of replacing the whole script.

`buffer_guard_supported` reports whether successful writes could inspect unsaved editor buffers. It is false without an editor or when the engine lacks the API (such as Godot 4.6). The content hash checks disk state only. This is an optimistic precondition on one script, not a filesystem lock, cross-file transaction or crash recovery guarantee; other write tools are outside this contract.

## Diagnostics after script writes

`create_script` and `modify_script` retain `status: "success"` for a successful file write. Inspect `validation_status` separately: `passed`, `failed` or `not_checked`. A saved file can still contain compiler errors; failed validation does not roll back the requested write. Creation skips optional node attachment when compilation fails. `modify_script` preserves its existing `validation` summary; `validate: false` skips compilation, returns `not_checked` and omits that legacy summary.

`diagnostics` contains up to 64 entries with `severity`, `path`, `line` (1-based, or 0 when unavailable) and `message`; `diagnostics_truncated` indicates omitted entries. `validation_hint` explains failures or skipped checks. C# requires a .NET build. Project script-template paths skipped by Godot return `not_checked`.

Loading at the saved path retains relative preloads, registered global classes and editor autoload context. Godot may refresh an existing Script resource; dependent scripts retain normal engine cache semantics. After related writes, use `verify_scripts` and runtime verification before treating a feature as complete.
