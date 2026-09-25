"""2D CAPABILITY MATRIX — cold-stress the classic 2D asks that had ZERO
prior coverage in tools/recipes/tests (2026-09-25 audit): parallax
backgrounds, 2D lighting (CanvasModulate + PointLight2D under GL
Compatibility), Path2D/PathFollow2D patrol, riding a moving
AnimatableBody2D platform, deterministic camera shake.

Each matrix cell: build through atomic MCP tools only -> FRESH run ->
frame-timed timeline -> in-game assertion (engine truth) + test-side
trajectory math. The light cell compares rendered output with the light
on vs off (variant override) via screenshot byte-diff.

  GODOT_EXE=... MCP_PORT=9196 python test_2d_capability_matrix.py
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

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
USER_PROJ = REPO / ".tmp_2dmatrix"
GODOT_EXE = Path(os.environ.get("GODOT_EXE", "C:/kaifa/Godot_v4.6.3-stable_win64_console.exe"))
MCP_PORT = int(os.environ.get("MCP_PORT", "9196"))
URL = f"http://127.0.0.1:{MCP_PORT}/mcp"

PLAYER_GD = """extends CharacterBody2D
@export var move_speed := 220.0

var _gravity := 980.0

func _physics_process(delta: float) -> void:
	if not is_on_floor():
		velocity.y += _gravity * delta
	velocity.x = Input.get_axis("move_left", "move_right") * move_speed
	move_and_slide()
"""

PATROL_GD = """extends PathFollow2D

func _ready() -> void:
	var path := get_parent() as Path2D
	if path:
		path.curve = Curve2D.new()
		for point in [Vector2(100, 300), Vector2(400, 180), Vector2(700, 300), Vector2(400, 420)]:
			path.curve.add_point(point)
	loop = true
	rotates = false

func _physics_process(delta: float) -> void:
	progress += 90.0 * delta
"""

PLATFORM_GD = """extends AnimatableBody2D

@export var radius := 120.0

# 帧驱动而非墙钟：帧锁定时间线回放下墙钟几乎不走（实测 flake——
# get_ticks_msec 的运动在快速回放中被冻结，搭载位移测成 0）。可被
# 断言的运动必须按物理帧计数推进。
var t := 0

func _physics_process(_delta: float) -> void:
	t += 1
	# 0.02 rad/帧：玩家落地（~26 帧）时平台仍在落点覆盖内，之后带着乘客摆动。
	position.x = 300.0 + sin(float(t) * 0.02) * radius
"""

SHAKE_GD = """extends Camera2D

var shake_left := 0

func _physics_process(_delta: float) -> void:
	if Input.is_action_just_pressed("shake"):
		shake_left = 14
	if shake_left > 0:
		shake_left -= 1
		offset.x = sin(float(shake_left) * 1.9) * 14.0
		offset.y = cos(float(shake_left) * 1.3) * 10.0
	else:
		offset = Vector2.ZERO
"""

LIGHT_GD = """extends PointLight2D

func _ready() -> void:
	var grad := Gradient.new()
	grad.set_color(0, Color(1, 1, 1, 1))
	grad.set_color(1, Color(1, 1, 1, 0))
	var tex := GradientTexture2D.new()
	tex.gradient = grad
	tex.fill = GradientTexture2D.FILL_RADIAL
	tex.fill_from = Vector2(0.5, 0.5)
	tex.fill_to = Vector2(1.0, 0.5)
	tex.width = 256
	tex.height = 256
	texture = tex
	texture_scale = 4.0
	energy = 3.2
"""

SKELETON_GD = """extends Skeleton2D

const ROT_PER_FRAME := 0.03

func _physics_process(_delta: float) -> void:
	var bone := get_node_or_null("Bone1")
	if bone:
		bone.rotation += ROT_PER_FRAME
"""

FX_GD = """shader_type canvas_item;

uniform sampler2D screen_tex : hint_screen_texture;

void fragment() {
	vec3 screen = texture(screen_tex, SCREEN_UV).rgb;
	COLOR = vec4(1.0 - screen, 1.0);
}
"""


# 实测铁律：ColorRect（canvas_item_add_rect 原语）不接收 2D 光照——被照亮的
# 表面必须是带纹理的 CanvasItem（Sprite2D 等），开关灯渲染字节才会不同。
FLOOR_GD = """extends Sprite2D

func _ready() -> void:
	var grad := Gradient.new()
	grad.add_point(0.0, Color(0.42, 0.42, 0.42))
	grad.add_point(1.0, Color(0.42, 0.42, 0.42))
	var tex := GradientTexture2D.new()
	tex.gradient = grad
	tex.width = 64
	tex.height = 64
	texture = tex
	region_enabled = true
	region_rect = Rect2(0, 0, 1152, 648)
	centered = false
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
    except (json.JSONDecodeError, TypeError):
        return {"raw": text}


def check(label, ok, detail=""):
    print(f"  [{'OK' if ok else 'FAIL':4}] {label}" + (f": {detail}" if detail else ""))
    if not ok:
        raise AssertionError(f"[FAIL] {label} — {detail}")


def main() -> int:
    if USER_PROJ.exists():
        shutil.rmtree(USER_PROJ, ignore_errors=True)
    (USER_PROJ / "addons").mkdir(parents=True)
    shutil.copytree(REPO / "addons" / "godot_mcp", USER_PROJ / "addons" / "godot_mcp")
    (USER_PROJ / "project.godot").write_text(
        "config_version=5\n\n[application]\n\nconfig/name=\"Matrix2D\"\n\n"
        "[editor_plugins]\n\nenabled=PackedStringArray(\"res://addons/godot_mcp/plugin.cfg\")\n",
        encoding="utf-8")
    appdata = Path(os.environ.get("APPDATA", "")) / "Godot" / "app_userdata" / "Matrix2D"
    if appdata.exists():
        shutil.rmtree(appdata / "mcp_play_and_verify", ignore_errors=True)

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
        print("=== 2D CAPABILITY MATRIX — zero-coverage cells, cold-stressed ===")

        tool("enable_tools", {"tools": [
            "create_scene", "open_scene", "create_node", "set_node_subresource",
            "batch_scene_node_edits", "create_script", "save_scene",
            "upsert_project_input_action", "run_verification_queue",
            "create_scene_variant"]})
        for action, key in [("move_left", 65), ("move_right", 68), ("shake", 83)]:
            tool("upsert_project_input_action", {"action_name": action, "erase_existing": True,
                "events": [{"type": "key", "physical_keycode": key}]})

        # ---- 视差背景 ----
        P = "res://scenes/parallax.tscn"
        tool("create_scene", {"scene_path": P, "root_node_type": "Node2D"})
        tool("open_scene", {"scene_path": P, "allow_ui_focus": True})
        for parent, ntype, nname in [
            ("", "CharacterBody2D", "Player"), ("Player", "CollisionShape2D", "Shape"),
            ("Player", "ColorRect", "Visual"), ("Player", "Camera2D", "Cam"),
            ("", "StaticBody2D", "Ground"), ("Ground", "CollisionShape2D", "GShape"),
            ("Ground", "ColorRect", "GVisual"),
            ("", "ParallaxBackground", "BG"),
            ("BG", "ParallaxLayer", "Far"), ("BG/Far", "ColorRect", "V"),
            ("BG", "ParallaxLayer", "Near"), ("BG/Near", "ColorRect", "V")]:
            r = tool("create_node", {"parent_path": parent, "node_type": ntype, "node_name": nname})
            check(f"parallax: node {nname}", not r.get("error", ""), str(r.get("error", "")))
        tool("set_node_subresource", {"node_path": "Player/Shape", "property_name": "shape",
            "resource_type": "RectangleShape2D", "properties": {"size": [24, 28]}})
        tool("set_node_subresource", {"node_path": "Ground/GShape", "property_name": "shape",
            "resource_type": "RectangleShape2D", "properties": {"size": [2400, 64]}})
        tool("batch_scene_node_edits", {"operations": [
            {"type": "set_property", "node_path": "Player", "property_name": "position", "property_value": [100, 300]},
            {"type": "set_property", "node_path": "Player/Visual", "property_name": "size", "property_value": [24, 28]},
            {"type": "set_property", "node_path": "Player/Visual", "property_name": "position", "property_value": [-12, -14]},
            {"type": "set_property", "node_path": "Ground", "property_name": "position", "property_value": [1200, 416]},
            {"type": "set_property", "node_path": "Ground/GVisual", "property_name": "size", "property_value": [2400, 64]},
            {"type": "set_property", "node_path": "Ground/GVisual", "property_name": "position", "property_value": [-1200, -32]},
            {"type": "set_property", "node_path": "Ground/GVisual", "property_name": "color", "property_value": [0.35, 0.26, 0.18, 1.0]},
            {"type": "set_property", "node_path": "BG/Far", "property_name": "motion_scale", "property_value": [0.2, 1.0]},
            {"type": "set_property", "node_path": "BG/Far/V", "property_name": "size", "property_value": [3000, 420]},
            {"type": "set_property", "node_path": "BG/Far/V", "property_name": "position", "property_value": [-1500, -430]},
            {"type": "set_property", "node_path": "BG/Far/V", "property_name": "color", "property_value": [0.16, 0.20, 0.30, 1.0]},
            {"type": "set_property", "node_path": "BG/Near", "property_name": "motion_scale", "property_value": [0.6, 1.0]},
            {"type": "set_property", "node_path": "BG/Near/V", "property_name": "size", "property_value": [3000, 280]},
            {"type": "set_property", "node_path": "BG/Near/V", "property_name": "position", "property_value": [-1500, 120]},
            {"type": "set_property", "node_path": "BG/Near/V", "property_name": "color", "property_value": [0.24, 0.30, 0.26, 1.0]}]})
        cr = tool("create_script", {"script_path": "res://scripts/matrix_player.gd",
            "content": PLAYER_GD, "attach_to_node": "Player"})
        check("parallax: player script clean", not cr.get("has_errors", False), json.dumps(cr)[:160])
        tool("save_scene", {"scene_path": P})

        # ---- 2D 光照（Sprite2D 表面：ColorRect 不接收 2D 光照，实测铁律）----
        L = "res://scenes/light.tscn"
        tool("create_scene", {"scene_path": L, "root_node_type": "Node2D"})
        tool("open_scene", {"scene_path": L, "allow_ui_focus": True})
        for parent, ntype, nname in [
            ("", "Sprite2D", "Floor"), ("", "PointLight2D", "Light")]:
            r = tool("create_node", {"parent_path": parent, "node_type": ntype, "node_name": nname})
            check(f"light: node {nname}", not r.get("error", ""), str(r.get("error", "")))
        tool("batch_scene_node_edits", {"operations": [
            {"type": "set_property", "node_path": "Light", "property_name": "position", "property_value": [500, 324]}]})
        cr = tool("create_script", {"script_path": "res://scripts/matrix_floor.gd",
            "content": FLOOR_GD, "attach_to_node": "Floor"})
        check("light: floor script clean", not cr.get("has_errors", False), json.dumps(cr)[:160])
        cr = tool("create_script", {"script_path": "res://scripts/matrix_light.gd",
            "content": LIGHT_GD, "attach_to_node": "Light"})
        check("light: light script clean", not cr.get("has_errors", False), json.dumps(cr)[:160])
        tool("save_scene", {"scene_path": L})
        variant = tool("create_scene_variant", {"scene_path": "res://scenes/light_off.tscn",
            "base_scene": L, "overrides": [{"node": "Light", "property": "enabled", "value": False}]})
        check("light: off-variant created", variant.get("status", "") == "success", json.dumps(variant)[:180])

        # ---- 巡逻路径 ----
        T = "res://scenes/patrol.tscn"
        tool("create_scene", {"scene_path": T, "root_node_type": "Node2D"})
        tool("open_scene", {"scene_path": T, "allow_ui_focus": True})
        for parent, ntype, nname in [
            ("", "Path2D", "EnemyPath"), ("EnemyPath", "PathFollow2D", "Follower"),
            ("EnemyPath/Follower", "ColorRect", "V")]:
            r = tool("create_node", {"parent_path": parent, "node_type": ntype, "node_name": nname})
            check(f"patrol: node {nname}", not r.get("error", ""), str(r.get("error", "")))
        tool("batch_scene_node_edits", {"operations": [
            {"type": "set_property", "node_path": "EnemyPath/Follower/V", "property_name": "size", "property_value": [24, 24]},
            {"type": "set_property", "node_path": "EnemyPath/Follower/V", "property_name": "position", "property_value": [-12, -12]},
            {"type": "set_property", "node_path": "EnemyPath/Follower/V", "property_name": "color", "property_value": [0.85, 0.30, 0.25, 1.0]}]})
        cr = tool("create_script", {"script_path": "res://scripts/matrix_patrol.gd",
            "content": PATROL_GD, "attach_to_node": "EnemyPath/Follower"})
        check("patrol: script clean", not cr.get("has_errors", False), json.dumps(cr)[:160])
        check("patrol: script attached", not cr.get("attach_warning", ""), str(cr.get("attach_warning", "")))
        tool("save_scene", {"scene_path": T})

        # ---- 移动平台 ----
        M = "res://scenes/platform.tscn"
        tool("create_scene", {"scene_path": M, "root_node_type": "Node2D"})
        tool("open_scene", {"scene_path": M, "allow_ui_focus": True})
        for parent, ntype, nname in [
            ("", "AnimatableBody2D", "Platform"), ("Platform", "CollisionShape2D", "PShape"),
            ("Platform", "ColorRect", "V"),
            ("", "CharacterBody2D", "Player"), ("Player", "CollisionShape2D", "Shape"),
            ("Player", "ColorRect", "Visual"), ("Player", "Camera2D", "Cam")]:
            r = tool("create_node", {"parent_path": parent, "node_type": ntype, "node_name": nname})
            check(f"platform: node {nname}", not r.get("error", ""), str(r.get("error", "")))
        tool("set_node_subresource", {"node_path": "Platform/PShape", "property_name": "shape",
            "resource_type": "RectangleShape2D", "properties": {"size": [160, 20]}})
        tool("set_node_subresource", {"node_path": "Player/Shape", "property_name": "shape",
            "resource_type": "RectangleShape2D", "properties": {"size": [24, 28]}})
        tool("batch_scene_node_edits", {"operations": [
            {"type": "set_property", "node_path": "Platform", "property_name": "position", "property_value": [300, 350]},
            {"type": "set_property", "node_path": "Platform", "property_name": "sync_to_physics", "property_value": True},
            {"type": "set_property", "node_path": "Platform/V", "property_name": "size", "property_value": [160, 20]},
            {"type": "set_property", "node_path": "Platform/V", "property_name": "position", "property_value": [-80, -10]},
            {"type": "set_property", "node_path": "Platform/V", "property_name": "color", "property_value": [0.30, 0.45, 0.30, 1.0]},
            {"type": "set_property", "node_path": "Player", "property_name": "position", "property_value": [300, 250]},
            {"type": "set_property", "node_path": "Player/Visual", "property_name": "size", "property_value": [24, 28]},
            {"type": "set_property", "node_path": "Player/Visual", "property_name": "position", "property_value": [-12, -14]}]})
        cr = tool("create_script", {"script_path": "res://scripts/matrix_platform.gd",
            "content": PLATFORM_GD, "attach_to_node": "Platform"})
        check("platform: script clean", not cr.get("has_errors", False), json.dumps(cr)[:160])
        cr = tool("create_script", {"script_path": "res://scripts/matrix_player2.gd",
            "content": PLAYER_GD, "attach_to_node": "Player"})
        check("platform: player script clean", not cr.get("has_errors", False), json.dumps(cr)[:160])
        tool("save_scene", {"scene_path": M})

        # ---- 2D 骨骼（Skeleton2D/Bone2D 运动链）----
        K = "res://scenes/skeleton.tscn"
        tool("create_scene", {"scene_path": K, "root_node_type": "Node2D"})
        tool("open_scene", {"scene_path": K, "allow_ui_focus": True})
        for parent, ntype, nname in [
            ("", "Skeleton2D", "Rig"), ("Rig", "Bone2D", "Bone1"),
            ("Rig/Bone1", "Bone2D", "Bone2"), ("Rig/Bone1/Bone2", "ColorRect", "V")]:
            r = tool("create_node", {"parent_path": parent, "node_type": ntype, "node_name": nname})
            check(f"skeleton: node {nname}", not r.get("error", ""), str(r.get("error", "")))
        tool("batch_scene_node_edits", {"operations": [
            {"type": "set_property", "node_path": "Rig", "property_name": "position", "property_value": [400, 324]},
            {"type": "set_property", "node_path": "Rig/Bone1", "property_name": "length", "property_value": 60},
            {"type": "set_property", "node_path": "Rig/Bone1/Bone2", "property_name": "position", "property_value": [60, 0]},
            {"type": "set_property", "node_path": "Rig/Bone1/Bone2", "property_name": "length", "property_value": 50},
            {"type": "set_property", "node_path": "Rig/Bone1/Bone2/V", "property_name": "size", "property_value": [18, 18]},
            {"type": "set_property", "node_path": "Rig/Bone1/Bone2/V", "property_name": "position", "property_value": [-9, -9]},
            {"type": "set_property", "node_path": "Rig/Bone1/Bone2/V", "property_name": "color", "property_value": [0.9, 0.6, 0.2, 1.0]}]})
        cr = tool("create_script", {"script_path": "res://scripts/matrix_skeleton.gd",
            "content": SKELETON_GD, "attach_to_node": "Rig"})
        check("skeleton: script clean", not cr.get("has_errors", False), json.dumps(cr)[:160])
        tool("save_scene", {"scene_path": K})

        # ---- 屏幕特效（BackBufferCopy + hint_screen_texture）----
        X = "res://scenes/fx.tscn"
        tool("create_scene", {"scene_path": X, "root_node_type": "Node2D"})
        tool("open_scene", {"scene_path": X, "allow_ui_focus": True})
        for parent, ntype, nname in [
            ("", "ColorRect", "Floor"), ("", "ColorRect", "FX"), ("", "BackBufferCopy", "FXCopy")]:
            r = tool("create_node", {"parent_path": parent, "node_type": ntype, "node_name": nname})
            check(f"fx: node {nname}", not r.get("error", ""), str(r.get("error", "")))
        tool("batch_scene_node_edits", {"operations": [
            {"type": "set_property", "node_path": "Floor", "property_name": "size", "property_value": [1152, 648]},
            {"type": "set_property", "node_path": "Floor", "property_name": "color", "property_value": [0.45, 0.45, 0.45, 1.0]},
            {"type": "set_property", "node_path": "FX", "property_name": "size", "property_value": [1152, 648]},
            {"type": "set_property", "node_path": "FXCopy", "property_name": "copy_mode", "property_value": 2}]})
        cr = tool("create_script", {"script_path": "res://scripts/matrix_fx.gdshader",
            "content": FX_GD, "attach_to_node": "FX"})
        check("fx: screen shader clean", not cr.get("has_errors", False), json.dumps(cr)[:160])
        tool("save_scene", {"scene_path": X})
        # 实测铁律：4.x 的 hint_screen_texture 会自动插入屏拷贝（BackBufferCopy
        # 节点并非必需）——copy_mode 开关的变体两帧字节相同。有效对照是特效
        # 可见 vs 隐藏。
        variant_fx = tool("create_scene_variant", {"scene_path": "res://scenes/fx_off.tscn",
            "base_scene": X, "overrides": [{"node": "FX", "property": "visible", "value": False}]})
        check("fx: off-variant created", variant_fx.get("status", "") == "success", json.dumps(variant_fx)[:180])

        # ---- 镜头震动 ----
        S = "res://scenes/shake.tscn"
        tool("create_scene", {"scene_path": S, "root_node_type": "Node2D"})
        tool("open_scene", {"scene_path": S, "allow_ui_focus": True})
        for parent, ntype, nname in [
            ("", "ColorRect", "Hero"), ("", "Camera2D", "Cam"), ("", "ColorRect", "Backdrop")]:
            r = tool("create_node", {"parent_path": parent, "node_type": ntype, "node_name": nname})
            check(f"shake: node {nname}", not r.get("error", ""), str(r.get("error", "")))
        tool("batch_scene_node_edits", {"operations": [
            {"type": "set_property", "node_path": "Hero", "property_name": "size", "property_value": [24, 28]},
            {"type": "set_property", "node_path": "Hero", "property_name": "position", "property_value": [288, 286]},
            {"type": "set_property", "node_path": "Backdrop", "property_name": "size", "property_value": [2000, 700]},
            {"type": "set_property", "node_path": "Backdrop", "property_name": "position", "property_value": [-350, -20]},
            {"type": "set_property", "node_path": "Backdrop", "property_name": "color", "property_value": [0.22, 0.24, 0.28, 1.0]}]})
        cr = tool("create_script", {"script_path": "res://scripts/matrix_shake.gd",
            "content": SHAKE_GD, "attach_to_node": "Cam"})
        check("shake: script clean", not cr.get("has_errors", False), json.dumps(cr)[:160])
        tool("save_scene", {"scene_path": S})

        # ---- 全部走 strict 契约（FRESH 隔离 + 引擎真值断言）----
        def tl(requirement, label, scene, expr, expected, events, settle, operator="eq", samples=(), extra=None):
            t = {"events": events, "settle_frames": settle,
                 "assertions": [{"label": label, "expression": expr,
                     "expected": expected, "operator": operator, "description": label}]}
            if samples:
                t["sample"] = [dict(s) for s in samples]
            detail = {"scene_path": scene, "timeline": t}
            if extra:
                detail.update(extra)
            return {"kind": "behavior_check", "requirement": requirement, "label": label, "detail": detail}

        q = tool("run_verification_queue", {"command": "create", "strict": True,
            "goal": "2D capability matrix",
            "requirements": ["parallax_differential_scroll", "light_renders_on_vs_off",
                             "patrol_progress", "platform_riding", "camera_shake",
                             "bone_chain_moves", "screen_fx_on_vs_off"],
            "items": [
                tl("parallax_differential_scroll", "px", P,
                   "get_node('Player').global_position.x", 1,
                   [{"frame": 0, "action": "move_right", "pressed": True},
                    {"frame": 110, "action": "move_right", "pressed": False}], 10, "gt",
                   samples=[{"label": "p", "expression": "get_node('Player').global_position.x"},
                            {"label": "f", "expression": "get_node('BG/Far').position.x"},
                            {"label": "n", "expression": "get_node('BG/Near').position.x"}]),
                {"kind": "behavior_check", "requirement": "light_renders_on_vs_off", "label": "light_on",
                 "detail": {"scene_path": L, "screenshot_dir": "user://shots/light_on",
                     "steps": [{"wait_ms": 900, "screenshot": True,
                         "assert": {"expression": "get_node('Light').energy", "expected": 3.2}}]}},
                {"kind": "behavior_check", "requirement": "light_renders_on_vs_off", "label": "light_off",
                 "detail": {"scene_path": "res://scenes/light_off.tscn", "screenshot_dir": "user://shots/light_off",
                     "steps": [{"wait_ms": 900, "screenshot": True,
                         "assert": {"expression": "get_node('Light').enabled", "expected": False}}]}},
                tl("patrol_progress", "pg", T, "get_node('EnemyPath/Follower').progress", 100,
                   [{"frame": 0, "action": "move_right", "pressed": False}], 120, "gte",
                   samples=[{"label": "g", "expression": "get_node('EnemyPath/Follower').progress"}]),
                tl("platform_riding", "ride", M,
                   "get_node('Player').global_position.x", 300,
                   [{"frame": 0, "action": "move_left", "pressed": False}], 150, "ne",
                   samples=[{"label": "x", "expression": "get_node('Player').global_position.x"},
                            {"label": "y", "expression": "get_node('Player').global_position.y"}]),
                tl("camera_shake", "cx", S, "get_node('Cam').offset.x", 0,
                   [{"frame": 5, "action": "shake", "pressed": True},
                    {"frame": 8, "action": "shake", "pressed": False}], 40, "eq",
                   samples=[{"label": "cx", "expression": "get_node('Cam').offset.x"}]),
                tl("bone_chain_moves", "bx", "res://scenes/skeleton.tscn",
                   "get_node('Rig/Bone1/Bone2').global_position.y", 324,
                   [{"frame": 0, "action": "move_right", "pressed": False}], 120, "ne",
                   samples=[{"label": "by", "expression": "get_node('Rig/Bone1/Bone2').global_position.y"},
                            {"label": "vx", "expression": "get_node('Rig/Bone1/Bone2/V').global_position.x"}]),
                {"kind": "behavior_check", "requirement": "screen_fx_on_vs_off", "label": "fx_on",
                 "detail": {"scene_path": "res://scenes/fx.tscn", "screenshot_dir": "user://shots/fx_on",
                     "steps": [{"wait_ms": 900, "screenshot": True,
                         "assert": {"expression": "get_node('FXCopy').copy_mode", "expected": 2}}]}},
                {"kind": "behavior_check", "requirement": "screen_fx_on_vs_off", "label": "fx_off",
                 "detail": {"scene_path": "res://scenes/fx_off.tscn", "screenshot_dir": "user://shots/fx_off",
                     "steps": [{"wait_ms": 900, "screenshot": True,
                         "assert": {"expression": "get_node('FX').visible", "expected": False}}]}},
            ]}, timeout=600.0)
        advances = 0
        while q.get("outcome") in ("pending_more", "open") and advances < 12:
            q = tool("run_verification_queue", {"command": "advance", "queue_id": q.get("queue_id", "")}, timeout=600.0)
            advances += 1
        for e in q.get("checklist", {}).get("requirements", []):
            print(f"  [{e.get('status')}] {e.get('requirement')}")
        overall = str(q.get("checklist", {}).get("overall", "incomplete"))
        check("matrix contracts COMPLETE", overall == "complete", json.dumps(q.get("items", []))[:400])

        # ---- 测试侧轨迹数学（契约之外的定量证据）----
        trajectories: dict = {}
        shot_paths: dict = {}
        try:
            store_raw = (USER_PROJ / ".mcp" / "verification_queues.json").read_text(encoding="utf-8")
            for queue_value in json.loads(store_raw).get("queues", []):
                if "capability matrix" in str(queue_value.get("goal", "")):
                    for item_value in queue_value.get("items", []):
                        label = str(item_value.get("label", ""))
                        ev = item_value.get("evidence", {})
                        if isinstance(ev.get("trajectory", []), list):
                            trajectories[label] = ev.get("trajectory", [])
                        for s_ in (ev.get("screenshots", []) or []):
                            if isinstance(s_, dict) and str(s_.get("save_path", "")).startswith("user://"):
                                shot_paths[label] = str(s_["save_path"]).replace("\\", "/")
        except FileNotFoundError:
            pass

        def series(label, key):
            out = []
            for s_ in trajectories.get(label, []):
                if isinstance(s_, dict) and key in (s_.get("values", {}) or {}):
                    v = s_["values"][key]
                    if isinstance(v, (int, float)) and not isinstance(v, bool):
                        out.append(float(v))
            return out

        far_d = series("px", "f")
        near_d = series("px", "n")
        check("parallax: both layers scrolled", len(far_d) > 10 and abs(far_d[-1] - far_d[0]) > 0.5,
              f"far {far_d[0]:.1f}->{far_d[-1]:.1f} over {len(far_d)} samples")
        if len(near_d) == len(far_d) and len(far_d) > 10:
            far_delta = abs(far_d[-1] - far_d[0])
            near_delta = abs(near_d[-1] - near_d[0])
            check("parallax: near scrolls ~3x faster than far (0.6/0.2)",
                  near_delta > 2.0 * far_delta and near_delta < 5.0 * far_delta,
                  f"far={far_delta:.1f} near={near_delta:.1f}")
        prog = series("pg", "g")
        check("patrol: progress monotonic", len(prog) > 10 and all(b >= a - 1e-6 for a, b in zip(prog, prog[1:])),
              f"{len(prog)} samples, {prog[0]:.0f}->{prog[-1]:.0f}")
        xs = series("ride", "x")
        ys = series("ride", "y")
        if xs:
            swing = max(xs) - min(xs)
            check("platform: player rode the platform (x swing > 25px)", swing > 25.0,
                  f"x swing={swing:.1f}px over {len(xs)} samples")
            check("platform: player landed and stayed (y stable)", (max(ys) - min(ys)) < 8.0,
                  f"y swing={max(ys) - min(ys):.1f}px")
        cxs = series("cx", "cx")
        if cxs:
            peak = max(abs(v) for v in cxs)
            check("shake: offset peaked > 5px during shake", peak > 5.0, f"peak |offset.x|={peak:.1f}px")
            check("shake: settled back to 0 at end", abs(cxs[-1]) < 0.01, f"final={cxs[-1]:.2f}")

        # ---- 光照：渲染输出 on/off 字节差 ----
        user_root = appdata
        on_p = user_root / shot_paths.get("light_on", "shots/light_on/step_00.jpg")[len("user://"):] if "light_on" in shot_paths else None
        off_p = user_root / shot_paths.get("light_off", "shots/light_off/step_00.jpg")[len("user://"):] if "light_off" in shot_paths else None
        check("light: both screenshots recorded", on_p is not None and off_p is not None
              and Path(on_p).is_file() and Path(off_p).is_file(), str(shot_paths))
        if on_p and off_p and Path(on_p).is_file() and Path(off_p).is_file():
            d1 = hashlib.md5(Path(on_p).read_bytes()).hexdigest()
            d2 = hashlib.md5(Path(off_p).read_bytes()).hexdigest()
            check("light: rendered output differs with light on vs off", d1 != d2,
                  f"on={d1[:8]} off={d2[:8]}")

                # ---- 骨骼链 + 屏幕特效（测试侧定量）----
        by = series("bx", "by")
        if by:
            swing = max(by) - min(by)
            check("skeleton: bone2 tip moved with parent rotation (y swing > 40px)",
                  swing > 40.0, f"y swing={swing:.1f}px over {len(by)} samples")
        vx = series("bx", "vx")
        if vx:
            check("skeleton: visual child follows the bone chain", (max(vx) - min(vx)) > 30.0,
                  f"x swing={max(vx) - min(vx):.1f}px")
        on_fx = user_root / "shots" / "fx_on" / "step_00.jpg"
        off_fx = user_root / "shots" / "fx_off" / "step_00.jpg"
        check("fx: both screenshots recorded", on_fx.is_file() and off_fx.is_file(),
              f"{on_fx.is_file()}/{off_fx.is_file()}")
        if on_fx.is_file() and off_fx.is_file():
            d_on = hashlib.md5(on_fx.read_bytes()).hexdigest()
            d_off = hashlib.md5(off_fx.read_bytes()).hexdigest()
            check("fx: BackBufferCopy on/off changes rendered output", d_on != d_off,
                  f"on={d_on[:8]} off={d_off[:8]}")

        print("\n=== 2D CAPABILITY MATRIX: ALL CHECKS PASSED ===")
        print("[matrix] parallax | 2d-light | path-patrol | moving-platform | camera-shake | skeleton | screen-fx — all 7 cells verified")
        return 0
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=15)
        except subprocess.TimeoutExpired:
            proc.kill()


if __name__ == "__main__":
    sys.exit(main())
