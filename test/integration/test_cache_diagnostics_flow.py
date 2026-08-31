"""Cache hit-rate regression flow.

Boots a headless editor with the plugin, repeats read-only catalog calls and
asserts via get_cache_diagnostics that the shared result cache actually serves
them (hit rate above threshold). This turns "the cache works" from a design
claim into a CI-protected regression: any change that accidentally invalidates
these reads on every call shows up here as a hit-rate drop.
"""

import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
GODOT_EXE = Path(os.environ.get("GODOT_EXE", r"C:\SourceCode\Godot_v4.6.2-stable_mono_win64\Godot_v4.6.2-stable_mono_win64_console.exe"))
MCP_URL = f"http://127.0.0.1:{os.environ.get('MCP_PORT', '9080')}/mcp"


def rpc_call(method: str, params: dict | None = None, request_id: int = 1) -> dict:
    payload = {
        "jsonrpc": "2.0",
        "method": method,
        "params": params or {},
        "id": request_id,
    }
    request = urllib.request.Request(
        MCP_URL,
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=15) as response:
        return json.loads(response.read().decode("utf-8"))


def tool_call(name: str, arguments: dict | None = None, request_id: int = 100) -> dict:
    response = rpc_call(
        "tools/call",
        {"name": name, "arguments": arguments or {}},
        request_id=request_id,
    )
    result = response["result"]
    if result.get("isError"):
        raise AssertionError(f"Tool {name} failed: {result['content'][0]['text']}")
    if "structuredContent" in result:
        return result["structuredContent"]
    return json.loads(result["content"][0]["text"])


def wait_for_server(timeout_seconds: float = 40.0) -> None:
    deadline = time.time() + timeout_seconds
    last_error = None
    while time.time() < deadline:
        try:
            response = rpc_call("initialize", {
                "protocolVersion": "2025-06-18",
                "capabilities": {},
                "clientInfo": {"name": "cache-flow-test", "version": "0.1"},
            })
            if "result" in response:
                rpc_call("notifications/initialized")
                return
        except (urllib.error.URLError, OSError) as error:
            last_error = error
        time.sleep(0.5)
    raise TimeoutError(f"MCP server did not come up: {last_error}")


def main() -> int:
    if not GODOT_EXE.exists():
        print(f"GODOT_EXE not found: {GODOT_EXE}")
        return 2
    args = [
        str(GODOT_EXE), "--editor", "--headless", "--path", str(REPO_ROOT),
        "--", "--mcp-server", f"--mcp-port={os.environ.get('MCP_PORT', '9080')}",
    ]
    process = subprocess.Popen(
        args,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        cwd=str(REPO_ROOT),
    )
    try:
        wait_for_server()

        # supplementary 工具先启用（meta 组始终在线）。
        enabled = tool_call("enable_tools", {
            "tools": [
                "get_cache_diagnostics", "get_import_status",
                "list_project_scenes", "set_project_setting",
            ],
            "enabled": True,
        })
        assert not enabled.get("error"), enabled

        # 等待启动期 EditorFileSystem 首次扫描结束：它的完成信号会合法推进
        # 资源/脚本域失效标签，恰好打断"首读→复读"窗口。
        scan_deadline = time.time() + 30.0
        status = {}
        while time.time() < scan_deadline:
            status = tool_call("get_import_status", {})
            if not bool(status.get("busy", False))                     and float(status.get("scanning_progress", 1.0)) >= 1.0:
                break
            time.sleep(0.5)
        else:
            raise AssertionError(f"editor import scan never settled: {status}")

        # 预热并制造确定性的重复读：三类只读目录各读两次，第二次必须命中。
        per_tool_hits: dict = {}
        for name, tool_args in [
            ("list_project_scripts", {}),
            ("list_project_scenes", {}),
            ("get_project_info", {}),
        ]:
            first = tool_call(name, tool_args)
            assert not first.get("error"), first
            before = tool_call("get_cache_diagnostics", {}).get("result_cache", {})
            second = tool_call(name, tool_args)
            assert not second.get("error"), second
            after = tool_call("get_cache_diagnostics", {}).get("result_cache", {})
            per_tool_hits[name] = int(after.get("hits", 0)) - int(before.get("hits", 0))
        print("per-tool hits:", per_tool_hits)

        diagnostics = tool_call("get_cache_diagnostics", {})
        result_cache = diagnostics.get("result_cache", {})
        hits = int(result_cache.get("hits", 0))
        misses = int(result_cache.get("misses", 0))
        hit_rate = float(result_cache.get("hit_rate", 0.0))
        print(f"cache telemetry: hits={hits} misses={misses} hit_rate={hit_rate:.2f}")

        # 三个不同键的首读 = 3 次未命中；三次重复 = 3 次命中。
        # 阈值取得保守：任何把这些读变成每次重扫的回归都会明显跌破。
        assert hits >= 3, f"expected at least 3 cache hits, got {hits}"
        assert misses >= 3, f"expected at least 3 cold misses, got {misses}"
        assert hit_rate >= 0.5, f"hit rate {hit_rate:.2f} below the 0.5 regression floor"
        # 核心回归信号：每个只读工具的重复调用必须命中（任一变 0 即失效策略回归）。
        for name, tool_hits in per_tool_hits.items():
            assert tool_hits == 1, (
                f"{name}: repeat call did not hit the result cache ({tool_hits} hits) — "
                "an invalidation change has made these reads re-execute every call"
            )

        # 一次真实变更必须让受影响域失效：改 project settings 后
        # get_project_info（PROJECT_SETTINGS 标签）必须重新执行而非吃缓存。
        bumped = tool_call("set_project_setting", {
            "setting": "application/config/description",
            "value": "cache flow probe",
            "persist": False,
        })
        assert not bumped.get("error"), bumped
        refreshed = tool_call("get_project_info", {})
        assert not refreshed.get("error"), refreshed

        after = tool_call("get_cache_diagnostics", {})
        misses_after = int(after.get("result_cache", {}).get("misses", 0))
        assert misses_after > misses, (
            "a project-settings mutation must invalidate the settings-tagged read "
            f"(misses {misses} -> {misses_after})"
        )
        print("cache diagnostics flow verified")
        return 0
    finally:
        process.terminate()
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()


if __name__ == "__main__":
    sys.exit(main())
