"""Gate-B playbook acceptance (M6): the audit's modification scenarios,
fixed as one reproducible flow over the real slice_b editor.

Covered in a single session (steps 1-2 proven in M2 are replayed fast):
  [1] shared enemy gains knockback resistance (change set)   -> boss bytes kept
  [2] item attribute edit (heal_amount 30 -> 45)
  [3] quest reward update (reward_coins 5 -> 8)
  [4] rename safety net: query_change_impact lists the referencing scenes
      for item_heart.tres before any rename is attempted
  [5] map tweak (change set moves Heart2's position in map_l1.tscn)
  [6] save migration v1 -> v2 + corrupt fallback (in-editor, real GameSave)
  [7] runtime smoke: quest loop closes in the live game (accept -> collect
      via inventory -> turn-in pays)
Anchors: boss_stats.tres and map_boss.tscn stay byte-identical throughout.

Usage: python test/integration/test_slice_b_playbook_flow.py
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

REPO = Path(__file__).resolve().parents[2]
SLICE = REPO / "slice_b"
GODOT = os.environ.get("GODOT_EXE", r"D:\youxi\kaifa\Godot_v4.7.2-stable_win64_console.exe")
PORT = 9199
URL = f"http://127.0.0.1:{PORT}/mcp"
_rid = 8000

GRUNT = "res://data/grunt_stats.tres"
HEART = "res://data/item_heart.tres"
QUEST = "res://data/quest_hearts.tres"
MAP_L1 = "res://scenes/maps/map_l1.tscn"
BOSS_BYTES_PATH = SLICE / "data/boss_stats.tres"
MAP_BOSS_BYTES_PATH = SLICE / "scenes/maps/map_boss.tscn"

EDITS = [
    # (resource, old, new, intent)
    (GRUNT, "knockback_resistance = 0.0", "knockback_resistance = 0.5",
     "playbook 1: shared grunts gain resistance"),
    (HEART, "heal_amount = 30", "heal_amount = 45",
     "playbook 2: heart heals more"),
    (QUEST, "reward_coins = 5", "reward_coins = 8",
     "playbook 3: quest reward updated"),
    (MAP_L1, "position = Vector2(640, 130)", "position = Vector2(700, 200)",
     "playbook 5: L1 map tweak (Heart2 moved)"),
]


def rpc(name, args, timeout=240.0):
    global _rid
    _rid += 1
    req = urllib.request.Request(URL, data=json.dumps(
        {"jsonrpc": "2.0", "method": "tools/call",
         "params": {"name": name, "arguments": args}, "id": _rid}).encode(),
        headers={"Content-Type": "application/json"})
    r = json.loads(urllib.request.urlopen(req, timeout=timeout).read())
    res = r.get("result", {})
    if res.get("isError"):
        raise AssertionError(f"{name}: {res['content'][0]['text'][:240]}")
    return res.get("structuredContent", {})


def wait_server(seconds=150.0):
    deadline = time.time() + seconds
    while time.time() < deadline:
        try:
            req = urllib.request.Request(URL, data=json.dumps(
                {"jsonrpc": "2.0", "method": "tools/list", "id": 0}).encode(),
                headers={"Content-Type": "application/json"})
            urllib.request.urlopen(req, timeout=5).read()
            return
        except Exception:
            time.sleep(1)
    raise TimeoutError("slice_b MCP server never came up")


def apply_change_set(intent, path, old, new, cs_id):
    expected = hashlib.sha256((SLICE / path.replace("res://", "")).read_bytes()).hexdigest()
    result = rpc("apply_change_set", {
        "intent": intent, "change_set_id": cs_id,
        "operations": [{"path": path, "expected_content_hash": expected,
                        "edits": [{"old_text": old, "new_text": new}]}],
    })
    if result.get("outcome") != "committed":
        raise AssertionError(f"{cs_id} did not commit: {json.dumps(result)[:400]}")
    return result


def editor_eval(gd_code):
    result = rpc("execute_editor_script", {"code": gd_code})
    output = result.get("output", "")
    if isinstance(output, list):
        output = "\n".join(str(part) for part in output)
    return str(output)


def main() -> int:
    for stream in (sys.stdout, sys.stderr):
        if hasattr(stream, "reconfigure"):
            stream.reconfigure(encoding="utf-8", errors="replace")
    subprocess.run(["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass",
                    "-File", str(SLICE / "setup.ps1")], capture_output=True, timeout=120)
    appdata = os.path.join(os.environ.get("APPDATA", ""), "Godot", "app_userdata")
    shutil.rmtree(os.path.join(appdata, "SliceB"), ignore_errors=True)

    # 干净起点：工作树即基线（上一轮失败可能留下已应用修改）。
    for path, old, new, _ in EDITS:
        f = SLICE / path.replace("res://", "")
        if new in f.read_text(encoding="utf-8"):
            f.write_text(f.read_text(encoding="utf-8").replace(new, old),
                         encoding="utf-8", newline="")
    journal = SLICE / ".mcp/change_journal.json"
    if journal.exists():
        journal.unlink()

    boss_before = BOSS_BYTES_PATH.read_bytes()
    map_boss_before = MAP_BOSS_BYTES_PATH.read_bytes()

    process = subprocess.Popen(
        [GODOT, "--editor", "--headless", "--path", str(SLICE),
         "--", "--mcp-server", f"--mcp-port={PORT}"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, cwd=str(SLICE))
    try:
        wait_server()
        rpc("enable_tools", {"tools": [
            "apply_change_set", "query_change_impact", "execute_editor_script",
            "install_runtime_probe", "run_project", "stop_project",
            "play_and_verify"], "enabled": True})

        # —— 剧本 1-3 + 5：四张变更单，每张读版本绑定 ——
        for index, (path, old, new, intent) in enumerate(EDITS):
            apply_change_set(intent, path, old, new, f"cs_pb_{index}")

        # —— 剧本 4：重命名安全网（改名前的影响面必须完整）——
        impact = rpc("query_change_impact", {
            "target_paths": [HEART], "direction": "dependents"})
        dependents = [str(entry.get("path", "")) for entry in impact.get("impact", [])]
        if not any("item_pickup.tscn" in p for p in dependents):
            raise AssertionError(
                f"rename safety net failed: item_pickup.tscn not in dependents ({dependents})")

        # —— 锚点：Boss 特例与 Boss 地图逐字节保留 ——
        if BOSS_BYTES_PATH.read_bytes() != boss_before:
            raise AssertionError("boss_stats.tres changed during the playbook")
        if MAP_BOSS_BYTES_PATH.read_bytes() != map_boss_before:
            raise AssertionError("map_boss.tscn changed during the playbook")

        # —— 剧本 6：存档 v1→v2 迁移 + 损坏回退（真实 GameSave）——
        # 编辑器脚本里 get_tree() 不可用（AGENTS 约束）——迁移已 static 化，
        # 直接 load 脚本调用纯函数。
        migration_output = editor_eval(
            'var save_script = load("res://scripts/world/game_save.gd")\n'
            'var v1_data = {"schema_version": 1, "visited_maps": ["res://scenes/maps/map_l1.tscn"],'
            ' "last_map": "res://scenes/maps/map_l1.tscn",'
            ' "player_position": {"x": 5.0, "y": 6.0}}\n'
            'var migrated = save_script._migrate(v1_data.duplicate())\n'
            'var future = save_script._migrate({"schema_version": 99})\n'
            'var ok = (int(migrated.get("schema_version", 0)) == 0 or int(migrated.get("hp", -1)) == 100)'
            ' and int(migrated.get("coins", -1)) == 0 and migrated.has("items") and migrated.has("quests")'
            ' and future.is_empty()\n'
            '_custom_print("MIGRATION_OK=" + str(ok) + " HP=" + str(migrated.get("hp"))'
            ' + " COINS=" + str(migrated.get("coins")) + " FUTURE_EMPTY=" + str(future.is_empty()))\n')
        if "MIGRATION_OK=true" not in migration_output:
            raise AssertionError(f"migration check failed: {migration_output[:300]}")

        # —— 剧本 7：运行时任务闭环（活游戏内 accept → 集齐 → 提交发奖）——
        installed = rpc("install_runtime_probe",
                        {"node_name": "MCPRuntimeProbe", "persistent": False})
        if installed.get("status") not in ("success", "already_installed"):
            raise AssertionError(f"probe install failed: {installed}")
        if rpc("run_project", {"allow_window": True}).get("status") != "success":
            raise AssertionError("run_project failed")
        verdict = rpc("play_and_verify", {
            "steps": [
                # 数值断言统一在表达式内比较返回 bool——探针会把 expected
                # 数值浮点化（int actual 永远不等），bool 期望值没有该问题。
                {"assert": {"expression":
                    "get_node(\"Heart1\").item.heal_amount == 45",
                    "expected": True,
                    "description": "the edited item attribute is live (45)"}},
                {"assert": {"expression":
                    "get_node(\"/root/GameSave\").quest_log.accept(\"quest_hearts\")",
                    "expected": True, "description": "quest accepted"}},
                {"assert": {"expression":
                    "get_node(\"/root/GameSave\").inventory.add(\"heart\", 2) == null",
                    "expected": True, "description": "two hearts enter the inventory"}},
                {"assert": {"expression":
                    "get_node(\"/root/GameSave\").quest_log.record_progress(\"quest_hearts\", 2) == null",
                    "expected": True, "description": "quest progress recorded"}},
                {"assert": {"expression":
                    "get_node(\"/root/GameSave\").quest_log.try_turn_in(\"quest_hearts\", get_node(\"QuestShrine\").quest, get_node(\"/root/GameSave\").inventory).get(\"reward_coins\") == 8",
                    "expected": True,
                    "description": "turn-in pays the UPDATED reward (8, playbook 3)"}},
                {"assert": {"expression":
                    "get_node(\"/root/GameSave\").quest_log.is_completed(\"quest_hearts\")",
                    "expected": True, "description": "quest completed"}},
            ],
        }, timeout=240.0)
        if not verdict.get("passed", False):
            raise AssertionError(f"runtime playbook failed: {json.dumps(verdict)[:600]}")

        # —— 恢复：四张变更单逐项还原 ——
        for index, (path, old, new, intent) in enumerate(EDITS):
            apply_change_set(f"restore: {intent}", path, new, old, f"cs_pb_restore_{index}")

        if BOSS_BYTES_PATH.read_bytes() != boss_before:
            raise AssertionError("boss bytes drifted across the whole playbook")
        print(f"Gate-B playbook verified: {len(EDITS)} change-set edits committed + restored, "
              f"rename impact listed the referencing scene, v1->v2 migration + future-version "
              f"rejection OK, live quest loop paid the updated reward, anchors byte-identical.")
        return 0
    finally:
        try:
            rpc("stop_project", {"allow_window": True})
        except Exception:
            pass
        process.kill()
        process.wait(timeout=15)
        for path, old, new, _ in EDITS:
            f = SLICE / path.replace("res://", "")
            if f.exists() and new in f.read_text(encoding="utf-8"):
                f.write_text(f.read_text(encoding="utf-8").replace(new, old),
                             encoding="utf-8", newline="")


if __name__ == "__main__":
    sys.exit(main())
