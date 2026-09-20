"""Replay only the showcase oracle's full_loop steps against the built game
to see the failing assertion without a 13-minute rebuild."""

import json
import math
import os
import subprocess
import sys
import time
import urllib.request

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# 上一层才是仓库根（本文件在 test/integration/）
SCRATCH = os.path.join(os.path.dirname(REPO), "tmp_showcase_game")
GODOT = r"D:\youxi\kaifa\Godot_v4.7.2-stable_win64_console.exe"
PORT = 9203
URL = f"http://127.0.0.1:{PORT}/mcp"
_rid = 0


def rpc(name, args, rid=None, timeout=300.0):
    global _rid
    _rid += 1
    req = urllib.request.Request(URL, data=json.dumps(
        {"jsonrpc": "2.0", "method": "tools/call",
         "params": {"name": name, "arguments": args}, "id": rid or _rid}).encode(),
        headers={"Content-Type": "application/json"})
    r = json.loads(urllib.request.urlopen(req, timeout=timeout).read())
    res = r.get("result", {})
    if res.get("isError"):
        raise AssertionError(f"{name}: {res['content'][0]['text'][:300]}")
    return res.get("structuredContent", {})


def main() -> int:
    model = json.loads(open(SCRATCH + os.sep + ".mcp" + os.sep + "game_model.json", encoding="utf-8").read())
    speed = float(model.get("params", {}).get("SPEED", 260.0))
    coins_n = 5
    spacing = min(40.0, 78.0 / float(coins_n - 1))
    window_px = 110.0 + (coins_n - 1) * spacing - 90.0 + 12.0
    sweep_frames = max(10, min(29, math.ceil(window_px / (speed / 60.0))))
    print(f"speed={speed} sweep_frames={sweep_frames} stop_px≈{sweep_frames * speed / 60.0:.0f}")

    process = subprocess.Popen(
        [GODOT, "--editor", "--headless", "--path", SCRATCH,
         "--", "--mcp-server", f"--mcp-port={PORT}"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, cwd=SCRATCH)
    try:
        deadline = time.time() + 150
        while time.time() < deadline:
            try:
                req = urllib.request.Request(URL, data=json.dumps(
                    {"jsonrpc": "2.0", "method": "tools/list", "id": 0}).encode(),
                    headers={"Content-Type": "application/json"})
                urllib.request.urlopen(req, timeout=5).read()
                break
            except Exception:
                time.sleep(1)
        rpc("enable_tools", {"tools": ["play_and_verify", "run_project",
                                       "install_runtime_probe", "stop_project"], "enabled": True}, 900)
        for attempt in range(3):
            try:
                rpc("run_project", {"allow_window": True}, 901)
                break
            except AssertionError:
                if attempt == 2:
                    raise
                time.sleep(8)
        time.sleep(3)
        steps = []
        for _ in range(3):
            steps.append({"action": "ui_accept", "pressed": True, "wait_ms": 300})
            steps.append({"action": "ui_accept", "pressed": False, "wait_ms": 100})
        for level in (1, 2, 3):
            steps.append({"action": "move_right", "pressed": True, "wait_frames": sweep_frames})
            steps.append({
                "action": "move_right", "pressed": False, "wait_ms": 300,
                "assert": {"expression":
                           "str(current_level) + '|' + str(coins_collected == COINS_TO_WIN) + '|' + game_state",
                           "expected": f"{level}|true|win",
                           "description": f"level {level} cleared"}})
            if level < 3:
                steps.append({"action": "ui_accept", "pressed": True, "wait_ms": 300})
                steps.append({
                    "action": "ui_accept", "pressed": False, "wait_ms": 200,
                    "assert": {"expression":
                               "str(current_level) + '|' + str(coins_collected) + '|' + game_state",
                               "expected": f"{level + 1}|0|playing",
                               "description": f"advanced to level {level + 1}"}})
        steps.append({"assert": {"expression": "_win_label.text", "expected": "You Win!"}})
        r = rpc("play_and_verify", {"steps": steps, "deterministic": True}, 905)
        print("passed:", r.get("passed"))
        for a in r.get("assertions", []):
            if not a.get("passed", True):
                print("FAILED:", json.dumps(a)[:500])
        return 0 if r.get("passed") else 1
    finally:
        try:
            rpc("stop_project", {"allow_window": True})
        except Exception:
            pass
        process.kill()
        process.wait(timeout=15)


if __name__ == "__main__":
    sys.exit(main())
