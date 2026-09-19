"""Editor-level change-set recovery flow (large-2D audit 2026-09-19, gate C).

High-efficiency evidence run: ONE editor session covers 30 consecutive
committed change sets (3 files each), then a real interruption (journal
prepared mid-set via the executor's interrupt hook), a hard editor kill,
restart, replay-to-resume, and a manual-edit conflict injection. An anchor
file proves untouched content survives everything.

Usage:
    python test_change_set_recovery_flow.py
Env:
    GODOT_EXE  Godot editor executable (4.7.x console build)
    MCP_PORT   HTTP MCP port (default 9187)
"""

import hashlib
import json
import os
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
GODOT_EXE = Path(os.environ.get("GODOT_EXE", r"D:\youxi\kaifa\Godot_v4.7.2-stable_win64_console.exe"))
MCP_PORT = os.environ.get("MCP_PORT", "9187")
MCP_URL = f"http://127.0.0.1:{MCP_PORT}/mcp"
FIXTURE = REPO_ROOT / ".tmp_cs_flow"
JOURNAL = REPO_ROOT / ".mcp" / "change_journal.json"
CHANGE_SETS = 30
FILES_PER_SET = 3

_rpc_id = 7000


def rpc_call(method: str, params: dict) -> dict:
    global _rpc_id
    _rpc_id += 1
    payload = {"jsonrpc": "2.0", "method": method, "params": params, "id": _rpc_id}
    request = urllib.request.Request(
        MCP_URL,
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.loads(response.read().decode("utf-8"))


def tool_call(name: str, arguments: dict) -> dict:
    response = rpc_call("tools/call", {"name": name, "arguments": arguments})
    result = response["result"]
    if result.get("isError"):
        raise AssertionError(f"Tool {name} failed: {result['content'][0]['text']}")
    if "structuredContent" in result:
        return result["structuredContent"]
    return json.loads(result["content"][0]["text"])


def wait_for_server(timeout_seconds: float = 150.0) -> None:
    deadline = time.time() + timeout_seconds
    last_error = None
    while time.time() < deadline:
        try:
            rpc_call("tools/list", {})
            return
        except Exception as exc:
            last_error = exc
            time.sleep(0.5)
    raise TimeoutError(
        f"Timed out waiting for MCP server on port {MCP_PORT}; last error: {type(last_error).__name__}: {last_error}")


def start_editor() -> subprocess.Popen:
    args = [
        str(GODOT_EXE),
        "--editor", "--headless", "--path", str(REPO_ROOT),
        "--", "--mcp-server", f"--mcp-port={MCP_PORT}",
    ]
    return subprocess.Popen(
        args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, cwd=REPO_ROOT)


def stop_editor_hard(process: subprocess.Popen) -> None:
    process.kill()
    process.wait(timeout=15)


def write_file(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8", newline="")


def read_script_hash(res_path: str) -> str:
    result = tool_call("read_script", {"script_path": res_path})
    if result.get("status") != "success" and "content_hash" not in result:
        raise AssertionError(f"read_script failed for {res_path}: {result}")
    return result["content_hash"]


def build_operations(set_index: int) -> list:
    operations = []
    for file_index in range(FILES_PER_SET):
        res_path = f"res://.tmp_cs_flow/set_{set_index:02d}/file_{file_index}.gd"
        old_text = f"var value_{set_index}_{file_index} := 0"
        new_text = f"var value_{set_index}_{file_index} := {set_index + 1}"
        operations.append({
            "path": res_path,
            "expected_content_hash": read_script_hash(res_path),
            "edits": [{"old_text": old_text, "new_text": new_text}],
        })
    return operations


def inject_interrupt(set_index: int, operations: list, interrupt_after: int, change_set_id: str) -> dict:
    """Run the executor's interrupt hook inside the real editor process so the
    journal stays prepared mid-set (the authentic crash window)."""
    payload = {
        "intent": f"interrupted set {set_index}",
        "operations": operations,
        "change_set_id": change_set_id,
        "interrupt_after": interrupt_after,
    }
    code = (
        "var executor = load(\"res://addons/godot_mcp/tools/change_set_executor.gd\")\n"
        f"var result = executor.apply(JSON.parse_string('{json.dumps(payload)}'))\n"
        "_custom_print(JSON.stringify(result))\n"
    )
    result = tool_call("execute_editor_script", {"code": code})
    output = result.get("output", "") if isinstance(result, dict) else ""
    # _custom_print 的多次输出被收集为数组；拼成文本再取首个 JSON 对象。
    if isinstance(output, list):
        output = "\n".join(str(part) for part in output)
    start = str(output).find("{")
    if start < 0:
        raise AssertionError(f"execute_editor_script returned no JSON: {result}")
    return json.loads(str(output)[start:])


def verify_file(res_path: str, expected_contains: str, label: str) -> None:
    content = (REPO_ROOT / res_path.replace("res://", "")).read_text(encoding="utf-8")
    if expected_contains not in content:
        raise AssertionError(f"{label}: {res_path} does not contain '{expected_contains}':\n{content}")


def main() -> int:
    if not GODOT_EXE.exists():
        raise AssertionError(f"Godot editor not found: {GODOT_EXE}")

    # —— 夹具：30 组 ×3 脚本 + 1 个全程不动的锚点 ——
    if FIXTURE.exists():
        for child in sorted(FIXTURE.iterdir(), reverse=True):
            if child.is_dir():
                for f in child.iterdir():
                    f.unlink()
                child.rmdir()
            else:
                child.unlink()
    # 30 个常规集 + 2 个中断/冲突段专用集（set_30/set_31）。
    for set_index in range(CHANGE_SETS + 2):
        for file_index in range(FILES_PER_SET):
            write_file(
                FIXTURE / f"set_{set_index:02d}" / f"file_{file_index}.gd",
                f"extends Node\nvar value_{set_index}_{file_index} := 0\n",
            )
    anchor = FIXTURE / "anchor.gd"
    write_file(anchor, "extends Node\nconst ANCHOR := \"untouched\"\n")
    anchor_hash_before = hashlib.sha256(anchor.read_bytes()).hexdigest()
    if JOURNAL.exists():
        JOURNAL.unlink()

    started = time.time()
    process = start_editor()
    try:
        wait_for_server()
        tool_call("enable_tools", {"tools": ["apply_change_set", "execute_editor_script"], "enabled": True})

        # —— 30 次连续变更单：全部 committed，锚点之外无意外 ——
        for set_index in range(CHANGE_SETS):
            operations = build_operations(set_index)
            result = tool_call("apply_change_set", {
                "intent": f"flow set {set_index}",
                "operations": operations,
                "change_set_id": f"cs_flow_{set_index:02d}",
            })
            if result.get("outcome") != "committed":
                raise AssertionError(f"set {set_index} did not commit: {result}")
        verify_file("res://.tmp_cs_flow/set_29/file_2.gd", "var value_29_2 := 30", "last set committed")

        # —— 真实中断：journal 停在 prepared（第 2/3 个文件之后）——
        interrupt_ops = build_operations(30)
        interrupted = inject_interrupt(30, interrupt_ops, 2, "cs_flow_interrupt")
        if interrupted.get("outcome") != "requires_recovery":
            raise AssertionError(f"interrupt injection did not stop mid-set: {interrupted}")
        verify_file("res://.tmp_cs_flow/set_30/file_0.gd", "var value_30_0 := 31", "file 0 applied before the interrupt")
        verify_file("res://.tmp_cs_flow/set_30/file_2.gd", "var value_30_2 := 0", "file 2 untouched by the interrupt")
        if not JOURNAL.exists():
            raise AssertionError("journal was not persisted for the interrupted set")

        # —— 硬杀编辑器 + 重启：从磁盘 journal 恢复 ——
        stop_editor_hard(process)
        process = start_editor()
        wait_for_server()
        tool_call("enable_tools", {"tools": ["apply_change_set", "execute_editor_script"], "enabled": True})
        resumed = tool_call("apply_change_set", {
            "intent": "interrupted set 30",
            "operations": interrupt_ops,
            "change_set_id": "cs_flow_interrupt",
        })
        if resumed.get("outcome") != "resumed_committed":
            raise AssertionError(f"replay after restart did not resume: {resumed}")
        states = {entry["path"]: entry["state"] for entry in resumed.get("files", [])}
        if states.get("res://.tmp_cs_flow/set_30/file_0.gd") != "already_applied":
            raise AssertionError(f"already-written file must be skipped, not rewritten: {states}")
        verify_file("res://.tmp_cs_flow/set_30/file_1.gd", "var value_30_1 := 31", "resume applied the remainder")
        verify_file("res://.tmp_cs_flow/set_30/file_2.gd", "var value_30_2 := 31", "resume applied the remainder")

        # —— 重复提交同一操作不重复生效 ——
        receipt = tool_call("apply_change_set", {
            "intent": "interrupted set 30",
            "operations": interrupt_ops,
            "change_set_id": "cs_flow_interrupt",
        })
        if receipt.get("outcome") != "receipt":
            raise AssertionError(f"committed replay must be a receipt: {receipt}")
        verify_file("res://.tmp_cs_flow/set_30/file_0.gd", "var value_30_0 := 31", "content stays exactly one application")

        # —— 手工冲突注入：中断后用户改了第 2 个文件 ——
        conflict_ops = build_operations(31)
        conflicted_interrupt = inject_interrupt(31, conflict_ops, 1, "cs_flow_conflict")
        if conflicted_interrupt.get("outcome") != "requires_recovery":
            raise AssertionError(f"conflict-stage interrupt failed: {conflicted_interrupt}")
        manual_path = FIXTURE / "set_31" / "file_1.gd"
        write_file(manual_path, "extends Node\nvar manual_edit := true\n")
        conflict = tool_call("apply_change_set", {
            "intent": "interrupted set 31",
            "operations": conflict_ops,
            "change_set_id": "cs_flow_conflict",
        })
        if conflict.get("outcome") != "conflict":
            raise AssertionError(f"manual edit must stop at an explicit conflict: {conflict}")
        if "res://.tmp_cs_flow/set_31/file_1.gd" not in conflict.get("conflicted_paths", []):
            raise AssertionError(f"conflicted path missing: {conflict}")
        verify_file("res://.tmp_cs_flow/set_31/file_1.gd", "var manual_edit := true", "manual work preserved, never overwritten")
        verify_file("res://.tmp_cs_flow/set_31/file_2.gd", "var value_31_2 := 0", "post-conflict file left untouched")

        # —— 锚点与 journal 证据 ——
        anchor_hash_after = hashlib.sha256(anchor.read_bytes()).hexdigest()
        if anchor_hash_after != anchor_hash_before:
            raise AssertionError("anchor file was modified — unrelated content must survive every flow")
        journal = json.loads(JOURNAL.read_text(encoding="utf-8"))
        phases = [op.get("phase") for op in journal.get("operations", [])]
        if len(phases) < CHANGE_SETS + 2:
            raise AssertionError(f"journal should record every change set: {len(phases)} entries")

        elapsed = time.time() - started
        committed_count = sum(1 for phase in phases if phase == "committed")
        print(f"change-set recovery flow verified: {CHANGE_SETS} consecutive commits, "
              f"hard-kill restart resume, idempotent receipt, manual-edit conflict; "
              f"journal phases: {committed_count} committed; total {elapsed:.1f}s")
        return 0
    finally:
        stop_editor_hard(process)
        if FIXTURE.exists():
            for child in sorted(FIXTURE.iterdir()):
                if child.is_dir():
                    for f in child.iterdir():
                        f.unlink()
                    child.rmdir()
                else:
                    child.unlink()
            FIXTURE.rmdir()
        if JOURNAL.exists():
            JOURNAL.unlink()


if __name__ == "__main__":
    sys.exit(main())
