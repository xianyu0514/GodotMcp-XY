"""Resilient evidence runner for the P4 2D Gate Lab.

The gate must not stop discovering defects after the first capability gap. It
therefore records generated-asset chainability failures, falls back to a tiny
pre-imported seed texture/audio fixture for downstream 2D tools, completes the
remaining verification matrix, and only then fails the overall gate if the gap
is still unresolved.
"""
from __future__ import annotations

import copy
import importlib.util
import math
import struct
import sys
import time
import wave
import zlib
from pathlib import Path


HERE = Path(__file__).resolve().parent
TARGET = HERE / "test_p4_2d_full_gate_flow.py"
spec = importlib.util.spec_from_file_location("p4_2d_gate_impl", TARGET)
if spec is None or spec.loader is None:
    raise RuntimeError(f"Cannot load {TARGET}")
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)

_original_tool_call = gate.tool_call
_original_prepare_project = gate.prepare_project
_original_coverage_gate = gate.coverage_gate
_generated_sources: list[str] = []
_generated_asset_gaps: list[str] = []
_import_barrier_done = False
_seed_ready = False


def _png_chunk(kind: bytes, data: bytes) -> bytes:
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)


def _write_seed_png(path: Path, width: int = 128, height: int = 64) -> None:
    rows = []
    for y in range(height):
        row = bytearray([0])
        for x in range(width):
            checker = ((x // 16) + (y // 16)) % 2
            if checker:
                row.extend((48, 190, 212, 255))
            else:
                row.extend((30, 53, 82, 255))
        rows.append(bytes(row))
    payload = b"".join(rows)
    png = b"\x89PNG\r\n\x1a\n"
    png += _png_chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
    png += _png_chunk(b"IDAT", zlib.compress(payload, 9))
    png += _png_chunk(b"IEND", b"")
    path.write_bytes(png)


def _write_seed_wav(path: Path) -> None:
    rate = 22050
    frames = int(rate * 0.12)
    with wave.open(str(path), "wb") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(rate)
        data = bytearray()
        for i in range(frames):
            sample = int(12000 * math.sin(2.0 * math.pi * 660.0 * i / rate))
            data.extend(struct.pack("<h", sample))
        wav.writeframes(bytes(data))


def prepare_project_with_seed(project_dir: Path) -> None:
    _original_prepare_project(project_dir)
    _write_seed_png(project_dir / "seed.png")
    _write_seed_wav(project_dir / "seed.wav")


gate.prepare_project = prepare_project_with_seed


def _metadata_ready(path: str) -> bool:
    result = _original_tool_call("get_import_metadata", {"resource_path": path}, allow_error=True)
    return not (result.get("_tool_error") or result.get("rpc_error") or result.get("error"))


def _ensure_seed_ready(timeout_seconds: float = 15.0) -> None:
    global _seed_ready
    if _seed_ready:
        return
    seeds = ["res://seed.png", "res://seed.wav"]
    _original_tool_call("reload_project", {"full_scan": True})
    _original_tool_call("reimport_resources", {"resource_paths": seeds})
    deadline = time.time() + timeout_seconds
    while time.time() < deadline:
        if all(_metadata_ready(path) for path in seeds):
            _seed_ready = True
            return
        time.sleep(0.15)
    raise AssertionError("Seed fixture resources did not become import-ready")


def _wait_for_generated_imports(timeout_seconds: float = 8.0) -> bool:
    global _import_barrier_done
    if _import_barrier_done:
        return not _generated_asset_gaps
    sources = sorted(set(_generated_sources))
    if not sources:
        _import_barrier_done = True
        return True

    _original_tool_call("reload_project", {"full_scan": True})
    _original_tool_call("reimport_resources", {"resource_paths": sources})
    deadline = time.time() + timeout_seconds
    while time.time() < deadline:
        status = _original_tool_call("get_import_status", {})
        ready = [path for path in sources if _metadata_ready(path)]
        if len(ready) == len(sources) and not bool(status.get("scanning", False)) and status.get("importing", False) in (False, None):
            _import_barrier_done = True
            return True
        time.sleep(0.15)

    missing = [path for path in sources if not _metadata_ready(path)]
    for path in missing:
        gap = f"generated_asset_not_chainable:{path}"
        if gap not in _generated_asset_gaps:
            _generated_asset_gaps.append(gap)
    _import_barrier_done = True
    _ensure_seed_ready()
    return False


def _fallback_path(path: str) -> str:
    if path not in _generated_sources:
        return path
    if path.lower().endswith(".wav"):
        return "res://seed.wav"
    return "res://seed.png"


def stable_tool_call(name: str, arguments: dict | None = None, allow_error: bool = False) -> dict:
    global _import_barrier_done
    args = copy.deepcopy(arguments or {})

    if name in {"draw_on_texture", "slice_sprite_sheet", "create_tileset"}:
        generated_ready = _wait_for_generated_imports()
        if not generated_ready:
            if name == "draw_on_texture":
                for operation in args.get("operations", []):
                    operation["source_path"] = _fallback_path(str(operation.get("source_path", "")))
            else:
                args["texture_path"] = _fallback_path(str(args.get("texture_path", "")))

    if name == "batch_update_node_properties" and _generated_asset_gaps:
        _ensure_seed_ready()
        for change in args.get("changes", []):
            value = change.get("property_value")
            if isinstance(value, str) and value in _generated_sources:
                change["property_value"] = _fallback_path(value)

    if name == "get_import_metadata" and str(args.get("resource_path", "")) in _generated_sources and _generated_asset_gaps:
        return _original_tool_call(name, args, allow_error=True)

    result = _original_tool_call(name, args, allow_error)
    if name == "generate_asset":
        path = str(args.get("resource_path", ""))
        if path and path not in _generated_sources:
            _generated_sources.append(path)
        _import_barrier_done = False
    return result


def coverage_gate_with_capability_gaps(report: dict) -> None:
    _original_coverage_gate(report)
    report["capability_gaps"] = list(_generated_asset_gaps)
    if _generated_asset_gaps:
        raise AssertionError("Unresolved capability gaps after full matrix: " + ", ".join(_generated_asset_gaps))


gate.tool_call = stable_tool_call
gate.coverage_gate = coverage_gate_with_capability_gaps


if __name__ == "__main__":
    sys.exit(gate.main())
