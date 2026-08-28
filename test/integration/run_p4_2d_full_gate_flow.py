"""Stable runner for the P4 2D Gate Lab.

Godot's EditorFileSystem import pipeline is asynchronous. A source file being
written, or even reimport_files() returning, does not prove ResourceLoader can
consume it. This runner inserts an evidence-based barrier: every generated
source must expose import metadata before 2D consumers may continue.
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


def _metadata_ready(path: str) -> bool:
    result = _original_tool_call("get_import_metadata", {"resource_path": path}, allow_error=True)
    if result.get("_tool_error") or result.get("rpc_error") or result.get("error"):
        return False
    imported = result.get("imported_paths", result.get("imported_files", result.get("dest_files", [])))
    # Some importers expose metadata without an imported-path array. A
    # successful structured response with an importer/source path is still
    # stronger evidence than EditorFileSystem merely reporting idle.
    return bool(imported) or bool(result.get("importer")) or bool(result.get("resource_path"))


def _wait_for_imports(timeout_seconds: float = 30.0) -> None:
    global _import_barrier_done
    if _import_barrier_done:
        return

    sources = sorted(set(_generated_sources))
    _original_tool_call("reload_project", {"full_scan": True})
    if sources:
        _original_tool_call("reimport_resources", {"resource_paths": sources})

    deadline = time.time() + timeout_seconds
    observed_busy = False
    while time.time() < deadline:
        status = _original_tool_call("get_import_status", {})
        scanning = bool(status.get("scanning", False))
        importing = status.get("importing", False)
        if scanning or importing is True:
            observed_busy = True

        ready = [path for path in sources if _metadata_ready(path)]
        if len(ready) == len(sources) and not scanning and importing in (False, None):
            _import_barrier_done = True
            return

        # Re-scan once if the queue looked idle before any actual import work
        # was observed. This closes the race where reimport_files() schedules
        # work after the first idle snapshot.
        if not observed_busy and not scanning and importing in (False, None):
            _original_tool_call("reload_project", {"full_scan": True})
        time.sleep(0.15)

    missing = [path for path in sources if not _metadata_ready(path)]
    raise AssertionError(f"Generated assets never became ResourceLoader-ready: {missing}")


def stable_tool_call(name: str, arguments: dict | None = None, allow_error: bool = False) -> dict:
    global _import_barrier_done
    arguments = arguments or {}
    if name in {"draw_on_texture", "slice_sprite_sheet", "create_tileset"}:
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
