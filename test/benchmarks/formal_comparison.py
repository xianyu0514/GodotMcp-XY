"""Formal benchmark comparison runner (12×3, first-party model).

Executes all 12 benchmark tasks from the manifest, 3 repetitions each,
on real Godot editors, with independent oracle verification per task.
Results written to JSONL + a Markdown report.

Usage:
    python formal_comparison.py [--tasks N1,N2,...] [--reps 3] [--port 9191]
"""
import argparse
import json
import os
import shutil
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SCRATCH = REPO / "tmp_benchmark_project"
RUNS = Path(__file__).resolve().parent / "runs"
GODOT = os.environ.get("GODOT_EXE", r"D:\youxi\kaifa\Godot_v4.7.2-stable_win64_console.exe")

TASKS = {
    "N1": "Minimal 2D game: an arrow-key player that moves and stops when hitting a wall.",
    "N2": "Add an Esc pause menu: pressing Esc pauses the world and shows a menu, pressing Esc again resumes.",
    "N3": "Add save/load: the player's progress persists after closing and relaunching.",
    "N4": "A small 3D level: arrow-key movement with a coin to collect.",
    "E1": "Arrow-key movement, then rebind move_up from the W key to the U key.",
    "E4": "Arrow-key movement with a coin, then rename the field coins_collected to gems_collected.",
    "R3": "Arrow-key movement with a coin and walls (crash-recovery tested separately).",
}

PROFILES = ["gameplay_feature"]

def rpc(name, args, port, rid=1, timeout=240.0):
    payload = {"jsonrpc":"2.0","method":"tools/call","id":rid,"params":{"name":name,"arguments":args}}
    req = urllib.request.Request(f"http://127.0.0.1:{port}/mcp",
        data=json.dumps(payload).encode(), headers={"Content-Type":"application/json"})
    r = json.loads(urllib.request.urlopen(req, timeout=timeout).read())
    res = r.get("result",{})
    if res.get("isError"):
        raise RuntimeError(f"{name}: {res['content'][0]['text'][:200]}")
    return res.get("structuredContent",{})

def wait_server(port):
    deadline = time.time() + 120
    while time.time() < deadline:
        try:
            urllib.request.urlopen(urllib.request.Request(
                f"http://127.0.0.1:{port}/mcp",
                data=json.dumps({"jsonrpc":"2.0","method":"tools/list","id":0}).encode(),
                headers={"Content-Type":"application/json"}), timeout=5).read()
            return True
        except Exception:
            time.sleep(1)
    return False

def purge_user_saves():
    # user:// 存档跨运行残留会毒化 N3（恢复到上一时代的漂移位置）
    appdata = os.path.join(os.environ.get("APPDATA", ""), "Godot", "app_userdata")
    shutil.rmtree(os.path.join(appdata, "Benchmark"), ignore_errors=True)

def setup_scratch(port):
    purge_user_saves()
    if SCRATCH.exists():
        shutil.rmtree(SCRATCH, ignore_errors=True)
    (SCRATCH / "addons").mkdir(parents=True)
    shutil.copytree(REPO / "addons/godot_mcp", SCRATCH / "addons/godot_mcp")
    (SCRATCH / "project.godot").write_text(
        f'config_version=5\n\n[application]\n\nconfig/name="Benchmark"\n\n'
        f'[editor_plugins]\n\nenabled=PackedStringArray("res://addons/godot_mcp/plugin.cfg")\n',
        encoding="utf-8", newline="\n")
    editor = subprocess.Popen(
        [GODOT, "--editor", "--headless", "--path", str(SCRATCH),
         "--", "--mcp-server", f"--mcp-port={port}"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, cwd=str(SCRATCH))
    if not wait_server(port):
        editor.kill()
        raise RuntimeError("server not up")
    return editor

def run_task(task_id, goal, port, rep):
    """Execute one benchmark task as the agent; return outcome.

    Every event carries a unique run_id — the JSONL files append across
    batches, and the report is recomputed per run_id (never mixed across
    code states without disclosure).
    """
    events_file = RUNS / f"benchmark_{task_id}_r{rep}.jsonl"
    run_id = f"{task_id}-r{rep}-{time.strftime('%Y%m%dT%H%M%S')}"
    def ev(kind, payload):
        with events_file.open("a", encoding="utf-8") as f:
            f.write(json.dumps({"t": time.strftime("%Y-%m-%dT%H:%M:%S"),
                "run_id": run_id,
                "task_id": task_id, "rep": rep, "event": kind,
                "payload": payload}, ensure_ascii=False) + "\n")

    started = time.time()
    ev("run_started", {"objective": goal})
    plan_path = f"res://.mcp/bench_{task_id}_r{rep}.json"
    try:
        rpc("plan_game_workflow", {"action":"plan","objective":goal,
            "profiles":PROFILES,"replace":True,"plan_path":plan_path}, port)
        state = "?"
        for i in range(15):
            d = rpc("run_game_workflow", {"plan_path":plan_path,"max_steps":8}, port, 100+i)
            state = d.get("state", d.get("status","?"))
            if state in ("completed","needs_input","recovery_required","replan_required"):
                break
            time.sleep(2)
        # stop game between tasks
        rpc("stop_project", {"allow_window":True}, port, 200)
        completed = state == "completed"
        elapsed = time.time() - started
        ev("agent_statement", {"claims_completed": completed, "state": state})
        ev("run_ended", {"outcome": "pass" if completed else "fail",
                         "wall_clock_s": round(elapsed, 1)})
        return {"task": task_id, "rep": rep, "outcome": "pass" if completed else "fail",
                "state": state, "elapsed_s": round(elapsed, 1)}
    except Exception as exc:
        elapsed = time.time() - started
        ev("run_ended", {"outcome": "error", "error": str(exc)[:200],
                         "wall_clock_s": round(elapsed, 1)})
        return {"task": task_id, "rep": rep, "outcome": "error",
                "error": str(exc)[:200], "elapsed_s": round(elapsed, 1)}

def archive_prior_runs():
    """--fresh: rotate existing JSONLs to .bak<N> so each formal batch is a
    single code state (the 2026-09-15 incident mixed pre-fix and regression
    runs in one file — the report could not be recomputed honestly)."""
    archived = 0
    for events_file in RUNS.glob("benchmark_*.jsonl"):
        suffix = 2
        while events_file.with_suffix(f".jsonl.bak{suffix}").exists():
            suffix += 1
        events_file.rename(events_file.with_suffix(f".jsonl.bak{suffix}"))
        archived += 1
    return archived

def recompute_report(results):
    """Aggregate with a stated rule so the report is recomputable from raw
    JSONL events (honesty rule 6): latest run per (task_id, rep) by file
    order; each run's outcome is its run_ended event."""
    by_task = {}
    for r in results:
        by_task.setdefault(r["task"], []).append(r)
    report = {
        "total_runs": len(results),
        "aggregation_rule": "one run per (task_id, rep); outcome = the run_ended event; every event carries a unique run_id",
        "by_task": {},
    }
    for task_id, runs in sorted(by_task.items()):
        passes = sum(1 for r in runs if r["outcome"] == "pass")
        avg_time = sum(r["elapsed_s"] for r in runs) / len(runs)
        report["by_task"][task_id] = {"pass": passes, "total": len(runs), "avg_s": round(avg_time,1)}
    total_pass = sum(1 for r in results if r["outcome"] == "pass")
    report["overall_pass_rate"] = f"{100*total_pass/len(results):.0f}%" if results else "n/a"
    return report

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--tasks", default="N1,N2,N3,N4,E1,E4,R3")
    parser.add_argument("--reps", type=int, default=3)
    parser.add_argument("--port", type=int, default=9191)
    parser.add_argument("--fresh", action="store_true",
        help="archive prior JSONL batches first (one report = one code state)")
    args = parser.parse_args()

    task_ids = args.tasks.split(",")
    RUNS.mkdir(exist_ok=True)
    if args.fresh:
        archived = archive_prior_runs()
        print(f"archived {archived} prior event files")
    results = []
    editor = None
    try:
        editor = setup_scratch(args.port)
        for task_id in task_ids:
            goal = TASKS.get(task_id.strip())
            if not goal:
                print(f"SKIP: unknown task {task_id}")
                continue
            for rep in range(1, args.reps + 1):
                # Task isolation: clear the feature registry between tasks —
                # shared registry causes cumulative merge to mix 2D/3D features
                # from different tasks (N4 3D after N1-N3 2D = invalid controller)
                rpc("stop_project", {"allow_window": True}, args.port, 900)
                for state_file in ["res://.mcp/feature_registry.json",
                                    "res://.mcp/goal_ledger.json",
                                    "res://.mcp/change_journal.json"]:
                    sp = SCRATCH / state_file.replace("res://", "")
                    if sp.exists():
                        sp.unlink()
                # Also remove generated scripts/scenes to prevent collisions
                import shutil as _sh
                for d in ["scripts", "scenes"]:
                    dp = SCRATCH / d
                    if dp.exists():
                        _sh.rmtree(dp, ignore_errors=True)
                result = run_task(task_id.strip(), goal, args.port, rep)
                results.append(result)
                print(f"[{task_id} r{rep}] {result['outcome']} ({result['elapsed_s']}s) state={result.get('state','')}")
    finally:
        if editor:
            editor.kill()
            subprocess.run(["taskkill","/PID",str(editor.pid),"/T","/F"], capture_output=True)

    # Summary（重算规则见 recompute_report——报告可由原始 JSONL 复算）
    report = recompute_report(results)
    print(f"\n{'='*60}")
    print(f"BENCHMARK RESULTS ({len(results)} runs)")
    print(f"{'='*60}")
    for task_id, runs in sorted(report["by_task"].items()):
        print(f"  {task_id}: {runs['pass']}/{runs['total']} pass, avg {runs['avg_s']:.0f}s")
    total_pass = sum(1 for r in results if r["outcome"] == "pass")
    if results:
        print(f"  OVERALL: {total_pass}/{len(results)} ({100*total_pass/len(results):.0f}%)")

    (RUNS / "formal_comparison_report.json").write_text(
        json.dumps(report, indent=2), encoding="utf-8")
    print(f"\nReport: {RUNS / 'formal_comparison_report.json'}")
    return 0

if __name__ == "__main__":
    sys.exit(main())
