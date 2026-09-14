extends RefCounted
## Coalesces Godot editor/file-system signals into one deterministic cache
## invalidation batch per process frame.
##
## EditorFileSystem's generic filesystem_changed signal carries no paths. The
## tracker compares the editor's previous/current path sets to recover additions,
## removals and renames. Path-bearing reload/save signals explain content-only
## changes. Only an event with neither source falls back to broad file-domain
## invalidation, while the result-cache TTL remains the final safety backstop.

var _known_paths: Dictionary = {}
var _pending_paths: Dictionary = {}
var _pending_structural_paths: Dictionary = {}
var _filesystem_event_seen: bool = false
var _reimported: bool = false
var _sources_changed: bool = false
var _script_classes_updated: bool = false
var _project_settings_changed: bool = false


func seed_paths(paths: PackedStringArray) -> void:
	_known_paths = _path_set(paths)


func queue_paths(paths: PackedStringArray, reimported: bool = false) -> void:
	for path_value in paths:
		var path: String = _normalized_path(path_value)
		if not path.is_empty():
			_pending_paths[path] = true
	_reimported = _reimported or reimported


func queue_filesystem_snapshot(paths: PackedStringArray) -> void:
	var current_paths: Dictionary = _path_set(paths)
	for path_value in _known_paths:
		var previous_path: String = String(path_value)
		if not current_paths.has(previous_path):
			_pending_paths[previous_path] = true
			_pending_structural_paths[previous_path] = true
	for path_value in current_paths:
		var current_path: String = String(path_value)
		if not _known_paths.has(current_path):
			_pending_paths[current_path] = true
			_pending_structural_paths[current_path] = true
	_known_paths = current_paths
	_filesystem_event_seen = true


func queue_sources_changed() -> void:
	_sources_changed = true


func queue_script_classes_updated() -> void:
	_script_classes_updated = true


func queue_project_settings_changed() -> void:
	_project_settings_changed = true


func flush() -> Dictionary:
	var paths: PackedStringArray = _sorted_paths(_pending_paths)
	var structural_paths: PackedStringArray = _sorted_paths(_pending_structural_paths)
	var filesystem_fallback: bool = _filesystem_event_seen and paths.is_empty()
	var has_changes: bool = (
		not paths.is_empty()
		or _reimported
		or _sources_changed
		or _script_classes_updated
		or _project_settings_changed
		or filesystem_fallback)
	var result: Dictionary = {
		"paths": paths,
		"structural_paths": structural_paths,
		"reimported": _reimported,
		"sources_changed": _sources_changed,
		"script_classes_updated": _script_classes_updated,
		"project_settings_changed": _project_settings_changed,
		"filesystem_fallback": filesystem_fallback,
		"has_changes": has_changes
	}
	_pending_paths.clear()
	_pending_structural_paths.clear()
	_filesystem_event_seen = false
	_reimported = false
	_sources_changed = false
	_script_classes_updated = false
	_project_settings_changed = false
	return result


static func _path_set(paths: PackedStringArray) -> Dictionary:
	var result: Dictionary = {}
	for path_value in paths:
		var path: String = _normalized_path(path_value)
		if not path.is_empty():
			result[path] = true
	return result


static func _sorted_paths(path_set: Dictionary) -> PackedStringArray:
	var result: PackedStringArray = PackedStringArray()
	for path_value in path_set:
		result.append(String(path_value))
	result.sort()
	return result


static func _normalized_path(path_value: Variant) -> String:
	var normalized: String = str(path_value).strip_edges().replace("\\", "/")
	if normalized.begins_with("res:/") and not normalized.begins_with("res://"):
		normalized = "res://" + normalized.substr(5)
	while normalized.contains("//") and not normalized.begins_with("res://"):
		normalized = normalized.replace("//", "/")
	return normalized
