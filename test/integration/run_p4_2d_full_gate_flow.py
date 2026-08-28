"""Resilient evidence runner for the P4 2D Gate Lab.

The gate keeps exploring after a capability failure, but never hides it. A
minimal startup seed PNG/WAV lets downstream 2D tools continue when a generated
asset cannot be consumed. Nested-file writers that fail on missing parent
directories are also recorded as capability gaps and retried at res:// root so
one defect cannot hide the rest of the end-to-end matrix.
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
_capability_gaps: list[str] = []
_path_aliases: dict[str, str] = {}
_import_attempted = False
_seed_ready = False

_NESTED_WRITERS = {
    "create_resource": "resource_path",
    "create_theme": "theme_path",
    "create_script": "script_path",
    "create_scene": "scene_path",
    "create_animation": "animation_path",
    "save_branch_as_scene": "scene_path",
}


def _png_chunk(kind: bytes, data: bytes) -> bytes:
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)


def _write_seed_png(path: Path, width: int = 128, height: int = 64) -> None:
    rows = []
    for y in range(height):
        row = bytearray([0])
        for x in range(width):
            checker = ((x // 16) + (y // 16)) % 2
            row.extend((48, 190, 212, 255) if checker else (30, 53, 82, 255))
        rows.append(bytes(row))
    raw = b"".join(rows)
    png = b"\x89PNG\r\n\x1a\n"
    png += _png_chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
    png += _png_chunk(b"IDAT", zlib.compress(raw, 9))
    png += _png_chunk(b"IEND", b"")
    path.write_bytes(png)


def _write_seed_wav(path: Path) -> None:
    rate = 22050
    with wave.open(str(path), "wb") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(rate)
        frames = bytearray()
        for i in range(int(rate * 0.12)):
            frames.extend(struct.pack("<h", int(12000 * math.sin(2.0 * math.pi * 660.0 * i / rate))))
        wav.writeframes(bytes(frames))


def prepare_project_with_seed(project_dir: Path) -> None:
    _original_prepare_project(project_dir)
    _write_seed_png(project_dir / "seed.png")
    _write_seed_wav(project_dir / "seed.wav")


gate.prepare_project = prepare_project_with_seed


def _metadata_ready(path: str) -> bool:
    result = _original_tool_call("get_import_metadata", {"resource_path": path}, allow_error=True)
    return not (result.get("_tool_error") or result.get("rpc_error") or result.get("error"))


def _attempt_generated_import() -> None:
    global _import_attempted
    if _import_attempted or not _generated_sources:
        return
    _original_tool_call("reload_project", {"full_scan": True})
    _original_tool_call("reimport_resources", {"resource_paths": sorted(set(_generated_sources))})
    deadline = time.time() + 3.0
    while time.time() < deadline:
        _original_tool_call("get_import_status", {})
        for path in _generated_sources:
            _metadata_ready(path)
        time.sleep(0.1)
    _import_attempted = True


def _ensure_seed_ready(timeout_seconds: float = 12.0) -> None:
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
        time.sleep(0.1)
    raise AssertionError("Seed fixture resources did not become import-ready")


def _record_gap(name: str, error: Exception | str) -> None:
    gap = f"{name}:{str(error)}"
    if gap not in _capability_gaps:
        _capability_gaps.append(gap)


def _fallback_path(path: str) -> str:
    if path.lower().endswith(".wav"):
        return "res://seed.wav"
    return "res://seed.png"


def _apply_aliases(value):
    if isinstance(value, str):
        return _path_aliases.get(value, value)
    if isinstance(value, list):
        return [_apply_aliases(v) for v in value]
    if isinstance(value, dict):
        return {k: _apply_aliases(v) for k, v in value.items()}
    return value


def _replace_generated_inputs(name: str, args: dict) -> dict:
    fallback = copy.deepcopy(args)
    if name == "draw_on_texture":
        for operation in fallback.get("operations", []):
            path = str(operation.get("source_path", ""))
            if path in _generated_sources:
                operation["source_path"] = _fallback_path(path)
    elif name in {"slice_sprite_sheet", "create_tileset"}:
        path = str(fallback.get("texture_path", ""))
        if path in _generated_sources:
            fallback["texture_path"] = _fallback_path(path)
    elif name == "batch_update_node_properties":
        for change in fallback.get("changes", []):
            value = change.get("property_value")
            if isinstance(value, str) and value in _generated_sources:
                change["property_value"] = _fallback_path(value)
    return fallback


def _has_generated_input(name: str, args: dict) -> bool:
    if name == "draw_on_texture":
        return any(str(op.get("source_path", "")) in _generated_sources for op in args.get("operations", []))
    if name in {"slice_sprite_sheet", "create_tileset"}:
        return str(args.get("texture_path", "")) in _generated_sources
    if name == "batch_update_node_properties":
        return any(isinstance(c.get("property_value"), str) and c.get("property_value") in _generated_sources
                   for c in args.get("changes", []))
    return False


def _root_retry_path(original: str) -> str:
    name = original.rsplit("/", 1)[-1]
    return "res://" + name


def stable_tool_call(name: str, arguments: dict | None = None, allow_error: bool = False) -> dict:
    global _import_attempted
    raw_args = copy.deepcopy(arguments or {})
    args = _apply_aliases(raw_args)

    if name == "generate_asset":
        result = _original_tool_call(name, args, allow_error)
        path = str(args.get("resource_path", ""))
        if path and path not in _generated_sources:
            _generated_sources.append(path)
        _import_attempted = False
        return result

    if name in {"draw_on_texture", "slice_sprite_sheet", "create_tileset"} and _has_generated_input(name, args):
        _attempt_generated_import()
        try:
            return _original_tool_call(name, args, allow_error)
        except AssertionError as exc:
            _record_gap("generated_asset_not_chainable", exc)
            _ensure_seed_ready()
            return _original_tool_call(name, _replace_generated_inputs(name, args), allow_error)

    if name == "batch_update_node_properties" and _has_generated_input(name, args):
        if _capability_gaps:
            _ensure_seed_ready()
            return _original_tool_call(name, _replace_generated_inputs(name, args), allow_error)
        try:
            return _original_tool_call(name, args, allow_error)
        except AssertionError as exc:
            _record_gap("generated_asset_property_binding", exc)
            _ensure_seed_ready()
            return _original_tool_call(name, _replace_generated_inputs(name, args), allow_error)

    if name == "get_import_metadata" and str(args.get("resource_path", "")) in _generated_sources and _capability_gaps:
        return _original_tool_call(name, args, allow_error=True)

    if name in _NESTED_WRITERS:
        path_key = _NESTED_WRITERS[name]
        original_path = str(raw_args.get(path_key, ""))
        effective_path = str(args.get(path_key, ""))
        try:
            return _original_tool_call(name, args, allow_error)
        except AssertionError as exc:
            if not effective_path.startswith("res://") or "/" not in effective_path[len("res://"):]:
                raise
            _record_gap(f"{name}_missing_parent_directory", exc)
            retry = copy.deepcopy(args)
            retry_path = _root_retry_path(effective_path)
            retry[path_key] = retry_path
            result = _original_tool_call(name, retry, allow_error)
            _path_aliases[original_path] = retry_path
            _path_aliases[effective_path] = retry_path
            return result

    return _original_tool_call(name, args, allow_error)


def coverage_gate_with_capability_gaps(report: dict) -> None:
    _original_coverage_gate(report)
    report["capability_gaps"] = list(_capability_gaps)
    report["path_aliases"] = dict(_path_aliases)
    if _capability_gaps:
        raise AssertionError("Unresolved capability gaps after full matrix: " + " | ".join(_capability_gaps))


gate.tool_call = stable_tool_call
gate.coverage_gate = coverage_gate_with_capability_gaps


if __name__ == "__main__":
    sys.exit(gate.main())
