#!/usr/bin/env python3
"""Run repeated release claim windows and summarize trend evidence."""

from __future__ import annotations

import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
BENCH_ROOT = REPO_ROOT / "bench"
for _path_entry in (str(REPO_ROOT), str(BENCH_ROOT)):
    if _path_entry not in sys.path:
        sys.path.insert(0, _path_entry)


import argparse
import subprocess
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any

from bench.lib import compare_claim_artifacts as artifacts_mod
from bench.lib import output_paths
from bench.lib.bench_utils import load_json_object as load_json
from bench.lib.bench_utils import write_json_object as write_report


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--config",
        default="bench/native-compare/compare.config.amd.vulkan.release.json",
        help="Release compare-lane config path.",
    )
    parser.add_argument(
        "--windows",
        type=int,
        default=5,
        help="Number of consecutive release windows to execute.",
    )
    parser.add_argument(
        "--strict-amd-vulkan",
        action="store_true",
        help="Forward strict host preflight to each release-window run.",
    )
    parser.add_argument(
        "--trace-semantic-parity-mode",
        choices=["off", "auto", "required"],
        default="auto",
        help="Semantic parity mode forwarded to each release pipeline window.",
    )
    parser.add_argument(
        "--with-comparability-parity-gate",
        action="store_true",
        help="Forward comparability parity verification gate to each release pipeline window.",
    )
    parser.add_argument(
        "--compare-html-output",
        action=argparse.BooleanOptionalAction,
        default=True,
        help=(
            "Forward compare HTML generation toggle to each release pipeline window "
            "(default: enabled)."
        ),
    )
    parser.add_argument(
        "--with-claim-rehearsal-artifacts",
        action=argparse.BooleanOptionalAction,
        default=True,
        help=(
            "Forward claim rehearsal artifact generation toggle to each release pipeline window "
            "(default: enabled)."
        ),
    )
    parser.add_argument(
        "--with-cycle-gate",
        action=argparse.BooleanOptionalAction,
        default=True,
        help="Forward cycle gate execution toggle to each release pipeline window.",
    )
    parser.add_argument(
        "--cycle-contract",
        default="config/claim-cycle.active.json",
        help="Cycle contract path forwarded to each release pipeline window.",
    )
    parser.add_argument(
        "--cycle-gate-out",
        default="bench/out/cycle_gate_report.json",
        help="Cycle-gate report path forwarded to each release pipeline window.",
    )
    parser.add_argument(
        "--cycle-artifact-class",
        choices=["claim", "diagnostic"],
        default="claim",
        help="Artifact class forwarded to cycle gate in each release pipeline window.",
    )
    parser.add_argument(
        "--cycle-comparability-obligations",
        default="config/comparability-obligations.json",
        help="Comparability-obligation contract path forwarded to cycle gate.",
    )
    parser.add_argument(
        "--cycle-substantiation-report",
        default="",
        help="Optional substantiation report path forwarded to cycle gate.",
    )
    parser.add_argument(
        "--cycle-enforce-rollbacks",
        action=argparse.BooleanOptionalAction,
        default=True,
        help="Forward rollback enforcement toggle to cycle gate in each window.",
    )
    parser.add_argument(
        "--with-dropin-gate",
        action="store_true",
        help="Run drop-in gate for each window.",
    )
    parser.add_argument(
        "--dropin-artifact",
        default="runtime/zig/zig-out/lib/libwebgpu_doe.so",
        help="Shared library artifact path when --with-dropin-gate is set.",
    )
    parser.add_argument(
        "--dropin-skip-benchmarks",
        action="store_true",
        help="Skip drop-in benchmark phase while still running symbol+behavior checks.",
    )
    parser.add_argument(
        "--with-claim-gate",
        action=argparse.BooleanOptionalAction,
        default=True,
        help="Run claim gate for each window (default: enabled).",
    )
    parser.add_argument(
        "--claim-require-comparison-status",
        default="comparable",
        help="Required comparisonStatus for claim gate.",
    )
    parser.add_argument(
        "--claim-require-claim-status",
        default="claimable",
        help="Required claimStatus for claim gate.",
    )
    parser.add_argument(
        "--claim-require-claimability-mode",
        default="release",
        help="Required claimability mode for claim gate.",
    )
    parser.add_argument(
        "--claim-require-min-timed-samples",
        type=int,
        default=15,
        help="Minimum timed sample floor for claim gate.",
    )
    parser.add_argument(
        "--timestamp-base",
        default="",
        help=(
            "Base UTC timestamp (YYYYMMDDTHHMMSSZ). "
            "Window i uses base + i seconds when timestamping is enabled."
        ),
    )
    parser.add_argument(
        "--timestamp-output",
        action=argparse.BooleanOptionalAction,
        default=True,
        help="Timestamp per-window report paths and summary output.",
    )
    parser.add_argument(
        "--out",
        default="bench/out/release-claim-windows.json",
        help="Summary JSON output path.",
    )
    parser.add_argument(
        "--continue-on-failure",
        action="store_true",
        help="Keep running later windows when one window fails.",
    )
    parser.add_argument(
        "--with-substantiation-gate",
        action="store_true",
        help="Run substantiation_gate.py over the generated window summary.",
    )
    parser.add_argument(
        "--substantiation-policy",
        default="config/substantiation-policy.json",
        help="Policy JSON path passed to substantiation_gate.py.",
    )
    parser.add_argument(
        "--substantiation-report",
        default="bench/out/substantiation_report.json",
        help="Output report path passed to substantiation_gate.py.",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Print planned commands without executing them.",
    )
    return parser.parse_args()


def resolve_config_report_path(config_path: Path) -> Path:
    config_payload = load_json(config_path)
    run_payload = config_payload.get("run")
    if not isinstance(run_payload, dict):
        raise ValueError(f"invalid config {config_path}: missing object field run")
    report_value = run_payload.get("out")
    if not isinstance(report_value, str) or not report_value.strip():
        raise ValueError(f"invalid config {config_path}: missing non-empty run.out")
    return Path(report_value)


def summarize_report(report_path: Path) -> dict[str, Any]:
    if not report_path.exists():
        return {
            "reportFound": False,
            "reportPath": str(report_path),
        }

    payload = load_json(report_path)
    claim_payload, claim_path = artifacts_mod.load_optional_claim_report(report_path)
    workloads = payload.get("workloads")
    if not isinstance(workloads, list):
        workloads = []

    claim_rows = artifacts_mod.claim_workloads_by_id(claim_payload)
    non_claimable_ids: list[str] = []
    non_comparable_ids: list[str] = []
    for workload in workloads:
        if not isinstance(workload, dict):
            continue
        workload_id = workload.get("id")
        workload_label = workload_id if isinstance(workload_id, str) and workload_id else "unknown"
        comparability = workload.get("comparability")
        claimability = claim_rows.get(str(workload_id), {})
        if isinstance(claimability, dict) and claimability.get("claimable") is False:
            non_claimable_ids.append(workload_label)
        if isinstance(comparability, dict) and comparability.get("comparable") is False:
            non_comparable_ids.append(workload_label)

    summary = {
        "reportFound": True,
        "reportPath": str(report_path),
        "claimReportPath": str(claim_path) if claim_path is not None else "",
        "comparisonStatus": payload.get("comparisonStatus"),
        "claimStatus": artifacts_mod.claim_status(payload, claim_payload),
        "comparabilitySummary": payload.get("comparabilitySummary"),
        "claimabilitySummary": {
            "workloadCount": len(workloads),
            "nonClaimableCount": artifacts_mod.non_claimable_count(payload, claim_payload),
        },
        "workloadCount": len(workloads),
        "nonClaimableWorkloadIds": non_claimable_ids,
        "nonComparableWorkloadIds": non_comparable_ids,
    }
    return summary


def main() -> int:
    args = parse_args()

    if args.windows <= 0:
        print(f"FAIL: --windows must be > 0 (received: {args.windows})")
        return 1
    if args.claim_require_min_timed_samples < 0:
        print(
            "FAIL: invalid --claim-require-min-timed-samples="
            f"{args.claim_require_min_timed_samples} expected >= 0"
        )
        return 1
    if not args.timestamp_output and args.windows > 1:
        print(
            "FAIL: --windows > 1 requires --timestamp-output to avoid report clobbering"
        )
        return 1

    config_path = Path(args.config)
    if not config_path.exists():
        print(f"FAIL: missing config: {config_path}")
        return 1

    if args.with_dropin_gate and not args.dropin_artifact.strip():
        print("FAIL: --with-dropin-gate requires --dropin-artifact")
        return 1
    if args.with_dropin_gate and not args.dry_run:
        artifact_path = Path(args.dropin_artifact)
        if not artifact_path.exists():
            print(f"FAIL: missing --dropin-artifact: {artifact_path}")
            return 1
    if args.with_substantiation_gate and not Path(args.substantiation_policy).exists():
        print(f"FAIL: missing --substantiation-policy: {args.substantiation_policy}")
        return 1
    if args.with_cycle_gate and args.with_claim_gate and not args.dry_run:
        if not Path(args.cycle_contract).exists():
            print(f"FAIL: missing --cycle-contract: {args.cycle_contract}")
            return 1
        if not Path(args.cycle_comparability_obligations).exists():
            print(
                "FAIL: missing --cycle-comparability-obligations: "
                f"{args.cycle_comparability_obligations}"
            )
            return 1
        if args.cycle_substantiation_report.strip() and not Path(
            args.cycle_substantiation_report.strip()
        ).exists():
            print(
                "FAIL: missing --cycle-substantiation-report: "
                f"{args.cycle_substantiation_report.strip()}"
            )
            return 1

    raw_report_path = resolve_config_report_path(config_path)
    base_timestamp = (
        output_paths.resolve_timestamp(args.timestamp_base)
        if args.timestamp_output
        else ""
    )
    base_dt = (
        datetime.strptime(base_timestamp, output_paths.TIMESTAMP_FORMAT).replace(
            tzinfo=timezone.utc
        )
        if base_timestamp
        else None
    )
    run_group = output_paths.derive_bench_out_group(args.out)
    out_path = output_paths.with_timestamp(
        args.out,
        base_timestamp,
        enabled=args.timestamp_output,
        group=run_group,
    )
    substantiation_report_path = output_paths.with_timestamp(
        args.substantiation_report,
        base_timestamp,
        enabled=args.timestamp_output,
        group=run_group,
    )

    runners_dir = BENCH_ROOT / "runners"
    gates_dir = BENCH_ROOT / "gates"
    pipeline = runners_dir / "run_release_pipeline.py"
    substantiation_gate = gates_dir / "substantiation_gate.py"
    python_exe = sys.executable

    windows: list[dict[str, Any]] = []
    failed_windows: list[int] = []
    substantiation_result: dict[str, Any] | None = None

    for idx in range(args.windows):
        window_timestamp = ""
        report_path = raw_report_path
        if args.timestamp_output:
            assert base_dt is not None
            window_timestamp = (
                base_dt + timedelta(seconds=idx)
            ).strftime(output_paths.TIMESTAMP_FORMAT)
            report_path = output_paths.with_timestamp(
                raw_report_path,
                window_timestamp,
                enabled=True,
                group=run_group,
            )

        command = [
            python_exe,
            str(pipeline),
            "--config",
            str(config_path),
            "--report",
            str(raw_report_path),
        ]
        if args.strict_amd_vulkan:
            command.append("--strict-amd-vulkan")
        command.extend(
            [
                "--trace-semantic-parity-mode",
                args.trace_semantic_parity_mode,
            ]
        )
        if args.with_comparability_parity_gate:
            command.append("--with-comparability-parity-gate")
        if args.with_dropin_gate:
            command.extend(
                [
                    "--with-dropin-gate",
                    "--dropin-artifact",
                    args.dropin_artifact,
                ]
            )
            if args.dropin_skip_benchmarks:
                command.append("--dropin-skip-benchmarks")
        if args.with_claim_gate:
            command.extend(
                [
                    "--with-claim-gate",
                    "--claim-require-comparison-status",
                    args.claim_require_comparison_status,
                    "--claim-require-claim-status",
                    args.claim_require_claim_status,
                    "--claim-require-claimability-mode",
                    args.claim_require_claimability_mode,
                    "--claim-require-min-timed-samples",
                    str(args.claim_require_min_timed_samples),
                ]
            )
        if args.with_cycle_gate:
            command.extend(
                [
                    "--with-cycle-gate",
                    "--cycle-contract",
                    args.cycle_contract,
                    "--cycle-gate-out",
                    args.cycle_gate_out,
                    "--cycle-artifact-class",
                    args.cycle_artifact_class,
                    "--cycle-comparability-obligations",
                    args.cycle_comparability_obligations,
                ]
            )
            if args.cycle_substantiation_report.strip():
                command.extend(
                    [
                        "--cycle-substantiation-report",
                        args.cycle_substantiation_report.strip(),
                    ]
                )
            if not args.cycle_enforce_rollbacks:
                command.append("--no-cycle-enforce-rollbacks")
        else:
            command.append("--no-with-cycle-gate")
        if not args.compare_html_output:
            command.append("--no-compare-html-output")
        if not args.with_claim_rehearsal_artifacts:
            command.append("--no-with-claim-rehearsal-artifacts")
        if args.timestamp_output:
            command.extend(["--timestamp", window_timestamp])
        else:
            command.append("--no-timestamp-output")

        window_record: dict[str, Any] = {
            "windowIndex": idx,
            "timestamp": window_timestamp,
            "reportPath": str(report_path),
            "cycleGateReportPath": (
                str(
                    output_paths.with_timestamp(
                        args.cycle_gate_out,
                        window_timestamp,
                        enabled=args.timestamp_output,
                    )
                )
                if args.with_cycle_gate
                else ""
            ),
            "claimRehearsalManifestPath": str(
                Path(f"{report_path.with_suffix('')}.claim-rehearsal.manifest.json")
            ),
            "command": command,
        }

        if args.dry_run:
            print(f"[window {idx}] {' '.join(command)}")
            window_record["returnCode"] = None
            window_record["dryRun"] = True
        else:
            completed = subprocess.run(command, capture_output=True, text=True, check=False)
            window_record["returnCode"] = completed.returncode
            window_record["stdout"] = completed.stdout
            window_record["stderr"] = completed.stderr
            if completed.returncode != 0:
                failed_windows.append(idx)
            window_record["reportSummary"] = summarize_report(report_path)

        windows.append(window_record)

        if failed_windows and not args.continue_on_failure and not args.dry_run:
            break

    completed_windows = len(windows)
    passed_windows = sum(
        1
        for window in windows
        if window.get("returnCode") == 0
        and isinstance(window.get("reportSummary"), dict)
        and window["reportSummary"].get("claimStatus") == "claimable"
        and window["reportSummary"].get("comparisonStatus") == "comparable"
    )

    payload = {
        "schemaVersion": 1,
        "generatedAtUtc": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        "outputTimestamp": base_timestamp,
        "config": str(config_path),
        "windowsRequested": args.windows,
        "windowsCompleted": completed_windows,
        "windowsPassedClaimableComparable": passed_windows,
        "failedWindowIndexes": failed_windows,
        "strictAmdVulkan": args.strict_amd_vulkan,
        "withDropinGate": args.with_dropin_gate,
        "dropinArtifact": args.dropin_artifact if args.with_dropin_gate else "",
        "withClaimGate": args.with_claim_gate,
        "withClaimRehearsalArtifacts": args.with_claim_rehearsal_artifacts,
        "withCycleGate": args.with_cycle_gate,
        "cycleContract": args.cycle_contract if args.with_cycle_gate else "",
        "cycleGateOut": args.cycle_gate_out if args.with_cycle_gate else "",
        "cycleArtifactClass": args.cycle_artifact_class if args.with_cycle_gate else "",
        "cycleComparabilityObligations": (
            args.cycle_comparability_obligations if args.with_cycle_gate else ""
        ),
        "cycleSubstantiationReport": (
            args.cycle_substantiation_report if args.with_cycle_gate else ""
        ),
        "cycleEnforceRollbacks": (
            bool(args.cycle_enforce_rollbacks) if args.with_cycle_gate else False
        ),
        "withSubstantiationGate": args.with_substantiation_gate,
        "substantiationPolicy": args.substantiation_policy if args.with_substantiation_gate else "",
        "substantiationReport": str(substantiation_report_path) if args.with_substantiation_gate else "",
        "timestampOutput": args.timestamp_output,
        "dryRun": args.dry_run,
        "windows": windows,
    }

    if args.with_substantiation_gate:
        substantiation_cmd_preview = [
            python_exe,
            str(substantiation_gate),
            "--policy",
            args.substantiation_policy,
            "--summary",
            str(out_path),
            "--out",
            str(substantiation_report_path),
            "--no-timestamp-output",
        ]
        payload["substantiationCommand"] = substantiation_cmd_preview
        if args.dry_run:
            print(f"[substantiation] {' '.join(substantiation_cmd_preview)}")

    if args.dry_run:
        print("PASS: release claim-window plan generated")
        print(f"report: {out_path}")
        return 0

    write_report(out_path, payload)

    substantiation_failed = False
    if args.with_substantiation_gate and not args.dry_run:
        substantiation_cmd = [
            python_exe,
            str(substantiation_gate),
            "--policy",
            args.substantiation_policy,
            "--summary",
            str(out_path),
            "--out",
            str(substantiation_report_path),
            "--no-timestamp-output",
        ]
        completed = subprocess.run(substantiation_cmd, capture_output=True, text=True, check=False)
        substantiation_result = {
            "command": substantiation_cmd,
            "returnCode": completed.returncode,
            "stdout": completed.stdout,
            "stderr": completed.stderr,
        }
        payload["substantiationResult"] = substantiation_result
        if completed.returncode != 0:
            substantiation_failed = True
        write_report(out_path, payload)

    if not args.dry_run:
        output_paths.write_run_manifest_for_outputs(
            [out_path, substantiation_report_path],
            {
                "runType": "release_claim_windows",
                "config": str(config_path),
                "fullRun": completed_windows == args.windows and not failed_windows,
                "claimGateRan": bool(args.with_claim_gate),
                "dropinGateRan": bool(args.with_dropin_gate),
                "compareHtmlRan": bool(args.compare_html_output),
                "windowsRequested": args.windows,
                "windowsCompleted": completed_windows,
                "failedWindowIndexes": failed_windows,
                "status": (
                    "failed"
                    if (failed_windows or substantiation_failed)
                    else "passed"
                ),
            },
        )

    if failed_windows or substantiation_failed:
        print("FAIL: one or more release claim windows failed")
        if substantiation_failed:
            print("FAIL: substantiation gate failed")
        print(f"report: {out_path}")
        if substantiation_result is not None:
            print(f"substantiation report: {substantiation_report_path}")
        return 1

    print("PASS: release claim windows completed")
    print(f"report: {out_path}")
    if substantiation_result is not None:
        print(f"substantiation report: {substantiation_report_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
