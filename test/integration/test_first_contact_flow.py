"""First-contact smoke: exactly what a fresh AI client experiences on connect.

Launches a headless Godot editor with the MCP server on this project, then
walks the real first-contact sequence over HTTP JSON-RPC and asserts the
answers an AI needs before it can do any work:

  initialize           -> protocol answer + accurate instructions (238-tool truth)
  tools/list           -> small core+meta surface (lazy loading by design)
  get_project_info     -> correct project identity (the G0 target check)
  get_editor_state     -> editor state readable
  list_tool_catalog    -> full catalog summary
  enable_tools         -> workflow_query one-call routing (+ suggested_prompt)
  disabled tool call   -> self-healing error embeds the exact enable call
  unknown tool call    -> self-healing error points at discovery paths
  search_tools         -> discovery by keyword
  read/validate script -> a real read with content_hash + clean validation
  prompts/list+get     -> 10 recipes incl. make_game_change, rendered with args

Exit code 0 = the first-contact contract holds against a live editor.

Usage:
  GODOT_EXE=... MCP_PORT=9187 python test/integration/test_first_contact_flow.py
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
GODOT_EXE = Path(os.environ.get("GODOT_EXE", r"C:\kaifa\Godot_v4.6.3-stable_win64_console.exe"))
MCP_PORT = os.environ.get("MCP_PORT", "9187")
MCP_URL = f"http://127.0.0.1:{MCP_PORT}/mcp"

_request_id = 0


def rpc_call(method: str, params: dict | None = None) -> dict:
    global _request_id
    _request_id += 1
    payload = {"jsonrpc": "2.0", "id": _request_id, "method": method}
    if params is not None:
        payload["params"] = params
    request = urllib.request.Request(
        MCP_URL,
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.loads(response.read().decode("utf-8"))


def tool_text(response: dict) -> str:
    result = response.get("result", {})
    content = result.get("content", [])
    if not content:
        return ""
    return str(content[0].get("text", ""))


def tool_payload(response: dict) -> dict:
    text = tool_text(response)
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        raise AssertionError(f"tool result is not JSON: {text[:300]}")


def wait_for_server(timeout_seconds: float = 120.0) -> None:
    deadline = time.time() + timeout_seconds
    last_error: Exception | None = None
    while time.time() < deadline:
        try:
            response = rpc_call("tools/list")
            if "result" in response:
                return
            last_error = AssertionError(f"unexpected tools/list response: {response}")
        except Exception as exc:  # noqa: BLE001 - poll until the editor is up
            last_error = exc
        time.sleep(1.0)
    raise AssertionError(f"MCP server did not answer on {MCP_URL}: {last_error}")


def check(label: str, condition: bool, detail: str = "") -> None:
    if not condition:
        raise AssertionError(f"[FAIL] {label}" + (f" — {detail}" if detail else ""))
    print(f"[ok] {label}")


def main() -> int:
    if not GODOT_EXE.exists():
        print(f"GODOT_EXE not found: {GODOT_EXE}", file=sys.stderr)
        return 2
    args = [
        str(GODOT_EXE), "--editor", "--headless", "--path", str(REPO_ROOT),
        "--", "--mcp-server", f"--mcp-port={MCP_PORT}",
    ]
    process = subprocess.Popen(
        args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, cwd=str(REPO_ROOT)
    )
    try:
        wait_for_server()
        print(f"server up on {MCP_URL}")

        # 1) initialize — protocol + first paragraph the client reads.
        init = rpc_call("initialize", {"protocolVersion": "2025-11-25", "capabilities": {}})
        check("initialize answers", "result" in init)
        instructions = str(init.get("result", {}).get("instructions", ""))
        check("instructions present", len(instructions) > 0)
        check("instructions cite 238-tool truth", "238-tool catalog" in instructions, instructions[:120])

        # 1b) Hermetic baseline: sequential tests on one runner share user://,
        #     so previously-enabled supplementary tools leak in. Reset to the
        #     minimal preset before asserting lazy-surface defaults.
        rpc_call("tools/call", {"name": "enable_tools", "arguments": {"preset": "minimal_core"}})

        # 2) tools/list — lazy surface: meta tools on, supplementary absent.
        tools = rpc_call("tools/list").get("result", {}).get("tools", [])
        names = {t["name"] for t in tools}
        check("tools/list is non-empty", len(names) > 0, f"{len(names)} tools")
        for meta_tool in ("list_tool_catalog", "search_tools", "get_tool_details", "enable_tools"):
            check(f"meta tool {meta_tool} visible", meta_tool in names)
        check("supplementary batch_read_scripts hidden by default", "batch_read_scripts" not in names)

        # 3/4) project identity + editor state — the G0 read-only probes.
        info = tool_payload(rpc_call("tools/call", {"name": "get_project_info", "arguments": {}}))
        check("project info has name", bool(info.get("project_name") or info.get("name")), str(info)[:200])
        check("project info has godot version", "godot_version" in json.dumps(info), str(info)[:200])
        state = tool_payload(rpc_call("tools/call", {"name": "get_editor_state", "arguments": {}}))
        check("editor state readable", "editor_mode" in state, str(state)[:200])

        # 5) catalog summary.
        catalog = tool_payload(rpc_call("tools/call", {
            "name": "list_tool_catalog", "arguments": {"summary_only": True}}))
        check("catalog reports revision + groups",
              "catalog_revision" in catalog and "groups" in catalog, str(catalog)[:200])

        # 6) self-healing errors, live against the real dispatch.
        disabled = rpc_call("tools/call", {"name": "batch_read_scripts", "arguments": {"script_paths": []}})
        disabled_text = tool_text(disabled)
        check("disabled error is isError", bool(disabled.get("result", {}).get("isError")))
        check("disabled error embeds exact enable call",
              "enable_tools" in disabled_text and '"batch_read_scripts"' in disabled_text,
              disabled_text[:200])
        unknown = rpc_call("tools/call", {"name": "definitely_not_a_tool", "arguments": {}})
        unknown_text = tool_text(unknown)
        check("unknown error points at discovery",
              "search_tools" in unknown_text and "prompts/get" in unknown_text, unknown_text[:200])

        # 7) one-call goal routing.
        enable = tool_payload(rpc_call("tools/call", {
            "name": "enable_tools",
            "arguments": {"workflow_query": "做一次跨文件变更单并验证脚本"}}))
        check("workflow_query routed successfully",
              enable.get("status") == "success" and len(enable.get("changed_tools", [])) >= 1,
              json.dumps(enable)[:300])
        # Membership via tools/list is state-independent (changed_tools is a
        # diff against whatever was enabled before, which prior tests pollute).
        enabled_names = {t["name"] for t in
                         rpc_call("tools/list").get("result", {}).get("tools", [])}
        check("chinese change-set query routes apply_change_set",
              "apply_change_set" in enabled_names, str(sorted(enabled_names))[:200])
        check("workflow_query suggested make_game_change",
              str(enable.get("suggested_prompt", {}).get("name", "")) == "make_game_change",
              json.dumps(enable.get("suggested_prompt", {})))

        # 7b) unknown-argument self-correction: a near-miss parameter must be
        #     named in _schema_warnings with the real property list, live.
        near_miss = rpc_call("tools/call", {
            "name": "search_tools",
            "arguments": {"query": "change set", "keyword": "change set"}})
        near_miss_text = tool_text(near_miss)
        check("unknown argument surfaces _schema_warnings",
              "_schema_warnings" in near_miss_text and "keyword" in near_miss_text,
              near_miss_text[:250])

        # 8) discovery by keyword.
        search = tool_payload(rpc_call("tools/call", {
            "name": "search_tools", "arguments": {"query": "change set"}}))
        search_names = {t.get("name", "") for t in search.get("tools", [])} if isinstance(search.get("tools"), list) else set(json.dumps(search).split())
        check("search_tools finds apply_change_set", "apply_change_set" in search_names,
              json.dumps(search)[:300])

        # 9) a real read + validation round-trip on this repo.
        #    validate_script is supplementary and not routed by the query above;
        #    the disabled error embeds the exact enable call — follow it, then retry.
        probe_script = "res://addons/godot_mcp/native_mcp/prompt_workflows.gd"
        read = tool_payload(rpc_call("tools/call", {
            "name": "read_script", "arguments": {"script_path": probe_script}}))
        check("read_script returns content hash", bool(read.get("content_hash")), str(read)[:200])
        first_validate = rpc_call("tools/call", {
            "name": "validate_script", "arguments": {"script_path": probe_script}})
        if first_validate.get("result", {}).get("isError"):
            tool_payload(rpc_call("tools/call", {
                "name": "enable_tools", "arguments": {"tools": ["validate_script"]}}))
        validate = tool_payload(rpc_call("tools/call", {
            "name": "validate_script", "arguments": {"script_path": probe_script}}))
        check("validate_script clean after self-healing enable",
              validate.get("valid") is True and validate.get("error_count") == 0,
              json.dumps(validate)[:300])

        # 10) prompts: catalog + the unified change recipe.
        prompts = rpc_call("prompts/list").get("result", {}).get("prompts", [])
        prompt_names = {p["name"] for p in prompts}
        check("12 recipes registered", len(prompts) == 12, f"{len(prompts)}: {sorted(prompt_names)}")
        check("make_game_change listed", "make_game_change" in prompt_names)
        recipe = rpc_call("prompts/get", {
            "name": "make_game_change",
            "arguments": {"change": "smoke", "acceptance": "none"}}).get("result", {})
        recipe_text = str(recipe.get("messages", [{}])[0].get("content", {}).get("text", ""))
        check("make_game_change renders with real tools",
              "apply_change_set" in recipe_text and "gather_task_context" in recipe_text,
              recipe_text[:200])
        bad_get = rpc_call("prompts/get", {"name": "make_game_change", "arguments": {}})
        check("prompts/get enforces required args", "error" in bad_get, json.dumps(bad_get)[:200])

        print("\nFIRST-CONTACT SMOKE: ALL CHECKS PASSED")
        return 0
    finally:
        process.terminate()
        try:
            process.wait(timeout=15)
        except subprocess.TimeoutExpired:
            process.kill()


if __name__ == "__main__":
    sys.exit(main())
