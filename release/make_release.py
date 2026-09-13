#!/usr/bin/env python3
"""Precise release packaging + install verification (roadmap P5).

Build: packages ONLY the plugin tree (addons/godot_mcp/**, .gd/.json/.cfg/.csv
and friends — no .uid churn, no test/config/user files) with a manifest
carrying version, source commit, file list and sha256 hashes.

Verify: unpacks the archive into a scratch Godot project, runs the headless
import gate (project imports cleanly, no script parse errors), and checks
every manifest hash — the install path, not the dev tree, is what gets
verified.

Usage:
    python release/make_release.py build [--out releases/godot-mcp-native-<ver>.zip]
    python release/make_release.py verify <archive.zip> [--godot path/to/godot]
"""

import argparse
import hashlib
import json
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
PLUGIN_ROOT = REPO / "addons" / "godot_mcp"
PLUGIN_CFG = PLUGIN_ROOT / "plugin.cfg"

# Packaged file extensions (text assets the plugin ships).
INCLUDE_SUFFIXES = {".gd", ".json", ".cfg", ".csv", ".md", ".txt", ".svg", ".png", ".ttf", ".otf", ".wav", ".ogg"}
INCLUDE_NAMES = {"plugin.cfg", ".gitignore", "README.md", "README.zh.md"}


def plugin_version() -> str:
    for line in PLUGIN_CFG.read_text(encoding="utf-8").splitlines():
        if line.startswith("version="):
            return line.split("=", 1)[1].strip().strip('"').strip("'")
    return "unknown"


def source_commit() -> str:
    result = subprocess.run(["git", "rev-parse", "HEAD"], cwd=REPO,
                            capture_output=True, text=True, timeout=30)
    return result.stdout.strip() if result.returncode == 0 else "unknown"


def collect_files() -> list[Path]:
    files: list[Path] = []
    for path in sorted(PLUGIN_ROOT.rglob("*")):
        if not path.is_file():
            continue
        if path.suffix.lower() in INCLUDE_SUFFIXES or path.name in INCLUDE_NAMES:
            files.append(path)
    return files


def sha256_of(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def build(out: Path) -> int:
    files = collect_files()
    if not files:
        print("ERROR: no files collected", file=sys.stderr)
        return 1
    out.parent.mkdir(parents=True, exist_ok=True)
    manifest = {
        "name": "godot-mcp-native",
        "version": plugin_version(),
        "source_commit": source_commit(),
        "file_count": len(files),
        "files": {},
    }
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as zf:
        for path in files:
            arcname = path.relative_to(REPO).as_posix()
            zf.write(path, arcname)
            manifest["files"][arcname] = sha256_of(path)
        zf.writestr("release-manifest.json", json.dumps(manifest, indent=2))
    print(f"[release] built {out} — {len(files)} files, "
          f"version {manifest['version']}, commit {manifest['source_commit'][:12]}")
    return 0


def verify(archive: Path, godot: str) -> int:
    with tempfile.TemporaryDirectory(prefix="mcp_release_verify_") as tmp:
        scratch = Path(tmp) / "project"
        (scratch / "addons").mkdir(parents=True)
        with zipfile.ZipFile(archive) as zf:
            zf.extractall(scratch)
        # 1) manifest hash integrity of every packaged file
        manifest = json.loads((scratch / "release-manifest.json").read_text(encoding="utf-8"))
        mismatches = []
        for arcname, expected in manifest["files"].items():
            target = scratch / arcname
            if not target.exists():
                mismatches.append(f"missing: {arcname}")
            elif sha256_of(target) != expected:
                mismatches.append(f"hash mismatch: {arcname}")
        if mismatches:
            print(f"ERROR: {len(mismatches)} integrity failures: {mismatches[:5]}", file=sys.stderr)
            return 1
        # 2) install-shape check: plugin.cfg present at the expected path
        if not (scratch / "addons/godot_mcp/plugin.cfg").exists():
            print("ERROR: installed tree lacks addons/godot_mcp/plugin.cfg", file=sys.stderr)
            return 1
        # 3) headless import gate on the scratch project (the L0 gate)
        (scratch / "project.godot").write_text(
            'config_version=5\n\n[application]\n\nconfig/name="ReleaseVerify"\n\n'
            '[editor_plugins]\n\nenabled=PackedStringArray("res://addons/godot_mcp/plugin.cfg")\n',
            encoding="utf-8", newline="\n")
        # --import：跑完资源导入并退出（--editor --quit 会在导入完成前退出）
        result = subprocess.run(
            [godot, "--headless", "--path", str(scratch), "--import"],
            capture_output=True, text=True, timeout=600, cwd=str(scratch))
        stderr = result.stderr + result.stdout
        fatal = [line for line in stderr.splitlines()
                 if "SCRIPT ERROR" in line or "Parse Error" in line]
        if result.returncode != 0 or fatal:
            print(f"ERROR: import gate failed (code {result.returncode}): {fatal[:5]}", file=sys.stderr)
            return 1
        print(f"[release] verified {archive.name}: {manifest['file_count']} files intact, "
              f"install shape ok, headless import clean")
        return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="cmd", required=True)
    build_p = sub.add_parser("build")
    build_p.add_argument("--out", type=Path,
                         default=REPO / "releases" / f"godot-mcp-native-{plugin_version()}.zip")
    verify_p = sub.add_parser("verify")
    verify_p.add_argument("archive", type=Path)
    verify_p.add_argument("--godot", default=r"D:\youxi\kaifa\Godot_v4.7.2-stable_win64.exe")
    args = parser.parse_args()
    if args.cmd == "build":
        return build(args.out)
    return verify(args.archive, args.godot)


if __name__ == "__main__":
    sys.exit(main())
