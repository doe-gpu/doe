#!/usr/bin/env python3
"""Run the governed local Windows D3D12 handoff sequence."""

from __future__ import annotations

import argparse
import re
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
RECEIPT_LINE = re.compile(r"^\s*(bench/out/\S+\.run\.json)\s*$")


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


def run_step(
    name: str,
    command: list[str],
    *,
    dry_run: bool,
    capture: bool = False,
) -> str:
    printable = " ".join(command)
    print(f"[{name}] {printable}")
    if dry_run:
        return ""
    result = subprocess.run(
        command,
        cwd=REPO_ROOT,
        check=True,
        capture_output=capture,
        text=True,
    )
    if capture and result.stdout:
        print(result.stdout, end="")
    if capture and result.stderr:
        print(result.stderr, file=sys.stderr, end="")
    return result.stdout if capture else ""


def receipt_paths(output: str, side: str) -> list[Path]:
    paths = [
        REPO_ROOT / match.group(1)
        for line in output.splitlines()
        if (match := RECEIPT_LINE.match(line))
    ]
    if not paths:
        raise ValueError(f"{side} run emitted no receipt paths")
    missing = [str(path) for path in paths if not path.is_file()]
    if missing:
        raise ValueError(f"{side} run receipts are missing: {', '.join(missing)}")
    return paths


def run_receipt_compare(
    name: str,
    config: Path,
    report: Path,
    *,
    dry_run: bool,
) -> None:
    commands = {
        side: [
            sys.executable,
            str(CLI),
            "run-config",
            "--config",
            str(config),
            "--side",
            side,
        ]
        for side in ("baseline", "comparison")
    }
    if dry_run:
        for side, command in commands.items():
            run_step(f"{name}-{side}", command, dry_run=True)
        print(
            f"[{name}-compare] {sys.executable} {CLI} compare "
            "<baseline.run.json...> <comparison.run.json...> "
            f"--out {report}"
        )
        return
    baseline = receipt_paths(
        run_step(
            f"{name}-baseline",
            commands["baseline"],
            dry_run=False,
            capture=True,
        ),
        "baseline",
    )
    comparison = receipt_paths(
        run_step(
            f"{name}-comparison",
            commands["comparison"],
            dry_run=False,
            capture=True,
        ),
        "comparison",
    )
    report.parent.mkdir(parents=True, exist_ok=True)
    run_step(
        f"{name}-compare",
        [
            sys.executable,
            str(CLI),
            "compare",
            *(str(path.relative_to(REPO_ROOT)) for path in baseline),
            *(str(path.relative_to(REPO_ROOT)) for path in comparison),
            "--comparability",
            "strict",
            "--require-timing-class",
            "operation",
            "--baseline-product",
            "doe",
            "--comparison-product",
            "dawn_delegate",
            "--out",
            str(report),
        ],
        dry_run=False,
    )


def main() -> int:
    args = parse_args()
    smoke_config = REPO_ROOT / args.smoke_config
    compare_config = REPO_ROOT / args.compare_config
    smoke_report = config_report_path(smoke_config)
    compare_report = config_report_path(compare_config)

    run_step(
        "preflight",
        [sys.executable, str(PREFLIGHT), "--json"],
        dry_run=args.dry_run,
    )
    run_receipt_compare(
        "smoke",
        smoke_config,
        smoke_report,
        dry_run=args.dry_run,
    )
    run_receipt_compare(
        "compare",
        compare_config,
        compare_report,
        dry_run=args.dry_run,
    )
    run_step(
        "blocking-gates",
        [
            sys.executable,
            str(BLOCKING_GATES),
            "--report",
            str(compare_report),
            "--trace-semantic-parity-mode",
            args.trace_semantic_parity_mode,
        ],
        dry_run=args.dry_run,
    )
    if not args.skip_cube:
        run_step(
            "cube",
            [sys.executable, str(CUBE)],
            dry_run=args.dry_run,
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
