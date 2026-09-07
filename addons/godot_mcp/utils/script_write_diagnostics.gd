@tool
extends RefCounted

## Per-write compiler feedback. Loading uses the saved path so relative preloads,
## global classes and editor autoloads retain their normal Godot context. The
## written source is rechecked through Godot's loader. GDScript's internal cache
## may refresh the existing Script; dependency caches are not force-reloaded.
class Capture extends Logger:
	const MAX_DIAGNOSTICS: int = 64
	var entries: Array[Dictionary] = []
	var has_errors: bool = false
	var truncated: bool = false
	var _thread_id: int = OS.get_thread_caller_id()

	func _log_error(_function: String, file: String, line: int,
			code: String, rationale: String, _editor_notify: bool,
			error_type: int, _script_backtraces: Array[ScriptBacktrace]) -> void:
		# ResourceLoader.load below is synchronous. Ignore unrelated worker-thread
		# imports; only the calling thread can read or write this capture buffer.
		if OS.get_thread_caller_id() != _thread_id or file.get_extension().to_lower() != "gd":
			return
		var severity: String = "warning" if error_type == ERROR_TYPE_WARNING else "error"
		if severity == "error":
			has_errors = true
		if entries.size() >= MAX_DIAGNOSTICS:
			truncated = true
			return
		entries.append({
			"severity": severity,
			"path": ProjectSettings.localize_path(file),
			"line": maxi(line, 0),
			"message": rationale if not rationale.is_empty() else code
		})

static func output_properties() -> Dictionary:
	return {
		"validation_status": {"type": "string", "enum": ["passed", "failed", "not_checked"], "description": "Compilation result, separate from the successful file write. C# and editor script templates are not_checked."},
		"diagnostics": {"type": "array", "items": {"type": "object", "properties": {
			"severity": {"type": "string"}, "path": {"type": "string"},
			"line": {"type": "integer"}, "message": {"type": "string"}
		}}},
		"diagnostics_truncated": {"type": "boolean"},
		"validation_hint": {"type": "string"}
	}

static func check(script_path: String, enabled: bool = true) -> Dictionary:
	if not enabled:
		return {"validation_status": "not_checked", "diagnostics": [], "diagnostics_truncated": false,
			"validation_hint": "The file was saved. Compilation was skipped by validate: false."}
	if script_path.get_extension().to_lower() != "gd":
		return {
			"validation_status": "not_checked",
			"diagnostics": [],
			"diagnostics_truncated": false,
			"validation_hint": "The file was saved. C# compilation requires the project's .NET build; GDScript validation was not applied."
		}

	# Godot 4.7 skips parsing any base directory starting with this setting.
	# Match that engine check, including custom template paths and its prefix rule.
	var template_dir: String = String(ProjectSettings.get_setting("editor/script/templates_search_path", "res://script_templates"))
	if Engine.is_editor_hint() and script_path.get_base_dir().begins_with(template_dir):
		return {
			"validation_status": "not_checked",
			"diagnostics": [],
			"diagnostics_truncated": false,
			"validation_hint": "The file was saved. Godot skips compilation in the project's script-template path; validate the instantiated script after replacing template placeholders."
		}

	var capture: Capture = Capture.new()
	OS.add_logger(capture)
	# No take_over_path, explicit Script.reload or instance construction. The
	# language loader owns refresh semantics for Scripts used by live objects.
	var script: GDScript = ResourceLoader.load(script_path, "GDScript", ResourceLoader.CACHE_MODE_IGNORE) as GDScript
	OS.remove_logger(capture)
	# can_instantiate() is false for valid non-@tool scripts in the editor and
	# for abstract scripts. Compilation is judged by the loader and its errors.
	var valid: bool = script != null and not capture.has_errors
	if not valid and not capture.has_errors:
		if capture.entries.size() >= Capture.MAX_DIAGNOSTICS:
			capture.entries.pop_back()
			capture.truncated = true
		capture.entries.append({
			"severity": "error",
			"path": script_path,
			"line": 0,
			"message": "Godot could not compile the saved script; an exact source location was not available."
		})
	var result: Dictionary = {
		"validation_status": "passed" if valid else "failed",
		"diagnostics": capture.entries,
		"diagnostics_truncated": capture.truncated
	}
	if not valid:
		result["validation_hint"] = "The file was saved. Inspect diagnostics and finish any related script writes, then call verify_scripts before running the project."
	return result
