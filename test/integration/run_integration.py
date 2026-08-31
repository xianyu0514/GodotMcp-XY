"""Sequential integration-test runner.

Runs every test_<name>_flow.py (plus the goal-level tests) one at a time,
each on its own MCP_PORT so a live editor on 9080 never collides.

Usage:
    GODOT_EXE=path/to/godot python run_integration.py                 # fast set
    GODOT_EXE=... python run_integration.py --slow                    # everything
    GODOT_EXE=... python run_integration.py --filter goal             # regex on file name
    GODOT_EXE=... python run_integration.py --timeout 900             # per-test seconds
"""

import argparse
import os
import platform
import re
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent

# Heavier end-to-end flows: valid but slow — opt in with --slow.
SLOW_TESTS = {
    "test_game_goal_flow.py",
    "test_game_goal_resume_flow.py",
    "test_game_goal_crash_midstep_flow.py",
    "test_game_goal_crash_nonidempotent_flow.py",
}

DEFAULT_TIMEOUT = 600
def kill_repo_godots() -> None:
    """Kill any Godot process still referencing this repository (process tree).

    Godot games spawn as children of the editor with --remote-debug/--editor-pid.
    stop_project uses the engine API, which does not guarantee the OS process
    dies; a hard editor terminate orphans the game, and on a CI runner leaked
    games accumulate until later editors cannot boot inside the test wait
    window (observed: everything after test #26 timing out).
    """
    if platform.system() != "Windows":
        return
    # CI（临时 runner）上只有本套件的 Godot 进程：按映像名整体击杀最可靠，
    # 不依赖可能慢/失败的 CIM 查询。本地保持精确匹配仓库路径的清扫，
    # 绝不碰用户自己打开的编辑器。
    if os.environ.get("MCP_RUNNER_KILL_ALL_GODOT"):
        result = subprocess.run(
            ["taskkill", "/IM", "Godot_v4.6.3-stable_win64.exe", "/T", "/F"],
            capture_output=True, text=True, timeout=30,
        )
        terminated = result.stdout.count("SUCCESS")
        if terminated:
            print(f"    [sweep] kill-all terminated {terminated} process tree(s)", flush=True)
        return
    query = (
        "Get-CimInstance Win32_Process -Filter \"Name like 'Godot%'\" | "
        "Where-Object { $_.CommandLine -like '*Godot-MCP-Native*' } | "
        "Select-Object -ExpandProperty ProcessId"
    )
    try:
        listing = subprocess.run(
            ["powershell", "-NoProfile", "-Command", query],
            capture_output=True, text=True, timeout=60,
        )
    except (OSError, subprocess.TimeoutExpired):
        print("    [sweep] WARNING: process listing failed; leaked processes may slow later tests", flush=True)
        return
    terminated = 0
    for pid_text in listing.stdout.split():
        kill = subprocess.run(
            ["taskkill", "/PID", pid_text, "/T", "/F"],
            capture_output=True, text=True, timeout=30,
        )
        if "SUCCESS" in kill.stdout:
            terminated += 1
    if terminated:
        print(f"    [sweep] terminated {terminated} leaked process tree(s)", flush=True)





def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--filter", default="", help="regex matched against the file name")
    parser.add_argument("--slow", action="store_true", help="include the slow goal-level flows")
    parser.add_argument("--timeout", type=int, default=DEFAULT_TIMEOUT, help="per-test timeout seconds")
    parser.add_argument("--port-base", type=int, default=0,
                        help="first MCP port to assign (default: 9200 + jitter so consecutive runs never reuse recent ports)")
    args = parser.parse_args()

    if args.port_base <= 0:
        # 连续两次运行若复用同一批端口，上一轮被硬杀的监听套接字可能仍在
        # TIME_WAIT，新编辑器绑定失败后进入 30s 复活退避，恰好击穿测试的
        # 30s 等待窗。基址抖动让每轮使用不同端口段。
        args.port_base = 9200 + ((int(time.time()) // 60 * 7) % 500)
    godot = os.environ.get("GODOT_EXE", "").strip()
    if not godot:
        print("ERROR: set GODOT_EXE to a Godot console/editor executable", file=sys.stderr)
        return 2
    if not Path(godot).exists():
        print(f"ERROR: GODOT_EXE does not exist: {godot}", file=sys.stderr)
        return 2

    tests = sorted(p.name for p in HERE.glob("test_*.py"))
    pattern = re.compile(args.filter) if args.filter else None
    selected = []
    for name in tests:
        if pattern and not pattern.search(name):
            continue
        if name in SLOW_TESTS and not args.slow:
            continue
        selected.append(name)
    if not selected:
        print("No tests matched.", file=sys.stderr)
        return 2

    print(f"running {len(selected)} integration tests with {godot}")
    results: list[tuple[str, str, float]] = []
    env = dict(os.environ)
    env["GODOT_EXE"] = str(Path(godot).resolve())
    for index, name in enumerate(selected):
        env["MCP_PORT"] = str(args.port_base + index)
        started = time.time()
        print(f"[{index + 1}/{len(selected)}] {name} (port {env['MCP_PORT']}) ...", flush=True)
        try:
            proc = subprocess.run(
                [sys.executable, str(HERE / name)],
                cwd=HERE, env=env, timeout=args.timeout,
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
            )
            verdict = "PASS" if proc.returncode == 0 else "FAIL"
            output = proc.stdout
        except subprocess.TimeoutExpired as exc:
            verdict = "TIMEOUT"
            output = (exc.stdout or "") if isinstance(exc.stdout, str) else ""
        elapsed = time.time() - started
        results.append((name, verdict, elapsed))
        print(f"    -> {verdict} in {elapsed:.1f}s", flush=True)
        kill_repo_godots()
        if verdict != "PASS":
            tail = "\n".join(output.strip().splitlines()[-12:])
            print("    " + tail.replace("\n", "\n    "), flush=True)
            # GitHub Actions converts ::error:: lines into check annotations,
            # so failures are identifiable without log-download access.
            first_error = next((l for l in output.splitlines()
                                if "AssertionError" in l or "TimeoutError" in l or "Error" in l), "")
            if first_error:
                print(f"::error::{name} {verdict}: {first_error[:350]}", flush=True)

    failures = [(n, v) for n, v, _ in results if v != "PASS"]
    print("\n==== summary ====")
    for name, verdict, elapsed in results:
        print(f"{verdict:7s} {elapsed:7.1f}s {name}")
    print(f"\n{len(results) - len(failures)}/{len(results)} passed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
