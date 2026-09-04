# scene_context.gd
# Editor-context drift guard shared by scene-scoped tools. When a workflow or
# caller names a target scene, the editor must edit that scene, otherwise node
# writes silently land in whatever scene happens to be open.

@tool
extends RefCounted

const ACTIVE_SCENE_STABILITY_FRAMES: int = 3


## Return only the editor's authoritative active root. Open scene roots are an
## unordered tab collection and must never be used as an active-scene fallback:
## during a scene switch that can select an unrelated, previously opened scene.
static func get_edited_user_scene_root(editor_interface: EditorInterface) -> Node:
	if editor_interface == null:
		return null
	var scene_root: Node = editor_interface.get_edited_scene_root()
	if scene_root == null or scene_root.name.begins_with("@") \
			or scene_root.get_class() == "PanelContainer":
		return null
	return scene_root


## Wait until the authoritative edited root matches target for consecutive
## frames. A one-frame match is not a committed scene switch: EditorFileSystem
## registration/import can briefly invalidate or replace the root afterward.
static func wait_for_scene_active(editor_interface: EditorInterface,
		target_scene_path: String, max_frames: int = 120) -> Node:
	if editor_interface == null:
		return null
	var stable_frames: int = 0
	var matching_root: Node = null
	for _frame in range(max_frames):
		await Engine.get_main_loop().process_frame
		var candidate: Node = get_edited_user_scene_root(editor_interface)
		if candidate and String(candidate.scene_file_path) == target_scene_path:
			stable_frames += 1
			matching_root = candidate
			if stable_frames >= ACTIVE_SCENE_STABILITY_FRAMES:
				return matching_root
		else:
			stable_frames = 0
			matching_root = null
	return null

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
	var active_root: Node = get_edited_user_scene_root(editor_interface)
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
	var switched_root: Node = await wait_for_scene_active(editor_interface, target)
	if switched_root:
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
