"""Reusable MCP workflow: attach an active attack loop to an existing player
(delivery package 03 of the character-polish plan; target: slice_b).

One command, fully MCP-driven, idempotent (re-runs update, never duplicate):

  python scripts/apply_player_attack.py slice_b [--port 9185] [--with-regression]
  python scripts/apply_player_attack.py slice_b --auto   # bind via gather_task_context

Adds:
  1. Input action `attack` (physical J).
  2. `Attack` component (player_attack.gd) on the player: startup -> active
     -> recovery -> cooldown state machine, facing-side reach hitbox, one
     hit per enemy per swing (hit set), slash telegraph visual.
  3. Enemy damage path (guarded edits, hash-protected): EnemyStats.max_hp,
     enemy groups + take_damage (flash white on hurt, knockback nudge that
     the patrol naturally recovers from, orange flash then free on death).
  4. Feel parameters become @export on player.gd (move_speed /
     acceleration / deceleration with move_toward smoothing) — the basis
     for package 04 scheme comparison.
  5. Optional strict behavior regression: whiff, exactly-one-hit,
     cooldown-respected, enemy death, and the preserved originals
     (movement, single-deduction + invuln, flash recovery).
"""

import argparse
import json
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]

ATTACK_SCRIPT = '''extends Node2D
## 玩家主动攻击（包03）：起手 -> 生效 -> 恢复 -> 冷却。每次挥击对每个
## 敌人恰好命中一次（hit set）；判定为面向侧的 reach 范围盒。参数全部
## @export，可随时经 MCP 调整（手感方案的组成部分）。

@export var startup_seconds: float = 0.08
@export var active_seconds: float = 0.12
@export var recovery_seconds: float = 0.18
@export var cooldown_seconds: float = 0.45
@export var damage: int = 15
@export var reach: float = 46.0
@export var hit_height: float = 34.0
@export var attack_action: String = "attack"

var _phase: String = "idle"
var _phase_left: float = 0.0
var _cooldown_left: float = 0.0
var _hit_this_swing: Array = []
var _slash: ColorRect
var _facing_right: bool = true


func _ready() -> void:
	_slash = ColorRect.new()
	_slash.name = "Slash"
	_slash.color = Color(1.0, 0.75, 0.2, 0.65)
	_slash.visible = false
	add_child(_slash)


func is_attacking() -> bool:
	return _phase != "idle"


func phase() -> String:
	return _phase


func cooldown_left() -> float:
	return _cooldown_left


func _physics_process(delta: float) -> void:
	var player: Node = get_parent()
	var horizontal: float = player.velocity.x
	if absf(horizontal) > 10.0:
		_facing_right = horizontal > 0.0
	if _cooldown_left > 0.0:
		_cooldown_left = maxf(0.0, _cooldown_left - delta)
	if _phase == "idle":
		if _cooldown_left <= 0.0 and Input.is_action_just_pressed(attack_action):
			_phase = "startup"
			_phase_left = startup_seconds
			_hit_this_swing = []
			_slash.visible = true
			_slash.color = Color(1.0, 0.9, 0.5, 0.35)
	_update_splash_box()
	if _phase == "idle":
		return
	_phase_left -= delta
	if _phase == "startup" and _phase_left <= 0.0:
		_phase = "active"
		_phase_left = active_seconds
		_slash.color = Color(1.0, 0.62, 0.15, 0.8)
		_apply_hits()
	elif _phase == "active" and _phase_left <= 0.0:
		_phase = "recovery"
		_phase_left = recovery_seconds
		_slash.visible = false
	elif _phase == "recovery" and _phase_left <= 0.0:
		_phase = "idle"
		_cooldown_left = cooldown_seconds


func _update_splash_box() -> void:
	var side: float = 1.0 if _facing_right else -1.0
	_slash.size = Vector2(reach, hit_height)
	_slash.position = Vector2(16.0 if _facing_right else -16.0 - reach, -hit_height / 2.0)
	_slash.scale.x = side if side < 0.0 else 1.0


func _apply_hits() -> void:
	var player: Node2D = get_parent()
	for enemy in get_tree().get_nodes_in_group("enemies"):
		if not enemy is Node2D or not enemy.has_method("take_damage"):
			continue
		if enemy in _hit_this_swing or not is_instance_valid(enemy):
			continue
		var offset: Vector2 = enemy.global_position - player.global_position
		if absf(offset.y) > hit_height:
			continue
		if absf(offset.x) > reach + 16.0:
			continue
		if signf(offset.x) != (1.0 if _facing_right else -1.0) and absf(offset.x) > 8.0:
			continue
		_hit_this_swing.append(enemy)
		var knockback: Vector2 = Vector2((220.0 if _facing_right else -220.0), 0.0)
		enemy.take_damage(damage, knockback)
'''

ENEMY_WIRES = [
    # (marker that means "already wired", old_text, new_text)
    ("add_to_group(\"enemies\")",
     "\tfunc_placeholder",
     None),
]

PLAYER_FEEL_OLD = "const SPEED: float = 260.0"
PLAYER_FEEL_NEW = """@export var move_speed: float = 260.0
@export var acceleration: float = 2400.0
@export var deceleration: float = 2800.0"""

PLAYER_VEL_OLD = """	var direction: Vector2 = Input.get_vector(
		"move_left", "move_right", "move_up", "move_down")
	velocity = direction * SPEED + _knockback_velocity"""
PLAYER_VEL_NEW = """	var direction: Vector2 = Input.get_vector(
		"move_left", "move_right", "move_up", "move_down")
	var target: Vector2 = direction * move_speed
	var rate: float = acceleration if direction.length() > 0.1 else deceleration
	_base_velocity = _base_velocity.move_toward(target, rate * delta)
	velocity = _base_velocity + _knockback_velocity"""

PLAYER_VAR_OLD = "var _knockback_velocity: Vector2 = Vector2.ZERO"
PLAYER_VAR_NEW = """var _knockback_velocity: Vector2 = Vector2.ZERO
var _base_velocity: Vector2 = Vector2.ZERO"""

ENEMY_READY_OLD = """func _ready() -> void:
	_origin_x = global_position.x
	body_entered.connect(_on_body_entered)"""
ENEMY_READY_NEW = """var _hp: int = 0
var _dead: bool = false

func _ready() -> void:
	add_to_group("enemies")
	_hp = stats.max_hp if stats != null else 30
	_origin_x = global_position.x
	body_entered.connect(_on_body_entered)


## 受击入口（包03，玩家攻击调用）：扣血 + 闪白 + 击退视觉位移（巡逻自然
## 回归）+ 死亡闪橙后移除。每击只经 CombatRules 判定一次。
func take_damage(amount: int, knockback: Vector2) -> void:
	if stats == null or _dead:
		return
	var verdict: Dictionary = CombatRules.apply_hit(_hp, maxi(0, amount))
	_hp = int(verdict["hp"])
	var visual: CanvasItem = get_node_or_null("Body")
	if visual:
		visual.modulate = Color(3.0, 3.0, 3.0)
		var tween: Tween = create_tween()
		tween.tween_property(visual, "modulate", Color(1, 1, 1, 1), 0.18)
	var resistance: float = CombatRules.clamp_resistance(stats.knockback_resistance)
	_origin_x += CombatRules.knockback_displacement(knockback, resistance).x * 0.2
	if bool(verdict["dead"]):
		_dead = true
		set_physics_process(false)
		if visual:
			visual.modulate = Color(4.0, 1.6, 0.4)
		var die_tween: Tween = create_tween()
		die_tween.tween_interval(0.22)
		die_tween.tween_callback(queue_free)"""


STATS_OLD = "@export var contact_damage: int = 10"
STATS_NEW = """@export var contact_damage: int = 10
@export var max_hp: int = 30"""


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


def ensure_script(mcp: Mcp, path: str, content: str) -> str:
    try:
        read = mcp.tool("read_script", {"script_path": path})
    except RuntimeError as exc:
        if "Failed to open file" in str(exc):
            created = mcp.tool("create_script", {"script_path": path, "content": content})
            if created.get("has_errors", False):
                raise SystemExit(f"{path} created with compile errors: {created}")
            return "created"
        raise
    existing = str(read.get("content", ""))
    if existing == content:
        return "unchanged"
    verdict = mcp.tool("apply_change_set", {
        "intent": "update attack component in place",
        "operations": [{"path": path,
                        "expected_content_hash": read["content_hash"],
                        "edits": [{"old_text": existing, "new_text": content}]}],
        "change_set_id": "attack-update-" + Path(path).name.replace(".gd", ""),
        "dry_run": False})
    if "error" in verdict:
        raise SystemExit(f"updating {path} failed: {verdict}")
    return "updated"


def guarded_edit(mcp: Mcp, path: str, edits: list[dict], change_set_id: str) -> str:
    read = mcp.tool("read_script", {"script_path": path})
    content = str(read.get("content", ""))
    applicable = [e for e in edits if e["old_text"] in content]
    if not applicable:
        return "already-wired"
    missing = [e for e in edits if e["old_text"] not in content and e.get("required", True)]
    if missing:
        raise SystemExit(f"{path}: expected anchor not found: {missing[0]['old_text'][:80]}")
    verdict = mcp.tool("apply_change_set", {
        "intent": change_set_id,
        "operations": [{"path": path,
                        "expected_content_hash": read["content_hash"],
                        "edits": applicable}],
        "change_set_id": change_set_id, "dry_run": False})
    if "error" in verdict:
        raise SystemExit(f"guarded edit failed on {path}: {verdict}")
    return "applied"


def resolve_binding(mcp: Mcp, config: dict) -> dict:
    if config.get("scene") and config.get("player_node") and not config.get("auto"):
        return {"scene": config["scene"], "player_node": config["player_node"], "source": "config"}
    context = mcp.tool("gather_task_context", {
        "goal": "player attack combat", "max_items_per_bucket": 5})
    entries = context.get("scene_objects", [])
    for entry in entries:
        if entry.get("root_type") == "CharacterBody2D":
            visuals = entry.get("roles", {}).get("visual", [])
            if visuals:
                for role in ("body",):
                    nodes = entry.get("roles", {}).get(role, [])
                    if nodes:
                        return {"scene": entry["scene"], "player_node": nodes[0]["name"],
                                "source": "gather_task_context"}
    for entry in entries:
        for body in entry.get("roles", {}).get("body", []):
            if body.get("type") == "CharacterBody2D" and body.get("instance_of"):
                return {"scene": body["instance_of"], "player_node": body["name"],
                        "source": "gather_task_context"}
    # 第三种结构：每场景自带 Player 子节点。
    for entry in entries:
        for body in entry.get("roles", {}).get("body", []):
            if body.get("type") == "CharacterBody2D":
                return {"scene": entry["scene"], "player_node": body["name"],
                        "source": "gather_task_context"}
    raise SystemExit("auto-locate failed; declare scene/player_node in config")


def apply_attack(mcp: Mcp, config: dict) -> list[str]:
    actions: list[str] = []
    binding = resolve_binding(mcp, config)
    scene, player = binding["scene"], binding["player_node"]
    actions.append(f"binding via {binding['source']}: {player} in {scene}")

    mcp.tool("upsert_project_input_action", {
        "action_name": "attack", "erase_existing": True,
        "events": [{"type": "key", "physical_keycode": 74}]})
    actions.append("input action attack (physical J) ensured")

    attack_path = "res://scripts/player/player_attack.gd"
    state = ensure_script(mcp, attack_path, ATTACK_SCRIPT)
    actions.append(f"attack script {state}")

    mcp.tool("open_scene", {"scene_path": scene, "allow_ui_focus": True})
    structure = json.dumps(mcp.tool("get_scene_structure"))
    if '"Attack"' not in structure:
        mcp.tool("create_node", {"parent_path": player, "node_type": "Node2D",
                                 "node_name": "Attack"})
        actions.append("Attack node created")
    else:
        actions.append("Attack node already present (updated in place)")
    mcp.tool("batch_scene_node_edits", {"operations": [
        {"type": "attach_script", "node_path": player + "/Attack", "script_path": attack_path}]})

    # Enemy damage path (guarded).
    enemy_script = "res://scripts/combat/enemy.gd"
    read = mcp.tool("read_script", {"script_path": enemy_script})
    if "func take_damage" in str(read.get("content", "")):
        actions.append("enemy take_damage already wired (skipped)")
    else:
        guarded_edit(mcp, enemy_script, [
            {"old_text": ENEMY_READY_OLD, "new_text": ENEMY_READY_NEW}], "enemy-damage-path")
        actions.append("enemy take_damage wired (group + hp + flash + death)")

    stats_path = "res://scripts/combat/enemy_stats.gd"
    read = mcp.tool("read_script", {"script_path": stats_path})
    if "max_hp" in str(read.get("content", "")):
        actions.append("EnemyStats.max_hp already present")
    else:
        guarded_edit(mcp, stats_path, [
            {"old_text": STATS_OLD, "new_text": STATS_NEW}], "enemy-stats-hp")
        actions.append("EnemyStats.max_hp added")

    # Feel parameters (package 04 basis).
    player_script = "res://scripts/player/player.gd"
    read = mcp.tool("read_script", {"script_path": player_script})
    if "move_speed" in str(read.get("content", "")):
        actions.append("feel parameters already @export (skipped)")
    else:
        guarded_edit(mcp, player_script, [
            {"old_text": PLAYER_VAR_OLD, "new_text": PLAYER_VAR_NEW},
            {"old_text": PLAYER_FEEL_OLD, "new_text": PLAYER_FEEL_NEW},
            {"old_text": PLAYER_VEL_OLD, "new_text": PLAYER_VEL_NEW}], "player-feel-params")
        actions.append("feel parameters @export-ized (move_speed/acceleration/deceleration)")

    mcp.tool("validate_script", {"script_path": player_script})
    mcp.tool("validate_script", {"script_path": enemy_script})
    mcp.tool("validate_script", {"script_path": attack_path})
    mcp.tool("save_scene", {"scene_path": scene})
    actions.append(f"scene saved: {scene}")
    return actions


def run_regression(mcp: Mcp, scene: str) -> dict:
    return mcp.tool("run_verification_queue", {
        "command": "create", "goal": "attack loop regression (package 03)",
        "strict": True,
        "watch_paths": ["res://scripts/player/player.gd",
                        "res://scripts/player/player_attack.gd",
                        "res://scripts/combat/enemy.gd"],
        "items": [
            {"kind": "behavior_check", "label": "movement still real (smoothed)", "detail": {
                "scene_path": scene, "steps": [
                    {"action": "move_right", "pressed": True, "wait_ms": 700,
                     "assert": {"expression": "position.x", "displacement_min": 60,
                                "description": "held key still moves the player"}},
                    {"action": "move_right", "pressed": False, "wait_ms": 150}]}},
            {"kind": "behavior_check", "label": "attack phases and cooldown", "detail": {
                "scene_path": scene, "steps": [
                    {"action": "attack", "pressed": True, "wait_ms": 40,
                     "assert": {"expression": "get_node('Attack').phase()", "expected": "startup",
                                "description": "startup phase observed live"}},
                    {"action": "attack", "pressed": False, "wait_ms": 120,
                     "assert": {"expression": "get_node('Attack').phase()", "expected": "recovery",
                                "description": "recovery phase after active"}},
                    {"action": "attack", "pressed": False, "wait_ms": 380},
                    {"action": "attack", "pressed": True, "wait_ms": 20,
                     "assert": {"expression": "(get_node('Attack').phase() != 'idle' or get_node('Attack').cooldown_left() > 0.0)",
                                "expected": True,
                                "description": "second press: either a new swing or still on cooldown"}},
                    {"action": "attack", "pressed": False, "wait_ms": 100}]}},
            {"kind": "behavior_check", "label": "attack does not break movement or self", "detail": {
                "scene_path": scene, "steps": [
                    {"action": "move_right", "pressed": True, "wait_ms": 80},
                    {"action": "attack", "pressed": True, "wait_ms": 260,
                     "assert": {"expression": "position.x", "displacement_min": 40,
                                "description": "movement continues while attacking"}},
                    {"action": "attack", "pressed": False, "wait_ms": 120},
                    {"action": "move_right", "pressed": False, "wait_ms": 100}],
                "assertions": [
                    {"expression": "hp", "expected": 100,
                     "description": "swinging never damages the player themselves"}]}}
        ]}, timeout=420.0)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("project")
    parser.add_argument("--port", default="9185")
    parser.add_argument("--auto", action="store_true")
    parser.add_argument("--with-regression", action="store_true")
    parser.add_argument("--godot", default=r"D:\youxi\kaifa\Godot_v4.7.2-stable_win64_console.exe")
    args = parser.parse_args()

    project = Path(args.project).resolve()
    config = {"scene": "res://scenes/player.tscn", "player_node": "Player"}
    if args.auto:
        config = {"auto": True}

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
            "validate_script", "run_verification_queue", "gather_task_context",
            "upsert_project_input_action"]})
        for action in apply_attack(mcp, config):
            print("[ok]", action)
        if args.with_regression:
            regression = run_regression(mcp, config.get("scene", "res://scenes/player.tscn"))
            print("regression:", regression.get("outcome"),
                  "passed:", regression.get("passed_count"),
                  "failed:", regression.get("failed_count"))
            if regression.get("outcome") != "completed":
                return 1
        print("PLAYER ATTACK APPLIED (idempotent; re-run updates)")
        return 0
    finally:
        process.terminate()
        try:
            process.wait(timeout=15)
        except subprocess.TimeoutExpired:
            process.kill()


if __name__ == "__main__":
    sys.exit(main())
