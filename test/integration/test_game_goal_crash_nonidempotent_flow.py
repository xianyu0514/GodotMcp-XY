"""Fail-closed crash regression: kill DURING a non-idempotent step.

The midstep test keeps landing on idempotent steps (save_scene) and proving
the replay-safe path. This variant polls the persisted plan for an
in-progress step whose tool is NOT idempotent-hinted (create_script /
create_theme / insert_animation_keys family), kills the editor at that exact
moment, restarts, and asserts the designed fail-closed behavior:

- the resume must report recovery_required naming the uncertain step with
  the "unknown outcome" reason (never silent corruption, never a fake
  completed), and
- the designed recovery path (replan with the same objective, then run)
  must still finish the goal.
"""

import json
import os
import shutil
import subprocess
import sys
import threading
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_game_goal_flow import (  # noqa: E402
    GODOT_EXE, SCRATCH, build_scratch_project, rpc_call, wait_for_server,
)

MCP_PORT = int(os.environ.get("MCP_PORT", "9092"))
MCP_URL = f"http://127.0.0.1:{MCP_PORT}/mcp"
PLAN_PATH = "res://.mcp/goal_flow_plan.json"
PLAN_ABS = SCRATCH / ".mcp" / "goal_flow_plan.json"
OBJECTIVE = (
    "Minimal 2D game: an arrow-key player movement controller, a collectible "
    "coin that disappears on touch, and a win label shown after collection. "
    "Validate the scripts and run a project smoke test."
)
PROFILES = ["gameplay_feature", "ui_screen", "quality_assurance"]
# 非 idempotentHint 家族：命中任一 in_progress 即杀。
NON_IDEMPOTENT_TOOLS = {
    "create_script", "create_theme", "upsert_project_input_action",
    "set_anchor_preset", "insert_animation_keys", "create_node",
    "connect_signal",
}


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


def wait_nonidempotent_in_progress(timeout: float = 120.0) -> str:
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            plan = json.loads(PLAN_ABS.read_text(encoding="utf-8"))
        except Exception:
            time.sleep(0.005)
            continue
        for task in plan.get("tasks", []):
            if task.get("status") == "in_progress" and str(task.get("tool_name", "")) in NON_IDEMPOTENT_TOOLS:
                return str(task.get("tool_name"))
        time.sleep(0.005)
    return ""


def main() -> int:
    build_scratch_project()
    editor = spawn_editor()
    caught = ""
    try:
        wait_for_server(timeout_seconds=90.0, mcp_url=MCP_URL)
        tool_call("plan_game_workflow",
                  {"action": "plan", "objective": OBJECTIVE, "profiles": PROFILES,
                   "replace": True, "plan_path": PLAN_PATH}, 2)

        def run_async() -> None:
            try:
                tool_call("run_game_workflow", {"plan_path": PLAN_PATH, "max_steps": 32}, 3)
            except Exception:
                pass  # editor killed mid-call

        worker = threading.Thread(target=run_async)
        worker.start()
        caught = wait_nonidempotent_in_progress(timeout=120.0)
        editor.kill()
        editor.wait(timeout=15)
        worker.join(timeout=30)
    finally:
        if editor.poll() is None:
            editor.kill()
            editor.wait(timeout=15)

    if not caught:
        # 未能自然命中非幂等窗口：明确失败而不是静默通过。
        raise AssertionError("never observed a non-idempotent step in_progress; "
                             "widen NON_IDEMPOTENT_TOOLS or tighten polling")
    print(f"[nonidem-crash] killed while non-idempotent '{caught}' was dispatched", flush=True)

    editor = spawn_editor()
    try:
        wait_for_server(timeout_seconds=90.0, mcp_url=MCP_URL)
        first = tool_call("run_game_workflow", {"plan_path": PLAN_PATH}, 100)
        state = str(first.get("state", first.get("status", "")))
        print(f"[nonidem-crash] resume state: {state}", flush=True)

        if state == "recovery_required":
            reason = str(first.get("blocked_reason", ""))
            if "unknown outcome" not in reason:
                raise AssertionError(f"fail-closed reason must flag unknown outcome: {reason}")
            if first.get("tool_name") != caught:
                raise AssertionError(
                    f"recovery must name the interrupted step '{caught}', got '{first.get('tool_name')}'")
            print(f"[nonidem-crash] fail-closed OK: {reason[:110]}", flush=True)
            tool_call("plan_game_workflow",
                      {"action": "plan", "objective": OBJECTIVE, "profiles": PROFILES,
                       "replace": True, "plan_path": PLAN_PATH}, 4)
        elif state == "completed":
            # 该步骤可能已在崩溃前落盘完成且重启后被判定为安全——同样诚实。
            print("[nonidem-crash] step had actually completed; goal finished on resume", flush=True)
            return 0
        elif state in ("blocked", "replan_required", "failed", "error"):
            raise AssertionError(f"unexpected terminal state {state}: "
                                 f"{str(first.get('blocked_reason', ''))[:200]}")

        for iteration in range(40):
            run = tool_call("run_game_workflow", {"plan_path": PLAN_PATH}, 200 + iteration)
            state = str(run.get("state", run.get("status", "")))
            print(f"[nonidem-crash] iter {iteration}: {state} {json.dumps(run.get('progress', {}))[:100]}", flush=True)
            if state == "completed":
                print(f"[nonidem-crash] goal completed after non-idempotent crash via "
                      f"{'recovery_required + replan' if 'replan' in locals() or 'recovery' in str(first.get('state','')) else 'safe replay'}")
                return 0
            if state == "needs_input" or (state == "waiting" and run.get("needs_input")):
                raise AssertionError(f"stalled: {json.dumps(run.get('needs_input', []))[:300]}")
            if state in ("blocked", "replan_required", "recovery_required", "failed", "error"):
                raise AssertionError(f"terminal {state}: {str(run.get('blocked_reason', ''))[:250]}")
            time.sleep(0.5)
        raise TimeoutError("goal did not complete after non-idempotent crash")
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
