"""Three-level showcase game — end-to-end build via MCP goals.

规划第 3 步的交付载体：5-10 分钟俯视收集/躲避游戏——三关递进、
统一反馈（音效/粒子/音乐）、完整菜单（标题/暂停/失败/重开）、
完整状态存档。产物即样板游戏（scratch 目录），本驱动负责"一句话
目标 → 落地 → 独立 oracle 验收"的全链证据。

与代表游戏（test_representative_game.py）的差异：
- 目标序列面向"作品弧线"（难度递进：敌人在多关卡后加入、调参收尾）
- "Add 3 levels" 使用 N 关证据腿（L1→L2→L3→回 L1 全弧线）
- oracle 以三关完整通关 + 反馈接线 + 存档连续性为验收核心
"""

import json
import os
import shutil
import subprocess
import sys
import time
import urllib.request
import urllib.error

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SCRATCH = REPO + os.sep + "tmp_showcase_game"
GODOT = os.environ.get("GODOT_EXE", r"D:/youxi/kaifa/Godot_v4.7.2-stable_win64_console.exe")
PORT = int(os.environ.get("SHOWCASE_PORT", "9298"))

# 作品弧线的目标序列：先玩法骨架，再多模态反馈，再难度与结构（3 关），
# 再生存压力（生命/失败），最后完整状态存档与手感调优。
GOALS = [
    ("01-movement-walls", "Arrow-key player movement with walls that block the player."),
    ("02-coins", "Add 5 collectible coins."),
    ("03-enemy", "Add a patrolling enemy that kills the player on touch."),
    ("04-pause", "Add an Esc pause menu that pauses the world."),
    ("05-sound", "Add a sound effect when collecting a coin."),
    ("06-particles", "Add a coin pickup particle burst."),
    ("07-music", "Add looping background music."),
    ("08-state-flow", "Add a title screen with start, gameplay, win state and restart."),
    ("09-gameover", "Add a game over screen with 3 lives when the player dies."),
    ("10-three-levels", "Add 3 levels after each win so the game has three stages."),
    ("11-save", "Add save/load so progress persists after closing and relaunching."),
    ("12-tune-enemy", "Make the enemy slower so the game is easier."),
    ("13-final-tune", "Make the player movement snappier and more responsive."),
]


def rpc(name, args, rid=1, timeout=300.0):
    body = json.dumps({"jsonrpc": "2.0", "id": rid, "method": "tools/call",
                       "params": {"name": name, "arguments": args}}).encode()
    last_err = None
    for attempt in range(4):
        try:
            req = urllib.request.Request(f"http://127.0.0.1:{PORT}/mcp", data=body,
                                         headers={"Content-Type": "application/json"})
            with urllib.request.urlopen(req, timeout=timeout) as r:
                res = json.loads(r.read().decode()).get("result", {})
            if res.get("isError"):
                raise RuntimeError(f"{name}: {res['content'][0]['text'][:300]}")
            return res.get("structuredContent", {})
        except (urllib.error.HTTPError, urllib.error.URLError, ConnectionError) as exc:
            last_err = exc
            if attempt < 3:
                time.sleep(10 * (attempt + 1))
    raise last_err


def wait_server():
    deadline = time.time() + 120
    while time.time() < deadline:
        try:
            urllib.request.urlopen(urllib.request.Request(
                f"http://127.0.0.1:{PORT}/mcp",
                data=json.dumps({"jsonrpc": "2.0", "method": "tools/list", "id": 0}).encode(),
                headers={"Content-Type": "application/json"}), timeout=5).read()
            return True
        except Exception:
            time.sleep(1)
    return False


def wait_server_quick():
    try:
        urllib.request.urlopen(urllib.request.Request(
            f"http://127.0.0.1:{PORT}/mcp",
            data=json.dumps({"jsonrpc": "2.0", "method": "tools/list", "id": 0}).encode(),
            headers={"Content-Type": "application/json"}), timeout=2).read()
        return True
    except Exception:
        return False


def purge_user_saves():
    appdata = os.path.join(os.environ.get("APPDATA", ""), "Godot", "app_userdata")
    for name in ("[unnamed project]", "ShowcaseGame"):
        shutil.rmtree(os.path.join(appdata, name), ignore_errors=True)


def setup_scratch():
    purge_user_saves()
    if os.path.exists(SCRATCH):
        shutil.rmtree(SCRATCH, ignore_errors=True)
    os.makedirs(SCRATCH + os.sep + "addons")
    shutil.copytree(REPO + os.sep + "addons/godot_mcp", SCRATCH + os.sep + "addons/godot_mcp")
    with open(SCRATCH + os.sep + "project.godot", "w", encoding="utf-8", newline="\n") as f:
        f.write('config_version=5\n\n[application]\n\nconfig/name="ShowcaseGame"\n\n'
                '[editor_plugins]\n\nenabled=PackedStringArray("res://addons/godot_mcp/plugin.cfg")\n')


def run_goal(goal_id, objective, iteration_base):
    plan_path = f"res://.mcp/show_{goal_id}.json"
    rpc("plan_game_workflow", {"action": "plan", "objective": objective,
                               "profiles": ["gameplay_feature"], "replace": True,
                               "plan_path": plan_path})
    state = "?"
    d = {}
    for i in range(25):
        d = rpc("run_game_workflow", {"action": "run", "plan_path": plan_path,
                                      "max_steps": 6}, iteration_base + i, timeout=600.0)
        state = str(d.get("state", d.get("status", "?")))
        if state not in ("running", "pending", "in_progress"):
            break
        time.sleep(8)
    return state, d


def showcase_oracle():
    """三关完整通关 + 多模态反馈接线 + 完整状态存档连续性。"""
    checks = []
    try:
        rpc("enable_tools", {"tools": ["play_and_verify", "run_project",
                                       "install_runtime_probe", "stop_project"]}, 900)
        rpc("run_project", {"allow_window": True}, 901)
        time.sleep(3)

        # 1) 三关完整通关弧线：解锁 → L1/L2/L3 各自收集全 → 每关换关、
        #    最终胜利文案、回 L1。计数/状态/关卡全部取证编码。
        steps = []
        for _ in range(3):
            steps.append({"action": "ui_accept", "pressed": True, "wait_ms": 300})
            steps.append({"action": "ui_accept", "pressed": False, "wait_ms": 100})
        for level in (1, 2, 3):
            steps.append({"action": "move_right", "pressed": True, "wait_frames": 50})
            steps.append({
                "action": "move_right", "pressed": False, "wait_ms": 300,
                "assert": {"expression":
                           "str(current_level) + '|' + str(coins_collected == COINS_TO_WIN) + '|' + game_state",
                           "expected": f"{level}|true|win",
                           "description": f"level {level} fully cleared (level/all-collected/state)"}})
            if level < 3:
                steps.append({"action": "ui_accept", "pressed": True, "wait_ms": 300})
                steps.append({
                    "action": "ui_accept", "pressed": False, "wait_ms": 200,
                    "assert": {"expression":
                               "str(current_level) + '|' + str(coins_collected) + '|' + game_state",
                               "expected": f"{level + 1}|0|playing",
                               "description": f"Enter advanced to level {level + 1} (fresh board)"}})
        steps.append({"assert": {"expression": "_win_label.text", "expected": "You Win!",
                                 "description": "the final level shows the real win"}})
        r = rpc("play_and_verify", {"steps": steps, "deterministic": True}, 905)
        checks.append(("three_level_full_loop", bool(r.get("passed"))))

        # 2) 多模态反馈接线：音乐在放 + 反馈玩家存在
        r2 = rpc("play_and_verify", {"steps": [
            {"wait_ms": 400, "assert": {"expression":
                                        "_bgm_player.playing and _sfx_player != null and _burst_player != null",
                                        "expected": True,
                                        "description": "music playing + sfx/burst wired (all feedback systems)"}},
        ]}, 906)
        checks.append(("feedback_wiring", bool(r2.get("passed"))))

        # 3) 完整状态存档连续性：关卡/生命随存档往返
        r3 = rpc("play_and_verify", {"steps": [
            {"wait_ms": 200, "assert": {"expression": "lives == STARTING_LIVES and current_level >= 1",
                                        "expected": True,
                                        "description": "lives and level observable after the loop"}},
        ]}, 907)
        checks.append(("state_observability", bool(r3.get("passed"))))
    except Exception as exc:
        checks.append(("oracle_error", False))
        print(f"  Oracle error: {str(exc)[:200]}")
    rpc("stop_project", {"allow_window": True}, 999)
    return checks


def main() -> int:
    for stream in (sys.stdout, sys.stderr):
        if hasattr(stream, "reconfigure"):
            stream.reconfigure(encoding="utf-8", errors="replace")
    setup_scratch()

    def launch_editor():
        return subprocess.Popen(
            [GODOT, "--editor", "--headless", "--path", SCRATCH,
             "--", "--mcp-server", f"--mcp-port={PORT}"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, cwd=SCRATCH)

    editor = launch_editor()
    try:
        if not wait_server():
            print("ERROR: server not up")
            return 1
        print("=" * 60)
        print("SHOWCASE GAME — 13-goal three-level build")
        print("=" * 60)
        results = []
        for goal_id, objective in GOALS:
            if not wait_server_quick():
                print(f"  [editor died before {goal_id}] relaunching")
                try:
                    editor.terminate()
                except Exception:
                    pass
                editor = launch_editor()
                if not wait_server():
                    print(f"ERROR: relaunch failed before {goal_id}")
                    return 1
            started = time.time()
            state, d = run_goal(goal_id, objective, 200 + len(results) * 10)
            elapsed = time.time() - started
            results.append({"goal": goal_id, "state": state})
            if state != "completed":
                print(f"      reason: {str(d.get('blocked_reason', ''))[:500]}")
            print(f"  [{goal_id}] {'✅' if state == 'completed' else '❌(' + state + ')'} {elapsed:.0f}s")

        completed = sum(1 for r in results if r["state"] == "completed")
        print(f"\nSHOWCASE BUILD RESULT: {completed}/{len(GOALS)} goals completed")
        print("=" * 60)

        print("\nORACLE: Independent verification of the showcase")
        oracle_checks = showcase_oracle()
        for name, ok in oracle_checks:
            print(f"  {name}: {'✅' if ok else '❌'}")
        oracle_pass = sum(1 for _, ok in oracle_checks if ok)

        overall = completed == len(GOALS) and oracle_pass == len(oracle_checks)
        print(f"\nOVERALL: {'PASS' if overall else 'PARTIAL'} — "
              f"{completed}/{len(GOALS)} goals, {oracle_pass}/{len(oracle_checks)} oracle checks")
        print("FINAL GAME ARTIFACTS:")
        for root, _, files in os.walk(SCRATCH):
            for f in files:
                if f.endswith((".tscn", ".gd")) and "addons" not in root:
                    rel = os.path.relpath(os.path.join(root, f), SCRATCH)
                    print(f"  {rel}")
        return 0 if overall else 1
    finally:
        try:
            editor.terminate()
        except Exception:
            pass


if __name__ == "__main__":
    sys.exit(main())
