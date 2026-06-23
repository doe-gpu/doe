#!/usr/bin/env python3
"""Validate full frontier-comparable matrix readiness from a compare report.

Legacy name retained for compatibility with existing scripts.
"""

from __future__ import annotations

import sys
from pathlib import Path

try:
    from bench.tools._repo_import import ensure_repo_root
except ModuleNotFoundError:
    from _repo_import import ensure_repo_root

REPO_ROOT = ensure_repo_root(__file__)

import argparse
import json
from typing import Any

from bench.lib import compare_claim_artifacts as artifacts_mod
from bench.lib import report_conformance


def sum_trace_meta(workload: dict[str, Any], side: str, field: str) -> int:
    samples = workload.get(side, {}).get("commandSamples", [])
    total = 0
    for sample in samples:
        trace_meta = sample.get("traceMeta")
        if isinstance(trace_meta, dict):
            raw = trace_meta.get(field, 0)
            if isinstance(raw, (int, float)):
                total += int(raw)
    return total


def load_expected_comparable_workload_ids(path: Path) -> list[str]:
    payload = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(payload, dict):
        raise ValueError(f"invalid workload contract at {path}: expected object")
    raw_workloads = payload.get("workloads")
    if not isinstance(raw_workloads, list):
        raise ValueError(f"invalid workload contract at {path}: missing workloads[]")
    ids: list[str] = []
    for row in raw_workloads:
        if not isinstance(row, dict):
            continue
        workload_id = row.get("id")
        if not isinstance(workload_id, str) or not workload_id:
            continue
        if bool(row.get("comparable", False)):
            ids.append(workload_id)
    return sorted(set(ids))


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Check full frontier-comparable matrix comparability/claimability/correctness counters."
    )
    parser.add_argument("--report", required=True, help="Path to compare report JSON.")
    parser.add_argument(
        "--claim-report",
        default="",
        help="Optional explicit claim report path. Defaults to sibling .claim.json.",
    )
    parser.add_argument(
        "--expected-workloads",
        type=int,
        default=0,
        help="Expected comparable workload count. When 0, derives from --expected-workload-contract.",
    )
    parser.add_argument(
        "--expected-workload-contract",
        default="bench/workloads/workloads.amd.vulkan.json",
        help=(
            "Workload contract JSON used for strict workload-identity checks. "
            "Set to empty string to disable identity/hash checks."
        ),
    )
    parser.add_argument(
        "--allow-missing-workload-contract-hash",
        action="store_true",
        help="Allow reports that do not include workloadContract.sha256 metadata.",
    )
    parser.add_argument(
        "--allow-diagnostic-claim",
        action="store_true",
        help="Allow claimStatus=diagnostic (for non-claim probe runs).",
    )
    parser.add_argument(
        "--comparability-obligations",
        default="config/comparability-obligations.json",
        help="Canonical comparability-obligation contract path.",
    )
    parser.add_argument(
        "--show-top-tail-regressions",
        type=int,
        default=10,
        help="Print up to N workloads with worst p95/p99 deltas (default: 10).",
    )
    args = parser.parse_args()

    report_path = Path(args.report)
    compare_payload, claim_payload, _claim_path = artifacts_mod.load_compare_bundle(
        report_path,
        explicit_claim_path=args.claim_report,
        require_claim=False,
    )
    payload = artifacts_mod.projected_compare_report(
        compare_payload,
        report_path,
        claim_report=claim_payload,
    )
    repo_root = REPO_ROOT
    obligations_path = Path(args.comparability_obligations)
    if not obligations_path.is_absolute():
        obligations_path = repo_root / obligations_path
    try:
        expected_obligation_schema_version, expected_obligation_ids = (
            report_conformance.load_obligation_contract(obligations_path)
        )
    except (OSError, UnicodeError, json.JSONDecodeError, ValueError) as exc:
        print("FAIL")
        print(f"- invalid comparability obligations contract: {exc}")
        return 2

    expected_contract_path = Path(args.expected_workload_contract) if args.expected_workload_contract else None
    expected_workload_ids: list[str] = []
    expected_contract_hash = ""
    if expected_contract_path is not None:
        try:
            if not expected_contract_path.is_absolute():
                expected_contract_path = (repo_root / expected_contract_path).resolve()
            expected_workload_ids = load_expected_comparable_workload_ids(expected_contract_path)
            expected_contract_hash = report_conformance.file_sha256(expected_contract_path)
        except (OSError, UnicodeError, json.JSONDecodeError, ValueError) as exc:
            print("FAIL")
            print(f"- invalid expected workload contract: {exc}")
            return 2

    expected_workload_count = args.expected_workloads
    if expected_workload_count <= 0:
        if expected_workload_ids:
            expected_workload_count = len(expected_workload_ids)
        else:
            expected_workload_count = 0

    workloads = payload.get("workloads", [])
    workload_count = len(workloads) if isinstance(workloads, list) else 0
    report_workload_ids = sorted(
        {
            str(workload.get("id"))
            for workload in workloads
            if isinstance(workload, dict) and isinstance(workload.get("id"), str)
        }
    )
    comparison_status = payload.get("comparisonStatus")
    claim_status = payload.get("claimStatus")
    non_comparable = (
        payload.get("comparabilitySummary", {}) or {}
    ).get("nonComparableCount")
    non_claimable = (payload.get("claimabilitySummary", {}) or {}).get("nonClaimableCount")

    baseline_success_total = 0
    baseline_unsupported_total = 0
    baseline_error_total = 0
    baseline_success_zero = 0
    baseline_unsupported_workloads = 0
    baseline_error_workloads = 0
    comparability_obligation_missing = 0
    comparability_obligation_blocking_failed = 0
    tail_sorted: list[dict[str, Any]] = []
    non_claimable_details: list[dict[str, Any]] = []

    for workload in workloads:
        workload_id = workload.get("id", "<unknown>")
        success = sum_trace_meta(workload, "baseline", "executionSuccessCount")
        unsupported = sum_trace_meta(workload, "baseline", "executionUnsupportedCount")
        error = sum_trace_meta(workload, "baseline", "executionErrorCount")
        baseline_success_total += success
        baseline_unsupported_total += unsupported
        baseline_error_total += error
        if success <= 0:
            baseline_success_zero += 1
        if unsupported > 0:
            baseline_unsupported_workloads += 1
        if error > 0:
            baseline_error_workloads += 1

        delta = workload.get("deltaPercent") or {}
        p95 = delta.get("p95Percent")
        p99 = delta.get("p99Percent")
        if isinstance(p95, (int, float)) and isinstance(p99, (int, float)):
            tail_sorted.append({"id": workload_id, "p95": float(p95), "p99": float(p99)})

        comparability = workload.get("comparability")
        if not isinstance(comparability, dict):
            comparability_obligation_missing += 1
        else:
            obligation_version = comparability.get("obligationSchemaVersion")
            obligations = comparability.get("obligations")
            blocking_failed = comparability.get("blockingFailedObligations")
            if (
                obligation_version != expected_obligation_schema_version
                or not isinstance(obligations, list)
                or not obligations
                or not isinstance(blocking_failed, list)
            ):
                comparability_obligation_missing += 1
            else:
                obligations_valid = True
                for obligation in obligations:
                    if not isinstance(obligation, dict):
                        obligations_valid = False
                        break
                    obligation_id = obligation.get("id")
                    if (
                        not isinstance(obligation_id, str)
                        or not obligation_id
                        or obligation_id not in expected_obligation_ids
                    ):
                        obligations_valid = False
                        break
                    if (
                        not isinstance(obligation.get("blocking"), bool)
                        or not isinstance(obligation.get("applicable"), bool)
                        or not isinstance(obligation.get("passes"), bool)
                    ):
                        obligations_valid = False
                        break
                if not obligations_valid:
                    comparability_obligation_missing += 1
                else:
                    invalid_blocking_ids = [
                        item
                        for item in blocking_failed
                        if not isinstance(item, str)
                        or not item
                        or item not in expected_obligation_ids
                    ]
                    if invalid_blocking_ids:
                        comparability_obligation_missing += 1
                    elif blocking_failed:
                        comparability_obligation_blocking_failed += 1

        claimability = workload.get("claimability")
        if isinstance(claimability, dict) and claimability.get("claimable") is False:
            reasons = claimability.get("reasons")
            if not isinstance(reasons, list):
                reasons = []
            non_claimable_details.append(
                {
                    "id": workload_id,
                    "reasons": [str(item) for item in reasons],
                    "p95": p95,
                    "p99": p99,
                }
            )

    print(f"report={report_path}")
    print(f"workloads={workload_count} expected={expected_workload_count}")
    if expected_contract_path is not None:
        print(f"expected_workload_contract={expected_contract_path}")
        print(f"expected_workload_contract_sha256={expected_contract_hash}")
    print(f"comparisonStatus={comparison_status} nonComparableCount={non_comparable}")
    print(f"claimStatus={claim_status} nonClaimableCount={non_claimable}")
    print(
        "baseline_totals "
        f"success={baseline_success_total} unsupported={baseline_unsupported_total} error={baseline_error_total}"
    )
    print(
        "baseline_workloads "
        f"success_zero={baseline_success_zero} unsupported_nonzero={baseline_unsupported_workloads} "
        f"error_nonzero={baseline_error_workloads}"
    )
    print(
        "comparability_obligations "
        f"missing_or_invalid={comparability_obligation_missing} "
        f"blocking_failed={comparability_obligation_blocking_failed}"
    )
    if tail_sorted:
        tail_sorted.sort(key=lambda row: (row["p95"], row["p99"]))
        limit = max(0, args.show_top_tail_regressions)
        if limit > 0:
            print("worst_tail_regressions:")
            for row in tail_sorted[:limit]:
                print(f"- {row['id']} p95={row['p95']}% p99={row['p99']}%")
    if non_claimable_details:
        print("non_claimable_workloads:")
        for row in non_claimable_details:
            reasons = " | ".join(row["reasons"]) if row["reasons"] else "no reasons listed"
            print(f"- {row['id']} p95={row['p95']} p99={row['p99']} reasons={reasons}")

    failures: list[str] = []
    if workload_count != expected_workload_count:
        failures.append(f"workload count mismatch: {workload_count} != {expected_workload_count}")
    if expected_workload_ids:
        missing_ids = sorted(set(expected_workload_ids) - set(report_workload_ids))
        unexpected_ids = sorted(set(report_workload_ids) - set(expected_workload_ids))
        if missing_ids:
            failures.append(
                "missing expected comparable workload IDs: " + ", ".join(missing_ids)
            )
        if unexpected_ids:
            failures.append(
                "unexpected comparable workload IDs in report: " + ", ".join(unexpected_ids)
            )
        workload_contract = payload.get("workloadContract")
        report_contract_path = ""
        report_contract_hash = ""
        if isinstance(workload_contract, dict):
            raw_path = workload_contract.get("path")
            if isinstance(raw_path, str):
                report_contract_path = raw_path
            raw_hash = workload_contract.get("sha256")
            if isinstance(raw_hash, str):
                report_contract_hash = raw_hash
        if not report_contract_path:
            failures.append("report missing workloadContract.path")
        else:
            resolved_report_contract_path = report_conformance.resolve_contract_path(
                report_path=report_path,
                repo_root=repo_root,
                raw_contract_path=report_contract_path,
            )
            if resolved_report_contract_path != expected_contract_path:
                failures.append(
                    "workload contract path mismatch: "
                    f"report={resolved_report_contract_path} expected={expected_contract_path}"
                )
        if not report_contract_hash:
            if not args.allow_missing_workload_contract_hash:
                failures.append(
                    "report missing workloadContract.sha256; rerun the compare lane with workload contract metadata"
                )
        elif report_contract_hash != expected_contract_hash:
            failures.append(
                "workload contract hash mismatch: "
                f"report={report_contract_hash} expected={expected_contract_hash}"
            )
    if comparison_status != "comparable":
        failures.append(f"comparisonStatus is {comparison_status!r}, expected 'comparable'")
    if non_comparable != 0:
        failures.append(f"nonComparableCount is {non_comparable!r}, expected 0")
    if not args.allow_diagnostic_claim and claim_status != "claimable":
        failures.append(f"claimStatus is {claim_status!r}, expected 'claimable'")
    if baseline_success_zero != 0:
        failures.append(f"{baseline_success_zero} workload(s) have zero baseline executionSuccessCount")
    if baseline_unsupported_workloads != 0 or baseline_unsupported_total != 0:
        failures.append("baseline unsupported counters are non-zero")
    if baseline_error_workloads != 0 or baseline_error_total != 0:
        failures.append("baseline error counters are non-zero")
    if comparability_obligation_missing != 0:
        failures.append(
            f"{comparability_obligation_missing} workload(s) missing/invalid comparability obligations"
        )
    if comparability_obligation_blocking_failed != 0:
        failures.append(
            f"{comparability_obligation_blocking_failed} workload(s) have blocking comparability obligation failures"
        )

    if failures:
        print("FAIL")
        for item in failures:
            print(f"- {item}")
        return 2

    print("PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
