"""First playable slice — the G0/M0.4 making smoke, atomic tools only.

Proves the thing that actually matters for "can this make a game": using
ONLY atomic MCP tool calls (no goal engine, no templates), in a blank
scratch project, an agent can

  create  : input actions + scene (player body/visual/collision + walls)
            + movement script, all validated and saved
  run     : launch the game, install the runtime probe, hold a key and
            observe real movement, and observe the wall actually blocking
  iterate : change SPEED through the recoverable change-set loop
            (read hash -> dry run -> commit -> validate -> re-run) and
            measure the effect of the parameter change
  persist : terminate the editor, boot a fresh one, and confirm the
            project identity, scene, script, input actions and main scene

Every step is an MCP call over HTTP against a real headless editor — this
is the "trustworthy daily making loop" (plan M1.1) exercised end to end.

Usage:
  GODOT_EXE=... MCP_PORT=9188 python test/integration/test_first_playable_flow.py
"""

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
MCP_PORT = os.environ.get("MCP_PORT", "9188")
MCP_URL = f"http://127.0.0.1:{MCP_PORT}/mcp"
SCRATCH = REPO_ROOT / "tmp_first_playable_project"
SCENE = "res://scenes/arena.tscn"
SCRIPT = "res://scripts/player_controller.gd"

PROJECT_GODOT = """config_version=5

[application]

config/name="FirstPlayableScratch"

[editor_plugins]

enabled=PackedStringArray("res://addons/godot_mcp/plugin.cfg")
"""

PLAYER_SCRIPT = """extends CharacterBody2D

const SPEED := 200.0

func _physics_process(_delta: float) -> void:
	var direction: float = Input.get_axis("move_left", "move_right")
	velocity = Vector2(direction * SPEED, 0.0)
	move_and_slide()
"""

ATOMIC_TOOLS = [
    "create_scene", "create_node", "set_node_subresource", "batch_scene_node_edits",
    "create_script", "read_script", "modify_script", "validate_script",
    "apply_change_set", "save_scene", "open_scene", "get_scene_structure",
    "set_project_setting", "get_project_settings", "upsert_project_input_action",
    "list_project_input_actions", "run_project", "stop_project",
    "install_runtime_probe", "simulate_runtime_input_action",
    "await_runtime_condition", "evaluate_runtime_expression",
    "get_runtime_screenshot", "get_editor_logs",
    "get_debugger_sessions", "get_runtime_info",
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


def check(label: str, condition: bool, detail: str = "") -> None:
    if not condition:
        raise AssertionError(f"[FAIL] {label}" + (f" — {detail}" if detail else ""))
    print(f"[ok] {label}", flush=True)


def boot_editor() -> subprocess.Popen:
    return subprocess.Popen(
        [str(GODOT_EXE), "--editor", "--headless", "--path", str(SCRATCH),
         "--", "--mcp-server", f"--mcp-port={MCP_PORT}"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, cwd=str(REPO_ROOT))


def build_scratch_project() -> None:
    if SCRATCH.exists():
        shutil.rmtree(SCRATCH, ignore_errors=True)
    (SCRATCH / "addons").mkdir(parents=True)
    shutil.copytree(REPO_ROOT / "addons" / "godot_mcp", SCRATCH / "addons" / "godot_mcp")
    (SCRATCH / "project.godot").write_text(PROJECT_GODOT, encoding="utf-8", newline="\n")


def player_x() -> float:
    result = tool_call("evaluate_runtime_expression", {"expression": "get_node('Player').position.x"})
    return float(result.get("value", 0.0))


def wait_runtime_ready(timeout_seconds: float = 20.0) -> None:
    """Mirror the proven probe-flow pattern: the debugger session must be
    active and the runtime tree visible before any input is simulated."""
    deadline = time.time() + timeout_seconds
    while time.time() < deadline:
        sessions = tool_call("get_debugger_sessions", timeout=15.0)
        if sessions.get("count", 0) > 0 and any(s.get("active") for s in sessions.get("sessions", [])):
            info = tool_call("get_runtime_info", {"timeout_ms": 2000}, timeout=15.0)
            if info.get("node_count", 0) > 0:
                return
        time.sleep(0.5)
    raise AssertionError("Runtime never became observable (no active debugger session)")


def hold_key_and_measure(action: str, target_x: float) -> dict:
    """Press an action, wait until the player crosses target_x, release.

    Returns the await receipt (elapsed_ms) so callers can compare how long
    the same distance took under different parameters.
    """
    tool_call("simulate_runtime_input_action", {"action_name": action, "pressed": True})
    receipt = tool_call("await_runtime_condition", {
        "expression": "get_node('Player').position.x >= %f" % target_x,
        "timeout_ms": 8000})
    tool_call("simulate_runtime_input_action", {"action_name": action, "pressed": False})
    check(f"player reached x>={target_x} under held {action}",
          bool(receipt.get("condition_met")), json.dumps(receipt)[:200])
    return receipt


def main() -> int:
    if not GODOT_EXE.exists():
        print(f"GODOT_EXE not found: {GODOT_EXE}", file=sys.stderr)
        return 2
    build_scratch_project()
    process = boot_editor()
    try:
        # ---------------- Phase 1: create (atomic tools only) ----------------
        wait_for_server()
        info = tool_call("get_project_info")
        check("connected to the scratch project",
              info.get("project_name") == "FirstPlayableScratch", json.dumps(info)[:200])

        tool_call("enable_tools", {"tools": ATOMIC_TOOLS})
        print("[ok] atomic toolset enabled (%d tools)" % len(ATOMIC_TOOLS))

        tool_call("upsert_project_input_action", {
            "action_name": "move_left",
            "events": [{"type": "key", "physical_keycode": 65}], "erase_existing": True})
        tool_call("upsert_project_input_action", {
            "action_name": "move_right",
            "events": [{"type": "key", "physical_keycode": 68}], "erase_existing": True})
        actions = {a["action_name"] for a in tool_call("list_project_input_actions").get("actions", [])}
        check("input actions move_left/move_right registered",
              {"move_left", "move_right"} <= actions, str(actions))

        tool_call("create_scene", {"scene_path": SCENE, "root_node_type": "Node2D"})
        tool_call("open_scene", {"scene_path": SCENE, "allow_ui_focus": True})
        for parent, ntype, nname in [
            ("", "CharacterBody2D", "Player"),
            ("Player", "ColorRect", "Visual"),
            ("Player", "CollisionShape2D", "Shape"),
            ("", "StaticBody2D", "WallLeft"),
            ("WallLeft", "CollisionShape2D", "Shape"),
            ("", "StaticBody2D", "WallRight"),
            ("WallRight", "CollisionShape2D", "Shape"),
        ]:
            tool_call("create_node", {"parent_path": parent, "node_type": ntype, "node_name": nname})
        tool_call("set_node_subresource", {
            "node_path": "Player/Shape", "property_name": "shape",
            "resource_type": "RectangleShape2D", "properties": {"size": [32, 32]}})
        for wall in ("WallLeft", "WallRight"):
            tool_call("set_node_subresource", {
                "node_path": f"{wall}/Shape", "property_name": "shape",
                "resource_type": "RectangleShape2D", "properties": {"size": [32, 576]}})
        tool_call("batch_scene_node_edits", {"operations": [
            {"type": "set_property", "node_path": "Player", "property_name": "position", "property_value": [320, 288]},
            {"type": "set_property", "node_path": "Player/Visual", "property_name": "size", "property_value": [32, 32]},
            {"type": "set_property", "node_path": "Player/Visual", "property_name": "position", "property_value": [-16, -16]},
            {"type": "set_property", "node_path": "WallLeft", "property_name": "position", "property_value": [64, 288]},
            {"type": "set_property", "node_path": "WallRight", "property_name": "position", "property_value": [576, 288]},
        ]})
        created = tool_call("create_script", {"script_path": SCRIPT, "content": PLAYER_SCRIPT, "attach_to_node": "Player"})
        check("player script created with validation",
              not created.get("has_errors", False), json.dumps(created)[:300])
        tool_call("save_scene", {"scene_path": SCENE})
        tool_call("set_project_setting", {
            "setting": "application/run/main_scene", "value": SCENE, "persist": True})
        print("[ok] scene + script + input + main scene created and saved")

        # ---------------- Phase 2: run and observe real behavior ----------------
        probe = tool_call("install_runtime_probe", {"node_name": "MCPRuntimeProbe", "persistent": True})
        if probe.get("status") not in ("success", "already_installed", "pending"):
            raise AssertionError(f"install_runtime_probe failed: {json.dumps(probe)[:300]}")
        tool_call("run_project", {"scene_path": SCENE, "allow_window": True})
        wait_runtime_ready()

        start_x = player_x()
        check("player starts at spawn x=320", abs(start_x - 320.0) < 1.0, str(start_x))

        baseline = hold_key_and_measure("move_right", 400.0)
        check("movement is real (320 -> 400 held key)", True)

        # Collision: keep holding right; the player must stop at the wall
        # (wall inner face 560 minus player half-width 16 -> 544) and stay there.
        tool_call("simulate_runtime_input_action", {"action_name": "move_right", "pressed": True})
        blocked = tool_call("await_runtime_condition", {
            "expression": "get_node('Player').position.x >= 543.5", "timeout_ms": 8000})
        tool_call("simulate_runtime_input_action", {"action_name": "move_right", "pressed": False})
        check("player reached the wall", bool(blocked.get("condition_met")), json.dumps(blocked)[:200])
        time.sleep(0.8)
        settled_x = player_x()
        check("wall blocks the player (x settles <= 544.5)", settled_x <= 544.5, str(settled_x))

        shot = tool_call("get_runtime_screenshot", {"save_path": "user://first_playable.png", "format": "png"})
        check("runtime screenshot captured",
              shot.get("status") == "success" and bool(shot.get("size")), json.dumps(shot)[:200])

        logs = tool_call("get_editor_logs", {"source": "runtime"})
        log_text = json.dumps(logs)
        check("no script errors while playing", "SCRIPT ERROR" not in log_text, log_text[:300])
        tool_call("stop_project", {"allow_window": True})

        # ---------------- Phase 3: iterate via the recoverable change set ----------------
        read = tool_call("read_script", {"script_path": SCRIPT})
        content_hash = read.get("content_hash")
        check("read_script returned the content hash", bool(content_hash))
        old_speed, new_speed = "const SPEED := 200.0", "const SPEED := 400.0"
        check("parameter before: SPEED 200", old_speed in read.get("content", ""))
        preview = tool_call("apply_change_set", {
            "intent": "double player speed for the iteration smoke",
            "operations": [{
                "path": SCRIPT, "expected_content_hash": content_hash,
                "edits": [{"old_text": old_speed, "new_text": new_speed}]}],
            "change_set_id": "first-playable-speed-2x", "dry_run": True})
        check("dry run previewed the edit",
              "error" not in preview and bool(preview.get("change_set_id")), json.dumps(preview)[:200])
        committed = tool_call("apply_change_set", {
            "intent": "double player speed for the iteration smoke",
            "operations": [{
                "path": SCRIPT, "expected_content_hash": content_hash,
                "edits": [{"old_text": old_speed, "new_text": new_speed}]}],
            "change_set_id": "first-playable-speed-2x", "dry_run": False})
        check("change set committed", "error" not in committed, json.dumps(committed)[:300])
        after = tool_call("read_script", {"script_path": SCRIPT})
        check("parameter after: SPEED 400", new_speed in after.get("content", ""))

        tool_call("run_project", {"scene_path": SCENE, "allow_window": True})
        wait_runtime_ready()
        check("fresh run spawns at x=320 again", abs(player_x() - 320.0) < 1.0)
        # Fixed-window position comparison: the probe round-trip (~150-200ms)
        # dominates short time-to-target measurements, so compare how far the
        # player gets inside one fixed 0.8s hold instead of comparing elapsed.
        tool_call("simulate_runtime_input_action", {"action_name": "move_right", "pressed": True})
        time.sleep(0.8)
        fast_x = player_x()
        tool_call("simulate_runtime_input_action", {"action_name": "move_right", "pressed": False})
        baseline_ms = float(baseline.get("elapsed_ms", -1))
        # Baseline: 80px took ~400ms (200 px/s). Doubled: 224px to the wall must
        # be covered inside the 0.8s window (needs > 280 px/s average).
        check("parameter change has measurable effect (2x speed reaches the wall)",
              fast_x >= 540.0, f"after 0.8s hold at SPEED 400: x={fast_x}")
        print(f"[ok] SPEED 200->400: baseline crossed 80px in {baseline_ms:.0f}ms; "
              f"doubled speed reached the wall ({fast_x:.0f}px) inside 0.8s")
        tool_call("stop_project", {"allow_window": True})

        # ---------------- Phase 4: persistence across an editor restart ----------------
        process.terminate()
        try:
            process.wait(timeout=15)
        except subprocess.TimeoutExpired:
            process.kill()
        process = boot_editor()
        wait_for_server()
        info2 = tool_call("get_project_info")
        check("editor restart reconnects to the same project",
              info2.get("project_name") == "FirstPlayableScratch")
        tool_call("open_scene", {"scene_path": SCENE, "allow_ui_focus": True})
        structure = json.dumps(tool_call("get_scene_structure"))
        for expected in ("Player", "Visual", "Shape", "WallLeft", "WallRight"):
            check(f"scene still contains {expected} after restart", expected in structure)
        persisted = tool_call("read_script", {"script_path": SCRIPT})
        check("edited SPEED=400 survived the restart", new_speed in persisted.get("content", ""))
        actions2 = {a["action_name"] for a in tool_call("list_project_input_actions").get("actions", [])}
        check("input actions survived the restart", {"move_left", "move_right"} <= actions2)
        settings = tool_call("get_project_settings", {"prefix": "application/run/"})
        check("main scene survived the restart",
              SCENE in json.dumps(settings), json.dumps(settings)[:200])

        print("\nFIRST PLAYABLE SLICE: ALL CHECKS PASSED")
        print(f"scene={SCENE} script={SCRIPT} param SPEED 200->400 "
              f"(baseline 80px in {baseline_ms:.0f}ms; doubled reached wall at {fast_x:.0f}px)")
        return 0
    finally:
        process.terminate()
        try:
            process.wait(timeout=15)
        except subprocess.TimeoutExpired:
            process.kill()
        if "PASSED" in " ".join(sys.argv):
            pass
        # Keep the scratch dir only when FAILED so it can be inspected.
        exc = sys.exc_info()[0]
        if exc is None:
            shutil.rmtree(SCRATCH, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
