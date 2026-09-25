"""FLAGSHIP DOGFOOD — the complete game, end to end, through MCP only.

"Gem Rush": player (move/jump/place/destroy), a telegraphing spike (fairness),
3 gems (win), 1 HP (lose), pause menu, save slots, juice (flash shader via
create_script, edit-time set_material_parameter FIRST REAL RUN, pickup burst,
apply_animation_preset FIRST REAL RUN). Climbs game_quality_ladder with
review-moment screenshots (A-evidence) and stresses the full chain.

  GODOT_EXE=... MCP_PORT=9194 python test_flagship_game_flow.py
  KEEP_FLAG=1 retains the scratch project.
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
USER_PROJ = REPO / ".tmp_flagship"
GODOT_EXE = Path(os.environ.get("GODOT_EXE", "C:/kaifa/Godot_v4.6.3-stable_win64_console.exe"))
MCP_PORT = int(os.environ.get("MCP_PORT", "9194"))
URL = f"http://127.0.0.1:{MCP_PORT}/mcp"

SCENE = "res://scenes/gem_rush.tscn"
GAME_SCRIPT = "res://scripts/game.gd"
PLAYER_SCRIPT = "res://scripts/player.gd"
SPIKE_SCRIPT = "res://scripts/spike.gd"
MENU_SCRIPT = "res://scripts/menu.gd"
FLASH_SHADER = "res://scripts/hit_flash.gdshader"

GAME_GD = """extends Node
var hp := 1
var gems := 0
var won := false
var dead := false

func _ready() -> void:
	var spike := get_node_or_null("../Spike")
	if spike:
		spike.body_entered.connect(_on_spike_body)
	for gem_name in ["Gem1", "Gem2", "Gem3"]:
		var gem := get_node_or_null("../" + gem_name)
		if gem:
			gem.body_entered.connect(_on_gem_body.bind(gem_name))
	_load()

func _on_spike_body(body: Node) -> void:
	var spike := get_node_or_null("../Spike")
	if body.name == "Player" and spike and spike.armed and not dead:
		dead = true
		hp = 0

func _on_gem_body(body: Node, gem_name: String) -> void:
	if body.name != "Player":
		return
	gems += 1
	var gem := get_node_or_null("../" + gem_name)
	var burst := get_node_or_null("../Burst")
	if gem and burst:
		burst.global_position = gem.global_position
		burst.restart()
	if gem:
		gem.queue_free()
	if gems >= 3:
		won = true

func save_slot() -> void:
	var f := FileAccess.open("user://gemrush_slot1.json", FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify({"gems": gems, "hp": hp}))
		f.close()

func _load() -> void:
	if not FileAccess.file_exists("user://gemrush_slot1.json"):
		return
	var f := FileAccess.open("user://gemrush_slot1.json", FileAccess.READ)
	if f == null:
		return
	var parsed = JSON.parse_string(f.get_as_text())
	f.close()
	if parsed is Dictionary:
		gems = int(parsed.get("gems", 0))
		hp = int(parsed.get("hp", 1))
"""

PLAYER_GD = """extends CharacterBody2D
@export var move_speed := 220.0
@export var jump_speed := 380.0

var _gravity := 980.0

func _physics_process(delta: float) -> void:
	var dir := Input.get_axis("move_left", "move_right")
	if not is_on_floor():
		velocity.y += _gravity * delta
	velocity.x = dir * move_speed
	if is_on_floor() and Input.is_action_just_pressed("jump"):
		velocity.y = -jump_speed
	var world := get_node_or_null("..")
	if Input.is_action_just_pressed("place") and world and world.has_method("place_block"):
		world.place_block()
	if Input.is_action_just_pressed("destroy") and world and world.has_method("destroy_block"):
		world.destroy_block()
	if Input.is_action_just_pressed("save"):
		var game := get_node_or_null("../Game")
		if game and game.has_method("save_slot"):
			game.save_slot()
	move_and_slide()
"""

SPIKE_GD = """extends Area2D
@export var arm_delay_frames := 18
@export var detect_range := 140.0

var warn_frames := 0
var warned := false
var armed := false

func _physics_process(_delta: float) -> void:
	var player := get_node_or_null("../Player")
	if player == null:
		return
	var near: bool = (player.global_position - global_position).length() < detect_range
	if armed:
		return
	if near and not warned:
		warned = true
		modulate = Color(1.0, 0.85, 0.4)
	if warned:
		warn_frames += 1
		if warn_frames >= arm_delay_frames:
			armed = true
			modulate = Color(1.0, 0.35, 0.35)
"""

MENU_GD = """extends CanvasLayer

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_WHEN_PAUSED

func _process(_delta: float) -> void:
	if Input.is_action_just_pressed("ui_cancel"):
		var tree := get_tree()
		tree.paused = not tree.paused
		var label := get_node_or_null("Label")
		if label:
			label.visible = tree.paused
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


def main() -> int:
    if USER_PROJ.exists():
        shutil.rmtree(USER_PROJ, ignore_errors=True)
    (USER_PROJ / "addons").mkdir(parents=True)
    shutil.copytree(REPO / "addons" / "godot_mcp", USER_PROJ / "addons" / "godot_mcp")
    (USER_PROJ / "project.godot").write_text(
        "config_version=5\n\n[application]\n\nconfig/name=\"GemRush\"\n\n"
        "[editor_plugins]\n\nenabled=PackedStringArray(\"res://addons/godot_mcp/plugin.cfg\")\n",
        encoding="utf-8")
    # user:// 残留清除（实测 flake 源）
    appdata = Path(os.environ.get("APPDATA", "")) / "Godot" / "app_userdata" / "GemRush"
    if appdata.exists():
        for stale in appdata.glob("gemrush_slot*.json"):
            stale.unlink()

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
        print("=== FLAGSHIP DOGFOOD: Gem Rush — complete game through MCP ===")

        card = rpc("prompts/get", {"name": "make_any_game", "arguments": {"goal": "Gem Rush"}})
        card_text = str(card.get("result", {}).get("messages", [{}])[0].get("content", {}).get("text", ""))
        check("capability card serves the build", "CAPABILITY CARD" in card_text)

        tool("enable_tools", {"tools": [
            "create_scene", "open_scene", "create_node", "set_node_subresource",
            "batch_scene_node_edits", "create_script", "save_scene",
            "set_project_setting", "upsert_project_input_action",
            "run_verification_queue", "install_runtime_probe",
            "game_quality_ladder", "set_material_parameter",
            "apply_animation_preset", "create_scene_variant",
            "batch_update_scene_files"]})
        for action, key in [("move_left", 65), ("move_right", 68), ("jump", 32),
                            ("place", 69), ("destroy", 81), ("save", 75)]:
            tool("upsert_project_input_action", {"action_name": action, "erase_existing": True,
                "events": [{"type": "key", "physical_keycode": key}]})

        # ---- 构建 ----
        tool("create_scene", {"scene_path": SCENE, "root_node_type": "Node2D"})
        tool("open_scene", {"scene_path": SCENE, "allow_ui_focus": True})
        for parent, ntype, nname in [
            ("", "Node", "Game"),
            ("", "CharacterBody2D", "Player"),
            ("Player", "CollisionShape2D", "Shape"),
            ("Player", "ColorRect", "Visual"),
            ("Player", "Camera2D", "Cam"),
            ("", "StaticBody2D", "Ground"), ("Ground", "CollisionShape2D", "GShape"),
            ("", "Area2D", "Spike"), ("Spike", "CollisionShape2D", "SShape"),
            ("", "Area2D", "Gem1"), ("Gem1", "CollisionShape2D", "Shape"),
            ("", "Area2D", "Gem2"), ("Gem2", "CollisionShape2D", "Shape"),
            ("", "Area2D", "Gem3"), ("Gem3", "CollisionShape2D", "Shape"),
            ("", "GPUParticles2D", "Burst"),
            ("", "CanvasLayer", "Menu"), ("Menu", "Label", "Label"),
        ]:
            tool("create_node", {"parent_path": parent, "node_type": ntype, "node_name": nname})
        tool("set_node_subresource", {"node_path": "Player/Shape", "property_name": "shape",
            "resource_type": "RectangleShape2D", "properties": {"size": [24, 28]}})
        tool("set_node_subresource", {"node_path": "Ground/GShape", "property_name": "shape",
            "resource_type": "RectangleShape2D", "properties": {"size": [2400, 64]}})
        tool("set_node_subresource", {"node_path": "Spike/SShape", "property_name": "shape",
            "resource_type": "RectangleShape2D", "properties": {"size": [28, 28]}})
        for gem in ("Gem1", "Gem2", "Gem3"):
            tool("set_node_subresource", {"node_path": f"{gem}/Shape", "property_name": "shape",
                "resource_type": "CircleShape2D", "properties": {"radius": 22}})
        tool("set_node_subresource", {"node_path": "Burst", "property_name": "process_material",
            "resource_type": "ParticleProcessMaterial",
            "properties": {"direction": [0, -1], "spread": 90.0, "initial_velocity_min": 100.0,
                "initial_velocity_max": 200.0, "explosiveness": 1.0}})
        tool("batch_scene_node_edits", {"operations": [
            {"type": "set_property", "node_path": "Player", "property_name": "position", "property_value": [100, 300]},
            {"type": "set_property", "node_path": "Player/Visual", "property_name": "size", "property_value": [24, 28]},
            {"type": "set_property", "node_path": "Player/Visual", "property_name": "position", "property_value": [-12, -14]},
            {"type": "set_property", "node_path": "Ground", "property_name": "position", "property_value": [1200, 416]},
            {"type": "set_property", "node_path": "Spike", "property_name": "position", "property_value": [300, 388]},
            {"type": "set_property", "node_path": "Gem1", "property_name": "position", "property_value": [500, 380]},
            {"type": "set_property", "node_path": "Gem2", "property_name": "position", "property_value": [700, 380]},
            {"type": "set_property", "node_path": "Gem3", "property_name": "position", "property_value": [900, 380]},
            {"type": "set_property", "node_path": "Burst", "property_name": "one_shot", "property_value": True},
            {"type": "set_property", "node_path": "Burst", "property_name": "amount", "property_value": 20},
            {"type": "set_property", "node_path": "Burst", "property_name": "lifetime", "property_value": 0.5},
            {"type": "set_property", "node_path": "Burst", "property_name": "emitting", "property_value": False},
            {"type": "set_property", "node_path": "Menu/Label", "property_name": "text", "property_value": "PAUSED — Esc resumes"},
        ]})
        for path, content, attach in [
            (GAME_SCRIPT, GAME_GD, "Game"),
            (PLAYER_SCRIPT, PLAYER_GD, "Player"),
            (SPIKE_SCRIPT, SPIKE_GD, "Spike"),
            (MENU_SCRIPT, MENU_GD, "Menu"),
        ]:
            created = tool("create_script", {"script_path": path, "content": content, "attach_to_node": attach})
            check(f"{path} clean", not created.get("has_errors", False), json.dumps(created)[:180])
        tool("save_scene", {"scene_path": SCENE})
        tool("set_project_setting", {"setting": "application/run/main_scene", "value": SCENE, "persist": True})
        print("[ok] Gem Rush built: player/spike/gems/menu/save/juice nodes + scripts")

        # ---- juice 三件套（新工具真实首用）----
        flash = """shader_type canvas_item;

uniform float flash_amount : hint_range(0.0, 1.0) = 0.0;

void fragment() {
	vec4 base = texture(TEXTURE, UV);
	COLOR = mix(base, vec4(1.0), flash_amount);
}
"""
        shader_created = tool("create_script", {"script_path": FLASH_SHADER,
            "content": flash, "attach_to_node": "Player/Visual"})
        check("flash shader written + mounted", shader_created.get("attach_kind", "") == "shader_material",
              json.dumps(shader_created)[:200])
        mat_set = tool("set_material_parameter", {
            "node_path": "Player/Visual", "parameter": "flash_amount", "value": 0.0})
        check("set_material_parameter FIRST REAL RUN", mat_set.get("status", "") == "success",
              json.dumps(mat_set)[:200])
        preset = tool("apply_animation_preset", {
            "save_path": "res://anim/pickup_pulse.tres", "preset": "pulse",
            "node_label": ".", "magnitude": 15.0, "duration": 0.3})
        check("apply_animation_preset FIRST REAL RUN", preset.get("status", "") == "success",
              json.dumps(preset)[:200])
        tool("save_scene", {"scene_path": SCENE})

        # ---- 契约（全 timeline 单往返，FRESH 隔离）----
        def tl(requirement, label, expr, expected, events, settle=90, operator="eq", samples=()):
            t = {"events": events, "settle_frames": settle,
                 "assertions": [{"label": label, "expression": expr,
                     "expected": expected, "operator": operator, "description": label}]}
            if samples:
                t["sample"] = [dict(s) for s in samples]
            return {"kind": "behavior_check", "requirement": requirement, "label": label,
                "detail": {"scene_path": SCENE, "timeline": t}}

        q = tool("run_verification_queue", {"command": "create", "strict": True,
            "goal": "Gem Rush contract",
            "requirements": ["player_moves", "gems_collect_and_win", "hazard_kills_when_armed",
                             "pause_roundtrip", "save_slot_roundtrip"],
            "items": [
                tl("player_moves", "r1", "get_node('Player').global_position.x", 130,
                   [{"frame": 30, "action": "move_right", "pressed": True},
                    {"frame": 90, "action": "move_right", "pressed": False}], 60, "gte"),
                tl("gems_collect_and_win", "r2", "get_node('Game').won", True,
                   [{"frame": 30, "action": "move_right", "pressed": True},
                    {"frame": 300, "action": "move_right", "pressed": False}], 60),
                tl("hazard_kills_when_armed", "r3", "get_node('Game').dead", True,
                   [{"frame": 0, "action": "move_right", "pressed": True},
                    {"frame": 60, "action": "move_right", "pressed": False}], 90),
                tl("pause_roundtrip", "r4", "get_tree().paused", False,
                   [{"frame": 5, "action": "ui_cancel", "pressed": True},
                    {"frame": 8, "action": "ui_cancel", "pressed": False},
                    {"frame": 40, "action": "ui_cancel", "pressed": True},
                    {"frame": 43, "action": "ui_cancel", "pressed": False}], 20,
                   samples=[{"label": "paused", "expression": "get_tree().paused"}]),
                tl("save_slot_roundtrip", "r5a", "get_node('Game').gems", 1,
                   [{"frame": 30, "action": "move_right", "pressed": True},
                    {"frame": 150, "action": "move_right", "pressed": False},
                    {"frame": 160, "action": "save", "pressed": True},
                    {"frame": 164, "action": "save", "pressed": False}], 20),
                tl("save_slot_roundtrip", "r5b", "get_node('Game').gems", 1,
                   [{"frame": 0, "action": "jump", "pressed": False}], 30),
            ]}, timeout=600.0)
        advances = 0
        while q.get("outcome") in ("pending_more", "open") and advances < 12:
            q = tool("run_verification_queue", {"command": "advance", "queue_id": q.get("queue_id", "")}, timeout=600.0)
            advances += 1
        for e in q.get("checklist", {}).get("requirements", []):
            print(f"  [{e.get('status')}] {e.get('requirement')}")
        overall = str(q.get("checklist", {}).get("overall", "incomplete"))
        print(f"=== FLAGSHIP CONTRACT: {overall.upper()} ===")
        check("Gem Rush contract COMPLETE", overall == "complete",
              json.dumps(q.get("items", []))[:400])

        # ---- 公平性轨迹（前摇帧数，测试侧计算）----
        fq = tool("run_verification_queue", {"command": "create", "strict": True,
            "goal": "fairness telegraph", "requirements": ["telegraph_measured"],
            "items": [{"kind": "behavior_check", "requirement": "telegraph_measured", "label": "F",
                "detail": {"scene_path": SCENE, "timeline": {
                    "events": [{"frame": 0, "action": "move_right", "pressed": True}], "settle_frames": 90,
                    "sample": [
                        {"label": "p", "expression": "get_node('Spike').armed"},
                        {"label": "n", "expression": "(get_node('Player').global_position - get_node('Spike').global_position).length() < 140.0"}],
                    "assertions": [{"label": "p", "expression": "get_node('Spike').armed",
                        "expected": True, "description": "spike arms after approach"}]}}}]},
            timeout=600.0)
        advances = 0
        while fq.get("outcome") in ("pending_more", "open") and advances < 12:
            fq = tool("run_verification_queue", {"command": "advance", "queue_id": fq.get("queue_id", "")}, timeout=600.0)
            advances += 1
        check("fairness item verified", str(fq.get("checklist", {}).get("overall", "")) == "complete")
        armed_traj = []
        try:
            store_raw = (USER_PROJ / ".mcp" / "verification_queues.json").read_text(encoding="utf-8")
            for queue_value in json.loads(store_raw).get("queues", []):
                if "fairness" in str(queue_value.get("goal", "")):
                    for item_value in queue_value.get("items", []):
                        ev = item_value.get("evidence", {})
                        if isinstance(ev.get("trajectory", []), list):
                            armed_traj = ev.get("trajectory", [])
        except FileNotFoundError:
            pass
        telegraph_frames = None
        if armed_traj:
            first_armed = first_near = None
            for s_ in armed_traj:
                if not isinstance(s_, dict):
                    continue
                vals = s_.get("values", {}) or {}
                if first_near is None and bool(vals.get("n", False)):
                    first_near = int(s_.get("frame_index", 0))
                if first_armed is None and bool(vals.get("p", False)):
                    first_armed = int(s_.get("frame_index", 0))
            if first_armed is not None and first_near is not None:
                telegraph_frames = first_armed - first_near
        check("telegraph computed from trajectory", telegraph_frames is not None,
              f"samples={len(armed_traj)}")
        check("fairness telegraph >= 12 frames (ladder R3 floor)",
              (telegraph_frames or 0) >= 12, f"armed at frame {telegraph_frames}")

        # ---- 天梯（review moments + 延迟 + 覆盖代理项）×2 压力幂等 ----
        ladder_params = {
            "scene_path": SCENE,
            "movement": {"action": "move_right", "node": "Player"},
            "platform": "desktop", "sample_seconds": 1.2,
            "extra_items": [
                {"requirement": "gem_feedback_burst", "rung": "r3",
                 "detail": {"timeline": {
                     "events": [{"frame": 30, "action": "move_right", "pressed": True},
                                {"frame": 150, "action": "move_right", "pressed": False}],
                     "settle_frames": 40,
                     "assertions": [
                         {"label": "gems", "expression": "get_node('Game').gems", "expected": 1,
                          "description": "feedback event: gem collected"},
                         {"label": "burst_done", "expression": "get_node('Burst').emitting", "expected": False,
                          "description": "burst fired and completed (coverage+completes)"}]}}},
            ],
            "review_moments": [
                {"id": "first_30_seconds", "steps": [{"wait_ms": 900, "screenshot": True}]},
                {"id": "visual_coherence", "steps": [
                    {"action": "move_right", "pressed": True, "wait_ms": 700},
                    {"action": "move_right", "pressed": False, "wait_ms": 100, "screenshot": True}]},
            ],
        }
        ladder1 = tool("game_quality_ladder", ladder_params, timeout=600.0)
        rung = str(ladder1.get("rung_reached", ""))
        lat = int(ladder1.get("ladder", {}).get("r2", {}).get("latency_frames", -1))
        a_items = ladder1.get("ladder", {}).get("r4", {}).get("a_items_awaiting_review", [])
        print(f"  LADDER #1: rung={rung} latency={lat} frames")
        for a in a_items:
            print(f"    [awaiting_review] {a.get('id')}: {str(a.get('evidence'))[:80]}")
        check("ladder reports a rung", rung in ("r1", "r2", "r3", "r4"), json.dumps(ladder1)[:250])
        check("latency <= 3 frames", 1 <= lat <= 3, f"latency={lat}")
        ladder2 = tool("game_quality_ladder", ladder_params, timeout=600.0)
        check("ladder IDEMPOTENT under stress rerun",
              str(ladder2.get("rung_reached", "")) == rung
              and int(ladder2.get("ladder", {}).get("r2", {}).get("latency_frames", -2)) == lat,
              f"#1 {rung}/{lat} vs #2 {ladder2.get('rung_reached')}/{ladder2.get('ladder', {}).get('r2', {}).get('latency_frames')}")

        # ---- 变体 + 批量（既有工具在复杂场景下压测）----
        variant = tool("create_scene_variant", {"scene_path": "res://scenes/gem_rush_night.tscn",
            "base_scene": SCENE,
            "overrides": [{"node": "Player", "property": "move_speed", "value": 260.0}]})
        check("night variant created", variant.get("status", "") == "success", json.dumps(variant)[:200])
        batch = tool("batch_update_scene_files", {"scenes": ["res://scenes/gem_rush_night.tscn"],
            "edits": [{"node": f"{variant.get('root_name', 'gem_rush')}/Player", "property": "move_speed",
                       "value": 240.0, "expect_current": 260.0}], "dry_run": False})
        scenes0 = batch.get("scenes", [{}])[0] if batch.get("scenes", [{}]) else {}
        check("batch retune on the variant", len(scenes0.get("changed", [])) == 1, json.dumps(batch)[:250])

        print("\n=== FLAGSHIP DOGFOOD: ALL CHECKS PASSED ===")
        print(f"[artifact] project retained for A-review at {USER_PROJ}" if os.environ.get("KEEP_FLAG") else "")
        return 0
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=15)
        except subprocess.TimeoutExpired:
            proc.kill()
        if os.environ.get("KEEP_FLAG"):
            print("[keep] project retained at", USER_PROJ)
        else:
            shutil.rmtree(USER_PROJ, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
