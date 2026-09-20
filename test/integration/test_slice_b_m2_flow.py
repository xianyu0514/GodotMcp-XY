"""Gate-B M2 acceptance: the audit playbook's first modification, end to end.

"The user goal: give every regular enemy knockback resistance, keep the
Boss special case, sync related resources, and never overwrite manual
work."

Flow (one real slice_b editor session over HTTP MCP):
1. read both stats resources, pinning content hashes
2. apply_change_set rewrites grunt_stats.tres knockback_resistance
   0.0 -> 0.5 with the read version bound (interrupt-safe journal)
3. boss_stats.tres stays byte-identical (special case untouched)
4. runtime probe asserts the live Grunt reads 0.5 AND that touching it
   still damages the player (combat smoke)
5. a second change set restores the shared file exactly

Usage: python test/integration/test_slice_b_m2_flow.py
"""

import hashlib
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
PORT = 9198
URL = f"http://127.0.0.1:{PORT}/mcp"
GRUNT = "res://data/grunt_stats.tres"
BOSS = "res://data/boss_stats.tres"
OLD_LINE = "knockback_resistance = 0.0"
NEW_LINE = "knockback_resistance = 0.5"
_rid = 6000


def rpc(name, args, timeout=180.0):
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
            req = urllib.request.Request(URL, data=json.dumps(
                {"jsonrpc": "2.0", "method": "tools/list", "id": 0}).encode(),
                headers={"Content-Type": "application/json"})
            urllib.request.urlopen(req, timeout=5).read()
            return
        except Exception:
            time.sleep(1)
    raise TimeoutError("slice_b MCP server never came up")


def read_hash(path):
    # 变更单的 expected_content_hash 只认内容指纹——read_script 仅收
    # .gd/.cs，.tres 的指纹由本侧直读文件计算。
    return hashlib.sha256((SLICE / path.replace("res://", "")).read_bytes()).hexdigest()


def read_stats_text(path):
    return (SLICE / path.replace("res://", "")).read_text(encoding="utf-8")


def main() -> int:
    for stream in (sys.stdout, sys.stderr):
        if hasattr(stream, "reconfigure"):
            stream.reconfigure(encoding="utf-8", errors="replace")
    subprocess.run(["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass",
                    "-File", str(SLICE / "setup.ps1")],
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
            "read_script", "apply_change_set", "install_runtime_probe",
            "run_project", "stop_project", "play_and_verify"], "enabled": True})

        # —— 1. 读版本钉住（文本值 + 内容指纹双起点）——
        if "knockback_resistance = 0.9" not in read_stats_text(BOSS):
            raise AssertionError("boss special case wrong before the run")
        # 上轮会话的变更单 journal 一并清掉——干净起点（幂等/恢复语义由
        # change-set 专项测试覆盖）。
        journal = SLICE / ".mcp/change_journal.json"
        if journal.exists():
            journal.unlink()
        grunt_file = SLICE / "data/grunt_stats.tres"
        if OLD_LINE not in grunt_file.read_text(encoding="utf-8"):
            # 上轮在中断后失败可能留下已应用的修改——归一回基线再开跑
            # （journal 语义由 change-set 专项测试覆盖，此处只求干净起点）。
            grunt_file.write_text(
                grunt_file.read_text(encoding="utf-8").replace(NEW_LINE, OLD_LINE),
                encoding="utf-8", newline="")
        grunt_hash = read_hash(GRUNT)
        boss_bytes_before = (SLICE / "data/boss_stats.tres").read_bytes()

        # —— 2. 变更单：共享敌人获得击退抗性（审计剧本第一步）——
        change = rpc("apply_change_set", {
            "intent": "gate-B playbook step 1: shared grunts gain knockback resistance",
            "change_set_id": "cs_m2_grunt_resist",
            "operations": [{
                "path": GRUNT,
                "expected_content_hash": grunt_hash,
                "edits": [{"old_text": OLD_LINE, "new_text": NEW_LINE}],
            }],
        })
        if change.get("outcome") != "committed":
            raise AssertionError(f"change set did not commit: {json.dumps(change)[:400]}")

        # —— 3. Boss 特例逐字节保留 ——
        boss_bytes_after = (SLICE / "data/boss_stats.tres").read_bytes()
        if boss_bytes_after != boss_bytes_before:
            raise AssertionError("boss_stats.tres changed — the special case must survive")

        # —— 4. 运行时生效 + 战斗冒烟 ——
        installed = rpc("install_runtime_probe",
                        {"node_name": "MCPRuntimeProbe", "persistent": False})
        if installed.get("status") not in ("success", "already_installed"):
            raise AssertionError(f"probe install failed: {installed}")
        if rpc("run_project", {"allow_window": True}).get("status") != "success":
            raise AssertionError("run_project failed")
        verdict = rpc("play_and_verify", {
            "steps": [
                # 先证共享值在活游戏里生效（数据 → 运行时同源）。
                {"assert": {"expression": "get_node(\"Grunt1\").stats.knockback_resistance",
                    "operator": "eq", "expected": 0.5,
                    "description": "the live grunt reads the modified shared value"}},

                # 战斗冒烟：右移穿过敌人巡逻带必有一次接触 → hp 从 100 下降。
                {"action": "move_right", "pressed": True, "wait_ms": 2600},
                {"action": "move_right", "pressed": False, "wait_ms": 900},
                {"assert": {"expression": "get_node(\"Player\").hp", "operator": "lt", "expected": 100,
                    "description": "touching the enemy damaged the player"}},
            ],
        }, timeout=240.0)
        if not verdict.get("passed", False):
            raise AssertionError(f"runtime verdict failed: {json.dumps(verdict)[:500]}")

        # —— 5. 恢复共享文件（同样走变更单，留下干净的工作树）——
        restore = rpc("apply_change_set", {
            "intent": "restore grunt knockback resistance after the playbook step",
            "change_set_id": "cs_m2_grant_restore",
            "operations": [{
                "path": GRUNT,
                "expected_content_hash": read_hash(GRUNT),
                "edits": [{"old_text": NEW_LINE, "new_text": OLD_LINE}],
            }],
        })
        if restore.get("outcome") != "committed":
            raise AssertionError(f"restore did not commit: {json.dumps(restore)[:400]}")
        digest_after = hashlib.sha256((SLICE / "data/grunt_stats.tres").read_bytes()).hexdigest()

        print(f"M2 playbook step verified: shared grunt modified via change set "
              f"(runtime 0.5 live, player damaged), boss bytes untouched, "
              f"shared file restored (sha {digest_after[:12]}…)")
        return 0
    finally:
        try:
            rpc("stop_project", {"allow_window": True})
        except Exception:
            pass
        process.kill()
        process.wait(timeout=15)
        # 兜底归一：任何一步失败都不把 0.5 泄漏给下一轮。
        grunt_file = SLICE / "data/grunt_stats.tres"
        if grunt_file.exists() and NEW_LINE in grunt_file.read_text(encoding="utf-8"):
            grunt_file.write_text(
                grunt_file.read_text(encoding="utf-8").replace(NEW_LINE, OLD_LINE),
                encoding="utf-8", newline="")


if __name__ == "__main__":
    sys.exit(main())
