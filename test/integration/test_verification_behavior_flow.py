"""F1 native behavioral acceptance — live integration.

Builds a minimal arena (first-playable machinery), then drives the
verification queue's behavior_check executor against a REAL editor and
running game:

  1. A behavior_check with movement + wall assertions must PASS with
     native_run evidence: real observed values, a session id, executed
     steps, zero runtime errors.
  2. Fault injection: an impossible assertion must FAIL — proving the
     executor observes the game instead of rubber-stamping.
  3. Strict mode: externally recorded verdicts are rejected live.
  4. Evidence drift: after the watched script changes, inspect re-opens
     the passed item.

Usage:
  GODOT_EXE=... MCP_PORT=9194 python test/integration/test_verification_behavior_flow.py
"""

import importlib.util
import json
import os
import subprocess
import sys
import time
from pathlib import Path

fp_spec = importlib.util.spec_from_file_location(
    "fp", Path(__file__).parent / "test_first_playable_flow.py")
fp = importlib.util.module_from_spec(fp_spec)
sys.modules["fp"] = fp
fp_spec.loader.exec_module(fp)

MCP_PORT = os.environ.get("MCP_PORT", "9194")

QUEUE_TOOLS = ["run_verification_queue", "apply_change_set", "read_script",
               "enable_tools", "get_project_info"]


def check(label, condition, detail=""):
    if not condition:
        raise AssertionError(f"[FAIL] {label}" + (f" — {detail}" if detail else ""))
    print(f"[ok] {label}", flush=True)


def main() -> int:
    fp.build_scratch_project()
    proc = fp.boot_editor()
    try:
        fp.MCP_URL = f"http://127.0.0.1:{MCP_PORT}/mcp"
        fp.wait_for_server()
        fp.tool_call("enable_tools", {"tools": fp.ATOMIC_TOOLS + QUEUE_TOOLS})

        # Reuse the first-playable build (inputs, arena, script, main scene).
        fp.tool_call("upsert_project_input_action", {
            "action_name": "move_left", "erase_existing": True,
            "events": [{"type": "key", "physical_keycode": 65}]})
        fp.tool_call("upsert_project_input_action", {
            "action_name": "move_right", "erase_existing": True,
            "events": [{"type": "key", "physical_keycode": 68}]})
        fp.tool_call("create_scene", {"scene_path": fp.SCENE, "root_node_type": "Node2D"})
        fp.tool_call("open_scene", {"scene_path": fp.SCENE, "allow_ui_focus": True})
        for parent, ntype, nname in [
            ("", "CharacterBody2D", "Player"), ("Player", "CollisionShape2D", "Shape"),
            ("", "StaticBody2D", "WallRight"), ("WallRight", "CollisionShape2D", "Shape")]:
            fp.tool_call("create_node", {"parent_path": parent, "node_type": ntype, "node_name": nname})
        fp.tool_call("set_node_subresource", {"node_path": "Player/Shape", "property_name": "shape",
            "resource_type": "RectangleShape2D", "properties": {"size": [32, 32]}})
        fp.tool_call("set_node_subresource", {"node_path": "WallRight/Shape", "property_name": "shape",
            "resource_type": "RectangleShape2D", "properties": {"size": [32, 576]}})
        fp.tool_call("batch_scene_node_edits", {"operations": [
            {"type": "set_property", "node_path": "Player", "property_name": "position", "property_value": [320, 288]},
            {"type": "set_property", "node_path": "WallRight", "property_name": "position", "property_value": [576, 288]}]})
        created = fp.tool_call("create_script", {
            "script_path": fp.SCRIPT, "content": fp.PLAYER_SCRIPT, "attach_to_node": "Player"})
        assert not created.get("has_errors", False), created
        fp.tool_call("save_scene", {"scene_path": fp.SCENE})
        fp.tool_call("set_project_setting", {
            "setting": "application/run/main_scene", "value": fp.SCENE, "persist": True})
        print("[ok] arena built for acceptance")

        # --- 1) native behavior_check passes with bound evidence ---
        result = fp.tool_call("run_verification_queue", {
            "command": "create", "goal": "movement and wall behavior preserved",
            "items": [{"kind": "behavior_check", "label": "move + wall",
                "detail": {"scene_path": fp.SCENE, "steps": [
                    {"action": "move_right", "pressed": True, "wait_ms": 1500,
                     "assert": {"expression": "get_node('Player').position.x", "expected": 544,
                                "operator": "lte", "description": "wall blocks at inner face"}},
                    {"action": "move_right", "pressed": False, "wait_ms": 100},
                ]}}],
            "watch_paths": [fp.SCRIPT], "strict": True})
        check("queue completes via native run",
              result.get("outcome") == "completed" and result.get("passed_count") == 1,
              json.dumps(result)[:400])
        items = _stored_items(fp, result["queue_id"])
        evidence = items[0].get("evidence", {})
        check("evidence level is native_run",
              evidence.get("evidence_level") == "native_run", str(evidence)[:200])
        check("evidence binds the run session",
              isinstance(evidence.get("session"), dict) and evidence.get("session"), str(evidence.get("session")))
        check("evidence carries executed steps", evidence.get("steps_executed", 0) >= 1)
        check("evidence records the assertion with real values",
              evidence.get("assertions") and evidence["assertions"][0].get("passed") is True
              and "actual" in evidence["assertions"][0],
              json.dumps(evidence.get("assertions", []))[:300])
        check("no runtime errors during the run", evidence.get("runtime_errors") == [])

        # --- 2) fault injection: impossible assertion must fail ---
        faulty = fp.tool_call("run_verification_queue", {
            "command": "create", "goal": "fault injection must be caught",
            "items": [{"kind": "behavior_check", "label": "impossible",
                "detail": {"scene_path": fp.SCENE, "steps": [
                    {"action": "move_right", "pressed": True, "wait_ms": 400,
                     "assert": {"expression": "get_node('Player').position.x", "expected": 99999,
                                "operator": "gte", "description": "impossible distance"}}]}}]})
        check("impossible assertion fails the queue",
              faulty.get("outcome") == "failed" and faulty.get("failed_count") == 1,
              json.dumps(faulty)[:300])
        faulty_evidence = _stored_items(fp, faulty["queue_id"])[0].get("evidence", {})
        check("failure evidence shows the unmet assertion",
              faulty_evidence.get("assertions") and faulty_evidence["assertions"][0].get("passed") is False,
              json.dumps(faulty_evidence.get("assertions", []))[:300])

        # --- 3) strict mode rejects external claims (live) ---
        strict_q = fp.tool_call("run_verification_queue", {
            "command": "create", "goal": "strict gate live",
            "items": [{"kind": "external", "label": "claimed", "detail": {}}],
            "strict": True, "defer_first_slice": True})
        external_id = strict_q["items"][0]["id"]
        rejected = fp.rpc_call("tools/call", {"name": "run_verification_queue", "arguments": {
            "command": "record", "queue_id": strict_q["queue_id"],
            "item_id": external_id, "passed": True, "evidence": {"claim": "trust me"}}})
        rejected = json.loads(rejected["result"]["content"][0]["text"])
        check("strict queue rejects external verdicts live",
              "error" in rejected and "strict" in str(rejected.get("error", "")),
              json.dumps(rejected)[:250])

        # --- 4) evidence drift re-opens a passed item ---
        read = fp.tool_call("read_script", {"script_path": fp.SCRIPT})
        fp.tool_call("apply_change_set", {
            "intent": "drift the watched script to invalidate evidence",
            "operations": [{"path": fp.SCRIPT,
                "expected_content_hash": read["content_hash"],
                "edits": [{"old_text": "const SPEED := 200.0",
                           "new_text": "const SPEED := 210.0"}]}],
            "change_set_id": "vq-drift-probe", "dry_run": False})
        stale = fp.tool_call("run_verification_queue", {
            "command": "inspect", "queue_id": result["queue_id"]})
        check("watched-script drift re-opens the passed item",
              stale.get("stale_refreshed", 0) >= 1
              and any(i.get("status") == "pending" for i in stale.get("items", [])),
              json.dumps(stale)[:300])

        print("\nNATIVE BEHAVIORAL ACCEPTANCE: ALL CHECKS PASSED")
        return 0
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=15)
        except subprocess.TimeoutExpired:
            proc.kill()
        import shutil
        if sys.exc_info()[0] is None:
            shutil.rmtree(fp.SCRATCH, ignore_errors=True)
        else:
            print(f"[diag] scratch kept at {fp.SCRATCH}", flush=True)


def _stored_items(fp, queue_id):
    store_path = fp.SCRATCH / ".mcp" / "verification_queues.json"
    parsed = json.loads(store_path.read_text(encoding="utf-8"))
    for queue in parsed.get("queues", []):
        if queue.get("queue_id") == queue_id:
            return queue.get("items", [])
    raise AssertionError(f"queue {queue_id} not found in store")


if __name__ == "__main__":
    sys.exit(main())
