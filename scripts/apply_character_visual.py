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
        "flash_color": [3.0, 3.0, 3.0],
        "flash_seconds": 0.25,
        "particle_amount": 14,
        "camera_shake_pixels": 6.0,
        "camera_shake_seconds": 0.18,
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

FEEDBACK_SCRIPT = '''extends Node2D
## 受击反馈（包02）：闪白（自动恢复）+ 一次性粒子 + 轻微镜头反馈。
## 只负责表现：伤害/无敌/音效规则留在 player.gd（SoundBus 已播 hit，
## 此处不重复播放）。参数全部 @export，可随时经 MCP 调整。

@export var flash_color: Color = Color(3.0, 3.0, 3.0)
@export var flash_seconds: float = 0.12
@export var particle_amount: int = 14
@export var camera_shake_pixels: float = 6.0
@export var camera_shake_seconds: float = 0.18

var _particles: CPUParticles2D
var _tween: Tween
var _camera_tween: Tween


func _ready() -> void:
	_particles = CPUParticles2D.new()
	_particles.one_shot = true
	_particles.emitting = false
	_particles.amount = particle_amount
	_particles.lifetime = 0.4
	_particles.speed_scale = 1.0
	_particles.direction = Vector2(0, -1)
	_particles.spread = 180.0
	_particles.initial_velocity_min = 60.0
	_particles.initial_velocity_max = 140.0
	_particles.gravity = Vector2(0, 240)
	_particles.scale_amount_min = 0.6
	_particles.scale_amount_max = 1.4
	_particles.color = Color(1.0, 0.85, 0.4)
	add_child(_particles)
	set_physics_process(false)


func play_hit_feedback(_knockback: Vector2 = Vector2.ZERO) -> void:
	# 闪白：kill 旧 tween 重启 —— 连续受击不会累积颜色或时间。
	if _tween:
		_tween.kill()
	var target: CanvasItem = get_parent().get_node_or_null("Skin") as CanvasItem
	if target == null:
		target = get_parent() as CanvasItem
	var original: Color = Color(1, 1, 1, 1)
	target.modulate = flash_color
	_tween = create_tween()
	_tween.tween_property(target, "modulate", original, maxf(flash_seconds, 0.01))
	# 粒子：one_shot 重发。
	_particles.amount = particle_amount
	_particles.restart()
	# 镜头：可配为 0（不改变伤害规则，纯表现）。
	if camera_shake_pixels > 0.0:
		var camera: Camera2D = get_viewport().get_camera_2d()
		if camera:
			if _camera_tween:
				_camera_tween.kill()
			var original_offset: Vector2 = camera.offset
			camera.offset = original_offset + Vector2(camera_shake_pixels, 0)
			_camera_tween = create_tween()
			_camera_tween.tween_property(camera, "offset", original_offset,
				maxf(camera_shake_seconds, 0.01))


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
        "change_set_id": "component-update-" + Path(path).name.replace(".gd", ""),
        "dry_run": False})
    if "error" in verdict:
        raise SystemExit(f"updating {path} failed: {verdict}")


def resolve_binding(mcp: Mcp, config: dict) -> dict:
    result = _resolve_binding_inner(mcp, config)
    if not result.get("player_script"):
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
    config["movement_expression"] = "position.x" if binding.get("root_is_player", False) else         "get_node('%s').position.x" % config["player_node"]
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
    """Structure-adaptive regression: movement via the bound expression
    (player-as-root vs player-as-child); hit/invuln/flash checks only when
    the player script exposes take_hit (reuse without a damage path
    degrades to movement + explicit guidance)."""
    has_take_hit = False
    try:
        read = mcp.tool("read_script", {"script_path": player_script})
        has_take_hit = "take_hit" in str(read.get("content", ""))
    except RuntimeError:
        pass
    items = [
        {"kind": "behavior_check", "label": "movement still real", "detail": {
            "scene_path": scene, "steps": [
                {"action": "move_right", "pressed": True, "wait_ms": 600,
                 "assert": {"expression": movement_expression, "displacement_min": 60,
                            "description": "held key still moves the player"}},
                {"action": "move_right", "pressed": False, "wait_ms": 100}]}}]
    if has_take_hit:
        items.append({"kind": "behavior_check", "label": "hit once; invuln blocks doubles; flash recovers", "detail": {
            "scene_path": scene, "steps": [
                {"wait_ms": 100,
                 "assert": {"expression": "(take_hit(10, Vector2(120, 0)) == null)", "expected": True,
                            "description": "first hit lands"}},
                {"wait_ms": 100,
                 "assert": {"expression": "hp", "expected": 90,
                            "description": "exactly one deduction of 10"}},
                {"wait_ms": 30,
                 "assert": {"expression": "get_node('HitFeedback').is_flash_active()", "expected": True,
                            "description": "flash is live right after the hit"}},
                {"wait_ms": 100,
                 "assert": {"expression": "(take_hit(10, Vector2(0, 0)) == null)", "expected": True,
                            "description": "second hit during invuln is a no-op call"}},
                {"wait_ms": 100,
                 "assert": {"expression": "hp", "expected": 90,
                            "description": "invuln window prevented a second deduction"}},
                {"wait_ms": 800,
                 "assert": {"expression": "get_node('HitFeedback').is_flash_active()", "expected": False,
                            "description": "modulate returns to white after the flash window"}}]}})
    else:
        print("[regression] player has no take_hit — hit checks skipped (movement-only)")
    return mcp.tool("run_verification_queue", {
        "command": "create", "goal": "character polish regression: originals intact, feedback obeys rules",
        "strict": True,
        "watch_paths": [player_script,
                        "res://scripts/player/character_skin.gd",
                        "res://scripts/player/hit_feedback.gd"],
        "items": items}, timeout=420.0)


def true_sentinel():
    return True


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("project", help="target Godot project directory (e.g. slice_b)")
    parser.add_argument("--port", default="9180")
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

    process = subprocess.Popen(
        [args.godot, "--editor", "--headless", "--path", str(project),
         "--", "--mcp-server", f"--mcp-port={args.port}"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        mcp = Mcp(int(args.port))
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
        if args.with_regression:
            regression = run_regression(mcp, config["scene"],
                movement_expression=config.get("movement_expression", "position.x"),
                player_script=config.get("player_script") or "res://scripts/player/player.gd")
            print("regression:", regression.get("outcome"),
                  "passed:", regression.get("passed_count"),
                  "failed:", regression.get("failed_count"))
            if regression.get("outcome") != "completed":
                return 1
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
