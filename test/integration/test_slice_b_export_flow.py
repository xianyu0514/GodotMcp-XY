"""Gate-D acceptance: the packaged game runs, saves, resumes and migrates
OUTSIDE the editor.

This is the PCK form: Godot's official distribution shape
(`godot --main-pack game.pck`), self-contained (scenes/scripts/
resources/project.godot), running without the slice_b source tree.
It stays the template-independent leg; the classic exe export is
covered by test_slice_b_exe_export_flow.py when 4.7.2 export
templates are installed.

Flow:
1. Editor session packs res:// into build/slice_b.pck (pack_pck)
2. PCK boots headless (exit 0), the autoload writes a v2 save
3. A hand-written v1 save is migrated to v2 by the packaged game on
   the next boot (schema upgrade proven outside the editor)
4. A second boot keeps the save intact (persistence across runs)

Usage: python test/integration/test_slice_b_export_flow.py
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
PORT = 9200
URL = f"http://127.0.0.1:{PORT}/mcp"
PCK = SLICE / "build/slice_b.pck"
USER_DATA = Path(os.environ.get("APPDATA", "")) / "Godot" / "app_userdata" / "SliceB"
SAVE = USER_DATA / "slice_b_save.json"
_rid = 9000


def rpc(name, args, timeout=300.0):
    global _rid
    _rid += 1
    req = urllib.request.Request(URL, data=json.dumps(
        {"jsonrpc": "2.0", "method": "tools/call",
         "params": {"name": name, "arguments": args}, "id": _rid}).encode(),
        headers={"Content-Type": "application/json"})
    r = json.loads(urllib.request.urlopen(req, timeout=timeout).read())
    res = r.get("result", {})
    if res.get("isError"):
        raise AssertionError(f"{name}: {res['content'][0]['text'][:240]}")
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


def run_packaged(extra_args, expect_exit=0):
    """Boot the packaged game with the engine runtime, away from the editor."""
    args = [GODOT, "--headless", "--main-pack", str(PCK)] + extra_args
    result = subprocess.run(args, capture_output=True, text=True,
                            cwd=str(PCK.parent), timeout=120)
    if result.returncode != expect_exit:
        raise AssertionError(
            f"packaged run exit {result.returncode} (want {expect_exit}): "
            f"{(result.stderr or result.stdout)[-400:]}")
    return result


def read_save():
    if not SAVE.exists():
        return None
    return json.loads(SAVE.read_text(encoding="utf-8"))


def write_save(data):
    USER_DATA.mkdir(parents=True, exist_ok=True)
    SAVE.write_text(json.dumps(data, indent=2), encoding="utf-8")


def main() -> int:
    for stream in (sys.stdout, sys.stderr):
        if hasattr(stream, "reconfigure"):
            stream.reconfigure(encoding="utf-8", errors="replace")
    subprocess.run(["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass",
                    "-File", str(SLICE / "setup.ps1")], capture_output=True, timeout=120)
    shutil.rmtree(USER_DATA, ignore_errors=True)
    if PCK.exists():
        PCK.unlink()
    PCK.parent.mkdir(parents=True, exist_ok=True)

    process = subprocess.Popen(
        [GODOT, "--editor", "--headless", "--path", str(SLICE),
         "--", "--mcp-server", f"--mcp-port={PORT}"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, cwd=str(SLICE))
    try:
        wait_server()
        rpc("enable_tools", {"tools": ["pack_pck"], "enabled": True})

        # —— 1. 打包：全项目（含 project.godot）自包含 ——
        sources = []
        for base in ("scenes", "scripts", "data"):
            for f in sorted((SLICE / base).rglob("*")):
                if f.is_file() and f.suffix in (".gd", ".tscn", ".tres"):
                    sources.append(f"res://{f.relative_to(SLICE).as_posix()}")
        sources.append("res://project.godot")
        # class_name 的运行时注册表（.godot 生成物）必须进包——否则打包
        # 运行时所有全局类解析失败（game_save/enemy/player 全线崩）。
        class_cache = SLICE / ".godot/global_script_class_cache.cfg"
        if class_cache.exists():
            sources.append({"target_path": "res://.godot/global_script_class_cache.cfg",
                            "source_path": class_cache.as_posix()})
        pack = rpc("pack_pck", {"pck_path": "res://build/slice_b.pck", "files": sources})
        if "error" in pack:
            raise AssertionError(f"pack failed: {pack['error']}")
        if not PCK.exists():
            raise AssertionError("pack reported success but the pck is missing")

        # —— 2. 打包游戏无头启动 + 首次存档 ——
        run_packaged(["--quit-after", "300"])
        first = read_save()
        if first is None:
            raise AssertionError("the packaged game did not write a save on boot")
        if int(first.get("schema_version", -1)) < 2:
            raise AssertionError(f"fresh save should be v2: {first}")

        # —— 3. v1 存档在打包游戏里被迁移为 v2 ——
        write_save({
            "schema_version": 1,
            "visited_maps": ["res://scenes/maps/map_l1.tscn"],
            "last_map": "res://scenes/maps/map_l1.tscn",
            "player_position": {"x": 11.0, "y": 22.0},
        })
        run_packaged(["--quit-after", "300"])
        migrated = read_save()
        if int(migrated.get("schema_version", -1)) < 2:
            raise AssertionError(f"packaged game did not migrate v1 -> v2: {migrated}")
        for field in ("hp", "coins", "items", "quests"):
            if field not in migrated:
                raise AssertionError(f"migration missed field {field}: {migrated}")
        visited = migrated.get("visited_maps", [])
        if "res://scenes/maps/map_l1.tscn" not in visited:
            raise AssertionError(f"v1 progress lost in migration: {migrated}")

        # —— 4. 二次启动存档持续（继续游玩语义）——
        run_packaged(["--quit-after", "300"])
        resumed = read_save()
        if int(resumed.get("schema_version", -1)) < 2:
            raise AssertionError(f"save did not survive a second boot: {resumed}")
        if "res://scenes/maps/map_l1.tscn" not in resumed.get("visited_maps", []):
            raise AssertionError(f"visited progress dropped: {resumed}")

        print(f"Gate-D verified (PCK form): self-contained pack boots headless "
              f"(exit 0), fresh v2 save written, hand-written v1 save migrated "
              f"in the packaged game, progress survives reboots. "
              f"Pack size {PCK.stat().st_size} bytes. "
              f"(exe form covered by test_slice_b_exe_export_flow.py)")
        return 0
    finally:
        process.kill()
        process.wait(timeout=15)


if __name__ == "__main__":
    sys.exit(main())
