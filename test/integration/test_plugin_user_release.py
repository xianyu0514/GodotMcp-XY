"""Release verification: simulate a real user who ONLY installed the plugin
(clean project, plugin copied from the repo, nothing else). Then an AI client
following the SHIPPED recipes (fetched via prompts/get, not repo scripts)
builds a playable slice and passes a requirement contract.

This is the "download plugin -> easily make games" acceptance.
"""
import json, os, random, subprocess, sys, time, urllib.request
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
USER_PROJ = REPO / ".tmp_plugin_user"
GODOT = os.environ.get("GODOT_EXE", "D:/youxi/kaifa/Godot_v4.7.2-stable_win64_console.exe")
port = random.randint(9400, 9799)
URL = f"http://127.0.0.1:{port}/mcp"
_req = [0]

def rpc(method, params=None, timeout=300):
    global _req
    _req[0] += 1
    payload = {"jsonrpc": "2.0", "id": _req[0], "method": method, "params": params or {}}
    req = urllib.request.Request(URL, data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"}, method="POST")
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read().decode())

# --- 注意力指标（M2 WP3）：游戏注意力 = 内容创作 + 验证；管道 = 发现/编排/重读 ---
CONTENT_PREFIXES = ("create_", "set_", "upsert_", "batch_", "apply_", "generate_",
                    "add_", "write_", "rename_", "attach_", "save_", "delete_",
                    "remove_", "insert_", "bump_")
VERIFY_TOOLS = {"run_verification_queue", "verify_change_effect", "play_and_verify",
                "assert_no_runtime_errors", "assert_performance_budget"}
CALLS = {"content": 0, "verify": 0, "discovery": 0}
T0 = {"v": None}

def _classify(name: str) -> str:
    if name in VERIFY_TOOLS:
        return "verify"
    if name.startswith(CONTENT_PREFIXES):
        return "content"
    return "discovery"  # enable_tools / get_* / list_* / read_* / gather_* / prompts

def tool(name, args=None, timeout=300):
    if T0["v"] is None:
        T0["v"] = time.time()
    CALLS[_classify(name)] += 1
    resp = rpc("tools/call", {"name": name, "arguments": args or {}}, timeout)
    result = resp.get("result", {})
    if result.get("isError"):
        return {"error": result["content"][0]["text"][:150]}
    text = result.get("content", [{}])[0].get("text", "")
    try:
        return json.loads(text)
    except Exception:
        return {"raw": text[:200]}

def check(label, ok, detail=""):
    print(f"  [{'OK' if ok else 'FAIL':4}] {label}" + (f": {detail}" if detail else ""))
    return ok

# Build the plugin-only user project fresh (CI has no residue): a clean
# project with ONLY addons/godot_mcp copied in — nothing else.
import shutil
if USER_PROJ.exists():
    shutil.rmtree(USER_PROJ, ignore_errors=True)
(USER_PROJ / "addons").mkdir(parents=True)
shutil.copytree(REPO / "addons" / "godot_mcp", USER_PROJ / "addons" / "godot_mcp")
(USER_PROJ / "project.godot").write_text(
    "config_version=5\n\n[application]\n\nconfig/name=\"PluginUserSim\"\n\n"
    "[editor_plugins]\n\nenabled=PackedStringArray(\"res://addons/godot_mcp/plugin.cfg\")\n",
    encoding="utf-8")

proc = subprocess.Popen([GODOT, "--editor", "--headless", "--path", str(USER_PROJ),
    "--", "--mcp-server", f"--mcp-port={port}"],
    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
try:
    deadline = time.time() + 180
    while time.time() < deadline:
        try:
            rpc("tools/list", timeout=10.0)
            break
        except Exception:
            time.sleep(1.5)
    print("=== RELEASE VERIFICATION: plugin-only user ===")

    # 1) the recipes SHIP and are fetchable
    info = tool("get_project_info")
    check("plugin runs in a clean project", info.get("project_name") == "PluginUserSim")
    prompts = rpc("prompts/list").get("result", {}).get("prompts", [])
    names = {p["name"] for p in prompts}
    check("make_game_character shipped", "make_game_character" in names)
    check("make_melee_enemy shipped", "make_melee_enemy" in names)
    recipe = rpc("prompts/get", {"name": "make_game_character",
                                 "arguments": {"goal": "knight with hit feedback"}})
    rtext = str(recipe.get("result", {}).get("messages", [{}])[0].get("content", {}).get("text", ""))
    check("recipe renders with goal", "knight" in rtext and "gather_task_context" in rtext)

    # 2) FOLLOW the shipped character recipe (atomic tools only)
    tool("enable_tools", {"tools": [
        "gather_task_context", "create_scene", "open_scene", "create_node",
        "set_node_subresource", "batch_scene_node_edits", "create_script",
        "read_script", "apply_change_set", "validate_script", "save_scene",
        "set_project_setting", "upsert_project_input_action",
        "generate_asset", "run_verification_queue", "get_scene_structure",
        "get_game_project_brief"]})
    tool("upsert_project_input_action", {"action_name": "move_left", "erase_existing": True,
        "events": [{"type": "key", "physical_keycode": 65}]})
    tool("upsert_project_input_action", {"action_name": "move_right", "erase_existing": True,
        "events": [{"type": "key", "physical_keycode": 68}]})
    SCENE = "res://scenes/player.tscn"
    SCRIPT = "res://scripts/player.gd"
    PLAYER = '''extends CharacterBody2D

const MAX_HP: int = 100
@export var move_speed: float = 260.0

var hp: int = MAX_HP
var _invuln_left: float = 0.0
var _knockback_velocity: Vector2 = Vector2.ZERO

func _physics_process(delta: float) -> void:
	if _invuln_left > 0.0:
		_invuln_left = maxf(0.0, _invuln_left - delta)
	var direction: Vector2 = Input.get_vector("move_left", "move_right", "move_up", "move_down")
	velocity = direction * move_speed + _knockback_velocity
	_knockback_velocity = _knockback_velocity.move_toward(Vector2.ZERO, delta * 900.0)
	move_and_slide()

func take_hit(damage: int, knockback: Vector2) -> void:
	if _invuln_left > 0.0:
		return
	hp = maxi(0, hp - damage)
	_invuln_left = 0.8
	_knockback_velocity = knockback
	var feedback := get_node_or_null("HitFeedback")
	if feedback:
		feedback.play_hit_feedback(knockback)
'''
    SKIN = '''extends Sprite2D
@export var idle_frames: int = 2
@export var move_frames: int = 4
@export var animation_fps: int = 8
@export var pixel_offset: Vector2 = Vector2.ZERO
var _frame_time: float = 0.0
var _frame: int = 0
var _facing_right: bool = true

func _physics_process(delta: float) -> void:
	var speed: float = get_parent().velocity.length()
	var count: int = move_frames if speed > 10.0 else idle_frames
	var row: int = 0 if speed <= 10.0 else 1
	var horizontal: float = get_parent().velocity.x
	if absf(horizontal) > 10.0:
		_facing_right = horizontal > 0.0
	_frame_time += delta
	if _frame_time >= 1.0 / maxf(animation_fps, 1.0):
		_frame_time = 0.0
		_frame = (_frame + 1) % maxi(count, 1)
	flip_h = not _facing_right
	frame_coords = Vector2i(_frame, row)
	offset = pixel_offset
'''
    FEEDBACK = '''extends Node2D
@export var flash_seconds: float = 0.22
@export var particle_amount: int = 20
@export var camera_shake_pixels: float = 6.0
@export var hitstop_seconds: float = 0.05

var last_hit_audit: Dictionary = {}

func _ready() -> void:
	var p := CPUParticles2D.new()
	p.one_shot = true
	p.amount = particle_amount
	p.lifetime = 0.4
	p.direction = Vector2(0, -1)
	p.spread = 180.0
	p.initial_velocity_min = 80.0
	p.initial_velocity_max = 180.0
	p.gravity = Vector2(0, 300)
	p.color = Color(1.0, 0.78, 0.3)
	add_child(p)
	set_meta("particles", p)

func play_hit_feedback(_knockback: Vector2 = Vector2.ZERO) -> void:
	last_hit_audit = {"flash_set": true, "flash_recovered": false,
		"hitstop_engaged": false, "hitstop_restored": false,
		"shake_magnitude": 0.0, "particles_emitted": false}
	var target: CanvasItem = get_parent().get_node_or_null("Skin")
	if target == null:
		target = get_parent() as CanvasItem
	target.modulate = Color(4, 4, 4)
	var t := create_tween()
	t.tween_property(target, "modulate", Color(1, 1, 1, 1), flash_seconds)
	t.finished.connect(func() -> void: last_hit_audit["flash_recovered"] = true)
	var p: CPUParticles2D = get_meta("particles")
	p.restart()
	last_hit_audit["particles_emitted"] = true
	_do_hitstop()
	if camera_shake_pixels > 0.0:
		var camera: Camera2D = get_viewport().get_camera_2d()
		if camera == null:
			camera = Camera2D.new()
			get_parent().add_child(camera)
		var original := camera.offset
		for i in range(5):
			camera.offset = original + Vector2(randf_range(-1, 1), randf_range(-1, 1)) * camera_shake_pixels * (1.0 - float(i) / 5.0)
			last_hit_audit["shake_magnitude"] = maxf(float(last_hit_audit["shake_magnitude"]), camera.offset.length())
			await get_tree().process_frame
			await get_tree().process_frame
		camera.offset = original
		last_hit_audit["shake_reset"] = true

func _do_hitstop() -> void:
	if hitstop_seconds <= 0.0:
		return
	Engine.time_scale = 0.05
	last_hit_audit["hitstop_engaged"] = true
	await get_tree().create_timer(hitstop_seconds, true, false, true).timeout
	Engine.time_scale = 1.0
	last_hit_audit["hitstop_restored"] = true
'''
    tool("create_scene", {"scene_path": SCENE, "root_node_type": "CharacterBody2D"})
    tool("open_scene", {"scene_path": SCENE, "allow_ui_focus": True})
    for parent, ntype, nname in [("", "ColorRect", "Body"), ("", "CollisionShape2D", "Collision"),
                                  ("", "Sprite2D", "Skin"), ("", "Node2D", "HitFeedback")]:
        tool("create_node", {"parent_path": parent, "node_type": ntype, "node_name": nname,
                             "on_name_conflict": "skip"})
    tool("set_node_subresource", {"node_path": "Collision", "property_name": "shape",
        "resource_type": "RectangleShape2D", "properties": {"size": [30, 30]}})
    c1 = tool("create_script", {"script_path": SCRIPT, "content": PLAYER})
    c2 = tool("create_script", {"script_path": "res://scripts/character_skin.gd", "content": SKIN})
    c3 = tool("create_script", {"script_path": "res://scripts/hit_feedback.gd", "content": FEEDBACK})
    check("scripts compile clean", not c1.get("has_errors") and not c2.get("has_errors") and not c3.get("has_errors"))
    tool("batch_scene_node_edits", {"operations": [
        {"type": "attach_script", "node_path": ".", "script_path": SCRIPT},
        {"type": "attach_script", "node_path": "Skin", "script_path": "res://scripts/character_skin.gd"},
        {"type": "attach_script", "node_path": "HitFeedback", "script_path": "res://scripts/hit_feedback.gd"},
        {"type": "set_property", "node_path": "Body", "property_name": "size", "property_value": [30, 30]},
        {"type": "set_property", "node_path": "Body", "property_name": "position", "property_value": [-15, -15]},
        {"type": "set_property", "node_path": "Body", "property_name": "color", "property_value": {"r": 0.35, "g": 0.75, "b": 0.95}},
    ]})
    sheet = tool("generate_asset", {"resource_path": "res://art/skin.tres", "prompt": "sheet",
        "type": "sprite", "provider": "placeholder", "pattern": "sprite_sheet",
        "width": 120, "height": 60, "frame_columns": 4, "frame_rows": 2,
        "colors": [{"r": 0.25, "g": 0.55, "b": 0.95}, {"r": 0.98, "g": 0.85, "b": 0.35}]})
    check("placeholder sheet generated", sheet.get("status") == "success")
    tool("batch_scene_node_edits", {"operations": [
        {"type": "set_property", "node_path": "Skin", "property_name": "texture",
         "property_value": "res://art/skin.tres"},
        {"type": "set_property", "node_path": "Skin", "property_name": "hframes", "property_value": 4},
        {"type": "set_property", "node_path": "Skin", "property_name": "vframes", "property_value": 2},
        {"type": "set_property", "node_path": "Skin", "property_name": "idle_frames", "property_value": 2},
        {"type": "set_property", "node_path": "Skin", "property_name": "move_frames", "property_value": 4},
        {"type": "set_property", "node_path": "Skin", "property_name": "animation_fps", "property_value": 8},
        {"type": "set_property", "node_path": "Skin", "property_name": "pixel_offset", "property_value": [-15, -15]},
    ]})
    tool("save_scene", {"scene_path": SCENE})
    tool("set_project_setting", {"setting": "application/run/main_scene", "value": SCENE, "persist": True})

    # 3) requirement contract per the recipe (each item self-contained)
    A = "get_node('HitFeedback').last_hit_audit"
    q = tool("run_verification_queue", {"command": "create", "strict": True,
        "goal": "plugin-only character contract",
        "requirements": ["movement", "flash", "shake", "hitstop", "art-present"],
        "items": [
            {"kind": "behavior_check", "requirement": "movement", "label": "r1",
             "detail": {"scene_path": SCENE, "steps": [
                 {"wait_ms": 400},
                 {"action": "move_right", "pressed": True, "wait_ms": 600,
                  "assert": {"expression": "position.x", "displacement_min": 60,
                             "description": "held key moves"}},
                 {"action": "move_right", "pressed": False, "wait_ms": 100}]}},
            {"kind": "behavior_check", "requirement": "flash", "label": "r2",
             "detail": {"scene_path": SCENE, "steps": [
                 {"wait_ms": 100,
                  "assert": {"expression": "(take_hit(10, Vector2(120, 0)) == null)", "expected": True,
                             "description": "hit lands"}},
                 {"wait_ms": 50,
                  "assert": {"expression": A + ".flash_set", "expected": True,
                             "description": "display changed"}},
                 {"wait_ms": 900,
                  "assert": {"expression": A + ".flash_recovered", "expected": True,
                             "description": "flash recovered"}}]}},
            {"kind": "behavior_check", "requirement": "shake", "label": "r3",
             "detail": {"scene_path": SCENE, "steps": [
                 {"wait_ms": 100,
                  "assert": {"expression": "(take_hit(10, Vector2(0, 0)) == null)", "expected": True,
                             "description": "hit lands"}},
                 {"wait_ms": 900,
                  "assert": {"expression": A + ".shake_magnitude", "expected": 1, "operator": "gte",
                             "description": "camera actually moved"}}]}},
            {"kind": "behavior_check", "requirement": "hitstop", "label": "r4",
             "detail": {"scene_path": SCENE, "steps": [
                 {"wait_ms": 100,
                  "assert": {"expression": "(take_hit(10, Vector2(0, 0)) == null)", "expected": True,
                             "description": "hit lands"}},
                 {"wait_ms": 900,
                  "assert": {"expression": A + ".hitstop_engaged", "expected": True,
                             "description": "time dipped"}},
                 {"wait_ms": 100,
                  "assert": {"expression": A + ".hitstop_restored", "expected": True,
                             "description": "time restored"}}]}},
            {"kind": "behavior_check", "requirement": "art-present", "label": "r5",
             "detail": {"scene_path": SCENE, "steps": [
                 {"wait_ms": 100,
                  "assert": {"expression": "get_node('Skin').texture.get_image().get_pixel(int(get_node('Skin').frame_coords.x) * 30 + 15, int(get_node('Skin').frame_coords.y) * 30 + 15).a",
                             "expected": 0.1, "operator": "gte",
                             "description": "skin frame cell has pixels"}}]}},
        ]}, timeout=600.0)
    advances = 0
    while q.get("outcome") in ("pending_more", "open") and advances < 10:
        q = tool("run_verification_queue", {"command": "advance", "queue_id": q.get("queue_id", "")}, timeout=600.0)
        advances += 1
    checklist = q.get("checklist", {})
    print("\n=== PLUGIN-ONLY DELIVERY CHECKLIST (plugin contract) ===")
    for e in checklist.get("requirements", []):
        print(f"  [{e.get('status')}] {e.get('requirement')}")
    overall = str(checklist.get("overall", "incomplete"))
    print(f"=== OVERALL: {overall.upper()} ===")
    ttfp_seconds = time.time() - T0["v"] if T0["v"] else -1
    ttfp_calls = sum(CALLS.values())

    # 会话二场景（M2 DoD）：一次调用重建上下文（TTFP 之后计量，不污染首跑）
    brief = tool("get_game_project_brief")
    brief_ok = (not brief.get("error") and isinstance(brief.get("next_sentences"), list)
                and len(brief["next_sentences"]) > 0)
    check("session-2 one-call resume (get_game_project_brief)", brief_ok,
          str(brief.get("next_sentences", brief.get("error", "")))[:120])

    total = sum(CALLS.values()) or 1
    game_calls = CALLS["content"] + CALLS["verify"]
    attention_ratio = game_calls / total
    print()
    print("=== ATTENTION METRICS (M2 WP3 baseline) ===")
    print(f"  TTFP: {ttfp_seconds:.0f}s wall, {ttfp_calls} calls (first tool -> contract {overall.upper()})")
    print(f"  calls: content={CALLS['content']} verify={CALLS['verify']} discovery(plumbing)={CALLS['discovery']}")
    print(f"  attention ratio (content+verify)/total: {attention_ratio:.2f}")
    print("  (baseline record; regression gate to follow once CI baselines exist)")
    sys.exit(0 if overall == "complete" else 1)
finally:
    proc.terminate()
    try:
        proc.wait(timeout=15)
    except subprocess.TimeoutExpired:
        proc.kill()
    shutil.rmtree(USER_PROJ, ignore_errors=True)
