"""M1 smoke: MCP drives the slice's map transitions.

Starts the slice editor with the MCP addon, installs the runtime probe,
runs the game, simulates movement into the L1 door, and asserts the
scene transitioned to L2 — evidence for docs/slice-b-plan.md milestone 1.

Usage: python test/integration/test_slice_b_m1_flow.py
"""

import json
import os
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SLICE = REPO / "slice_b"
GODOT = os.environ.get("GODOT_EXE", r"D:\youxi\kaifa\Godot_v4.7.2-stable_win64_console.exe")
PORT = 9197
URL = f"http://127.0.0.1:{PORT}/mcp"
_rid = 4000


def rpc(name, args, timeout=120.0):
    global _rid
    _rid += 1
    req = urllib.request.Request(URL, data=json.dumps(
        {"jsonrpc": "2.0", "method": "tools/call",
         "params": {"name": name, "arguments": args}, "id": _rid}).encode(),
        headers={"Content-Type": "application/json"})
    r = json.loads(urllib.request.urlopen(req, timeout=timeout).read())
    res = r.get("result", {})
    if res.get("isError"):
        raise AssertionError(f"{name}: {res['content'][0]['text'][:200]}")
    return res.get("structuredContent", {})


def wait_server(seconds=150.0):
    deadline = time.time() + seconds
    while time.time() < deadline:
        try:
            # 探活走 JSON-RPC 的 tools/list 方法本身——不是名为 tools/list
            # 的工具调用（不存在的工具会让探活永远失败）。
            req = urllib.request.Request(URL, data=json.dumps(
                {"jsonrpc": "2.0", "method": "tools/list", "id": 0}).encode(),
                headers={"Content-Type": "application/json"})
            urllib.request.urlopen(req, timeout=5).read()
            return
        except Exception:
            time.sleep(1)
    raise TimeoutError("slice_b MCP server never came up")


def main() -> int:
    for stream in (sys.stdout, sys.stderr):
        if hasattr(stream, "reconfigure"):
            stream.reconfigure(encoding="utf-8", errors="replace")
    # 插件同步（干净 checkout 无 slice_b/addons——没有它插件不加载、
    # 服务器永不上，CI 实证 150s 超时）+ 存档残留清零。
    import shutil
    subprocess.run(["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass",
                    "-File", str(Path(__file__).resolve().parents[2] / "slice_b" / "setup.ps1")],
                   capture_output=True, timeout=120)
    appdata = os.path.join(os.environ.get("APPDATA", ""), "Godot", "app_userdata")
    shutil.rmtree(os.path.join(appdata, "SliceB"), ignore_errors=True)

    process = subprocess.Popen(
        [GODOT, "--editor", "--headless", "--path", str(SLICE),
         "--", "--mcp-server", f"--mcp-port={PORT}"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, cwd=str(SLICE))
    try:
        wait_server()
        rpc("enable_tools", {"tools": [
            "install_runtime_probe", "run_project", "stop_project",
            "play_and_verify", "get_runtime_info"], "enabled": True})
        installed = rpc("install_runtime_probe",
                        {"node_name": "MCPRuntimeProbe", "persistent": False})
        if installed.get("status") not in ("success", "already_installed"):
            raise AssertionError(f"probe install failed: {installed}")
        run = rpc("run_project", {"allow_window": True})
        if run.get("status") != "success":
            raise AssertionError(f"run_project failed: {run}")

        # 右移进入 L1→L2 门（120→880px @260px/s ≈ 2.9s；进 L2 后从 x=120
        # 起步——时长必须只覆盖第一段行程，否则会横穿 L2 撞进 Boss 门）。
        verdict = rpc("play_and_verify", {
            "steps": [
                {"action": "move_right", "pressed": True, "wait_ms": 3300},
                {"action": "move_right", "pressed": False, "wait_ms": 800},
                {"assert": {"expression": "get_tree().current_scene.map_id",
                    "expected": "res://scenes/maps/map_l2.tscn",
                    "description": "the door moved the player to map L2"}},
            ],
        }, timeout=180.0)
        if not verdict.get("passed", False):
            raise AssertionError(f"transition verdict failed: {json.dumps(verdict)[:500]}")
        print("M1 smoke verified: L1 -> L2 transition driven via MCP runtime probe")
        return 0
    finally:
        try:
            rpc("stop_project", {"allow_window": True})
        except Exception:
            pass
        process.kill()
        process.wait(timeout=15)


if __name__ == "__main__":
    sys.exit(main())
