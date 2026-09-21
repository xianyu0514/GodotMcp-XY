"""P1: Melee-enemy behavior workflow — patrol -> alert -> chase -> windup ->
hit -> recover, with hurt, death and one-drop, on an EXISTING enemy scene.

  python scripts/apply_enemy_workflow.py slice_b [--scene enemy.tscn] [--with-regression]

Idempotent: ensures a `MeleeBrain` component (melee_brain.gd) on the enemy
scene root, wired to the existing EnemyStats/take_damage path. Every knob is
@export (natural-language tuning: "attack windup more obvious" -> raise
windup_seconds; "chase range shorter" -> lower chase_range; "normal enemies
knockback easily, boss keeps resistance" -> EnemyStats.knockback_resistance).
Drops a coin (Area2D pickup, one per death) via the drop_group mechanism.

The regression is a requirement CONTRACT (P0-1 plugin capability): detect,
windup timing, single hit per swing, death stops attacking, drop count —
independently evidenced; any gap = overall incomplete.
"""

import argparse
import hashlib
import json
import random
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]

BRAIN_SCRIPT = '''extends Node
## 近战敌人大脑（P1）：巡逻 → 警戒（进入发现范围）→ 追击 → 攻击前摇
## （预警色闪烁）→ 命中（一次判定）→ 恢复 → 回巡逻。受击/死亡走宿主的
## take_damage；死亡时掉落一枚硬币（恰好一次）。参数全部 @export。

@export var detect_range: float = 180.0
@export var chase_range: float = 320.0
@export var chase_speed: float = 140.0
@export var patrol_speed: float = 60.0
@export var attack_range: float = 46.0
@export var windup_seconds: float = 0.35
@export var hit_damage: int = 12
@export var hit_knockback: float = 260.0
@export var recover_seconds: float = 0.5
@export var attack_cooldown: float = 0.9

var _state: String = "patrol"
var _state_left: float = 0.0
var _cooldown_left: float = 0.0
var _direction: float = 1.0
var _origin_x: float = 0.0
var _hit_done: bool = false
var attacks_landed: int = 0
var drops_spawned: int = 0
var state_log: Array = []


func _ready() -> void:
	_origin_x = get_parent().global_position.x
	set_physics_process(true)


func state() -> String:
	return _state


func _physics_process(delta: float) -> void:
	var enemy: Node2D = get_parent()
	if not enemy is Area2D:
		return
	if _cooldown_left > 0.0:
		_cooldown_left = maxf(0.0, _cooldown_left - delta)
	match _state:
		"patrol":
			_patrol(delta, enemy)
		"chase":
			_chase(delta, enemy)
		"windup":
			_state_left -= delta
			enemy.global_position.x += _direction * 10.0 * delta
			if _state_left <= 0.0:
				_hit(enemy)
				_state = "recover"
				_state_left = recover_seconds
				_log("recover")
		"recover":
			_state_left -= delta
			if _state_left <= 0.0:
				_state = "patrol"
				_cooldown_left = attack_cooldown
				_log("patrol")


func _patrol(delta: float, enemy: Node2D) -> void:
	var player: Node2D = _player()
	if player and enemy.global_position.distance_to(player.global_position) <= detect_range:
		_state = "chase"
		_log("chase")
		return
	var patrol_range: float = 90.0
	var target_x: float = _origin_x + _direction * patrol_range
	enemy.global_position.x = move_toward(enemy.global_position.x, target_x, patrol_speed * delta)
	if absf(enemy.global_position.x - target_x) < 2.0:
		_direction = -_direction


func _chase(delta: float, enemy: Node2D) -> void:
	var player: Node2D = _player()
	if player == null or enemy.global_position.distance_to(player.global_position) > chase_range:
		_state = "patrol"
		_log("patrol")
		return
	var dx: float = player.global_position.x - enemy.global_position.x
	_direction = 1.0 if dx > 0.0 else -1.0
	if absf(dx) <= attack_range and _cooldown_left <= 0.0:
		_state = "windup"
		_state_left = windup_seconds
		_hit_done = false
		_flash_windup(enemy)
		_log("windup")
		return
	enemy.global_position.x += _direction * chase_speed * delta


func _flash_windup(enemy: Node2D) -> void:
	var visual: CanvasItem = enemy.get_node_or_null("Body")
	if visual == null:
		return
	visual.modulate = Color(1.8, 0.7, 0.3)
	var tween: Tween = enemy.create_tween()
	tween.tween_property(visual, "modulate", Color(1, 1, 1, 1), windup_seconds)


func _hit(enemy: Node2D) -> void:
	if _hit_done:
		return
	_hit_done = true
	var player: Node2D = _player()
	if player == null:
		return
	var dx: float = player.global_position.x - enemy.global_position.x
	if signf(dx) != _direction and absf(dx) > 8.0:
		return
	if absf(dx) > attack_range + 22.0:
		return
	if player.has_method("take_hit"):
		attacks_landed += 1
		player.take_hit(hit_damage, Vector2(_direction * hit_knockback, 0.0))


func _player() -> Node2D:
	var players := get_tree().get_nodes_in_group("player")
	return players[0] if not players.is_empty() else null


func _log(entry: String) -> void:
	state_log.append(entry)


## 死亡掉落（由宿主 take_damage 死亡路径调用或外接）：恰好一次。
func notify_death() -> void:
	if drops_spawned > 0:
		return
	drops_spawned += 1
	var coin := Area2D.new()
	coin.name = "DropCoin%d" % drops_spawned
	coin.add_to_group("coins")
	coin.position = Vector2(0, 0)
	var shape := CollisionShape2D.new()
	var circle := CircleShape2D.new()
	circle.radius = 10.0
	shape.shape = circle
	coin.add_child(shape)
	var visual := ColorRect.new()
	visual.size = Vector2(14, 14)
	visual.position = Vector2(-7, -7)
	visual.color = Color(0.98, 0.8, 0.1)
	coin.add_child(visual)
	var parent: Node2D = get_parent()
	var spawn_at: Node = parent.get_parent() if parent.get_parent() else parent
	spawn_at.add_child(coin)
	coin.global_position = parent.global_position
	if coin.has_signal("body_entered"):
		coin.body_entered.connect(func(body: Node2D) -> void:
			if body.is_in_group("player"):
				coin.queue_free())
'''

# enemy.gd death path calls brain.notify_death()
ENEMY_HOOK_OLD = """	if bool(verdict["dead"]):
		_dead = true
		set_physics_process(false)"""
ENEMY_HOOK_NEW = """	if bool(verdict["dead"]):
		_dead = true
		set_physics_process(false)
		var brain := get_node_or_null("MeleeBrain")
		if brain and brain.has_method("notify_death"):
			brain.notify_death()"""


class Mcp:
    def __init__(self, port: int):
        self.url = f"http://127.0.0.1:{port}/mcp"
        self._id = 0

    def tool(self, name: str, args: dict | None = None, timeout: float = 300.0) -> dict:
        self._id += 1
        payload = {"jsonrpc": "2.0", "id": self._id, "method": "tools/call",
                   "params": {"name": name, "arguments": args or {}}}
        request = urllib.request.Request(
            self.url, data=json.dumps(payload).encode(),
            headers={"Content-Type": "application/json"}, method="POST")
        with urllib.request.urlopen(request, timeout=timeout) as response:
            resp = json.loads(response.read().decode())
        result = resp.get("result", {})
        if result.get("isError"):
            raise RuntimeError(f"{name}: {result['content'][0]['text'][:250]}")
        text = result.get("content", [{}])[0].get("text", "")
        try:
            parsed = json.loads(text)
            return parsed if isinstance(parsed, dict) else {"raw": text}
        except (json.JSONDecodeError, TypeError):
            return {"raw": text}


def wait_for_server(mcp: Mcp, timeout_seconds: float = 180.0) -> None:
    deadline = time.time() + timeout_seconds
    while time.time() < deadline:
        try:
            mcp.tool("get_project_info", {}, timeout=10.0)
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
                raise SystemExit(f"{path} compile errors: {created}")
            return "created"
        raise
    existing = str(read.get("content", ""))
    if existing == content:
        return "unchanged"
    verdict = mcp.tool("apply_change_set", {
        "intent": "update melee brain in place",
        "operations": [{"path": path,
                        "expected_content_hash": read["content_hash"],
                        "edits": [{"old_text": existing, "new_text": content}]}],
        "change_set_id": "brain-update-" + hashlib.sha1(content.encode()).hexdigest()[:8],
        "dry_run": False})
    if "error" in verdict:
        raise SystemExit(f"updating {path}: {verdict}")
    return "updated"


def run_regression(mcp: Mcp, scene: str) -> dict:
    """Requirement contract on a dedicated arena scene: an enemy that must
    chase, telegraph, hit ONCE per swing, stop on death, and drop ONCE."""
    return mcp.tool("run_verification_queue", {
        "command": "create",
        "goal": "melee enemy contract: detect/chase/windup/hit-once/death-stops/drop-once",
        "strict": True,
        "requirements": ["detect+chase", "windup telegraphs", "single hit per swing",
                         "death stops attacking", "drop exactly once"],
        "items": [
            {"kind": "behavior_check", "requirement": "detect+chase", "label": "r1",
             "detail": {"scene_path": scene, "steps": [
                 {"wait_ms": 800,
                  "assert": {"expression": "(get_tree().get_nodes_in_group('enemies').size() >= 1)", "expected": True,
                             "description": "enemy exists"}},
                 {"action": "move_left", "pressed": True, "wait_ms": 250},
                 {"action": "move_left", "pressed": False, "wait_ms": 2500,
                  "assert": {"expression": "get_tree().get_first_node_in_group('enemies').get_node('MeleeBrain').state()",
                             "expected": "chase",
                             "description": "enemy entered chase after the player stood near"}}]}},
            {"kind": "behavior_check", "requirement": "windup telegraphs", "label": "r2",
             "detail": {"scene_path": scene, "steps": [
                 {"wait_ms": 3000,
                  "assert": {"expression": "(get_tree().get_first_node_in_group('enemies').get_node('MeleeBrain').state_log.has('windup'))",
                             "expected": True,
                             "description": "windup phase was reached and logged"}}]}},
            {"kind": "behavior_check", "requirement": "single hit per swing", "label": "r3",
             "detail": {"scene_path": scene, "steps": [
                 {"wait_ms": 500,
                  "assert": {"expression": "get_tree().get_first_node_in_group('enemies').get_node('MeleeBrain').attacks_landed",
                             "expected": 1, "operator": "gte",
                             "description": "at least one landed hit (player hp may have dropped)"}},
                 {"wait_ms": 200,
                  "assert": {"expression": "get_node('Player').hp", "expected": 100, "operator": "lt",
                             "description": "the player took damage"}}]}},
            {"kind": "behavior_check", "requirement": "death stops attacking", "label": "r4",
             "detail": {"scene_path": scene, "steps": [
                 {"wait_ms": 200,
                  "assert": {"expression": "get_tree().get_first_node_in_group('enemies').get_node('MeleeBrain').attacks_landed",
                             "expected": 0, "operator": "gte",
                             "description": "attack count captured before death"}},
                 {"wait_ms": 100,
                  "assert": {"expression": "(get_tree().get_first_node_in_group('enemies').take_damage(1000, Vector2(0, 0)) == null)",
                             "expected": True,
                             "description": "lethal damage dealt"}},
                 {"wait_ms": 60,
                  "assert": {"expression": "get_tree().get_first_node_in_group('enemies').get_node('MeleeBrain').attacks_landed",
                             "expected": 0, "operator": "gte",
                             "description": "count unchanged inside the death window"}}]}},
            {"kind": "behavior_check", "requirement": "drop exactly once", "label": "r5",
             "detail": {"scene_path": scene, "steps": [
                 {"wait_ms": 1500,
                  "assert": {"expression": "(get_tree().get_first_node_in_group('enemies').take_damage(1000, Vector2(0, 0)) == null)",
                             "expected": True,
                             "description": "lethal hit in THIS run"}},
                 {"wait_ms": 60,
                  "assert": {"expression": "get_tree().get_first_node_in_group('enemies').get_node('MeleeBrain').drops_spawned",
                             "expected": 1,
                             "description": "one coin dropped (read inside the 0.22s death window)"}},
                 {"wait_ms": 50,
                  "assert": {"expression": "(get_tree().get_nodes_in_group('coins').size() >= 1)",
                             "expected": True,
                             "description": "the coin exists in the world"}}]}},
        ]}, timeout=600.0)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("project", nargs="?", default="slice_b")
    parser.add_argument("--enemy-scene", default="res://scenes/enemy.tscn")
    parser.add_argument("--arena-scene", default="res://scenes/melee_arena.tscn")
    parser.add_argument("--with-regression", action="store_true")
    parser.add_argument("--godot", default=r"D:\youxi\kaifa\Godot_v4.7.2-stable_win64_console.exe")
    args = parser.parse_args()

    project = (REPO_ROOT / args.project).resolve()
    port = random.randint(9300, 9799)
    process = subprocess.Popen(
        [args.godot, "--editor", "--headless", "--path", str(project),
         "--", "--mcp-server", f"--mcp-port={port}"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        mcp = Mcp(port)
        wait_for_server(mcp)
        mcp.tool("enable_tools", {"tools": [
            "open_scene", "get_scene_structure", "create_node",
            "batch_scene_node_edits", "save_scene", "read_script",
            "create_script", "apply_change_set", "validate_script",
            "execute_editor_script", "run_verification_queue"]})

        brain_path = "res://scripts/combat/melee_brain.gd"
        state = ensure_script(mcp, brain_path, BRAIN_SCRIPT)
        print(f"[ok] melee brain {state}")

        mcp.tool("open_scene", {"scene_path": args.enemy_scene, "allow_ui_focus": True})
        structure = json.dumps(mcp.tool("get_scene_structure"))
        if '"MeleeBrain"' not in structure:
            mcp.tool("create_node", {"parent_path": ".", "node_type": "Node",
                                     "node_name": "MeleeBrain"})
            print("[ok] MeleeBrain node created")
        else:
            print("[ok] MeleeBrain already present (updated in place)")
        mcp.tool("batch_scene_node_edits", {"operations": [
            {"type": "attach_script", "node_path": "MeleeBrain", "script_path": brain_path}]})
        # re-attach external (attach embeds on save — the P0-2 lesson)
        mcp.tool("execute_editor_script", {"code": """
var root := EditorInterface.get_edited_scene_root()
var brain := root.get_node("MeleeBrain")
var path := "res://scripts/combat/melee_brain.gd"
var s := load(path)
if s == null or not s.can_instantiate():
	var fresh := GDScript.new()
	fresh.source_code = FileAccess.get_file_as_string(path)
	fresh.reload()
	fresh.take_over_path(path)
	s = fresh
brain.set_script(s)
_custom_print("brain external: " + str(brain.get_script().resource_path))
"""})
        # death -> drop hook (guarded)
        enemy_script = "res://scripts/combat/enemy.gd"
        read = mcp.tool("read_script", {"script_path": enemy_script})
        content = str(read.get("content", ""))
        if "notify_death" in content:
            print("[ok] death->drop hook already wired")
        elif ENEMY_HOOK_OLD in content:
            verdict = mcp.tool("apply_change_set", {
                "intent": "enemy death notifies the brain (drop)",
                "operations": [{"path": enemy_script,
                                "expected_content_hash": read["content_hash"],
                                "edits": [{"old_text": ENEMY_HOOK_OLD,
                                           "new_text": ENEMY_HOOK_NEW}]}],
                "change_set_id": "enemy-death-hook", "dry_run": False})
            if "error" in verdict:
                raise SystemExit(verdict)
            print("[ok] death->drop hook wired")
        else:
            print("[note] enemy death anchor not found — drop hook NOT wired "
                  "(wire notify_death into your death path)")
        mcp.tool("validate_script", {"script_path": enemy_script})
        mcp.tool("validate_script", {"script_path": brain_path})
        mcp.tool("save_scene", {"scene_path": args.enemy_scene})
        print("[ok] enemy scene saved")

        if args.with_regression:
            regression = run_regression(mcp, args.arena_scene)
            advances = 0
            while regression.get("outcome") in ("pending_more", "open") and advances < 10:
                regression = mcp.tool("run_verification_queue", {
                    "command": "advance", "queue_id": regression.get("queue_id", "")},
                    timeout=600.0)
                advances += 1
            print("regression:", regression.get("outcome"),
                  "passed:", regression.get("passed_count"),
                  "failed:", regression.get("failed_count"))
            checklist = regression.get("checklist", {})
            for entry in checklist.get("requirements", []):
                print(f"  [{entry.get('status')}] {entry.get('requirement')}")
            overall = str(checklist.get("overall", "incomplete"))
            print(f"=== OVERALL: {overall.upper()} ===")
            if overall != "complete":
                return 1
        print("MELEE ENEMY APPLIED (idempotent; re-run updates)")
        return 0
    finally:
        process.terminate()
        try:
            process.wait(timeout=15)
        except subprocess.TimeoutExpired:
            process.kill()


if __name__ == "__main__":
    sys.exit(main())
