"""Twelve deterministic edit/recovery tasks over real HTTP MCP and Godot.

This is a native-tool regression replay, NOT an AI-agent or competitor score.
File bytes and a separate runtime process are the outcome oracles. Set GODOT_EXE.
"""

import hashlib
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import tempfile
import time
import urllib.request

REPO_ROOT = Path(__file__).resolve().parents[2]
ARTIFACTS = REPO_ROOT / "test/integration/.tmp_script_edit_replay"
DEFAULT_GODOT = Path(r"C:\Users\26901\Downloads\Godot_v4.7-stable_win64.exe\Godot_v4.7-stable_win64_console.exe")
SOURCE = 'extends RefCounted\n# 保留设计师注释\nvar speed: int = 100\nfunc velocity_for(axis: Vector2) -> Vector2:\n\treturn axis * speed\n'
BUFFER_PLUGIN = '''@tool
extends EditorPlugin
var code_edit: CodeEdit
func _enter_tree() -> void:
    call_deferred("_prepare")
func _prepare() -> void:
    var fs: EditorFileSystem = EditorInterface.get_resource_filesystem()
    while fs.is_scanning():
        await get_tree().process_frame
    EditorInterface.edit_script(load("res://buffer.gd"))
    for index: int in range(60):
        await get_tree().process_frame
        var current: ScriptEditorBase = EditorInterface.get_script_editor().get_current_editor()
        if current != null and current.get_base_editor() is CodeEdit:
            code_edit = current.get_base_editor()
            break
    if code_edit == null:
        return
    code_edit.text += "# unsaved human work\\n"
    await get_tree().process_frame
    var script_editor: ScriptEditor = EditorInterface.get_script_editor()
    var supported: bool = script_editor.has_method("get_unsaved_files") or script_editor.has_method("get_unsaved_scripts")
    _record("res://buffer_ready.json", {"supported": supported, "text": code_edit.text})
func _process(_delta: float) -> void:
    if code_edit != null and FileAccess.file_exists("res://check_buffer"):
        DirAccess.remove_absolute("res://check_buffer")
        _record("res://buffer_after.json", {"text": code_edit.text})
func _record(path: String, data: Dictionary) -> void:
    var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
    file.store_string(JSON.stringify(data))
    file.close()
'''
RUNTIME_ORACLE = '''extends SceneTree
func _initialize() -> void:
    var failures: Array[String] = []
    var player: RefCounted = load("res://movement.gd").new()
    if player.velocity_for(Vector2(1, 0)) != Vector2(250, 0):
        failures.append("movement speed is not 250 at runtime")
    var input: RefCounted = load("res://input.gd").new()
    if input.action_name() != "move_right":
        failures.append("input action was not updated")
    var save: RefCounted = load("res://save.gd").new()
    if save.snapshot() != {"score": 0, "health": 3}:
        failures.append("save extension broke existing score or missing health")
    var repaired: RefCounted = load("res://repair.gd").new()
    if repaired.speed != 400:
        failures.append("repair did not produce executable script")
    var output: FileAccess = FileAccess.open("res://runtime_result.json", FileAccess.WRITE)
    output.store_string(JSON.stringify({"checks": 4, "failures": failures}))
    output.close()
    quit(0 if failures.is_empty() else 1)
'''


def main() -> None:
    godot = Path(os.environ.get("GODOT_EXE", str(DEFAULT_GODOT))).resolve()
    if not godot.is_file():
        raise FileNotFoundError(f"Set GODOT_EXE to a Godot executable: {godot}")
    version = subprocess.check_output([str(godot), "--version"], text=True, encoding="utf-8", timeout=10,
                                      creationflags=subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0).strip()
    ARTIFACTS.mkdir(exist_ok=True)
    (ARTIFACTS / ".gdignore").touch()
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        port = probe.getsockname()[1]
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    evidence: list[dict] = []
    cases: list[dict] = []
    request_id = 0

    def rpc(method: str, params: dict, timeout: float = 15) -> dict:
        nonlocal request_id
        request_id += 1
        body = {"jsonrpc": "2.0", "id": request_id, "method": method, "params": params}
        request = urllib.request.Request(f"http://127.0.0.1:{port}/mcp", data=json.dumps(body).encode(),
                                         headers={"Content-Type": "application/json"})
        with opener.open(request, timeout=timeout) as response:
            result = json.load(response)
        assert "error" not in result, result
        return result["result"]

    def call(name: str, arguments: dict, error: str | None = None) -> dict:
        result = rpc("tools/call", {"name": name, "arguments": arguments})
        payload = result.get("structuredContent")
        if payload is None:
            payload = json.loads(result["content"][0]["text"])
        evidence.append({"tool": name, "arguments": arguments, "result": payload})
        assert bool(result.get("isError")) == (error is not None), payload
        if error is not None:
            assert payload.get("error_code") == error, payload
        return payload

    def wait_file(path: Path) -> dict:
        deadline = time.monotonic() + 12
        while time.monotonic() < deadline:
            if path.is_file():
                try:
                    return json.loads(path.read_text(encoding="utf-8"))
                except json.JSONDecodeError:
                    pass
            time.sleep(0.05)
        raise AssertionError(f"Editor fixture did not produce {path.name}")

    with tempfile.TemporaryDirectory(prefix="editor_", dir=ARTIFACTS) as directory:
        project = Path(directory)
        shutil.copytree(REPO_ROOT / "addons/godot_mcp", project / "addons/godot_mcp")
        fixture = project / "addons/edit_test"
        fixture.mkdir()
        (fixture / "plugin.cfg").write_text('[plugin]\nname="Edit Test"\ndescription="Test"\nauthor="Test"\nversion="1"\nscript="plugin.gd"\n', encoding="utf-8")
        (fixture / "plugin.gd").write_text(BUFFER_PLUGIN, encoding="utf-8")
        (project / "buffer.gd").write_bytes(SOURCE.encode("utf-8"))
        (project / "project.godot").write_text(
            'config_version=5\n[application]\nconfig/name="Script Edit Replay"\n'
            '[rendering]\nrenderer/rendering_method="gl_compatibility"\n'
            '[editor_plugins]\nenabled=PackedStringArray("res://addons/godot_mcp/plugin.cfg", "res://addons/edit_test/plugin.cfg")\n', encoding="utf-8")
        env = os.environ.copy()
        for key in ("APPDATA", "LOCALAPPDATA", "XDG_DATA_HOME", "XDG_CONFIG_HOME"):
            destination = project / key.lower()
            destination.mkdir()
            env[key] = str(destination)
        flags = subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0

        def seed(name: str, content: str = SOURCE) -> str:
            (project / f"{name}.gd").write_bytes(content.encode("utf-8"))
            return f"res://{name}.gd"

        def assert_file(path: str, expected: str) -> None:
            assert (project / path.removeprefix("res://")).read_bytes() == expected.encode("utf-8"), path

        def edit(path: str, **arguments: object) -> dict:
            return call("modify_script", {"script_path": path, **arguments})

        def task(case_id: str, action) -> None:
            started = time.monotonic()
            first_call = len(evidence)
            try:
                status = action() or "passed"
                cases.append({"id": case_id, "status": status, "seconds": round(time.monotonic() - started, 4),
                              "tool_calls": len(evidence) - first_call})
            except Exception as exc:
                cases.append({"id": case_id, "status": "failed", "error": str(exc)})

        log_path = ARTIFACTS / "editor.log"
        with log_path.open("w", encoding="utf-8") as log:
            process = subprocess.Popen([str(godot), "--headless", "--editor", "--path", str(project),
                                        "--log-file", str(ARTIFACTS / "engine.log"), "--", "--mcp-server", f"--mcp-port={port}"],
                                       stdout=log, stderr=subprocess.STDOUT, env=env, creationflags=flags)
            try:
                deadline = time.monotonic() + 45
                while True:
                    try:
                        rpc("tools/list", {}, timeout=1)
                        break
                    except Exception:
                        if process.poll() is not None or time.monotonic() > deadline:
                            raise AssertionError(f"Server startup failed: {log_path.read_text(encoding='utf-8')}")
                        time.sleep(0.2)
                buffer_before = wait_file(project / "buffer_ready.json")

                def movement() -> None:
                    path = seed("movement")
                    read = call("read_script", {"script_path": path})
                    assert read["content_hash"] == hashlib.sha256(SOURCE.encode()).hexdigest()
                    result = edit(path, old_text="var speed: int = 100", content="var speed: int = 250", expected_content_hash=read["content_hash"])
                    assert result["validation_status"] == "passed", result
                    assert_file(path, SOURCE.replace("100", "250"))
                task("edit-movement-preserve-comments", movement)

                def input_action() -> None:
                    source = 'extends RefCounted\nfunc action_name() -> String:\n\treturn "ui_right"\n'
                    path = seed("input", source)
                    edit(path, old_text='"ui_right"', content='"move_right"')
                    assert_file(path, source.replace("ui_right", "move_right"))
                task("edit-input-action", input_action)

                def save_extension() -> None:
                    source = 'extends RefCounted\nfunc snapshot() -> Dictionary:\n\treturn {"score": 0}\n'
                    path = seed("save", source)
                    edit(path, old_text='{"score": 0}', content='{"score": 0, "health": 3}')
                    assert_file(path, source.replace('{"score": 0}', '{"score": 0, "health": 3}'))
                task("extend-save-preserve-score", save_extension)

                def remove_debug() -> None:
                    block = 'func debug_value() -> void:\n\tprint("debug")\n'
                    path = seed("debug", SOURCE + block)
                    edit(path, old_text=block, content="")
                    assert_file(path, SOURCE)
                task("remove-obsolete-function", remove_debug)

                def stale_disk() -> None:
                    path = seed("manual")
                    read = call("read_script", {"script_path": path})
                    seed("manual", SOURCE.replace("100", "101"))
                    call("modify_script", {"script_path": path, "content": SOURCE, "expected_content_hash": read["content_hash"]}, "content_conflict")
                    assert_file(path, SOURCE.replace("100", "101"))
                task("preserve-newer-disk-edit", stale_disk)

                def unsaved_buffer() -> str | None:
                    path = "res://buffer.gd"
                    read = call("read_script", {"script_path": path})
                    if not buffer_before["supported"]:
                        return "unsupported"
                    call("modify_script", {"script_path": path, "content": SOURCE.replace("100", "300"), "expected_content_hash": read["content_hash"]}, "unsaved_script_changes")
                    assert_file(path, SOURCE)
                    (project / "check_buffer").touch()
                    assert wait_file(project / "buffer_after.json")["text"] == buffer_before["text"]
                task("preserve-unsaved-editor-work", unsaved_buffer)

                def ambiguous() -> None:
                    source = SOURCE + "# speed\n"
                    path = seed("ambiguous", source)
                    call("modify_script", {"script_path": path, "old_text": "speed", "content": "run_speed"}, "ambiguous_text")
                    assert_file(path, source)
                task("reject-ambiguous-edit", ambiguous)

                def invalid_line() -> None:
                    path = seed("line")
                    call("modify_script", {"script_path": path, "line_number": 999, "content": "var speed: int = 1"}, "line_out_of_range")
                    assert_file(path, SOURCE)
                task("reject-invalid-line-without-truncation", invalid_line)

                def retry_conflict() -> None:
                    path = seed("retry")
                    old = call("read_script", {"script_path": path})
                    manual = SOURCE + "var health: int = 7\n"
                    seed("retry", manual)
                    call("modify_script", {"script_path": path, "content": SOURCE, "expected_content_hash": old["content_hash"]}, "content_conflict")
                    latest = call("read_script", {"script_path": path})
                    assert latest["content"] == manual, latest
                    result = edit(path, old_text="100", content="200", expected_content_hash=latest["content_hash"])
                    assert result["content_hash"] == hashlib.sha256(manual.replace("100", "200").encode()).hexdigest()
                    assert_file(path, manual.replace("100", "200"))
                task("recover-stale-edit-by-rereading", retry_conflict)

                def repair() -> None:
                    path = seed("repair")
                    broken = edit(path, old_text="100", content="(")
                    assert broken["status"] == "success" and broken["validation_status"] == "failed", broken
                    assert broken["diagnostics"], broken
                    fixed = edit(path, old_text="var speed: int = (", content="var speed: int = 400", expected_content_hash=broken["content_hash"])
                    assert fixed["validation_status"] == "passed", fixed
                    assert_file(path, SOURCE.replace("100", "400"))
                task("recover-compiler-error", repair)

                def missing_retry() -> None:
                    path = seed("missing")
                    call("modify_script", {"script_path": path, "old_text": "var speed: int = 300", "content": "var speed: int = 200"}, "text_not_found")
                    assert_file(path, SOURCE)
                    latest = call("read_script", {"script_path": path})
                    edit(path, old_text="100", content="200", expected_content_hash=latest["content_hash"])
                    assert_file(path, SOURCE.replace("100", "200"))
                task("recover-missing-anchor", missing_retry)

                def legacy_crlf() -> None:
                    source = SOURCE.replace("\n", "\r\n")
                    path = seed("legacy", source)
                    result = edit(path, line_number=3, content="var speed: int = 50")
                    assert_file(path, source.replace("100", "50"))
                    edit(path, content=SOURCE, expected_content_hash=result["content_hash"])
                    assert_file(path, SOURCE)
                task("retain-legacy-edit-and-crlf", legacy_crlf)
            finally:
                process.terminate()
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)
                report = {"mode": "deterministic_native_tool_replay", "suite_version": 1, "status": "incomplete",
                          "godot_version": version, "suite_digest": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                          "agent_success_rate": None, "competitor_results": None, "cases": cases,
                          "passed": sum(case["status"] == "passed" for case in cases),
                          "failed": sum(case["status"] == "failed" for case in cases),
                          "unsupported": sum(case["status"] == "unsupported" for case in cases)}
                (ARTIFACTS / "report.json").write_text(json.dumps(report, indent=2), encoding="utf-8")
                (ARTIFACTS / "http_evidence.json").write_text(json.dumps(evidence, indent=2, ensure_ascii=False), encoding="utf-8")
        assert len(cases) == 12 and report["failed"] == 0, report
        (project / "runtime_oracle.gd").write_text(RUNTIME_ORACLE, encoding="utf-8")
        runtime = subprocess.run([str(godot), "--headless", "--path", str(project), "--log-file", str(ARTIFACTS / "runtime.log"),
                                  "-s", "res://runtime_oracle.gd"], env=env, creationflags=flags,
                                 stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, encoding="utf-8", errors="replace", timeout=30)
        result = wait_file(project / "runtime_result.json")
        assert runtime.returncode == 0 and not result["failures"], (result, runtime.stdout)
        report["runtime_oracle"] = result
        report["status"] = "passed" if report["unsupported"] == 0 else "passed_with_unsupported_cases"
        (ARTIFACTS / "report.json").write_text(json.dumps(report, indent=2), encoding="utf-8")
        print(f"PASS: {report['passed']}/12 edit tasks, {report['unsupported']} unsupported; 4 independent runtime checks; {len(evidence)} HTTP calls")


if __name__ == "__main__":
    main()
