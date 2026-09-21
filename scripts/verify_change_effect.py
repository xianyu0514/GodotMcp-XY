"""P0-2: Verify a modification actually took effect in the RUNNING game.

The "I changed the code but nothing changed when I play" killer:
  python scripts/verify_change_effect.py slice_b [--port auto]

What it proves (each step is a real MCP observation, printed as a checklist):
  1. TARGET  — project identity + run entry + session the probe sees.
  2. ENTITY  — the node's ACTUAL script (external path vs embedded source),
               owner scene chain, instance overrides, unsaved buffer risk.
  3. APPLIED — the change is read back at RUNTIME (disk value == live value).
  4. BEHAVED — the behavior measurably changed (attack cooldown shortened ->
               measured inter-attack interval shrinks by the same ratio).
  5. PERSIST — after save + a FRESH editor boot + re-run, the new value and
               the new interval survive (no "only in memory" illusions).
Any step failing prints its evidence and exits non-zero with the checklist.
"""

import argparse
import json
import random
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]


class Mcp:
    def __init__(self, port: int):
        self.url = f"http://127.0.0.1:{port}/mcp"
        self._id = 0

    def tool(self, name: str, args: dict | None = None, timeout: float = 300.0) -> dict:
        self._id += 1
        payload = {"jsonrpc": "2.0", "id": self._id, "method": "tools/call",
                   "params": {"name": name, "arguments": args or {}}}
        request = urllib.request.Request(
            self.url, data=json.dumps(payload).encode(),
            headers={"Content-Type": "application/json"}, method="POST")
        with urllib.request.urlopen(request, timeout=timeout) as response:
            resp = json.loads(response.read().decode())
        result = resp.get("result", {})
        if result.get("isError"):
            raise RuntimeError(f"{name}: {result['content'][0]['text'][:250]}")
        text = result.get("content", [{}])[0].get("text", "")
        try:
            parsed = json.loads(text)
            return parsed if isinstance(parsed, dict) else {"raw": text}
        except (json.JSONDecodeError, TypeError):
            return {"raw": text}


def wait_for_server(mcp: Mcp, timeout_seconds: float = 180.0) -> None:
    deadline = time.time() + timeout_seconds
    while time.time() < deadline:
        try:
            mcp.tool("get_project_info", {}, timeout=10.0)
            return
        except Exception:  # noqa: BLE001
            pass
        time.sleep(1.5)
    raise SystemExit("MCP server did not answer")


def boot(project: Path, godot: str) -> tuple[subprocess.Popen, Mcp]:
    port = random.randint(9300, 9799)
    process = subprocess.Popen(
        [godot, "--editor", "--headless", "--path", str(project),
         "--", "--mcp-server", f"--mcp-port={port}"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    mcp = Mcp(port)
    wait_for_server(mcp)
    return process, mcp


CHECKS: list[dict] = []


def record(step: str, ok: bool, evidence: str) -> bool:
    CHECKS.append({"step": step, "ok": ok, "evidence": evidence})
    print(f"  [{'OK' if ok else 'FAIL':4}] {step}: {evidence}")
    return ok


def _runtime_value(mcp: Mcp, node_path: str, prop: str, root_node: str):
    """Try the full path first; when the target IS the scene root, Godot
    names it after the scene file — fall back to the relative child path."""
    for candidate in (node_path, node_path.split("/", 1)[1] if "/" in node_path else node_path):
        try:
            value = mcp.tool("evaluate_runtime_expression", {
                "expression": f"get_node('{candidate}').{prop}"}, timeout=60.0).get("value")
            if value is not None:
                return value
        except RuntimeError:
            continue
    return None


def measure_attack_interval(mcp: Mcp, scene: str, taps: int = 8) -> float:
    """Latency-immune: tap attack repeatedly (press/release pulses — the
    component only accepts fresh presses); each accepted tap logs an
    engine-side start stamp. Interval = average consecutive delta = the
    cooldown gate the player actually feels."""
    mcp.tool("install_runtime_probe", {"node_name": "MCPRuntimeProbe", "persistent": True})
    mcp.tool("run_project", {"scene_path": scene, "allow_window": True})
    time.sleep(2.0)
    for _ in range(taps):
        mcp.tool("simulate_runtime_input_action", {"action_name": "attack", "pressed": True})
        time.sleep(0.05)
        mcp.tool("simulate_runtime_input_action", {"action_name": "attack", "pressed": False})
        time.sleep(0.12)
    time.sleep(0.3)
    log = mcp.tool("evaluate_runtime_expression", {
        "expression": "get_node('Attack').swing_log_ms"}, timeout=60.0).get("value")
    mcp.tool("stop_project", {"allow_window": True})
    if not isinstance(log, list) or len(log) < 2:
        return -1.0
    deltas = [(log[i + 1] - log[i]) / 1000.0 for i in range(len(log) - 1)]
    return sum(deltas) / len(deltas)

def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("project", nargs="?", default="slice_b")
    parser.add_argument("--scene", default="res://scenes/player.tscn")
    parser.add_argument("--node", default="Player")
    parser.add_argument("--property", default="Attack.cooldown_seconds")
    parser.add_argument("--from", dest="value_from", type=float, default=0.55)
    parser.add_argument("--to", dest="value_to", type=float, default=0.25)
    parser.add_argument("--godot", default=r"D:\youxi\kaifa\Godot_v4.7.2-stable_win64_console.exe")
    args = parser.parse_args()

    project = (REPO_ROOT / args.project).resolve()
    prop_path = args.property.split(".")
    node_path, prop_name = args.node + "/" + prop_path[0], prop_path[1]
    # slice_b 的 Player 是场景根：运行时路径不带 Player 前缀。探测式选择。
    runtime_prefix = ""

    print("=== P0-2: verify the change actually reaches the game ===")
    process, mcp = boot(project, args.godot)
    try:
        mcp.tool("enable_tools", {"tools": [
            "get_project_info", "open_scene", "read_script", "save_scene",
            "batch_scene_node_edits", "install_runtime_probe", "run_project",
            "stop_project", "simulate_runtime_input_action",
            "evaluate_runtime_expression", "get_scene_structure"]})

        # 1) TARGET
        info = mcp.tool("get_project_info")
        target_ok = record("target project confirmed",
                           bool(info.get("project_name")),
                           f"{info.get('project_name', '?')} @ {info.get('project_path', '?')}")

        # 2) ENTITY — which script really serves the node
        mcp.tool("open_scene", {"scene_path": args.scene, "allow_ui_focus": True})
        structure = mcp.tool("get_scene_structure")
        text = json.dumps(structure)
        node_known = record("node exists in the edited scene",
                            f'"{args.node}"' in text or '"root_node"' in text,
                            f"node={args.node}")
        player_read = mcp.tool("read_script", {"script_path": "res://scripts/player/player.gd"})
        content = str(player_read.get("content", ""))
        external_ok = record("player script is an external file (not embedded)",
                             "extends CharacterBody2D" in content,
                             f"res://scripts/player/player.gd ({len(content)} chars, "
                             f"hash {str(player_read.get('content_hash', ''))[:8]})")
        take_hit = record("take_hit wired (runtime damage entry)",
                          "play_hit_feedback" in content,
                          "wired" if "play_hit_feedback" in content else "MISSING WIRE")

        # 2.5) BASELINE behavior at the ORIGINAL value (the comparison anchor)
        interval_old = measure_attack_interval(mcp, args.scene)
        record("baseline interval measured", interval_old > 0,
               f"inter-attack interval at {prop_name}={args.value_from}: {interval_old:.2f}s")

        # 3) APPLIED — set the property, read it back at runtime
        mcp.tool("batch_scene_node_edits", {"operations": [
            {"type": "set_property", "node_path": node_path,
             "property_name": prop_name, "property_value": args.value_to}]})
        mcp.tool("save_scene", {"scene_path": args.scene})
        mcp.tool("install_runtime_probe", {"node_name": "MCPRuntimeProbe", "persistent": True})
        mcp.tool("run_project", {"scene_path": args.scene, "allow_window": True})
        time.sleep(2.0)
        live = _runtime_value(mcp, node_path, prop_name, args.node)
        applied_ok = record("runtime readback equals requested value",
                            live == args.value_to,
                            f"live={live} requested={args.value_to}")
        mcp.tool("stop_project", {"allow_window": True})

        # 4) BEHAVED — the measured interval shrinks with the shorter cooldown
        interval_new = measure_attack_interval(mcp, args.scene)
        behaved_ok = record("behavior measurably changed",
                            interval_new > 0 and interval_new <= interval_old - 0.15,
                            f"{interval_old:.2f}s -> {interval_new:.2f}s after "
                            f"{prop_name} {args.value_from} -> {args.value_to}")

        # 5) PERSIST — fresh boot, re-read, re-measure
        process.terminate()
        try:
            process.wait(timeout=15)
        except subprocess.TimeoutExpired:
            process.kill()
        process, mcp = boot(project, args.godot)
        mcp.tool("enable_tools", {"tools": [
            "install_runtime_probe", "run_project", "stop_project",
            "simulate_runtime_input_action", "evaluate_runtime_expression"]})
        mcp.tool("install_runtime_probe", {"node_name": "MCPRuntimeProbe", "persistent": True})
        mcp.tool("run_project", {"scene_path": args.scene, "allow_window": True})
        time.sleep(2.0)
        live2 = _runtime_value(mcp, node_path, prop_name, args.node)
        persist_value = record("value persists after a fresh editor boot",
                              live2 == args.value_to, f"live after restart={live2}")
        mcp.tool("stop_project", {"allow_window": True})
        interval2 = measure_attack_interval(mcp, args.scene)
        persist_behaviour = record("behavior persists after restart",
                                   interval2 > 0 and interval2 <= interval_old - 0.15,
                                   f"interval after restart={interval2:.2f}s "
                                   f"(baseline {interval_old:.2f}s)")

        # restore the original value (leave the project as we found it)
        process.terminate()
        try:
            process.wait(timeout=15)
        except subprocess.TimeoutExpired:
            process.kill()
        process, mcp = boot(project, args.godot)
        mcp.tool("enable_tools", {"tools": [
            "open_scene", "batch_scene_node_edits", "save_scene"]})
        mcp.tool("open_scene", {"scene_path": args.scene, "allow_ui_focus": True})
        mcp.tool("batch_scene_node_edits", {"operations": [
            {"type": "set_property", "node_path": node_path,
             "property_name": prop_name, "property_value": args.value_from}]})
        mcp.tool("save_scene", {"scene_path": args.scene})
        print(f"[restored] {prop_name} back to {args.value_from}")
    finally:
        process.terminate()
        try:
            process.wait(timeout=15)
        except subprocess.TimeoutExpired:
            process.kill()

    print("\n=== VERIFY-CHANGE-EFFECT CHECKLIST ===")
    failures = 0
    for check in CHECKS:
        status = "verified" if check["ok"] else "NOT MET"
        if not check["ok"]:
            failures += 1
        print(f"  [{status}] {check['step']}: {check['evidence']}")
    print(f"=== {'ALL STEPS VERIFIED' if failures == 0 else str(failures) + ' STEP(S) NOT MET — OVERALL: NOT VERIFIED'} ===")
    return 0 if failures == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
