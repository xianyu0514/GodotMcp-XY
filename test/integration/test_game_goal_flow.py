"""Goal-level closed-loop regression.

Builds a minimal scratch project with the plugin installed, boots a real
headless editor, hands plan_game_workflow a complete-but-small game goal and
advances run_game_workflow until the persisted DAG reaches `completed` with
evidence. Any failure here is a real closed-loop defect — unit tests cannot
see cross-layer editor races, and the dev repo's own test suite would skew
the QA profile semantics.
"""

import json
import os
import shutil
import subprocess
import sys
import time
import urllib.request
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
GODOT_EXE = Path(os.environ.get("GODOT_EXE", r"C:\SourceCode\Godot_v4.6.2-stable_mono_win64\Godot_v4.6.2-stable_mono_win64_console.exe"))
MCP_PORT = int(os.environ.get("MCP_PORT", "9087"))
MCP_URL = f"http://127.0.0.1:{MCP_PORT}/mcp"
SCRATCH = REPO_ROOT / "tmp_goal_flow_project"
PLAN_PATH = "res://.mcp/goal_flow_plan.json"
RUN_ITERATIONS = int(os.environ.get("GOAL_FLOW_ITERATIONS", "40"))

OBJECTIVE = (
    "Minimal 2D game: an arrow-key player movement controller, a collectible "
    "coin that disappears on touch, and a win label shown after collection. "
    "Validate the scripts and run a project smoke test."
)
PROFILES = ["gameplay_feature", "ui_screen", "quality_assurance"]

PROJECT_GODOT = """config_version=5

[application]

config/name="GoalFlowScratch"

[editor_plugins]

enabled=PackedStringArray("res://addons/godot_mcp/plugin.cfg")
"""


def rpc_call(method: str, params: dict | None = None, request_id: int = 1, timeout: float = 240.0) -> dict:
    payload = {"jsonrpc": "2.0", "method": method, "params": params or {}, "id": request_id}
    request = urllib.request.Request(
        MCP_URL,
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    body = ""
    for attempt in range(3):
        try:
            with urllib.request.urlopen(request, timeout=timeout) as response:
                body = response.read().decode("utf-8")
            if body.strip():
                return json.loads(body)
        except Exception:
            if attempt == 2:
                raise
        time.sleep(2.0)
    raise AssertionError(f"Empty response from MCP server after retries: {method}")


def tool_call(name: str, arguments: dict | None = None, request_id: int = 100, timeout: float = 240.0) -> dict:
    response = rpc_call("tools/call", {"name": name, "arguments": arguments or {}}, request_id=request_id, timeout=timeout)
    result = response.get("result", {})
    if result.get("isError"):
        raise AssertionError(f"Tool {name} failed: {result['content'][0]['text']}")
    if result.get("structuredContent"):
        return result["structuredContent"]
    text = result.get("content", [{}])[0].get("text", "")
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        return {"raw": text[:400]}


def wait_for_server(timeout_seconds: float = 90.0) -> None:
    deadline = time.time() + timeout_seconds
    while time.time() < deadline:
        try:
            rpc_call("tools/list", timeout=5.0)
            return
        except Exception:
            time.sleep(1.0)
    raise TimeoutError(f"Timed out waiting for MCP server on port {MCP_PORT}")


def build_scratch_project() -> None:
    if SCRATCH.exists():
        shutil.rmtree(SCRATCH, ignore_errors=True)
    (SCRATCH / "addons").mkdir(parents=True)
    shutil.copytree(REPO_ROOT / "addons" / "godot_mcp", SCRATCH / "addons" / "godot_mcp")
    (SCRATCH / "project.godot").write_text(PROJECT_GODOT, encoding="utf-8", newline="\n")


def main() -> int:
    build_scratch_project()
    process = subprocess.Popen(
        [str(GODOT_EXE), "--editor", "--headless", "--path", str(SCRATCH), "--", "--mcp-server", f"--mcp-port={MCP_PORT}"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        cwd=SCRATCH,
    )
    try:
        wait_for_server()
        # 残留服务器防串台：确认应答的确实是 scratch 项目（project_name 一致）。
        info = tool_call("get_project_info", {}, request_id=1)
        if str(info.get("project_name", "")) != "GoalFlowScratch":
            raise AssertionError(
                f"Port {MCP_PORT} is serving a stale editor for project "
                f"'{info.get('project_name', '?')}', not the scratch project")

        plan = tool_call(
            "plan_game_workflow",
            {"action": "plan", "objective": OBJECTIVE, "profiles": PROFILES,
             "replace": True, "plan_path": PLAN_PATH},
            request_id=2,
        )
        if str(plan.get("status", "")) not in ("planned", "resumed", "ok", "compiled", "success"):
            raise AssertionError(f"plan_game_workflow returned unexpected status: {json.dumps(plan)[:600]}")

        for iteration in range(RUN_ITERATIONS):
            run = tool_call("run_game_workflow", {"plan_path": PLAN_PATH}, request_id=100 + iteration)
            state = str(run.get("state", run.get("status", "")))
            print(f"[goal-flow] iter {iteration}: state={state} progress={json.dumps(run.get('progress', {}))[:160]}", flush=True)
            if state == "completed":
                executed = run.get("executed", [])
                if not executed:
                    raise AssertionError("completed without any executed steps")
                print(f"[goal-flow] completed after {iteration + 1} run calls; "
                      f"executed {len(executed)} steps in the last slice")
                return 0
            if state == "needs_input" or (state == "waiting" and run.get("needs_input")):
                needs = run.get("needs_input", run.get("needs", []))
                raise AssertionError(f"Goal stalled requiring input — derivation gap: {json.dumps(needs)[:600]}")
            if state == "waiting":
                # 纯 pending（无缺失输入）：异步步骤进行中，继续轮询。
                time.sleep(1.0)
                continue
            if state in ("blocked", "replan_required", "recovery_required", "failed", "error"):
                last = run.get("executed", [])[-1] if run.get("executed") else {}
                raise AssertionError(
                    f"Goal reached terminal failure state {state} at {last.get('tool_name', '?')}: "
                    f"{str(run.get('blocked_reason', ''))[:300]}")
            time.sleep(0.5)

        raise TimeoutError(f"Goal did not complete within {RUN_ITERATIONS} run calls")
    finally:
        process.terminate()
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=10)
        if os.environ.get("GOAL_FLOW_KEEP") != "1":
            shutil.rmtree(SCRATCH, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
