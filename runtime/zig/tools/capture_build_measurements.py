"""Capture source-bound clean and incremental Doe Zig build measurements."""

from __future__ import annotations

import argparse
import hashlib
import platform
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Any

from source_architecture import analyze, canonical_json, load_manifest, sha256_file


ROOT = Path(__file__).resolve().parents[1]
CONFIG_PATH = ROOT / "source-layout.json"
OUTPUT_PATH = ROOT / "reports" / "architecture" / "build-measurements.json"


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


def _run_build(
    command: list[str],
    root: Path,
    temporary_root: Path,
) -> dict[str, Any]:
    started_ns = time.monotonic_ns()
    result = subprocess.run(
        command,
        cwd=root,
        check=False,
        capture_output=True,
        text=True,
    )
    elapsed_ns = time.monotonic_ns() - started_ns
    stdout = _sanitize(result.stdout, temporary_root)
    stderr = _sanitize(result.stderr, temporary_root)
    return {
        "elapsedNs": elapsed_ns,
        "exitCode": result.returncode,
        "stderr": stderr[-16_384:],
        "stderrSha256": _digest_text(stderr),
        "stdout": stdout[-16_384:],
        "stdoutSha256": _digest_text(stdout),
    }


def _artifact_inventory(prefix: Path, temporary_root: Path) -> list[dict[str, Any]]:
    if not prefix.is_dir():
        return []
    return [
        {
            "path": _sanitize(str(path), temporary_root),
            "sha256": sha256_file(path),
            "sizeBytes": path.stat().st_size,
        }
        for path in sorted(prefix.rglob("*"))
        if path.is_file()
    ]


def capture(
    root: Path,
    config_path: Path,
    *,
    build_step: str,
    optimize: str,
) -> tuple[int, dict[str, Any]]:
    """Run one clean and one cache-reuse build against one coherent source tree."""

    capture_tool_sha256 = sha256_file(Path(__file__))
    config = load_manifest(config_path)
    before = analyze(root, config)
    if before.manifest_errors or before.unresolved_imports:
        raise RuntimeError("source architecture is not valid before measurement")
    zig = _find_zig(root)
    zig_version = subprocess.run(
        [str(zig), "version"],
        cwd=root,
        check=True,
        capture_output=True,
        text=True,
    ).stdout.strip()
    with tempfile.TemporaryDirectory(prefix="doe-zig-build-measurement-") as temporary:
        temporary_root = Path(temporary)
        cache = temporary_root / "cache"
        global_cache = temporary_root / "global-cache"
        prefix = temporary_root / "prefix"
        command = [
            str(zig),
            "build",
            build_step,
            f"-Doptimize={optimize}",
            "-j1",
            "--seed",
            "0",
            "--summary",
            "none",
            "--cache-dir",
            str(cache),
            "--global-cache-dir",
            str(global_cache),
            "--prefix",
            str(prefix),
        ]
        clean = _run_build(command, root, temporary_root)
        after_clean = analyze(root, config)
        source_changed_before_incremental = (
            after_clean.source_tree_sha256 != before.source_tree_sha256
        )
        incremental = (
            _run_build(command, root, temporary_root)
            if clean["exitCode"] == 0 and not source_changed_before_incremental
            else {
                "elapsedNs": None,
                "exitCode": None,
                "status": (
                    "not-run-source-changed"
                    if source_changed_before_incremental
                    else "not-run-clean-build-failed"
                ),
                "stderr": "",
                "stderrSha256": None,
                "stdout": "",
                "stdoutSha256": None,
            }
        )
        builds_passed = clean["exitCode"] == 0 and incremental["exitCode"] == 0
        artifacts = _artifact_inventory(prefix, temporary_root)
        normalized_command = [
            _sanitize(argument, temporary_root) for argument in command
        ]
    after = analyze(root, config)
    source_changed = after.source_tree_sha256 != before.source_tree_sha256
    capture_tool_changed = sha256_file(Path(__file__)) != capture_tool_sha256
    status = (
        "captured"
        if builds_passed and not source_changed and not capture_tool_changed
        else "failure"
    )
    payload = {
        "artifacts": artifacts,
        "buildStep": build_step,
        "cleanCompile": clean,
        "command": normalized_command,
        "captureToolChangedDuringCapture": capture_tool_changed,
        "captureToolSha256": capture_tool_sha256,
        "host": {
            "machine": platform.machine(),
            "operatingSystem": platform.system(),
            "release": platform.release(),
        },
        "incrementalCompile": incremental,
        "measurementClass": "diagnostic-only",
        "optimize": optimize,
        "schemaVersion": 2,
        "sourceChangedDuringCapture": source_changed,
        "sourceChangedBeforeIncremental": source_changed_before_incremental,
        "sourceTreeSha256": before.source_tree_sha256,
        "status": status,
        "toolchain": {
            "path": str(zig),
            "sha256": sha256_file(zig),
            "version": zig_version,
        },
    }
    return (0 if status == "captured" else 1), payload


def parse_args() -> argparse.Namespace:
    """Parse build-measurement arguments."""

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=ROOT, help="runtime/zig root")
    parser.add_argument(
        "--config", type=Path, default=CONFIG_PATH, help="source-layout manifest"
    )
    parser.add_argument(
        "--output", type=Path, default=OUTPUT_PATH, help="measurement receipt path"
    )
    parser.add_argument(
        "--build-step", default="doe-runtime", help="Zig build step to measure"
    )
    parser.add_argument(
        "--optimize", default="ReleaseSafe", help="Zig optimization mode"
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        exit_code, payload = capture(
            args.root.resolve(),
            args.config.resolve(),
            build_step=args.build_step,
            optimize=args.optimize,
        )
    except (OSError, RuntimeError, subprocess.SubprocessError, ValueError) as exc:
        exit_code = 1
        payload = {
            "diagnostic": str(exc),
            "failureBoundary": "build-measurement-setup",
            "schemaVersion": 1,
            "status": "failure",
        }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(
        mode="w",
        encoding="utf-8",
        prefix=f".{args.output.name}.",
        dir=args.output.parent,
        delete=False,
    ) as temporary:
        temporary.write(canonical_json(payload))
        temporary_path = Path(temporary.name)
    temporary_path.replace(args.output)
    if exit_code != 0:
        print(canonical_json(payload), file=sys.stderr, end="")
    return exit_code


if __name__ == "__main__":
    raise SystemExit(main())
