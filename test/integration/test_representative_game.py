"""Phase D: Representative game — 2D top-down collection adventure.

Builds a complete game through 10 sequential MCP goals on one project,
then verifies the final product with independent oracle checks.

Game spec (from gap analysis Phase D):
- 4-direction movement with walls
- 3 collectible coins (each with its own identity — one-shot pickup)
- Patrolling enemy with death/respawn (a second one from goal 08)
- Esc pause menu
- Save/load across process restart
- Sound effect on collection
- Score HUD
- Win condition (collect all coins)
- Tune difficulty (enemy speed — direction must be PROVEN vs baseline)
- Visual polish (walls)

Honesty rules (gap analysis 2026-09-15, P0-2):
- The final verdict gates on BOTH goal completion AND independent oracle
  checks. "10/10 goals completed" alone is not success.
- Oracle checks assert real behavior (full two-round game loop, meaningful
  enemy patrol and death, exact coin count) — not config presence
  (the old `COINS_TO_WIN >= 1` / `deaths_count >= 0` checks were vacuous).
- Windows console cannot encode emoji/UTF-8 by default: stdout is
  reconfigured up-front so the run cannot die mid-report (the CI break).
"""
import json
import os
import shutil
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SCRATCH = REPO / "tmp_representative_game"
GODOT = os.environ.get("GODOT_EXE", r"D:\youxi\kaifa\Godot_v4.7.2-stable_win64_console.exe")
PORT = int(os.environ.get("REP_PORT", "9195"))

def rpc(name, args, rid=1, timeout=300.0):
    # 编辑器中途打嗝（503/连接重置，本机与 CI runner 均实测）不再截断整轮：
    # 工作流状态是持久检查点，重复同一命令安全挂接不重做——退避重试。
    import time as _t
    last_err = None
    for attempt in range(4):
        try:
            payload = {"jsonrpc":"2.0","method":"tools/call","id":rid,"params":{"name":name,"arguments":args}}
            req = urllib.request.Request(f"http://127.0.0.1:{PORT}/mcp",
                data=json.dumps(payload).encode(), headers={"Content-Type":"application/json"})
            r = json.loads(urllib.request.urlopen(req, timeout=timeout).read())
            res = r.get("result",{})
            if res.get("isError"):
                raise RuntimeError(f"{name}: {res['content'][0]['text'][:300]}")
            return res.get("structuredContent",{})
        except (urllib.error.HTTPError, urllib.error.URLError, ConnectionError) as exc:
            last_err = exc
            if attempt < 3:
                wait_s = 10 * (attempt + 1)
                print(f"  [rpc hiccup on {name}: {exc}] retrying in {wait_s}s "
                      f"({attempt + 1}/3) — durable workflow state makes this safe")
                _t.sleep(wait_s)
    raise last_err

def wait_server():
    deadline = time.time() + 120
    while time.time() < deadline:
        try:
            urllib.request.urlopen(urllib.request.Request(
                f"http://127.0.0.1:{PORT}/mcp",
                data=json.dumps({"jsonrpc":"2.0","method":"tools/list","id":0}).encode(),
                headers={"Content-Type":"application/json"}), timeout=5).read()
            return True
        except Exception:
            time.sleep(1)
    return False

# The 11-goal game-building sequence
GOALS = [
    ("01-movement-walls", "Arrow-key player movement with walls that block the player."),
    ("02-coins", "Add 3 collectible coins."),
    ("03-enemy", "Add a patrolling enemy that kills the player on touch."),
    ("04-pause", "Add an Esc pause menu that pauses the world."),
    ("05-sound", "Add a sound effect when collecting a coin."),
    ("05b-particles", "Add a coin pickup particle burst."),
    ("06-save", "Add save/load so progress persists after closing and relaunching."),
    ("07-tune-enemy", "Make the enemy slower so the game is easier."),
    ("08-second-enemy", "Add another patrolling enemy."),
    ("09-state-flow", "Add a title screen with start, gameplay, win state and restart."),
    ("10-final-tune", "Make the player movement snappier and more responsive."),
]

def purge_user_saves():
    # user:// 存档跨运行残留（真机复现：漂移时代的 {"x":4812} 毒化每次
    # 全新启动——恢复位置远离金币，收集重验永远失败）。游戏进程实际
    # 落在 "[unnamed project]"，两个名字都清。
    appdata = os.path.join(os.environ.get("APPDATA", ""), "Godot", "app_userdata")
    for name in ("[unnamed project]", "RepresentativeGame"):
        shutil.rmtree(os.path.join(appdata, name), ignore_errors=True)

def setup_scratch():
    purge_user_saves()
    if SCRATCH.exists():
        shutil.rmtree(SCRATCH, ignore_errors=True)
    (SCRATCH / "addons").mkdir(parents=True)
    shutil.copytree(REPO / "addons/godot_mcp", SCRATCH / "addons/godot_mcp")
    (SCRATCH / "project.godot").write_text(
        'config_version=5\n\n[application]\n\nconfig/name="RepresentativeGame"\n\n'
        '[editor_plugins]\n\nenabled=PackedStringArray("res://addons/godot_mcp/plugin.cfg")\n',
        encoding="utf-8", newline="\n")

def run_goal(goal_id, objective, iteration_base):
    plan_path = f"res://.mcp/rep_{goal_id}.json"
    rpc("plan_game_workflow", {"action":"plan","objective":objective,
        "profiles":["gameplay_feature"],"replace":True,"plan_path":plan_path})
    state = "?"
    d = {}
    # 旧行为回归门禁让每个完成多花 ~10-60s（受影响旧功能逐个重验）——
    # 轮询预算相应放大。
    for i in range(25):
        d = rpc("run_game_workflow", {"plan_path":plan_path,"max_steps":8}, iteration_base+i)
        state = d.get("state", d.get("status","?"))
        if state in ("completed","needs_input","recovery_required","replan_required"):
            break
        time.sleep(2)
    rpc("stop_project", {"allow_window":True}, iteration_base+90)
    return state, d

# ---- Oracle step sequences (mirror the workflow's own exercise semantics) ----

def full_loop_steps():
    """Title -> playing -> collect ALL coins -> win -> restart -> win again."""
    return [
        {"action": "ui_accept", "pressed": True, "wait_ms": 300},
        {"action": "ui_accept", "pressed": False, "wait_ms": 100},
        {"action": "ui_accept", "pressed": True, "wait_ms": 300},
        {"action": "ui_accept", "pressed": False, "wait_ms": 100},
        {"action": "ui_accept", "pressed": True, "wait_ms": 300},
        {"action": "ui_accept", "pressed": False, "wait_ms": 100},
        {"action": "move_right", "pressed": True, "wait_frames": 90},
        {"action": "move_right", "pressed": False, "wait_ms": 300,
         "assert": {"expression": "coins_collected == COINS_TO_WIN", "expected": True,
            "description": "round one: every coin collected (identity-safe pickup)"}},
        # 反馈等值断言只放第二轮：第一轮受读档影响（save 目标落盘
        # coins=1，恢复后 sfx 计数与本轮拾取分母不同——等值必假）；
        # 第二轮在 win->title 重置之后，两个计数器同从 0 起算。
        {"assert": {"expression": "_win_label.text", "expected": "You Win!",
            "description": "round one: win label shows"}},
        {"assert": {"expression": "game_state", "expected": "win",
            "description": "round one: win state reached"}},
        {"action": "ui_accept", "pressed": True, "wait_ms": 300},
        {"action": "ui_accept", "pressed": False, "wait_ms": 100},
        {"action": "ui_accept", "pressed": True, "wait_ms": 300},
        {"action": "ui_accept", "pressed": False, "wait_ms": 100},
        {"action": "ui_accept", "pressed": True, "wait_ms": 300},
        {"action": "ui_accept", "pressed": False, "wait_ms": 200,
         "assert": {"expression": "coins_collected == 0", "expected": True,
            "description": "the restart cycle reset the counter (win->title->playing)"}},
        {"assert": {"expression": "abs(position.x) < 20", "expected": True,
            "description": "restart reset the player to the origin"}},
        {"action": "ui_accept", "pressed": True, "wait_ms": 300},
        {"action": "ui_accept", "pressed": False, "wait_ms": 200,
         "assert": {"expression": "game_state", "expected": "playing",
            "description": "second round starts"}},
        {"action": "move_right", "pressed": True, "wait_frames": 90},
        {"action": "move_right", "pressed": False, "wait_ms": 300,
         "assert": {"expression": "coins_collected == COINS_TO_WIN and game_state == \"win\"",
            "expected": True,
            "description": "second round: full win achieved again after restart"}},
        {"assert": {"expression": "sfx_played_count == coins_collected and burst_count == coins_collected",
            "expected": True,
            "description": "second round: feedback re-fired after the restart reset"}},
    ]

def death_check_steps():
    """Dodge below the enemy band, pass it, return to y=0, sweep back left
    through the band: a death must occur and the player must respawn."""
    return [
        {"action": "ui_accept", "pressed": True, "wait_ms": 300},
        {"action": "ui_accept", "pressed": False, "wait_ms": 100},
        {"action": "ui_accept", "pressed": True, "wait_ms": 300},
        {"action": "ui_accept", "pressed": False, "wait_ms": 100},
        {"action": "ui_accept", "pressed": True, "wait_ms": 300},
        {"action": "ui_accept", "pressed": False, "wait_ms": 100},
        {"action": "move_down", "pressed": True, "wait_ms": 1000},
        {"action": "move_down", "pressed": False, "wait_ms": 100},
        {"action": "move_right", "pressed": True, "wait_ms": 2000},
        {"action": "move_right", "pressed": False, "wait_ms": 100},
        {"action": "move_up", "pressed": True, "wait_ms": 1000},
        {"action": "move_up", "pressed": False, "wait_ms": 100},
        {"action": "move_left", "pressed": True, "wait_ms": 1500},
        {"action": "move_left", "pressed": False, "wait_ms": 300,
         "assert": {"expression": "deaths_count > 0", "expected": True,
            "description": "crossing the patrol band killed the player at least once"}},
        {"assert": {"expression": "position.x < 220", "expected": True,
            "description": "the player respawned left of the enemy band"}},
    ]

def main() -> int:
    # P0-1: Windows 控制台默认 GBK 无法编码 emoji/长破折号——CI 曾在
    # 输出勾号时 UnicodeEncodeError 中断整轮测试。先重配 stdout/stderr。
    for stream in (sys.stdout, sys.stderr):
        if hasattr(stream, "reconfigure"):
            stream.reconfigure(encoding="utf-8", errors="replace")
    setup_scratch()
    editor = subprocess.Popen(
        [GODOT, "--editor", "--headless", "--path", str(SCRATCH),
         "--", "--mcp-server", f"--mcp-port={PORT}"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, cwd=str(SCRATCH))
    try:
        if not wait_server():
            print("ERROR: server not up"); return 1

        print("=" * 60)
        print("PHASE D: REPRESENTATIVE GAME — 10-goal build sequence")
        print("=" * 60)

        results = []
        for goal_id, objective in GOALS:
            started = time.time()
            state, d = run_goal(goal_id, objective, 100 + len(results) * 10)
            elapsed = time.time() - started
            ledger = d.get("goal_ledger", {})
            regression = d.get("ledger_regression", {})
            prior = d.get("prior_regression", {})
            model = d.get("game_model", {})
            results.append({
                "goal": goal_id, "state": state, "elapsed_s": round(elapsed, 1),
                "ledger_goals": ledger.get("recorded_goals", 0),
                "regression_clean": regression.get("regression_clean", None),
                "prior_checked": len(prior.get("checked", [])) if prior else None,
                "model_counts": model.get("counts", {}),
            })
            status = "✅" if state == "completed" else f"❌({state})"
            if state != "completed":
                reason = str(d.get("blocked_reason", ""))[:220]
                print(f"      reason: {reason}")
            print(f"  [{goal_id}] {status} {elapsed:.0f}s ledger={ledger.get('recorded_goals',0)} "
                  f"regression={'✅' if regression.get('regression_clean') else '⚠️' if regression else 'n/a'} "
                  f"prior_reverified={len(prior.get('checked', [])) if prior else 0} "
                  f"model={model.get('counts', {})}")

        completed = sum(1 for r in results if r["state"] == "completed")
        print(f"\n{'='*60}")
        print(f"GAME BUILD RESULT: {completed}/{len(GOALS)} goals completed")
        print(f"{'='*60}")

        # Independent oracle: verify the final game is actually playable.
        print("\nORACLE: Independent verification of final game")
        oracle_checks = []
        try:
            rpc("enable_tools", {"tools": ["play_and_verify", "run_project",
                "install_runtime_probe", "stop_project"]}, 900)
            rpc("run_project", {"allow_window": True}, 901)
            time.sleep(3)

            # Check 1: exact coin count (goal 02 asked for three — the count
            # must survive every later merge; the old >= 1 check was vacuous)
            r3 = rpc("play_and_verify", {"steps": [
                {"wait_ms": 200, "assert": {"expression": "COINS_TO_WIN == 3", "expected": True,
                    "description": "three coins configured (count survived all merges)"}},
            ]}, 912)
            oracle_checks.append(("coins_configured_exact", bool(r3.get("passed"))))

            # Check 2: full two-round game loop (title -> collect all -> win
            # -> restart -> collect all again -> win again)
            r6 = rpc("play_and_verify", {"steps": full_loop_steps(),
                "deterministic": True}, 915)
            oracle_checks.append(("full_two_round_loop", bool(r6.get("passed"))))

            # Check 3: no runtime errors anywhere above (the old multi-coin
            # double-free would surface here)
            oracle_checks.append(("no_runtime_errors",
                bool(r6.get("passed")) and not r6.get("runtime_errors")))

            # Check 4: enemy patrol is meaningful (moves away from home)
            r5 = rpc("play_and_verify", {"steps": [
                {"wait_ms": 800, "assert": {"expression": "abs(_enemy.position.x - 300.0) > 10",
                    "expected": True,
                    "description": "the first enemy patrols away from its home"}},
            ]}, 914)
            oracle_checks.append(("enemy_patrols", bool(r5.get("passed"))))

            # Check 5: touching the enemy actually kills (deaths > 0 via a
            # deliberate band crossing, not the vacuous >= 0)
            r7 = rpc("play_and_verify", {"steps": death_check_steps()}, 916)
            oracle_checks.append(("enemy_kills", bool(r7.get("passed"))))

            # Check 6: two enemies really exist (goal 08 added a second one)
            r8 = rpc("play_and_verify", {"steps": [
                {"wait_ms": 200, "assert": {"expression": "ENEMY_COUNT == 2", "expected": True,
                    "description": "the second enemy survived later merges (goal 08)"}},
            ]}, 917)
            oracle_checks.append(("two_enemies", bool(r8.get("passed"))))

            # Check 7: pause works
            r4 = rpc("play_and_verify", {"steps": [
                {"action": "ui_cancel", "pressed": True, "wait_ms": 300,
                 "assert": {"expression": "get_tree().paused", "expected": True}},
                {"action": "ui_cancel", "pressed": False, "wait_ms": 100},
                {"action": "ui_cancel", "pressed": True, "wait_ms": 300,
                 "assert": {"expression": "get_tree().paused", "expected": False}},
                {"action": "ui_cancel", "pressed": False, "wait_ms": 100},
            ]}, 913)
            oracle_checks.append(("pause_resume", bool(r4.get("passed"))))

            # Check 8: both feedback systems survived every later merge
            # (goals 05/05b added sfx + particles; 06-10 each regenerate the
            # full controller — the wiring must still be there at the end)
            r9 = rpc("play_and_verify", {"steps": [
                {"wait_ms": 200, "assert": {"expression": "_sfx_player != null and _burst_player != null",
                    "expected": True,
                    "description": "sfx + particle feedback wiring survived all merges (goals 05/05b)"}},
            ]}, 918)
            oracle_checks.append(("feedback_wiring", bool(r9.get("passed"))))

        except Exception as exc:
            oracle_checks.append(("oracle_error", False))
            print(f"  Oracle error: {str(exc)[:200]}")

        rpc("stop_project", {"allow_window": True}, 999)

        print(f"\nORACLE RESULTS:")
        oracle_pass = 0
        for name, ok in oracle_checks:
            print(f"  {name}: {'✅' if ok else '❌'}")
            if ok:
                oracle_pass += 1
        print(f"  Oracle: {oracle_pass}/{len(oracle_checks)}")

        # Final game stats
        scripts = list((SCRATCH / "scripts").glob("*.gd")) if (SCRATCH / "scripts").exists() else []
        scenes = list((SCRATCH / "scenes").glob("*.tscn")) if (SCRATCH / "scenes").exists() else []
        print(f"\nFINAL GAME ARTIFACTS:")
        print(f"  Scripts: {len(scripts)}")
        print(f"  Scenes: {len(scenes)}")
        print(f"  Ledger entries: {results[-1]['ledger_goals'] if results else 0}")
        print(f"  Game model counts: {results[-1]['model_counts'] if results else {}}")

        # P0-2: independent oracle checks gate the final verdict — completed
        # goals alone are a claim, not evidence.
        overall = completed == len(GOALS) and oracle_pass == len(oracle_checks)
        print(f"\n{'='*60}")
        print(f"OVERALL: {'PASS' if overall else 'PARTIAL'} — "
              f"{completed}/{len(GOALS)} goals, {oracle_pass}/{len(oracle_checks)} oracle checks")
        print(f"{'='*60}")

        return 0 if overall else 1
    finally:
        editor.kill()
        subprocess.run(["taskkill","/PID",str(editor.pid),"/T","/F"], capture_output=True)

if __name__ == "__main__":
    sys.exit(main())
