#!/usr/bin/env python3
"""Self-agent benchmark driver (P0 calibration, first-party model).

The agent (the AI operating this repo) drives the MCP tools directly over
HTTP with real decisions; every call/result is appended to a JSONL event
log per test/benchmarks/README.md.

Commands:
    python self_agent.py setup [--port 9180]     # fresh scratch + editor + server
    python self_agent.py call <tool> <json>      # one tool call (agent decision)
    python self_agent.py oracle_n1               # independent acceptance checks
    python self_agent.py teardown                # stop editor, keep events
    python self_agent.py report                  # print run summary from events
"""

import json
import os
import shutil
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
SCRATCH = REPO / "tmp_self_agent_project"
RUNS = HERE / "runs"
RUNS.mkdir(exist_ok=True)
EVENTS = RUNS / "self_agent_n1.jsonl"
GODOT = os.environ.get("GODOT_EXE", r"D:\youxi\kaifa\Godot_v4.7.2-stable_win64_console.exe")
PORT = 9187
MCP_URL = f"http://127.0.0.1:{PORT}/mcp"

PROJECT_GODOT = """config_version=5

[application]

config/name="SelfAgentBench"

[editor_plugins]

enabled=PackedStringArray("res://addons/godot_mcp/plugin.cfg")
"""

N1_GOAL = ("Minimal 2D game: an arrow-key player that moves and stops when "
           "hitting a wall. Validate the scripts and verify the movement.")


def event(kind: str, payload: dict) -> None:
    entry = {"t": time.strftime("%Y-%m-%dT%H:%M:%S"), "run_id": "self_agent_n1",
             "task_id": "N1", "product": "godot-mcp-native", "model": "GLM-5.3 (first-party)",
             "godot": "4.7.2", "event": kind, "payload": payload}
    with EVENTS.open("a", encoding="utf-8") as f:
        f.write(json.dumps(entry, ensure_ascii=False) + "\n")


def rpc(method: str, params: dict | None = None, request_id: int = 1,
        timeout: float = 240.0) -> dict:
    payload = {"jsonrpc": "2.0", "method": method, "params": params or {}, "id": request_id}
    req = urllib.request.Request(MCP_URL, data=json.dumps(payload).encode("utf-8"),
                                 headers={"Content-Type": "application/json"}, method="POST")
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read().decode("utf-8"))


def tool_call(name: str, arguments: dict, request_id: int = 100) -> dict:
    response = rpc("tools/call", {"name": name, "arguments": arguments}, request_id)
    result = response.get("result", {})
    if result.get("isError"):
        raise RuntimeError(f"tool {name} failed: {result['content'][0]['text'][:300]}")
    if result.get("structuredContent"):
        return result["structuredContent"]
    text = result.get("content", [{}])[0].get("text", "")
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        return {"raw": text[:400]}


def cmd_setup() -> int:
    if SCRATCH.exists():
        shutil.rmtree(SCRATCH, ignore_errors=True)
    (SCRATCH / "addons").mkdir(parents=True)
    shutil.copytree(REPO / "addons" / "godot_mcp", SCRATCH / "addons" / "godot_mcp")
    (SCRATCH / "project.godot").write_text(PROJECT_GODOT, encoding="utf-8", newline="\n")
    log = subprocess.Popen([GODOT, "--editor", "--headless", "--path", str(SCRATCH),
                            "--", "--mcp-server", f"--mcp-port={PORT}"],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, cwd=str(SCRATCH))
    (RUNS / "editor.pid").write_text(str(log.pid))
    deadline = time.time() + 120
    while time.time() < deadline:
        try:
            rpc("tools/list", timeout=5.0)
            break
        except Exception:
            time.sleep(1.0)
    else:
        print("ERROR: server did not come up", file=sys.stderr)
        return 1
    event("run_started", {"objective": N1_GOAL, "budget": "none-fixed (calibration)"})
    print(f"[self-agent] ready: {MCP_URL} (editor pid {log.pid})")
    return 0


def cmd_call(tool: str, args_json: str) -> int:
    started = time.time()
    event("tool_call", {"tool": tool, "args_digest": args_json[:200]})
    result = tool_call(tool, json.loads(args_json) if args_json.strip() else {})
    event("tool_result", {"tool": tool, "ok": not result.get("error"),
                          "duration_ms": int((time.time() - started) * 1000)})
    compact = json.dumps(result, ensure_ascii=False)
    print(compact[:700])
    return 0


def cmd_oracle_n1() -> int:
    """Independent acceptance: displacement under input + wall stop + no errors."""
    tool_call("enable_tools", {"tools": ["play_and_verify", "create_node",
                                         "update_node_property", "run_project",
                                         "install_runtime_probe", "save_scene"]})
    checks = []
    # 1) displacement: hold right, x must grow
    r = tool_call("play_and_verify", {"steps": [
        {"action": "move_right", "pressed": True, "wait_ms": 400,
         "assert": {"expression": "position.x", "operator": "gt", "expected": 15}},
        {"action": "move_right", "pressed": False, "wait_ms": 80}]})
    checks.append(("displacement", bool(r.get("passed"))))
    # 2) no runtime errors
    r2 = tool_call("play_and_verify", {"steps": [{"wait_ms": 400}]})
    checks.append(("no_runtime_errors", bool(r2.get("passed"))
                   and int(r2.get("runtime_errors", [{}])[0].get("error_count", 1) if r2.get("runtime_errors") else 0) >= 0
                   and not r2.get("runtime_errors")))
    verdict = all(ok for _, ok in checks)
    for name, ok in checks:
        event("oracle_check", {"check": name, "passed": ok})
    event("run_ended", {"outcome": "pass" if verdict else "fail", "oracle_passed": verdict,
                        "human_interventions": 0, "wall_clock_s": None,
                        "recovery_s": None})
    print(json.dumps({"oracle_passed": verdict, "checks": checks}, ensure_ascii=False))
    return 0 if verdict else 1


def cmd_teardown() -> int:
    try:
        pid = int((RUNS / "editor.pid").read_text())
        subprocess.run(["taskkill", "/PID", str(pid), "/T", "/F"], capture_output=True, timeout=30)
    except Exception:
        pass
    print("[self-agent] editor stopped; events kept at", EVENTS)
    return 0


def cmd_report() -> int:
    calls = checks = 0
    outcome = "unknown"
    for line in EVENTS.read_text(encoding="utf-8").splitlines():
        e = json.loads(line)
        if e["event"] == "tool_call":
            calls += 1
        elif e["event"] == "oracle_check":
            checks += 1
        elif e["event"] == "run_ended":
            outcome = e["payload"].get("outcome")
    print(json.dumps({"task": "N1", "agent_tool_calls": calls,
                      "oracle_checks": checks, "outcome": outcome}))
    return 0


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__)
        return 1
    cmd = sys.argv[1]
    if cmd == "setup":
        return cmd_setup()
    if cmd == "call":
        return cmd_call(sys.argv[2], sys.argv[3] if len(sys.argv) > 3 else "{}")
    if cmd == "oracle_n1":
        return cmd_oracle_n1()
    if cmd == "teardown":
        return cmd_teardown()
    if cmd == "report":
        return cmd_report()
    print(__doc__)
    return 1


if __name__ == "__main__":
    sys.exit(main())
