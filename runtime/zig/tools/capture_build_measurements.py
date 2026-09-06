"""Measure clean, no-change, and declared source-edit builds in a private snapshot."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Any

import jsonschema

from source_architecture import analyze, canonical_json, load_manifest, sha256_file

ROOT = Path(__file__).resolve().parents[1]
CONFIG_PATH = ROOT / "source-layout.json"
OUTPUT_PATH = ROOT / "reports" / "architecture" / "build-measurements.json"
PROFILE_PATH = ROOT.parents[1] / "config" / "zig-build-measurements.json"
LOG_TAIL_BYTES = 16_384
KIB_BYTES = 1024


def _find_zig(root: Path) -> Path:
    repository_root = root.parents[1]
    workspace_root = root.parents[2]
    candidates = sorted((repository_root / ".tooling").glob("zig-*/zig"))
    candidates.extend(sorted((workspace_root / ".tooling").glob("zig-*/zig")))
    system_zig = shutil.which("zig")
    if system_zig:
        candidates.append(Path(system_zig))
    if not candidates:
        raise RuntimeError("Zig executable not found")
    return candidates[-1].resolve()


def _digest_text(content: str) -> str:
    return hashlib.sha256(content.encode("utf-8")).hexdigest()


def _sanitize(content: str, temporary_root: Path) -> str:
    return content.replace(str(temporary_root), "$MEASUREMENT_ROOT")


def _run_build(command: list[str], root: Path, temporary_root: Path) -> dict[str, Any]:
    if not hasattr(os, "wait4"):
        raise RuntimeError("per-build resource measurement requires POSIX wait4")
    started_ns = time.monotonic_ns()
    with tempfile.TemporaryFile() as stdout_file, tempfile.TemporaryFile() as stderr_file:
        process = subprocess.Popen(command, cwd=root, stdout=stdout_file, stderr=stderr_file)
        _, status, usage = os.wait4(process.pid, 0)
        process.returncode = os.waitstatus_to_exitcode(status)
        elapsed_ns = time.monotonic_ns() - started_ns
        stdout_file.seek(0)
        stderr_file.seek(0)
        stdout = _sanitize(stdout_file.read().decode("utf-8", errors="replace"), temporary_root)
        stderr = _sanitize(stderr_file.read().decode("utf-8", errors="replace"), temporary_root)
    return {
        "elapsedNs": elapsed_ns,
        "exitCode": process.returncode,
        "peakResidentBytes": int(usage.ru_maxrss) * (1 if sys.platform == "darwin" else KIB_BYTES),
        "residentScope": "wait4-largest-process-in-build-tree",
        "userCpuNs": round(usage.ru_utime * 1_000_000_000),
        "systemCpuNs": round(usage.ru_stime * 1_000_000_000),
        "stderr": stderr[-LOG_TAIL_BYTES:],
        "stderrSha256": _digest_text(stderr),
        "stdout": stdout[-LOG_TAIL_BYTES:],
        "stdoutSha256": _digest_text(stdout),
    }


def _artifact_inventory(prefix: Path, temporary_root: Path) -> list[dict[str, Any]]:
    if not prefix.is_dir():
        return []
    return [
        {"path": _sanitize(str(path), temporary_root), "sha256": sha256_file(path),
         "sizeBytes": path.stat().st_size}
        for path in sorted(prefix.rglob("*")) if path.is_file()
    ]


def _relative_path(value: str) -> Path:
    path = Path(value)
    if path.is_absolute() or ".." in path.parts:
        raise ValueError(f"measurement path must stay within its root: {value}")
    return path


def _snapshot(repository: Path, destination: Path, roots: list[str]) -> list[dict[str, str]]:
    selected = [str(_relative_path(root)) for root in roots]
    files = subprocess.run(
        ["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard", "--", *selected],
        cwd=repository, check=True, capture_output=True,
    ).stdout.split(b"\0")
    inputs = []
    for raw in sorted(set(files)):
        if not raw:
            continue
        relative = _relative_path(os.fsdecode(raw))
        source = repository / relative
        if not source.exists():
            continue
        if source.is_symlink():
            raise ValueError(f"build snapshot requires a regular source file: {source}")
        target = destination / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)
        inputs.append({"path": str(relative), "sha256": sha256_file(target)})
    for item in inputs:
        if sha256_file(repository / item["path"]) != item["sha256"]:
            raise RuntimeError(f"source changed while taking snapshot: {item['path']}")
    return inputs


def _apply_edit(root: Path, edit: dict[str, str]) -> tuple[Path, bytes, str]:
    path = root / _relative_path(edit["path"])
    original = path.read_bytes()
    before, after = edit["before"].encode(), edit["after"].encode()
    if before == after or original.count(before) != 1:
        raise ValueError(f"{edit['id']}: expected exactly one changed source fragment in {path}")
    changed = original.replace(before, after, 1)
    path.write_bytes(changed)
    return path, original, hashlib.sha256(changed).hexdigest()


def capture(root: Path, config_path: Path, *, profile_path: Path,
            build_step: str | None = None, optimize: str | None = None) -> tuple[int, dict[str, Any]]:
    """Measure explicit edits without modifying the working tree or sharing its cache."""
    capture_tool_sha256 = sha256_file(Path(__file__))
    profile_bytes = profile_path.read_bytes()
    profile = json.loads(profile_bytes)
    profile_sha256 = hashlib.sha256(profile_bytes).hexdigest()
    schema_path = PROFILE_PATH.with_suffix(".schema.json")
    jsonschema.validate(profile, json.loads(schema_path.read_text(encoding="utf-8")))
    if len({edit["id"] for edit in profile["edits"]}) != len(profile["edits"]):
        raise ValueError("build measurement edit identifiers must be unique")
    build_step = build_step or profile["buildStep"]
    optimize = optimize or profile["optimize"]
    config = load_manifest(config_path)
    before = analyze(root, config)
    if before.manifest_errors or before.unresolved_imports:
        raise RuntimeError("source architecture is not valid before measurement")
    zig = _find_zig(root)
    zig_version = subprocess.run([str(zig), "version"], check=True, capture_output=True, text=True).stdout.strip()
    with tempfile.TemporaryDirectory(prefix="doe-zig-build-measurement-") as temporary:
        temporary_root = Path(temporary)
        snapshot = temporary_root / "repository"
        inputs = _snapshot(root.parents[1], snapshot, profile["snapshotRoots"])
        measured_root = snapshot / root.relative_to(root.parents[1])
        if analyze(measured_root, config).source_tree_sha256 != before.source_tree_sha256:
            raise RuntimeError("snapshot did not retain the complete Zig source tree")
        prefix = temporary_root / "prefix"
        command = [str(zig), "build", build_step, f"-Doptimize={optimize}", "-j1", "--seed", "0",
                   "--summary", "all", "--cache-dir", str(temporary_root / "cache"),
                   "--global-cache-dir", str(temporary_root / "global-cache"), "--prefix", str(prefix)]
        clean = _run_build(command, measured_root, temporary_root)
        if clean["exitCode"] != 0:
            raise RuntimeError(f"clean snapshot build failed: {clean['stderr']}")
        clean["artifacts"] = _artifact_inventory(prefix, temporary_root)
        no_change = _run_build(command, measured_root, temporary_root)
        edits = []
        for edit in profile["edits"]:
            path, original, changed_hash = _apply_edit(measured_root, edit)
            try:
                result = _run_build(command, measured_root, temporary_root)
                result.update({"id": edit["id"], "path": edit["path"],
                               "beforeSha256": hashlib.sha256(original).hexdigest(),
                               "afterSha256": changed_hash,
                               "artifacts": _artifact_inventory(prefix, temporary_root)})
            finally:
                path.write_bytes(original)
            # Each edit starts from the same restored, built baseline.
            result["restoreCompile"] = _run_build(command, measured_root, temporary_root)
            edits.append(result)
            if result["exitCode"] != 0 or result["restoreCompile"]["exitCode"] != 0:
                break
        source_changed = analyze(root, config).source_tree_sha256 != before.source_tree_sha256
        normalized_command = [_sanitize(argument, temporary_root) for argument in command]
    passed = no_change["exitCode"] == 0 and len(edits) == len(profile["edits"]) and all(
        edit["exitCode"] == 0 and edit["restoreCompile"]["exitCode"] == 0 for edit in edits)
    tool_changed = sha256_file(Path(__file__)) != capture_tool_sha256
    payload = {
        "schemaVersion": 3, "status": "captured" if passed and not tool_changed else "failure",
        "measurementClass": "diagnostic-only", "buildStep": build_step, "optimize": optimize,
        "cleanCompile": clean, "noChangeCompile": no_change, "editCompiles": edits,
        "command": normalized_command, "profile": profile, "profileSha256": profile_sha256,
        "sourceTreeSha256": before.source_tree_sha256, "snapshotInputs": inputs,
        "sourceChangedDuringCapture": source_changed,
        "captureToolChangedDuringCapture": tool_changed, "captureToolSha256": capture_tool_sha256,
        "host": {"machine": platform.machine(), "operatingSystem": platform.system(), "release": platform.release()},
        "toolchain": {"path": str(zig), "sha256": sha256_file(zig), "version": zig_version},
    }
    return (0 if payload["status"] == "captured" else 1), payload


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=ROOT, help="runtime/zig root")
    parser.add_argument("--config", type=Path, default=CONFIG_PATH, help="source-layout manifest")
    parser.add_argument("--profile", type=Path, default=PROFILE_PATH, help="declared edit scenarios")
    parser.add_argument("--output", type=Path, default=OUTPUT_PATH, help="measurement receipt path")
    parser.add_argument("--build-step", help="override the profile's Zig build step")
    parser.add_argument("--optimize", choices=["Debug", "ReleaseSafe", "ReleaseFast", "ReleaseSmall"],
                        help="override the profile's Zig optimization mode")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        exit_code, payload = capture(args.root.resolve(), args.config.resolve(), profile_path=args.profile.resolve(),
                                     build_step=args.build_step, optimize=args.optimize)
    except (OSError, RuntimeError, subprocess.SubprocessError, ValueError, jsonschema.ValidationError) as exc:
        exit_code = 1
        payload = {"diagnostic": str(exc), "failureBoundary": "build-measurement-setup",
                   "schemaVersion": 3, "status": "failure"}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", prefix=f".{args.output.name}.",
                                     dir=args.output.parent, delete=False) as temporary:
        temporary.write(canonical_json(payload))
        temporary_path = Path(temporary.name)
    temporary_path.replace(args.output)
    if exit_code != 0:
        print(canonical_json(payload), file=sys.stderr, end="")
    return exit_code


if __name__ == "__main__":
    raise SystemExit(main())
