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

SCENARIOS = [
    {
        "name": "playable-minimal-game",
        "objective": (
            "Minimal 2D game: an arrow-key player movement controller, a collectible "
            "coin that disappears on touch, and a win label shown after collection. "
            "Validate the scripts and run a project smoke test."
        ),
        "profiles": ["gameplay_feature", "ui_screen", "quality_assurance"],
        "assert_playable": True,
    },
    {
        "name": "performance-and-health",
        "objective": (
            "Audit project health and verify the game holds at least 30 fps "
            "with low memory and no runtime errors."
        ),
        "profiles": ["project_health", "performance"],
        "assert_playable": False,
    },
    {
        "name": "runtime-debug",
        "objective": (
            "Debug the running game: collect editor logs and the runtime scene "
            "tree, and assert no runtime errors occur."
        ),
        "profiles": ["runtime_debug"],
        "assert_playable": False,
    },
    {
        "name": "level-design-tilemap",
        "objective": (
            "Build a tilemap level: create a tileset, configure its physics "
            "layer, paint cells into the map, save the scene and verify the "
            "visual result against a baseline."
        ),
        "profiles": ["level_design"],
        "assert_playable": False,
    },
    {
        "name": "enemy-patrol",
        "objective": (
            "Arrow-key movement with a patrolling enemy that kills and "
            "respawns the player on touch."
        ),
        "profiles": ["gameplay_feature"],
        "assert_enemy": True,
    },
    {
        "name": "input-remap",
        "objective": (
            "Arrow-key movement, then rebind move_up from the W key to the "
            "U key and verify the new binding."
        ),
        "profiles": ["gameplay_feature"],
        "assert_remap": True,
    },
    {
        "name": "save-persistence",
        "objective": (
            "Add save/load: the player's progress persists after fully closing "
            "and relaunching the game."
        ),
        "profiles": ["gameplay_feature"],
        "assert_save_persistence": True,
    },
    {
        "name": "pause-menu-behavior",
        "objective": (
            "Esc pause menu: pressing Esc pauses the world and shows a paused "
            "menu, pressing Esc again resumes it. Verify the pause behavior "
            "while playing."
        ),
        "profiles": ["gameplay_feature"],
        "assert_pause_menu": True,
    },
    {
        "name": "animation-audio",
        "objective": (
            "Animate the game: create an animation resource, insert its keys, "
            "then play it and verify the runtime animation state with no "
            "runtime errors; report the audio buses."
        ),
        "profiles": ["animation_audio"],
        "assert_playable": False,
    },
    {
        "name": "asset-pipeline",
        "objective": (
            "Check the asset pipeline: list project resources and import "
            "status, reimport resources and verify no missing dependencies."
        ),
        "profiles": ["asset_pipeline"],
        "assert_playable": False,
    },
    {
        "name": "release-export-validate",
        "objective": (
            "Prepare a release: list export presets and inspect export "
            "template availability, then validate the export preset."
        ),
        "profiles": ["release_export"],
        "assert_playable": False,
        # scratch 无导出模板：验证链完成后 run_export 诚实失败是合法结局。
        "accept_blocked_tool": "run_export",
    },
    {
        "name": "localization",
        "objective": (
            "Extract translatable strings, import the translated messages and "
            "list the localization tables for the game."
        ),
        "profiles": ["localization"],
        "assert_playable": False,
    }]

PROJECT_GODOT = """config_version=5

[application]

config/name="GoalFlowScratch"

[editor_plugins]

enabled=PackedStringArray("res://addons/godot_mcp/plugin.cfg")
"""


def rpc_call(method: str, params: dict | None = None, request_id: int = 1, timeout: float = 240.0, mcp_url: str | None = None) -> dict:
    payload = {"jsonrpc": "2.0", "method": method, "params": params or {}, "id": request_id}
    request = urllib.request.Request(
        mcp_url or MCP_URL,
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


def tool_call(name: str, arguments: dict | None = None, request_id: int = 100, timeout: float = 240.0, mcp_url: str | None = None) -> dict:
    response = rpc_call("tools/call", {"name": name, "arguments": arguments or {}}, request_id=request_id, timeout=timeout, mcp_url=mcp_url)
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


def wait_for_server(timeout_seconds: float = 90.0, mcp_url: str | None = None) -> None:
    deadline = time.time() + timeout_seconds
    while time.time() < deadline:
        try:
            rpc_call("tools/list", timeout=5.0, mcp_url=mcp_url)
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



def _failing_receipt_summaries(name: str) -> str:
    """needs_input/失败时dump未通过步骤的回执摘要，供失败诊断。"""
    try:
        status = tool_call("plan_game_workflow",
                           {"action": "status", "plan_path": PLAN_PATH, "include_plan": True},
                           request_id=97)
        plan = status.get("plan", {})
        out = []
        for t in plan.get("tasks", []):
            if t.get("status") == "done":
                continue
            receipts = [r.get("summary", {}) for r in plan.get("workflow", {}).get("receipts", [])
                        if r.get("step_id") == t.get("id")]
            out.append({"step": t.get("id"), "tool": t.get("tool_name"),
                        "key": t.get("step_key", "?"),
                        "derived": (t.get("derived_inputs", {}) or {}).get("steps", "?"),
                        "status": t.get("status"),
                        "fingerprint": str(t.get("verification_failure_fingerprint", ""))[:100],
                        "receipt_summaries": receipts})
        return json.dumps(out, ensure_ascii=False)[:1500]
    except Exception as exc:  # noqa: BLE001 - diagnostics only
        return f"<receipt dump failed: {exc}>"


def run_scenario(scenario: dict) -> None:
    name = scenario["name"]
    print(f"[goal-flow] scenario: {name}", flush=True)
    if scenario.get("assert_save_persistence"):
        # user:// 在 scratch 重建后仍残留（app_userdata 按项目名存放）：
        # 上一轮的存档会让新游戏从旧位置启动，位移断言全乱。先清档。
        import os
        user_dir = os.path.join(
            os.environ.get("APPDATA", ""), "Godot", "app_userdata", "GoalFlowScratch")
        stale_save = Path(user_dir) / "save_game.json"
        if stale_save.exists():
            stale_save.unlink()
            print(f"[goal-flow] cleared stale user:// save at {stale_save}", flush=True)
    # 场景 = 独立目标：上一个目标完成时其游戏可能仍在播放（同路径场景
    # 会让 run_project 的 already_running 判定复用旧游戏——旧内容、旧脚本）。
    # 每个场景开始前先停掉残留游戏，保证本目标验证的是自己的产物。
    tool_call("enable_tools", {"tools": ["stop_project"]}, request_id=91)
    stopped = tool_call("stop_project", {"allow_window": True}, request_id=92)
    print(f"[goal-flow] pre-scenario game stop: {str(stopped.get('status', stopped))[:60]}", flush=True)
    plan = tool_call(
        "plan_game_workflow",
        {"action": "plan", "objective": scenario["objective"], "profiles": scenario["profiles"],
         "replace": True, "plan_path": PLAN_PATH},
        request_id=2,
    )
    if str(plan.get("status", "")) not in ("planned", "resumed", "ok", "compiled", "success"):
        raise AssertionError(f"[{name}] plan_game_workflow returned unexpected status: {json.dumps(plan)[:600]}")

    for iteration in range(RUN_ITERATIONS):
        run = tool_call("run_game_workflow", {"plan_path": PLAN_PATH}, request_id=100 + iteration)
        state = str(run.get("state", run.get("status", "")))
        print(f"[{name}] iter {iteration}: state={state} progress={json.dumps(run.get('progress', {}))[:160]}", flush=True)
        if state == "completed":
            executed = run.get("executed", [])
            if not executed:
                raise AssertionError(f"[{name}] completed without any executed steps")
            if scenario.get("assert_enemy"):
                plan_file = SCRATCH / ".mcp" / "goal_flow_plan.json"
                plan_data = json.loads(plan_file.read_text(encoding="utf-8"))
                script_artifact = str(plan_data.get("workflow", {}).get("artifacts", {}).get("script", ""))
                controller = (SCRATCH / script_artifact.replace("res://", "")).read_text(encoding="utf-8")
                for marker in ("_on_enemy_touched", "deaths_count", "ENEMY_HOME_X"):
                    if marker not in controller:
                        raise AssertionError(f"[{name}] enemy controller lacks {marker}")
                play_tasks = [t for t in plan_data.get("tasks", []) if t.get("tool_name") == "play_and_verify"]
                derived = {str((t.get("derived_inputs", {}) or {}).get("steps", "")) for t in play_tasks}
                if not any("enemy" in d for d in derived):
                    raise AssertionError(f"[{name}] no play gate derived enemy legs: {derived}")
                note = "; enemy patrol/death/respawn verified in-run"
            elif scenario.get("assert_remap"):
                # E1：门禁必须派生 remap 演练（旧键失效 + 新键生效的事件级断言）
                plan_file = SCRATCH / ".mcp" / "goal_flow_plan.json"
                plan_data = json.loads(plan_file.read_text(encoding="utf-8"))
                play_tasks = [t for t in plan_data.get("tasks", [])
                              if t.get("tool_name") == "play_and_verify"]
                derived = {str((t.get("derived_inputs", {}) or {}).get("steps", "")) for t in play_tasks}
                if "remap-exercise" not in derived:
                    raise AssertionError(f"[{name}] no play gate derived the remap exercise: {derived}")
                note = "; rebind verified at event level (old key inert, new key works)"
            elif scenario.get("assert_save_persistence"):
                # N3：存档跨进程证据——控制器含 save/load 与自动读档，
                # 恢复门禁派生的是磁盘回归演练且已完成（目标完成本身
                # 已要求两侧门禁的行为断言在真机上通过）。
                # 脚本从计划工件取（场景间脚本累积，按文件名排序会拿错）
                plan_file = SCRATCH / ".mcp" / "goal_flow_plan.json"
                plan_data = json.loads(plan_file.read_text(encoding="utf-8"))
                script_artifact = str(plan_data.get("workflow", {}).get("artifacts", {}).get("script", ""))
                if not script_artifact:
                    raise AssertionError(f"[{name}] plan carries no script artifact")
                controller = (SCRATCH / script_artifact.replace("res://", "")).read_text(encoding="utf-8")
                for marker in ("func save_game() -> bool", "func load_game() -> bool",
                               "user://save_game.json", "load_game()"):
                    if marker not in controller:
                        raise AssertionError(f"[{name}] save controller lacks {marker}: {controller[:200]}")
                if not plan_file.exists():
                    raise AssertionError(f"[{name}] plan file missing for save-evidence check")
                by_key = {t.get("step_key", ""): t for t in plan_data.get("tasks", [])}
                for gate_key, exercise in (("save_play", "save-exercise"),
                                           ("restore_play", "save-restore-exercise")):
                    gate = by_key.get(gate_key)
                    if gate is None:
                        raise AssertionError(f"[{name}] plan is missing the {gate_key} gate")
                    derived = str((gate.get("derived_inputs", {}) or {}).get("steps", ""))
                    if derived != exercise:
                        raise AssertionError(f"[{name}] {gate_key} derived '{derived}', expected '{exercise}'")
                    if str(gate.get("status", "")) != "done":
                        raise AssertionError(f"[{name}] {gate_key} gate not done")
                note = "; save persistence verified across a full process restart"
            elif scenario.get("assert_pause_menu"):
                # M7：暂停目标必须留下真实暂停代码 + pause-exercise 行为证据。
                script_files = sorted((SCRATCH / "scripts").glob("*.gd")) if (SCRATCH / "scripts").exists() else []
                if not script_files:
                    raise AssertionError(f"[{name}] completed without any generated scripts")
                controller = script_files[0].read_text(encoding="utf-8")
                for marker in ("set_paused", "ui_cancel", "PROCESS_MODE_ALWAYS", "PauseLabel"):
                    if marker not in controller:
                        raise AssertionError(f"[{name}] pause controller lacks {marker}: {controller[:200]}")
                plan_file = SCRATCH / ".mcp" / "goal_flow_plan.json"
                if plan_file.exists():
                    plan_data = json.loads(plan_file.read_text(encoding="utf-8"))
                    play_tasks = [t for t in plan_data.get("tasks", [])
                                  if t.get("tool_name") == "play_and_verify"]
                    if play_tasks:
                        derived = str((play_tasks[0].get("derived_inputs", {}) or {}).get("steps", ""))
                        if derived != "pause-exercise":
                            raise AssertionError(
                                f"[{name}] play gate derived '{derived}', not the pause exercise")
                        if str(play_tasks[0].get("status", "")) != "done":
                            raise AssertionError(f"[{name}] pause play gate not done")
                else:
                    raise AssertionError(f"[{name}] plan file missing for pause-evidence check")
                note = "; pause behavior verified (paused/resumed asserted in-run)"
            elif scenario.get("assert_playable"):
                script_files = sorted((SCRATCH / "scripts").glob("*.gd")) if (SCRATCH / "scripts").exists() else []
                if not script_files:
                    raise AssertionError(f"[{name}] completed without any generated scripts")
                controller = script_files[0].read_text(encoding="utf-8")
                if "move_and_slide()" not in controller:
                    raise AssertionError(f"[{name}] controller lacks real movement code: {controller[:200]}")
                if "_on_coin_touched" not in controller:
                    raise AssertionError(f"[{name}] controller lacks pickup logic for the coin goal")
                scene_file = SCRATCH / "scenes" / "gameplay-feature.tscn"
                if not scene_file.exists() or "CharacterBody2D" not in scene_file.read_text(encoding="utf-8"):
                    raise AssertionError(f"[{name}] movement goal must produce a CharacterBody2D-rooted scene")
                note = "; playable controller verified"
            else:
                note = ""
            print(f"[{name}] completed after {iteration + 1} run calls; "
                  f"executed {len(executed)} steps in the last slice{note}", flush=True)
            return
        if state == "needs_input" or (state == "waiting" and run.get("needs_input")):
            needs = run.get("needs_input", run.get("needs", []))
            print(f"[{name}] needs_input detail: {_failing_receipt_summaries(name)}", flush=True)
            last_exec = run.get("executed", [])[-1] if run.get("executed") else {}
            print(f"[{name}] last executed step: {json.dumps(last_exec, ensure_ascii=False)[:2000]}", flush=True)
        if state == "waiting":
            # 纯 pending（无缺失输入）：异步步骤进行中，继续轮询。
            time.sleep(1.0)
            continue
        if state in ("blocked", "replan_required", "recovery_required", "failed", "error"):
            last = run.get("executed", [])[-1] if run.get("executed") else {}
            if scenario.get("accept_blocked_tool") == last.get("tool_name"):
                print(f"[{name}] honest boundary: {state} at {last.get('tool_name')} "
                      f"({str(run.get('blocked_reason', ''))[:160]})", flush=True)
                return
            raise AssertionError(
                f"[{name}] Goal reached terminal failure state {state} at {last.get('tool_name', '?')}: "
                f"{str(run.get('blocked_reason', ''))[:300]}")
        time.sleep(0.5)

    raise TimeoutError(f"[{name}] Goal did not complete within {RUN_ITERATIONS} run calls")


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
        tool_call("enable_tools", {"tools": ["plan_game_workflow", "run_game_workflow"], "enabled": True}, request_id=90)
        # 残留服务器防串台：确认应答的确实是 scratch 项目（project_name 一致）。
        info = tool_call("get_project_info", {}, request_id=1)
        if str(info.get("project_name", "")) != "GoalFlowScratch":
            raise AssertionError(
                f"Port {MCP_PORT} is serving a stale editor for project "
                f"'{info.get('project_name', '?')}', not the scratch project")

        for scenario in SCENARIOS:
            if scenario.get("skip"):
                print(f"[goal-flow] scenario {scenario['name']} SKIPPED: {scenario['skip']}", flush=True)
                continue
            run_scenario(scenario)
        return 0
    finally:
        process.terminate()
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=10)
        if os.environ.get("GOAL_FLOW_KEEP") != "1":
            if os.environ.get("KEEP_SCRATCH"):
                print(f"[goal-flow] scratch kept at {SCRATCH}", flush=True)
            else:
                shutil.rmtree(SCRATCH, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
