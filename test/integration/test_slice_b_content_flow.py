"""Gate-B content pass: real visuals and audio, all made through MCP.

1. create_gradient_texture: one sky texture per map
2. generate_asset (placeholder mode): pickup/hit/door sfx + bgm
3. wire: maps get TextureRect backgrounds; player/door/pickup call the
   sound bus; map_root starts the BGM
4. verify in the live tree: sounds playing, transition intact

Usage: python test/integration/test_slice_b_content_flow.py
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
PORT = 9205
URL = f"http://127.0.0.1:{PORT}/mcp"
_rid = 9800

SKIES = {
    "sky_l1.tres": {"colors": ["#87ceeb", "#a8d8a8", "#5a9e5a"],
                    "desc": "meadow morning"},
    "sky_l2.tres": {"colors": ["#e8b86d", "#c98a3d", "#8a5a2a"],
                    "desc": "amber dusk"},
    "sky_boss.tres": {"colors": ["#5a1a24", "#8a2a3a", "#2a0a12"],
                      "desc": "crimson night"},
}
SFX = [
    ("pickup.wav", "bright pickup chime, sine, short", {"frequency": 880.0, "duration": 0.25, "waveform": "sine"}),
    ("hit.wav", "low impact thud, square", {"frequency": 110.0, "duration": 0.2, "waveform": "square"}),
    ("door.wav", "whoosh transition, triangle", {"frequency": 330.0, "duration": 0.4, "waveform": "triangle"}),
    ("bgm.wav", "calm loopable pad", {"frequency": 165.0, "duration": 6.0, "waveform": "sine", "amplitude": 0.35}),
]


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
                    "-File", str(SLICE / "setup.ps1")], capture_output=True, timeout=120)
    appdata = os.path.join(os.environ.get("APPDATA", ""), "Godot", "app_userdata")
    shutil.rmtree(os.path.join(appdata, "SliceB"), ignore_errors=True)

    process = subprocess.Popen(
        [GODOT, "--editor", "--headless", "--path", str(SLICE),
         "--", "--mcp-server", f"--mcp-port={PORT}"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, cwd=str(SLICE))
    try:
        wait_server()
        rpc("enable_tools", {"tools": [
            "create_gradient_texture", "generate_asset",
            "install_runtime_probe", "run_project", "stop_project",
            "play_and_verify"], "enabled": True})

        # —— 1. 三张地图的天空纹理 ——
        for name, spec in SKIES.items():
            result = rpc("create_gradient_texture", {
                "resource_path": f"res://art/{name}",
                "fill": "linear",
                "colors": spec["colors"],
                "fill_from": {"x": 0.0, "y": 0.0},
                "fill_to": {"x": 0.0, "y": 1.0},
                "width": 64, "height": 360,
            })
            if str(result.get("status", "")) != "success":
                raise AssertionError(f"sky {name}: {json.dumps(result)[:300]}")
        print("skies: 3 gradient textures created")

        # —— 2. 音效与 BGM ——
        for name, prompt, extra in SFX:
            result = rpc("generate_asset", {
                "type": "audio",
                "prompt": prompt,
                "provider": "placeholder",
                "resource_path": f"res://audio/{name}",
                **extra,
            })
            status = str(result.get("status", ""))
            if status not in ("success",):
                raise AssertionError(f"audio {name}: {json.dumps(result)[:300]}")
        print("audio: pickup/hit/door/bgm generated")

        # —— 3. 场景与脚本接线由仓库文件承担（地图场景引用纹理 + sound_bus
        #    autoload + player/door/pickup 调用），本流程只验资产与运行时。

        # —— 4. 运行时验证 ——
        installed = rpc("install_runtime_probe",
                        {"node_name": "MCPRuntimeProbe", "persistent": False})
        if installed.get("status") not in ("success", "already_installed"):
            raise AssertionError(f"probe install failed: {installed}")
        for attempt in range(3):
            try:
                rpc("run_project", {"allow_window": True})
                break
            except AssertionError:
                if attempt == 2:
                    raise
                time.sleep(8)
        verdict = rpc("play_and_verify", {
            "steps": [
                {"assert": {"expression":
                    "get_node(\"/root/SoundBus\")._bgm.stream != null and get_node(\"/root/SoundBus\")._bgm.playing",
                    "expected": True, "description": "BGM streaming in the live tree"}},
                {"assert": {"expression":
                    "get_node(\"Background\").texture != null",
                    "expected": True, "description": "L1 background is a real texture"}},
                {"action": "move_right", "pressed": True, "wait_ms": 3300},
                {"action": "move_right", "pressed": False, "wait_ms": 800},
                {"assert": {"expression": "get_tree().current_scene.map_id",
                    "expected": "res://scenes/maps/map_l2.tscn",
                    "description": "map transition still works with content in place"}},
                {"assert": {"expression":
                    "get_node(\"Background\").texture.resource_path.find(\"sky_l2\") >= 0",
                    "expected": True,
                    "description": "L2 shows its own sky"}},
            ],
        }, timeout=240.0)
        if not verdict.get("passed", False):
            raise AssertionError(f"runtime verdict failed: {json.dumps(verdict)[:600]}")

        print("Gate-B content verified: 3 map skies + 4 audio assets made via MCP, "
              "BGM playing live, per-map textures active, transition intact.")
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
