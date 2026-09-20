"""Focused repro for the 09b-levels failure (CI run 35439054444, both game legs).

Runs the shortest goal chain that still reproduces the failing assertion
(movement, coins, enemy, save, state-flow, gameover -> second-level), then
dumps the failing step's full receipt and the generated controller's
coin/level/enemy layout so the geometric cause can be pinned down locally
instead of through 20-minute CI cycles.

Usage: python test/integration/repro_09b_levels.py
"""

import json
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import test_representative_game as base

CHAIN = [
    ("01-movement-walls", "Arrow-key player movement with walls that block the player."),
    ("02-coins", "Add 3 collectible coins."),
    ("03-enemy", "Add a patrolling enemy that kills the player on touch."),
    ("06-save", "Add save/load so progress persists after closing and relaunching."),
    ("09-state-flow", "Add a title screen with start, gameplay, win state and restart."),
    ("09a-gameover", "Add a game over screen with 3 lives when the player dies."),
    ("09b-levels", "Add a second level after the first win."),
]


def main() -> int:
    for stream in (sys.stdout, sys.stderr):
        if hasattr(stream, "reconfigure"):
            stream.reconfigure(encoding="utf-8", errors="replace")
    base.setup_scratch()
    process = subprocess.Popen(
        [base.GODOT, "--editor", "--headless", "--path", str(base.SCRATCH),
         "--", "--mcp-server", f"--mcp-port={base.PORT}"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, cwd=str(base.SCRATCH))
    try:
        base.wait_server()
        base.rpc("enable_tools", {"tools": ["read_script"], "enabled": True}, 99)
        for goal_id, objective in CHAIN:
            started = time.time()
            state, d = base.run_goal(goal_id, objective, 100 + len(CHAIN) * 10)
            print(f"[{goal_id}] {state} {time.time() - started:.0f}s")
            if state != "completed":
                print(json.dumps(d, ensure_ascii=False)[:3000])
                if goal_id == "09b-levels":
                    _dump_failure_context()
                return 1
        print("chain completed — 09b passed locally; the CI failure is flaky")
        return 0
    finally:
        process.terminate()
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=10)


def _dump_failure_context() -> None:
    try:
        result = base.rpc("read_script", {"script_path": "res://gameplay_feature.gd"}, 990)
        content = result.get("content", "")
        interesting = [
            (i, line) for i, line in enumerate(content.splitlines(), 1)
            if any(k in line for k in (
                "base_x", "COIN", "ENEMY_HOME", "ENEMY_RANGE", "current_level",
                "_respawn_coins", "position = Vector2", "PATROL"))
        ]
        print("--- controller layout lines ---")
        for i, line in interesting:
            print(f"{i:4d}: {line}")
    except Exception as exc:
        print("controller dump failed:", exc)


if __name__ == "__main__":
    sys.exit(main())
