#!/usr/bin/env python3
"""Run the governed local Windows D3D12 handoff sequence."""

from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from bench.lib.bench_utils import load_json_object

BENCH_DIR = REPO_ROOT / "bench"
PREFLIGHT = BENCH_DIR / "runners" / "preflight_d3d12_host.py"
CLI = BENCH_DIR / "cli.py"
BLOCKING_GATES = BENCH_DIR / "runners" / "run_blocking_gates.py"
CUBE = BENCH_DIR / "tools" / "build_benchmark_cube.py"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--smoke-config",
        default="bench/native-compare/compare.config.local.d3d12.smoke.json",
        help="Smoke compare config path.",
    )
    parser.add_argument(
        "--compare-config",
        default="bench/native-compare/compare.config.local.d3d12.compare.json",
        help="Governed compare config path.",
    )
    parser.add_argument(
        "--extended-config",
        dest="compare_config",
        help="Legacy alias for --compare-config.",
    )
    parser.add_argument(
        "--trace-semantic-parity-mode",
        choices=["off", "auto", "required"],
        default="auto",
        help="Forwarded to run_blocking_gates.py for the governed compare report.",
    )
    parser.add_argument(
        "--skip-cube",
        action="store_true",
        help="Skip benchmark cube rebuild after the governed compare lane passes.",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Print planned commands without executing them.",
    )
    return parser.parse_args()


def config_report_path(config_path: Path) -> Path:
    payload = load_json_object(config_path)
    run_payload = payload.get("run")
    if not isinstance(run_payload, dict):
        raise ValueError(f"invalid compare config: {config_path}")
    out_path = run_payload.get("out")
    if not isinstance(out_path, str) or not out_path:
        raise ValueError(f"missing run.out in compare config: {config_path}")
    return REPO_ROOT / out_path


def run_step(name: str, command: list[str], *, dry_run: bool) -> None:
    printable = " ".join(command)
    print(f"[{name}] {printable}")
    if dry_run:
        return
    subprocess.run(command, cwd=REPO_ROOT, check=True)


def main() -> int:
    args = parse_args()
    smoke_config = REPO_ROOT / args.smoke_config
    compare_config = REPO_ROOT / args.compare_config
    compare_report = config_report_path(compare_config)

    steps: list[tuple[str, list[str]]] = [
        ("preflight", [sys.executable, str(PREFLIGHT), "--json"]),
        ("smoke", [sys.executable, str(CLI), "compare", "--config", str(smoke_config)]),
        ("compare", [sys.executable, str(CLI), "compare", "--config", str(compare_config)]),
        (
            "blocking-gates",
            [
                sys.executable,
                str(BLOCKING_GATES),
                "--report",
                str(compare_report),
                "--trace-semantic-parity-mode",
                args.trace_semantic_parity_mode,
            ],
        ),
    ]
    if not args.skip_cube:
        steps.append(("cube", [sys.executable, str(CUBE)]))

    for name, command in steps:
        run_step(name, command, dry_run=args.dry_run)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
