"""Reusable MCP workflow: attach character visuals + hit feedback to an
EXISTING player in an existing 2D project (delivery packages 01+02 of the
character-polish plan; first target: slice_b).

One command, fully MCP-driven (every mutation is a tool call, evidence kept):

  python scripts/apply_character_visual.py slice_b [--port 9180] [--config my.json]

What it does, idempotently (re-runs UPDATE, never duplicate):
  1. Locate the declared player (scene + CharacterBody2D node). Missing
     pieces stop with a concrete report of what is absent (plan 4.1).
  2. Ensure `Skin` (Sprite2D + character_skin.gd): sheet-based idle/move
     animation, facing flip, pivot alignment. The original ColorRect body
     is KEPT and can be toggled back via `use_block_visual` (original
     version stays playable).
  3. Ensure `HitFeedback` (Node2D + hit_feedback.gd): white flash with
     auto-recovery, one-shot particles, optional camera nudge. The
     existing SoundBus SFX is NOT replayed (the player script already
     plays it — plan 02: reuse, never double-play).
  4. Generate a placeholder sprite sheet via the editor itself (procedural
     frames using the body color) when no sheet exists — reproducible,
     no binary in the repo.
  5. Wire take_hit -> HitFeedback.play_hit_feedback() through
     apply_change_set (content-hash guarded; skips when already wired).
  6. Optional: run the strict behavior regression (--with-regression).

All tunable parameters are @export on the component scripts — adjustable
later via ordinary MCP node-property calls, no re-run required.
"""

import argparse
import hashlib
import json
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]

DEFAULT_CONFIG = {
    "scene": "res://scenes/player.tscn",
    "player_node": "Player",
    "body_node": "Body",
    "sheet": "res://art/player_skin.tres",
    "frame_size": [30, 30],
    "idle_frames": 2,
    "move_frames": 4,
    "fps": 8,
    "use_block_visual": False,
    "feedback": {
        "flash_color": [4.0, 4.0, 4.0],
        "flash_seconds": 0.22,
        "particle_amount": 26,
        "camera_shake_pixels": 8.0,
        "camera_shake_seconds": 0.22,
    },
}

SKIN_SCRIPT = '''extends Sprite2D
## 角色皮肤（包01）：精灵表 idle/move 动画 + 朝向翻转 + 支点对齐。
## 由 apply_character_visual 接入；参数全部 @export，可随时经 MCP 调整。

@export var idle_frames: int = 2
@export var move_frames: int = 4
@export var animation_fps: int = 8
@export var use_block_visual: bool = false:
	set(value):
		use_block_visual = value
		_body_visible = value
		_update_visibility()
@export var pixel_offset: Vector2 = Vector2.ZERO

var _frame_time: float = 0.0
var _frame: int = 0
var _facing_right: bool = true
var _body_visible: bool = false

@onready var _body: ColorRect = get_parent().get_node_or_null("Body")


func _ready() -> void:
	_update_visibility()


func _update_visibility() -> void:
	visible = not use_block_visual
	if _body:
		_body.visible = use_block_visual or not visible


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


func is_using_block_visual() -> bool:
	return use_block_visual


func set_block_visual(value: bool) -> bool:
	use_block_visual = value
	return use_block_visual
'''

FEEDBACK_SCRIPT = '''
extends Node2D
## 受击反馈 + 自审计（包①：每项用户要求独立证据）。子效果各自记录真值，
## 任何一项的通过不再替其他项背书；断言读审计字典，免疫探针往返延迟。
## 只负责表现：伤害/无敌/音效规则留在 player.gd。

@export var flash_color: Color = Color(4.0, 4.0, 4.0)
@export var flash_seconds: float = 0.22
@export var particle_amount: int = 26
@export var camera_shake_pixels: float = 8.0
@export var camera_shake_seconds: float = 0.22
@export var hitstop_seconds: float = 0.06
@export var hitstop_scale: float = 0.05

## 最近一次受击的自审计：每项子效果的独立真值（回归逐项断言这些键）。
var last_hit_audit: Dictionary = {}

var _particles: CPUParticles2D
var _tween: Tween
var _hitstop_active: bool = false


func _ready() -> void:
	_particles = CPUParticles2D.new()
	_particles.one_shot = true
	_particles.emitting = false
	_particles.amount = particle_amount
	_particles.lifetime = 0.45
	_particles.direction = Vector2(0, -1)
	_particles.spread = 180.0
	_particles.initial_velocity_min = 90.0
	_particles.initial_velocity_max = 220.0
	_particles.gravity = Vector2(0, 320)
	_particles.scale_amount_min = 0.8
	_particles.scale_amount_max = 2.2
	_particles.color = Color(1.0, 0.78, 0.3)
	add_child(_particles)
	set_physics_process(false)


func _reset_audit() -> void:
	last_hit_audit = {
		"flash_set": false, "flash_recovered": false,
		"hitstop_engaged": false, "hitstop_restored": false,
		"hitstop_time_scale_seen": 1.0, "hitstop_restored_to": 1.0,
		"shake_magnitude": 0.0, "shake_reset": false,
		"camera_was_created": false, "camera_existed": false,
		"particles_emitted": false, "particle_amount": 0,
	}


## hitstop：引擎时间短暂拉慢（顿帧）。计时器 ignore_time_scale 保证恢复准时。
func _do_hitstop() -> void:
	if hitstop_seconds <= 0.0 or _hitstop_active:
		return
	_hitstop_active = true
	var before: float = Engine.time_scale
	Engine.time_scale = maxf(hitstop_scale, 0.01)
	last_hit_audit["hitstop_engaged"] = true
	last_hit_audit["hitstop_time_scale_seen"] = Engine.time_scale
	await get_tree().create_timer(hitstop_seconds, true, false, true).timeout
	Engine.time_scale = before
	last_hit_audit["hitstop_restored"] = true
	last_hit_audit["hitstop_restored_to"] = Engine.time_scale
	_hitstop_active = false


func play_hit_feedback(_knockback: Vector2 = Vector2.ZERO) -> void:
	_reset_audit()
	if _tween:
		_tween.kill()
	var target: CanvasItem = get_parent().get_node_or_null("Skin") as CanvasItem
	if target == null:
		target = get_parent() as CanvasItem
	target.modulate = flash_color
	last_hit_audit["flash_set"] = true
	_tween = create_tween()
	_tween.tween_property(target, "modulate", Color(1, 1, 1, 1), maxf(flash_seconds, 0.01))
	_tween.finished.connect(func() -> void:
		last_hit_audit["flash_recovered"] = true)
	_particles.amount = particle_amount
	_particles.restart()
	last_hit_audit["particles_emitted"] = true
	last_hit_audit["particle_amount"] = particle_amount
	_do_hitstop()
	# 真随机镜头震：多步随机偏移线性衰减回原位。无相机则自动补一个挂玩家上
	# ——震屏绝不静默跳过（实测教训：slice_b 地图原本没有 Camera2D）。
	if camera_shake_pixels > 0.0:
		var camera: Camera2D = get_viewport().get_camera_2d()
		last_hit_audit["camera_existed"] = camera != null
		if camera == null:
			camera = Camera2D.new()
			camera.position_smoothing_enabled = false
			get_parent().add_child(camera)
			last_hit_audit["camera_was_created"] = true
		var steps: int = maxi(int(camera_shake_seconds / 0.033), 3)
		var original_offset: Vector2 = camera.offset
		for i in range(steps):
			var falloff: float = 1.0 - float(i) / float(steps)
			camera.offset = original_offset + Vector2(
				randf_range(-1.0, 1.0), randf_range(-1.0, 1.0)) * camera_shake_pixels * falloff
			last_hit_audit["shake_magnitude"] = maxf(
				float(last_hit_audit["shake_magnitude"]), camera.offset.length())
			await get_tree().process_frame
			await get_tree().process_frame
		camera.offset = original_offset
		last_hit_audit["shake_reset"] = camera.offset == original_offset


func is_flash_active() -> bool:
	var target: CanvasItem = get_parent().get_node_or_null("Skin") as CanvasItem
	if target == null:
		target = get_parent() as CanvasItem
	return target.modulate != Color(1, 1, 1, 1)
'''

WIRE_MARKER = "feedback.play_hit_feedback(knockback)"
WIRE_OLD = '''	if SoundBus != null:
		SoundBus.play_sfx(SoundBus.SFX_HIT)'''
WIRE_NEW = '''	if SoundBus != null:
		SoundBus.play_sfx(SoundBus.SFX_HIT)
	var feedback := get_node_or_null("HitFeedback")
	if feedback:
		feedback.play_hit_feedback(knockback)'''


class Mcp:
    def __init__(self, port: int):
        self.url = f"http://127.0.0.1:{port}/mcp"
        self._id = 0

    def rpc(self, method: str, params: dict | None = None, timeout: float = 120.0) -> dict:
        self._id += 1
        payload = {"jsonrpc": "2.0", "id": self._id, "method": method, "params": params or {}}
        request = urllib.request.Request(
            self.url, data=json.dumps(payload).encode(),
            headers={"Content-Type": "application/json"}, method="POST")
        with urllib.request.urlopen(request, timeout=timeout) as response:
            body = response.read().decode()
        if not body.strip():
            raise RuntimeError(f"empty MCP response: {method}")
        return json.loads(body)

    def tool(self, name: str, args: dict | None = None, timeout: float = 120.0) -> dict:
        resp = self.rpc("tools/call", {"name": name, "arguments": args or {}}, timeout=timeout)
        result = resp.get("result", {})
        if result.get("isError"):
            raise RuntimeError(f"{name}: {result['content'][0]['text'][:300]}")
        text = result.get("content", [{}])[0].get("text", "")
        try:
            parsed = json.loads(text)
            return parsed if isinstance(parsed, dict) else {"raw": text}
        except (json.JSONDecodeError, TypeError):
            return {"raw": text}


def wait_for_server(mcp: Mcp, timeout_seconds: float = 150.0) -> None:
    deadline = time.time() + timeout_seconds
    while time.time() < deadline:
        try:
            if "result" in mcp.rpc("tools/list", timeout=10.0):
                return
        except Exception:  # noqa: BLE001
            pass
        time.sleep(1.5)
    raise SystemExit("MCP server did not answer")


def ensure_sheet(mcp: Mcp, config: dict, project: Path) -> None:
    """Sheet via the plugin's generate_asset (pattern=sprite_sheet, .tres) —
    no inline editor drawing, immediately referenceable, no repo binary."""
    if (project / config["sheet"].replace("res://", "")).exists():
        print(f"[sheet] exists: {config['sheet']}")
        return
    w, h = config["frame_size"]
    columns = max(config["idle_frames"], config["move_frames"])
    result = mcp.tool("generate_asset", {
        "resource_path": config["sheet"],
        "prompt": "player character sheet placeholder (sprite_sheet pattern)",
        "type": "sprite", "provider": "placeholder",
        "pattern": "sprite_sheet",
        "width": w * columns, "height": h * 2,
        "frame_columns": columns, "frame_rows": 2,
        "colors": [{"r": 0.25, "g": 0.55, "b": 0.95}, {"r": 0.98, "g": 0.85, "b": 0.35}],
    }, timeout=120.0)
    if result.get("status") != "success":
        raise SystemExit(f"sheet generation failed: {result}")
    print(f"[sheet] generated via generate_asset: {config['sheet']}")


def ensure_script(mcp: Mcp, path: str, content: str) -> None:
    """Create the script, or update it in place when it already exists
    (guarded full-content replace through apply_change_set)."""
    try:
        read = mcp.tool("read_script", {"script_path": path})
    except RuntimeError as exc:
        if "Failed to open file" in str(exc):
            created = mcp.tool("create_script", {"script_path": path, "content": content})
            if created.get("has_errors", False):
                raise SystemExit(f"{path} created with compile errors: {created}")
            return
        raise
    existing = str(read.get("content", ""))
    read = {"content_hash": read.get("content_hash", "")}
    if existing == content:
        return
    verdict = mcp.tool("apply_change_set", {
        "intent": "update component script in place",
        "operations": [{"path": path,
                        "expected_content_hash": read["content_hash"],
                        "edits": [{"old_text": existing, "new_text": content}]}],
        "change_set_id": "component-update-" + Path(path).name.replace(".gd", "")
                         + "-" + hashlib.sha1(content.encode()).hexdigest()[:8],
        "dry_run": False})
    if "error" in verdict:
        raise SystemExit(f"updating {path} failed: {verdict}")


def resolve_binding(mcp: Mcp, config: dict) -> dict:
    result = _resolve_binding_inner(mcp, config)
    # 仅 auto 模式从 gather 推导脚本路径；配置模式用默认（slice_b 布局）。
    if not result.get("player_script") and config.get("auto"):
        result["player_script"] = _entry_script_for(mcp, config)
    return result


def _entry_script_for(mcp: Mcp, config: dict) -> str:
    context = mcp.tool("gather_task_context", {
        "goal": f"{config.get('goal_hint', 'player character visual')} player",
        "max_items_per_bucket": 5})
    for entry in context.get("entry_scripts", []):
        return str(entry.get("path", ""))
    return ""


def _resolve_binding_inner(mcp: Mcp, config: dict) -> dict:
    """Auto-locate the player scene+node via the plugin's gather_task_context
    (scene_objects bucket) when the config does not declare them explicitly."""
    if config.get("scene") and config.get("player_node") and not config.get("auto"):
        return {"scene": config["scene"], "player_node": config["player_node"], "source": "config"}
    context = mcp.tool("gather_task_context", {
        "goal": f"{config.get('goal_hint', 'player character visual')} player",
        "max_items_per_bucket": 5})

    # 玩家源场景优先（root 即 CharacterBody2D）；实例 body 一律绑定其源场景
    # （改源场景而非地图实例覆盖 —— 地图同层的 visual 是地图 UI，不是角色的）。
    entries = context.get("scene_objects", [])
    for entry in entries:
        if entry.get("root_type") == "CharacterBody2D":
            visuals = entry.get("roles", {}).get("visual", [])
            if visuals:
                return {"scene": entry["scene"],
                        "player_node": _root_node_name(entry),
                        "body_node": visuals[0]["name"], "root_is_player": True,
                        "source": "gather_task_context"}
    for entry in entries:
        for body in entry.get("roles", {}).get("body", []):
            if body.get("type") == "CharacterBody2D" and body.get("instance_of"):
                return {"scene": body["instance_of"],
                        "player_node": body["name"],
                        "body_node": body.get("visual_node", "Body"),
                        "source": "gather_task_context"}
    # 第三种结构：每场景自带 Player 子节点（root 是 Node2D 等）——同层有
    # 视觉子节点的 CharacterBody2D 即绑定目标。
    for entry in entries:
        visuals = entry.get("roles", {}).get("visual", [])
        for body in entry.get("roles", {}).get("body", []):
            if body.get("type") == "CharacterBody2D" and visuals:
                return {"scene": entry["scene"], "player_node": body["name"],
                        "body_node": visuals[0]["name"], "source": "gather_task_context"}
    raise SystemExit("auto-locate failed: no scene with a CharacterBody2D + visual node "
                     "matched; declare scene/player_node in the config explicitly")


def _root_node_name(entry: dict) -> str:
    for role in ("body", "visual", "collision"):
        nodes = entry.get("roles", {}).get(role, [])
        if nodes and not str(nodes[0].get("path", "x")).strip("."):
            return nodes[0]["name"]
    return "Player"


def apply_workflow(mcp: Mcp, config: dict) -> dict:
    actions: list[str] = []
    binding = resolve_binding(mcp, config)
    config["scene"], config["player_node"] = binding["scene"], binding["player_node"]
    if binding.get("player_script"):
        config["player_script"] = binding["player_script"]
    config.setdefault("body_node", binding.get("body_node", "Body"))
    actions.append(f"binding resolved via {binding['source']}: "
                   f"{binding['player_node']} in {binding['scene']}")
    scene, player = config["scene"], config["player_node"]

    # 1) locate the declared objects — stop with concrete gaps otherwise.
    mcp.tool("enable_tools", {"tools": [
        "open_scene", "get_scene_structure", "list_nodes", "create_node",
        "set_node_property", "batch_scene_node_edits", "create_script",
        "read_script", "apply_change_set", "save_scene", "validate_script",
        "execute_editor_script", "upsert_project_input_action",
        "run_verification_queue", "get_scene_structure"]})
    mcp.tool("open_scene", {"scene_path": scene, "allow_ui_focus": True})
    structure = json.dumps(mcp.tool("get_scene_structure"))
    # 回归表达式自适应（配置模式同样生效）：绑定节点是场景根 → position.x，
    # 否则 get_node('<player>').position.x。
    if not binding.get("root_is_player"):
        try:
            root_node = mcp.tool("get_scene_structure").get("root_node", {})
            binding["root_is_player"] = str(root_node.get("name", "")) == player
        except Exception:
            binding["root_is_player"] = False
    # 表达式在根探测之后计算（配置模式同样受益）。
    config["movement_expression"] = "position.x" if binding.get("root_is_player", False) else         "get_node('%s').position.x" % config["player_node"]
    for needed in (player, config.get("body_node", "Body")):
        if needed not in structure:
            raise SystemExit(f"declared node missing in {scene}: {needed} "
                             "(this workflow supports declared CharacterBody2D + visual nodes)")
    actions.append(f"located {player} in {scene}")

    # 2) Skin (idempotent).
    skin_path = "res://scripts/player/character_skin.gd"
    ensure_script(mcp, skin_path, SKIN_SCRIPT)
    actions.append("skin script ensured")
    if '"Skin"' not in structure:
        mcp.tool("create_node", {"parent_path": player, "node_type": "Sprite2D",
                                 "node_name": "Skin"})
        actions.append("Skin node created")
    else:
        actions.append("Skin node already present (updated in place)")

    # 3) HitFeedback (idempotent).
    feedback_path = "res://scripts/player/hit_feedback.gd"
    ensure_script(mcp, feedback_path, FEEDBACK_SCRIPT)
    actions.append("feedback script ensured")
    if '"HitFeedback"' not in structure:
        mcp.tool("create_node", {"parent_path": player, "node_type": "Node2D",
                                 "node_name": "HitFeedback"})
        actions.append("HitFeedback node created")
    else:
        actions.append("HitFeedback node already present (updated in place)")

    # 4) parameters + texture wiring (always re-applied — this IS the update path).
    w, h = config["frame_size"]
    fb = config["feedback"]
    skin_ops = [
        {"type": "attach_script", "node_path": player + "/Skin", "script_path": skin_path},
        {"type": "set_property", "node_path": player + "/Skin", "property_name": "texture",
         "property_value": config["sheet"]},
        {"type": "set_property", "node_path": player + "/Skin", "property_name": "hframes",
         "property_value": max(max(config["idle_frames"], config["move_frames"]), 1)},
        {"type": "set_property", "node_path": player + "/Skin", "property_name": "vframes",
         "property_value": 2},
        {"type": "set_property", "node_path": player + "/Skin", "property_name": "idle_frames",
         "property_value": config["idle_frames"]},
        {"type": "set_property", "node_path": player + "/Skin", "property_name": "move_frames",
         "property_value": config["move_frames"]},
        {"type": "set_property", "node_path": player + "/Skin", "property_name": "animation_fps",
         "property_value": config["fps"]},
        {"type": "set_property", "node_path": player + "/Skin", "property_name": "use_block_visual",
         "property_value": bool(config["use_block_visual"])},
        {"type": "attach_script", "node_path": player + "/HitFeedback", "script_path": feedback_path},
        {"type": "set_property", "node_path": player + "/HitFeedback", "property_name": "flash_color",
         "property_value": {"r": fb["flash_color"][0], "g": fb["flash_color"][1], "b": fb["flash_color"][2]}},
        {"type": "set_property", "node_path": player + "/HitFeedback", "property_name": "flash_seconds",
         "property_value": fb["flash_seconds"]},
        {"type": "set_property", "node_path": player + "/HitFeedback", "property_name": "particle_amount",
         "property_value": fb["particle_amount"]},
        {"type": "set_property", "node_path": player + "/HitFeedback", "property_name": "camera_shake_pixels",
         "property_value": fb["camera_shake_pixels"]},
        {"type": "set_property", "node_path": player + "/HitFeedback", "property_name": "camera_shake_seconds",
         "property_value": fb["camera_shake_seconds"]},
    ]
    mcp.tool("batch_scene_node_edits", {"operations": skin_ops})
    actions.append("component parameters applied (@export, live-tunable)")

    # 5) wire take_hit -> feedback via guarded change set (skip when wired).
    player_script = config.get("player_script") or "res://scripts/player/player.gd"
    read = mcp.tool("read_script", {"script_path": player_script})
    content = str(read.get("content", ""))
    if WIRE_MARKER in content:
        actions.append("take_hit already wired (skipped)")
    elif WIRE_OLD not in content:
        # 结构复用（包05）：项目没有声明的伤害锚点时不硬接线——反馈组件
        # 已就位，接线点以说明交付（首次受击路径实现时一行接上）。
        actions.append("wiring anchor not found (SoundBus SFX_HIT block) — "
                       "HitFeedback attached but unwired; wire play_hit_feedback "
                       "into your damage entry point when it exists")
    else:
        verdict = mcp.tool("apply_change_set", {
            "intent": "wire hit feedback into the existing damage path",
            "operations": [{"path": player_script,
                            "expected_content_hash": read["content_hash"],
                            "edits": [{"old_text": WIRE_OLD, "new_text": WIRE_NEW}]}],
            "change_set_id": "character-hit-feedback-wiring", "dry_run": False})
        if "error" in verdict:
            raise SystemExit(f"wiring failed: {verdict}")
        actions.append("take_hit wired via apply_change_set")
    mcp.tool("validate_script", {"script_path": player_script})
    mcp.tool("save_scene", {"scene_path": scene})
    actions.append(f"scene saved: {scene}")
    return {"actions": actions}


def run_regression(mcp: Mcp, scene: str, movement_expression: str = "position.x",
                   player_script: str = "res://scripts/player/player.gd") -> dict:
    """Per-requirement regression (Package 1): every user-facing effect is
    its OWN queue item with its own assertions — one passing check can
    never stand in for another. Items gate on take_hit presence (structure
    reuse degrades explicitly and the checklist reports the gap)."""
    has_take_hit = False
    try:
        read = mcp.tool("read_script", {"script_path": player_script})
        has_take_hit = "take_hit" in str(read.get("content", ""))
    except RuntimeError:
        pass
    items = [
        {"kind": "behavior_check", "label": "requirement:movement", "detail": {
            "scene_path": scene, "steps": [
                {"wait_ms": 400},
                {"action": "move_right", "pressed": True, "wait_ms": 600,
                 "assert": {"expression": movement_expression, "displacement_min": 60,
                            "description": "held key still moves the player"}},
                {"action": "move_right", "pressed": False, "wait_ms": 100}]}}]
    if has_take_hit:
        items += [
            {"kind": "behavior_check", "label": "requirement:hitstop", "detail": {
                "scene_path": scene, "steps": [
                    {"wait_ms": 100,
                     "assert": {"expression": "(take_hit(10, Vector2(120, 0)) == null)", "expected": True,
                                "description": "hit lands"}},
                    {"wait_ms": 900,
                     "assert": {"expression": "get_node('HitFeedback').last_hit_audit.hitstop_engaged", "expected": True,
                                "description": "time_scale actually dropped during the hit"}},
                    {"wait_ms": 100,
                     "assert": {"expression": "get_node('HitFeedback').last_hit_audit.hitstop_restored", "expected": True,
                                "description": "time_scale restored after the hit"}},
                    {"wait_ms": 100,
                     "assert": {"expression": "get_node('HitFeedback').last_hit_audit.hitstop_time_scale_seen < 1.0", "expected": True,
                                "description": "the seen scale was genuinely below 1"}}]}},
            {"kind": "behavior_check", "label": "requirement:flash", "detail": {
                "scene_path": scene, "steps": [
                    {"wait_ms": 100,
                     "assert": {"expression": "(take_hit(10, Vector2(0, 0)) == null)", "expected": True,
                                "description": "hit lands"}},
                    {"wait_ms": 50,
                     "assert": {"expression": "get_node('HitFeedback').last_hit_audit.flash_set", "expected": True,
                                "description": "display object changed as expected"}},
                    {"wait_ms": 900,
                     "assert": {"expression": "get_node('HitFeedback').last_hit_audit.flash_recovered", "expected": True,
                                "description": "flash recovered afterwards"}},
                    {"wait_ms": 100,
                     "assert": {"expression": "get_node('HitFeedback').is_flash_active()", "expected": False,
                                "description": "modulate back to white"}}]}},
            {"kind": "behavior_check", "label": "requirement:shake", "detail": {
                "scene_path": scene, "steps": [
                    {"wait_ms": 100,
                     "assert": {"expression": "(take_hit(10, Vector2(0, 0)) == null)", "expected": True,
                                "description": "hit lands"}},
                    {"wait_ms": 900,
                     "assert": {"expression": "get_node('HitFeedback').last_hit_audit.shake_magnitude", "expected": 1, "operator": "gte",
                                "description": "active camera actually moved (magnitude evidence)"}},
                    {"wait_ms": 100,
                     "assert": {"expression": "get_node('HitFeedback').last_hit_audit.shake_reset", "expected": True,
                                "description": "camera offset correctly reset"}},
                    {"wait_ms": 100,
                     "assert": {"expression": "(get_viewport().get_camera_2d() != null)", "expected": True,
                                "description": "a camera exists (created when the scene had none)"}}]}},
            {"kind": "behavior_check", "label": "requirement:particles", "detail": {
                "scene_path": scene, "steps": [
                    {"wait_ms": 100,
                     "assert": {"expression": "(take_hit(10, Vector2(0, 0)) == null)", "expected": True,
                                "description": "hit lands"}},
                    {"wait_ms": 100,
                     "assert": {"expression": "get_node('HitFeedback').last_hit_audit.particles_emitted", "expected": True,
                                "description": "emission actually triggered"}},
                    {"wait_ms": 100,
                     "assert": {"expression": "get_node('HitFeedback').last_hit_audit.particle_amount", "expected": 2, "operator": "gte",
                                "description": "configured burst amount in effect"}}]}},
            {"kind": "behavior_check", "label": "requirement:respawn (twice)", "detail": {
                "scene_path": scene, "steps": [
                    {"wait_ms": 100,
                     "assert": {"expression": "(take_hit(1000, Vector2(0, 0)) == null)", "expected": True,
                                "description": "first lethal hit"}},
                    {"wait_ms": 200,
                     "assert": {"expression": "hp", "expected": 100,
                                "description": "first death: full HP after respawn"}},
                    {"wait_ms": 200,
                     "assert": {"expression": "(position == _respawn_at)", "expected": True,
                                "description": "first death: at the respawn point"}},
                    {"action": "move_right", "pressed": True, "wait_ms": 400,
                     "assert": {"expression": movement_expression, "displacement_min": 30,
                                "description": "first respawn: can still move (not stuck)"}},
                    {"action": "move_right", "pressed": False, "wait_ms": 100},
                    {"wait_ms": 100,
                     "assert": {"expression": "(take_hit(1000, Vector2(0, 0)) == null)", "expected": True,
                                "description": "second lethal hit"}},
                    {"wait_ms": 200,
                     "assert": {"expression": "hp", "expected": 100,
                                "description": "second death: full HP again"}},
                    {"wait_ms": 200,
                     "assert": {"expression": "(position == _respawn_at)", "expected": True,
                                "description": "second death: respawn point again"}}]}},
        ]
    else:
        print("[regression] player has no take_hit — hit-effect items skipped "
              "(movement verified only)")
    return mcp.tool("run_verification_queue", {
        "command": "create",
        "goal": "per-requirement regression: every user-facing effect independently evidenced",
        "strict": True,
        "watch_paths": [player_script,
                        "res://scripts/player/character_skin.gd",
                        "res://scripts/player/hit_feedback.gd"],
        "items": items}, timeout=600.0)


def _merged_items(partial: dict, final: dict) -> list:
    """inspect summaries lack the inline assertion fields; prefer the richer
    processed items from create/advance responses, fall back to inspect."""
    rich = [i for i in partial.get("items", []) if i.get("verification")]
    by_id = {i.get("id"): i for i in rich}
    merged = []
    for item in final.get("items", []):
        merged.append(by_id.get(item.get("id"), item))
    return merged


def report_checklist(regression: dict) -> int:
    """Package 3: evidence-constrained delivery checklist. Every line is
    derived from actual queue outcomes; unmet/untested requirements make
    the overall verdict NOT COMPLETE (non-zero return)."""
    print("\n=== DELIVERY CHECKLIST (evidence-constrained) ===")
    failures = 0
    for item in regression.get("items", []):
        label = str(item.get("label", "?"))
        if not label.startswith("requirement:"):
            continue
        requirement = label.split(":", 1)[1]
        status = str(item.get("status", "?"))
        if status == "passed":
            detail = "verified (%s/%s assertions)" % (
                item.get("assertions_passed", "?"), item.get("assertions_total", "?"))
        else:
            detail = "NOT MET (%s)" % status
            if item.get("first_failure"):
                detail += " — %s" % item["first_failure"]
            failures += 1
        print("  [%s] %s: %s" % (status.upper(), requirement, detail))
    untested = [r for r in ("hitstop", "flash", "shake", "particles", "respawn (twice)")
                if not any(str(i.get("label", "")) == "requirement:%s" % r
                           for i in regression.get("items", []))]
    for requirement in untested:
        print("  [UNTESTED] %s: no check ran — NOT complete" % requirement)
        failures += 1
    verdict = ("ALL REQUIREMENTS VERIFIED" if failures == 0 else
               "%d REQUIREMENT(S) WITHOUT VERIFIED EVIDENCE — OVERALL: NOT COMPLETE" % failures)
    print("=== %s ===" % verdict)
    return 1 if failures else 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("project", help="target Godot project directory (e.g. slice_b)")
    parser.add_argument("--port", default=None,
                        help="fixed port; default picks a free random port (avoids stray leftover editors)")
    parser.add_argument("--config", default=None, help="JSON file overriding defaults")
    parser.add_argument("--with-regression", action="store_true")
    parser.add_argument("--swap-sheet", nargs=2, type=int, metavar=("W", "H"),
                        help="package 05: generate and bind a different frame-size sheet")
    parser.add_argument("--auto", action="store_true",
                        help="locate the player via gather_task_context instead of the config declaration")
    parser.add_argument("--godot", default=r"D:\youxi\kaifa\Godot_v4.7.2-stable_win64_console.exe")
    args = parser.parse_args()

    project = Path(args.project).resolve()
    if not (project / "project.godot").exists():
        raise SystemExit(f"not a Godot project: {project}")
    config = json.loads(json.dumps(DEFAULT_CONFIG))
    if args.auto:
        config["auto"] = True
        config.pop("scene", None)
        config.pop("player_node", None)
    if args.config:
        override = json.loads(Path(args.config).read_text(encoding="utf-8"))
        for key, value in override.items():
            if isinstance(value, dict) and isinstance(config.get(key), dict):
                config[key].update(value)
            else:
                config[key] = value

    if not (project / "addons" / "godot_mcp" / "plugin.cfg").exists():
        subprocess.run(["powershell", "-ExecutionPolicy", "Bypass", "-File",
                        str(REPO_ROOT / "slice_b" / "setup.ps1")],
                       cwd=REPO_ROOT, check=True)

    import random as _random
    port = int(args.port) if args.port else _random.randint(9300, 9799)
    process = subprocess.Popen(
        [args.godot, "--editor", "--headless", "--path", str(project),
         "--", "--mcp-server", f"--mcp-port={port}"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        mcp = Mcp(port)
        wait_for_server(mcp)
        mcp.tool("enable_tools", {"tools": [
            "execute_editor_script", "read_script", "create_script",
            "apply_change_set", "open_scene", "get_scene_structure",
            "create_node", "batch_scene_node_edits", "save_scene",
            "validate_script", "run_verification_queue",
            "gather_task_context", "generate_asset"]})
        # 资产替换（包05）：--swap-sheet W H 生成不同尺寸新表并改绑——
        # 复用同一配方，只换素材配置；碰撞与支点由 pixel_offset 对齐语义保持。
        if args.swap_sheet:
            w, h = args.swap_sheet
            columns = max(config["idle_frames"], config["move_frames"])
            sheet_path = config["sheet"].replace(".tres", "_%dx%d.tres" % (w, h))
            result = mcp.tool("generate_asset", {
                "resource_path": sheet_path,
                "prompt": "swapped player sheet (different frame size)",
                "type": "sprite", "provider": "placeholder",
                "pattern": "sprite_sheet",
                "width": w * columns, "height": h * 2,
                "frame_columns": columns, "frame_rows": 2,
                "colors": [{"r": 0.9, "g": 0.45, "b": 0.25}, {"r": 0.2, "g": 0.95, "b": 0.6}],
            }, timeout=120.0)
            if result.get("status") != "success":
                raise SystemExit(f"swap sheet generation failed: {result}")
            config["sheet"] = sheet_path
            config["frame_size"] = [w, h]
            print(f"[swap] new {w}x{h} sheet: {sheet_path}")
        ensure_sheet(mcp, config, project)
        report = apply_workflow(mcp, config)
        for action in report["actions"]:
            print("[ok]", action)
        if args.swap_sheet:
            # 碰撞完整性（实测教训：资源类型属性必须走 set_node_subresource，
            # 换图后必须证明碰撞仍在）：运行时断言 shape 非空且尺寸未变。
            mcp.tool("enable_tools", {"tools": [
                "run_project", "install_runtime_probe",
                "evaluate_runtime_expression", "stop_project"]})
            mcp.tool("install_runtime_probe", {"node_name": "MCPRuntimeProbe", "persistent": True})
            mcp.tool("run_project", {"scene_path": config["scene"], "allow_window": True})
            import time as _t
            _t.sleep(2.0)
            shape = mcp.tool("evaluate_runtime_expression", {
                "expression": "get_node('Collision').shape.size"})
            mcp.tool("stop_project", {"allow_window": True})
            value = shape.get("value")
            size_ok = isinstance(value, dict) and value.get("x") and value.get("y")
            print(f"[integrity] collision shape after swap: {json.dumps(value)} "
                  f"{'OK' if size_ok else 'MISSING — SWAP REJECTED'}")
            if not size_ok:
                return 1
            # ART GATE（实测教训：跑步帧落在贴图外=移动时角色消失）：当前帧
            # 格子中心必须非透明——移动中运行时断言。
            mcp.tool("simulate_runtime_input_action", {"action_name": "move_right", "pressed": True})
            import time as _t2
            _t2.sleep(0.4)
            frame_size = config.get("frame_size", [32, 32])
            gate = mcp.tool("evaluate_runtime_expression", {"expression":
                "get_node('Skin').texture.get_image().get_pixel("
                "int(get_node('Skin').frame_coords.x) * %d + %d, "
                "int(get_node('Skin').frame_coords.y) * %d + %d).a > 0.0"
                % (frame_size[0], frame_size[0] // 2, frame_size[1], frame_size[1] // 2 - 2)})
            mcp.tool("simulate_runtime_input_action", {"action_name": "move_right", "pressed": False})
            art_ok = gate.get("value") is True
            print(f"[integrity] run-frame art present: {'OK' if art_ok else 'EMPTY CELL — SHEET REJECTED'}")
            if not art_ok:
                return 1
        if args.with_regression:
            regression = run_regression(mcp, config["scene"],
                movement_expression=config.get("movement_expression", "position.x"),
                player_script=config.get("player_script") or "res://scripts/player/player.gd")
            # 分片预算：推进到终态（completed/failed）才允许出清单——
            # 挂起的分片绝不冒充完成。
            advances = 0
            while regression.get("outcome") in ("pending_more", "open") and advances < 10:
                regression = mcp.tool("run_verification_queue", {
                    "command": "advance", "queue_id": regression.get("queue_id", "")},
                    timeout=600.0)
                advances += 1
            final = mcp.tool("run_verification_queue", {
                "command": "inspect", "queue_id": regression.get("queue_id", "")}, timeout=120.0)
            final.setdefault("items", [])
            final["items"] = _merged_items(regression, final)
            print("regression:", final.get("outcome"),
                  "passed:", final.get("passed_count"),
                  "failed:", final.get("failed_count"))
            checklist_code = report_checklist(final)
            if final.get("outcome") != "completed":
                return 1
            if checklist_code != 0:
                return checklist_code
        print("CHARACTER VISUAL + FEEDBACK APPLIED (idempotent; re-run updates)")
        return 0
    finally:
        process.terminate()
        try:
            process.wait(timeout=15)
        except subprocess.TimeoutExpired:
            process.kill()


if __name__ == "__main__":
    sys.exit(main())
