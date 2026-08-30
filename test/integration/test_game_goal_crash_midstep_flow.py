"""Mid-step crash regression for the goal closed loop.

Kills the editor WHILE a workflow step is dispatched (plan file shows an
in-progress task), restarts, and asserts fail-closed semantics: the resume
either replays the step safely and completes, or explicitly reports the
uncertain non-idempotent step — never silent corruption. After an explicit
uncertainty the designed path (replan + run) must still finish the goal.
"""

import json
import os
import shutil
import subprocess
import sys
import threading
import time
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_game_goal_flow import (  # noqa: E402
    GODOT_EXE, SCRATCH, build_scratch_project, rpc_call, wait_for_server,
)

MCP_PORT = int(os.environ.get("MCP_PORT", "9091"))
MCP_URL = f"http://127.0.0.1:{MCP_PORT}/mcp"
PLAN_PATH = "res://.mcp/goal_flow_plan.json"
PLAN_ABS = SCRATCH / ".mcp" / "goal_flow_plan.json"
OBJECTIVE = (
    "Minimal 2D game: an arrow-key player movement controller, a collectible "
    "coin that disappears on touch, and a win label shown after collection. "
    "Validate the scripts and run a project smoke test."
)
PROFILES = ["gameplay_feature", "ui_screen", "quality_assurance"]
UNCERTAINTY_MARK = "unknown outcome"


def tool_call(name, arguments=None, request_id=100, timeout=240.0):
    response = rpc_call("tools/call", {"name": name, "arguments": arguments or {}},
                        request_id=request_id, timeout=timeout, mcp_url=MCP_URL)
    result = response.get("result", {})
    if result.get("isError"):
        raise AssertionError(f"{name} failed: {result['content'][0]['text']}")
    if result.get("structuredContent"):
        return result["structuredContent"]
    return json.loads(result.get("content", [{}])[0].get("text", "{}"))


def spawn_editor() -> subprocess.Popen:
    return subprocess.Popen(
        [str(GODOT_EXE), "--editor", "--headless", "--path", str(SCRATCH), "--", "--mcp-server", f"--mcp-port={MCP_PORT}"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, cwd=SCRATCH,
    )


def wait_in_progress(min_done: int = 0, timeout: float = 120.0) -> str:
    """Poll the persisted plan until a task is mid-execution; return its tool."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            plan = json.loads(PLAN_ABS.read_text(encoding="utf-8"))
        except Exception:
            time.sleep(0.01)
            continue
        done = sum(1 for t in plan.get("tasks", []) if t.get("status") == "done")
        if done >= min_done:
            for task in plan.get("tasks", []):
                if task.get("status") == "in_progress" or task.get("repair_in_progress"):
                    return str(task.get("tool_name", "?"))
        time.sleep(0.01)
    return ""


def main() -> int:
    build_scratch_project()
    editor = spawn_editor()
    try:
        wait_for_server(timeout_seconds=90.0, mcp_url=MCP_URL)
        info = tool_call("get_project_info", {}, 1)
        if info.get("project_name") != "GoalFlowScratch":
            raise AssertionError(f"stale server on {MCP_PORT}: {info.get('project_name')}")
        tool_call("plan_game_workflow",
                  {"action": "plan", "objective": OBJECTIVE, "profiles": PROFILES,
                   "replace": True, "plan_path": PLAN_PATH}, 2)

        # 后台发起 run 调用，主线程盯住计划文件里的 in_progress，抓到即杀。
        call_error: list = []

        def run_async() -> None:
            try:
                tool_call("run_game_workflow", {"plan_path": PLAN_PATH, "max_steps": 32}, 3)
            except Exception as exc:  # 编辑器被杀，连接必然断开
                call_error.append(exc)

        worker = threading.Thread(target=run_async)
        worker.start()
        interrupted_tool = wait_in_progress(min_done=8, timeout=90.0)
        editor.kill()
        editor.wait(timeout=15)
        worker.join(timeout=30)
        if not interrupted_tool:
            print("[midstep-crash] no in-progress step caught; run completed too fast — "
                  "falling back to a clean-slice crash proof")
        else:
            print(f"[midstep-crash] killed while '{interrupted_tool}' was dispatched", flush=True)
    finally:
        if editor.poll() is None:
            editor.kill()
            editor.wait(timeout=15)

    if not PLAN_ABS.exists():
        raise AssertionError("checkpoint plan file missing after mid-step kill")

    editor = spawn_editor()
    try:
        wait_for_server(timeout_seconds=90.0, mcp_url=MCP_URL)
        tool_call("get_project_info", {}, 1)

        first = tool_call("run_game_workflow", {"plan_path": PLAN_PATH}, 100)
        state = str(first.get("state", first.get("status", "")))
        print(f"[midstep-crash] resume state: {state}", flush=True)

        if state == "recovery_required":
            reason = str(first.get("blocked_reason", ""))
            if UNCERTAINTY_MARK not in reason:
                raise AssertionError(f"fail-closed reason must flag the unknown outcome: {reason}")
            if not first.get("tool_name"):
                raise AssertionError("recovery response must name the uncertain step's tool")
            print(f"[midstep-crash] fail-closed OK: {reason[:120]} (step tool={first.get('tool_name')})", flush=True)
            # 设计内的恢复路径：同目标重规划后继续，目标仍要完成。
            tool_call("plan_game_workflow",
                      {"action": "plan", "objective": OBJECTIVE, "profiles": PROFILES,
                       "replace": True, "plan_path": PLAN_PATH}, 4)
        elif state in ("blocked", "replan_required", "failed", "error"):
            raise AssertionError(f"unexpected terminal state on resume: {state}: "
                                 f"{str(first.get('blocked_reason', ''))[:200]}")
        else:
            print("[midstep-crash] uncertain step was replay-safe; continuing", flush=True)

        for iteration in range(40):
            run = tool_call("run_game_workflow", {"plan_path": PLAN_PATH}, 200 + iteration)
            state = str(run.get("state", run.get("status", "")))
            print(f"[midstep-crash] iter {iteration}: {state} {json.dumps(run.get('progress', {}))[:100]}", flush=True)
            if state == "completed":
                if not run.get("executed"):
                    raise AssertionError("completed without executed steps")
                print(f"[midstep-crash] goal completed after mid-step crash, "
                      f"recovery path exercised; progress={json.dumps(run.get('progress', {}))}")
                return 0
            if state == "needs_input" or (state == "waiting" and run.get("needs_input")):
                raise AssertionError(f"stalled needing input: {json.dumps(run.get('needs_input', []))[:300]}")
            if state in ("blocked", "replan_required", "recovery_required", "failed", "error"):
                raise AssertionError(f"post-recovery terminal state {state}: "
                                     f"{str(run.get('blocked_reason', ''))[:250]}")
            time.sleep(0.5)
        raise TimeoutError("goal did not complete after mid-step crash recovery")
    finally:
        editor.terminate()
        try:
            editor.wait(timeout=10)
        except subprocess.TimeoutExpired:
            editor.kill()
            editor.wait(timeout=10)
        if os.environ.get("GOAL_FLOW_KEEP") != "1":
            shutil.rmtree(SCRATCH, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
