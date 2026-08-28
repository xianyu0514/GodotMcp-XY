"""Stable runner for the P4 2D Gate Lab.

The editor import pipeline is asynchronous: generate_asset(reimport=true) can
return after the source file is written but before ResourceLoader can see the
imported texture. This runner wraps the gate's tool_call and inserts an
observable import-stability barrier before the first resource consumer.
"""
from __future__ import annotations

import importlib.util
import sys
import time
from pathlib import Path


HERE = Path(__file__).resolve().parent
TARGET = HERE / "test_p4_2d_full_gate_flow.py"
spec = importlib.util.spec_from_file_location("p4_2d_gate_impl", TARGET)
if spec is None or spec.loader is None:
    raise RuntimeError(f"Cannot load {TARGET}")
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)

_original_tool_call = gate.tool_call
_generated_sources: list[str] = []
_import_barrier_done = False


def _wait_for_imports(timeout_seconds: float = 20.0) -> None:
    global _import_barrier_done
    if _import_barrier_done:
        return

    # Force EditorFileSystem to discover newly written source files, then ask
    # the dedicated import tools to reimport them. Neither operation is treated
    # as a sleep-only workaround: get_import_status supplies the evidence that
    # scanning/importing reached a stable state before ResourceLoader consumers
    # are allowed to proceed.
    _original_tool_call("reload_project", {"full_scan": True})
    deadline = time.time() + timeout_seconds
    while time.time() < deadline:
        status = _original_tool_call("get_import_status", {})
        scanning = bool(status.get("scanning", False))
        importing = status.get("importing", False)
        if not scanning and importing in (False, None):
            break
        time.sleep(0.1)
    else:
        raise AssertionError("EditorFileSystem did not become stable after generated assets")

    if _generated_sources:
        _original_tool_call("reimport_resources", {"resource_paths": sorted(set(_generated_sources))})
        deadline = time.time() + timeout_seconds
        while time.time() < deadline:
            status = _original_tool_call("get_import_status", {})
            scanning = bool(status.get("scanning", False))
            importing = status.get("importing", False)
            if not scanning and importing in (False, None):
                _import_barrier_done = True
                return
            time.sleep(0.1)
        raise AssertionError("EditorFileSystem did not become stable after explicit reimport")

    _import_barrier_done = True


def stable_tool_call(name: str, arguments: dict | None = None, allow_error: bool = False) -> dict:
    global _import_barrier_done
    arguments = arguments or {}
    if name in {"draw_on_texture", "slice_sprite_sheet", "create_tileset", "get_import_metadata"}:
        _wait_for_imports()
    result = _original_tool_call(name, arguments, allow_error)
    if name == "generate_asset":
        path = str(arguments.get("resource_path", ""))
        if path and path not in _generated_sources:
            _generated_sources.append(path)
        _import_barrier_done = False
    return result


gate.tool_call = stable_tool_call


if __name__ == "__main__":
    sys.exit(gate.main())
