"""Player-flow P0-2 acceptance: quit mid-game, relaunch, the WORLD resumes.

Scenario (the audit's exact bar): second map, off-spawn position, half
HP, one heart collected, quest accepted — save, HARD-KILL the game,
relaunch → map/position/HP/inventory/quest/item all restore; the
collected heart does not reappear. Run the relaunch TWICE — the same
item can never be granted twice.

Usage: python test/integration/test_slice_b_resume_flow.py
"""

import json
import os
import shutil
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SLICE = REPO / "slice_b"
GODOT = os.environ.get("GODOT_EXE", r"D:\youxi\kaifa\Godot_v4.7.2-stable_win64_console.exe")
PORT = 9206
URL = f"http://127.0.0.1:{PORT}/mcp"
USER_DATA = Path(os.environ.get("APPDATA", "")) / "Godot" / "app_userdata" / "SliceB"
SAVE = USER_DATA / "slice_b_save.json"
MAP_L2 = "res://scenes/maps/map_l2.tscn"
_rid = 9900


def rpc(name, args, timeout=240.0):
    global _rid
    _rid += 1
    req = urllib.request.Request(URL, data=json.dumps(
        {"jsonrpc": "2.0", "method": "tools/call",
         "params": {"name": name, "arguments": args}, "id": _rid}).encode(),
        headers={"Content-Type": "application/json"})
    r = json.loads(urllib.request.urlopen(req, timeout=timeout).read())
    res = r.get("result", {})
    if res.get("isError"):
        raise AssertionError(f"{name}: {res['content'][0]['text'][:300]}")
    return res.get("structuredContent", {})


def wait_server(seconds=150.0):
    deadline = time.time() + seconds
    while time.time() < deadline:
        try:
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
    subprocess.run(["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass",
                    "-File", str(SLICE / "setup.ps1")], capture_output=True, timeout=180)
    shutil.rmtree(USER_DATA, ignore_errors=True)

    process = subprocess.Popen(
        [GODOT, "--editor", "--headless", "--path", str(SLICE),
         "--", "--mcp-server", f"--mcp-port={PORT}"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, cwd=str(SLICE))
    try:
        wait_server()
        rpc("enable_tools", {"tools": [
            "install_runtime_probe", "run_project", "stop_project",
            "play_and_verify"], "enabled": True})
        installed = rpc("install_runtime_probe",
                        {"node_name": "MCPRuntimeProbe", "persistent": False})
        if installed.get("status") not in ("success", "already_installed"):
            raise AssertionError(f"probe install failed: {installed}")
        # 探针安装会写 project.godot 的 autoload——首启需要游戏进程带着探针
        # 起来（冷启重试），否则 play_and_verify 找不到会话。
        for retry in range(3):
            try:
                rpc("run_project", {"allow_window": True})
                break
            except AssertionError:
                if retry == 2:
                    raise
                time.sleep(8)
        time.sleep(2)

        # —— 场景布置（活游戏内，全部走表达式）——
        # 走到 L2（真实移动过门——也验证门流程与恢复互不干扰）。
        first = rpc("play_and_verify", {"steps": [
            {"action": "move_right", "pressed": True, "wait_ms": 3300},
            {"action": "move_right", "pressed": False, "wait_ms": 800},
            {"assert": {"expression":
                'get_tree().current_scene.map_id == "' + MAP_L2 + '"',
                "expected": True, "description": "walked through the door to L2"}},
        ]}, timeout=240.0)
        if not first.get("passed"):
            raise AssertionError(f"door walk failed: {json.dumps(first)}")

        # 半血 + 拾取一枚 heart（L1 的 Heart1——回 L1 拾取）+ 接任务 + 存档。
        setup = rpc("play_and_verify", {"steps": [
            {"assert": {"expression":
                "get_node(\"/root/GameSave\").inventory.add(\"heart\", 1) == null",
                "expected": True, "description": "one heart in the inventory"}},
            {"assert": {"expression":
                "get_node(\"/root/GameSave\").record_item_collected(\"res://scenes/maps/map_l1.tscn#Heart1\") == null",
                "expected": True, "description": "Heart1 recorded as collected"}},
            {"assert": {"expression":
                "get_node(\"/root/GameSave\").quest_log.accept(\"quest_hearts\")",
                "expected": True, "description": "quest accepted (in progress)"}},
            {"assert": {"expression":
                "get_node(\"Player\").take_hit(50, Vector2(0, 0)) == null",
                "expected": True, "description": "apply 50 damage"}},
            {"assert": {"expression":
                "get_node(\"Player\").hp == 50",
                "expected": True, "description": "half HP"}},
            {"assert": {"expression":
                "(get_node(\"Player\").set_global_position(Vector2(400, 300))) == null",
                "expected": True, "description": "park at an off-spawn position"}},
            {"assert": {"expression":
                "get_node(\"/root/GameSave\").record_player_position(get_node(\"Player\").global_position) == null",
                "expected": True, "description": "position recorded"}},
            {"assert": {"expression":
                "get_node(\"/root/GameSave\").record_combat_state(get_node(\"Player\").hp, get_node(\"/root/GameSave\").coins) == null",
                "expected": True, "description": "combat state recorded"}},
            {"assert": {"expression":
                "get_node(\"/root/GameSave\").save()",
                "expected": True, "description": "save written (bool true on success)"}},
        ]}, timeout=240.0)
        if not setup.get("passed"):
            raise AssertionError(f"state setup failed: {json.dumps(setup)}")

        # —— 硬杀 + 重启 ×2：每次都应精确恢复 ——
        for attempt in (1, 2):
            try:
                rpc("stop_project", {"allow_window": True})
            except Exception:
                pass
            # 旧游戏进程若残留（stop 不彻底），会继续跑并覆写存档——
            # 按映像强杀 slice_b 路径的游戏进程后再生（CI/本机均实证）。
            # 游戏进程命令行带 --remote-debug（编辑器 run 出来的），编辑器
            # 自己带 --editor——按此区分，绝不误杀编辑器（曾误杀：本机实证）。
            subprocess.run(["powershell", "-NoProfile", "-Command",
                "Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -like '*slice_b*' -and $_.CommandLine -like '*--remote-debug*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }"],
                capture_output=True, timeout=30)
            time.sleep(2)
            for retry in range(3):
                try:
                    rpc("run_project", {"allow_window": True})
                    break
                except AssertionError:
                    if retry == 2:
                        raise
                    time.sleep(8)
            time.sleep(3)
            verdict = rpc("play_and_verify", {"steps": [
                {"wait_ms": 800},
                {"assert": {"expression":
                    'get_tree().current_scene.map_id == "' + MAP_L2 + '"',
                    "expected": True,
                    "description": f"[relaunch {attempt}] back on L2, not L1"}},
                {"assert": {"expression": "get_node(\"Player\").hp == 50",
                    "expected": True,
                    "description": f"[relaunch {attempt}] HP restored to 50"}},
                {"assert": {"expression":
                    "abs(get_node(\"Player\").global_position.x - 400.0) < 1.0 and abs(get_node(\"Player\").global_position.y - 300.0) < 1.0",
                    "expected": True,
                    "description": f"[relaunch {attempt}] off-spawn position restored"}},
                {"assert": {"expression":
                    "get_node(\"/root/GameSave\").inventory.count(\"heart\") == 1",
                    "expected": True,
                    "description": f"[relaunch {attempt}] inventory intact (not doubled)"}},
                {"assert": {"expression":
                    "get_node(\"/root/GameSave\").quest_log.is_active(\"quest_hearts\")",
                    "expected": True,
                    "description": f"[relaunch {attempt}] quest still in progress"}},
                {"assert": {"expression":
                    "get_node(\"/root/GameSave\").is_item_collected(\"res://scenes/maps/map_l1.tscn#Heart1\")",
                    "expected": True,
                    "description": f"[relaunch {attempt}] item stays collected"}},
            ]}, timeout=240.0)
            if not verdict.get("passed"):
                raise AssertionError(
                    f"relaunch {attempt} failed: {json.dumps(verdict)[:600]}")
            print(f"  relaunch {attempt}: map/HP/position/inventory/quest/item all restored")

        print("Player-flow P0-2 verified: mid-game world (L2, off-spawn, half HP, "
              "item collected, quest active) survives a hard kill and restores "
              "exactly, twice in a row — no duplicate grants.")
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
