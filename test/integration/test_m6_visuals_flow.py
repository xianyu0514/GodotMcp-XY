"""M6 real-engine validation: the surfaces never touched by a real editor.

create_scene_variant (does Godot ACCEPT the generated inherited .tscn?),
camera data-presets + timeline follow, particle one_shot burst via inline
sub-resource, batch_update_scene_files real round trip (edit -> reload ->
read back). One scratch plugin-only project, one real editor session.

  GODOT_EXE=... MCP_PORT=9192 python test_m6_visuals_flow.py
  KEEP_M6=1 retains the scratch project for triage.
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
USER_PROJ = REPO / ".tmp_m6_visuals"
GODOT_EXE = Path(os.environ.get("GODOT_EXE", "C:/kaifa/Godot_v4.6.3-stable_win64_console.exe"))
MCP_PORT = int(os.environ.get("MCP_PORT", "9192"))
URL = f"http://127.0.0.1:{MCP_PORT}/mcp"

SCENE = "res://scenes/arena.tscn"
VARIANT = "res://scenes/arena_night.tscn"
BALL_SCRIPT = "res://scripts/ball.gd"
GAME_SCRIPT = "res://scripts/game.gd"

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

var _charging := false
var _charge_ms := 0.0

func _physics_process(delta: float) -> void:
\tif Input.is_action_just_pressed("launch"):
\t\t_charging = true
\t\t_charge_ms = 0.0
\telif Input.is_action_just_released("launch"):
\t\tvar factor: float = clampf(_charge_ms / 1000.0, 0.5, 1.0)
\t\tapply_impulse(Vector2(1, 0) * launch_power * factor, Vector2.ZERO)
\t\t_charging = false
\t\tvar game := get_node_or_null("../Game")
\t\tif game and game.has_method("register_stroke"):
\t\t\tgame.register_stroke()
\t\tvar burst := get_node_or_null("../Burst")
\t\tif burst:
\t\t\tburst.restart()
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
        return {"error": result["content"][0]["text"][:250]}
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


TIMELINE = {
    "events": [
        {"frame": 5, "action": "launch", "pressed": True},
        {"frame": 35, "action": "launch", "pressed": False},
    ],
    "settle_frames": 120,
}


def tl(requirement, label, expr, expected, operator="eq", extra_samples=()):
    t = dict(TIMELINE)
    t["sample"] = [{"label": label, "expression": expr}] + [dict(s) for s in extra_samples]
    t["assertions"] = [{"label": label, "expression": expr, "expected": expected,
        "operator": operator, "description": label}]
    return {"kind": "behavior_check", "requirement": requirement, "label": label,
        "detail": {"scene_path": SCENE, "timeline": t}}


def main() -> int:
    if USER_PROJ.exists():
        shutil.rmtree(USER_PROJ, ignore_errors=True)
    (USER_PROJ / "addons").mkdir(parents=True)
    shutil.copytree(REPO / "addons" / "godot_mcp", USER_PROJ / "addons" / "godot_mcp")
    (USER_PROJ / "project.godot").write_text(
        "config_version=5\n\n[application]\n\nconfig/name=\"M6Visuals\"\n\n"
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
        print("=== M6 REAL-ENGINE VALIDATION: variant + camera + particles + batch ===")

        tool("enable_tools", {"tools": [
            "create_scene", "open_scene", "create_node", "set_node_subresource",
            "batch_scene_node_edits", "create_script", "save_scene",
            "set_project_setting", "upsert_project_input_action",
            "run_verification_queue", "create_scene_variant",
            "batch_update_scene_files", "batch_get_node_properties",
            "get_editor_logs", "close_scene_tab", "create_navigation_region"]})
        tool("upsert_project_input_action", {"action_name": "launch", "erase_existing": True,
            "events": [{"type": "key", "physical_keycode": 32}]})

        tool("create_scene", {"scene_path": SCENE, "root_node_type": "Node2D"})
        tool("open_scene", {"scene_path": SCENE, "allow_ui_focus": True})
        for parent, ntype, nname in [
            ("", "Node", "Game"),
            ("", "RigidBody2D", "Ball"),
            ("Ball", "CollisionShape2D", "Shape"),
            ("Ball", "Camera2D", "Cam"),
            ("", "Area2D", "Hole"), ("Hole", "CollisionShape2D", "Shape"),
            ("", "GPUParticles2D", "Burst"),
        ]:
            tool("create_node", {"parent_path": parent, "node_type": ntype, "node_name": nname})
        tool("set_node_subresource", {"node_path": "Ball/Shape", "property_name": "shape",
            "resource_type": "CircleShape2D", "properties": {"radius": 12}})
        tool("set_node_subresource", {"node_path": "Hole/Shape", "property_name": "shape",
            "resource_type": "CircleShape2D", "properties": {"radius": 48}})
        tool("set_node_subresource", {"node_path": "Burst", "property_name": "process_material",
            "resource_type": "ParticleProcessMaterial",
            "properties": {"direction": [0, -1], "spread": 60.0, "initial_velocity_min": 120.0,
                "initial_velocity_max": 220.0, "explosiveness": 1.0}})
        tool("batch_scene_node_edits", {"operations": [
            {"type": "set_property", "node_path": "Ball", "property_name": "position", "property_value": [100, 300]},
            {"type": "set_property", "node_path": "Ball", "property_name": "gravity_scale", "property_value": 0.0},
            {"type": "set_property", "node_path": "Ball", "property_name": "linear_damp", "property_value": 0.4},
            # 相机=数据预设（子节点刚性跟随 + 世界边界 limits 全是内建属性）
            {"type": "set_property", "node_path": "Ball/Cam", "property_name": "position_smoothing_enabled", "property_value": False},
            {"type": "set_property", "node_path": "Ball/Cam", "property_name": "limit_left", "property_value": 0},
            {"type": "set_property", "node_path": "Ball/Cam", "property_name": "limit_right", "property_value": 800},
            {"type": "set_property", "node_path": "Hole", "property_name": "position", "property_value": [560, 300]},
            # 粒子=数据预设（one_shot 爆发：节点属性，explosiveness 在材质上）
            {"type": "set_property", "node_path": "Burst", "property_name": "one_shot", "property_value": True},
            {"type": "set_property", "node_path": "Burst", "property_name": "amount", "property_value": 16},
            {"type": "set_property", "node_path": "Burst", "property_name": "lifetime", "property_value": 0.6},
            {"type": "set_property", "node_path": "Burst", "property_name": "emitting", "property_value": False},
        ]})
        for path, content, attach in ((GAME_SCRIPT, GAME_GD, "Game"), (BALL_SCRIPT, BALL_GD, "Ball")):
            created = tool("create_script", {"script_path": path, "content": content, "attach_to_node": attach})
            check(f"{path} clean", not created.get("has_errors", False), json.dumps(created)[:180])
        tool("save_scene", {"scene_path": SCENE})
        tool("set_project_setting", {"setting": "application/run/main_scene", "value": SCENE, "persist": True})
        print("[ok] arena built: ball+camera(data) + particles(one_shot data) + hole(script-wired)")

        # ---- 契约：相机跟随 / 粒子爆发完成 / 球被发射（全部 timeline 单往返）----
        q = tool("run_verification_queue", {"command": "create", "strict": True,
            "goal": "M6 visuals: data presets proven by timelines",
            "requirements": ["ball_moves", "camera_tracks_ball", "burst_completes"],
            "items": [
                tl("ball_moves", "ball_x", "get_node('Ball').global_position.x", 150, "gte"),
                tl("camera_tracks_ball", "cam_x", "get_node('Ball/Cam').global_position.x", 150, "gte"),
                tl("burst_completes", "emitting", "get_node('Burst').emitting", False, "eq"),
            ]}, timeout=600.0)
        advances = 0
        while q.get("outcome") in ("pending_more", "open") and advances < 10:
            q = tool("run_verification_queue", {"command": "advance", "queue_id": q.get("queue_id", "")}, timeout=600.0)
            advances += 1
        checklist = q.get("checklist", {})
        for e in checklist.get("requirements", []):
            print(f"  [{e.get('status')}] {e.get('requirement')}")
        overall = str(checklist.get("overall", "incomplete"))
        print(f"=== M6 CONTRACT: {overall.upper()} ===")
        check("visuals data presets proven", overall == "complete", json.dumps(q.get("items", []))[:400])

        # ---- 变体：生成 -> 真引擎加载 -> 覆盖可读回 ----
        variant = tool("create_scene_variant", {"scene_path": VARIANT, "base_scene": SCENE,
            "overrides": [
                {"node": "Ball", "property": "linear_damp", "value": 0.2},
                {"node": "Ball/Cam", "property": "limit_right", "value": 720},
            ]})
        check("variant created", variant.get("status") == "success", json.dumps(variant)[:200])
        opened = tool("open_scene", {"scene_path": VARIANT, "allow_ui_focus": True})
        check("real engine opens the generated inherited scene", not opened.get("error"),
              json.dumps(opened)[:250])
        logs = tool("get_editor_logs", {"source": "editor", "log_type": ["Error"], "count": 20})
        error_lines = [l for l in (logs.get("logs", []) if isinstance(logs.get("logs"), list) else [])
                       if VARIANT in str(l) or "arena_night" in str(l)]
        check("no load errors for the variant", len(error_lines) == 0, str(error_lines)[:200])
        props = tool("batch_get_node_properties", {"node_paths": ["Ball"]})
        ball_props = {}
        entries = props.get("results", props.get("properties", []))
        if isinstance(entries, list):
            for entry in entries:
                if isinstance(entry, dict) and str(entry.get("node_path", entry.get("node", ""))).endswith("Ball"):
                    ball_props = entry.get("properties", entry)
        damp = ball_props.get("linear_damp") if isinstance(ball_props, dict) else None
        check("variant override readable in the loaded scene",
              damp is not None and abs(float(damp) - 0.2) < 0.001, f"linear_damp={damp}")

        # ---- batch：真实文件改写 -> 重载读回 ----
        root_name = str(variant.get("root_name", ""))
        batch = tool("batch_update_scene_files", {"scenes": [VARIANT],
            "edits": [{"node": f"{root_name}/Ball", "property": "linear_damp",
                       "value": 0.15, "expect_current": 0.2}],
            "dry_run": False})
        scenes = batch.get("scenes", [{}])
        changed = scenes[0].get("changed", []) if scenes else []
        check("batch edited the variant file", len(changed) == 1, json.dumps(batch)[:250])
        # 文本改写后已打开的标签聚焦的是旧实例（already_open 路径）——
        # 真实调用流：关标签再开，从刷新后的缓存重新实例化。
        tool("close_scene_tab", {"scene_path": VARIANT, "allow_ui_focus": True})
        tool("open_scene", {"scene_path": VARIANT, "allow_ui_focus": True})
        props2 = tool("batch_get_node_properties", {"node_paths": ["Ball"]})
        entries2 = props2.get("results", props2.get("properties", []))
        damp2 = None
        if isinstance(entries2, list):
            for entry in entries2:
                if isinstance(entry, dict) and str(entry.get("node_path", entry.get("node", ""))).endswith("Ball"):
                    damp2 = (entry.get("properties", entry) or {}).get("linear_damp")
        check("reload reads the batched value back",
              damp2 is not None and abs(float(damp2) - 0.15) < 0.001, f"linear_damp={damp2}")

        # ---- 导航：工具烘焙 -> 运行时顶点证明 ----
        tool("open_scene", {"scene_path": SCENE, "allow_ui_focus": True})
        nav = tool("create_navigation_region", {
            "outlines": [[[80, 120], [740, 120], [740, 480], [80, 480]]],
            "agent_radius": 8.0, "node_name": "NavRegion"})
        check("navigation region baked", nav.get("status") == "success" and int(nav.get("vertices_count", 0)) >= 4,
              json.dumps(nav)[:220])
        tool("save_scene", {"scene_path": SCENE})
        q2 = tool("run_verification_queue", {"command": "create", "strict": True,
            "goal": "nav proof", "requirements": ["nav_mesh_present"],
            "items": [tl("nav_mesh_present", "nav_verts",
                "get_node('NavRegion').navigation_polygon.get_vertices().size()", 4, "gte")]},
            timeout=600.0)
        advances = 0
        while q2.get("outcome") in ("pending_more", "open") and advances < 10:
            q2 = tool("run_verification_queue", {"command": "advance", "queue_id": q2.get("queue_id", "")}, timeout=600.0)
            advances += 1
        check("baked nav mesh present at RUNTIME",
              str(q2.get("checklist", {}).get("overall", "")) == "complete",
              json.dumps(q2.get("items", []))[:300])

        print("\n=== M6 REAL-ENGINE VALIDATION: ALL CHECKS PASSED ===")
        return 0
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=15)
        except subprocess.TimeoutExpired:
            proc.kill()
        if os.environ.get("KEEP_M6"):
            print("[keep] project retained at", USER_PROJ)
        else:
            shutil.rmtree(USER_PROJ, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
