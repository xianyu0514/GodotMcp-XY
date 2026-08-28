"""Final P4 2D gate entrypoint.

Editor signal connections must use CONNECT_PERSIST (flag 4) to survive saving
the generated scene and be present when the game is launched. The lower-level
resilient runner intentionally exercises the same signal tools; this entrypoint
supplies the correct persistence contract without bypassing them.
"""
from __future__ import annotations

import importlib.util
import sys
from pathlib import Path


HERE = Path(__file__).resolve().parent
RUNNER = HERE / "run_p4_2d_full_gate_flow.py"
spec = importlib.util.spec_from_file_location("p4_2d_resilient_runner", RUNNER)
if spec is None or spec.loader is None:
    raise RuntimeError(f"Cannot load {RUNNER}")
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)

_base_tool_call = runner.gate.tool_call


def persistent_signal_tool_call(name: str, arguments: dict | None = None, allow_error: bool = False) -> dict:
    args = dict(arguments or {})
    if name == "connect_signal":
        args.setdefault("flags", 4)
    elif name == "batch_connect_signals":
        connections = []
        for connection in args.get("connections", []):
            item = dict(connection)
            item.setdefault("flags", 4)
            connections.append(item)
        args["connections"] = connections
    return _base_tool_call(name, args, allow_error)


runner.gate.tool_call = persistent_signal_tool_call


if __name__ == "__main__":
    sys.exit(runner.gate.main())
