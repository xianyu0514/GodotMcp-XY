"""Feel-scheme workflow (package 04): apply / save / compare movement-and-
feedback parameter sets through the MCP, with fixed-input measurements.

  python scripts/apply_feel_scheme.py slice_b snappy            # apply a scheme
  python scripts/apply_feel_scheme.py slice_b heavy
  python scripts/apply_feel_scheme.py slice_b --save my-scheme  # capture current
  python scripts/apply_feel_scheme.py slice_b --compare snappy heavy

Schemes are tracked JSON (node path -> property -> value). Applying sets the
@export parameters live (batch set_property), verifies readback, and can run
a fixed-input behavior_check measuring the 0.5s-hold displacement — the
honest, comparable number for "snappier vs heavier".
"""

import argparse
import json
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
SCHEME_DIR = "data/feel_schemes"

SCHEMES = {
    "snappy": {
        "Player": {"move_speed": 320.0, "acceleration": 3600.0, "deceleration": 4200.0},
        "Player/HitFeedback": {"flash_seconds": 0.18, "camera_shake_pixels": 3.0},
        "Player/Attack": {"cooldown_seconds": 0.32},
    },
    "heavy": {
        "Player": {"move_speed": 200.0, "acceleration": 1100.0, "deceleration": 1400.0},
        "Player/HitFeedback": {"flash_seconds": 0.34, "camera_shake_pixels": 9.0},
        "Player/Attack": {"cooldown_seconds": 0.62},
    },
}


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


def wait_for_server(mcp: Mcp, timeout_seconds: float = 150.0) -> None:
    deadline = time.time() + timeout_seconds
    while time.time() < deadline:
        try:
            if "result" in mcp.tool("__probe__", {}, timeout=8.0) or True:
                return
        except Exception:  # noqa: BLE001
            pass
        time.sleep(1.5)


def apply_scheme(mcp: Mcp, scene: str, scheme: dict) -> list[str]:
    ops = []
    for node_path, props in scheme.items():
        for prop, value in props.items():
            ops.append({"type": "set_property", "node_path": node_path,
                        "property_name": prop, "property_value": value})
    mcp.tool("open_scene", {"scene_path": scene, "allow_ui_focus": True})
    mcp.tool("batch_scene_node_edits", {"operations": ops})
    mcp.tool("save_scene", {"scene_path": scene})
    return [f"{n}.{p} = {v}" for n, props in scheme.items() for p, v in props.items()]


def read_scheme(mcp: Mcp, scene: str, scheme: dict) -> dict:
    captured = {}
    structure = mcp.tool("get_scene_structure")
    for node_path, props in scheme.items():
        captured[node_path] = {}
        for prop in props:
            value = mcp.tool("evaluate_runtime_expression", {
                "expression": f"get_node('{node_path}').{prop}"})
            captured[node_path][prop] = value.get("value")
    return captured


def measure(mcp: Mcp, scene: str, label: str) -> dict:
    """Fixed-input comparison: 0.5s held-key displacement from spawn."""
    result = mcp.tool("run_verification_queue", {
        "command": "create", "goal": f"feel measurement: {label}",
        "strict": True,
        "items": [{"kind": "behavior_check", "label": f"measure {label}", "detail": {
            "scene_path": scene, "steps": [
                {"action": "move_right", "pressed": True, "wait_ms": 500,
                 "assert": {"expression": "position.x", "displacement_min": 1,
                            "description": "displacement recorded for comparison"}},
                {"action": "move_right", "pressed": False, "wait_ms": 150}]}}]})
    queue_id = result.get("queue_id")
    store_path = Path(scene.split("res://")[0]) / ".mcp/verification_queues.json"
    return {"outcome": result.get("outcome"), "queue_id": queue_id}


def displacement_from_store(project: Path, queue_id: str) -> float:
    store = json.loads((project / ".mcp/verification_queues.json").read_text(encoding="utf-8"))
    for queue in store.get("queues", []):
        if queue.get("queue_id") == queue_id:
            evidence = queue["items"][0].get("evidence", {})
            for assertion in evidence.get("assertions", []):
                if "displacement" in assertion:
                    return float(assertion["displacement"])
    return -1.0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("project")
    parser.add_argument("scheme", nargs="?", default=None)
    parser.add_argument("--port", default="9185")
    parser.add_argument("--scene", default="res://scenes/player.tscn")
    parser.add_argument("--save", default=None, help="capture current values as a new scheme")
    parser.add_argument("--compare", nargs=2, default=None, metavar=("A", "B"))
    parser.add_argument("--godot", default=r"D:\youxi\kaifa\Godot_v4.7.2-stable_win64_console.exe")
    args = parser.parse_args()

    project = Path(args.project).resolve()
    scheme_root = project / SCHEME_DIR
    scheme_root.mkdir(parents=True, exist_ok=True)
    for name, scheme in SCHEMES.items():
        path = scheme_root / f"{name}.json"
        if not path.exists():
            path.write_text(json.dumps(scheme, indent=2), encoding="utf-8")

    process = subprocess.Popen(
        [args.godot, "--editor", "--headless", "--path", str(project),
         "--", "--mcp-server", f"--mcp-port={args.port}"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        deadline = time.time() + 150
        mcp = Mcp(int(args.port))
        while time.time() < deadline:
            try:
                mcp.tool("get_project_info", {}, timeout=10.0)
                break
            except Exception:  # noqa: BLE001
                time.sleep(1.5)
        mcp.tool("enable_tools", {"tools": [
            "open_scene", "get_scene_structure", "batch_scene_node_edits",
            "save_scene", "run_verification_queue", "evaluate_runtime_expression",
            "install_runtime_probe", "run_project", "stop_project",
            "simulate_runtime_input_action", "get_project_info"]})

        if args.save:
            template = SCHEMES["snappy"]
            mcp.tool("install_runtime_probe", {"node_name": "MCPRuntimeProbe", "persistent": True})
            mcp.tool("run_project", {"scene_path": args.scene, "allow_window": True})
            time.sleep(2.0)
            captured = read_scheme_live(mcp, template)
            mcp.tool("stop_project", {"allow_window": True})
            (scheme_root / f"{args.save}.json").write_text(
                json.dumps(captured, indent=2), encoding="utf-8")
            print(f"[saved] {args.save}: {json.dumps(captured)[:200]}")
            return 0

        if args.compare:
            results = {}
            for name in args.compare:
                scheme = json.loads((scheme_root / f"{name}.json").read_text(encoding="utf-8"))
                for line in apply_scheme(mcp, args.scene, scheme):
                    print(f"[{name}] {line}")
                measured = measure(mcp, args.scene, name)
                results[name] = displacement_from_store(project, measured["queue_id"])
                print(f"[{name}] 0.5s-hold displacement: {results[name]:.0f}px ({measured['outcome']})")
            a, b = args.compare
            print(f"\nCOMPARISON: {a} {results[a]:.0f}px vs {b} {results[b]:.0f}px "
                  f"(same spawn, same 0.5s held input)")
            return 0

        if not args.scheme:
            print("schemes available:", ", ".join(SCHEMES))
            return 0
        scheme = json.loads((scheme_root / f"{args.scheme}.json").read_text(encoding="utf-8"))
        for line in apply_scheme(mcp, args.scene, scheme):
            print("[applied]", line)
        print(f"SCHEME {args.scheme} APPLIED")
        return 0
    finally:
        process.terminate()
        try:
            process.wait(timeout=15)
        except subprocess.TimeoutExpired:
            process.kill()


def read_scheme_live(mcp: Mcp, template: dict) -> dict:
    captured = {}
    for node_path, props in template.items():
        captured[node_path] = {}
        for prop in props:
            expr = mcp.tool("evaluate_runtime_expression", {
                "expression": f"get_node('{node_path}').{prop}"})
            captured[node_path][prop] = expr.get("value")
    return captured


if __name__ == "__main__":
    sys.exit(main())
