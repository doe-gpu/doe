"""CLI for the physical Fawn-Doe four-lane context matrix."""

from __future__ import annotations

import argparse
import dataclasses
import datetime
import json
import os
import subprocess
import sys
from pathlib import Path
from typing import Any

from bench.fawn_matrix.harness.evaluator import evaluate_decision_rules
from bench.fawn_matrix.harness.evidence import (
    sha256_file,
    validate_raw_evidence,
)
from bench.fawn_matrix.harness.lanes import build_lane_results


REPO_ROOT = Path(__file__).resolve().parents[2]
CONFIG_PATH = (
    Path(__file__).parent / "config" / "matrix-workloads.json"
)
EXECUTOR_PATH = (
    Path(__file__).parent
    / "executors"
    / "context_snapshot_diff.mjs"
)
DEFAULT_OUTPUT_ROOT = REPO_ROOT / "bench" / "out" / "fawn-matrix"


def load_config() -> dict[str, Any]:
    return json.loads(CONFIG_PATH.read_text(encoding="utf-8"))


def _first_existing(
    paths: list[Path],
    executable: bool = False,
) -> Path | None:
    for path in paths:
        if path.is_file() and (
            not executable or os.access(path, os.X_OK)
        ):
            return path.resolve()
    return None


def resolve_host_paths(
    stock_chrome: str | None,
    fawn_chrome: str | None,
    doe_lib: str | None,
) -> tuple[Path, Path, Path]:
    """Resolve the host artifacts used by the Chromium lane wrappers."""
    stock = (
        Path(stock_chrome).resolve()
        if stock_chrome
        else _first_existing(
            [
                Path(
                    "/Applications/Google Chrome.app/Contents/MacOS/"
                    "Google Chrome"
                ),
                Path(
                    "/Applications/Google Chrome Canary.app/Contents/"
                    "MacOS/Google Chrome Canary"
                ),
                Path("/usr/bin/google-chrome-stable"),
                Path("/usr/bin/google-chrome"),
                Path("/usr/bin/chromium"),
                Path("/usr/bin/chromium-browser"),
            ],
            executable=True,
        )
    )
    fawn = (
        Path(fawn_chrome).resolve()
        if fawn_chrome
        else _first_existing(
            [
                REPO_ROOT
                / "browser/chromium/out/fawn_release_local/Fawn.app/"
                "Contents/MacOS/Chromium-real",
                REPO_ROOT
                / "browser/chromium/out/fawn_release_local/chrome",
                Path.home()
                / "Applications/Fawn.app/Contents/MacOS/Chromium-real",
                REPO_ROOT
                / "browser/chromium/src/out/fawn_release/chrome",
            ],
            executable=True,
        )
    )
    library = (
        Path(doe_lib).resolve()
        if doe_lib
        else _first_existing(
            [
                REPO_ROOT
                / "runtime/zig/zig-out/lib/libwebgpu_doe_full.dylib",
                REPO_ROOT
                / "runtime/zig/zig-out/lib/libwebgpu_doe_full.so",
                REPO_ROOT
                / "runtime/zig/zig-out/lib/libwebgpu_doe_full.dll",
            ]
        )
    )
    if stock is None:
        raise FileNotFoundError(
            "stock Chromium executable was not found"
        )
    if fawn is None:
        raise FileNotFoundError(
            "Fawn Chromium executable was not found"
        )
    if library is None:
        raise FileNotFoundError(
            "Doe browser runtime library was not found"
        )
    return stock, fawn, library


def _workload(
    config: dict[str, Any],
    workload_id: str,
) -> dict[str, Any]:
    for workload in config["workloads"]:
        if workload["workloadId"] == workload_id:
            return workload
    raise ValueError("unsupported workload: " + workload_id)


def _write_json(path: Path, payload: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(payload, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


def run_matrix(
    workload_id: str,
    platform_id: str,
    output_root: Path,
    stock_chrome: Path,
    fawn_chrome: Path,
    doe_lib: Path,
    is_headless: bool = True,
) -> tuple[dict[str, Any], Path]:
    """Execute four real lanes and emit a platform-scoped report."""
    config = load_config()
    workload = _workload(config, workload_id)
    run_id = datetime.datetime.now(
        datetime.timezone.utc
    ).strftime("%Y%m%dT%H%M%SZ")
    run_dir = output_root / platform_id / run_id
    raw_path = run_dir / (workload_id + ".raw.json")
    report_path = run_dir / (
        workload_id + ".platform-report.json"
    )
    command = [
        "node",
        str(EXECUTOR_PATH),
        "--stock-chrome",
        str(stock_chrome),
        "--fawn-chrome",
        str(fawn_chrome),
        "--doe-lib",
        str(doe_lib),
        "--fixture",
        str(REPO_ROOT / workload["inputPath"]),
        "--platform-id",
        platform_id,
        "--warmup-iterations",
        str(workload["warmupIterations"]),
        "--timed-iterations",
        str(workload["timedIterations"]),
        "--headless",
        "true" if is_headless else "false",
        "--out",
        str(raw_path),
    ]
    completed = subprocess.run(
        command,
        cwd=REPO_ROOT,
        check=False,
        capture_output=True,
        text=True,
    )
    if completed.returncode != 0:
        detail = (completed.stderr or completed.stdout).strip()
        raise RuntimeError(
            "physical matrix executor failed: " + detail[-4000:]
        )
    payload = json.loads(raw_path.read_text(encoding="utf-8"))
    evidence = validate_raw_evidence(
        payload,
        workload,
        REPO_ROOT,
    )
    results = build_lane_results(payload, evidence)
    raw_artifact = {
        "path": str(raw_path.relative_to(REPO_ROOT)),
        "sha256": sha256_file(raw_path),
    }
    report = evaluate_decision_rules(
        workload_id,
        results,
        config["decisionThresholds"],
        payload["platform"],
        evidence,
        raw_artifact,
    )
    report_payload = dataclasses.asdict(report)
    _write_json(report_path, report_payload)
    return report_payload, report_path


def aggregate_reports(
    report_paths: list[Path],
    output_path: Path,
) -> dict[str, Any]:
    """Require both physical targets before emitting a reviewable report."""
    config = load_config()
    reports = [
        json.loads(path.read_text(encoding="utf-8"))
        for path in report_paths
    ]
    by_platform = {
        report["platform"]["platformId"]: report
        for report in reports
    }
    required = set(config["requiredPhysicalPlatforms"])
    if set(by_platform) != required:
        raise ValueError(
            "aggregate requires exactly these physical platforms: "
            + ", ".join(sorted(required))
        )
    identity_hashes = {
        report["platform"]["hardwareIdentity"]["identityHash"]
        for report in reports
    }
    if len(identity_hashes) != len(required):
        raise ValueError(
            "physical platform reports must use distinct hardware"
        )
    if any(
        report["evidence_status"] != "physical_diagnostic"
        for report in reports
    ):
        raise ValueError(
            "every platform report must contain physical evidence"
        )
    statuses = {
        report["overall_thesis_status"] for report in reports
    }
    decision = (
        statuses.pop()
        if len(statuses) == 1
        else "PLATFORM_DEPENDENT"
    )
    aggregate = {
        "schemaVersion": 1,
        "reportKind": (
            "fawn-doe-context-snapshot-diff-two-platform-report"
        ),
        "workloadId": "context_snapshot_diff",
        "evidenceStatus": "cross_platform_review_required",
        "productDecision": decision,
        "doeRuntimePerformanceCredit": False,
        "platformReports": [
            {
                "hardwareIdentityHash": report["platform"][
                    "hardwareIdentity"
                ]["identityHash"],
                "path": str(path),
                "platformId": report["platform"]["platformId"],
                "sha256": sha256_file(path),
            }
            for path, report in zip(
                report_paths,
                reports,
                strict=True,
            )
        ],
        "publicationStatus": (
            "not_claim_indexed_pending_review"
        ),
        "generatedAtUtc": datetime.datetime.now(
            datetime.timezone.utc
        ).isoformat(),
    }
    _write_json(output_path, aggregate)
    return aggregate


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Physical Fawn-Doe context matrix"
    )
    subparsers = parser.add_subparsers(
        dest="command",
        required=True,
    )
    run_parser = subparsers.add_parser(
        "run",
        help="Run all four physical lanes",
    )
    run_parser.add_argument(
        "--workload",
        default="context_snapshot_diff",
    )
    run_parser.add_argument(
        "--platform-id",
        choices=["apple-metal", "amd-vulkan"],
        required=True,
    )
    run_parser.add_argument("--stock-chrome")
    run_parser.add_argument("--fawn-chrome")
    run_parser.add_argument("--doe-lib")
    run_parser.add_argument(
        "--output-root",
        type=Path,
        default=DEFAULT_OUTPUT_ROOT,
    )
    run_parser.add_argument("--headful", action="store_true")
    aggregate_parser = subparsers.add_parser(
        "aggregate",
        help="Join Apple Metal and AMD Vulkan platform reports",
    )
    aggregate_parser.add_argument(
        "--platform-report",
        action="append",
        type=Path,
        required=True,
    )
    aggregate_parser.add_argument(
        "--out",
        type=Path,
        required=True,
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.command == "aggregate":
        aggregate = aggregate_reports(
            args.platform_report,
            args.out,
        )
        print(json.dumps(aggregate, indent=2, sort_keys=True))
        return 0
    stock, fawn, library = resolve_host_paths(
        args.stock_chrome,
        args.fawn_chrome,
        args.doe_lib,
    )
    report, path = run_matrix(
        args.workload,
        args.platform_id,
        args.output_root,
        stock,
        fawn,
        library,
        is_headless=not args.headful,
    )
    print(
        json.dumps(
            {
                "evidenceStatus": report["evidence_status"],
                "overallThesisStatus": report[
                    "overall_thesis_status"
                ],
                "reportPath": str(path),
            },
            indent=2,
            sort_keys=True,
        )
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (FileNotFoundError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(1) from None
