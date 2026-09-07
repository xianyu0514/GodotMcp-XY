"""Check script-write diagnostics in a real isolated Godot 4.7 editor."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile


REPO_ROOT = Path(__file__).resolve().parents[2]
ARTIFACTS = REPO_ROOT / "test" / "integration" / ".tmp_adoption_diagnostics"
DEFAULT_GODOT = Path(
    r"C:\Users\26901\Downloads\Godot_v4.7-stable_win64.exe\Godot_v4.7-stable_win64_console.exe"
)

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

func _run() -> void:
    var fs: EditorFileSystem = EditorInterface.get_resource_filesystem()
    while fs.is_scanning():
        await get_tree().process_frame
    var tools: RefCounted = preload("res://addons/godot_mcp/tools/script_tools_native.gd").new()
    tools.initialize(EditorInterface)
    var valid: Dictionary = tools._tool_create_script({"script_path": "res://scripts/new_script.gd", "content": "extends Node\\n"})
    _check(valid.get("validation_status") == "passed", "Non-tool script must validate in the editor: " + str(valid))
    _check(valid.get("status") == "success", "File write retains success")
    var dependency: Dictionary = tools._tool_create_script({"script_path": "res://scripts/dependent.gd", "content": "extends RefCounted\\nconst Dependency = preload(\\"base.gd\\")\\nfunc read_value() -> int:\\n\\treturn DiagnosticAutoload.value\\n"})
    _check(dependency.get("validation_status") == "passed", "Relative preload and actual autoload name resolve: " + str(dependency))
    var global_class: Dictionary = tools._tool_modify_script({"script_path": "res://scripts/base.gd", "content": "class_name DiagnosticFixtureBase\\nextends RefCounted\\nconst VALUE: int = 8\\n"})
    _check(global_class.get("validation_status") == "passed", "Existing class_name validates at its actual path: " + str(global_class))
    var invalid: Dictionary = tools._tool_modify_script({"script_path": "res://scripts/new_script.gd", "content": "extends Node\\nfunc broken(\\n"})
    _check(invalid.get("status") == "success" and invalid.get("validation_status") == "failed", "A saved invalid script reports compilation failure")
    var diagnostics: Array = invalid.get("diagnostics", [])
    _check(not diagnostics.is_empty(), "Compiler diagnostics returned")
    if not diagnostics.is_empty():
        _check(diagnostics[0].get("path") == "res://scripts/new_script.gd", "Compiler error identifies written file")
        _check(int(diagnostics[0].get("line", 0)) == 2, "Compiler error gives exact line")
    var repaired: Dictionary = tools._tool_modify_script({"script_path": "res://scripts/new_script.gd", "content": "extends Node\\n"})
    _check(repaired.get("validation_status") == "passed", "Repair is checked against current source")
    _check(repaired.get("diagnostics", ["missing"]).is_empty(), "Previous errors do not leak into repaired response")
    var csharp: Dictionary = tools._tool_create_script({"script_path": "res://scripts/Player.cs", "content": "public class Player {}\\n"})
    _check(csharp.get("validation_status") == "not_checked", "C# does not claim GDScript validation")
    var template_dir: String = String(ProjectSettings.get_setting("editor/script/templates_search_path", "res://script_templates"))
    var template_path: String = template_dir.path_join("Node/diagnostic_template.gd")
    DirAccess.make_dir_recursive_absolute(template_path.get_base_dir())
    var template: Dictionary = tools._tool_create_script({"script_path": template_path, "content": "extends _BASE_\\nfunc broken(\\n"})
    _check(template.get("status") == "success" and template.get("validation_status") == "not_checked", "Templates skipped by the engine must not claim validation: " + str(template))
    var template_edit: Dictionary = tools._tool_modify_script({"script_path": template_path, "content": "extends _BASE_\\n"})
    _check(template_edit.get("validation_status") == "not_checked", "Template edits remain unchecked")
    _check(not String(template_edit.get("validation_hint", "")).is_empty(), "Unchecked templates explain why")
    var output: FileAccess = FileAccess.open("res://result.json", FileAccess.WRITE)
    output.store_string(JSON.stringify({"checks": checks, "failures": failures}))
    output.close()
    get_tree().quit(0 if failures.is_empty() else 1)
'''


def main() -> None:
    godot = Path(os.environ.get("GODOT_EXE", str(DEFAULT_GODOT)))
    if not godot.is_file():
        raise FileNotFoundError(f"Set GODOT_EXE to a Godot 4.7 executable: {godot}")
    ARTIFACTS.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="editor_", dir=ARTIFACTS) as directory:
        project = Path(directory)
        shutil.copytree(REPO_ROOT / "addons/godot_mcp", project / "addons/godot_mcp")
        fixture = project / "addons/diagnostics_test"
        fixture.mkdir()
        (fixture / "plugin.cfg").write_text(
            '[plugin]\nname="Diagnostics Test"\ndescription="Isolated test"\nauthor="Test"\nversion="1"\nscript="plugin.gd"\n', encoding="utf-8"
        )
        (fixture / "plugin.gd").write_text(PLUGIN, encoding="utf-8")
        (project / "scripts").mkdir()
        (project / "scripts/base.gd").write_text("class_name DiagnosticFixtureBase\nextends RefCounted\nconst VALUE: int = 7\n", encoding="utf-8")
        (project / "autoload.gd").write_text("extends Node\nvar value: int = 3\n", encoding="utf-8")
        (project / "project.godot").write_text(
            'config_version=5\n[application]\nconfig/name="Diagnostics Test"\n'
            '[autoload]\nDiagnosticAutoload="*res://autoload.gd"\n'
            '[rendering]\nrenderer/rendering_method="gl_compatibility"\n'
            '[editor_plugins]\nenabled=PackedStringArray("res://addons/diagnostics_test/plugin.cfg")\n', encoding="utf-8"
        )
        env = os.environ.copy()
        if os.name == "nt":
            for key in ("APPDATA", "LOCALAPPDATA"):
                location = ARTIFACTS / key.lower()
                location.mkdir(exist_ok=True)
                env[key] = str(location)
        completed = subprocess.run(
            [str(godot), "--headless", "--editor", "--path", str(project), "--log-file", str(ARTIFACTS / "editor.log"), "--quit-after", "600"],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, encoding="utf-8", errors="replace", timeout=90, env=env,
            creationflags=subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0,
        )
        result_path = project / "result.json"
        if not result_path.is_file():
            raise AssertionError(f"Editor fixture did not finish:\n{completed.stdout}")
        result = json.loads(result_path.read_text(encoding="utf-8"))
        (ARTIFACTS / "editor-result.json").write_text(json.dumps(result, indent=2), encoding="utf-8")
        if completed.returncode or result["failures"]:
            raise AssertionError(f"Diagnostics checks failed: {result}\n{completed.stdout}")
        print(f"PASS: {result['checks']} real editor script diagnostic checks")


if __name__ == "__main__":
    main()
