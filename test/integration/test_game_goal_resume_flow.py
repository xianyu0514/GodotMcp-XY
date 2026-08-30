"""Resume-after-crash regression for the goal closed loop.

The checkpoint chain (persisted plan -> tool cache -> idempotent steps ->
retry -> replan fallback -> resume) is only real if a hard editor crash
mid-workflow loses no completed work and the goal still finishes. This test
kills the editor between slices, restarts it on the same scratch project and
drives the same plan to `completed`, asserting progress never restarts from
zero.
"""

import json
import os
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_game_goal_flow import (  # noqa: E402
    GODOT_EXE, MCP_PORT, SCRATCH, build_scratch_project, tool_call, wait_for_server,
)

PLAN_PATH = "res://.mcp/goal_flow_plan.json"
OBJECTIVE = (
    "Minimal 2D game: an arrow-key player movement controller, a collectible "
    "coin that disappears on touch, and a win label shown after collection. "
    "Validate the scripts and run a project smoke test."
)
PROFILES = ["gameplay_feature", "ui_screen", "quality_assurance"]


def spawn_editor() -> subprocess.Popen:
    return subprocess.Popen(
        [str(GODOT_EXE), "--editor", "--headless", "--path", str(SCRATCH), "--", "--mcp-server", f"--mcp-port={MCP_PORT}"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        cwd=SCRATCH,
    )


def assert_scratch_server() -> None:
    info = tool_call("get_project_info", {}, request_id=1)
    if str(info.get("project_name", "")) != "GoalFlowScratch":
        raise AssertionError(
            f"Port {MCP_PORT} is serving a stale editor for '{info.get('project_name', '?')}'")


def read_plan_progress() -> dict:
    plan_file = SCRATCH / ".mcp" / "goal_flow_plan.json"
    if not plan_file.exists():
        raise AssertionError("checkpoint plan file disappeared after the crash")
    plan = json.loads(plan_file.read_text(encoding="utf-8"))
    done = 0
    statuses = {}
    for task in plan.get("tasks", []):
        status = str(task.get("status", ""))
        statuses[status] = statuses.get(status, 0) + 1
        if status == "done":
            done += 1
    return {"done": done, "statuses": statuses, "workflow_id": str(plan.get("workflow", {}).get("workflow_id", ""))}


def main() -> int:
    build_scratch_project()
    plan_abs = SCRATCH / ".mcp" / "goal_flow_plan.json"

    editor = spawn_editor()
    try:
        wait_for_server()
        assert_scratch_server()

        tool_call("plan_game_workflow",
                  {"action": "plan", "objective": OBJECTIVE, "profiles": PROFILES,
                   "replace": True, "plan_path": PLAN_PATH}, request_id=2)

        # 推进一个有界切片，制造"进行到一半"的检查点。
        partial = tool_call("run_game_workflow",
                            {"plan_path": PLAN_PATH, "max_steps": 6}, request_id=3)
        state = str(partial.get("state", partial.get("status", "")))
        if state == "completed":
            print("[resume-flow] slice already completed the goal; crash test trivially passes")
            return 0
        if state not in ("running", "waiting", "repairing", "repair_required", "needs_input"):
            raise AssertionError(f"unexpected partial state {state}: {json.dumps(partial)[:300]}")
    finally:
        # 硬崩：不给清理机会（terminate 走正常退出，kill 模拟崩溃）。
        editor.kill()
        editor.wait(timeout=15)

    if not plan_abs.exists():
        raise AssertionError("checkpoint plan file missing after hard kill")

    before = read_plan_progress()
    if before["done"] < 3:
        raise AssertionError(f"expected at least 3 done steps before the crash, got {before}")

    # 重启同一项目：模型无需重建上下文，直接续跑同一计划。
    editor = spawn_editor()
    try:
        wait_for_server()
        assert_scratch_server()

        resumed_id: str = ""
        for iteration in range(40):
            run = tool_call("run_game_workflow", {"plan_path": PLAN_PATH}, request_id=100 + iteration)
            state = str(run.get("state", run.get("status", "")))
            progress = run.get("progress", {})
            if iteration == 0:
                resumed_id = str(run.get("workflow_id", ""))
                if resumed_id and before["workflow_id"] and resumed_id != before["workflow_id"]:
                    raise AssertionError(
                        f"resume created a new workflow {resumed_id} instead of continuing {before['workflow_id']}")
                done_now = int(progress.get("done", 0))
                if done_now < before["done"]:
                    raise AssertionError(
                        f"progress regressed after restart: {before['done']} -> {done_now}")
                print(f"[resume-flow] resumed workflow {resumed_id or '(same plan)'} "
                      f"with {done_now}/{progress.get('pending', '?')} steps intact", flush=True)
            print(f"[resume-flow] iter {iteration}: state={state} progress={json.dumps(progress)[:120]}", flush=True)
            if state == "completed":
                if not run.get("executed"):
                    raise AssertionError("completed without any executed steps")
                after = read_plan_progress()
                if after["done"] < before["done"]:
                    raise AssertionError("final done count regressed")
                print(f"[resume-flow] completed after crash+restart: {before['done']} done before crash, "
                      f"{after['done']} done after; statuses={after['statuses']}")
                return 0
            if state == "needs_input" or (state == "waiting" and run.get("needs_input")):
                raise AssertionError(f"resume stalled needing input: {json.dumps(run.get('needs_input', []))[:400]}")
            if state in ("blocked", "replan_required", "recovery_required", "failed", "error"):
                raise AssertionError(
                    f"resume failed with {state}: {str(run.get('blocked_reason', ''))[:300]}")
            time.sleep(0.5)
        raise TimeoutError("resumed goal did not complete in time")
    finally:
        editor.terminate()
        try:
            editor.wait(timeout=10)
        except subprocess.TimeoutExpired:
            editor.kill()
            editor.wait(timeout=10)
        if os.environ.get("GOAL_FLOW_KEEP") != "1":
            import shutil
            shutil.rmtree(SCRATCH, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
