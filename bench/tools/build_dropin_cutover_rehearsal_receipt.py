#!/usr/bin/env python3
"""Build a hash-linked drop-in cutover rehearsal receipt."""

from __future__ import annotations

import argparse
import hashlib
import json
import platform
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

try:
    from bench.tools._repo_import import ensure_repo_root
except ModuleNotFoundError:
    from _repo_import import ensure_repo_root

REPO_ROOT = ensure_repo_root(__file__)

from bench.lib.bench_utils import load_json_object, write_json_object


RECEIPT_KIND = "dropin-cutover-rehearsal-receipt"
CLAIM_KIND = "claim-report"
COMPARE_KIND = "compare-report"
BENCHMARK_POLICY_PATH = Path("config/benchmark-methodology-thresholds.json")
DEFAULT_CUTOVER_POLICY_PATH = Path("config/backend-cutover-policy.json")


def sha256_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def repo_rel(root: Path, path: Path) -> str:
    resolved = path if path.is_absolute() else root / path
    try:
        return resolved.resolve().relative_to(root.resolve()).as_posix()
    except ValueError:
        return str(path)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", default=str(REPO_ROOT))
    parser.add_argument("--cutover-policy", default=str(DEFAULT_CUTOVER_POLICY_PATH))
    parser.add_argument("--dropin-report", required=True)
    parser.add_argument("--rollback-report", required=True)
    parser.add_argument("--rollback-claim", required=True)
    parser.add_argument("--receipt-id", default="")
    parser.add_argument("--out", default="")
    parser.add_argument("--claim-out", default="")
    parser.add_argument("--json", action="store_true", dest="emit_json")
    return parser.parse_args()


def require_object(value: Any, label: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise ValueError(f"{label} must be an object")
    return value


def require_list(value: Any, label: str) -> list[Any]:
    if not isinstance(value, list):
        raise ValueError(f"{label} must be a list")
    return value


def step_by_label(dropin_report: dict[str, Any], label: str) -> dict[str, Any]:
    steps = require_list(dropin_report.get("steps"), "drop-in report steps")
    for step in steps:
        if isinstance(step, dict) and step.get("label") == label:
            return step
    raise ValueError(f"drop-in report missing step: {label}")


def require_step_pass(dropin_report: dict[str, Any], label: str) -> dict[str, Any]:
    step = step_by_label(dropin_report, label)
    if step.get("pass") is not True or step.get("returnCode") != 0:
        raise ValueError(f"drop-in report step did not pass: {label}")
    return step


def embedded_step_report(step: dict[str, Any], label: str) -> dict[str, Any]:
    report = step.get("report")
    if not isinstance(report, dict):
        raise ValueError(f"drop-in report step missing embedded child report: {label}")
    if report.get("pass") is not True:
        raise ValueError(f"drop-in child report did not pass: {label}")
    return report


def observed_execution_backends(compare_report: dict[str, Any]) -> list[str]:
    backends: set[str] = set()

    def collect(value: Any) -> None:
        if isinstance(value, dict):
            for key, item in value.items():
                if key in ("baselineExecutionBackends", "comparisonExecutionBackends"):
                    if isinstance(item, list):
                        backends.update(
                            str(entry)
                            for entry in item
                            if isinstance(entry, str) and entry
                        )
                    continue
                collect(item)
        elif isinstance(value, list):
            for item in value:
                collect(item)

    for workload in require_list(compare_report.get("workloads"), "compare report workloads"):
        if not isinstance(workload, dict):
            continue
        comparability = workload.get("comparability")
        if not isinstance(comparability, dict):
            continue
        collect(comparability)
    return sorted(backends)


def validate_rollback_evidence(
    compare_report: dict[str, Any],
    claim_report: dict[str, Any],
    rollback_report_path: str,
) -> list[str]:
    if compare_report.get("artifactKind") != COMPARE_KIND:
        raise ValueError("rollback report artifactKind must be compare-report")
    if compare_report.get("comparisonStatus") != "comparable":
        raise ValueError("rollback report comparisonStatus must be comparable")
    if claim_report.get("artifactKind") != CLAIM_KIND:
        raise ValueError("rollback claim artifactKind must be claim-report")
    if claim_report.get("pass") is not True:
        raise ValueError("rollback claim must pass")
    if claim_report.get("comparisonStatus") != "comparable":
        raise ValueError("rollback claim comparisonStatus must be comparable")
    if claim_report.get("claimStatus") != "claimable":
        raise ValueError("rollback claim claimStatus must be claimable")
    compare_ref = require_object(claim_report.get("compareReport"), "claim compareReport")
    if compare_ref.get("path") != rollback_report_path:
        raise ValueError("rollback claim compareReport.path must match rollback report")
    backends = observed_execution_backends(compare_report)
    if "dawn_delegate" not in backends:
        raise ValueError("rollback report must observe dawn_delegate execution")
    return backends


def build_receipt(
    *,
    root: Path,
    cutover_policy_path: Path,
    dropin_report_path: Path,
    rollback_report_path: Path,
    rollback_claim_path: Path,
    receipt_id: str = "",
) -> dict[str, Any]:
    cutover_policy = load_json_object(root / cutover_policy_path)
    dropin_report = load_json_object(root / dropin_report_path)
    rollback_report = load_json_object(root / rollback_report_path)
    rollback_claim = load_json_object(root / rollback_claim_path)

    if dropin_report.get("pass") is not True:
        raise ValueError("drop-in gate report must pass")

    symbol_step = require_step_pass(dropin_report, "symbol_gate")
    behavior_step = require_step_pass(dropin_report, "behavior_suite")
    proc_step = require_step_pass(dropin_report, "proc_resolution")
    benchmark_step = require_step_pass(dropin_report, "benchmark_suite")
    require_step_pass(dropin_report, "benchmark_visualization")

    symbol_report = embedded_step_report(symbol_step, "symbol_gate")
    behavior_report = embedded_step_report(behavior_step, "behavior_suite")
    benchmark_report = embedded_step_report(benchmark_step, "benchmark_suite")
    if int(symbol_report.get("missingSymbolCount", -1)) != 0:
        raise ValueError("drop-in symbol gate must report zero missing symbols")

    rollback_policy = require_object(cutover_policy.get("rollback"), "rollback policy")
    cutover = require_object(cutover_policy.get("cutover"), "cutover policy")
    rollback_backend = rollback_policy.get("switchBackend")
    if rollback_backend != "dawn_delegate":
        raise ValueError("rollback policy switchBackend must be dawn_delegate")
    if cutover.get("requireRollbackRehearsal") is not True:
        raise ValueError("cutover policy must require rollback rehearsal")

    rollback_report_rel = rollback_report_path.as_posix()
    observed_backends = validate_rollback_evidence(
        rollback_report,
        rollback_claim,
        rollback_report_rel,
    )

    artifact = str(dropin_report.get("artifact", ""))
    if not artifact:
        raise ValueError("drop-in gate report must record artifact")
    artifact_path = root / artifact
    if not artifact_path.exists():
        raise ValueError(f"drop-in artifact does not exist: {artifact}")

    resolved_receipt_id = (
        receipt_id
        or f"dropin-cutover-{dropin_report.get('outputTimestamp', 'unstamped')}"
    )
    benchmark_html = str(dropin_report.get("benchmarkHtml", ""))
    step_labels = [
        str(step.get("label"))
        for step in require_list(dropin_report.get("steps"), "drop-in report steps")
        if isinstance(step, dict) and isinstance(step.get("label"), str)
    ]
    return {
        "schemaVersion": 1,
        "artifactKind": RECEIPT_KIND,
        "receiptId": resolved_receipt_id,
        "generatedAt": utc_now(),
        "comparisonStatus": "comparable",
        "claimStatus": "claimable",
        "pass": True,
        "platform": {
            "os": platform.system().lower() or sys.platform,
            "machine": platform.machine() or "unknown",
            "pythonVersion": platform.python_version(),
        },
        "cutoverPolicy": {
            "path": cutover_policy_path.as_posix(),
            "sha256": sha256_file(root / cutover_policy_path),
            "targetLane": str(cutover.get("targetLane")),
            "defaultBackend": str(cutover.get("defaultBackend")),
            "requireRollbackRehearsal": True,
            "rollbackSwitchName": str(rollback_policy.get("switchName")),
            "rollbackBackend": "dawn_delegate",
            "requiredCiValidation": bool(rollback_policy.get("requiredCiValidation")),
        },
        "dropinGate": {
            "path": dropin_report_path.as_posix(),
            "sha256": sha256_file(root / dropin_report_path),
            "artifact": artifact,
            "artifactSha256": sha256_file(artifact_path),
            "outputTimestamp": str(dropin_report.get("outputTimestamp")),
            "pass": True,
            "stepLabels": step_labels,
            "benchmarkHtml": benchmark_html,
        },
        "abiValidation": {
            "requiredSymbolCount": int(symbol_report.get("requiredSymbolCount", 0)),
            "exportedSymbolCount": int(symbol_report.get("exportedSymbolCount", 0)),
            "missingSymbolCount": int(symbol_report.get("missingSymbolCount", 0)),
            "extraSymbolCount": int(symbol_report.get("extraSymbolCount", 0)),
            "symbolGatePass": True,
            "behaviorPass": behavior_report.get("pass") is True,
            "procResolutionPass": proc_step.get("pass") is True,
            "benchmarkPass": benchmark_report.get("pass") is True,
        },
        "rollbackBackendEvidence": {
            "report": {
                "path": rollback_report_path.as_posix(),
                "sha256": sha256_file(root / rollback_report_path),
                "artifactKind": str(rollback_report.get("artifactKind")),
            },
            "claim": {
                "path": rollback_claim_path.as_posix(),
                "sha256": sha256_file(root / rollback_claim_path),
                "artifactKind": str(rollback_claim.get("artifactKind")),
            },
            "comparisonStatus": "comparable",
            "claimStatus": "claimable",
            "rollbackBackend": "dawn_delegate",
            "observedExecutionBackends": observed_backends,
        },
        "rehearsal": {
            "switchName": str(rollback_policy.get("switchName")),
            "stagedDefaultBackend": str(cutover.get("defaultBackend")),
            "rollbackBackend": "dawn_delegate",
            "dropinCandidateValid": True,
            "rollbackCandidateValid": True,
            "strictNoRuntimeFallback": rollback_policy.get("switchName")
            == "strict_no_runtime_fallback",
            "rollbackRehearsed": True,
        },
        "reasons": [],
    }


def build_claim_sidecar(
    *,
    root: Path,
    receipt_path: Path,
    receipt: dict[str, Any],
) -> dict[str, Any]:
    benchmark_policy = root / BENCHMARK_POLICY_PATH
    policy_hash = sha256_file(benchmark_policy)
    return {
        "schemaVersion": 1,
        "artifactKind": CLAIM_KIND,
        "generatedAt": utc_now(),
        "compareReport": {
            "path": receipt_path.as_posix(),
            "sha256": sha256_file(root / receipt_path),
        },
        "comparisonStatus": str(receipt["comparisonStatus"]),
        "claimStatus": str(receipt["claimStatus"]),
        "pass": True,
        "claimPolicy": {
            "mode": "release",
            "minTimedSamples": 0,
            "benchmarkPolicy": {
                "path": BENCHMARK_POLICY_PATH.as_posix(),
                "sha256": policy_hash,
            },
            "policyHash": policy_hash,
        },
        "workloads": [
            {
                "workloadId": "dropin_cutover_rehearsal",
                "claimable": True,
                "reasons": [],
                "claimMetricField": "status",
                "claimMetricScope": "dropin-cutover-rehearsal",
                "requiredPositivePercentiles": [],
            }
        ],
        "reasons": [],
    }


def main() -> int:
    args = parse_args()
    root = Path(args.root).resolve()
    cutover_policy_path = Path(args.cutover_policy)
    dropin_report_path = Path(args.dropin_report)
    rollback_report_path = Path(args.rollback_report)
    rollback_claim_path = Path(args.rollback_claim)

    try:
        receipt = build_receipt(
            root=root,
            cutover_policy_path=cutover_policy_path,
            dropin_report_path=dropin_report_path,
            rollback_report_path=rollback_report_path,
            rollback_claim_path=rollback_claim_path,
            receipt_id=args.receipt_id,
        )
        if args.out:
            out_path = Path(args.out)
            write_json_object(root / out_path, receipt)
            if args.claim_out:
                claim_out = Path(args.claim_out)
                claim = build_claim_sidecar(root=root, receipt_path=out_path, receipt=receipt)
                write_json_object(root / claim_out, claim)
        if args.emit_json:
            print(json.dumps(receipt, indent=2, sort_keys=True))
        elif args.out:
            print(f"PASS: drop-in cutover rehearsal receipt written: {args.out}")
            if args.claim_out:
                print(f"claim: {args.claim_out}")
        else:
            print("PASS: drop-in cutover rehearsal receipt")
        return 0
    except (OSError, UnicodeError, json.JSONDecodeError, ValueError) as exc:
        print(f"FAIL: drop-in cutover rehearsal receipt: {exc}")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
