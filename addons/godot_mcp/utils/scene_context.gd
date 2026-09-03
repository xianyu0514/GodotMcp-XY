# scene_context.gd
# Editor-context drift guard shared by scene-scoped tools. When a workflow or
# caller names a target scene, the editor must edit that scene, otherwise node
# writes silently land in whatever scene happens to be open.

@tool
extends RefCounted

## Ensures `target_scene_path` is the active edited scene. A no-op when the
## target is already active; saves the previous scene first when it has
## unsaved edits so a context switch never loses work. open_scene_from_path
## takes effect on a later frame, so the switch is confirmed by polling a few
## frames — callers must await this coroutine.
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
	# 与 open_scene 工具同因修复：刚创建/保存的场景可能尚未进入
	# EditorFileSystem 缓存，open_scene_from_path 会静默失败——update_file
	# 幂等，先登记再打开（CI 上曾以 "Failed to activate scene" 形式抖动）。
	var editor_fs: EditorFileSystem = editor_interface.get_resource_filesystem()
	if editor_fs != null:
		editor_fs.update_file(target)
	editor_interface.open_scene_from_path(target)
	var switched_path: String = ""
	for _frame in range(120):
		await Engine.get_main_loop().process_frame
		var switched_root: Node = editor_interface.get_edited_scene_root()
		switched_path = String(switched_root.scene_file_path) if switched_root else ""
		if switched_path == target:
			return {"ok": true, "switched": true, "saved_previous": saved_previous}
	return {"ok": false, "error": "Failed to activate scene: " + target}

static func scene_is_modified(editor_interface: EditorInterface, scene_root: Node) -> bool:
	if editor_interface == null or scene_root == null:
		return false
	var undo_redo_mgr: EditorUndoRedoManager = editor_interface.get_editor_undo_redo()
	if undo_redo_mgr == null:
		return false
	var history_id: int = undo_redo_mgr.get_object_history_id(scene_root)
	var undo_redo: UndoRedo = undo_redo_mgr.get_history_undo_redo(history_id)
	return undo_redo != null and undo_redo.has_undo()
