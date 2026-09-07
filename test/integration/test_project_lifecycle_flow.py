"""Verify lifecycle status through HTTP in an isolated editor and runtime.

Set GODOT_EXE to the editor executable. Uses a temporary project, separate user
data, and an ephemeral loopback port; never changes the active editor project.
"""

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
ARTIFACTS = REPO_ROOT / "test" / "integration" / ".tmp_adoption_runtime"
DEFAULT_GODOT = Path(
    r"C:\Users\26901\Downloads\Godot_v4.7-stable_win64.exe\Godot_v4.7-stable_win64_console.exe"
)


def main() -> None:
    godot = Path(os.environ.get("GODOT_EXE", str(DEFAULT_GODOT)))
    if not godot.is_file():
        raise FileNotFoundError(f"Set GODOT_EXE to the Godot editor executable: {godot}")
    ARTIFACTS.mkdir(exist_ok=True)
    (ARTIFACTS / ".gdignore").touch()
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        port = probe.getsockname()[1]
    url = f"http://127.0.0.1:{port}/mcp"
    evidence: list[dict] = []
    request_id = 0
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))

    def rpc(method: str, params: dict | None = None, timeout: float = 20) -> dict:
        nonlocal request_id
        request_id += 1
        data = json.dumps({"jsonrpc": "2.0", "id": request_id, "method": method,
                           "params": params or {}}).encode()
        request = urllib.request.Request(url, data=data, headers={"Content-Type": "application/json"})
        with opener.open(request, timeout=timeout) as response:
            result = json.load(response)
        if "error" in result:
            raise AssertionError(result)
        return result["result"]

    def call(name: str, arguments: dict | None = None, *, expect_error: bool = False) -> dict:
        result = rpc("tools/call", {"name": name, "arguments": arguments or {}})
        payload = result.get("structuredContent")
        if payload is None:
            payload = json.loads(result["content"][0]["text"])
        evidence.append({"tool": name, "arguments": arguments or {}, "result": payload})
        if bool(result.get("isError")) != expect_error:
            raise AssertionError(f"Unexpected error state from {name}: {payload}")
        return payload

    def check_state(result: dict, expected: str) -> None:
        assert result.get("game_status", {}).get("state") == expected, result

    with tempfile.TemporaryDirectory(prefix="editor_", dir=ARTIFACTS) as directory:
        project = Path(directory)
        shutil.copytree(REPO_ROOT / "addons/godot_mcp", project / "addons/godot_mcp")
        (project / "main.tscn").write_text('[gd_scene format=3]\n[node name="Main" type="Node"]\n', encoding="utf-8")
        child_log = (ARTIFACTS / "runtime.log").as_posix()
        main_args = json.dumps(f'--headless --log-file "{child_log}"')
        (project / "project.godot").write_text(
            'config_version=5\n[application]\nconfig/name="Lifecycle HTTP Test"\n'
            'run/main_scene="res://main.tscn"\n'
            '[editor]\nrun/main_run_args=' + main_args + '\n'
            '[rendering]\nrenderer/rendering_method="gl_compatibility"\n'
            '[editor_plugins]\nenabled=PackedStringArray("res://addons/godot_mcp/plugin.cfg")\n',
            encoding="utf-8",
        )
        environment = os.environ.copy()
        for variable in ("APPDATA", "LOCALAPPDATA", "XDG_DATA_HOME", "XDG_CONFIG_HOME"):
            destination = project / variable.lower()
            destination.mkdir()
            environment[variable] = str(destination)
        output_path = ARTIFACTS / "http_editor.log"
        with output_path.open("w", encoding="utf-8") as output:
            process = subprocess.Popen(
                [str(godot), "--headless", "--editor", "--path", str(project),
                 "--log-file", str(ARTIFACTS / "http_engine.log"), "--",
                 "--mcp-server", f"--mcp-port={port}"],
                stdout=output, stderr=subprocess.STDOUT, env=environment,
                creationflags=subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0,
            )
            try:
                deadline = time.monotonic() + 45
                while True:
                    try:
                        rpc("tools/list", timeout=1)
                        break
                    except Exception:
                        if process.poll() is not None or time.monotonic() >= deadline:
                            raise AssertionError(f"Isolated server failed to start: {output_path.read_text(encoding='utf-8')}")
                        time.sleep(0.2)
                call("enable_tools", {"tools": ["remove_runtime_probe", "install_runtime_probe",
                                                   "request_debug_break", "get_debugger_sessions"]})
                check_state(call("stop_project", {"allow_window": True}), "stopped")
                started = call("run_project", {"scene_path": "res://main.tscn", "allow_window": True})
                check_state(started, "live")
                assert started["status"] == "success" and started["probe_ready"], started
                reused = call("run_project", {"allow_window": True, "timeout_ms": 0})
                check_state(reused, "live")
                assert reused["already_running"] and reused["session_active"], reused
                call("run_project", {"scene_path": "res://missing.tscn", "allow_window": True}, expect_error=True)
                check_state(call("run_project", {"allow_window": True}), "live")

                call("request_debug_break")
                deadline = time.monotonic() + 5
                while True:
                    sessions = call("get_debugger_sessions")
                    if any(session.get("active") and session.get("breaked") for session in sessions["sessions"]):
                        break
                    if time.monotonic() > deadline:
                        raise AssertionError(f"Debugger did not pause: {sessions}")
                    time.sleep(0.1)
                check_state(call("run_project", {"allow_window": True}, expect_error=True), "break")
                check_state(call("stop_project", {"allow_window": True}), "stopped")
                check_state(call("stop_project", {"allow_window": True}), "stopped")

                call("remove_runtime_probe")
                without_probe = call("run_project", {"scene_path": "res://main.tscn", "allow_window": True})
                check_state(without_probe, "no_probe")
                assert without_probe["status"] == "success" and not without_probe["probe_ready"], without_probe
                check_state(call("stop_project", {"allow_window": True}), "stopped")
                call("install_runtime_probe", {"node_name": "CustomLifecycleProbe"})
                check_state(call("run_project", {"scene_path": "res://main.tscn", "allow_window": True}), "live")
                check_state(call("stop_project", {"allow_window": True}), "stopped")
            finally:
                (ARTIFACTS / "http_evidence.json").write_text(json.dumps(evidence, indent=2), encoding="utf-8")
                if process.poll() is None:
                    try:
                        call("stop_project", {"allow_window": True, "timeout_ms": 2000})
                    except Exception:
                        pass
                    process.terminate()
                    try:
                        process.wait(timeout=10)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait(timeout=5)
    print(f"PASS: {len(evidence)} isolated HTTP lifecycle calls, including real probe readiness, breakpoint state, and shutdown")


if __name__ == "__main__":
    main()
