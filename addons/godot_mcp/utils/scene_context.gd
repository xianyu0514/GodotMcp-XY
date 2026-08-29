# scene_context.gd
# Editor-context drift guard shared by scene-scoped tools. When a workflow or
# caller names a target scene, the editor must edit that scene, otherwise node
# writes silently land in whatever scene happens to be open.

@tool
extends RefCounted

## Ensures `target_scene_path` is the active edited scene. A no-op when the
## target is already active; saves the previous scene first when it has
## unsaved edits so a context switch never loses work.
static func ensure_scene_active(editor_interface: EditorInterface,
		target_scene_path: String) -> Dictionary:
	var target: String = target_scene_path.strip_edges()
	if target.is_empty():
		return {"ok": true, "switched": false}
	if editor_interface == null:
		return {"ok": false, "error": "Editor interface not available"}
	if not FileAccess.file_exists(target):
		return {"ok": false, "error": "Scene file not found: " + target}
	var active_root: Node = editor_interface.get_edited_scene_root()
	var active_path: String = String(active_root.scene_file_path) if active_root else ""
	if active_path == target:
		return {"ok": true, "switched": false}
	var saved_previous: bool = false
	if active_root and not active_path.is_empty() \
			and scene_is_modified(editor_interface, active_root):
		editor_interface.save_scene()
		saved_previous = true
	editor_interface.open_scene_from_path(target)
	var switched_root: Node = editor_interface.get_edited_scene_root()
	var switched_path: String = String(switched_root.scene_file_path) if switched_root else ""
	if switched_path != target:
		return {"ok": false, "error": "Failed to activate scene: " + target}
	return {"ok": true, "switched": true, "saved_previous": saved_previous}

static func scene_is_modified(editor_interface: EditorInterface, scene_root: Node) -> bool:
	if editor_interface == null or scene_root == null:
		return false
	var undo_redo_mgr: EditorUndoRedoManager = editor_interface.get_editor_undo_redo()
	if undo_redo_mgr == null:
		return false
	var history_id: int = undo_redo_mgr.get_object_history_id(scene_root)
	var undo_redo: UndoRedo = undo_redo_mgr.get_history_undo_redo(history_id)
	return undo_redo != null and undo_redo.has_undo()
