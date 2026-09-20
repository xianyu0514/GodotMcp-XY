"""Slice B asset preparation — idempotent, test-independent, no save wiping.

Generates the four synthesized audio clips under slice_b/audio/ (the sky
textures are tracked .tres files under slice_b/art/). Safe to run any
number of times: existing clips with the expected size are left alone,
so a player's progress and a dev's tweaks both survive.

Usage:  python slice_b/prepare_assets.py [--check]
        --check  verify only; exit 1 with a report if anything is missing.
"""
import math
import struct
import sys
import wave
from pathlib import Path

AUDIO_DIR = Path(__file__).resolve().parent / "audio"
ART_DIR = Path(__file__).resolve().parent / "art"

# (name, duration_s, frequency_hz, waveform, amplitude)
# 与 test_slice_b_content_flow.py 的占位合成参数一致——同一资产两种入口：
# 日常准备走本脚本（无编辑器依赖），MCP 管线证据走内容流。
CLIPS = [
    ("pickup.wav", 0.25, 880.0, "sine", 0.6),
    ("hit.wav", 0.20, 110.0, "square", 0.6),
    ("door.wav", 0.40, 330.0, "triangle", 0.6),
    ("bgm.wav", 6.00, 165.0, "sine", 0.35),
]
SAMPLE_RATE = 22050

SKY_TEXTURES = ["sky_l1.tres", "sky_l2.tres", "sky_boss.tres"]


def _sample(waveform: str, phase: float) -> float:
    if waveform == "sine":
        return math.sin(2 * math.pi * phase)
    if waveform == "square":
        return 1.0 if phase < 0.5 else -1.0
    if waveform == "triangle":
        return 4.0 * abs(phase - round(phase)) - 1.0 if phase >= 0.5 else 4.0 * phase - 1.0
    raise ValueError(waveform)


def _expected_bytes(duration: float) -> int:
    # PCM16 单声道：采样数 * 2 字节 + wav 头(44)
    return 44 + int(round(duration * SAMPLE_RATE)) * 2


def generate_clip(path: Path, duration: float, frequency: float,
                  waveform: str, amplitude: float) -> None:
    sample_count = max(1, int(round(duration * SAMPLE_RATE)))
    fade = max(1, int(sample_count * 0.1))
    frames = bytearray()
    for i in range(sample_count):
        t = i / SAMPLE_RATE
        value = _sample(waveform, (t * frequency) % 1.0) * amplitude
        edge = min(i, sample_count - 1 - i)
        if edge < fade:
            value *= edge / fade
        frames += struct.pack("<h", int(max(-1.0, min(1.0, value)) * 32767))
    with wave.open(str(path), "wb") as handle:
        handle.setnchannels(1)
        handle.setsampwidth(2)
        handle.setframerate(SAMPLE_RATE)
        handle.writeframes(bytes(frames))


def main() -> int:
    check_only = "--check" in sys.argv
    missing: list[str] = []
    actions: list[str] = []

    AUDIO_DIR.mkdir(parents=True, exist_ok=True)
    for name, duration, frequency, waveform, amplitude in CLIPS:
        path = AUDIO_DIR / name
        if path.exists() and path.stat().st_size == _expected_bytes(duration):
            actions.append(f"ok      audio/{name}")
            continue
        if check_only:
            missing.append(f"audio/{name}")
            actions.append(f"MISSING audio/{name}")
            continue
        generate_clip(path, duration, frequency, waveform, amplitude)
        actions.append(f"wrote   audio/{name} ({path.stat().st_size} bytes)")

    for name in SKY_TEXTURES:
        state = "ok     " if (ART_DIR / name).exists() else "MISSING"
        if state.startswith("MISS"):
            missing.append(f"art/{name}")
        actions.append(f"{state} art/{name} (tracked in git)")

    print("\n".join(actions))
    if missing:
        print(f"\n{len(missing)} asset(s) missing — run: python slice_b/prepare_assets.py")
        return 1
    print("\nslice_b assets ready.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
