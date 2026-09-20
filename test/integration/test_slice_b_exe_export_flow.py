"""Gate-D exe-export leg: the classic export — real SliceB.exe built via MCP
and verified outside the editor (boot / save / v1->v2 migration / resume).

Preconditions: 4.7.2 export templates installed under
%APPDATA%/Godot/export_templates/4.7.2.stable (the user-supplied tpz).
The PCK-form sibling (test_slice_b_export_flow.py) covers the same
runtime assertions when templates are unavailable.

Flow:
1. Editor session creates the Windows Desktop preset (idempotent) and
   runs the export via run_export
2. SliceB.exe boots headless (exit 0), the autoload writes a v2 save
3. A hand-written v1 save is migrated to v2 by the exported game on
   the next boot, v1 progress preserved
4. A second boot keeps the save (continue-play semantics)

Usage: python test/integration/test_slice_b_exe_export_flow.py
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
PORT = 9201
URL = f"http://127.0.0.1:{PORT}/mcp"
EXE = SLICE / "build/SliceB.exe"
USER_DATA = Path(os.environ.get("APPDATA", "")) / "Godot" / "app_userdata" / "SliceB"
SAVE = USER_DATA / "slice_b_save.json"
_rid = 9500


def rpc(name, args, timeout=600.0):
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


def run_exported(extra_args):
    args = [str(EXE), "--headless"] + extra_args
    result = subprocess.run(args, capture_output=True, text=True,
                            cwd=str(EXE.parent), timeout=120)
    if result.returncode != 0:
        raise AssertionError(
            f"exported exe exit {result.returncode}: {(result.stderr or result.stdout)[-400:]}")
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
    templates = Path(os.environ.get("APPDATA", "")) / "Godot" / "export_templates" / "4.7.2.stable"
    if not (templates / "windows_release_x86_64.exe").exists():
        raise AssertionError(f"export templates missing under {templates}")
    subprocess.run(["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass",
                    "-File", str(SLICE / "setup.ps1")], capture_output=True, timeout=120)
    shutil.rmtree(USER_DATA, ignore_errors=True)
    if EXE.exists():
        EXE.unlink()

    process = subprocess.Popen(
        [GODOT, "--editor", "--headless", "--path", str(SLICE),
         "--", "--mcp-server", f"--mcp-port={PORT}"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, cwd=str(SLICE))
    try:
        wait_server()
        rpc("enable_tools", {"tools": ["create_export_preset", "run_export"], "enabled": True})

        preset = rpc("create_export_preset", {
            "name": "Windows Desktop",
            "platform": "Windows Desktop",
            "export_path": "res://build/SliceB.exe",
            "if_exists": "reuse",
        })
        if preset.get("error"):
            raise AssertionError(f"preset creation failed: {preset['error']}")

        export = rpc("run_export", {"preset": "Windows Desktop", "mode": "release"},
                     timeout=900.0)
        if export.get("error"):
            raise AssertionError(f"export failed: {export['error']}")
        if not EXE.exists():
            raise AssertionError(f"export reported success but the exe is missing: {export}")

        # —— 打包 exe 的完整运行时链 ——
        run_exported(["--quit-after", "300"])
        first = read_save()
        if first is None or int(first.get("schema_version", -1)) != 2:
            raise AssertionError(f"exported game did not write a v2 save: {first}")

        write_save({
            "schema_version": 1,
            "visited_maps": ["res://scenes/maps/map_l1.tscn"],
            "last_map": "res://scenes/maps/map_l1.tscn",
            "player_position": {"x": 11.0, "y": 22.0},
        })
        run_exported(["--quit-after", "300"])
        migrated = read_save()
        if int(migrated.get("schema_version", -1)) != 2:
            raise AssertionError(f"exported game did not migrate v1 -> v2: {migrated}")
        for field in ("hp", "coins", "items", "quests"):
            if field not in migrated:
                raise AssertionError(f"migration missed field {field}: {migrated}")
        if "res://scenes/maps/map_l1.tscn" not in migrated.get("visited_maps", []):
            raise AssertionError(f"v1 progress lost in migration: {migrated}")

        run_exported(["--quit-after", "300"])
        resumed = read_save()
        if int(resumed.get("schema_version", -1)) != 2:
            raise AssertionError(f"save did not survive a second boot: {resumed}")

        print(f"Gate-D exe leg verified: real SliceB.exe exported via MCP "
              f"({EXE.stat().st_size} bytes), boots headless (exit 0), writes v2 "
              f"saves, migrates a hand-written v1 save, progress survives reboots.")
        return 0
    finally:
        process.kill()
        process.wait(timeout=15)


if __name__ == "__main__":
    sys.exit(main())
