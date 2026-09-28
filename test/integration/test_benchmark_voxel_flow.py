"""SAME-PROMPT BENCHMARK, our leg: godot-ai's README showcase prompt, verbatim,
through OUR system — capability card consulted (no procedure), built with atomic
tools only, contract-proven, latency measured from the per-frame trajectory
(ladder R2), waivers recorded where the game honestly lacks the dimension.

  Prompt (their README): "Build a voxel block-world game with a player,
  blocks to place and destroy, and save slots."

  GODOT_EXE=... MCP_PORT=9193 python test_benchmark_voxel_flow.py
  KEEP_BENCH=1 retains the scratch project for triage.
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
USER_PROJ = REPO / ".tmp_bench_voxel"
GODOT_EXE = Path(os.environ.get("GODOT_EXE", "C:/kaifa/Godot_v4.6.3-stable_win64_console.exe"))
MCP_PORT = int(os.environ.get("MCP_PORT", "9193"))
URL = f"http://127.0.0.1:{MCP_PORT}/mcp"

THEIR_PROMPT = "Build a voxel block-world game with a player, blocks to place and destroy, and save slots."

SCENE = "res://scenes/world.tscn"
WORLD_SCRIPT = "res://scripts/world.gd"
PLAYER_SCRIPT = "res://scripts/player.gd"

WORLD_GD = """extends Node2D
const CELL := 32

var blocks := {}
var facing := Vector2(1, 0)
var save_path := "user://voxel_slot1.json"

func _ready() -> void:
	_load_if_present()

func register_facing(dir: Vector2) -> void:
	if dir.length() > 0.1:
		facing = Vector2(signf(dir.x), 0) if abs(dir.x) > 0.1 else Vector2(0, signf(dir.y))

func _target_cell() -> Vector2i:
	var p: Node2D = get_node_or_null("../Player")
	if p == null:
		return Vector2i.ZERO
	var base := Vector2i(int(p.global_position.x) / CELL, int(p.global_position.y) / CELL)
	return base + Vector2i(int(facing.x), 0)

func place_block() -> void:
	var cell := _target_cell()
	if blocks.has(cell):
		return
	var body := StaticBody2D.new()
	body.name = "Block_%d_%d" % [cell.x, cell.y]
	body.position = Vector2(cell.x * CELL + CELL / 2.0, cell.y * CELL + CELL / 2.0)
	var shape := CollisionShape2D.new()
	var rect := RectangleShape2D.new()
	rect.size = Vector2(CELL, CELL)
	shape.shape = rect
	body.add_child(shape)
	var visual := ColorRect.new()
	visual.size = Vector2(CELL, CELL)
	visual.position = Vector2(-CELL / 2.0, -CELL / 2.0)
	visual.color = Color(0.35, 0.55, 0.9)
	body.add_child(visual)
	add_child(body)
	blocks[cell] = body

func destroy_block() -> void:
	var cell := _target_cell()
	if not blocks.has(cell):
		return
	blocks[cell].queue_free()
	blocks.erase(cell)

func save_slot() -> void:
	var p: Node2D = get_node_or_null("../Player")
	var cells := []
	for cell in blocks.keys():
		cells.append([cell.x, cell.y])
	var payload := {"cells": cells, "player": [p.global_position.x, p.global_position.y] if p else [100, 100]}
	var f := FileAccess.open(save_path, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(payload))
		f.close()

func _load_if_present() -> void:
	if not FileAccess.file_exists(save_path):
		return
	var f := FileAccess.open(save_path, FileAccess.READ)
	if f == null:
		return
	var parsed = JSON.parse_string(f.get_as_text())
	f.close()
	if not (parsed is Dictionary):
		return
	for cell_value in parsed.get("cells", []):
		if cell_value is Array and (cell_value as Array).size() >= 2:
			var cell := Vector2i(int(cell_value[0]), int(cell_value[1]))
			if not blocks.has(cell):
				var body := StaticBody2D.new()
				body.name = "Block_%d_%d" % [cell.x, cell.y]
				body.position = Vector2(cell.x * CELL + CELL / 2.0, cell.y * CELL + CELL / 2.0)
				var shape := CollisionShape2D.new()
				var rect := RectangleShape2D.new()
				rect.size = Vector2(CELL, CELL)
				shape.shape = rect
				body.add_child(shape)
				var visual := ColorRect.new()
				visual.size = Vector2(CELL, CELL)
				visual.position = Vector2(-CELL / 2.0, -CELL / 2.0)
				visual.color = Color(0.35, 0.55, 0.9)
				body.add_child(visual)
				add_child(body)
				blocks[cell] = body
	var p: Node2D = get_node_or_null("../Player")
	var saved_pos = parsed.get("player", [100, 100])
	if p and saved_pos is Array and (saved_pos as Array).size() >= 2:
		p.global_position = Vector2(float(saved_pos[0]), float(saved_pos[1]))
"""

PLAYER_GD = """extends CharacterBody2D
@export var move_speed := 220.0
@export var jump_speed := 380.0

var _gravity := 980.0

func _physics_process(delta: float) -> void:
	var dir := Input.get_axis("move_left", "move_right")
	var world := get_node_or_null("../World")
	if world and abs(dir) > 0.1:
		world.register_facing(Vector2(dir, 0))
	if not is_on_floor():
		velocity.y += _gravity * delta
	velocity.x = dir * move_speed
	if is_on_floor() and Input.is_action_just_pressed("jump"):
		velocity.y = -jump_speed
	if Input.is_action_just_pressed("place") and world:
		world.place_block()
	if Input.is_action_just_pressed("destroy") and world:
		world.destroy_block()
	if Input.is_action_just_pressed("save") and world:
		world.save_slot()
	move_and_slide()
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
        "config_version=5\n\n[application]\n\nconfig/name=\"BenchVoxel\"\n\n"
        "[editor_plugins]\n\nenabled=PackedStringArray(\"res://addons/godot_mcp/plugin.cfg\")\n",
        encoding="utf-8")

    # user:// 跨运行残留（历史 flake 同类）：启动前清掉本项目的存档。
    appdata = Path(os.environ.get("APPDATA", "")) / "Godot" / "app_userdata" / "BenchVoxel"
    if appdata.exists():
        for stale in appdata.glob("voxel_slot*.json"):
            stale.unlink()
            print("[purged] stale save:", stale.name)

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
        print(f"=== SAME-PROMPT BENCHMARK (our leg) ===")
        print(f"  prompt (their README, verbatim): {THEIR_PROMPT}")

        # 0) 能力卡是唯一"指导"：取卡并断言其声明式内容（无步骤）
        card = rpc("prompts/get", {"name": "make_any_game", "arguments": {"goal": THEIR_PROMPT}})
        card_text = str(card.get("result", {}).get("messages", [{}])[0].get("content", {}).get("text", ""))
        check("capability card serves the prompt (declarative, no steps)",
              "CAPABILITY CARD, not a procedure" in card_text and "Step 1" not in card_text)

        tool("enable_tools", {"tools": [
            "create_scene", "open_scene", "create_node", "set_node_subresource",
            "batch_scene_node_edits", "create_script", "save_scene",
            "set_project_setting", "upsert_project_input_action",
            "run_verification_queue", "install_runtime_probe", "game_quality_ladder"]})
        for action, key in [("move_left", 65), ("move_right", 68), ("jump", 32),
                            ("place", 69), ("destroy", 81), ("save", 75)]:
            tool("upsert_project_input_action", {"action_name": action, "erase_existing": True,
                "events": [{"type": "key", "physical_keycode": key}]})

        tool("create_scene", {"scene_path": SCENE, "root_node_type": "Node2D"})
        tool("open_scene", {"scene_path": SCENE, "allow_ui_focus": True})
        for parent, ntype, nname in [
            ("", "Node2D", "World"),
            ("", "CharacterBody2D", "Player"),
            ("Player", "CollisionShape2D", "Shape"),
            ("Player", "ColorRect", "Visual"),
            ("", "StaticBody2D", "Ground"), ("Ground", "CollisionShape2D", "Shape"),
        ]:
            tool("create_node", {"parent_path": parent, "node_type": ntype, "node_name": nname})
        tool("set_node_subresource", {"node_path": "Player/Shape", "property_name": "shape",
            "resource_type": "RectangleShape2D", "properties": {"size": [24, 28]}})
        tool("set_node_subresource", {"node_path": "Ground/Shape", "property_name": "shape",
            "resource_type": "RectangleShape2D", "properties": {"size": [1600, 64]}})
        tool("batch_scene_node_edits", {"operations": [
            {"type": "set_property", "node_path": "World", "property_name": "position", "property_value": [0, 0]},
            {"type": "set_property", "node_path": "Player", "property_name": "position", "property_value": [100, 300]},
            {"type": "set_property", "node_path": "Player/Visual", "property_name": "size", "property_value": [24, 28]},
            {"type": "set_property", "node_path": "Player/Visual", "property_name": "position", "property_value": [-12, -14]},
            {"type": "set_property", "node_path": "Ground", "property_name": "position", "property_value": [400, 416]},
        ]})
        for path, content, attach in ((WORLD_SCRIPT, WORLD_GD, "World"), (PLAYER_SCRIPT, PLAYER_GD, "Player")):
            created = tool("create_script", {"script_path": path, "content": content, "attach_to_node": attach})
            check(f"{path} clean", not created.get("has_errors", False), json.dumps(created)[:200])
        tool("save_scene", {"scene_path": SCENE})
        tool("set_project_setting", {"setting": "application/run/main_scene", "value": SCENE, "persist": True})
        print("[ok] voxel world built: player + ground + place/destroy/save scripts")

        # 1) 契约：移动 / 放置 / 拆除 / 存档往返（全 timeline 单往返，FRESH 隔离）
        def tl_item(requirement, label, expr, expected, events, settle=90, operator="eq"):
            return {"kind": "behavior_check", "requirement": requirement, "label": label,
                "detail": {"scene_path": SCENE, "timeline": {
                    "events": events, "settle_frames": settle,
                    "assertions": [{"label": label, "expression": expr,
                        "expected": expected, "operator": operator, "description": label}]}}}

        settle_land = [{"frame": 0, "action": "jump", "pressed": False}]
        q = tool("run_verification_queue", {"command": "create", "strict": True,
            "goal": THEIR_PROMPT,
            "requirements": ["player_moves", "block_placed", "block_destroyed", "save_slot_roundtrip"],
            "items": [
                tl_item("player_moves", "r1", "get_node('Player').global_position.x", 130,
                        [{"frame": 30, "action": "move_right", "pressed": True},
                         {"frame": 60, "action": "move_right", "pressed": False}], 60, "gte"),
                tl_item("block_placed", "r2", "get_node('World').blocks.size()", 1,
                        [{"frame": 30, "action": "place", "pressed": True},
                         {"frame": 35, "action": "place", "pressed": False}], 30),
                tl_item("block_destroyed", "r3", "get_node('World').blocks.size()", 0,
                        [{"frame": 30, "action": "place", "pressed": True},
                         {"frame": 34, "action": "place", "pressed": False},
                         {"frame": 60, "action": "destroy", "pressed": True},
                         {"frame": 64, "action": "destroy", "pressed": False}], 30),
                tl_item("save_slot_roundtrip", "r4a", "get_node('World').blocks.size()", 1,
                        [{"frame": 30, "action": "place", "pressed": True},
                         {"frame": 34, "action": "place", "pressed": False},
                         {"frame": 60, "action": "save", "pressed": True},
                         {"frame": 64, "action": "save", "pressed": False}], 30),
                tl_item("save_slot_roundtrip", "r4b", "get_node('World').blocks.size()", 1,
                        [{"frame": 0, "action": "jump", "pressed": False}], 30),
            ]}, timeout=600.0)
        advances = 0
        while q.get("outcome") in ("pending_more", "open") and advances < 12:
            q = tool("run_verification_queue", {"command": "advance", "queue_id": q.get("queue_id", "")}, timeout=600.0)
            advances += 1
        checklist = q.get("checklist", {})
        for e in checklist.get("requirements", []):
            print(f"  [{e.get('status')}] {e.get('requirement')}")
        overall = str(checklist.get("overall", "incomplete"))
        print(f"=== BENCH CONTRACT: {overall.upper()} ===")
        check("same-prompt build contract COMPLETE", overall == "complete",
              json.dumps(q.get("items", []))[:400])

        # 2) 天梯 R2：输入延迟 = 轨迹首变帧（测试侧计算）
        lat = tool("run_verification_queue", {"command": "create", "strict": True,
            "goal": "ladder: input latency", "requirements": ["latency_measured"],
            "items": [{"kind": "behavior_check", "requirement": "latency_measured", "label": "L",
                "detail": {"scene_path": SCENE, "timeline": {
                    "events": [{"frame": 0, "action": "move_right", "pressed": True}],
                    "settle_frames": 10,
                    "sample": [{"label": "px", "expression": "get_node('Player').global_position.x"}],
                    "assertions": [{"label": "px", "expression": "get_node('Player').global_position.x",
                        "expected": 101, "operator": "gte", "description": "moved in the window"}]}}}]},
            timeout=600.0)
        advances = 0
        while lat.get("outcome") in ("pending_more", "open") and advances < 12:
            lat = tool("run_verification_queue", {"command": "advance", "queue_id": lat.get("queue_id", "")}, timeout=600.0)
        check("latency item verified", str(lat.get("checklist", {}).get("overall", "")) == "complete")
        # 汇总响应不带 evidence（既有语义）：从 store 读轨迹（L3 调试验证过的模式）。
        traj = []
        try:
            store_raw = (USER_PROJ / ".mcp" / "verification_queues.json").read_text(encoding="utf-8")
            for queue_value in json.loads(store_raw).get("queues", []):
                if "latency" in str(queue_value.get("goal", "")):
                    for item_value in queue_value.get("items", []):
                        ev = item_value.get("evidence", {}) if isinstance(item_value, dict) else {}
                        if isinstance(ev.get("trajectory", []), list) and ev.get("trajectory", []):
                            traj = ev.get("trajectory", [])
        except FileNotFoundError:
            pass
        latency_frames = None
        if traj:
            xs = [float((s.get("values", {}) or {}).get("px", 0.0)) for s in traj if isinstance(s, dict)]
            for i in range(1, len(xs)):
                if abs(xs[i] - xs[0]) > 0.5:
                    latency_frames = i
                    break
        check("latency computed from trajectory", latency_frames is not None,
              f"samples={len(traj)}")
        check("input latency <= 3 physics frames (ladder R2)", (latency_frames or 99) <= 3,
              f"measured {latency_frames} frames")
        print(f"  LADDER BASELINE: input latency = {latency_frames} frames "
              f"(~{round((latency_frames or 0) * 1000 / 60)}ms @60Hz)")

        # 3) WP2 一键天梯（真机）：movement hint 驱动，含 R1-R4 M 项与 awaiting_review
        ladder = tool("game_quality_ladder", {
            "scene_path": SCENE,
            "movement": {"action": "move_right", "node": "Player"},
            "platform": "desktop", "sample_seconds": 1.2,
            "extra_items": [
                {"requirement": "density_proxy_blocks", "rung": "r3",
                 "detail": {"timeline": {
                     "events": [{"frame": 30, "action": "place", "pressed": True},
                                {"frame": 34, "action": "place", "pressed": False}],
                     "settle_frames": 20,
                     "assertions": [{"label": "place_works",
                         "expression": "get_node('World').blocks.size()", "expected": 1,
                         "description": "interaction responds (feedback density proxy)"}]}}},
            ],
            "waivers": []}, timeout=600.0)
        rung = str(ladder.get("rung_reached", ""))
        lat_frames = int(ladder.get("ladder", {}).get("r2", {}).get("latency_frames", -1))
        print(f"  LADDER TOOL: rung_reached={rung} latency={lat_frames} frames")
        for entry in ladder.get("ladder", {}).get("r4", {}).get("a_items_awaiting_review", []):
            print(f"    [awaiting_review] {entry.get('id')}")
        check("ladder tool runs for real and reports a rung",
              rung in ("r1", "r2", "r3", "r4"), json.dumps(ladder)[:300])
        check("ladder latency matches the manual baseline (<=3)",
              1 <= lat_frames <= 3, f"latency={lat_frames}")

        # 4) 天梯豁免纪律（该游戏诚实缺省的维度）
        print("  LADDER WAIVERS: fairness=N/A (no damage source); audio=waived (no files); "
              "persistence=PROVEN (r4 cross-FRESH)")

        print("\n=== SAME-PROMPT BENCHMARK (our leg): ALL CHECKS PASSED ===")
        return 0
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=15)
        except subprocess.TimeoutExpired:
            proc.kill()
        if os.environ.get("KEEP_BENCH"):
            print("[keep] project retained at", USER_PROJ)
        else:
            shutil.rmtree(USER_PROJ, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
