#!/usr/bin/env python3
"""Run one physical Metal, Vulkan, or D3D12 recomposition evidence lane."""

from __future__ import annotations

import argparse
import platform
import re
import subprocess
import sys
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
CLI = REPO_ROOT / "bench" / "cli.py"
BACKEND_CAPTURE = (
    REPO_ROOT / "runtime" / "zig" / "tools" / "capture_backend_evidence.py"
)
SCHEMA_GATE = REPO_ROOT / "bench" / "gates" / "schema_gate.py"
REPORT_INTEGRITY = (
    REPO_ROOT / "runtime" / "zig" / "tools" / "check_recomposition_reports.py"
)
WORKLOAD_ID = "compute_workgroup_atomic_1024"
RECEIPT_LINE = re.compile(r"^\s*(bench/out/\S+\.run\.json)\s*$")
BACKENDS = {
    "metal": {
        "config": "bench/native-compare/compare.config.apple.metal.smoke.json",
        "host": "Darwin",
        "preflight": "bench/runners/preflight_metal_host.py",
    },
    "vulkan": {
        "config": "bench/native-compare/compare.config.amd.vulkan.smoke.json",
        "host": "Linux",
        "preflight": "bench/runners/preflight_vulkan_host.py",
    },
    "d3d12": {
        "config": "bench/native-compare/compare.config.local.d3d12.smoke.json",
        "host": "Windows",
        "preflight": "bench/runners/preflight_d3d12_host.py",
    },
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--backend", choices=sorted(BACKENDS))
    parser.add_argument("--config", type=Path)
    parser.add_argument(
        "--report",
        type=Path,
        help="Comparable report path; defaults under bench/out/recomposition/.",
    )
    parser.add_argument("--skip-preflight", action="store_true")
    parser.add_argument("--dry-run", action="store_true")
    return parser.parse_args()


def _backend_for_host(explicit: str | None) -> str:
    if explicit is not None:
        return explicit
    system = platform.system()
    for name, spec in BACKENDS.items():
        if spec["host"] == system:
            return name
    raise ValueError("backend must be explicit on an unsupported host OS")


def _run(command: list[str], *, dry_run: bool, capture: bool = False) -> str:
    print(" ".join(command))
    if dry_run:
        return ""
    result = subprocess.run(
        command,
        cwd=REPO_ROOT,
        check=False,
        capture_output=capture,
        text=True,
    )
    if capture:
        if result.stdout:
            print(result.stdout, end="")
        if result.stderr:
            print(result.stderr, file=sys.stderr, end="")
    if result.returncode != 0:
        raise RuntimeError(
            f"command failed with exit code {result.returncode}: {command[1]}"
        )
    return result.stdout if capture else ""


def _receipt_from_output(output: str, side: str) -> Path:
    paths = [
        REPO_ROOT / match.group(1)
        for line in output.splitlines()
        if (match := RECEIPT_LINE.match(line))
    ]
    if len(paths) != 1:
        raise RuntimeError(
            f"{side} run emitted {len(paths)} receipt paths; expected exactly one"
        )
    if not paths[0].is_file():
        raise RuntimeError(f"{side} run receipt is missing: {paths[0]}")
    return paths[0]


def _run_side(config: Path, side: str, *, dry_run: bool) -> Path | None:
    command = [
        sys.executable,
        str(CLI),
        "run-config",
        "--config",
        str(config),
        "--side",
        side,
        "--workload-filter",
        WORKLOAD_ID,
    ]
    output = _run(command, dry_run=dry_run, capture=True)
    return None if dry_run else _receipt_from_output(output, side)


def main() -> int:
    args = parse_args()
    try:
        backend = _backend_for_host(args.backend)
        spec = BACKENDS[backend]
        if platform.system() != spec["host"] and not args.dry_run:
            raise ValueError(f"{backend} evidence requires a {spec['host']} host")
        config = (args.config or Path(spec["config"])).resolve()
        report = (
            args.report
            or Path(f"bench/out/recomposition/backend-evidence-inputs/{backend}.json")
        ).resolve()
        if not args.skip_preflight:
            preflight = [sys.executable, str(REPO_ROOT / spec["preflight"])]
            if backend == "d3d12":
                preflight.append("--json")
            _run(preflight, dry_run=args.dry_run)
        baseline = _run_side(config, "baseline", dry_run=args.dry_run)
        comparison = _run_side(config, "comparison", dry_run=args.dry_run)
        if args.dry_run:
            print("compare <baseline.run.json> <comparison.run.json>")
            print(f"capture {backend} output from {report}")
            return 0
        assert baseline is not None and comparison is not None
        report.parent.mkdir(parents=True, exist_ok=True)
        _run(
            [
                sys.executable,
                str(CLI),
                "compare",
                str(baseline.relative_to(REPO_ROOT)),
                str(comparison.relative_to(REPO_ROOT)),
                "--comparability",
                "strict",
                "--require-timing-class",
                "operation",
                "--out",
                str(report),
            ],
            dry_run=False,
        )
        _run(
            [
                sys.executable,
                str(BACKEND_CAPTURE),
                f"--{backend}-output-report",
                str(report),
                f"--{backend}-output-workload-id",
                WORKLOAD_ID,
            ],
            dry_run=False,
        )
        _run([sys.executable, str(SCHEMA_GATE)], dry_run=False)
        _run([sys.executable, str(REPORT_INTEGRITY)], dry_run=False)
    except (OSError, RuntimeError, ValueError) as exc:
        print(f"backend evidence lane failed: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
