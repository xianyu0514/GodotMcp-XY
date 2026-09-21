"""Hot-sync the MCP plugin from this repository into a live Godot project
and reload it inside the RUNNING editor — no restart, no manual copying.

This is the deploy step of the tight development loop:
    use MCP on a real project -> hit a defect -> fix it in the repo ->
    `python scripts/hot_sync_plugin.py <target_project> --port 9080` ->
    the running editor picks up the fix -> keep making the game.

What it does
  1. Copies changed files under addons/godot_mcp (by content) into the
     target project: .gd .cfg .csv .json .uid .tscn .import-source text.
  2. Asks the running editor (via the MCP itself) to rescan the filesystem.
  3. Waits until the editor main thread settles (watchdog 503s while a
     scan/import/reload holds the thread).
  4. Health probe: get_project_info must answer afterwards.

  This script deliberately does NOT force-reload tool modules: explicit
  .reload() on modules whose instances are SERVING traffic corrupts them
  (observed live - the next behavior_check dropped the connection). The
  editor's own external-change hot reload, or an editor restart, is the
  only safe reload path; data-only changes (csv/json) apply immediately.

Safety
  - Only addons/godot_mcp is touched; game content is never modified.

Usage
  python scripts/hot_sync_plugin.py D:/youxi/kaifa/1 --port 9080
  python scripts/hot_sync_plugin.py D:/youxi/kaifa/1 --only addons/godot_mcp/tools/debug_runtime_tools.gd
"""

import argparse
import json
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
PLUGIN_SUBDIR = Path("addons/godot_mcp")
COPY_EXTENSIONS = {".gd", ".cfg", ".csv", ".json", ".uid"}
# Entry + transport layer: reloaded only with --include-core.
CORE_RELATIVE = {
    "addons/godot_mcp/mcp_server_native.gd",
    "addons/godot_mcp/native_mcp/mcp_http_server.gd",
    "addons/godot_mcp/native_mcp/mcp_stdio_server.gd",
    "addons/godot_mcp/native_mcp/mcp_transport_base.gd",
}


def http_tool(port: int, name: str, arguments: dict, timeout: float = 60.0) -> dict:
    payload = json.dumps({
        "jsonrpc": "2.0", "id": int(time.time() * 1000) % 10 ** 9,
        "method": "tools/call",
        "params": {"name": name, "arguments": arguments},
    }).encode()
    request = urllib.request.Request(
        f"http://127.0.0.1:{port}/mcp", data=payload,
        headers={"Content-Type": "application/json"}, method="POST")
    with urllib.request.urlopen(request, timeout=timeout) as response:
        body = response.read().decode()
    if not body.strip():
        raise RuntimeError(f"empty MCP response for {name}")
    resp = json.loads(body)
    result = resp.get("result", {})
    if result.get("isError"):
        raise RuntimeError(f"{name}: {result['content'][0]['text'][:300]}")
    text = result.get("content", [{}])[0].get("text", "")
    try:
        return json.loads(text)
    except (json.JSONDecodeError, TypeError):
        return {"raw": text}


def collect_changed(source_root: Path, target_root: Path, only: str | None) -> list[Path]:
    src = source_root / PLUGIN_SUBDIR
    if only:
        candidates = [source_root / only]
    else:
        candidates = [p for p in src.rglob("*")
                      if p.is_file() and p.suffix.lower() in COPY_EXTENSIONS]
    changed: list[Path] = []
    for path in candidates:
        if not path.is_file():
            raise SystemExit(f"source file not found: {path}")
        rel = path.relative_to(source_root)
        dst = target_root / rel
        if dst.exists() and dst.read_bytes() == path.read_bytes():
            continue
        changed.append(path)
    return changed


def copy_changed(source_root: Path, target_root: Path, changed: list[Path]) -> list[str]:
    copied: list[str] = []
    for path in changed:
        rel = path.relative_to(source_root)
        dst = target_root / rel
        dst.parent.mkdir(parents=True, exist_ok=True)
        dst.write_bytes(path.read_bytes())
        copied.append(rel.as_posix())
    return copied


def request_scan_and_settle(port: int) -> None:
    """Trigger a filesystem scan, then wait until the editor main thread is
    stable again (the dispatch watchdog answers 503 while scan/import/reload
    holds the main thread).

    Deliberately does NOT force-reload scripts: reloading modules whose
    instances are serving traffic corrupts them (observed live: the next
    behavior_check dropped the connection after an explicit .reload()).
    The editor's own external-change hot reload - or a restart - is the
    only safe reload path."""
    try:
        http_tool(port, "execute_editor_script", {"code":
            "EditorInterface.get_resource_filesystem().scan()\n"
            "_custom_print('scan requested')"}, timeout=30)
    except Exception as exc:  # noqa: BLE001 - scan may hit the busy watchdog
        print(f"scan request note: {exc}")
    stable = 0
    deadline = time.time() + 120
    while time.time() < deadline and stable < 3:
        try:
            payload = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "tools/list", "params": {}}).encode()
            request = urllib.request.Request(
                f"http://127.0.0.1:{port}/mcp", data=payload,
                headers={"Content-Type": "application/json"}, method="POST")
            with urllib.request.urlopen(request, timeout=8) as response:
                if "result" in json.loads(response.read().decode()):
                    stable += 1
            time.sleep(1.0)
        except Exception:  # noqa: BLE001 - busy watchdog / dropped connection
            stable = 0
            time.sleep(3.0)
    if stable < 3:
        raise SystemExit("editor main thread never settled after the scan")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("target_project", help="path of the live Godot project")
    parser.add_argument("--port", default="9080", help="MCP HTTP port of the live editor")
    parser.add_argument("--only", default=None,
                        help="repo-relative file to sync (default: whole plugin dir)")
    args = parser.parse_args()

    target = Path(args.target_project)
    if not (target / "project.godot").exists():
        raise SystemExit(f"not a Godot project: {target}")

    changed = collect_changed(REPO_ROOT, target, args.only)
    if not changed:
        print("nothing to sync — repo plugin and target are identical")
    else:
        copied = copy_changed(REPO_ROOT, target, changed)
        print(f"copied {len(copied)} file(s):")
        for rel in copied:
            print("  ", rel)
        request_scan_and_settle(int(args.port))
        gd_files = [rel for rel in copied if rel.endswith(".gd")]
        if gd_files:
            print(f"{len(gd_files)} script(s) synced. Behavior changes take effect via")
            print("the editor's automatic hot reload (usually immediate) or fully")
            print("reliably after an editor restart. Data files apply immediately.")

    health = http_tool(int(args.port), "get_project_info", {})
    name = health.get("project_name", "?")
    print(f"health: server answering, project '{name}' at {health.get('project_path', '?')}")
    print("HOT SYNC COMPLETE")
    return 0


if __name__ == "__main__":
    sys.exit(main())
