"""Stress game S01 acceptance: movement, walls, dash, cooldown.

Runs against the TRACKED stress_game project (content built once via MCP;
see stress_game/DESIGN.md). Verifies the room's four observable behaviors
with runtime expressions only — no content mutation, so the repo tree stays
clean in CI. Writes the acceptance record to user:// always, and to the
tracked data/acceptance/s01.json when STRESS_WRITE_ACCEPTANCE=1 (deliberate
local evidence refresh).

Usage:
  GODOT_EXE=... MCP_PORT=9192 python test/integration/test_stress_s01_flow.py
"""

import hashlib
import json
import os
import shutil
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
GODOT_EXE = Path(os.environ.get("GODOT_EXE", r"C:\kaifa\Godot_v4.6.3-stable_win64_console.exe"))
MCP_PORT = os.environ.get("MCP_PORT", "9192")
MCP_URL = f"http://127.0.0.1:{MCP_PORT}/mcp"
GAME = REPO_ROOT / "stress_game"
SCENE = "res://scenes/room_movement.tscn"
SCRIPT = "res://scripts/player_movement.gd"

TOOLS = [
    "open_scene", "get_scene_structure", "read_script", "validate_script",
    "list_project_input_actions", "install_runtime_probe", "run_project",
    "stop_project", "simulate_runtime_input_action", "await_runtime_condition",
    "evaluate_runtime_expression", "get_runtime_screenshot", "get_editor_logs",
    "get_debugger_sessions", "get_runtime_info", "enable_tools",
]

_request_id = 0


def rpc_call(method: str, params: dict | None = None, timeout: float = 240.0) -> dict:
    global _request_id
    _request_id += 1
    payload = {"jsonrpc": "2.0", "id": _request_id, "method": method, "params": params or {}}
    request = urllib.request.Request(
        MCP_URL, data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"}, method="POST")
    body = ""
    for attempt in range(3):
        try:
            with urllib.request.urlopen(request, timeout=timeout) as response:
                body = response.read().decode("utf-8")
            if body.strip():
                return json.loads(body)
        except Exception:
            if attempt == 2:
                raise
        time.sleep(2.0)
    raise AssertionError(f"Empty MCP response: {method}")


def tool_call(name: str, arguments: dict | None = None, timeout: float = 240.0) -> dict:
    response = rpc_call("tools/call", {"name": name, "arguments": arguments or {}}, timeout=timeout)
    result = response.get("result", {})
    if result.get("isError"):
        raise AssertionError(f"Tool {name} failed: {result['content'][0]['text']}")
    if result.get("structuredContent"):
        return result["structuredContent"]
    text = result.get("content", [{}])[0].get("text", "")
    try:
        return json.loads(text)
    except (json.JSONDecodeError, TypeError):
        return {"raw": text}


def wait_for_server(timeout_seconds: float = 120.0) -> None:
    deadline = time.time() + timeout_seconds
    last: Exception | None = None
    while time.time() < deadline:
        try:
            if "result" in rpc_call("tools/list", timeout=15.0):
                return
        except Exception as exc:  # noqa: BLE001
            last = exc
        time.sleep(1.0)
    raise AssertionError(f"MCP server did not answer on {MCP_URL}: {last}")


def wait_runtime_ready(timeout_seconds: float = 20.0) -> None:
    deadline = time.time() + timeout_seconds
    while time.time() < deadline:
        sessions = tool_call("get_debugger_sessions", timeout=15.0)
        if sessions.get("count", 0) > 0 and any(s.get("active") for s in sessions.get("sessions", [])):
            info = tool_call("get_runtime_info", {"timeout_ms": 2000}, timeout=15.0)
            if info.get("node_count", 0) > 0:
                return
        time.sleep(0.5)
    raise AssertionError("Runtime never became observable")


def sync_addons() -> None:
    dest = GAME / "addons"
    marker = dest / "godot_mcp" / "plugin.cfg"
    if marker.exists():
        return
    if dest.exists():
        shutil.rmtree(dest, ignore_errors=True)
    shutil.copytree(REPO_ROOT / "addons" / "godot_mcp", dest / "godot_mcp")


def ev(expression: str):
    return tool_call("evaluate_runtime_expression", {"expression": expression}).get("value")


def check(label: str, condition: bool, detail: str = "") -> None:
    if not condition:
        raise AssertionError(f"[FAIL] {label}" + (f" — {detail}" if detail else ""))
    print(f"[ok] {label}", flush=True)


def main() -> int:
    sync_addons()
    process = subprocess.Popen(
        [str(GODOT_EXE), "--editor", "--headless", "--path", str(GAME),
         "--", "--mcp-server", f"--mcp-port={MCP_PORT}"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, cwd=str(REPO_ROOT))
    evidence: dict = {"scenario": "S01", "scene": SCENE, "checks": {}}
    try:
        wait_for_server()
        tool_call("enable_tools", {"tools": TOOLS})

        # --- static contract: the tracked room is what the acceptance assumes ---
        # Boot race: a fresh editor may answer MCP before its main scene opens.
        tool_call("open_scene", {"scene_path": SCENE, "allow_ui_focus": True})
        structure = json.dumps(tool_call("get_scene_structure"))
        for expected in ("Player", "WallLeft", "WallRight"):
            check(f"scene contains {expected}", expected in structure)
        source = tool_call("read_script", {"script_path": SCRIPT})
        content = str(source.get("content", ""))
        check("script defines SPEED/DASH constants",
              "SPEED" in content and "DASH_SPEED" in content)
        evidence["script_sha256"] = hashlib.sha256(content.encode()).hexdigest()
        validation = tool_call("validate_script", {"script_path": SCRIPT})
        check("script validates clean", validation.get("valid") is True)
        actions = {a["action_name"] for a in tool_call("list_project_input_actions").get("actions", [])}
        check("input actions present", {"move_left", "move_right", "dash"} <= actions, str(actions))

        # --- runtime behavior ---
        tool_call("install_runtime_probe", {"node_name": "MCPRuntimeProbe", "persistent": True})
        tool_call("run_project", {"scene_path": SCENE, "allow_window": True})
        wait_runtime_ready()

        # 1) movement: hold right, must advance meaningfully and stay off the wall.
        start_x = float(ev("get_node('Player').position.x"))
        tool_call("simulate_runtime_input_action", {"action_name": "move_right", "pressed": True})
        moved = tool_call("await_runtime_condition", {
            "expression": "get_node('Player').position.x >= %f" % (start_x + 120.0),
            "timeout_ms": 6000})
        moved_x = float(ev("get_node('Player').position.x"))
        tool_call("simulate_runtime_input_action", {"action_name": "move_right", "pressed": False})
        check("movement advances under held key", bool(moved.get("condition_met")),
              json.dumps(moved)[:200])
        evidence["checks"]["movement"] = {"start_x": start_x, "observed_x": moved_x}

        # 2) wall: keep holding right; must stop at the inner face (560-16=544).
        tool_call("simulate_runtime_input_action", {"action_name": "move_right", "pressed": True})
        blocked = tool_call("await_runtime_condition", {
            "expression": "get_node('Player').position.x >= 543.5", "timeout_ms": 8000})
        tool_call("simulate_runtime_input_action", {"action_name": "move_right", "pressed": False})
        time.sleep(0.6)
        settled = float(ev("get_node('Player').position.x"))
        check("wall blocks at inner face", bool(blocked.get("condition_met")) and settled <= 544.5,
              f"settled={settled}")
        evidence["checks"]["wall"] = {"settled_x": settled}

        # 3) dash: walk left off the wall, then dash right — distance in a fixed
        #    window must far exceed walking distance.
        tool_call("simulate_runtime_input_action", {"action_name": "move_left", "pressed": True})
        tool_call("await_runtime_condition", {
            "expression": "get_node('Player').position.x <= 400.0", "timeout_ms": 6000})
        tool_call("simulate_runtime_input_action", {"action_name": "move_left", "pressed": False})
        dash_start = float(ev("get_node('Player').position.x"))
        tool_call("simulate_runtime_input_action", {"action_name": "move_right", "pressed": True})
        tool_call("simulate_runtime_input_action", {"action_name": "dash", "pressed": True})
        tool_call("simulate_runtime_input_action", {"action_name": "dash", "pressed": False})
        dashed = tool_call("await_runtime_condition", {
            "expression": "get_node('Player').is_dashing()", "timeout_ms": 3000})
        tool_call("await_runtime_condition", {
            "expression": "not get_node('Player').is_dashing()", "timeout_ms": 3000})
        tool_call("simulate_runtime_input_action", {"action_name": "move_right", "pressed": False})
        dash_end = float(ev("get_node('Player').position.x"))
        dash_distance = dash_end - dash_start
        check("dash covers far more than walking (12f x 640px/s ~= 128px vs ~55px walking)", dash_distance >= 120.0,
              f"dash_distance={dash_distance}")
        check("dash state was observed live", bool(dashed.get("condition_met")))
        evidence["checks"]["dash"] = {"start_x": dash_start, "end_x": dash_end,
                                      "distance": dash_distance}

        # 4) cooldown: right after the dash, an immediate second dash must not
        #    trigger (cooldown > 0 observed, distance stays walking-level).
        cooldown = int(ev("get_node('Player').dash_cooldown_remaining()"))
        check("cooldown is active after dash", cooldown > 0, f"cooldown={cooldown}")
        cd_start = float(ev("get_node('Player').position.x"))
        tool_call("simulate_runtime_input_action", {"action_name": "move_right", "pressed": True})
        tool_call("simulate_runtime_input_action", {"action_name": "dash", "pressed": True})
        tool_call("simulate_runtime_input_action", {"action_name": "dash", "pressed": False})
        time.sleep(0.3)
        cd_distance = float(ev("get_node('Player').position.x")) - cd_start
        tool_call("simulate_runtime_input_action", {"action_name": "move_right", "pressed": False})
        check("second dash suppressed during cooldown", cd_distance <= 90.0,
              f"distance={cd_distance}")
        evidence["checks"]["cooldown"] = {"cooldown_frames": cooldown, "distance": cd_distance}

        shot = tool_call("get_runtime_screenshot",
                         {"save_path": "user://stress_s01.png", "format": "png"})
        check("screenshot captured", shot.get("status") == "success")
        logs = tool_call("get_editor_logs", {"source": "runtime"})
        check("no script errors during acceptance", "SCRIPT ERROR" not in json.dumps(logs))
        tool_call("stop_project", {"allow_window": True})

        evidence["verdict"] = "passed"
        record_local = GAME / "data" / "acceptance" / "s01.json"
        record_user = os.path.expanduser("~/AppData/Roaming/Godot/app_userdata/StressGame/stress_s01_acceptance.json")
        Path(record_user).parent.mkdir(parents=True, exist_ok=True)
        Path(record_user).write_text(json.dumps(evidence, indent=2), encoding="utf-8")
        if os.environ.get("STRESS_WRITE_ACCEPTANCE") == "1":
            record_local.parent.mkdir(parents=True, exist_ok=True)
            record_local.write_text(json.dumps(evidence, indent=2), encoding="utf-8")
            print(f"[ok] acceptance record refreshed at {record_local}")
        print("\nS01 ACCEPTANCE: ALL CHECKS PASSED")
        print(f"dash distance {dash_distance:.0f}px vs walking <90px; wall stop at {settled:.1f}")
        return 0
    finally:
        process.terminate()
        try:
            process.wait(timeout=15)
        except subprocess.TimeoutExpired:
            process.kill()


if __name__ == "__main__":
    sys.exit(main())
