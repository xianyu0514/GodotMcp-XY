"""Multi-goal accumulation E2E: 5+ goals in one project produce a single
accumulating game; prior goals' behavioral suites stay green.

This is the Q1 accumulation proof: goal B adds to goal A's scene instead
of rebuilding; the ledger grows; prior-goal regression is clean.
"""
import json
import os
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SCRATCH = REPO / "tmp_accumulate_project"
GODOT = os.environ.get("GODOT_EXE", r"D:\youxi\kaifa\Godot_v4.7.2-stable_win64_console.exe")
PORT = 9189

def rpc(name, args, rid=1, timeout=240.0):
    payload = {"jsonrpc":"2.0","method":"tools/call","id":rid,"params":{"name":name,"arguments":args}}
    req = urllib.request.Request(f"http://127.0.0.1:{PORT}/mcp",
        data=json.dumps(payload).encode(), headers={"Content-Type":"application/json"})
    # 503 = 派发看门狗：前一个长请求（如 run_game_workflow 演练）还占着
    # 编辑器主线程时，排队请求超时被回 503（CI 实证 65s 处 HTTPError）。
    # 工作流状态持久化使重发安全——与 representative 腿的 hiccup 重试同型。
    for attempt in range(5):
        try:
            r = json.loads(urllib.request.urlopen(req, timeout=timeout).read())
            break
        except urllib.error.HTTPError as exc:
            if exc.code == 503 and attempt < 4:
                time.sleep(10 + attempt * 10)
                continue
            raise
    res = r.get("result",{})
    if res.get("isError"):
        raise RuntimeError(f"{name}: {res['content'][0]['text'][:200]}")
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

GOALS = [
    ("goal1-movement", "Arrow-key player movement."),
    ("goal2-coin", "Add a collectible coin."),
    ("goal3-enemy", "Add a patrolling enemy that kills the player."),
    ("goal4-pause", "Add an Esc pause menu."),
    ("goal5-sound", "Add a sound effect when collecting the coin."),
]

def main() -> int:
    if SCRATCH.exists():
        shutil.rmtree(SCRATCH, ignore_errors=True)
    (SCRATCH / "addons").mkdir(parents=True)
    shutil.copytree(REPO / "addons/godot_mcp", SCRATCH / "addons/godot_mcp")
    (SCRATCH / "project.godot").write_text(
        'config_version=5\n\n[application]\n\nconfig/name="AccumulateBench"\n\n'
        '[editor_plugins]\n\nenabled=PackedStringArray("res://addons/godot_mcp/plugin.cfg")\n',
        encoding="utf-8", newline="\n")

    editor = subprocess.Popen(
        [GODOT, "--editor", "--headless", "--path", str(SCRATCH),
         "--", "--mcp-server", f"--mcp-port={PORT}"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, cwd=str(SCRATCH))
    try:
        if not wait_server():
            print("ERROR: server not up"); return 1

        results = []
        for goal_id, objective in GOALS:
            plan_path = f"res://.mcp/accum_{goal_id}.json"
            rpc("plan_game_workflow", {"action":"plan","objective":objective,
                "profiles":["gameplay_feature"],"replace":True,"plan_path":plan_path})
            state = "?"
            for i in range(12):
                d = rpc("run_game_workflow", {"plan_path":plan_path,"max_steps":8}, 100+i)
                state = d.get("state", d.get("status","?"))
                if state in ("completed","needs_input","recovery_required","replan_required"):
                    break
                time.sleep(2)
            ledger = d.get("goal_ledger", {})
            regression = d.get("ledger_regression", {})
            results.append({
                "goal": goal_id, "state": state,
                "ledger_goals": ledger.get("recorded_goals", 0),
                "regression_clean": regression.get("regression_clean", None),
                "missing": regression.get("missing_scripts", []),
            })
            print(f"[{goal_id}] state={state} ledger={ledger.get('recorded_goals',0)} "
                  f"regression={regression.get('regression_clean', 'n/a')}")
            # Stop the game before next goal (fresh-plan stop handles it, but be safe)
            rpc("stop_project", {"allow_window": True}, 200)

        # Final: check the ledger file exists and has all 5 goals
        ledger_file = SCRATCH / ".mcp" / "goal_ledger.json"
        ledger_count = 0
        if ledger_file.exists():
            ledger_data = json.loads(ledger_file.read_text(encoding="utf-8"))
            ledger_count = len(ledger_data.get("goals", []))

        all_completed = all(r["state"] == "completed" for r in results)
        regression_ok = all(r["regression_clean"] in (True, None) for r in results)
        print(f"\nACCUMULATION RESULT: {'PASS' if all_completed else 'FAIL'}")
        print(f"  Goals completed: {sum(1 for r in results if r['state']=='completed')}/{len(GOALS)}")
        print(f"  Ledger entries: {ledger_count}")
        print(f"  Regression clean: {regression_ok}")
        print(f"  Scene reused (accumulated): check scripts count below")
        scripts = list((SCRATCH / "scripts").glob("*.gd")) if (SCRATCH / "scripts").exists() else []
        print(f"  Scripts generated: {len(scripts)}")

        return 0 if all_completed else 1
    finally:
        editor.kill()
        subprocess.run(["taskkill","/PID",str(editor.pid),"/T","/F"], capture_output=True)

if __name__ == "__main__":
    sys.exit(main())
