"""L3 final acceptance: follow make_any_game's general loop on an UNSHIPPED
genre (top-down mini-golf, pure physics) in a scratch plugin-only project,
using ONLY plugin tools through a real editor MCP session.

Validates for real (first time): the recipe's L3 guidance, frame-timed
timeline contracts through run_verification_queue, verify_change_effect
end-to-end, and game_quality_report scope=full.

  GODOT_EXE=... MCP_PORT=9191 python test_l3_any_game_flow.py
"""

import json
import os
import shutil
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
USER_PROJ = REPO / ".tmp_l3_golf"
GODOT_EXE = Path(os.environ.get("GODOT_EXE", "C:/kaifa/Godot_v4.6.3-stable_win64_console.exe"))
MCP_PORT = int(os.environ.get("MCP_PORT", "9191"))
URL = f"http://127.0.0.1:{MCP_PORT}/mcp"

SCENE = "res://scenes/golf.tscn"
GAME_SCRIPT = "res://scripts/game.gd"
BALL_SCRIPT = "res://scripts/ball.gd"

GAME_GD = """extends Node
var strokes := 0
var won := false

func _ready() -> void:
\tvar hole := get_node_or_null("../Hole")
\tif hole:
\t\thole.body_entered.connect(_on_hole_body_entered)

func register_stroke() -> void:
\tstrokes += 1

func _on_hole_body_entered(body: Node) -> void:
\tif body.name == "Ball":
\t\twon = true
"""

BALL_GD = """extends RigidBody2D
@export var launch_power: float = 600.0
@export var launch_direction: Vector2 = Vector2(1, 0)

var _charging := false
var _charge_ms := 0.0

func _physics_process(delta: float) -> void:
\tif Input.is_action_just_pressed("launch"):
\t\t_charging = true
\t\t_charge_ms = 0.0
\telif Input.is_action_just_released("launch"):
\t\tvar factor: float = clampf(_charge_ms / 1000.0, 0.5, 1.0)
\t\tapply_impulse(launch_direction.normalized() * launch_power * factor, Vector2.ZERO)
\t\t_charging = false
\t\tvar game := get_node_or_null("../Game")
\t\tif game and game.has_method("register_stroke"):
\t\t\tgame.register_stroke()
\tif _charging:
\t\t_charge_ms += delta * 1000.0
"""

_req = [0]


def rpc(method, params=None, timeout=300.0):
    _req[0] += 1
    payload = {"jsonrpc": "2.0", "id": _req[0], "method": method, "params": params or {}}
    request = urllib.request.Request(URL, data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"}, method="POST")
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return json.loads(response.read().decode())


def tool(name, args=None, timeout=300.0):
    resp = rpc("tools/call", {"name": name, "arguments": args or {}}, timeout)
    result = resp.get("result", {})
    if result.get("isError"):
        return {"error": result["content"][0]["text"][:200]}
    text = result.get("content", [{}])[0].get("text", "")
    try:
        parsed = json.loads(text)
        return parsed if isinstance(parsed, dict) else {"raw": text}
    except Exception:
        return {"raw": text[:300]}


def check(label, ok, detail=""):
    print(f"  [{'OK' if ok else 'FAIL':4}] {label}" + (f": {detail}" if detail else ""))
    if not ok:
        raise AssertionError(f"[FAIL] {label} — {detail}")


TIMELINE_LAUNCH = {
    "events": [
        {"frame": 5, "action": "launch", "pressed": True},
        {"frame": 35, "action": "launch", "pressed": False},
    ],
    "settle_frames": 300,
    "sample": [
        {"label": "ball_x", "expression": "get_node('Ball').global_position.x"},
        {"label": "won", "expression": "get_node('Game').won"},
        {"label": "strokes", "expression": "get_node('Game').strokes"},
    ],
}


def main() -> int:
    if USER_PROJ.exists():
        shutil.rmtree(USER_PROJ, ignore_errors=True)
    (USER_PROJ / "addons").mkdir(parents=True)
    shutil.copytree(REPO / "addons" / "godot_mcp", USER_PROJ / "addons" / "godot_mcp")
    # 实测坑：键是 config/name（下划线变体会静默空名）。
    (USER_PROJ / "project.godot").write_text(
        "config_version=5\n\n[application]\n\nconfig/name=\"L3GolfSim\"\n\n"
        "[editor_plugins]\n\nenabled=PackedStringArray(\"res://addons/godot_mcp/plugin.cfg\")\n",
        encoding="utf-8")

    proc = subprocess.Popen([str(GODOT_EXE), "--editor", "--headless", "--path", str(USER_PROJ),
        "--", "--mcp-server", f"--mcp-port={MCP_PORT}"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        deadline = time.time() + 180
        while time.time() < deadline:
            try:
                rpc("tools/list", timeout=10.0)
                break
            except Exception:
                time.sleep(1.5)
        print("=== L3 FINAL ACCEPTANCE: make_any_game on an unshipped genre ===")

        # Step 1 — follow the recipe: fetch it, pin its L3 guidance
        recipe = rpc("prompts/get", {"name": "make_any_game", "arguments": {"goal": "top-down mini-golf, one hole"}})
        rtext = str(recipe.get("result", {}).get("messages", [{}])[0].get("content", {}).get("text", ""))
        check("recipe fetched, L3 loop present", "SMALLEST PLAYABLE SLICE" in rtext and "strict" in rtext)
        check("recipe quality floor names report", "game_quality_report" in rtext)

        tool("enable_tools", {"tools": [
            "gather_task_context", "create_scene", "open_scene", "create_node",
            "set_node_subresource", "batch_scene_node_edits", "create_script",
            "connect_signal", "save_scene", "set_project_setting",
            "upsert_project_input_action", "install_runtime_probe",
            "run_verification_queue", "verify_change_effect", "game_quality_report"]})

        # Step 2 — input map FIRST (the recipe's rule)
        tool("upsert_project_input_action", {"action_name": "launch", "erase_existing": True,
            "events": [{"type": "key", "physical_keycode": 32}]})

        # Step 3 — smallest playable slice via atomic tools
        tool("create_scene", {"scene_path": SCENE, "root_node_type": "Node2D"})
        tool("open_scene", {"scene_path": SCENE, "allow_ui_focus": True})
        for parent, ntype, nname in [
            ("", "Node", "Game"),
            ("", "RigidBody2D", "Ball"),
            ("Ball", "ColorRect", "Visual"),
            ("Ball", "CollisionShape2D", "Shape"),
            ("", "StaticBody2D", "WallTop"), ("WallTop", "CollisionShape2D", "Shape"),
            ("", "StaticBody2D", "WallBottom"), ("WallBottom", "CollisionShape2D", "Shape"),
            ("", "StaticBody2D", "WallRight"), ("WallRight", "CollisionShape2D", "Shape"),
            ("", "Area2D", "Hole"), ("Hole", "CollisionShape2D", "Shape"),
            ("Hole", "ColorRect", "Visual"),
        ]:
            tool("create_node", {"parent_path": parent, "node_type": ntype, "node_name": nname})
        tool("set_node_subresource", {"node_path": "Ball/Shape", "property_name": "shape",
            "resource_type": "CircleShape2D", "properties": {"radius": 12}})
        tool("set_node_subresource", {"node_path": "Hole/Shape", "property_name": "shape",
            "resource_type": "CircleShape2D", "properties": {"radius": 48}})
        for wall, size in (("WallTop", [800, 32]), ("WallBottom", [800, 32]), ("WallRight", [32, 600])):
            tool("set_node_subresource", {"node_path": f"{wall}/Shape", "property_name": "shape",
                "resource_type": "RectangleShape2D", "properties": {"size": size}})
        tool("batch_scene_node_edits", {"operations": [
            {"type": "set_property", "node_path": "Ball", "property_name": "position", "property_value": [100, 300]},
            {"type": "set_property", "node_path": "Ball", "property_name": "gravity_scale", "property_value": 0.0},
            {"type": "set_property", "node_path": "Ball", "property_name": "linear_damp", "property_value": 0.4},
            {"type": "set_property", "node_path": "Ball/Visual", "property_name": "size", "property_value": [24, 24]},
            {"type": "set_property", "node_path": "Ball/Visual", "property_name": "position", "property_value": [-12, -12]},
            {"type": "set_property", "node_path": "WallTop", "property_name": "position", "property_value": [400, 84]},
            {"type": "set_property", "node_path": "WallBottom", "property_name": "position", "property_value": [400, 516]},
            {"type": "set_property", "node_path": "WallRight", "property_name": "position", "property_value": [776, 300]},
            {"type": "set_property", "node_path": "Hole", "property_name": "position", "property_value": [560, 300]},
            {"type": "set_property", "node_path": "Hole", "property_name": "monitoring", "property_value": True},
            {"type": "set_property", "node_path": "Hole/Visual", "property_name": "size", "property_value": [96, 96]},
            {"type": "set_property", "node_path": "Hole/Visual", "property_name": "position", "property_value": [-48, -48]},
        ]})
        for path, content, attach in ((GAME_SCRIPT, GAME_GD, "Game"), (BALL_SCRIPT, BALL_GD, "Ball")):
            created = tool("create_script", {"script_path": path, "content": content, "attach_to_node": attach})
            check(f"script {path} created clean", not created.get("has_errors", False), json.dumps(created)[:200])
        wired = tool("connect_signal", {"emitter_path": "Hole", "signal_name": "body_entered",
            "receiver_path": "Game", "receiver_method": "_on_hole_body_entered",
            "flags": 1})  # CONNECT_PERSIST：否则连接不进 .tscn（实测坑）
        check("hole signal wired", not wired.get("error"), json.dumps(wired)[:200])
        tool("save_scene", {"scene_path": SCENE})
        tool("set_project_setting", {"setting": "application/run/main_scene", "value": SCENE, "persist": True})
        print("[ok] slice built: ball + lane + hole + signal + scripts")

        # Step 4 — strict contract BEFORE tuning, timeline items (one round trip each)
        def timeline_item(requirement: str, label: str, expr: str, expected, operator: str = "eq", desc: str = ""):
            tl = dict(TIMELINE_LAUNCH)
            tl["assertions"] = [{"label": label, "expression": expr, "expected": expected,
                "operator": operator, "description": desc or label}]
            return {"kind": "behavior_check", "requirement": requirement, "label": label,
                "detail": {"scene_path": SCENE, "timeline": tl}}

        q = tool("run_verification_queue", {"command": "create", "strict": True,
            "goal": "L3 golf: unshipped genre through the general loop",
            "requirements": ["ball_launches", "hole_wins", "stroke_counted"],
            "items": [
                timeline_item("ball_launches", "r1",
                    "get_node('Ball').global_position.x", 150, "gte",
                    "physics launch moved the ball"),
                timeline_item("hole_wins", "r2",
                    "get_node('Game').won", True, "eq",
                    "full-power straight shot sinks the hole"),
                timeline_item("stroke_counted", "r3",
                    "get_node('Game').strokes", 1, "eq",
                    "one launch = one stroke"),
            ]}, timeout=600.0)
        advances = 0
        while q.get("outcome") in ("pending_more", "open") and advances < 10:
            q = tool("run_verification_queue", {"command": "advance", "queue_id": q.get("queue_id", "")}, timeout=600.0)
            advances += 1
        checklist = q.get("checklist", {})
        for e in checklist.get("requirements", []):
            print(f"  [{e.get('status')}] {e.get('requirement')}")
        overall = str(checklist.get("overall", "incomplete"))
        print(f"=== L3 CONTRACT: {overall.upper()} ===")
        if overall != "complete":
            try:
                store_raw = (USER_PROJ / ".mcp" / "verification_queues.json").read_text(encoding="utf-8")
                Path("/tmp/l3_queue_dump.json").write_text(store_raw, encoding="utf-8")
                print("DEBUG store dumped to /tmp/l3_queue_dump.json")
            except Exception as exc:
                print("DEBUG store dump failed:", exc)
        check("unshipped genre contract COMPLETE", overall == "complete", json.dumps(q.get("items", []))[:400])

        # Step 5 — single-knob change proven by verify_change_effect (real run)
        tool("open_scene", {"scene_path": SCENE, "allow_ui_focus": True})
        tool("batch_scene_node_edits", {"operations": [
            {"type": "set_property", "node_path": "Ball", "property_name": "launch_power",
             "property_value": 900.0}]})
        tool("save_scene", {"scene_path": SCENE})
        effect = tool("verify_change_effect", {"scene_path": SCENE, "node_path": "Ball",
            "property": "launch_power", "expected_value": 900.0,
            "script_path": BALL_SCRIPT, "check_persistence": False}, timeout=600.0)
        verdict = str(effect.get("overall", ""))
        print(f"  verify_change_effect: {verdict}")
        for entry in effect.get("checklist", []):
            print(f"    [{entry.get('status')}] {entry.get('step')}: {str(entry.get('evidence', ''))[:90]}")
        check("change reaches the running game", verdict == "effective", json.dumps(effect)[:400])

        # Step 6 — quality floor: game_quality_report scope=full (first real run)
        report = tool("game_quality_report", {"scope": "full", "scene_path": SCENE,
            "platform": "desktop", "sample_seconds": 1.5}, timeout=600.0)
        print(f"  quality verdict: {report.get('verdict')}")
        for c in report.get("checks", []):
            print(f"    [{c.get('status')}] {c.get('id')}")
        check("quality report full runs and reports",
              report.get("verdict") in ("green", "red"), json.dumps(report)[:300])

        print("\n=== L3 FINAL ACCEPTANCE: ALL CHECKS PASSED ===")
        return 0
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=15)
        except subprocess.TimeoutExpired:
            proc.kill()
        if os.environ.get("KEEP_L3"):
            print("[keep] project retained at", USER_PROJ)
        else:
            shutil.rmtree(USER_PROJ, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
