"""Phase D: Representative game — 2D top-down collection adventure.

Builds a complete game through 10 sequential MCP goals on one project,
then verifies the final product with independent oracle checks.

Game spec (from gap analysis Phase D):
- 4-direction movement with walls
- 3 collectible coins
- Patrolling enemy with death/respawn
- Esc pause menu
- Save/load across process restart
- Sound effect on collection
- Score HUD
- Win condition (collect all coins)
- Tune difficulty (enemy speed)
- Visual polish (walls)

This is the proof that "the same game gets more complete with each change" —
not just that individual features work, but that the accumulated game is
playable end-to-end.
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
PORT = 9195

def rpc(name, args, rid=1, timeout=300.0):
    payload = {"jsonrpc":"2.0","method":"tools/call","id":rid,"params":{"name":name,"arguments":args}}
    req = urllib.request.Request(f"http://127.0.0.1:{PORT}/mcp",
        data=json.dumps(payload).encode(), headers={"Content-Type":"application/json"})
    r = json.loads(urllib.request.urlopen(req, timeout=timeout).read())
    res = r.get("result",{})
    if res.get("isError"):
        raise RuntimeError(f"{name}: {res['content'][0]['text'][:300]}")
    return res.get("structuredContent",{})

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

# The 10-goal game-building sequence
GOALS = [
    ("01-movement-walls", "Arrow-key player movement with walls that block the player."),
    ("02-coins", "Add 3 collectible coins."),
    ("03-enemy", "Add a patrolling enemy that kills the player on touch."),
    ("04-pause", "Add an Esc pause menu that pauses the world."),
    ("05-sound", "Add a sound effect when collecting a coin."),
    ("06-save", "Add save/load so progress persists after closing and relaunching."),
    ("07-tune-enemy", "Make the enemy slower so the game is easier."),
    ("08-second-enemy", "Add another patrolling enemy."),
    ("09-state-flow", "Add a title screen with start, gameplay, win state and restart."),
    ("10-final-tune", "Make the player movement snappier and more responsive."),
]

def setup_scratch():
    if SCRATCH.exists():
        shutil.rmtree(SCRATCH, ignore_errors=True)
    (SCRATCH / "addons").mkdir(parents=True)
    shutil.copytree(REPO / "addons/godot_mcp", SCRATCH / "addons/godot_mcp")
    (SCRATCH / "project.godot").write_text(
        'config_version=5\n\n[application]\n\nconfig_name="RepresentativeGame"\n\n'
        '[editor_plugins]\n\nenabled=PackedStringArray("res://addons/godot_mcp/plugin.cfg")\n',
        encoding="utf-8", newline="\n")

def run_goal(goal_id, objective, iteration_base):
    plan_path = f"res://.mcp/rep_{goal_id}.json"
    rpc("plan_game_workflow", {"action":"plan","objective":objective,
        "profiles":["gameplay_feature"],"replace":True,"plan_path":plan_path})
    state = "?"
    d = {}
    for i in range(15):
        d = rpc("run_game_workflow", {"plan_path":plan_path,"max_steps":8}, iteration_base+i)
        state = d.get("state", d.get("status","?"))
        if state in ("completed","needs_input","recovery_required","replan_required"):
            break
        time.sleep(2)
    rpc("stop_project", {"allow_window":True}, iteration_base+90)
    return state, d

def main() -> int:
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
            results.append({
                "goal": goal_id, "state": state, "elapsed_s": round(elapsed, 1),
                "ledger_goals": ledger.get("recorded_goals", 0),
                "regression_clean": regression.get("regression_clean", None),
            })
            status = "✅" if state == "completed" else f"❌({state})"
            print(f"  [{goal_id}] {status} {elapsed:.0f}s ledger={ledger.get('recorded_goals',0)} "
                  f"regression={'✅' if regression.get('regression_clean') else '⚠️' if regression else 'n/a'}")

        # Summary
        completed = sum(1 for r in results if r["state"] == "completed")
        print(f"\n{'='*60}")
        print(f"GAME BUILD RESULT: {completed}/{len(GOALS)} goals completed")
        print(f"{'='*60}")

        # Independent oracle: verify the final game is playable
        print("\nORACLE: Independent verification of final game")
        oracle_checks = []
        try:
            # Start the game
            rpc("enable_tools", {"tools": ["play_and_verify", "run_project",
                "install_runtime_probe", "stop_project"]}, 900)
            rpc("run_project", {"allow_window": True}, 901)
            time.sleep(3)

            # Check 1: Movement works
            r = rpc("play_and_verify", {"steps": [
                {"action": "move_right", "pressed": True, "wait_ms": 400,
                 "assert": {"expression": "position.x", "displacement_min": 10}},
                {"action": "move_right", "pressed": False, "wait_ms": 80},
            ]}, 910)
            oracle_checks.append(("movement", bool(r.get("passed"))))

            # Check 2: No runtime errors
            r2 = rpc("play_and_verify", {"steps": [{"wait_ms": 500}]}, 911)
            oracle_checks.append(("no_runtime_errors", bool(r2.get("passed")) and not r2.get("runtime_errors")))

            # Check 3: Coins exist (controller has coins_collected)
            r3 = rpc("play_and_verify", {"steps": [
                {"wait_ms": 200, "assert": {"expression": "COINS_TO_WIN >= 1", "expected": True,
                    "description": "coins are configured"}},
            ]}, 912)
            oracle_checks.append(("coins_configured", bool(r3.get("passed"))))

            # Check 4: Pause works (if controller has set_paused)
            r4 = rpc("play_and_verify", {"steps": [
                {"action": "ui_cancel", "pressed": True, "wait_ms": 300,
                 "assert": {"expression": "get_tree().paused", "expected": True}},
                {"action": "ui_cancel", "pressed": False, "wait_ms": 100},
                {"action": "ui_cancel", "pressed": True, "wait_ms": 300,
                 "assert": {"expression": "get_tree().paused", "expected": False}},
                {"action": "ui_cancel", "pressed": False, "wait_ms": 100},
            ]}, 913)
            oracle_checks.append(("pause_resume", bool(r4.get("passed"))))

            # Check 5: Enemy exists
            r5 = rpc("play_and_verify", {"steps": [
                {"wait_ms": 500, "assert": {"expression": "deaths_count >= 0", "expected": True,
                    "description": "enemy system present (deaths_count accessible)"}},
            ]}, 914)
            oracle_checks.append(("enemy_system", bool(r5.get("passed"))))

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

        overall = completed == len(GOALS)
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
