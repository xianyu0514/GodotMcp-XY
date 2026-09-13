import json, subprocess, time, urllib.request, shutil
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SCRATCH = REPO / "tmp_self_agent_project"
GODOT = r"D:\youxi\kaifa\Godot_v4.7.2-stable_win64_console.exe"
PORT = 9187
EVENTS = Path(__file__).resolve().parent / "runs" / "self_agent_n1.jsonl"

def ev(kind, payload, task="R3"):
    with EVENTS.open("a", encoding="utf-8") as f:
        f.write(json.dumps({"t": time.strftime("%Y-%m-%dT%H:%M:%S"), "run_id": "self_agent_n1",
            "task_id": task, "product": "godot-mcp-native", "model": "GLM-5.3 (first-party)",
            "godot": "4.7.2", "event": kind, "payload": payload}, ensure_ascii=False) + "\n")

def rpc(params, rid=1, timeout=240.0):
    payload = {"jsonrpc":"2.0","method":"tools/call","id":rid,"params":{"name":params[0],"arguments":params[1]}}
    req = urllib.request.Request(f"http://127.0.0.1:{PORT}/mcp", data=json.dumps(payload).encode(), headers={"Content-Type":"application/json"})
    r = json.loads(urllib.request.urlopen(req, timeout=timeout).read())
    res = r.get("result",{})
    if res.get("isError"): raise RuntimeError(res["content"][0]["text"][:200])
    return res.get("structuredContent",{})

def launch():
    p = subprocess.Popen([GODOT, "--editor", "--headless", "--path", str(SCRATCH), "--", "--mcp-server", f"--mcp-port={PORT}"],
                          stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, cwd=str(SCRATCH))
    deadline = time.time() + 120
    while time.time() < deadline:
        try:
            urllib.request.urlopen(urllib.request.Request(f"http://127.0.0.1:{PORT}/mcp",
                data=json.dumps({"jsonrpc":"2.0","method":"tools/list","id":0}).encode(),
                headers={"Content-Type":"application/json"}), timeout=5).read()
            return p
        except Exception:
            time.sleep(1)
    raise RuntimeError("server not up")

def kill_editor(p):
    p.kill()
    time.sleep(2)
    try:
        p.wait(timeout=5)
    except Exception:
        subprocess.run(["taskkill", "/PID", str(p.pid), "/T", "/F"], capture_output=True)

def main():
    if SCRATCH.exists():
        shutil.rmtree(SCRATCH, ignore_errors=True)
    (SCRATCH / "addons").mkdir(parents=True)
    shutil.copytree(REPO / "addons/godot_mcp", SCRATCH / "addons/godot_mcp")
    (SCRATCH / "project.godot").write_text(
        'config_version=5\n\n[application]\n\nconfig/name="R3Bench"\n\n[editor_plugins]\n\n'
        'enabled=PackedStringArray("res://addons/godot_mcp/plugin.cfg")\n', encoding="utf-8", newline="\n")

    GOAL = "Arrow-key movement with a coin and walls that block the player."
    ev("run_started", {"objective": GOAL, "task": "R3 crash-recovery calibration"})
    e1 = launch()
    rpc(("plan_game_workflow", {"action":"plan","objective":GOAL,"profiles":["gameplay_feature"],
                                 "replace":True,"plan_path":"res://.mcp/r3_plan.json"}))
    d = rpc(("run_game_workflow", {"plan_path":"res://.mcp/r3_plan.json","max_steps":6}))
    print("pre-crash:", d.get("state",""), json.dumps(d.get("progress",{})))
    kill_editor(e1)
    print("CRASH simulated (editor killed mid-workflow)")
    ev("tool_result", {"tool": "editor_crash", "ok": True,
                       "note": "hard kill after 6 atomic steps; receipts partially persisted"})

    e2 = launch()
    print("editor restarted on preserved scratch")
    for i in range(8):
        d = rpc(("run_game_workflow", {"plan_path":"res://.mcp/r3_plan.json","max_steps":8}), 100+i)
        state = d.get("state", d.get("status","?"))
        print(f"resume {i}:", state, json.dumps(d.get("progress",{}), ensure_ascii=False)[:80])
        if state in ("completed","needs_input","recovery_required","replan_required"):
            break
        time.sleep(2)

    completed = state == "completed"
    rpc(("enable_tools", {"tools":["play_and_verify"]}, 90))
    # 恢复后行为检查：目标可能带墙（右侧被墙挡），用左移验证位移——
    # oracle 不能假设玩家在原点/无障碍（第一次跑把 move_right 打墙上抓到）。
    o = rpc(("play_and_verify", {"steps":[
        {"action":"move_left","pressed":True,"wait_ms":400,
         "assert":{"expression":"position.x","displacement_max":-10}},
        {"action":"move_left","pressed":False,"wait_ms":80}]}, 91))
    oracle_ok = bool(o.get("passed")) and not o.get("runtime_errors")
    print("oracle:", json.dumps({"passed": o.get("passed"), "errors": bool(o.get("runtime_errors"))}))
    ev("oracle_check", {"check": "post-recovery-behavior", "passed": oracle_ok})
    ev("run_ended", {"outcome": "pass" if (completed and oracle_ok) else "fail",
                     "oracle_passed": oracle_ok, "human_interventions": 0,
                     "note": f"resume state={state}; crash-recovery calibration"})
    kill_editor(e2)
    print(f"R3 RESULT: {'PASS' if (completed and oracle_ok) else 'FAIL'} (state={state})")

if __name__ == "__main__":
    main()
