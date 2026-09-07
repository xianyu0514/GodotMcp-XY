"""Exercise scene batches against a real, isolated EditorUndoRedoManager.

The fixture enables only its test plugin, so it never opens the MCP HTTP port.
Run with GODOT_EXE pointing to a Godot 4.x editor executable.
"""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile


REPO_ROOT = Path(__file__).resolve().parents[2]
ARTIFACTS = REPO_ROOT / "test" / "integration" / ".tmp_adoption_batch"
DEFAULT_GODOT = Path(
    r"C:\Users\26901\Downloads\Godot_v4.7-stable_win64.exe\Godot_v4.7-stable_win64_console.exe"
)

SCENE = '''[gd_scene format=3]

[node name="Scene" type="Node2D"]

[node name="First" type="Node2D" parent="."]

[node name="Nested" type="Node" parent="First"]

[node name="Second" type="Node2D" parent="."]

[node name="Destination" type="Node2D" parent="."]
'''

PLUGIN = '''@tool
extends EditorPlugin

var failures: Array[String] = []
var checks: int = 0

func _enter_tree() -> void:
    call_deferred("_run")

func _check(condition: bool, message: String) -> void:
    checks += 1
    if not condition:
        failures.append(message)

func _finish() -> void:
    var file: FileAccess = FileAccess.open("res://result.json", FileAccess.WRITE)
    file.store_string(JSON.stringify({"checks": checks, "failures": failures}))
    file.close()
    get_tree().quit(0 if failures.is_empty() else 1)

func _run() -> void:
    await get_tree().process_frame
    EditorInterface.open_scene_from_path("res://scene.tscn")
    for index in range(10):
        await get_tree().process_frame
    var root: Node = EditorInterface.get_edited_scene_root()
    if root == null:
        _check(false, "Fixture scene failed to open")
        _finish()
        return
    var tools: RefCounted = preload("res://addons/godot_mcp/tools/node_tools_native.gd").new()
    tools.initialize(EditorInterface)
    var first: Node = root.get_node("First")
    var nested: Node = first.get_node("Nested")
    var first_id: int = first.get_instance_id()
    var nested_id: int = nested.get_instance_id()
    var manager: EditorUndoRedoManager = get_undo_redo()
    var result: Dictionary = tools._tool_batch_scene_node_edits({"operations": [
        {"type": "delete", "node_path": "/root/First"}
    ]})
    _check(result.get("status") == "success", "Delete batch succeeds")
    var history: UndoRedo = manager.get_history_undo_redo(manager.get_object_history_id(root))
    if history == null or not history.has_undo():
        _check(false, "Batch must be in edited scene undo history")
        _finish()
        return
    history.undo()
    var restored: Node = root.get_node_or_null("First")
    _check(restored != null and restored.get_instance_id() == first_id, "Delete undo restores the exact original node")
    if restored == null or restored.get_instance_id() != first_id:
        _finish()
        return
    for cycle in range(2):
        _check(first.owner == root, "Root owner restored on cycle " + str(cycle))
        _check(nested.get_instance_id() == nested_id and nested.owner == root, "Nested identity and owner restored")
        _check(first.get_index() == 0, "Sibling position restored")
        history.redo()
        _check(first.get_parent() == null, "Redo removes the original node")
        history.undo()
    history.clear_history()
    first.position = Vector2(10, 20)
    root.get_node("Destination").position = Vector2(100, 200)
    var result_mixed: Dictionary = tools._tool_batch_scene_node_edits({"operations": [
        {"type": "rename", "node_path": "/root/First", "new_name": "Renamed"},
        {"type": "move", "node_path": "/root/First", "new_parent_path": "/root/Destination"},
        {"type": "create", "parent_path": "/root/Destination", "node_type": "Node2D", "node_name": "New"},
        {"type": "delete", "node_path": "/root/Second"}
    ]})
    _check(result_mixed.get("status") == "success", "Mixed batch succeeds")
    if result_mixed.has("error"):
        _finish()
        return
    var operations: Array = result_mixed["operations"]
    _check(operations[1].get("node_path") == "/root/Scene/Destination/Renamed", "Move result follows earlier rename in the batch: " + str(operations[1]))
    var created: Node = root.get_node("Destination/New")
    var created_id: int = created.get_instance_id()
    for cycle in range(2):
        _check(root.get_node("Destination/Renamed") == first, "Mixed move retains original identity")
        _check(first.owner == root and nested.owner == root and created.owner == root, "Mixed batch preserves persistence owners")
        _check(first.global_position == Vector2(10, 20), "Move preserves global transform")
        _check(root.get_node_or_null("Second") == null, "Mixed delete applied")
        history.undo()
        _check(root.get_node("First") == first and first.get_index() == 0, "Mixed undo restores first node and order")
        _check(root.get_node("Second").get_index() == 1, "Mixed undo restores deleted sibling order")
        _check(first.position == Vector2(10, 20) and nested.owner == root, "Mixed undo restores transform and descendant owner")
        _check(created.get_parent() == null, "Mixed undo detaches created node")
        history.redo()
        _check(root.get_node("Destination/New").get_instance_id() == created_id, "Mixed redo reuses created node")
    history.undo()
    history.clear_history()
    _check(not is_instance_id_valid(created_id), "Discarded create history frees undone node")
    var packed: PackedScene = PackedScene.new()
    _check(packed.pack(root) == OK, "Restored scene packs")
    var reloaded: Node = packed.instantiate()
    _check(reloaded.get_node_or_null("First/Nested") != null, "Restored subtree persists when saved")
    reloaded.free()
    var invalid: Dictionary = tools._tool_batch_scene_node_edits({"operations": [
        {"type": "rename", "node_path": "/root/First", "new_name": "Changed"},
        {"type": "delete", "node_path": "/root/Missing"}
    ]})
    _check(invalid.has("error") and root.get_node_or_null("First") == first, "Invalid mixed batch leaves original scene untouched")
    _check(not history.has_undo(), "Invalid batch does not add undo history")
    var extended: Dictionary = tools._tool_batch_scene_node_edits({"save": true, "operations": [
        {"type": "create", "parent_path": "/root", "node_name": "Actor", "node_type": "Node2D"},
        {"type": "attach_script", "node_path": "/root/Actor", "script_path": "res://batch_actor.gd"},
        {"type": "set_property", "node_path": "/root/Actor", "property_name": "health", "property_value": 7},
        {"type": "set_property", "node_path": "/root/Actor", "property_name": "health", "property_value": 9},
        {"type": "connect_signal", "node_path": "/root/Actor", "signal_name": "changed", "method_name": "on_changed"},
        {"type": "connect_signal", "node_path": "/root/Actor", "signal_name": "changed", "method_name": "on_changed"}
    ]})
    _check(extended.get("status") == "success", "Extended batch succeeds: " + str(extended))
    if extended.has("error"):
        _finish()
        return
    _check(extended.get("saved", false), "Existing save option is preserved")
    _check(extended.get("operation_count") == 6, "Every extended operation has a result")
    var actor: Node = root.get_node("Actor")
    var actor_id: int = actor.get_instance_id()
    for cycle in range(2):
        _check(actor.get("health") == 9, "Ordered property writes apply")
        _check(actor.is_connected("changed", Callable(actor, "on_changed")), "Script signal connects once")
        history.undo()
        _check(actor.get_parent() == null and actor.get_script() == null, "Extended undo reverses attachment before detaching create")
        history.redo()
        _check(root.get_node("Actor").get_instance_id() == actor_id, "Extended redo preserves identity")
    var saved: PackedScene = ResourceLoader.load("res://scene.tscn", "PackedScene", ResourceLoader.CACHE_MODE_IGNORE)
    var saved_root: Node = saved.instantiate()
    _check(saved_root.get_node("Actor").get("health") == 9, "Saved script properties persist")
    _check(saved_root.get_node("Actor").is_connected("changed", Callable(saved_root.get_node("Actor"), "on_changed")), "Saved signal connection persists")
    saved_root.free()
    history.undo()
    history.clear_history()
    _check(not is_instance_id_valid(actor_id), "Discarded extended create is freed")
    var nodes_before: int = int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))
    var failed_extended: Dictionary = tools._tool_batch_scene_node_edits({"operations": [
        {"type": "create", "parent_path": "/root", "node_name": "Temporary"},
        {"type": "set_property", "node_path": "/root/Temporary", "property_name": "missing_property", "property_value": 1}
    ]})
    _check(failed_extended.has("error"), "Invalid extended operation is rejected")
    _check(int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)) == nodes_before, "Failed extended preparation frees temporary nodes")
    _check(root.get_node_or_null("Temporary") == null and not history.has_undo(), "Failed extended preparation changes neither scene nor history")
    var deleted_target: Dictionary = tools._tool_batch_scene_node_edits({"operations": [
        {"type": "delete", "node_path": "/root/First"},
        {"type": "set_property", "node_path": "/root/First", "property_name": "position", "property_value": {"x": 0, "y": 0}}
    ]})
    _check(deleted_target.has("error") and first.get_parent() == root, "Extended edits cannot address an earlier deleted node")
    tools._tool_batch_scene_node_edits({"operations": [{"type": "delete", "node_path": "/root/First"}]})
    history.clear_history()
    _check(not is_instance_id_valid(first_id), "Discarded delete history frees detached original node")
    _check(not is_instance_id_valid(nested_id), "Discarded delete history frees its subtree")
    _finish()
'''


def main() -> None:
    godot = Path(os.environ.get("GODOT_EXE", str(DEFAULT_GODOT)))
    if not godot.is_file():
        raise FileNotFoundError(f"Set GODOT_EXE to your Godot editor executable: {godot}")
    ARTIFACTS.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="editor_", dir=ARTIFACTS) as directory:
        project = Path(directory)
        shutil.copytree(REPO_ROOT / "addons/godot_mcp", project / "addons/godot_mcp")
        fixture = project / "addons/batch_recovery"
        fixture.mkdir()
        (fixture / "plugin.cfg").write_text(
            '[plugin]\nname="Batch Recovery Test"\ndescription="Isolated test"\nauthor="Test"\nversion="1"\nscript="plugin.gd"\n',
            encoding="utf-8",
        )
        (fixture / "plugin.gd").write_text(PLUGIN, encoding="utf-8")
        (project / "scene.tscn").write_text(SCENE, encoding="utf-8")
        (project / "batch_actor.gd").write_text(
            '@tool\nextends Node2D\n@export var health: int = 1\nsignal changed\nfunc on_changed() -> void:\n\tpass\n', encoding="utf-8"
        )
        (project / "project.godot").write_text(
            'config_version=5\n[application]\nconfig/name="Batch Recovery Test"\n'
            '[rendering]\nrenderer/rendering_method="gl_compatibility"\n'
            '[editor_plugins]\nenabled=PackedStringArray("res://addons/batch_recovery/plugin.cfg")\n',
            encoding="utf-8",
        )
        env = os.environ.copy()
        if os.name == "nt":
            for key in ("APPDATA", "LOCALAPPDATA"):
                location = ARTIFACTS / key.lower()
                location.mkdir(exist_ok=True)
                env[key] = str(location)
        completed = subprocess.run(
            [str(godot), "--headless", "--editor", "--path", str(project),
             "--log-file", str(ARTIFACTS / "editor.log"), "--quit-after", "600"],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
            encoding="utf-8", errors="replace", timeout=90, env=env,
            creationflags=subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0,
        )
        result_path = project / "result.json"
        if not result_path.is_file():
            raise AssertionError(f"Editor fixture did not finish:\n{completed.stdout}")
        result = json.loads(result_path.read_text(encoding="utf-8"))
        (ARTIFACTS / "result.json").write_text(json.dumps(result, indent=2), encoding="utf-8")
        if completed.returncode or result["failures"]:
            raise AssertionError(f"Recovery checks failed: {result}\n{completed.stdout}")
        if "SCRIPT ERROR" in completed.stdout or "Invalid owner" in completed.stdout:
            raise AssertionError(f"Unexpected engine errors:\n{completed.stdout}")
        print(f"PASS: {result['checks']} real EditorUndoRedo recovery checks")


if __name__ == "__main__":
    main()
