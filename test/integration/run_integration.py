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


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--filter", default="", help="regex matched against the file name")
    parser.add_argument("--slow", action="store_true", help="include the slow goal-level flows")
    parser.add_argument("--timeout", type=int, default=DEFAULT_TIMEOUT, help="per-test timeout seconds")
    parser.add_argument("--port-base", type=int, default=9200, help="first MCP port to assign")
    args = parser.parse_args()

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
